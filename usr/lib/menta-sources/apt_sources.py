#!/usr/bin/python3
"""Read and edit APT source files.

Both the one-line format (*.list) and the deb822 format (*.sources) are
supported. Files are edited in place: entries keep their options (signed-by,
arch...) and content which isn't touched is written back unchanged.
"""
import os
import re

SOURCES_LIST = "/etc/apt/sources.list"
SOURCES_PARTS = "/etc/apt/sources.list.d"
ADDITIONAL_REPOSITORIES = os.path.join(SOURCES_PARTS, "additional-repositories.list")

LEGACY = "list"
DEB822 = "sources"

# apt only reads files in sources.list.d whose names match this
_VALID_PART = re.compile(r"^[A-Za-z0-9_.-]+\.(list|sources)$")

_LEGACY_LINE = re.compile(r"""
    ^\s*(?P<disabled>\#\s*)?
    (?P<type>deb|deb-src)\s+
    (?:\[(?P<options>[^\]]*)\]\s+)?
    (?P<uri>cdrom:\[[^\]]*\]/?\S*|[a-z][a-z0-9+.-]*:\S+)\s+
    (?P<suite>[^\s\#]+)
    (?P<components>(?:[ \t]+[^\s\#]+)*)
    \s*(?:\#.*)?$
    """, re.VERBOSE)

_DEB822_FIELD = re.compile(r"^(?P<key>[^\s:#][^\s:]*)\s*:\s*(?P<value>.*)$")


def _strip_slash(uri):
    return uri.rstrip("/")


class Entry():
    """A repository: one line of a .list file or one stanza of a .sources file."""

    def __init__(self, source_file, types, uris, suites, components, options, enabled):
        self.file = source_file
        self.types = types
        self.uris = uris
        self.suites = suites
        self.components = components
        self.options = options
        self.enabled = enabled

    @property
    def signed_by(self):
        """The keyring path this entry is signed by, if any (inline keys are ignored)."""
        value = self.options.get("signed-by")
        if not value or "\n" in value or "BEGIN PGP" in value:
            return None
        # signed-by can also list fingerprints, only keep the paths
        paths = [item for item in re.split(r"[\s,]+", value) if item.startswith("/")]
        return paths[0] if paths else None

    def set_enabled(self, enabled):
        raise NotImplementedError

    def text(self):
        raise NotImplementedError

    def expand(self):
        """Every (type, uri, suite, component) combination this entry provides."""
        result = set()
        for type_ in self.types:
            for uri in self.uris:
                for suite in self.suites:
                    for component in self.components or [""]:
                        result.add((type_, _strip_slash(uri), suite, component))
        return result

    def matches(self, other):
        return self.expand() == other.expand()

    def __repr__(self):
        return "<Entry %s %s %s %s>" % (" ".join(self.types), " ".join(self.uris),
                                         " ".join(self.suites), " ".join(self.components))


class LegacyEntry(Entry):

    def __init__(self, source_file, line, match):
        options = {}
        for option in (match.group("options") or "").split():
            key, sep, value = option.partition("=")
            options[key.lower()] = value
        Entry.__init__(self, source_file,
                       [match.group("type")],
                       [match.group("uri")],
                       [match.group("suite")],
                       match.group("components").split(),
                       options,
                       not match.group("disabled"))
        self.line = line

    @classmethod
    def parse(cls, source_file, line):
        match = _LEGACY_LINE.match(line)
        if match is None:
            return None
        return cls(source_file, line, match)

    def set_enabled(self, enabled):
        if enabled == self.enabled:
            return
        self.enabled = enabled
        if enabled:
            self.line = re.sub(r"^\s*#\s*", "", self.line)
        else:
            self.line = "# " + self.line.lstrip()

    def text(self):
        return self.line


class Deb822Entry(Entry):

    def __init__(self, source_file, lines, fields):
        Entry.__init__(self, source_file,
                       fields.get("types", "").split(),
                       fields.get("uris", "").split(),
                       fields.get("suites", "").split(),
                       fields.get("components", "").split(),
                       {key: value for key, value in fields.items()
                        if key not in ("types", "uris", "suites", "components", "enabled")},
                       fields.get("enabled", "yes").strip().lower() not in ("no", "false", "without", "off", "0"))
        self.lines = lines

    @classmethod
    def parse(cls, source_file, lines):
        fields = {}
        key = None
        for line in lines:
            if line.startswith("#"):
                continue
            if line[:1] in (" ", "\t") and key is not None:
                fields[key] += "\n" + line.strip()
                continue
            match = _DEB822_FIELD.match(line)
            if match is None:
                key = None
                continue
            key = match.group("key").lower()
            fields[key] = match.group("value").strip()
        if not (fields.get("types") and fields.get("uris") and fields.get("suites")):
            return None
        return cls(source_file, lines, fields)

    def set_enabled(self, enabled):
        if enabled == self.enabled:
            return
        self.enabled = enabled
        lines = [line for line in self.lines if not re.match(r"^enabled\s*:", line, re.IGNORECASE)]
        if not enabled:
            position = next((i + 1 for i, line in enumerate(lines)
                             if re.match(r"^types\s*:", line, re.IGNORECASE)), 0)
            lines.insert(position, "Enabled: no")
        self.lines = lines

    def text(self):
        return "\n".join(self.lines)


class SourceFile():

    def __init__(self, path):
        self.path = path
        self.format = DEB822 if path.endswith(".sources") else LEGACY
        # Raw text (str) and Entry objects, in file order
        self.items = []

    @property
    def name(self):
        return os.path.splitext(os.path.basename(self.path))[0]

    @property
    def entries(self):
        return [item for item in self.items if isinstance(item, Entry)]

    def load(self):
        self.items = []
        if not os.path.exists(self.path):
            return self
        with open(self.path, encoding="utf-8", errors="replace") as f:
            content = f.read()
        if self.format == LEGACY:
            for line in content.splitlines():
                entry = LegacyEntry.parse(self, line)
                self.items.append(entry if entry is not None else line)
        else:
            for paragraph in re.split(r"\n[ \t]*\n", content.strip("\n")):
                lines = paragraph.strip("\n").split("\n")
                entry = Deb822Entry.parse(self, lines)
                self.items.append(entry if entry is not None else paragraph.strip("\n"))
        return self

    def text(self):
        parts = [item.text() if isinstance(item, Entry) else item for item in self.items]
        if self.format == LEGACY:
            return "\n".join(parts) + "\n"
        return "\n\n".join(part for part in parts if part.strip()) + "\n"

    def save(self):
        if not self.entries and self.path != SOURCES_LIST:
            if os.path.exists(self.path):
                os.unlink(self.path)
            return
        with open(self.path, "w", encoding="utf-8") as f:
            f.write(self.text())
        os.chmod(self.path, 0o644)

    def add_line(self, line):
        """Append a one-line repository definition (legacy files only)."""
        entry = LegacyEntry.parse(self, line)
        if entry is None:
            raise ValueError(line)
        self.items.append(entry)
        return entry

    def remove(self, entry):
        self.items.remove(entry)


def source_file_paths(sources_list=None, parts_dir=None):
    """The source files apt reads, in the order it reads them."""
    sources_list = sources_list or SOURCES_LIST
    parts_dir = parts_dir or SOURCES_PARTS
    paths = []
    if os.path.isfile(sources_list):
        paths.append(sources_list)
    if os.path.isdir(parts_dir):
        for name in sorted(os.listdir(parts_dir)):
            path = os.path.join(parts_dir, name)
            if _VALID_PART.match(name) and os.path.isfile(path):
                paths.append(path)
    return paths


def load_files(sources_list=None, parts_dir=None):
    return [SourceFile(path).load() for path in source_file_paths(sources_list, parts_dir)]


def all_entries(files):
    return [entry for source_file in files for entry in source_file.entries]


def repo_key_path(uri, entries):
    """The keyring of the first enabled entry using this URI, if it is signed-by."""
    uri = _strip_slash(uri)
    for entry in entries:
        if not entry.enabled or not entry.signed_by:
            continue
        if any(uri == _strip_slash(u) for u in entry.uris):
            return entry.signed_by
    return None


def expand_http_line(line, codename):
    """
    Short cut, this:
      add-apt-repository http://example.com/debian main contrib
    is the same as:
      add-apt-repository 'deb http://example.com/debian <codename> main contrib'
    """
    if not line.startswith("http"):
        return line
    pieces = line.split()
    components = " ".join(pieces[1:]) or "main"
    return "deb %s %s %s" % (pieces[0], codename, components)


def repo_malformed(line):
    match = _LEGACY_LINE.match(line)
    return match is None or match.group("disabled") is not None


def repo_exists(line, entries):
    """Whether everything this line provides is already configured."""
    new_entry = LegacyEntry.parse(None, line)
    if new_entry is None:
        return False
    known = set()
    for entry in entries:
        known |= entry.expand()
    return new_entry.expand() <= known


def find_entries(line, files):
    """The configured entries which match this line."""
    wanted = LegacyEntry.parse(None, line)
    if wanted is None:
        return []
    return [entry for entry in all_entries(files) if entry.matches(wanted)]


def remove_duplicates(files):
    """Remove enabled entries which only provide what earlier entries already provide.

    Files are processed in the given order, so put the ones to keep first.
    Returns the list of files which were modified (not saved yet).
    """
    known = set()
    modified = []
    for source_file in files:
        for entry in source_file.entries:
            if not entry.enabled:
                continue
            provided = entry.expand()
            if provided <= known:
                source_file.remove(entry)
                if source_file not in modified:
                    modified.append(source_file)
            else:
                known |= provided
    return modified
