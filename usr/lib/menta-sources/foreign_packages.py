#!/usr/bin/python3
import gettext
import os
import subprocess
import sys
import threading
import locale

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib

import apt

from apt_runner import AptCommand

LIB_DIR = os.path.dirname(os.path.abspath(__file__))

# i18n
APP = 'menta-sources'
LOCALE_DIR = "/usr/share/locale"
locale.bindtextdomain(APP, LOCALE_DIR)
gettext.bindtextdomain(APP, LOCALE_DIR)
gettext.textdomain(APP)
_ = gettext.gettext

# Origins whose packages are considered official
OFFICIAL_ORIGINS = ("debian", "debian backports")

(PKG_ID, PKG_CHECKED, PKG_NAME, PKG_INSTALLED_VERSION, PKG_REPO_VERSION, PKG_SORT_NAME) = range(6)

# Used as a decorator to run things in the background
def run_async(func):
    def wrapper(*args, **kwargs):
        thread = threading.Thread(target=func, args=args, kwargs=kwargs)
        thread.daemon = True
        thread.start()
        return thread
    return wrapper

# Used as a decorator to run things in the main loop, from another thread
def idle(func):
    def wrapper(*args):
        GLib.idle_add(func, *args)
    return wrapper

# Returns a tuple containing two lists
# The first list is a list of orphaned packages (packages which have no origin)
# The second list is a list of packages which version is not the official version (this does not
# include packages which simply aren't up to date)
def get_foreign_packages(find_orphans=True, find_downgradable_packages=True):
    orphan_packages = []
    downgradable_packages = []

    cache = apt.Cache()

    for key in cache.keys():
        pkg = cache[key]
        if (pkg.is_installed):
            installed_version = pkg.installed.version

            # Find packages which aren't downloadable
            if (pkg.candidate is None) or (not pkg.candidate.downloadable):
                if find_orphans:
                    downloadable = False
                    for version in pkg.versions:
                        if version.downloadable:
                            downloadable = True
                    if not downloadable:
                        orphan_packages.append([pkg, installed_version])
            # Versions installed from Debian (backports for instance) aren't foreign
            installed_from_debian = pkg.installed.downloadable and any(
                origin.origin is not None and origin.origin.lower() in OFFICIAL_ORIGINS
                for origin in pkg.installed.origins)
            if pkg.candidate is not None and not installed_from_debian:
                if find_downgradable_packages:
                    best_version = None
                    archive = None
                    for version in pkg.versions:
                        if not version.downloadable:
                            continue
                        for origin in version.origins:
                            if origin.origin is not None and origin.origin.lower() in OFFICIAL_ORIGINS:
                                if best_version is None:
                                    best_version = version
                                    archive = origin.archive
                                else:
                                    if version.policy_priority > best_version.policy_priority:
                                        best_version = version
                                        archive = origin.archive
                                    elif version.policy_priority == best_version.policy_priority:
                                        # same priorities, compare version
                                        return_code = subprocess.call(["dpkg", "--compare-versions", version.version, "gt", best_version.version])
                                        if return_code == 0:
                                            best_version = version
                                            archive = origin.archive

                    if best_version is not None and installed_version != best_version.version and pkg.candidate.version != best_version.version:
                        downgradable_packages.append([pkg, installed_version, best_version, archive])

    return (orphan_packages, downgradable_packages)

def preview_changes(package_ids, downgrade):
    """Lists what apt will do: returns (removals, other changes) as lists of strings."""
    cache = apt.Cache()
    with cache.actiongroup():
        for package_id in package_ids:
            if downgrade:
                name, version = package_id.split("=", 1)
                pkg = cache[name]
                pkg.candidate = pkg.versions[version]
                pkg.mark_install(from_user=False)
            else:
                cache[package_id].mark_delete()
    removals = []
    changes = []
    for pkg in cache.get_changes():
        if pkg.marked_delete:
            removals.append(pkg.name)
        elif pkg.marked_downgrade:
            changes.append("%s (%s → %s)" % (pkg.name, pkg.installed.version, pkg.candidate.version))
        elif pkg.marked_install or pkg.marked_upgrade:
            changes.append("%s (%s)" % (pkg.name, pkg.candidate.version))
    if cache.broken_count > 0:
        raise SystemError(_("These changes would leave broken packages on the system."))
    return (sorted(removals), sorted(changes))

class Foreign_Browser():

    def __init__(self):

        self.downgrade_mode = (sys.argv[1] == "downgrade") # whether to downgrade or remove packages
        self.transaction_running = False

        self.builder = Gtk.Builder()
        self.builder.set_translation_domain(APP)
        self.builder.add_from_file(os.path.join(LIB_DIR, "menta-sources.ui"))

        self.window = self.builder.get_object("foreign_window")
        self.window.set_title(_("Foreign Packages"))
        self.window.set_icon_name("menta-sources")
        self.window.connect("destroy", Gtk.main_quit)
        self.window.connect("delete-event", lambda w, e: self.transaction_running)
        self.builder.get_object("button_foreign_cancel").connect("clicked", Gtk.main_quit)
        self.action_button = self.builder.get_object("button_foreign_action")
        self.action_button.connect("clicked", self.install)
        if self.downgrade_mode:
            self.action_button.set_label(_("_Downgrade"))
            self.builder.get_object("label_foreign_explanation").set_text(_("The version of the following packages doesn't match the one provided by Debian:"))
        else:
            self.action_button.set_label(_("_Remove"))
            self.builder.get_object("label_foreign_explanation").set_text(_("The packages below are installed on your computer but not present in the repositories:"))
        self.action_button.set_sensitive(False)

        self.select_button = self.builder.get_object("button_foreign_select")
        self.select_button.connect("clicked", self.select_all)
        self.select_button_selects_all = True

        self.model = Gtk.ListStore(str, bool, str, str, str, str)
        # PKG_ID, PKG_CHECKED, PKG_NAME, PKG_INSTALLED_VERSION, PKG_REPO_VERSION, PKG_SORT_NAME

        treeview = self.builder.get_object("treeview_foreign_pkgs")
        treeview.set_model(self.model)
        self.model.set_sort_column_id(PKG_SORT_NAME, Gtk.SortType.ASCENDING)

        cr = Gtk.CellRendererToggle()
        cr.connect("toggled", self.toggled)
        col = Gtk.TreeViewColumn("", cr)
        col.set_cell_data_func(cr, self.datafunction_checkbox)
        treeview.append_column(col)
        col.set_sort_column_id(PKG_CHECKED)

        r = Gtk.CellRendererText()
        col = Gtk.TreeViewColumn(_("Package"), r, markup = PKG_NAME)
        treeview.append_column(col)
        col.set_sort_column_id(PKG_NAME)

        r = Gtk.CellRendererText()
        col = Gtk.TreeViewColumn(_("Installed version"), r, text = PKG_INSTALLED_VERSION)
        treeview.append_column(col)
        col.set_sort_column_id(PKG_INSTALLED_VERSION)

        if self.downgrade_mode:
            r = Gtk.CellRendererText()
            col = Gtk.TreeViewColumn(_("Repository version"), r, text = PKG_REPO_VERSION)
            treeview.append_column(col)
            col.set_sort_column_id(PKG_REPO_VERSION)

        treeview.connect("row-activated", self.treeview_row_activated)
        self.window.show_all()
        self.load_foreign_packages()

    def show_spinner(self):
        self.builder.get_object("stack1").set_visible_child_name("spin_page")
        self.builder.get_object("spinner").set_size_request(32, 32)
        self.builder.get_object("spinner").start()

    def load_foreign_packages(self):
        self.show_spinner()
        self._load_foreign_packages()

    @run_async
    def _load_foreign_packages(self):
        if self.downgrade_mode:
            (orphans, foreigns) = get_foreign_packages(find_orphans=False, find_downgradable_packages=True)
        else:
            (orphans, foreigns) = get_foreign_packages(find_orphans=True, find_downgradable_packages=False)
        self.update_ui(orphans, foreigns)

    @idle
    def update_ui(self, orphans, foreigns):
        self.model.clear()
        if self.downgrade_mode:
            # downgrade mode
            # Find packages which candidate isn't available
            for foreign in foreigns:
                (pkg, installed_version, best_version, archive) = foreign
                iter = self.model.insert_before(None, None)
                self.model.set_value(iter, PKG_ID, "%s=%s" % (pkg.name, best_version.version))
                self.model.set_value(iter, PKG_CHECKED, False)
                self.model.set_value(iter, PKG_NAME, "<b>%s</b>" % GLib.markup_escape_text(pkg.name))
                self.model.set_value(iter, PKG_INSTALLED_VERSION, installed_version)
                self.model.set_value(iter, PKG_REPO_VERSION, "%s (%s)" % (best_version.version, archive))
                self.model.set_value(iter, PKG_SORT_NAME, "%s %s" % (best_version.source_name, pkg.name))
        else:
            # remove mode
            # Find packages which aren't downloadable
            for orphan in orphans:
                (pkg, installed_version) = orphan
                iter = self.model.insert_before(None, None)
                self.model.set_value(iter, PKG_ID, "%s" % (pkg.name))
                self.model.set_value(iter, PKG_CHECKED, False)
                self.model.set_value(iter, PKG_NAME, "<b>%s</b>" % GLib.markup_escape_text(pkg.name))
                self.model.set_value(iter, PKG_INSTALLED_VERSION, installed_version)
                self.model.set_value(iter, PKG_REPO_VERSION, "")
                self.model.set_value(iter, PKG_SORT_NAME, "%s" % (pkg.name))

        self.builder.get_object("spinner").stop()
        self.builder.get_object("stack1").set_visible_child_name("main_page")
        self.select_button_selects_all = True
        self.select_button.set_label(_("Select _All"))
        self.update_action_button()

    def datafunction_checkbox(self, column, cell, model, iter, data):
        cell.set_property("activatable", True)
        cell.set_property("active", model.get_value(iter, PKG_CHECKED))

    def treeview_row_activated(self, treeview, path, view_column):
        self.toggled(None, path)

    def get_selected(self):
        return [row[PKG_ID] for row in self.model if row[PKG_CHECKED]]

    def update_action_button(self):
        self.action_button.set_sensitive(len(self.get_selected()) > 0)

    def toggled(self, renderer, path):
        iter = self.model.get_iter(path)
        if iter is not None:
            checked = self.model.get_value(iter, PKG_CHECKED)
            self.model.set_value(iter, PKG_CHECKED, not(checked))
        self.update_action_button()

    def confirm(self, removals, changes):
        dialog = Gtk.MessageDialog(transient_for=self.window, modal=True,
                                   message_type=Gtk.MessageType.WARNING,
                                   buttons=Gtk.ButtonsType.NONE,
                                   text=_("Review the changes below carefully before applying them."))
        dialog.add_buttons(_("_Cancel"), Gtk.ResponseType.CANCEL,
                           _("_Apply"), Gtk.ResponseType.OK)
        dialog.set_default_response(Gtk.ResponseType.CANCEL)
        lines = []
        if removals:
            lines += [_("The following packages will be removed:")] + ["    %s" % name for name in removals] + [""]
        if changes:
            lines += [_("The following packages will be installed or downgraded:")] + ["    %s" % name for name in changes]
        buffer = Gtk.TextBuffer()
        buffer.set_text("\n".join(lines).strip())
        textview = Gtk.TextView(buffer=buffer, editable=False, cursor_visible=False, monospace=True)
        scrolled = Gtk.ScrolledWindow(shadow_type=Gtk.ShadowType.IN)
        scrolled.set_size_request(480, 240)
        scrolled.add(textview)
        scrolled.show_all()
        dialog.get_message_area().pack_end(scrolled, True, True, 0)
        response = dialog.run()
        dialog.destroy()
        return response == Gtk.ResponseType.OK

    def show_error(self, title, details):
        dialog = Gtk.MessageDialog(transient_for=self.window, modal=True,
                                   message_type=Gtk.MessageType.ERROR,
                                   buttons=Gtk.ButtonsType.OK,
                                   text=title)
        dialog.format_secondary_text(details)
        dialog.run()
        dialog.destroy()

    def install(self, button):
        if self.transaction_running:
            return
        foreign_packages = self.get_selected()
        try:
            (removals, changes) = preview_changes(foreign_packages, self.downgrade_mode)
        except (SystemError, KeyError) as e:
            self.show_error(_("The selected packages can't be processed."), str(e))
            return
        if not self.confirm(removals, changes):
            return

        self.transaction_running = True
        self.builder.get_object("label_foreign_progress").set_text("")
        self.builder.get_object("progressbar_foreign").set_fraction(0)
        self.builder.get_object("stack1").set_visible_child_name("progress_page")
        if self.downgrade_mode:
            args = ["install", "--allow-downgrades"] + foreign_packages
        else:
            args = ["remove"] + foreign_packages
        AptCommand(args, self.on_progress, self.on_finished).run()

    def on_progress(self, percent, description):
        self.builder.get_object("progressbar_foreign").set_fraction(min(percent, 100) / 100.0)
        self.builder.get_object("label_foreign_progress").set_text(description)

    def on_finished(self, success, errors):
        self.transaction_running = False
        if not success:
            self.show_error(_("An error occurred while applying the changes."), "\n".join(errors))
        self.load_foreign_packages()

    def select_all (self, button):
        for row in self.model:
            row[PKG_CHECKED] = self.select_button_selects_all
        self.select_button_selects_all = not (self.select_button_selects_all)
        if self.select_button_selects_all:
            self.select_button.set_label(_("Select _All"))
        else:
            self.select_button.set_label(_("C_lear"))
        self.update_action_button()

if __name__ == "__main__":
    foreign_browser = Foreign_Browser()
    Gtk.main()
