#!/usr/bin/python3
import argparse
import configparser
import datetime
import gettext
import glob
import gnupg
import json
import locale
import os
import pycurl
import re
import requests
import shutil
import signal
import subprocess
import sys
import tempfile

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, Gio, GLib

import apt_pkg

import apt_sources
import debian_repos
from apt_runner import AptCommand
from CountryInformation import CountryInformation

LIB_DIR = os.path.dirname(os.path.abspath(__file__))

# Used when launched by synaptic (via software-properties-gtk).
# The return code tells synaptic to refresh the cache if sources have changed
# If we try to refresh ourselves in this scenario, apt.Cache gets stuck waiting
# for synaptic to exit...
disable_refresh = False
sources_changed = False

# User agent used by pycurl requests
USER_AGENT = "menta-sources (Debian; +https://www.debian.org/mirror/)"

# Keys of the Debian archive itself, which are not shown in the list
DEBIAN_KEYRINGS = ["/usr/share/keyrings/debian-archive-keyring.gpg",
                   "/usr/share/keyrings/debian-archive-removed-keys.gpg"]

# i18n
APP = 'menta-sources'
LOCALE_DIR = "/usr/share/locale"
locale.bindtextdomain(APP, LOCALE_DIR)
gettext.bindtextdomain(APP, LOCALE_DIR)
gettext.textdomain(APP)
_ = gettext.gettext

os.umask(0o022)

def signal_handler(signum, _):
    print("")
    sys.exit(128 + signum)

signal.signal(signal.SIGINT, signal_handler)

COMPONENT_DESCRIPTIONS = {
    "main": _("Free software supported by Debian"),
    "contrib": _("Free software which depends on non-free software"),
    "non-free": _("Software which doesn't comply with the Debian Free Software Guidelines"),
    "non-free-firmware": _("Non-free firmware for hardware support"),
}

SUITE_DESCRIPTIONS = {
    "security": _("Important security updates"),
    "updates": _("Recommended updates"),
    "backports": _("Newer versions of selected packages (backports)"),
    "proposed-updates": _("Updates proposed for the next point release"),
    "experimental": _("Experimental packages"),
}

def init_gnupg():
    # gpg commands fail until its folders exist in the user's home
    subprocess.run(["gpg", "--list-keys"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def import_to_temp_keyring(tmpdir, filename):
    gpg = gnupg.GPG(keyring=os.path.join(tmpdir, "keyring.gpg"))
    with open(filename, "rb") as f:
        return gpg, gpg.import_keys(f.read())

def add_remote_key(fingerprint, keyserver, path=None):
    """Download a key into path, or into trusted.gpg.d if no path is given."""
    try:
        if path is None:
            path = "/etc/apt/trusted.gpg.d/%s.gpg" % re.sub("[^A-Za-z0-9]", "", fingerprint)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        init_gnupg()
        with tempfile.TemporaryDirectory(prefix="menta-sources-") as tmpdir:
            keyring = os.path.join(tmpdir, "keyring.gpg")
            key = os.path.join(tmpdir, "key.gpg")
            cmd = ["gpg", "--yes", "--no-default-keyring", "--keyring", keyring, "--keyserver", keyserver]
            if os.environ.get('http_proxy'):
                cmd.append("--honor-http-proxy")
            subprocess.run(cmd + ["--recv-keys", fingerprint], check=True)
            subprocess.run(["gpg", "--yes", "--no-default-keyring", "--keyring", keyring, "--export", "-o", key], check=True)
            shutil.move(key, path)
        os.chmod(path, 0o644)
    except (subprocess.CalledProcessError, OSError) as e:
        print("E: Could not download key %s: %s" % (fingerprint, e), file=sys.stderr)
        return False
    return True

def add_local_key(filename):
    init_gnupg()
    if not gnupg.GPG().scan_keys(filename):
        return None

    with tempfile.TemporaryDirectory(prefix="menta-sources-") as tmpdir:
        gpg, imported = import_to_temp_keyring(tmpdir, filename)
        if not imported.fingerprints:
            return None
        data = gpg.export_keys(imported.fingerprints, armor=False)

    if not data:
        return None

    key_path = "/etc/apt/trusted.gpg.d/%s.gpg" % imported.fingerprints[0]
    with open(key_path, "wb") as f:
        f.write(data)
    os.chmod(key_path, 0o644)
    return key_path

SPEED_PIX_WIDTH = 125

def format_fingerprint(fingerprint):
    groups = [fingerprint[i:i + 4] for i in range(0, len(fingerprint), 4)]
    return "%s  %s" % (" ".join(groups[:5]), " ".join(groups[5:]))

class Key():
    def __init__(self, pub, uid="", paths=None, removable=True, sources=None):
        self.pub = pub
        self.sub = ""
        self.uid = uid
        self.paths = paths or []
        self.removable = removable
        self.sources = sources or []

    def delete(self):
        init_gnupg()
        for path in self.paths:
            armored = path.endswith(".asc")
            with tempfile.TemporaryDirectory(prefix="menta-sources-") as tmpdir:
                gpg, imported = import_to_temp_keyring(tmpdir, path)
                gpg.delete_keys(self.pub.replace(" ", ""))
                remaining = [key["fingerprint"] for key in gpg.list_keys()]
                data = gpg.export_keys(remaining, armor=armored) if remaining else None

            if data:
                with open(path, "w" if armored else "wb") as f:
                    f.write(data)
                os.chmod(path, 0o644)
            else:
                os.remove(path)

    def get_name(self):
        details = [self.pub] + self.paths
        if self.sources:
            details.append(_("Used by: %s") % ", ".join(sorted(set(self.sources))))
        details = "".join(["\n<small>    %s</small>" % GLib.markup_escape_text(detail) for detail in details])
        return "%s%s" % (GLib.markup_escape_text(self.uid), details)

class Mirror():
    def __init__(self, country_code, url, name):
        self.country_code = country_code
        self.url = url
        self.name = name

class Source():
    """A repository listed in the Other Software tab."""
    def __init__(self, application, entry):
        self.application = application
        self.entry = entry
        self.filename = entry.file.path

        uri = entry.uris[0]
        self.name = uri
        if uri.startswith("cdrom:"):
            self.name = _("CD-ROM (Installation Disc)")
        elif uri.startswith("file:"):
            self.name = _("Local Repository")
        elif "://" in uri:
            host = uri.split("://", 1)[1].split("/")[0].split(":")[0]
            subparts = host.split(".")
            if len(subparts) > 2 and subparts[-2] in ("co", "com", "org", "net", "ac") and len(subparts[-1]) == 2:
                self.name = subparts[-3].capitalize()
            elif len(subparts) >= 2:
                self.name = subparts[-2].capitalize()
            else:
                self.name = host

        types = " ".join(entry.types)
        uris = " ".join(entry.uris)
        suites = " ".join(entry.suites)
        components = " ".join(entry.components)
        details = GLib.markup_escape_text(f"{types} {uris} {suites} {components}".strip())
        self.ui_name = f"<b>{GLib.markup_escape_text(self.name)}</b>\n<small><i>{details}\n{GLib.markup_escape_text(self.filename)}</i></small>"

    def is_enabled(self):
        return self.entry.enabled

    def switch(self):
        self.entry.set_enabled(not self.entry.enabled)
        self.entry.file.save()
        self.application.enable_reload_button()

    def delete(self):
        self.entry.file.remove(self.entry)
        self.entry.file.save()
        self.application.enable_reload_button()

class MirrorSelectionDialog(object):
    MIRROR_COLUMN = 0
    MIRROR_URL_COLUMN = 1
    MIRROR_COUNTRY_COLUMN = 2
    MIRROR_SPEED_COLUMN = 3
    MIRROR_SPEED_LABEL_COLUMN = 4
    MIRROR_TOOLTIP_COLUMN = 5
    MIRROR_NAME_COLUMN = 6

    def __init__(self, application, ui_builder):
        self._application = application
        self._ui_builder = ui_builder

        self._dialog = ui_builder.get_object("mirror_selection_dialog")
        self._dialog.set_transient_for(application.main_window)

        self._mirrors_model = Gtk.ListStore(object, str, str, float, str, str, str)
        # mirror, url, country name, speed, speed label, tooltip, mirror name
        self._treeview = ui_builder.get_object("mirrors_treeview")
        self._treeview.set_model(self._mirrors_model)
        self._treeview.set_headers_clickable(True)
        self._treeview.connect("row-activated", self._row_activated)

        self._mirrors_model.set_sort_column_id(MirrorSelectionDialog.MIRROR_SPEED_COLUMN, Gtk.SortType.DESCENDING)

        # Since GtkListStore sorts the mirrors internally, we need a copy of the iterators in their original order
        self._mirrors_iters = []
        self._gtask = None

        r = Gtk.CellRendererText()
        col = Gtk.TreeViewColumn(_("Country"), r, text = MirrorSelectionDialog.MIRROR_COUNTRY_COLUMN)
        self._treeview.append_column(col)
        col.set_sort_column_id(MirrorSelectionDialog.MIRROR_COUNTRY_COLUMN)

        r = Gtk.CellRendererText()
        col = Gtk.TreeViewColumn(_("Server"), r, text = MirrorSelectionDialog.MIRROR_NAME_COLUMN)
        col.set_expand(True)
        self._treeview.append_column(col)
        col.set_sort_column_id(MirrorSelectionDialog.MIRROR_NAME_COLUMN)

        r = Gtk.CellRendererText()
        col = Gtk.TreeViewColumn(_("Speed"), r, text = MirrorSelectionDialog.MIRROR_SPEED_LABEL_COLUMN)
        self._treeview.append_column(col)
        col.set_sort_column_id(MirrorSelectionDialog.MIRROR_SPEED_COLUMN)
        col.set_min_width(int(1.1 * SPEED_PIX_WIDTH))

        self._treeview.set_tooltip_column(MirrorSelectionDialog.MIRROR_TOOLTIP_COLUMN)

        self.country_info = CountryInformation()

        with open(os.path.join(LIB_DIR, "countries.json"), encoding="utf-8", errors="ignore") as data_file:
            self.countries = json.load(data_file)

        self.arch = subprocess.getoutput("dpkg --print-architecture").strip() or "amd64"

    def _row_activated(self, treeview, path, view_column):
        self._dialog.response(Gtk.ResponseType.APPLY)

    def get_country(self, country_code):
        for country in self.countries:
            if country["cca2"] == country_code:
                return country
        return None

    def _update_list(self):
        self._mirrors_model.clear()
        self._mirrors_iters.clear()

        for mirror in self.visible_mirrors:
            if mirror.country_code == "WD":
                country_name = _("Worldwide")
            else:
                country_name = self.country_info.get_country_name(mirror.country_code)
            tooltip = country_name
            if mirror.name != mirror.url:
                tooltip = "%s: %s" % (country_name, mirror.url)
            self._mirrors_model.append((
                mirror,
                mirror.url,
                country_name,
                0,
                None,
                tooltip,
                mirror.name
            ))

        iter = self._mirrors_model.get_iter_first()
        while iter is not None:
            self._mirrors_iters.append(iter)
            iter = self._mirrors_model.iter_next(iter)

    def get_url_last_modified(self, url):
        try:
            c = pycurl.Curl()
            c.setopt(pycurl.URL, url)
            c.setopt(pycurl.CONNECTTIMEOUT, 5)
            c.setopt(pycurl.TIMEOUT, 30)
            c.setopt(pycurl.FOLLOWLOCATION, 1)
            c.setopt(pycurl.NOBODY, 1)
            c.setopt(pycurl.OPT_FILETIME, 1)
            c.setopt(pycurl.USERAGENT, USER_AGENT)
            c.perform()
            filetime = c.getinfo(pycurl.INFO_FILETIME)
            if filetime < 0:
                return None
            else:
                return filetime
        except:
            return None

    def check_mirror_up_to_date(self, url):
        # If the default mirror is unavailable it's likely temporary, assume the mirror is ok.
        if self.default_mirror_date is None:
            return True
        # Every Debian mirror updates this file each time it syncs with the archive
        mirror_timestamp = self.get_url_last_modified("%s/project/trace/master" % url)
        if mirror_timestamp is None:
            print ("Error: Can't find the age of %s !!" % url)
            return False
        mirror_date = datetime.datetime.fromtimestamp(mirror_timestamp)
        mirror_age = (self.default_mirror_date - mirror_date).days
        if (mirror_age > 2):
            print ("Error: %s is out of date by %d days!" % (url, mirror_age))
            return False
        return True

    def _get_speed_label(self, speed):
        if speed > 0:
            divider = (1024 * 1.0)
            represented_speed = (speed / divider)   # translate it to kB/S
            unit = _("kB/s")
            if represented_speed > divider:
                represented_speed = (represented_speed / divider)   # translate it to MB/S
                unit = _("MB/s")
            if represented_speed > divider:
                represented_speed = (represented_speed / divider)   # translate it to GB/S
                unit = _("GB/s")
            num_int_digits = len("%d" % represented_speed)
            if (num_int_digits > 2):
                represented_speed = "%d %s" % (represented_speed, unit)
            else:
                represented_speed = "%.1f %s" % (represented_speed, unit)
            represented_speed = represented_speed.replace(".0", "")
        else:
            represented_speed = ("0 %s") % _("kB/s")
        return represented_speed

    def _speed_test_thread(self, task, source_object, task_data, cancellable):
        url = self.current_speed_test_mirror
        download_speed = 0
        try:
            if self.check_mirror_up_to_date(url):
                test_url = "%s/dists/%s/main/binary-%s/Packages.xz" % (url, self.codename, self.arch)
                c = pycurl.Curl()
                c.setopt(pycurl.URL, test_url)
                c.setopt(pycurl.CONNECTTIMEOUT, 5)
                c.setopt(pycurl.TIMEOUT, 20)
                c.setopt(pycurl.FOLLOWLOCATION, 1)
                c.setopt(pycurl.WRITEFUNCTION, lambda data: None)
                c.setopt(pycurl.NOSIGNAL, 1)
                c.setopt(pycurl.USERAGENT, USER_AGENT)
                c.perform()
                if c.getinfo(pycurl.RESPONSE_CODE) == 200:
                    download_speed = c.getinfo(pycurl.SPEED_DOWNLOAD) # bytes/sec
            else:
                # the mirror is not up to date
                download_speed = -1
        except Exception as error:
            print ("Error '%s' on url %s" % (error, url))
            download_speed = 0

        task.return_value(download_speed)

    def speed_test_finished_cb(self, source, task, iter):
        if not Gio.Task.is_valid(task, source):
            return

        if task.had_error() or task.get_cancellable().is_cancelled():
            return

        # Get speed test result
        download_speed = task.propagate_value().value

        # Add the result to the model
        self.show_speed_test_result(iter, download_speed)

        # Run speed test for the next mirror
        self._create_speed_test_gtask()

    def show_speed_test_result(self, iter, download_speed):
        if (iter is not None): # recheck as it can get null
            if download_speed == -1:
                # don't remove from model as this is not thread-safe
                self._mirrors_model.set_value(iter, MirrorSelectionDialog.MIRROR_SPEED_LABEL_COLUMN, _("Obsolete"))
            elif download_speed == 0:
                # don't remove from model as this is not thread-safe
                self._mirrors_model.set_value(iter, MirrorSelectionDialog.MIRROR_SPEED_LABEL_COLUMN, _("Unreachable"))
            else:
                self._mirrors_model.set_value(iter, MirrorSelectionDialog.MIRROR_SPEED_COLUMN, download_speed)
                self._mirrors_model.set_value(iter, MirrorSelectionDialog.MIRROR_SPEED_LABEL_COLUMN, self._get_speed_label(download_speed))

    def _create_speed_test_gtask(self):
        if not self._mirrors_iters:
            return

        iter = self._mirrors_iters.pop(0)
        self._gtask = Gio.Task.new(self._dialog, Gio.Cancellable(), self.speed_test_finished_cb, iter)
        self._gtask.set_return_on_cancel(True)

        # This must only be set here and read inside the speed test thread
        self.current_speed_test_mirror = self._mirrors_model.get_value(iter, MirrorSelectionDialog.MIRROR_URL_COLUMN)
        self._gtask.run_in_thread(self._speed_test_thread)

    def run(self, mirrors, release):
        self.codename = release.codename
        self.default_mirror = release.mirror

        # Try to find out where we're located...
        self.local_country_code = None
        try:
            lookup = requests.get('https://api.ip2location.io', timeout=10).json()
            cur_country_code = lookup['country_code']
            if cur_country_code != 'None':
                self.local_country_code = cur_country_code
        except Exception as detail:
            print("GeoIP lookup failed!", detail)

        if self.local_country_code is None:
            # fallback to LANG location or 'US'
            print("No GeoIP, falling back to locale.")
            self.local_country_code = os.environ.get('LANG', 'US').split('.')[0].split('_')[-1]

        print("Using country code:", self.local_country_code)

        self.bordering_countries = []
        self.network_neighbors = []
        self.subregion = []
        self.region = []
        self.local_country = self.get_country(self.local_country_code)
        if self.local_country is not None:
            for country in self.countries:
                country_code = country["cca2"]
                if country["region"] == self.local_country["region"]:
                    if country["subregion"] == self.local_country["subregion"]:
                        self.subregion.append(country_code)
                    else:
                        self.region.append(country_code)
                if country["cca3"] in self.local_country["borders"]:
                    self.bordering_countries.append(country_code)
                elif country["cca3"] in self.local_country["networkNeighbors"]:
                    self.network_neighbors.append(country_code)

        self.worldwide_mirrors = []
        self.local_mirrors = []
        self.bordering_mirrors = []
        self.network_neighbors_mirrors = []
        self.subregional_mirrors = []
        self.regional_mirrors = []
        self.official_mirrors = []
        self.other_mirrors = []

        for mirror in mirrors:
            if mirror.country_code == "WD":
                self.worldwide_mirrors.append(mirror)
            elif mirror.country_code == self.local_country_code:
                self.local_mirrors.append(mirror)
            elif mirror.country_code in self.bordering_countries:
                self.bordering_mirrors.append(mirror)
            elif mirror.country_code in self.network_neighbors:
                self.network_neighbors_mirrors.append(mirror)
            elif mirror.country_code in self.subregion:
                self.subregional_mirrors.append(mirror)
            elif mirror.country_code in self.region:
                self.regional_mirrors.append(mirror)
            elif mirror.url == self.default_mirror:
                self.official_mirrors.append(mirror)
            else:
                self.other_mirrors.append(mirror)

        self.worldwide_mirrors = sorted(self.worldwide_mirrors, key=lambda x: x.country_code)
        self.bordering_mirrors = sorted(self.bordering_mirrors, key=lambda x: x.country_code)
        self.network_neighbors_mirrors = sorted(self.network_neighbors_mirrors, key=lambda x: x.country_code)
        self.subregional_mirrors = sorted(self.subregional_mirrors, key=lambda x: x.country_code)
        self.regional_mirrors = sorted(self.regional_mirrors, key=lambda x: x.country_code)

        self.visible_mirrors = self.worldwide_mirrors + self.local_mirrors + self.bordering_mirrors + self.network_neighbors_mirrors + self.subregional_mirrors + self.regional_mirrors + self.official_mirrors

        if len(self.visible_mirrors) < 2:
            # We failed to identify the continent/country, let's show all mirrors
            self.visible_mirrors = mirrors

        # Find the age of the Debian archive, as seen by the default mirror
        self.default_mirror_date = None
        mirror_timestamp = self.get_url_last_modified("%s/project/trace/master" % self.default_mirror)
        if mirror_timestamp is not None:
            self.default_mirror_date = datetime.datetime.fromtimestamp(mirror_timestamp)

        self._update_list()
        self._create_speed_test_gtask()

        self._dialog.show_all()
        retval = self._dialog.run()
        if retval == Gtk.ResponseType.APPLY:
            try:
                model, path = self._treeview.get_selection().get_selected_rows()
                iter = model.get_iter(path[0])
                res = model.get(iter, MirrorSelectionDialog.MIRROR_URL_COLUMN)[0]
            except:
                res = None
        else:
            res = None

        if self._gtask is not None:
            self._gtask.get_cancellable().cancel()
        self._mirrors_iters.clear()
        self._dialog.hide()
        self._mirrors_model.clear()
        return res

class Application(object):
    def __init__(self, release):

        self.release = release

        parser = argparse.ArgumentParser(description="Software sources for Debian")
        parser.add_argument("-n", "--no-update", action="store_true", help="Disable cache refresh prompting")
        args = parser.parse_known_args()

        try:
            known_args = args[0]
            global disable_refresh
            disable_refresh = known_args.no_update
        except (AttributeError, IndexError) as e:
            print(e)

        # Prevent settings from being saved until the interface is fully loaded
        self._interface_loaded = False
        self._currently_applying_sources = False

        self.builder = Gtk.Builder()
        self.builder.set_translation_domain(APP)
        self.builder.add_from_file(os.path.join(LIB_DIR, "menta-sources.ui"))
        self.main_window = self.builder.get_object("main_window")
        self.infobar = self.builder.get_object("infobar")
        self.status_stack = self.builder.get_object("status_stack")

        self.main_window.set_title(_("Software Sources"))
        self.main_window.set_icon_name("menta-sources")

        self.builder.get_object("reload_button").connect("clicked", self.update_cache)
        self.infobar.connect("response", lambda infobar, response: infobar.hide())

        self.builder.get_object("label_release").set_text(self.release.description)

        # Components (main, contrib, non-free...) and suites (security, updates...)
        self.component_checks = {}
        for component in self.release.components:
            description = COMPONENT_DESCRIPTIONS.get(component, component)
            check = Gtk.CheckButton(label="%s (%s)" % (description, component))
            check.connect("toggled", self.apply_official_sources)
            self.builder.get_object("box_components").pack_start(check, False, False, 0)
            self.component_checks[component] = check
        self.builder.get_object("box_components").show_all()

        self.suite_checks = {}
        for suite in self.release.suites:
            description = SUITE_DESCRIPTIONS.get(suite, suite)
            check = Gtk.CheckButton(label="%s (%s)" % (description, self.release.suite_name(suite)))
            check.connect("toggled", self.on_suite_toggled, suite)
            self.builder.get_object("box_suites").pack_start(check, False, False, 0)
            self.suite_checks[suite] = check
        self.builder.get_object("box_suites").show_all()
        self.builder.get_object("box_suites_section").set_visible(len(self.suite_checks) > 0)

        self.mirrors = self.read_mirror_list(self.release.mirrors_file)

        # Add repositories
        self._repository_model = Gtk.ListStore(object, bool, str) # source, selected, name
        self._repository_treeview = self.builder.get_object("treeview_repository")
        self._repository_treeview.set_model(self._repository_model)
        self._repository_treeview.set_headers_clickable(True)
        repo_selection = self._repository_treeview.get_selection()
        repo_selection.set_mode(Gtk.SelectionMode.MULTIPLE)
        repo_selection.connect("changed", self.repo_selected)

        self._repository_model.set_sort_column_id(2, Gtk.SortType.ASCENDING)

        r = Gtk.CellRendererToggle()
        r.connect("toggled", self.repository_toggled)
        col = Gtk.TreeViewColumn(_("Enabled"), r)
        col.set_cell_data_func(r, self.datafunction_checkbox, self._repository_treeview)
        self._repository_treeview.append_column(col)
        col.set_sort_column_id(1)

        r = Gtk.CellRendererText()
        col = Gtk.TreeViewColumn(_("Repository"), r, markup = 2)
        self._repository_treeview.append_column(col)
        col.set_sort_column_id(2)

        self._keys_model = Gtk.ListStore(object, str)
        self._keys_treeview = self.builder.get_object("treeview_keys")
        self._keys_treeview.set_model(self._keys_model)
        self._keys_treeview.set_headers_clickable(True)
        keys_selection = self._keys_treeview.get_selection()
        keys_selection.set_mode(Gtk.SelectionMode.MULTIPLE)
        keys_selection.connect("changed", self.key_selected)

        self._keys_model.set_sort_column_id(1, Gtk.SortType.ASCENDING)

        r = Gtk.CellRendererText()
        col = Gtk.TreeViewColumn(_("Key"), r, markup = 1)
        self._keys_treeview.append_column(col)
        col.set_sort_column_id(1)

        self.system_keys = self.get_system_keys()

        # Move the official repositories to debian.sources if needed and read their settings
        self.settings, self.migrated = debian_repos.prepare(self.release, apt_sources.load_files())
        self.show_official_settings()

        self.read_source_lists()
        self.refresh_repository_model()
        self.load_keys()

        self.builder.get_object("revert_button").connect("clicked", self.revert_to_default_sources)

        self.main_window.connect("delete_event", lambda w,e: Gtk.main_quit())
        self.builder.get_object("close_button").connect("clicked", lambda w: Gtk.main_quit())

        self.mirror_selection_dialog = MirrorSelectionDialog(self, self.builder)

        self.builder.get_object("button_mirror").connect("clicked", self.select_new_mirror)

        self.builder.get_object("button_repository_add").connect("clicked", self.add_repository)
        self.builder.get_object("button_repository_remove").connect("clicked", self.remove_repository)

        self.builder.get_object("button_keys_add").connect("clicked", self.add_key)
        self.builder.get_object("button_keys_fetch").connect("clicked", self.fetch_key)
        self.builder.get_object("button_keys_remove").connect("clicked", self.remove_key)

        self.builder.get_object("button_mergelist").connect("clicked", self.fix_mergelist)
        self.builder.get_object("button_purge").connect("clicked", self.fix_purge)
        self.builder.get_object("button_duplicates").connect("clicked", self.remove_duplicates)
        self.builder.get_object("button_fix_missing_keys").connect("clicked", self.fix_missing_keys)
        self.builder.get_object("button_remove_foreign").connect("clicked", self.remove_foreign)
        self.builder.get_object("button_downgrade_foreign").connect("clicked", self.downgrade_foreign)

        self.builder.get_object("source_code_check").connect("toggled", self.apply_official_sources)
        self.builder.get_object("debug_symbol_check").connect("toggled", self.apply_official_sources)

        # From now on, we handle modifications to the settings and save them when they happen
        self._interface_loaded = True

    def refresh_repository_model(self):
        self._repository_model.clear()
        for source in self.sources:
            self._repository_model.append((source, source.is_enabled(), source.ui_name))

    def read_source_lists(self):
        self.source_files = apt_sources.load_files()
        self.sources = []
        for source_file in self.source_files:
            if source_file.path == debian_repos.OFFICIAL_FILE:
                continue
            for entry in source_file.entries:
                self.sources.append(Source(self, entry))

    def read_mirror_list(self, path):
        mirror_list = []
        country_code = None
        if path and os.path.exists(path):
            with open(path, "r", encoding="utf-8", errors="ignore") as mirrorsfile:
                for line in mirrorsfile.readlines():
                    line = line.strip()
                    if line == "":
                        continue
                    if ("#LOC:" in line):
                        country_code = line.split(":")[1]
                    elif country_code is not None:
                        elements = line.split(" ")
                        url = elements[0].rstrip("/")
                        if len(elements) > 1:
                            name = " ".join(elements[1:])
                        else:
                            name = url
                        mirror_list.append(Mirror(country_code, url, name))
        # The Debian content delivery network, which redirects to a nearby server
        if not any(mirror.url == "https://deb.debian.org/debian" for mirror in mirror_list):
            mirror_list.append(Mirror("WD", "https://deb.debian.org/debian", "https://deb.debian.org/debian/"))
        return mirror_list

    def remove_foreign(self, widget):
        subprocess.Popen([os.path.join(LIB_DIR, "foreign_packages.py"), "remove"])

    def downgrade_foreign(self, widget):
        subprocess.Popen([os.path.join(LIB_DIR, "foreign_packages.py"), "downgrade"])

    def fix_purge(self, widget):
        output = subprocess.run(["dpkg-query", "-W", "-f", "${db:Status-Abbrev} ${binary:Package}\n"],
                                stdout=subprocess.PIPE, text=True).stdout
        packages = [line.split()[1] for line in output.splitlines() if line.startswith("rc")]
        if not packages:
            self.show_confirmation_dialog(_("There is no residual configuration on the system."), affirmation=True)
            return
        if not self.show_confirmation_dialog(_("The configuration files of the following packages will be deleted:") + "\n\n" + ", ".join(packages), yes_no=True):
            return
        self.set_busy(True)
        result = subprocess.run(["dpkg", "--purge"] + packages, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.set_busy(False)
        if result.returncode == 0:
            self.show_confirmation_dialog(_("There is no more residual configuration on the system."), affirmation=True)
        else:
            self.show_error_dialog(result.stdout.strip()[-2000:])

    def fix_mergelist(self, widget):
        apt_pkg.init_config()
        lists = apt_pkg.config.find_dir("Dir::State::lists")
        for path in glob.glob(os.path.join(lists, "*")):
            if os.path.basename(path) == "lock":
                continue
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path, ignore_errors=True)
            else:
                os.unlink(path)
        os.makedirs(os.path.join(lists, "partial"), exist_ok=True)
        self.show_confirmation_dialog(_("The problem was fixed. Please reload the cache."), affirmation=True)
        self.enable_reload_button()

    def remove_duplicates(self, widget):
        # Keep the official repositories, remove their duplicates elsewhere
        files = apt_sources.load_files()
        files.sort(key=lambda source_file: source_file.path != debian_repos.OFFICIAL_FILE)
        modified = apt_sources.remove_duplicates(files)
        for source_file in modified:
            print("Found duplicates in %s, rewriting it." % source_file.path)
            source_file.save()

        if modified:
            self.show_confirmation_dialog(_("Duplicate entries were removed. Please reload the cache."), affirmation=True)
            self.enable_reload_button()
            self.read_source_lists()
            self.refresh_repository_model()
        else:
            self.show_confirmation_dialog(_("No duplicate entries were found."), affirmation=True)

    def set_busy(self, busy):
        window = self.main_window.get_window()
        if window is not None:
            window.set_cursor(Gdk.Cursor.new_for_display(window.get_display(), Gdk.CursorType.WATCH) if busy else None)
        while Gtk.events_pending():
            Gtk.main_iteration()

    def fix_missing_keys(self, widget):
        #get paths from apt
        apt_pkg.init()
        trusted = apt_pkg.config.find_file("Dir::Etc::trusted")
        trustedparts = apt_pkg.config.find_dir("Dir::Etc::trustedparts")
        lists = apt_pkg.config.find_dir("Dir::State::lists")
        if not os.path.isdir(trustedparts) or not os.path.isdir(lists):
            self.show_confirmation_dialog(_("Error with your APT configuration, you may have to reload the cache first."), affirmation=True)
            return

        self.set_busy(True)

        init_gnupg()

        cmd_stub = ["gpg", "--no-default-keyring", "--no-options"]
        keyrings = [trusted] + glob.glob("%s*.gpg" % trustedparts) + glob.glob("%s*.asc" % trustedparts)
        for keyring in keyrings:
            if not keyring or not os.path.isfile(keyring):
                continue
            cmd_stub.extend(["--keyring", keyring])

        # build repository list
        class RepositoryInfo():
            def __init__(self, path, uri):
                self.path = path
                self.uri = uri
                self.added = False
                self.missing = False

        repositories = []
        tempdir = None
        apt_source_list = apt_pkg.SourceList()
        apt_source_list.read_main_list()
        for metaindex in apt_source_list.list:
            # can't seem to get the metaindex filename from apt_pkg so rebuild it:
            filename = apt_pkg.uri_to_filename("%sdists/%s/" % (metaindex.uri, metaindex.dist))
            path = os.path.join(lists, filename + "InRelease")
            if not os.path.isfile(path):
                path = os.path.join(lists, filename + "Release")
                if not os.path.isfile(path):
                    path = None
            if not path:
                print("W: Release file missing for %s, trying to retrieve" % metaindex.uri)
                try:
                    data = requests.get("%sdists/%s/InRelease" % (metaindex.uri, metaindex.dist), timeout=30)
                    data_gpg = None
                    if not data.ok:
                        data = requests.get("%sdists/%s/Release" % (metaindex.uri, metaindex.dist), timeout=30)
                        data_gpg = requests.get("%sdists/%s/Release.gpg" % (metaindex.uri, metaindex.dist), timeout=30)
                except requests.exceptions.RequestException as e:
                    print("E: %s" % e, file=sys.stderr)
                    continue
                if data.ok and (not data_gpg or data_gpg.ok):
                    if not tempdir:
                        tempdir = tempfile.TemporaryDirectory(prefix="menta-sources-")
                    filename_stub = apt_pkg.uri_to_filename("%sdists/%s/" % (metaindex.uri, metaindex.dist))
                    if data_gpg:
                        path = os.path.join(tempdir.name, filename_stub + "Release")
                        with open(path + ".gpg", "w") as f:
                            f.write(data_gpg.text)
                    else:
                        path = os.path.join(tempdir.name, filename_stub + "InRelease")
                    with open(path, "w") as f:
                        f.write(data.text)
            if path:
                repositories.append(RepositoryInfo(path, metaindex.uri))
            else:
                print("E: Could not retrieve release file for %s" % metaindex.uri, file=sys.stderr)

        r = re.compile(r"^gpg\:\s+using \S+ key (.+)$", re.MULTILINE | re.IGNORECASE)
        # try to verify all repository lists using gpg
        entries = apt_sources.all_entries(apt_sources.load_files())
        for repository in repositories:
            # if the repository is "signed-by", just check that the key file is present
            uri = repository.uri
            key_path = apt_sources.repo_key_path(uri, entries)
            if key_path:
                print(f"{uri} is signed by {key_path}")
                if os.path.exists(key_path):
                    print("  Key found.")
                    continue
                else:
                    print("  Key is missing.")
            if repository.path.endswith("_InRelease"):
                command = cmd_stub + (["--verify", repository.path])
            else:
                command = cmd_stub + (["--verify", repository.path + ".gpg", repository.path])
            result = subprocess.run(command, stderr=subprocess.PIPE, env={"LC_ALL": "C"})
            if result.returncode == 2:
                # missing key
                repository.missing = True
                message = result.stderr.decode()
                try:
                    # parse gpg output for key id or fingerprint
                    key = r.search(message).group(1)
                    key = re.sub(r"\s", "", key)
                    # get key from keyserver
                    success = add_remote_key(key, self.release.keyserver, path=key_path)
                    if not success:
                        raise ValueError("Retrieving key %s failed" % key)
                    repository.added = True
                except (AttributeError, IndexError):
                    print("E: Could not identify the key in the output:\n\n%s" % message, file=sys.stderr)
                    continue
                except ValueError as e:
                    print("E: %s" % str(e), file=sys.stderr)
                    continue

        if tempdir:
            tempdir.cleanup()

        self.set_busy(False)

        keys_added = [x.uri for x in repositories if x.added]
        keys_missing = [x.uri for x in repositories if (x.missing and not x.added)]
        keys_missing_count = len(keys_missing)
        keys_added_count = len(keys_added)
        if keys_missing_count or keys_added_count:
            if not keys_missing_count:
                msg_info = _("All missing keys were successfully added.")
            else:
                msg_info = _("Not all missing keys could be found.")
            msg_log = ""
            if keys_added:
                msg_repos_added = _("Keys were added for the following repositories:")
                repo_list = "\n".join([' - %s' % uri for uri in keys_added])
                msg_log = "%s\n%s\n" % (msg_repos_added, repo_list)
            if keys_missing:
                msg_repos_missing = _("Keys are still missing for the following repositories:")
                msg_action = _("Add the remaining missing key(s) manually or remove the corresponding repositories.")
                repo_list = "\n".join([' - %s' % uri for uri in keys_missing])
                if keys_added:
                    msg_log += "\n"
                msg_log = "%s%s\n%s\n\n%s\n" % (msg_log, msg_repos_missing, repo_list, msg_action)

            msg = "%s\n\n%s" % (msg_info, msg_log)
            if keys_added:
                msg += "\n%s" % _("Please reload the cache.")
                self.load_keys()
                self.enable_reload_button()
            self.show_confirmation_dialog(msg, affirmation=True)
        else:
            self.show_confirmation_dialog(_("No missing keys were found."), affirmation=True)

    def get_system_keys(self):
        """Fingerprints of the Debian archive keys, which can't be removed here."""
        init_gnupg()
        gpg = gnupg.GPG()
        keys = set()
        for path in DEBIAN_KEYRINGS + [self.release.keyring]:
            if os.path.isfile(path):
                try:
                    keys.update(format_fingerprint(key["fingerprint"]) for key in gpg.scan_keys(path))
                except Exception as e:
                    print("W: Could not read keyring %s: %s" % (path, e), file=sys.stderr)
        return keys

    def get_keyrings(self):
        apt_pkg.init_config()
        trustedparts = apt_pkg.config.find_dir("Dir::Etc::trustedparts")
        keyrings = [(path, True, []) for path in sorted(glob.glob("%s*" % trustedparts)) if os.path.isfile(path)]

        signed_by = {}
        for entry in apt_sources.all_entries(apt_sources.load_files()):
            if not entry.enabled or not entry.signed_by:
                continue
            name = Source(self, entry).name
            signed_by.setdefault(entry.signed_by, []).append(name)
        keyrings += [(path, False, signed_by[path]) for path in sorted(signed_by) if os.path.isfile(path)]

        return keyrings

    def load_keys(self):
        init_gnupg()
        gpg = gnupg.GPG()
        self.keys = []
        seen = {}
        for path, removable, sources in self.get_keyrings():
            try:
                scanned_keys = gpg.scan_keys(path)
            except Exception as e:
                print("W: Could not read keyring %s: %s" % (path, e), file=sys.stderr)
                continue
            for scanned_key in scanned_keys:
                pub = format_fingerprint(scanned_key["fingerprint"])
                if pub in self.system_keys:
                    continue
                if pub in seen:
                    if removable and seen[pub].removable:
                        seen[pub].paths.append(path)
                    seen[pub].sources += sources
                    continue
                uid = scanned_key["uids"][0] if scanned_key["uids"] else ""
                key = Key(pub, uid, [path], removable, list(sources))
                seen[pub] = key
                self.keys.append(key)

        self._keys_model.clear()
        for key in self.keys:
            self._keys_model.append((key, key.get_name()))

    def add_key(self, widget):
        dialog = Gtk.FileChooserDialog(title=_("Import Key File"),
                                       transient_for=self.main_window,
                                       action=Gtk.FileChooserAction.OPEN)
        dialog.add_buttons(_("_Cancel"), Gtk.ResponseType.CANCEL,
                           _("_Import"), Gtk.ResponseType.OK)
        dialog.set_default_response(Gtk.ResponseType.OK)

        key_filter = Gtk.FileFilter()
        key_filter.set_name(_("Key files"))
        for pattern in ["*.asc", "*.gpg", "*.key", "*.pgp", "*.pub"]:
            key_filter.add_pattern(pattern)
        for mime_type in ["application/pgp-keys", "application/pgp-encrypted"]:
            key_filter.add_mime_type(mime_type)
        dialog.add_filter(key_filter)

        all_filter = Gtk.FileFilter()
        all_filter.set_name(_("All files"))
        all_filter.add_pattern("*")
        dialog.add_filter(all_filter)

        response = dialog.run()
        filename = dialog.get_filename()
        dialog.destroy()
        if response != Gtk.ResponseType.OK or filename is None:
            return

        try:
            key_path = add_local_key(filename)
        except OSError as e:
            print("E: Could not import %s: %s" % (filename, e), file=sys.stderr)
            key_path = None

        if key_path is None:
            self.show_confirmation_dialog(_("No key could be imported from this file."), affirmation=True)
            return

        self.load_keys()
        self.enable_reload_button()

    def fetch_key(self, widget):
        keyserver = re.sub(r"^\w+://", "", self.release.keyserver).split(":")[0]
        fingerprint = self.show_entry_dialog(_("Please enter the fingerprint of the public key you want to download from %s:") % keyserver, "")
        if fingerprint:
            fingerprint = fingerprint.replace(" ", "")
            self.set_busy(True)
            success = add_remote_key(fingerprint, self.release.keyserver)
            self.set_busy(False)
            if not success:
                self.show_error_dialog(_("The key could not be downloaded."))
                return
            self.load_keys()
            self.enable_reload_button()

    def remove_key(self, widget):
        if (self.show_confirmation_dialog(_("Are you sure you want to permanently remove the selected keys?"), yes_no=True)):
            selection = self._keys_treeview.get_selection()
            (model, indexes) = selection.get_selected_rows()
            iters = []
            for index in indexes:
                iters.append(model.get_iter(index))
            for iter in iters:
                key = model.get(iter, 0)[0]
                if key.removable:
                    key.delete()
            self.load_keys()

    def key_selected(self, selection):
        (model, indexes) = selection.get_selected_rows()
        removable = [index for index in indexes if model.get(model.get_iter(index), 0)[0].removable]
        self.builder.get_object("button_keys_remove").set_sensitive(len(removable) == len(indexes) and len(indexes) >= 1)

    def add_repository(self, widget):
        default_line = "deb http://packages.example.com/debian %s main" % self.release.codename
        start_line = self.get_clipboard_text("deb") or default_line

        line = self.show_entry_dialog(_("Please enter the APT line of the repository you want to add:"), start_line)
        if not line or line == default_line:
            return
        line = apt_sources.expand_http_line(line.strip(), self.release.codename)
        if apt_sources.repo_malformed(line):
            self.show_confirmation_dialog(_("Malformed input, repository not added."), affirmation=True)
            return
        if apt_sources.repo_exists(line, apt_sources.all_entries(apt_sources.load_files())):
            self.show_confirmation_dialog(_("This repository is already configured, you cannot add it a second time."), affirmation=True)
            return

        # Add the repository in sources.list.d
        source_file = apt_sources.SourceFile(apt_sources.ADDITIONAL_REPOSITORIES).load()
        source_file.add_line(line)
        source_file.save()
        self.read_source_lists()
        self.refresh_repository_model()
        self.enable_reload_button()

    def remove_repository(self, widget):
        if (self.show_confirmation_dialog(_("Are you sure you want to permanently remove the selected repositories?"), yes_no=True)):
            selection = self._repository_treeview.get_selection()
            (model, indexes) = selection.get_selected_rows()
            iters = []
            for index in indexes:
                iters.append(model.get_iter(index))
            for iter in iters:
                source = model.get(iter, 0)[0]
                model.remove(iter)
                source.delete()
                self.sources.remove(source)

    def repo_selected(self, selection):
        selection_count = selection.count_selected_rows()
        self.builder.get_object("button_repository_remove").set_sensitive(selection_count >= 1)

    def show_confirmation_dialog(self, message, affirmation=None, yes_no=False):
        buttons = Gtk.ButtonsType.OK_CANCEL
        default_button = Gtk.ResponseType.OK
        confirmation_button = Gtk.ResponseType.OK
        if yes_no:
            buttons = Gtk.ButtonsType.YES_NO
            default_button = Gtk.ResponseType.NO
            confirmation_button = Gtk.ResponseType.YES

        if affirmation is None:
            d = Gtk.MessageDialog(transient_for=self.main_window,
                              message_type=Gtk.MessageType.WARNING if yes_no else Gtk.MessageType.QUESTION,
                              buttons=buttons,
                              text=message,
                              modal=True)
        else:
            d = Gtk.MessageDialog(transient_for=self.main_window,
                              message_type=Gtk.MessageType.INFO,
                              buttons=Gtk.ButtonsType.OK,
                              text=message,
                              modal=True)

        d.set_default_response(default_button)
        r = d.run()
        d.destroy()
        if r == confirmation_button:
            return True
        else:
            return False

    def show_error_dialog(self, message):
        d = Gtk.MessageDialog(transient_for=self.main_window,
                              message_type=Gtk.MessageType.ERROR,
                              buttons=Gtk.ButtonsType.OK,
                              text=str(message),
                              modal=True)
        d.set_default_response(Gtk.ResponseType.OK)
        r = d.run()
        d.destroy()
        if r == Gtk.ResponseType.OK:
            return True
        else:
            return False

    def show_entry_dialog(self, message, default=''):
        d = Gtk.MessageDialog(transient_for=self.main_window,
                              message_type=Gtk.MessageType.QUESTION,
                              buttons=Gtk.ButtonsType.OK_CANCEL,
                              text=message,
                              modal=True)
        entry = Gtk.Entry()
        entry.set_text(default)
        entry.set_margin_start(6)
        entry.set_margin_end(6)
        entry.set_width_chars(60)
        entry.show()
        d.get_message_area().pack_end(entry, False, False, 0)
        entry.connect('activate', lambda _: d.response(Gtk.ResponseType.OK))
        d.set_default_response(Gtk.ResponseType.OK)

        r = d.run()
        text = entry.get_text()
        d.destroy()
        if r == Gtk.ResponseType.OK:
            return text
        else:
            return None

    def datafunction_checkbox(self, column, cell, model, iter, data):
        cell.set_property("activatable", True)
        cell.set_property("active", model.get_value(iter, 0).is_enabled())

    def repository_toggled(self, renderer, path):
        iter = self._repository_model.get_iter(path)
        if iter is not None:
            repository = self._repository_model.get_value(iter, 0)
            repository.switch()
            self._repository_model.set_value(iter, 1, repository.is_enabled())

    def select_new_mirror(self, widget):
        url = self.mirror_selection_dialog.run(self.mirrors, self.release)
        if url is not None and self.settings.mirror != url:
            self.settings.mirror = url
            self.builder.get_object("label_mirror_name").set_text(url)
            self.apply_official_sources()

    def run(self):
        self.main_window.show()
        if self.migrated:
            message = _("The official Debian repositories were moved to %s.") % debian_repos.OFFICIAL_FILE
            message += "\n\n" + _("Backups of the previous configuration:")
            message += "\n" + "\n".join(["%s → %s" % (path, backup) for path, backup in self.migrated])
            self.show_confirmation_dialog(message, affirmation=True)
        Gtk.main()

    def show_official_settings(self):
        self._currently_applying_sources = True
        self.builder.get_object("label_mirror_name").set_text(self.settings.mirror)
        self.builder.get_object("button_mirror").set_tooltip_text(self.settings.mirror)
        for component, check in self.component_checks.items():
            check.set_active(component in self.settings.components or component == "main")
            # Nothing works without main
            check.set_sensitive(component != "main")
        for suite, check in self.suite_checks.items():
            check.set_active(suite in self.settings.suites)
        self.builder.get_object("source_code_check").set_active(self.settings.source_code)
        self.builder.get_object("debug_symbol_check").set_active(self.settings.debug)
        self._currently_applying_sources = False

    def revert_to_default_sources(self, widget):
        self.settings = debian_repos.default_settings(self.release)
        self.show_official_settings()
        self.apply_official_sources()

    def on_suite_toggled(self, widget, suite):
        if self._interface_loaded and not self._currently_applying_sources and widget.get_active() and suite == "experimental":
            if not self.show_confirmation_dialog(_("Experimental contains packages which are under development and may be broken. They are only installed when you explicitly ask for them. Are you sure you want to enable Experimental?"), yes_no=True):
                self._currently_applying_sources = True
                widget.set_active(False)
                self._currently_applying_sources = False
                return
        self.apply_official_sources()

    def enable_reload_button(self):
        if disable_refresh:
            global sources_changed
            sources_changed = True
            return
        self.infobar.set_message_type(Gtk.MessageType.INFO)
        self.infobar.set_show_close_button(False)
        self.builder.get_object("reload_button").show()
        self.status_stack.set_visible_child_name("page_update")
        self.infobar.show()

    def update_cache(self, widget):
        self.status_stack.set_visible_child_name("page_progress")
        self.builder.get_object("reload_button").hide()
        self.builder.get_object("notebook").set_sensitive(False)
        self.builder.get_object("progressbar").set_fraction(0.0)
        AptCommand(["update"], self.on_cache_update_progress, self.on_cache_update_finished).run()

    def on_cache_update_progress(self, percent, description):
        self.builder.get_object("progressbar").set_fraction(min(percent, 100) / 100.0)
        self.builder.get_object("label_progress").set_text(description)

    def on_cache_update_finished(self, success, errors):
        self.builder.get_object("notebook").set_sensitive(True)
        self.builder.get_object("progressbar").set_fraction(0.0)
        if success:
            self.infobar.hide()
        else:
            self.infobar.set_message_type(Gtk.MessageType.ERROR)
            self.infobar.set_show_close_button(True)
            self.builder.get_object("error_label").set_text("\n".join(errors))
            self.status_stack.set_visible_child_name("page_error")
            self.builder.get_object("reload_button").show()

    def apply_official_sources(self, widget=None):
        # As long as the interface isn't fully loaded, don't save anything
        if not self._interface_loaded:
            return

        if self._currently_applying_sources:
            return

        # Keep components we don't know about
        unknown_components = [c for c in self.settings.components if c not in self.component_checks]
        self.settings.components = [c for c, check in self.component_checks.items() if check.get_active()]
        self.settings.components += unknown_components
        self.settings.suites = [s for s, check in self.suite_checks.items() if check.get_active()]
        self.settings.source_code = self.builder.get_object("source_code_check").get_active()
        self.settings.debug = self.builder.get_object("debug_symbol_check").get_active()
        self.builder.get_object("button_mirror").set_tooltip_text(self.settings.mirror)

        debian_repos.write(self.release, self.settings)
        self.enable_reload_button()

    def get_clipboard_text(self, source_type):
        clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        text = clipboard.wait_for_text()
        if text is not None and text.strip().startswith(source_type):
            return text.strip()
        else:
            return None

def load_release():
    entries = apt_sources.all_entries(apt_sources.load_files())
    codename = debian_repos.detect_codename(entries)
    try:
        return debian_repos.load_release(codename)
    except (OSError, configparser.Error) as e:
        print ("OS codename: '%s'." % codename)
        print ("This codename isn't currently supported: %s" % e)
        print ("Please check your OS release information with \"cat /etc/os-release\" (identified as VERSION_CODENAME).")
        sys.exit(1)

if __name__ == "__main__":
    Application(load_release()).run()

    exit(1 if sources_changed else 0)
