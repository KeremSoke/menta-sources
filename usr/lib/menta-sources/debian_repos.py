#!/usr/bin/python3
"""The official Debian repositories.

They are written in deb822 format to /etc/apt/sources.list.d/debian.sources,
the same file "apt modernize-sources" produces. Settings are read back from
that file, so it can also be edited by hand or by other tools.
"""
import configparser
import datetime
import os
import re
import shutil
import urllib.parse

import apt_sources

CONFIG_DIR = "/usr/share/menta-sources"
OFFICIAL_FILE = os.path.join(apt_sources.SOURCES_PARTS, "debian.sources")
BACKUP_DIR = "/var/backups/menta-sources"
DEBIAN_KEYRING = "/usr/share/keyrings/debian-archive-keyring.gpg"

# Optional suites, in the order they're displayed
SUITES = ["security", "updates", "backports", "proposed-updates", "experimental"]

HEADER = """# Official Debian repositories, managed by Software Sources (menta-sources).
# Use Software Sources to change them, manual edits may be overwritten.
"""


class Release():
    """A Debian release, as described in /usr/share/menta-sources/<codename>/menta-sources.conf"""

    def __init__(self, path):
        parser = configparser.RawConfigParser()
        if not parser.read(path):
            raise FileNotFoundError(path)
        self.codename = parser.get("general", "codename")
        self.description = parser.get("general", "description", fallback=self.codename)
        self.alias = parser.get("general", "alias", fallback="")
        self.keyring = parser.get("general", "keyring", fallback=DEBIAN_KEYRING)
        self.mirror = parser.get("mirrors", "default").rstrip("/")
        self.security_mirror = parser.get("mirrors", "security", fallback="").rstrip("/")
        self.debug_mirror = parser.get("mirrors", "debug", fallback="").rstrip("/")
        self.security_debug_mirror = parser.get("mirrors", "security_debug", fallback="").rstrip("/")
        self.mirrors_file = parser.get("mirrors", "mirrors", fallback="")
        self.components = parser.get("components", "available").split()
        self.default_components = parser.get("components", "default").split()
        self.suites = [s for s in SUITES if s in parser.get("suites", "available", fallback="").split()]
        self.default_suites = parser.get("suites", "default", fallback="").split()
        self.keyserver = parser.get("keys", "keyserver", fallback="hkps://keyserver.ubuntu.com")

    def suite_name(self, suite, codename=None):
        codename = codename or self.codename
        if suite == "experimental":
            return "experimental"
        return "%s-%s" % (codename, suite)

    def base_names(self):
        return [name for name in (self.codename, self.alias) if name]

    def classify_suite(self, name):
        """Returns (suite, is_debug) for an official suite name, suite being None for the base
        suite, or raises ValueError for suites which don't belong to this release."""
        debug = name.endswith("-debug")
        if debug:
            name = name[:-len("-debug")]
        for base in self.base_names():
            if name == base:
                return (None, debug)
            for suite in SUITES:
                if name == self.suite_name(suite, base):
                    return (suite, debug)
            # Old security suite name: <codename>/updates
            if name == "%s/updates" % base:
                return ("security", debug)
        raise ValueError(name)


class Settings():
    """What the user selected for the official repositories."""

    def __init__(self, mirror, security_mirror, components, suites, source_code=False, debug=False):
        self.mirror = mirror
        self.security_mirror = security_mirror
        self.components = list(components)
        self.suites = list(suites)
        self.source_code = source_code
        self.debug = debug

    def __eq__(self, other):
        return vars(self) == vars(other)

    def __repr__(self):
        return "<Settings %s>" % vars(self)


def config_path(codename, config_dir=None):
    return os.path.join(config_dir or CONFIG_DIR, codename, "menta-sources.conf")


def load_release(codename, config_dir=None):
    return Release(config_path(codename, config_dir))


def read_os_release(path="/etc/os-release"):
    values = {}
    with open(path, encoding="utf-8", errors="ignore") as f:
        for line in f:
            key, sep, value = line.strip().partition("=")
            if sep and not key.startswith("#"):
                values[key] = value.strip().strip("\"'")
    return values


def detect_codename(entries=(), os_release="/etc/os-release", debian_version="/etc/debian_version"):
    """The codename of the running Debian release.

    Testing and unstable share the same os-release, both say they are the
    next stable release, so unstable is recognized by its repositories.
    """
    codename = read_os_release(os_release).get("VERSION_CODENAME", "unknown")
    try:
        with open(debian_version, encoding="utf-8", errors="ignore") as f:
            version = f.read().strip()
    except OSError:
        version = ""
    if version.endswith("/sid"):
        for entry in entries:
            if entry.enabled and "deb" in entry.types and set(entry.suites) & {"sid", "unstable"}:
                return "sid"
    return codename


def default_settings(release):
    return Settings(release.mirror,
                    release.security_mirror,
                    [c for c in release.components if c in release.default_components],
                    [s for s in release.suites if s in release.default_suites])


def _host(uri):
    return urllib.parse.urlparse(uri).hostname or ""


def read_mirror_hosts(release):
    hosts = set()
    if release.mirrors_file and os.path.exists(release.mirrors_file):
        with open(release.mirrors_file, encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    hosts.add(_host(line.split()[0]))
    return hosts


def is_official(release, entry, mirror_hosts=()):
    """Whether this entry is one of the official Debian repositories of this release."""
    try:
        for suite in entry.suites:
            release.classify_suite(suite)
    except ValueError:
        return False
    for uri in entry.uris:
        if not re.search(r"/debian(-security)?(-debug)?/?$", uri):
            return False
        host = _host(uri)
        # Third party repositories often live under /debian too, so only trust
        # known Debian hosts or entries signed by the Debian archive key.
        if not (host == "debian.org" or host.endswith(".debian.org") or host in mirror_hosts
                or entry.signed_by == release.keyring):
            return False
    return bool(entry.uris)


def detect_settings(release, entries):
    """Read the settings from official entries, None if the base suite isn't there."""
    mirror = None
    security_mirror = None
    components = []
    suites = []
    source_code = False
    debug = False
    for entry in entries:
        if not entry.enabled:
            continue
        for name in entry.suites:
            try:
                suite, is_debug = release.classify_suite(name)
            except ValueError:
                continue
            if is_debug:
                debug = True
                continue
            if suite is None and "deb" in entry.types and mirror is None:
                mirror = entry.uris[0].rstrip("/")
            if suite == "security" and security_mirror is None:
                security_mirror = entry.uris[0].rstrip("/")
            if suite is not None and suite in release.suites and suite not in suites:
                suites.append(suite)
            if suite is None and "deb-src" in entry.types:
                source_code = True
            for component in entry.components:
                if component not in components:
                    components.append(component)
    if mirror is None:
        return None
    ordered = [c for c in release.components if c in components]
    ordered += [c for c in components if c not in ordered]
    return Settings(mirror,
                    security_mirror or release.security_mirror,
                    ordered,
                    [s for s in release.suites if s in suites],
                    source_code,
                    debug)


def merge_settings(release, settings, other):
    """Add everything enabled in other to settings, so that nothing apt currently uses is lost."""
    for component in other.components:
        if component not in settings.components:
            settings.components.append(component)
    settings.suites = [s for s in release.suites if s in settings.suites or s in other.suites]
    settings.source_code = settings.source_code or other.source_code
    settings.debug = settings.debug or other.debug
    return settings


def _stanza(types, uri, suites, components, keyring):
    lines = ["Types: %s" % " ".join(types),
             "URIs: %s" % uri,
             "Suites: %s" % " ".join(suites),
             "Components: %s" % " ".join(components)]
    if keyring:
        lines.append("Signed-By: %s" % keyring)
    return "\n".join(lines) + "\n"


def render(release, settings):
    """The content of debian.sources for these settings."""
    types = ["deb", "deb-src"] if settings.source_code else ["deb"]
    components = list(settings.components)
    if "main" not in components:
        components.insert(0, "main")
    keyring = release.keyring or None

    main_suites = [release.codename]
    main_suites += [release.suite_name(s) for s in settings.suites if s != "security"]
    stanzas = [_stanza(types, settings.mirror, main_suites, components, keyring)]

    security = "security" in settings.suites and settings.security_mirror
    if security:
        stanzas.append(_stanza(types, settings.security_mirror,
                               [release.suite_name("security")], components, keyring))

    if settings.debug and release.debug_mirror:
        # There are no debug symbols for -updates, they are in the base -debug suite
        debug_suites = ["%s-debug" % release.codename]
        debug_suites += ["%s-debug" % release.suite_name(s) for s in settings.suites
                         if s in ("backports", "proposed-updates", "experimental")]
        stanzas.append(_stanza(["deb"], release.debug_mirror, debug_suites, components, keyring))
        if security and release.security_debug_mirror:
            stanzas.append(_stanza(["deb"], release.security_debug_mirror,
                                   ["%s-debug" % release.suite_name("security")], components, keyring))

    return HEADER + "\n" + "\n".join(stanzas)


def write(release, settings, path=None):
    path = path or OFFICIAL_FILE
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(render(release, settings))
    os.chmod(path, 0o644)


def backup(path, backup_dir=None):
    backup_dir = backup_dir or BACKUP_DIR
    os.makedirs(backup_dir, mode=0o755, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    destination = os.path.join(backup_dir, "%s.%s" % (os.path.basename(path), stamp))
    shutil.copy2(path, destination)
    return destination


def prepare(release, files, official_path=None, backup_dir=None):
    """Make sure the official repositories are configured in debian.sources.

    Official entries found in other files are moved into debian.sources, after
    saving a backup of the files they came from.

    Returns (settings, migrated) where migrated lists (path, backup path) tuples.
    """
    official_path = official_path or OFFICIAL_FILE
    mirror_hosts = read_mirror_hosts(release)

    official_file = next((f for f in files if f.path == official_path), None)
    settings = detect_settings(release, official_file.entries) if official_file else None

    legacy = [entry for source_file in files if source_file.path != official_path
              for entry in source_file.entries if is_official(release, entry, mirror_hosts)]
    legacy_settings = detect_settings(release, legacy)

    if settings is None:
        settings = legacy_settings or default_settings(release)
    elif legacy_settings is not None:
        merge_settings(release, settings, legacy_settings)

    if official_file is None or legacy:
        write(release, settings, official_path)

    migrated = []
    for source_file in {entry.file.path: entry.file for entry in legacy}.values():
        backup_path = backup(source_file.path, backup_dir)
        for entry in legacy:
            if entry.file is source_file:
                source_file.remove(entry)
        if not source_file.entries:
            # Files in sources.list.d are deleted, leave a pointer in sources.list
            source_file.items = ["# The official Debian repositories are configured in %s" % official_path]
        source_file.save()
        migrated.append((source_file.path, backup_path))

    return (settings, migrated)
