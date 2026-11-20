namespace Menta {
    public class CheckItem : Object {
        public string key;
        public Gtk.CheckButton value;

        public CheckItem (string key, Gtk.CheckButton value) {
            this.key = key;
            this.value = value;
        }
    }

    public class CheckList : Object {
        public Gee.ArrayList<CheckItem> entries = new Gee.ArrayList<CheckItem> ();

        public int size {
            get {
                return entries.size;
            }
        }

        public void add (string key, Gtk.CheckButton value) {
            entries.add (new CheckItem (key, value));
        }

        public bool has_key (string key) {
            foreach (var item in entries) {
                if (item.key == key) {
                    return true;
                }
            }
            return false;
        }
    }

    public class Application : Object {
        public bool disable_refresh = false;
        public bool sources_changed = false;

        public DebianRepos.Release release;
        public Gtk.Window main_window;
        private Gtk.Builder builder;
        private Gtk.InfoBar infobar;
        private Gtk.Stack status_stack;
        private Privileged privileged;

        private bool interface_loaded = false;
        private bool currently_applying_sources = false;

        private CheckList component_checks = new CheckList ();
        private CheckList suite_checks = new CheckList ();

        private Gtk.ListStore repository_model;
        private Gtk.TreeView repository_treeview;
        private Gtk.ListStore keys_model;
        private Gtk.TreeView keys_treeview;

        public DebianRepos.Settings settings;
        private Gee.ArrayList<DebianRepos.Migration> migrated = new Gee.ArrayList<DebianRepos.Migration> ();
        private Gee.ArrayList<RepositorySource> sources = new Gee.ArrayList<RepositorySource> ();
        private Gee.ArrayList<AptSources.SourceFile> source_files = new Gee.ArrayList<AptSources.SourceFile> ();
        private Gee.HashSet<string> system_keys = new Gee.HashSet<string> ();
        private Gee.ArrayList<Key> keys = new Gee.ArrayList<Key> ();
        private MirrorDialog mirror_dialog;
        private ForeignWindow? remove_window = null;
        private ForeignWindow? downgrade_window = null;
        private int busy_count = 0;

        private static Gee.HashMap<string, string> component_descriptions () {
            var map = new Gee.HashMap<string, string> ();
            map.set ("main", _("Free software supported by Debian"));
            map.set ("contrib", _("Free software which depends on non-free software"));
            map.set ("non-free", _("Software which doesn't comply with the Debian Free Software Guidelines"));
            map.set ("non-free-firmware", _("Non-free firmware for hardware support"));
            return map;
        }

        private static Gee.HashMap<string, string> suite_descriptions () {
            var map = new Gee.HashMap<string, string> ();
            map.set ("security", _("Important security updates"));
            map.set ("updates", _("Recommended updates"));
            map.set ("backports", _("Newer versions of selected packages (backports)"));
            map.set ("proposed-updates", _("Updates proposed for the next point release"));
            map.set ("experimental", _("Experimental packages"));
            return map;
        }

        private T get_widget<T> (string name) {
            return (T) builder.get_object (name);
        }

        public Application (DebianRepos.Release release, Privileged privileged, bool disable_refresh) throws Error {
            this.release = release;
            this.privileged = privileged;
            this.disable_refresh = disable_refresh;

            builder = new Gtk.Builder ();
            builder.set_translation_domain (Config.GETTEXT_PACKAGE);
            builder.add_objects_from_resource ("/org/menta/menta-sources/ui/menta-sources.ui", { "main_window", "mirror_selection_dialog" });
            main_window = get_widget<Gtk.Window> ("main_window");
            infobar = get_widget<Gtk.InfoBar> ("infobar");
            status_stack = get_widget<Gtk.Stack> ("status_stack");

            main_window.set_title (_("Software Sources"));
            main_window.set_icon_name ("menta-sources");

            get_widget<Gtk.Button> ("reload_button").clicked.connect (update_cache);
            infobar.response.connect (() => infobar.hide ());

            get_widget<Gtk.Label> ("label_release").set_text (release.description);

            var components_box = get_widget<Gtk.Box> ("box_components");
            var descriptions = component_descriptions ();
            foreach (var component in release.components) {
                var description = descriptions.has_key (component) ? descriptions.get (component) : component;
                var check = new Gtk.CheckButton.with_label ("%s (%s)".printf (description, component));
                check.toggled.connect (() => apply_official_sources ());
                components_box.pack_start (check, false, false, 0);
                component_checks.add (component, check);
            }
            components_box.show_all ();

            var suites_box = get_widget<Gtk.Box> ("box_suites");
            var suite_texts = suite_descriptions ();
            foreach (var suite in release.suites) {
                var description = suite_texts.has_key (suite) ? suite_texts.get (suite) : suite;
                var check = new Gtk.CheckButton.with_label ("%s (%s)".printf (description, release.suite_name (suite)));
                var suite_name = suite;
                check.toggled.connect (() => on_suite_toggled (check, suite_name));
                suites_box.pack_start (check, false, false, 0);
                suite_checks.add (suite, check);
            }
            suites_box.show_all ();
            get_widget<Gtk.Box> ("box_suites_section").set_visible (suite_checks.size > 0);

            repository_model = new Gtk.ListStore (3, typeof (RepositorySource), typeof (bool), typeof (string));
            repository_treeview = get_widget<Gtk.TreeView> ("treeview_repository");
            repository_treeview.set_model (repository_model);
            repository_treeview.set_headers_clickable (true);
            var repo_selection = repository_treeview.get_selection ();
            repo_selection.set_mode (Gtk.SelectionMode.MULTIPLE);
            repo_selection.changed.connect (repo_selected);
            repository_model.set_sort_column_id (2, Gtk.SortType.ASCENDING);

            var toggle = new Gtk.CellRendererToggle ();
            toggle.toggled.connect (repository_toggled);
            var column = new Gtk.TreeViewColumn ();
            column.set_title (_("Enabled"));
            column.pack_start (toggle, false);
            column.set_cell_data_func (toggle, (col, cell, model, iter) => {
                RepositorySource source;
                model.get (iter, 0, out source);
                var renderer = (Gtk.CellRendererToggle) cell;
                renderer.activatable = true;
                renderer.active = source != null && source.is_enabled ();
            });
            column.set_sort_column_id (1);
            repository_treeview.append_column (column);

            column = new Gtk.TreeViewColumn.with_attributes (_("Repository"), new Gtk.CellRendererText (), "markup", 2);
            column.set_sort_column_id (2);
            repository_treeview.append_column (column);

            keys_model = new Gtk.ListStore (2, typeof (Key), typeof (string));
            keys_treeview = get_widget<Gtk.TreeView> ("treeview_keys");
            keys_treeview.set_model (keys_model);
            keys_treeview.set_headers_clickable (true);
            var keys_selection = keys_treeview.get_selection ();
            keys_selection.set_mode (Gtk.SelectionMode.MULTIPLE);
            keys_selection.changed.connect (key_selected);
            keys_model.set_sort_column_id (1, Gtk.SortType.ASCENDING);

            column = new Gtk.TreeViewColumn.with_attributes (_("Key"), new Gtk.CellRendererText (), "markup", 1);
            column.set_sort_column_id (1);
            keys_treeview.append_column (column);

            system_keys = get_system_keys ();

            var mirror_hosts = Masterlist.hosts (release.masterlist);
            settings = DebianRepos.prepare (release, AptSources.load_files (), mirror_hosts, migrated);
            show_official_settings ();

            read_source_lists ();
            refresh_repository_model ();
            load_keys ();

            get_widget<Gtk.Button> ("revert_button").clicked.connect (revert_to_default_sources);

            main_window.delete_event.connect (() => {
                Gtk.main_quit ();
                return false;
            });
            get_widget<Gtk.Button> ("close_button").clicked.connect (() => Gtk.main_quit ());

            mirror_dialog = new MirrorDialog (this, builder);

            get_widget<Gtk.Button> ("button_mirror").clicked.connect (select_new_mirror);
            get_widget<Gtk.Button> ("button_repository_add").clicked.connect (add_repository);
            get_widget<Gtk.Button> ("button_repository_remove").clicked.connect (remove_repository);
            get_widget<Gtk.Button> ("button_keys_add").clicked.connect (add_key);
            get_widget<Gtk.Button> ("button_keys_fetch").clicked.connect (fetch_key);
            get_widget<Gtk.Button> ("button_keys_remove").clicked.connect (remove_key);
            get_widget<Gtk.Button> ("button_mergelist").clicked.connect (fix_mergelist);
            get_widget<Gtk.Button> ("button_purge").clicked.connect (fix_purge);
            get_widget<Gtk.Button> ("button_duplicates").clicked.connect (remove_duplicates);
            get_widget<Gtk.Button> ("button_fix_missing_keys").clicked.connect (() => fix_missing_keys.begin ());
            get_widget<Gtk.Button> ("button_remove_foreign").clicked.connect (() => open_foreign (false));
            get_widget<Gtk.Button> ("button_downgrade_foreign").clicked.connect (() => open_foreign (true));

            get_widget<Gtk.CheckButton> ("source_code_check").toggled.connect (() => apply_official_sources ());
            get_widget<Gtk.CheckButton> ("debug_symbol_check").toggled.connect (() => apply_official_sources ());

            interface_loaded = true;
        }

        public void run () {
            main_window.show ();
            if (migrated.size > 0) {
                var message = new StringBuilder (_("The official Debian repositories were moved to %s.").printf (DebianRepos.OFFICIAL_FILE));
                message.append ("\n\n");
                message.append (_("Backups of the previous configuration:"));
                foreach (var item in migrated) {
                    message.append ("\n%s → %s".printf (item.path, item.backup));
                }
                show_info_dialog (message.str);
            }
            Gtk.main ();
        }

        private void refresh_repository_model () {
            repository_model.clear ();
            foreach (var source in sources) {
                Gtk.TreeIter iter;
                repository_model.insert_with_values (out iter, -1, 0, source, 1, source.is_enabled (), 2, source.ui_name);
            }
        }

        private void read_source_lists () {
            sources.clear ();
            source_files = AptSources.load_files ();
            foreach (var file in source_files) {
                if (file.path == DebianRepos.OFFICIAL_FILE) {
                    continue;
                }
                foreach (var entry in file.entries) {
                    sources.add (new RepositorySource (entry));
                }
            }
        }

        private void reload_sources () {
            read_source_lists ();
            refresh_repository_model ();
        }

        private void open_foreign (bool downgrade) {
            var existing = downgrade ? downgrade_window : remove_window;
            if (existing != null) {
                existing.present ();
                return;
            }
            var window = new ForeignWindow (downgrade, privileged);
            window.closed.connect (() => {
                if (downgrade) {
                    downgrade_window = null;
                } else {
                    remove_window = null;
                }
            });
            if (downgrade) {
                downgrade_window = window;
            } else {
                remove_window = window;
            }
        }

        private static string command_output (string[] argv, out int status) {
            status = 1;
            try {
                var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                launcher.setenv ("LC_ALL", "C", true);
                var process = launcher.spawnv (argv);
                Bytes output;
                process.communicate (null, null, out output, null);
                status = process.get_if_exited () ? process.get_exit_status () : 1;
                return bytes_to_string (output);
            } catch (Error e) {
                return "";
            }
        }

        private static string apt_config (string key, string suffix) {
            int status;
            var output = command_output ({ "apt-config", "shell", "VALUE", "%s/%s".printf (key, suffix) }, out status);
            var line = output.strip ();
            if (!line.has_prefix ("VALUE='") || !line.has_suffix ("'") || line.length < 8) {
                return "";
            }
            return line.substring (7, line.length - 8).replace ("'\\''", "'");
        }

        private void fix_purge () {
            int status;
            var output = command_output ({ "dpkg-query", "-W", "-f", "${db:Status-Abbrev} ${binary:Package}\n" }, out status);
            if (status != 0 || output.strip () == "") {
                show_error_dialog (_("The list of installed packages could not be read."));
                return;
            }
            string[] packages = {};
            foreach (var line in output.split ("\n")) {
                if (line.has_prefix ("rc")) {
                    var words = AptSources.split_words (line);
                    if (words.length > 1) {
                        packages += words[1];
                    }
                }
            }
            if (packages.length == 0) {
                show_info_dialog (_("There is no residual configuration on the system."));
                return;
            }
            if (!show_question_dialog (_("The configuration files of the following packages will be deleted:") + "\n\n" + string.joinv (", ", packages))) {
                return;
            }
            set_busy (true);
            HelperReply? reply = null;
            string? failure = null;
            try {
                reply = privileged.purge (packages);
            } catch (Error e) {
                failure = e.message;
            }
            set_busy (false);
            if (reply != null && reply.ok) {
                show_info_dialog (_("There is no more residual configuration on the system."));
            } else {
                var text = failure;
                if (text == null) {
                    text = reply.result.strip () != "" ? reply.result.strip () : reply.error.strip ();
                }
                if (text == "") {
                    text = _("The residual configuration could not be purged.");
                }
                var count = text.char_count ();
                if (count > 2000) {
                    text = text.substring (text.index_of_nth_char (count - 2000));
                }
                show_error_dialog (text);
            }
        }

        private void fix_mergelist () {
            try {
                privileged.clear_lists ();
            } catch (Error e) {
                show_error_dialog (e.message);
                return;
            }
            show_info_dialog (_("The problem was fixed. Please reload the cache."));
            enable_reload_button ();
        }

        private void remove_duplicates () {
            var modified = AptSources.remove_duplicates_keeping (AptSources.load_files (), DebianRepos.OFFICIAL_FILE);
            try {
                foreach (var file in modified) {
                    print ("Found duplicates in %s, rewriting it.\n", file.path);
                    file.save ();
                }
            } catch (Error e) {
                show_error_dialog (e.message);
                reload_sources ();
                return;
            }
            if (modified.size > 0) {
                show_info_dialog (_("Duplicate entries were removed. Please reload the cache."));
                enable_reload_button ();
                reload_sources ();
            } else {
                show_info_dialog (_("No duplicate entries were found."));
            }
        }

        public void set_busy (bool busy) {
            busy_count += busy ? 1 : -1;
            if (busy_count < 0) {
                busy_count = 0;
            }
            var window = main_window.get_window ();
            if (window != null) {
                window.set_cursor (busy_count > 0 ? new Gdk.Cursor.from_name (window.get_display (), "wait") : null);
            }
            while (Gtk.events_pending ()) {
                Gtk.main_iteration ();
            }
        }

        private class RepositoryInfo : Object {
            public string uri;
            public string base_uri;
            public string path;
            public string? key_path;
            public bool missing = false;
            public bool added = false;
            public Bytes? key_data = null;
            public string fingerprint = "";
        }

        public static string uri_to_filename (string uri) {
            var rest = uri;
            var scheme = rest.index_of (":");
            if (scheme > 0 && Regex.match_simple ("^[A-Za-z][A-Za-z0-9+.-]*$", rest.substring (0, scheme))) {
                rest = rest.substring (scheme + 1);
            }
            if (rest.has_prefix ("[")) {
                var close = rest.index_of ("]");
                if (close > 0) {
                    rest = rest.substring (1, close - 1) + rest.substring (close + 1);
                }
            } else if (rest.has_prefix ("//")) {
                rest = rest.substring (2);
                var slash = rest.index_of ("/");
                var authority = slash >= 0 ? rest.substring (0, slash) : rest;
                var tail = slash >= 0 ? rest.substring (slash) : "";
                var at = authority.last_index_of ("@");
                if (at >= 0) {
                    authority = authority.substring (at + 1);
                }
                if (authority.has_prefix ("[")) {
                    var close = authority.index_of ("]");
                    if (close > 0) {
                        authority = authority.substring (1, close - 1) + authority.substring (close + 1);
                    }
                }
                rest = authority + tail;
            }
            var builder = new StringBuilder ();
            const string BAD = "\\|{}[]<>\"^~_=!@#$%^&*";
            for (int i = 0; i < rest.length; i++) {
                var c = rest[i];
                var code = (uint8) c;
                if (BAD.index_of_char (c) >= 0 || code <= 0x20 || code >= 0x7F || c == '%') {
                    builder.append_printf ("%%%02x", code);
                } else if (c == '/') {
                    builder.append_c ('_');
                } else {
                    builder.append_c (c);
                }
            }
            return builder.str;
        }

        private static Gee.ArrayList<RepositoryInfo> release_targets () {
            var result = new Gee.ArrayList<RepositoryInfo> ();
            int status;
            var output = command_output ({ "apt-get", "indextargets", "--no-release-info", "--format", "$(REPO_URI)\t$(BASE_URI)" }, out status);
            var seen = new Gee.HashSet<string> ();
            foreach (var line in output.split ("\n")) {
                var fields = line.split ("\t");
                if (fields.length != 2 || fields[1] == "" || seen.contains (fields[1])) {
                    continue;
                }
                seen.add (fields[1]);
                var info = new RepositoryInfo ();
                info.uri = fields[0];
                info.base_uri = fields[1].has_suffix ("/") ? fields[1] : fields[1] + "/";
                result.add (info);
            }
            return result;
        }

        private static bool download (Soup.Session session, string url, out Bytes? data) {
            data = null;
            var message = new Soup.Message ("GET", url);
            if (message == null) {
                return false;
            }
            try {
                data = session.send_and_read (message, null);
            } catch (Error e) {
                printerr ("E: %s\n", e.message);
                return false;
            }
            return message.status_code == Soup.Status.OK;
        }

        private static void scan_missing_keys (Gee.List<RepositoryInfo> repositories, string[] keyrings, string lists, Gee.List<AptSources.Entry> entries, string keyserver) {
            GpgHome? temp_files = null;
            GpgHome home;
            try {
                home = new GpgHome ();
            } catch (Error e) {
                printerr ("E: %s\n", e.message);
                return;
            }
            foreach (var keyring in keyrings) {
                home.import_file (keyring);
            }
            var session = new Soup.Session ();
            session.user_agent = USER_AGENT;
            session.timeout = 30;
            var checked = new Gee.ArrayList<RepositoryInfo> ();
            foreach (var repository in repositories) {
                var stub = uri_to_filename (repository.base_uri);
                var path = Path.build_filename (lists, stub + "InRelease");
                if (!FileUtils.test (path, FileTest.IS_REGULAR)) {
                    path = Path.build_filename (lists, stub + "Release");
                    if (!FileUtils.test (path, FileTest.IS_REGULAR) || !FileUtils.test (path + ".gpg", FileTest.IS_REGULAR)) {
                        path = null;
                    }
                }
                if (path == null) {
                    print ("W: Release file missing for %s, trying to retrieve\n", display_uri (repository.uri));
                    Bytes? data;
                    Bytes? signature = null;
                    bool detached = false;
                    var ok = download (session, repository.base_uri + "InRelease", out data);
                    if (!ok) {
                        detached = true;
                        ok = download (session, repository.base_uri + "Release", out data)
                            && download (session, repository.base_uri + "Release.gpg", out signature);
                    }
                    if (ok) {
                        try {
                            if (temp_files == null) {
                                temp_files = new GpgHome ();
                            }
                            if (detached) {
                                path = Path.build_filename (temp_files.path, stub + "Release");
                                FileUtils.set_data (path + ".gpg", signature.get_data ());
                            } else {
                                path = Path.build_filename (temp_files.path, stub + "InRelease");
                            }
                            FileUtils.set_data (path, data.get_data ());
                        } catch (Error e) {
                            printerr ("E: %s\n", e.message);
                            path = null;
                        }
                    }
                }
                if (path == null) {
                    printerr ("E: Could not retrieve release file for %s\n", display_uri (repository.uri));
                    continue;
                }
                repository.path = path;
                checked.add (repository);
            }

            var fetched = new Gee.HashMap<string, Bytes> ();
            foreach (var repository in checked) {
                repository.key_path = AptSources.repo_key_path (repository.uri, entries);
                GpgHome verifier = home;
                if (repository.key_path != null) {
                    print ("%s is signed by %s\n", display_uri (repository.uri), repository.key_path);
                    try {
                        verifier = new GpgHome ();
                    } catch (Error e) {
                        printerr ("E: %s\n", e.message);
                        continue;
                    }
                    if (FileUtils.test (repository.key_path, FileTest.IS_REGULAR)) {
                        print ("  Key found.\n");
                        verifier.import_file (repository.key_path);
                    } else {
                        print ("  Key is missing.\n");
                    }
                }
                string[] args = { "--status-fd", "1", "--verify" };
                if (repository.path.has_suffix ("InRelease")) {
                    args += repository.path;
                } else {
                    args += repository.path + ".gpg";
                    args += repository.path;
                }
                string output;
                string errors;
                verifier.run (args, out output, out errors);
                var signers = missing_signers (output);
                if (signers.size == 0) {
                    continue;
                }
                repository.missing = true;
                var armor = repository.key_path != null && repository.key_path.has_suffix (".asc");
                foreach (var fingerprint in signers) {
                    repository.fingerprint = fingerprint;
                    var cache_key = "%s %s".printf (fingerprint, armor.to_string ());
                    if (fetched.has_key (cache_key)) {
                        repository.key_data = fetched.get (cache_key);
                    } else {
                        string error_text;
                        repository.key_data = fetch_remote_key (fingerprint, keyserver, armor, out error_text);
                        if (repository.key_data == null) {
                            printerr ("E: Retrieving key %s failed: %s\n", fingerprint, error_text.strip ());
                            continue;
                        }
                        fetched.set (cache_key, repository.key_data);
                    }
                    if (repository.key_path != null && FileUtils.test (repository.key_path, FileTest.IS_REGULAR)) {
                        repository.key_data = merge_keyring (repository.key_path, repository.key_data, armor);
                    }
                    if (repository.key_data != null) {
                        break;
                    }
                }
            }
        }

        public static Gee.ArrayList<string> missing_signers (string status) {
            var result = new Gee.ArrayList<string> ();
            var key_ids = new Gee.ArrayList<string> ();
            foreach (var line in status.split ("\n")) {
                var fields = AptSources.split_words (line);
                if (fields.length < 2 || fields[0] != "[GNUPG:]") {
                    continue;
                }
                if (fields[1] == "GOODSIG" || fields[1] == "VALIDSIG") {
                    return new Gee.ArrayList<string> ();
                }
                if (fields[1] == "ERRSIG" && fields.length > 7 && fields[7] == "9") {
                    var id = fields.length > 8 && fields[8] != "-" ? fields[8] : fields[2];
                    if (!result.contains (id)) {
                        result.add (id);
                    }
                } else if (fields[1] == "NO_PUBKEY" && fields.length > 2) {
                    key_ids.add (fields[2]);
                }
            }
            if (result.size == 0) {
                foreach (var id in key_ids) {
                    if (!result.contains (id)) {
                        result.add (id);
                    }
                }
            }
            return result;
        }

        private static Bytes? merge_keyring (string path, Bytes data, bool armor) {
            try {
                var merged = new GpgHome ();
                var incoming = Path.build_filename (merged.path, "incoming.gpg");
                FileUtils.set_data (incoming, data.get_data ());
                merged.import_file (path);
                merged.import_file (incoming);
                string[] fingerprints = {};
                foreach (var key in merged.list_keys ()) {
                    fingerprints += key.fingerprint;
                }
                return merged.export (fingerprints, armor);
            } catch (Error e) {
                printerr ("E: %s\n", e.message);
                return null;
            }
        }

        public static string display_uri (string uri) {
            var position = uri.index_of ("://");
            if (position < 0) {
                return uri;
            }
            var rest = uri.substring (position + 3);
            var slash = rest.index_of ("/");
            var authority = slash >= 0 ? rest.substring (0, slash) : rest;
            var at = authority.last_index_of ("@");
            if (at < 0) {
                return uri;
            }
            return uri.substring (0, position + 3) + authority.substring (at + 1) + (slash >= 0 ? rest.substring (slash) : "");
        }

        private async void fix_missing_keys () {
            var trusted = apt_config ("Dir::Etc::trusted", "f");
            var trustedparts = apt_config ("Dir::Etc::trustedparts", "d");
            var lists = apt_config ("Dir::State::lists", "d");
            if (!FileUtils.test (trustedparts, FileTest.IS_DIR) || !FileUtils.test (lists, FileTest.IS_DIR)) {
                show_info_dialog (_("Error with your APT configuration, you may have to reload the cache first."));
                return;
            }

            string[] keyrings = {};
            if (trusted != "" && FileUtils.test (trusted, FileTest.IS_REGULAR)) {
                keyrings += trusted;
            }
            foreach (var path in list_directory (trustedparts)) {
                if ((path.has_suffix (".gpg") || path.has_suffix (".asc")) && FileUtils.test (path, FileTest.IS_REGULAR)) {
                    keyrings += path;
                }
            }

            set_busy (true);
            main_window.set_sensitive (false);
            var repositories = release_targets ();
            var sourcelist = apt_config ("Dir::Etc::sourcelist", "f");
            var sourceparts = apt_config ("Dir::Etc::sourceparts", "d");
            var entries = AptSources.all_entries (AptSources.load_files (sourcelist != "" ? sourcelist : null, sourceparts != "" ? sourceparts : null));
            var keyserver = release.keyserver;
            SourceFunc callback = fix_missing_keys.callback;
            new Thread<void*> ("missing-keys", () => {
                scan_missing_keys (repositories, keyrings, lists, entries, keyserver);
                Idle.add ((owned) callback);
                return null;
            });
            yield;

            foreach (var repository in repositories) {
                if (repository.key_data == null) {
                    continue;
                }
                try {
                    Files.storage ().write_file (repository.key_path ?? remote_key_path (repository.fingerprint), repository.key_data.get_data (), 0644);
                    repository.added = true;
                } catch (Error e) {
                    printerr ("E: Could not download key %s: %s\n", repository.fingerprint, e.message);
                }
            }
            main_window.set_sensitive (true);
            set_busy (false);

            var keys_added = new Gee.ArrayList<string> ();
            var keys_missing = new Gee.ArrayList<string> ();
            foreach (var repository in repositories) {
                if (repository.added) {
                    keys_added.add (display_uri (repository.uri));
                } else if (repository.missing) {
                    keys_missing.add (display_uri (repository.uri));
                }
            }
            if (keys_added.size == 0 && keys_missing.size == 0) {
                show_info_dialog (_("No missing keys were found."));
                return;
            }
            var info = keys_missing.size == 0 ? _("All missing keys were successfully added.") : _("Not all missing keys could be found.");
            var log = new StringBuilder ();
            if (keys_added.size > 0) {
                log.append (_("Keys were added for the following repositories:"));
                log.append ("\n");
                foreach (var uri in keys_added) {
                    log.append (" - %s\n".printf (uri));
                }
            }
            if (keys_missing.size > 0) {
                if (keys_added.size > 0) {
                    log.append ("\n");
                }
                log.append (_("Keys are still missing for the following repositories:"));
                log.append ("\n");
                foreach (var uri in keys_missing) {
                    log.append (" - %s\n".printf (uri));
                }
                log.append ("\n");
                log.append (_("Add the remaining missing key(s) manually or remove the corresponding repositories."));
                log.append ("\n");
            }
            var message = "%s\n\n%s".printf (info, log.str);
            if (keys_added.size > 0) {
                message += "\n" + _("Please reload the cache.");
                load_keys ();
                enable_reload_button ();
            }
            show_info_dialog (message);
        }

        private static Gee.ArrayList<string> list_directory (string directory) {
            var result = new Gee.ArrayList<string> ();
            try {
                var dir = Dir.open (directory);
                string? name;
                while ((name = dir.read_name ()) != null) {
                    if (!name.has_prefix (".")) {
                        result.add (Path.build_filename (directory, name));
                    }
                }
            } catch (FileError e) {
            }
            result.sort ((a, b) => strcmp (a, b));
            return result;
        }

        private Gee.HashSet<string> get_system_keys () {
            var result = new Gee.HashSet<string> ();
            var paths = new Gee.ArrayList<string> ();
            foreach (var path in DEBIAN_KEYRINGS) {
                paths.add (path);
            }
            if (!paths.contains (release.keyring)) {
                paths.add (release.keyring);
            }
            foreach (var path in paths) {
                if (FileUtils.test (path, FileTest.IS_REGULAR)) {
                    foreach (var key in scan_keyring (path)) {
                        result.add (format_fingerprint (key.fingerprint));
                    }
                }
            }
            return result;
        }

        private class Keyring : Object {
            public string path;
            public bool removable;
            public Gee.ArrayList<string> sources = new Gee.ArrayList<string> ();

            public Keyring (string path, bool removable) {
                this.path = path;
                this.removable = removable;
            }
        }

        private Gee.ArrayList<Keyring> get_keyrings () {
            var result = new Gee.ArrayList<Keyring> ();
            var trustedparts = apt_config ("Dir::Etc::trustedparts", "d");
            if (trustedparts != "") {
                foreach (var path in list_directory (trustedparts)) {
                    if (FileUtils.test (path, FileTest.IS_REGULAR)) {
                        result.add (new Keyring (path, true));
                    }
                }
            }
            var signed_by = new Gee.TreeMap<string, Keyring> ();
            var sourcelist = apt_config ("Dir::Etc::sourcelist", "f");
            var sourceparts = apt_config ("Dir::Etc::sourceparts", "d");
            foreach (var entry in AptSources.all_entries (AptSources.load_files (sourcelist != "" ? sourcelist : null, sourceparts != "" ? sourceparts : null))) {
                if (!entry.enabled || entry.signed_by == null) {
                    continue;
                }
                var keyring = signed_by.get (entry.signed_by);
                if (keyring == null) {
                    keyring = new Keyring (entry.signed_by, false);
                    signed_by.set (entry.signed_by, keyring);
                }
                keyring.sources.add (RepositorySource.display_name (entry.uris[0]));
            }
            foreach (var keyring in signed_by.values) {
                if (FileUtils.test (keyring.path, FileTest.IS_REGULAR)) {
                    result.add (keyring);
                }
            }
            return result;
        }

        private void load_keys () {
            keys.clear ();
            var seen = new Gee.HashMap<string, Key> ();
            foreach (var keyring in get_keyrings ()) {
                foreach (var scanned in scan_keyring (keyring.path)) {
                    var pub = format_fingerprint (scanned.fingerprint);
                    if (system_keys.contains (pub)) {
                        continue;
                    }
                    if (seen.has_key (pub)) {
                        var known = seen.get (pub);
                        if (keyring.removable && known.removable) {
                            known.paths.add (keyring.path);
                        }
                        known.sources.add_all (keyring.sources);
                        continue;
                    }
                    var uid = scanned.uids.size > 0 ? scanned.uids[0] : "";
                    var key = new Key (scanned.fingerprint, uid, keyring.path, keyring.removable, keyring.sources);
                    seen.set (pub, key);
                    keys.add (key);
                }
            }
            keys_model.clear ();
            foreach (var key in keys) {
                Gtk.TreeIter iter;
                keys_model.insert_with_values (out iter, -1, 0, key, 1, key.markup ());
            }
        }

        private void add_key () {
            var dialog = new Gtk.FileChooserDialog (_("Import Key File"), main_window, Gtk.FileChooserAction.OPEN,
                                                    _("_Cancel"), Gtk.ResponseType.CANCEL,
                                                    _("_Import"), Gtk.ResponseType.OK);
            dialog.set_default_response (Gtk.ResponseType.OK);

            var key_filter = new Gtk.FileFilter ();
            key_filter.set_name (_("Key files"));
            foreach (var pattern in new string[] { "*.asc", "*.gpg", "*.key", "*.pgp", "*.pub" }) {
                key_filter.add_pattern (pattern);
            }
            foreach (var mime_type in new string[] { "application/pgp-keys", "application/pgp-encrypted" }) {
                key_filter.add_mime_type (mime_type);
            }
            dialog.add_filter (key_filter);

            var all_filter = new Gtk.FileFilter ();
            all_filter.set_name (_("All files"));
            all_filter.add_pattern ("*");
            dialog.add_filter (all_filter);

            var response = dialog.run ();
            var filename = dialog.get_filename ();
            dialog.destroy ();
            if (response != Gtk.ResponseType.OK || filename == null) {
                return;
            }

            import_key_async.begin (filename);
        }

        private async void import_key_async (string filename) {
            set_busy (true);
            main_window.set_sensitive (false);
            Bytes? data = null;
            string key_path = "";
            string? failure = null;
            SourceFunc callback = import_key_async.callback;
            new Thread<void*> ("import-key", () => {
                try {
                    data = prepare_local_key (filename, out key_path);
                } catch (Error e) {
                    failure = e.message;
                }
                Idle.add ((owned) callback);
                return null;
            });
            yield;
            if (data != null) {
                try {
                    Files.storage ().write_file (key_path, data.get_data (), 0644);
                } catch (Error e) {
                    failure = e.message;
                    data = null;
                }
            }
            main_window.set_sensitive (true);
            set_busy (false);
            if (data == null) {
                if (failure != null) {
                    printerr ("E: Could not import %s: %s\n", filename, failure);
                }
                show_info_dialog (_("No key could be imported from this file."));
                return;
            }
            load_keys ();
            enable_reload_button ();
        }

        private void fetch_key () {
            string keyserver;
            try {
                keyserver = new Regex ("^\\w+://").replace (release.keyserver, -1, 0, "").split (":")[0];
            } catch (RegexError e) {
                keyserver = release.keyserver;
            }
            var fingerprint = show_entry_dialog (_("Please enter the fingerprint of the public key you want to download from %s:").printf (keyserver), "");
            if (fingerprint == null || fingerprint.strip () == "") {
                return;
            }
            var normalized = normalize_fingerprint (fingerprint);
            if (normalized == null) {
                show_error_dialog (_("Please enter the full fingerprint of the key (40 or 64 hexadecimal characters)."));
                return;
            }
            fetch_key_async.begin (normalized);
        }

        private async void fetch_key_async (string fingerprint) {
            set_busy (true);
            main_window.set_sensitive (false);
            Bytes? data = null;
            string error_text = "";
            string received = fingerprint;
            var keyserver = release.keyserver;
            SourceFunc callback = fetch_key_async.callback;
            new Thread<void*> ("fetch-key", () => {
                data = fetch_remote_key (fingerprint, keyserver, false, out error_text, out received);
                Idle.add ((owned) callback);
                return null;
            });
            yield;
            bool success = false;
            if (data != null) {
                try {
                    Files.storage ().write_file (remote_key_path (received), data.get_data (), 0644);
                    success = true;
                } catch (Error e) {
                    error_text = e.message;
                }
            }
            main_window.set_sensitive (true);
            set_busy (false);
            if (!success) {
                printerr ("E: Could not download key %s: %s\n", fingerprint, error_text.strip ());
                show_error_dialog (_("The key could not be downloaded."));
                return;
            }
            load_keys ();
            enable_reload_button ();
        }

        private Gee.ArrayList<Gtk.TreeIter?> selected_iters (Gtk.TreeView view) {
            var result = new Gee.ArrayList<Gtk.TreeIter?> ();
            Gtk.TreeModel model;
            var rows = view.get_selection ().get_selected_rows (out model);
            foreach (var path in rows) {
                Gtk.TreeIter iter;
                if (model.get_iter (out iter, path)) {
                    result.add (iter);
                }
            }
            return result;
        }

        private void remove_key () {
            if (!show_question_dialog (_("Are you sure you want to permanently remove the selected keys?"))) {
                return;
            }
            var to_delete = new Gee.ArrayList<Key> ();
            foreach (var iter in selected_iters (keys_treeview)) {
                Key key;
                keys_model.get (iter, 0, out key);
                to_delete.add (key);
            }
            foreach (var key in to_delete) {
                if (!key.removable) {
                    continue;
                }
                try {
                    key.delete ();
                } catch (Error e) {
                    show_error_dialog (e.message);
                    break;
                }
            }
            load_keys ();
        }

        private void key_selected () {
            Gtk.TreeModel model;
            var rows = keys_treeview.get_selection ().get_selected_rows (out model);
            int count = 0;
            int removable = 0;
            foreach (var path in rows) {
                Gtk.TreeIter iter;
                if (model.get_iter (out iter, path)) {
                    count++;
                    Key key;
                    model.get (iter, 0, out key);
                    if (key.removable) {
                        removable++;
                    }
                }
            }
            get_widget<Gtk.Button> ("button_keys_remove").set_sensitive (count >= 1 && removable == count);
        }

        private void add_repository () {
            var default_line = "deb http://packages.example.com/debian %s main".printf (release.codename);
            var start_line = get_clipboard_text ("deb") ?? default_line;
            var line = show_entry_dialog (_("Please enter the APT line of the repository you want to add:"), start_line);
            if (line == null || line == "" || line == default_line) {
                return;
            }
            line = AptSources.expand_http_line (AptSources.unicode_strip (line), release.codename);
            if (AptSources.repo_malformed (line)) {
                show_info_dialog (_("Malformed input, repository not added."));
                return;
            }
            if (AptSources.repo_exists (line, AptSources.all_entries (AptSources.load_files ()))) {
                show_info_dialog (_("This repository is already configured, you cannot add it a second time."));
                return;
            }
            try {
                var file = new AptSources.SourceFile (AptSources.ADDITIONAL_REPOSITORIES).load ();
                file.add_line (line);
                file.save ();
            } catch (Error e) {
                show_error_dialog (e.message);
                return;
            }
            reload_sources ();
            enable_reload_button ();
        }

        private void remove_repository () {
            if (!show_question_dialog (_("Are you sure you want to permanently remove the selected repositories?"))) {
                return;
            }
            var selected = new Gee.ArrayList<RepositorySource> ();
            foreach (var iter in selected_iters (repository_treeview)) {
                RepositorySource source;
                repository_model.get (iter, 0, out source);
                selected.add (source);
            }
            bool changed = false;
            foreach (var source in selected) {
                try {
                    source.delete ();
                    changed = true;
                } catch (Error e) {
                    show_error_dialog (e.message);
                    break;
                }
            }
            reload_sources ();
            if (changed) {
                enable_reload_button ();
            }
        }

        private void repo_selected () {
            get_widget<Gtk.Button> ("button_repository_remove").set_sensitive (repository_treeview.get_selection ().count_selected_rows () >= 1);
        }

        private void repository_toggled (string path) {
            Gtk.TreeIter iter;
            if (!repository_model.get_iter (out iter, new Gtk.TreePath.from_string (path))) {
                return;
            }
            RepositorySource source;
            repository_model.get (iter, 0, out source);
            try {
                source.switch_state ();
            } catch (Error e) {
                show_error_dialog (e.message);
                return;
            }
            repository_model.set (iter, 1, source.is_enabled ());
            enable_reload_button ();
        }

        private bool run_message (Gtk.MessageType type, Gtk.ButtonsType buttons, string message, Gtk.ResponseType default_response, Gtk.ResponseType confirm) {
            var dialog = new Gtk.MessageDialog (main_window, Gtk.DialogFlags.MODAL, type, buttons, "%s", message);
            dialog.set_default_response (default_response);
            var response = dialog.run ();
            dialog.destroy ();
            return response == confirm;
        }

        public bool show_question_dialog (string message) {
            return run_message (Gtk.MessageType.WARNING, Gtk.ButtonsType.YES_NO, message, Gtk.ResponseType.NO, Gtk.ResponseType.YES);
        }

        public void show_info_dialog (string message) {
            run_message (Gtk.MessageType.INFO, Gtk.ButtonsType.OK, message, Gtk.ResponseType.OK, Gtk.ResponseType.OK);
        }

        public void show_error_dialog (string message) {
            run_message (Gtk.MessageType.ERROR, Gtk.ButtonsType.OK, message, Gtk.ResponseType.OK, Gtk.ResponseType.OK);
        }

        private string? show_entry_dialog (string message, string default_text) {
            var dialog = new Gtk.MessageDialog (main_window, Gtk.DialogFlags.MODAL, Gtk.MessageType.QUESTION, Gtk.ButtonsType.OK_CANCEL, "%s", message);
            var entry = new Gtk.Entry ();
            entry.set_text (default_text);
            entry.set_margin_start (6);
            entry.set_margin_end (6);
            entry.set_width_chars (60);
            entry.show ();
            ((Gtk.Box) dialog.get_message_area ()).pack_end (entry, false, false, 0);
            entry.activate.connect (() => dialog.response (Gtk.ResponseType.OK));
            dialog.set_default_response (Gtk.ResponseType.OK);
            var response = dialog.run ();
            var text = entry.get_text ();
            dialog.destroy ();
            return response == Gtk.ResponseType.OK ? text : null;
        }

        private void select_new_mirror () {
            var url = mirror_dialog.run (release);
            if (url != null && settings.mirror != url) {
                settings.mirror = url;
                get_widget<Gtk.Label> ("label_mirror_name").set_text (url);
                apply_official_sources ();
            }
        }

        private void show_official_settings () {
            currently_applying_sources = true;
            get_widget<Gtk.Label> ("label_mirror_name").set_text (settings.mirror);
            get_widget<Gtk.Button> ("button_mirror").set_tooltip_text (settings.mirror);
            foreach (var item in component_checks.entries) {
                item.value.set_active (settings.components.contains (item.key) || item.key == "main");
                item.value.set_sensitive (item.key != "main");
            }
            foreach (var item in suite_checks.entries) {
                item.value.set_active (settings.suites.contains (item.key));
            }
            get_widget<Gtk.CheckButton> ("source_code_check").set_active (settings.source_code);
            get_widget<Gtk.CheckButton> ("debug_symbol_check").set_active (settings.debug);
            currently_applying_sources = false;
        }

        private void revert_to_default_sources () {
            settings = DebianRepos.default_settings (release);
            show_official_settings ();
            apply_official_sources ();
        }

        private void on_suite_toggled (Gtk.CheckButton check, string suite) {
            if (interface_loaded && !currently_applying_sources && check.get_active () && suite == "experimental") {
                if (!show_question_dialog (_("Experimental contains packages which are under development and may be broken. They are only installed when you explicitly ask for them. Are you sure you want to enable Experimental?"))) {
                    currently_applying_sources = true;
                    check.set_active (false);
                    currently_applying_sources = false;
                    return;
                }
            }
            apply_official_sources ();
        }

        public void enable_reload_button () {
            if (disable_refresh) {
                sources_changed = true;
                return;
            }
            infobar.set_message_type (Gtk.MessageType.INFO);
            infobar.set_show_close_button (false);
            get_widget<Gtk.Button> ("reload_button").show ();
            status_stack.set_visible_child_name ("page_update");
            infobar.show ();
        }

        private void update_cache () {
            status_stack.set_visible_child_name ("page_progress");
            get_widget<Gtk.Button> ("reload_button").hide ();
            get_widget<Gtk.Notebook> ("notebook").set_sensitive (false);
            var progressbar = get_widget<Gtk.ProgressBar> ("progressbar");
            var label = get_widget<Gtk.Label> ("label_progress");
            progressbar.set_fraction (0.0);
            label.set_text (_("Downloading the package information..."));
            privileged.apt ("update", {},
                (percent, description) => {
                    progressbar.set_fraction (double.min (percent, 100) / 100.0);
                    label.set_text (description);
                },
                (success, errors) => {
                    get_widget<Gtk.Notebook> ("notebook").set_sensitive (true);
                    progressbar.set_fraction (0.0);
                    if (success) {
                        infobar.hide ();
                    } else {
                        infobar.set_message_type (Gtk.MessageType.ERROR);
                        infobar.set_show_close_button (true);
                        get_widget<Gtk.Label> ("error_label").set_text (string.joinv ("\n", errors));
                        status_stack.set_visible_child_name ("page_error");
                        get_widget<Gtk.Button> ("reload_button").show ();
                    }
                });
        }

        private void apply_official_sources () {
            if (!interface_loaded || currently_applying_sources) {
                return;
            }
            var unknown = new Gee.ArrayList<string> ();
            foreach (var component in settings.components) {
                if (!component_checks.has_key (component)) {
                    unknown.add (component);
                }
            }
            var components = new Gee.ArrayList<string> ();
            foreach (var item in component_checks.entries) {
                if (item.value.get_active ()) {
                    components.add (item.key);
                }
            }
            components.add_all (unknown);
            settings.components = components;
            var suites = new Gee.ArrayList<string> ();
            foreach (var item in suite_checks.entries) {
                if (item.value.get_active ()) {
                    suites.add (item.key);
                }
            }
            settings.suites = suites;
            settings.source_code = get_widget<Gtk.CheckButton> ("source_code_check").get_active ();
            settings.debug = get_widget<Gtk.CheckButton> ("debug_symbol_check").get_active ();
            get_widget<Gtk.Button> ("button_mirror").set_tooltip_text (settings.mirror);
            try {
                DebianRepos.write (release, settings);
            } catch (Error e) {
                show_error_dialog (e.message);
                return;
            }
            enable_reload_button ();
        }

        private string? get_clipboard_text (string source_type) {
            var clipboard = Gtk.Clipboard.get (Gdk.SELECTION_CLIPBOARD);
            var text = clipboard.wait_for_text ();
            if (text != null && AptSources.unicode_strip (text).has_prefix (source_type)) {
                return AptSources.unicode_strip (text);
            }
            return null;
        }
    }
}
