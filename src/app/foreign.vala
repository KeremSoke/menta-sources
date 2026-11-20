namespace Menta {
    public const string[] OFFICIAL_ORIGINS = { "debian", "debian backports" };

    public class PackageOrigin : Object {
        public string origin = "";
        public string archive = "";
    }

    public class PackageVersion : Object {
        public string version;
        public int priority;
        public Gee.ArrayList<string> sources = new Gee.ArrayList<string> ();

        public PackageVersion (string version, int priority) {
            this.version = version;
            this.priority = priority;
        }

        public bool downloadable {
            get {
                foreach (var source in sources) {
                    if (source != "/var/lib/dpkg/status") {
                        return true;
                    }
                }
                return false;
            }
        }
    }

    public class InstalledPackage : Object {
        public string name;
        public string installed_version;
        public string source_name;
        public string? candidate = null;
        public Gee.ArrayList<PackageVersion> versions = new Gee.ArrayList<PackageVersion> ();

        public InstalledPackage (string name, string installed_version, string source_name) {
            this.name = name;
            this.installed_version = installed_version;
            this.source_name = source_name;
        }

        public PackageVersion? find (string? version) {
            if (version == null) {
                return null;
            }
            foreach (var item in versions) {
                if (item.version == version) {
                    return item;
                }
            }
            return null;
        }
    }

    public class ForeignPackage : Object {
        public string id;
        public string name;
        public string installed_version;
        public string repo_version;
        public string sort_name;

        public ForeignPackage (string id, string name, string installed_version, string repo_version, string sort_name) {
            this.id = id;
            this.name = name;
            this.installed_version = installed_version;
            this.repo_version = repo_version;
            this.sort_name = sort_name;
        }
    }

    namespace PackageScan {
        private string run_command (string[] argv, out int status) {
            status = 1;
            try {
                var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
                launcher.setenv ("LC_ALL", "C", true);
                var process = launcher.spawnv (argv);
                Bytes output;
                Bytes errors;
                process.communicate (null, null, out output, out errors);
                status = process.get_if_exited () ? process.get_exit_status () : 1;
                return bytes_to_string (output) + (status != 0 ? bytes_to_string (errors) : "");
            } catch (Error e) {
                return e.message;
            }
        }

        public Gee.HashMap<string, PackageOrigin> package_files () {
            var result = new Gee.HashMap<string, PackageOrigin> ();
            int status;
            var output = run_command ({ "apt-cache", "policy" }, out status);
            string? current = null;
            foreach (var line in output.split ("\n")) {
                if (line.has_prefix ("Pinned packages:")) {
                    break;
                }
                MatchInfo match;
                if (Regex.match_simple ("^ *-?\\d+ ", line)) {
                    try {
                        if (new Regex ("^ *(-?\\d+) (.+)$").match (line, 0, out match)) {
                            current = match.fetch (2).strip ();
                            result.set (current, new PackageOrigin ());
                        }
                    } catch (RegexError e) {
                    }
                    continue;
                }
                var trimmed = line.strip ();
                if (current != null && trimmed.has_prefix ("release ")) {
                    var origin = result.get (current);
                    foreach (var field in trimmed.substring (8).split (",")) {
                        var position = field.index_of ("=");
                        if (position < 0) {
                            continue;
                        }
                        var key = field.substring (0, position);
                        var value = field.substring (position + 1);
                        if (key == "o") {
                            origin.origin = value;
                        } else if (key == "a") {
                            origin.archive = value;
                        }
                    }
                }
            }
            return result;
        }

        public Gee.ArrayList<InstalledPackage> installed_packages (string native_arch) throws Error {
            var packages = new Gee.ArrayList<InstalledPackage> ();
            int status;
            var output = run_command ({ "dpkg-query", "-W", "-f", "${db:Status-Abbrev}\t${binary:Package}\t${Version}\t${source:Package}\n" }, out status);
            if (status != 0) {
                throw new IOError.FAILED ("%s", output.strip ());
            }
            foreach (var line in output.split ("\n")) {
                var fields = line.split ("\t");
                if (fields.length < 4 || fields[0].length < 2) {
                    continue;
                }
                var state = fields[0][1];
                if (state == 'n' || state == 'c' || fields[2] == "") {
                    continue;
                }
                var name = fields[1];
                if (name.has_suffix (":" + native_arch)) {
                    name = name.substring (0, name.length - native_arch.length - 1);
                }
                packages.add (new InstalledPackage (name, fields[2], fields[3] != "" ? fields[3] : name));
            }
            return packages;
        }

        public void read_policy (Gee.List<InstalledPackage> packages, string native_arch) {
            var by_name = new Gee.HashMap<string, InstalledPackage> ();
            foreach (var package in packages) {
                by_name.set (package.name, package);
            }
            Regex header;
            Regex version_line;
            Regex source_line;
            try {
                header = new Regex ("^(\\S+):$");
                version_line = new Regex ("^ (\\*\\*\\*| {3}) (\\S+) (-?\\d+)$");
                source_line = new Regex ("^ {7,}(-?\\d+) (.+)$");
            } catch (RegexError e) {
                return;
            }
            const int BATCH = 400;
            for (int start = 0; start < packages.size; start += BATCH) {
                string[] argv = { "apt-cache", "policy" };
                for (int i = start; i < int.min (start + BATCH, packages.size); i++) {
                    argv += packages[i].name;
                }
                int status;
                var output = run_command (argv, out status);
                InstalledPackage? current = null;
                PackageVersion? version = null;
                foreach (var line in output.split ("\n")) {
                    MatchInfo match;
                    if (header.match (line, 0, out match)) {
                        var name = match.fetch (1);
                        current = by_name.get (name);
                        if (current == null && name.has_suffix (":" + native_arch)) {
                            current = by_name.get (name.substring (0, name.length - native_arch.length - 1));
                        }
                        if (current == null && !(":" in name)) {
                            current = by_name.get (name + ":" + native_arch);
                        }
                        version = null;
                        continue;
                    }
                    if (current == null) {
                        continue;
                    }
                    var trimmed = line.strip ();
                    if (trimmed.has_prefix ("Candidate:")) {
                        var candidate = trimmed.substring (10).strip ();
                        current.candidate = candidate == "(none)" ? null : candidate;
                        continue;
                    }
                    if (version_line.match (line, 0, out match)) {
                        version = new PackageVersion (match.fetch (2), int.parse (match.fetch (3)));
                        current.versions.add (version);
                        continue;
                    }
                    if (version != null && source_line.match (line, 0, out match)) {
                        version.sources.add (match.fetch (2).strip ());
                    }
                }
            }
        }

        private Gee.ArrayList<PackageOrigin> origins (PackageVersion version, Gee.Map<string, PackageOrigin> files) {
            var result = new Gee.ArrayList<PackageOrigin> ();
            foreach (var source in version.sources) {
                var origin = files.get (source);
                if (origin != null) {
                    result.add (origin);
                }
            }
            return result;
        }

        private bool official (PackageOrigin origin) {
            return origin.origin != "" && AptSources.contains (OFFICIAL_ORIGINS, origin.origin.down ());
        }

        private Gee.HashMap<string, string> source_names (Gee.List<string> specs, string native_arch) {
            var result = new Gee.HashMap<string, string> ();
            const int BATCH = 400;
            for (int start = 0; start < specs.size; start += BATCH) {
                string[] argv = { "apt-cache", "show", "--no-all-versions" };
                for (int i = start; i < int.min (start + BATCH, specs.size); i++) {
                    argv += specs[i];
                }
                int status;
                var output = run_command (argv, out status);
                foreach (var stanza in output.split ("\n\n")) {
                    string package = "";
                    string version = "";
                    string arch = "";
                    string source = "";
                    foreach (var line in stanza.split ("\n")) {
                        if (line.has_prefix ("Package:")) {
                            package = line.substring (8).strip ();
                        } else if (line.has_prefix ("Version:")) {
                            version = line.substring (8).strip ();
                        } else if (line.has_prefix ("Architecture:")) {
                            arch = line.substring (13).strip ();
                        } else if (line.has_prefix ("Source:")) {
                            var words = AptSources.split_words (line.substring (7));
                            source = words.length > 0 ? words[0] : "";
                        }
                    }
                    if (package == "" || version == "") {
                        continue;
                    }
                    var name = (arch == "" || arch == "all" || arch == native_arch) ? package : "%s:%s".printf (package, arch);
                    result.set ("%s=%s".printf (name, version), source != "" ? source : package);
                }
            }
            return result;
        }

        public Gee.ArrayList<ForeignPackage> scan (bool downgrade_mode) throws Error {
            var result = new Gee.ArrayList<ForeignPackage> ();
            string native_arch = "amd64";
            int status;
            var arch_output = run_command ({ "dpkg", "--print-architecture" }, out status).strip ();
            if (status == 0 && arch_output != "") {
                native_arch = arch_output;
            }
            var files = package_files ();
            var packages = installed_packages (native_arch);
            read_policy (packages, native_arch);
            foreach (var package in packages) {
                var installed = package.find (package.installed_version);
                var candidate = package.find (package.candidate);
                if (!downgrade_mode) {
                    if (candidate == null || !candidate.downloadable) {
                        bool downloadable = false;
                        foreach (var version in package.versions) {
                            if (version.downloadable) {
                                downloadable = true;
                            }
                        }
                        if (!downloadable) {
                            result.add (new ForeignPackage (package.name, package.name, package.installed_version, "", package.name));
                        }
                    }
                    continue;
                }
                bool installed_from_debian = false;
                if (installed != null && installed.downloadable) {
                    foreach (var origin in origins (installed, files)) {
                        if (official (origin)) {
                            installed_from_debian = true;
                        }
                    }
                }
                if (candidate == null || installed_from_debian) {
                    continue;
                }
                PackageVersion? best = null;
                string archive = "";
                foreach (var version in package.versions) {
                    if (!version.downloadable) {
                        continue;
                    }
                    foreach (var origin in origins (version, files)) {
                        if (!official (origin)) {
                            continue;
                        }
                        if (best == null
                            || version.priority > best.priority
                            || (version.priority == best.priority && DebVersion.compare (version.version, best.version) > 0)) {
                            best = version;
                            archive = origin.archive;
                        }
                    }
                }
                if (best != null && package.installed_version != best.version && candidate.version != best.version) {
                    result.add (new ForeignPackage ("%s=%s".printf (package.name, best.version),
                                                    package.name,
                                                    package.installed_version,
                                                    "%s (%s)".printf (best.version, archive),
                                                    package.source_name));
                }
            }
            if (downgrade_mode && result.size > 0) {
                var specs = new Gee.ArrayList<string> ();
                foreach (var item in result) {
                    specs.add (item.id);
                }
                var sources = source_names (specs, native_arch);
                foreach (var item in result) {
                    var source = sources.get (item.id) ?? item.sort_name;
                    item.sort_name = "%s %s".printf (source, item.name);
                }
            }
            return result;
        }

        public void preview (string[] ids, bool downgrade, out Gee.ArrayList<string> removals, out Gee.ArrayList<string> changes) throws Error {
            removals = new Gee.ArrayList<string> ();
            changes = new Gee.ArrayList<string> ();
            string[] argv = { "apt-get", "--simulate", "--quiet", "-o", "Debug::NoLocking=true" };
            if (downgrade) {
                argv += "install";
                argv += "--allow-downgrades";
            } else {
                argv += "remove";
            }
            foreach (var id in ids) {
                argv += id;
            }
            int status;
            var output = run_command (argv, out status);
            if (status != 0) {
                string[] errors = {};
                bool keep = false;
                foreach (var line in output.split ("\n")) {
                    if (line.has_prefix ("E:") || line.has_prefix ("The following packages have unmet dependencies")) {
                        keep = true;
                        errors += line;
                    } else if (keep && (line.has_prefix (" ") || line.has_prefix ("\t")) && line.strip () != "") {
                        errors += line;
                    } else {
                        keep = false;
                    }
                }
                throw new IOError.FAILED ("%s", errors.length > 0 ? string.joinv ("\n", errors) : output.strip ());
            }
            var inst = new Regex ("^Inst (\\S+)(?: \\[(\\S+)\\])? \\((\\S+)");
            var remv = new Regex ("^Remv (\\S+)");
            foreach (var line in output.split ("\n")) {
                MatchInfo match;
                if (remv.match (line, 0, out match)) {
                    removals.add (match.fetch (1));
                } else if (inst.match (line, 0, out match)) {
                    var name = match.fetch (1);
                    var old_version = match.fetch (2);
                    var new_version = match.fetch (3);
                    if (old_version != null && old_version != "" && DebVersion.compare (new_version, old_version) < 0) {
                        changes.add ("%s (%s → %s)".printf (name, old_version, new_version));
                    } else {
                        changes.add ("%s (%s)".printf (name, new_version));
                    }
                }
            }
            removals.sort ((a, b) => strcmp (a, b));
            changes.sort ((a, b) => strcmp (a, b));
        }
    }

    public class ForeignWindow : Object {
        private enum Column {
            ID,
            CHECKED,
            NAME,
            INSTALLED_VERSION,
            REPO_VERSION,
            SORT_NAME
        }

        public signal void closed ();

        private Gtk.Builder builder;
        public Gtk.Window window;
        private Gtk.ListStore model;
        private Gtk.Button action_button;
        private Gtk.Button select_button;
        private bool select_all_next = true;
        private bool downgrade_mode;
        private bool transaction_running = false;
        private Privileged privileged;

        public ForeignWindow (bool downgrade_mode, Privileged privileged) {
            this.downgrade_mode = downgrade_mode;
            this.privileged = privileged;
            builder = new Gtk.Builder ();
            builder.set_translation_domain (Config.GETTEXT_PACKAGE);
            try {
                builder.add_objects_from_resource ("/org/menta/menta-sources/ui/menta-sources.ui", { "foreign_window" });
            } catch (Error e) {
                error ("%s", e.message);
            }
            window = (Gtk.Window) builder.get_object ("foreign_window");
            window.set_title (_("Foreign Packages"));
            window.set_icon_name ("menta-sources");
            window.delete_event.connect (() => transaction_running);
            window.destroy.connect (() => closed ());
            ((Gtk.Button) builder.get_object ("button_foreign_cancel")).clicked.connect (() => {
                if (!transaction_running) {
                    window.destroy ();
                }
            });
            action_button = (Gtk.Button) builder.get_object ("button_foreign_action");
            action_button.clicked.connect (install);
            var explanation = (Gtk.Label) builder.get_object ("label_foreign_explanation");
            if (downgrade_mode) {
                action_button.set_label (_("_Downgrade"));
                explanation.set_text (_("The version of the following packages doesn't match the one provided by Debian:"));
            } else {
                action_button.set_label (_("_Remove"));
                explanation.set_text (_("The packages below are installed on your computer but not present in the repositories:"));
            }
            action_button.set_sensitive (false);

            select_button = (Gtk.Button) builder.get_object ("button_foreign_select");
            select_button.clicked.connect (select_all);

            model = new Gtk.ListStore (6, typeof (string), typeof (bool), typeof (string), typeof (string), typeof (string), typeof (string));
            var treeview = (Gtk.TreeView) builder.get_object ("treeview_foreign_pkgs");
            treeview.set_model (model);
            model.set_sort_column_id (Column.SORT_NAME, Gtk.SortType.ASCENDING);

            var toggle = new Gtk.CellRendererToggle ();
            toggle.activatable = true;
            toggle.toggled.connect ((path) => toggled (new Gtk.TreePath.from_string (path)));
            var column = new Gtk.TreeViewColumn.with_attributes ("", toggle, "active", Column.CHECKED);
            column.set_sort_column_id (Column.CHECKED);
            treeview.append_column (column);

            column = new Gtk.TreeViewColumn.with_attributes (_("Package"), new Gtk.CellRendererText (), "markup", Column.NAME);
            column.set_sort_column_id (Column.NAME);
            treeview.append_column (column);

            column = new Gtk.TreeViewColumn.with_attributes (_("Installed version"), new Gtk.CellRendererText (), "text", Column.INSTALLED_VERSION);
            column.set_sort_column_id (Column.INSTALLED_VERSION);
            treeview.append_column (column);

            if (downgrade_mode) {
                column = new Gtk.TreeViewColumn.with_attributes (_("Repository version"), new Gtk.CellRendererText (), "text", Column.REPO_VERSION);
                column.set_sort_column_id (Column.REPO_VERSION);
                treeview.append_column (column);
            }

            treeview.row_activated.connect ((path, view_column) => toggled (path));
            window.show_all ();
            load.begin ();
        }

        public void present () {
            window.present ();
        }

        private Gtk.Stack stack () {
            return (Gtk.Stack) builder.get_object ("stack1");
        }

        private async void load () {
            stack ().set_visible_child_name ("spin_page");
            var spinner = (Gtk.Spinner) builder.get_object ("spinner");
            spinner.set_size_request (32, 32);
            spinner.start ();

            Gee.ArrayList<ForeignPackage>? found = null;
            string? failure = null;
            SourceFunc callback = load.callback;
            var mode = downgrade_mode;
            new Thread<void*> ("foreign-packages", () => {
                try {
                    found = PackageScan.scan (mode);
                } catch (Error e) {
                    failure = e.message;
                    found = new Gee.ArrayList<ForeignPackage> ();
                }
                Idle.add ((owned) callback);
                return null;
            });
            yield;

            model.clear ();
            foreach (var package in found) {
                Gtk.TreeIter iter;
                model.insert_with_values (out iter, -1,
                    Column.ID, package.id,
                    Column.CHECKED, false,
                    Column.NAME, "<b>%s</b>".printf (Markup.escape_text (package.name)),
                    Column.INSTALLED_VERSION, package.installed_version,
                    Column.REPO_VERSION, package.repo_version,
                    Column.SORT_NAME, package.sort_name);
            }
            spinner.stop ();
            stack ().set_visible_child_name ("main_page");
            if (failure != null) {
                show_error (_("The installed packages could not be read."), failure);
            }
            select_all_next = true;
            select_button.set_label (_("Select _All"));
            update_action_button ();
        }

        private string[] selected () {
            var result = new Gee.ArrayList<string> ();
            model.foreach ((m, path, iter) => {
                bool checked;
                string id;
                m.get (iter, Column.CHECKED, out checked, Column.ID, out id);
                if (checked) {
                    result.add (id);
                }
                return false;
            });
            return result.to_array ();
        }

        private void update_action_button () {
            action_button.set_sensitive (selected ().length > 0);
        }

        private void toggled (Gtk.TreePath path) {
            Gtk.TreeIter iter;
            if (model.get_iter (out iter, path)) {
                bool checked;
                model.get (iter, Column.CHECKED, out checked);
                model.set (iter, Column.CHECKED, !checked);
            }
            update_action_button ();
        }

        private bool confirm (Gee.List<string> removals, Gee.List<string> changes) {
            var dialog = new Gtk.MessageDialog (window, Gtk.DialogFlags.MODAL, Gtk.MessageType.WARNING, Gtk.ButtonsType.NONE, "%s", _("Review the changes below carefully before applying them."));
            dialog.add_button (_("_Cancel"), Gtk.ResponseType.CANCEL);
            dialog.add_button (_("_Apply"), Gtk.ResponseType.OK);
            dialog.set_default_response (Gtk.ResponseType.CANCEL);
            var lines = new Gee.ArrayList<string> ();
            if (removals.size > 0) {
                lines.add (_("The following packages will be removed:"));
                foreach (var name in removals) {
                    lines.add ("    " + name);
                }
                lines.add ("");
            }
            if (changes.size > 0) {
                lines.add (_("The following packages will be installed or downgraded:"));
                foreach (var name in changes) {
                    lines.add ("    " + name);
                }
            }
            var buffer = new Gtk.TextBuffer (null);
            buffer.set_text (string.joinv ("\n", lines.to_array ()).strip ());
            var textview = new Gtk.TextView.with_buffer (buffer);
            textview.editable = false;
            textview.cursor_visible = false;
            textview.monospace = true;
            var scrolled = new Gtk.ScrolledWindow (null, null);
            scrolled.shadow_type = Gtk.ShadowType.IN;
            scrolled.set_size_request (480, 240);
            scrolled.add (textview);
            scrolled.show_all ();
            ((Gtk.Box) dialog.get_message_area ()).pack_end (scrolled, true, true, 0);
            var response = dialog.run ();
            dialog.destroy ();
            return response == Gtk.ResponseType.OK;
        }

        private void show_error (string title, string details) {
            var dialog = new Gtk.MessageDialog (window, Gtk.DialogFlags.MODAL, Gtk.MessageType.ERROR, Gtk.ButtonsType.OK, "%s", title);
            dialog.format_secondary_text ("%s", details);
            dialog.run ();
            dialog.destroy ();
        }

        private void install () {
            if (transaction_running) {
                return;
            }
            var packages = selected ();
            Gee.ArrayList<string> removals;
            Gee.ArrayList<string> changes;
            try {
                PackageScan.preview (packages, downgrade_mode, out removals, out changes);
            } catch (Error e) {
                show_error (_("The selected packages can't be processed."), e.message);
                return;
            }
            if (!confirm (removals, changes)) {
                return;
            }
            transaction_running = true;
            var progress_label = (Gtk.Label) builder.get_object ("label_foreign_progress");
            var progress_bar = (Gtk.ProgressBar) builder.get_object ("progressbar_foreign");
            progress_label.set_text ("");
            progress_bar.set_fraction (0);
            stack ().set_visible_child_name ("progress_page");
            privileged.apt (downgrade_mode ? "downgrade" : "remove", packages,
                (percent, description) => {
                    progress_bar.set_fraction (double.min (percent, 100) / 100.0);
                    progress_label.set_text (description);
                },
                (success, errors) => {
                    transaction_running = false;
                    if (!success) {
                        show_error (_("An error occurred while applying the changes."), string.joinv ("\n", errors));
                    }
                    load.begin ();
                });
        }

        private void select_all () {
            var value = select_all_next;
            model.foreach ((m, path, iter) => {
                ((Gtk.ListStore) m).set (iter, Column.CHECKED, value);
                return false;
            });
            select_all_next = !select_all_next;
            select_button.set_label (select_all_next ? _("Select _All") : _("C_lear"));
            update_action_button ();
        }
    }
}
