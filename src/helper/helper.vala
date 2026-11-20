namespace Menta.Helper {
    private Regex? package_regex = null;
    private Regex? package_version_regex = null;

    private bool valid_package (string name) {
        try {
            if (package_regex == null) {
                package_regex = new Regex ("^[a-z0-9][a-z0-9+.-]*(:[a-z0-9][a-z0-9-]*)?$", RegexCompileFlags.DOLLAR_ENDONLY);
            }
        } catch (RegexError e) {
            return false;
        }
        return package_regex.match (name);
    }

    private bool valid_package_version (string spec) {
        try {
            if (package_version_regex == null) {
                package_version_regex = new Regex ("^[a-z0-9][a-z0-9+.-]*(:[a-z0-9][a-z0-9-]*)?=[A-Za-z0-9.+~:-]+$", RegexCompileFlags.DOLLAR_ENDONLY);
            }
        } catch (RegexError e) {
            return false;
        }
        return package_version_regex.match (spec);
    }

    public string bytes_text (Bytes? bytes) {
        if (bytes == null || bytes.get_size () == 0) {
            return "";
        }
        var buffer = new uint8[bytes.get_size () + 1];
        Memory.copy (buffer, bytes.get_data (), bytes.get_size ());
        buffer[bytes.get_size ()] = 0;
        var text = (string) buffer;
        if (text.length != bytes.get_size ()) {
            var builder = new StringBuilder ();
            foreach (var b in bytes.get_data ()) {
                builder.append_c (b == 0 ? ' ' : (char) b);
            }
            text = builder.str;
        }
        return text.make_valid ();
    }

    private bool clean_absolute (string path) {
        if (!path.has_prefix ("/") || "\n" in path) {
            return false;
        }
        foreach (var part in path.split ("/")) {
            if (part == ".." || part == ".") {
                return false;
            }
        }
        return !("//" in path);
    }

    private bool name_matches (string name, string pattern) {
        return Regex.match_simple (pattern, name, RegexCompileFlags.DOLLAR_ENDONLY);
    }

    public bool sources_path (string path) {
        if (!clean_absolute (path)) {
            return false;
        }
        if (path == AptSources.SOURCES_LIST) {
            return true;
        }
        var directory = Path.get_dirname (path);
        var name = Path.get_basename (path);
        return directory == AptSources.SOURCES_PARTS && name_matches (name, "^[A-Za-z0-9_.-]+\\.(list|sources)$");
    }

    public bool keyring_path (string path) {
        if (!clean_absolute (path)) {
            return false;
        }
        var name = Path.get_basename (path);
        if (!name_matches (name, "^[A-Za-z0-9_.@+-]+\\.(gpg|asc)$") || name.has_prefix (".")) {
            return false;
        }
        foreach (var root in new string[] { "/etc/apt/", "/usr/share/keyrings/", "/usr/local/share/keyrings/" }) {
            if (path.has_prefix (root)) {
                return true;
            }
        }
        return false;
    }

    public bool writable_path (string path) {
        return sources_path (path) || keyring_path (path);
    }

    private class Server : Object {
        private MainLoop loop;
        private DataInputStream input;
        private Gee.LinkedList<Json.Object> queue = new Gee.LinkedList<Json.Object> ();
        private bool busy = false;
        private bool finished_input = false;

        public Server () {
            loop = new MainLoop ();
            input = new DataInputStream (new UnixInputStream (0, false));
        }

        public int run () {
            send_event (null, "ready");
            read_next ();
            loop.run ();
            return 0;
        }

        private void send (Json.Object object) {
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (object);
            var generator = new Json.Generator ();
            generator.set_root (node);
            stdout.puts (generator.to_data (null));
            stdout.putc ('\n');
            stdout.flush ();
        }

        private void send_event (int64? id, string event) {
            var object = new Json.Object ();
            if (id != null) {
                object.set_int_member ("id", id);
            }
            object.set_string_member ("event", event);
            send (object);
        }

        private void reply (int64 id, bool ok, string? error = null, string? result = null, string[]? errors = null) {
            var object = new Json.Object ();
            object.set_int_member ("id", id);
            object.set_string_member ("event", "done");
            object.set_boolean_member ("ok", ok);
            if (error != null) {
                object.set_string_member ("error", error);
            }
            if (result != null) {
                object.set_string_member ("result", result);
            }
            if (errors != null) {
                var array = new Json.Array ();
                foreach (var line in errors) {
                    array.add_string_element (line);
                }
                object.set_array_member ("errors", array);
            }
            send (object);
        }

        private void read_next () {
            input.read_line_async.begin (Priority.DEFAULT, null, (obj, res) => {
                string? line = null;
                try {
                    line = input.read_line_async.end (res);
                } catch (Error e) {
                    line = null;
                }
                if (line == null) {
                    finished_input = true;
                    maybe_quit ();
                    return;
                }
                if (line.strip () != "") {
                    var parser = new Json.Parser ();
                    try {
                        parser.load_from_data (line);
                        var root = parser.get_root ();
                        if (root != null && root.get_node_type () == Json.NodeType.OBJECT) {
                            queue.offer_tail (root.get_object ());
                        }
                    } catch (Error e) {
                        printerr ("menta-sources-helper: %s\n", e.message);
                    }
                }
                process ();
                read_next ();
            });
        }

        private void maybe_quit () {
            if (finished_input && !busy && queue.is_empty) {
                loop.quit ();
            }
        }

        private void process () {
            while (!busy && !queue.is_empty) {
                handle (queue.poll_head ());
            }
            maybe_quit ();
        }

        private static string member (Json.Object request, string name) {
            return request.has_member (name) ? (request.get_string_member (name) ?? "") : "";
        }

        private static string[] string_list (Json.Object request, string name) {
            string[] result = {};
            if (!request.has_member (name)) {
                return result;
            }
            var array = request.get_array_member (name);
            for (uint i = 0; i < array.get_length (); i++) {
                result += array.get_string_element (i);
            }
            return result;
        }

        private void handle (Json.Object request) {
            var id = request.has_member ("id") ? request.get_int_member ("id") : 0;
            var op = member (request, "op");
            try {
                switch (op) {
                    case "write":
                        var path = member (request, "path");
                        if (!writable_path (path)) {
                            throw new StorageError.DENIED ("Writing %s is not allowed", path);
                        }
                        var data = Base64.decode (member (request, "data"));
                        DirectStorage.write_atomically (path, data, 0644);
                        reply (id, true);
                        break;
                    case "remove":
                        var path = member (request, "path");
                        if (!writable_path (path)) {
                            throw new StorageError.DENIED ("Removing %s is not allowed", path);
                        }
                        new DirectStorage ().remove_file (path);
                        reply (id, true);
                        break;
                    case "backup":
                        var path = member (request, "path");
                        if (!sources_path (path) || !FileUtils.test (path, FileTest.IS_REGULAR)) {
                            throw new StorageError.DENIED ("Backing up %s is not allowed", path);
                        }
                        reply (id, true, null, DirectStorage.copy_to_backup (path, DebianRepos.BACKUP_DIR));
                        break;
                    case "clear-lists":
                        clear_lists ();
                        reply (id, true);
                        break;
                    case "purge":
                        var packages = string_list (request, "packages");
                        if (packages.length == 0) {
                            throw new StorageError.DENIED ("No packages");
                        }
                        foreach (var name in packages) {
                            if (!valid_package (name)) {
                                throw new StorageError.DENIED ("Invalid package name %s", name);
                            }
                        }
                        string[] argv = { "dpkg", "--purge" };
                        foreach (var name in packages) {
                            argv += name;
                        }
                        int status;
                        var output = run_merged (argv, locale_environment (request), out status);
                        reply (id, status == 0, status == 0 ? null : output, output);
                        break;
                    case "apt":
                        start_apt (id, request);
                        break;
                    default:
                        throw new StorageError.DENIED ("Unknown operation %s", op);
                }
            } catch (Error e) {
                reply (id, false, e.message);
            }
        }

        private static string[] locale_environment (Json.Object request) {
            string[] result = {};
            foreach (var name in new string[] { "LANG", "LANGUAGE", "LC_ALL", "LC_MESSAGES" }) {
                var value = member (request, name);
                if (value != "" && Regex.match_simple ("^[A-Za-z0-9_.@:-]+$", value, RegexCompileFlags.DOLLAR_ENDONLY)) {
                    result += "%s=%s".printf (name, value);
                }
            }
            return result;
        }

        private string run_merged (string[] argv, string[] environment, out int status) throws Error {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_MERGE);
            foreach (var item in environment) {
                var position = item.index_of ("=");
                launcher.setenv (item.substring (0, position), item.substring (position + 1), true);
            }
            var process = launcher.spawnv (argv);
            Bytes output;
            process.communicate (null, null, out output, null);
            var text = bytes_text (output);
            if (process.get_if_exited ()) {
                status = process.get_exit_status ();
                if (status != 0 && text.strip () == "") {
                    text = "%s exited with status %d".printf (argv[0], status);
                }
            } else {
                status = 128 + process.get_term_sig ();
                text += "%s%s was terminated by signal %d".printf (text == "" ? "" : "\n", argv[0], process.get_term_sig ());
            }
            return text;
        }

        private string apt_directory (string key) throws Error {
            string output;
            int status;
            Process.spawn_sync (null, { "apt-config", "shell", "VALUE", key + "/d" }, { "PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C" }, SpawnFlags.SEARCH_PATH | SpawnFlags.STDERR_TO_DEV_NULL, null, out output, null, out status);
            var line = output.strip ();
            if (!line.has_prefix ("VALUE='") || !line.has_suffix ("'") || line.length < 8) {
                throw new StorageError.FAILED ("%s is not configured", key);
            }
            return line.substring (7, line.length - 8).replace ("'\\''", "'");
        }

        private void remove_tree (string path) throws Error {
            var file = File.new_for_path (path);
            var type = file.query_file_type (FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            if (type == FileType.DIRECTORY) {
                var children = file.enumerate_children (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? info;
                while ((info = children.next_file ()) != null) {
                    remove_tree (Path.build_filename (path, info.get_name ()));
                }
            }
            file.delete ();
        }

        private void clear_lists () throws Error {
            var lists = apt_directory ("Dir::State::lists");
            var trimmed = AptSources.strip_slash (lists);
            if (trimmed == "" || !clean_absolute (trimmed) || !FileUtils.test (lists, FileTest.IS_DIR)) {
                throw new StorageError.DENIED ("Unexpected lists directory %s", lists);
            }
            var lock_path = Path.build_filename (lists, "lock");
            var lock_fd = Posix.open (lock_path, Posix.O_RDWR | Posix.O_CREAT | Posix.O_NOFOLLOW | Posix.O_CLOEXEC, 0640);
            if (lock_fd < 0) {
                throw new StorageError.FAILED ("%s: %s", lock_path, strerror (errno));
            }
            var request = Posix.Flock ();
            request.l_type = Posix.F_WRLCK;
            request.l_whence = Posix.SEEK_SET;
            request.l_start = 0;
            request.l_len = 0;
            if (Posix.fcntl (lock_fd, Posix.F_SETLK, request) != 0) {
                Posix.close (lock_fd);
                throw new StorageError.FAILED ("The package lists are in use by another program. Close it and try again.");
            }
            string[] failures = {};
            try {
                var directory = Dir.open (lists);
                string? name;
                var names = new Gee.ArrayList<string> ();
                while ((name = directory.read_name ()) != null) {
                    names.add (name);
                }
                foreach (var entry in names) {
                    if (entry == "lock") {
                        continue;
                    }
                    try {
                        remove_tree (Path.build_filename (lists, entry));
                    } catch (Error e) {
                        failures += e.message;
                    }
                }
                var partial = Path.build_filename (lists, "partial");
                if (DirUtils.create_with_parents (partial, 0700) != 0
                    || FileUtils.test (partial, FileTest.IS_SYMLINK)
                    || !FileUtils.test (partial, FileTest.IS_DIR)
                    || FileUtils.chmod (partial, 0700) != 0) {
                    failures += "%s: could not be recreated".printf (partial);
                }
            } finally {
                Posix.close (lock_fd);
            }
            if (failures.length > 0) {
                throw new StorageError.FAILED ("%s", string.joinv ("\n", failures));
            }
        }

        private void start_apt (int64 id, Json.Object request) throws Error {
            var action = member (request, "action");
            var packages = string_list (request, "packages");
            string[] args = {};
            switch (action) {
                case "update":
                    args = { "update" };
                    break;
                case "remove":
                    if (packages.length == 0) {
                        throw new StorageError.DENIED ("No packages");
                    }
                    args = { "remove" };
                    foreach (var name in packages) {
                        if (!valid_package (name)) {
                            throw new StorageError.DENIED ("Invalid package name %s", name);
                        }
                        args += name;
                    }
                    break;
                case "downgrade":
                    if (packages.length == 0) {
                        throw new StorageError.DENIED ("No packages");
                    }
                    args = { "install", "--allow-downgrades" };
                    foreach (var spec in packages) {
                        if (!valid_package_version (spec)) {
                            throw new StorageError.DENIED ("Invalid package %s", spec);
                        }
                        args += spec;
                    }
                    break;
                default:
                    throw new StorageError.DENIED ("Unknown apt action %s", action);
            }
            busy = true;
            var command = new AptCommand (args, locale_environment (request));
            command.progress.connect ((percent, text) => {
                var object = new Json.Object ();
                object.set_int_member ("id", id);
                object.set_string_member ("event", "progress");
                object.set_double_member ("percent", percent);
                object.set_string_member ("text", text);
                send (object);
            });
            command.finished.connect ((success, errors) => {
                reply (id, success, success ? null : string.joinv ("\n", errors), null, errors);
                busy = false;
                Idle.add (() => {
                    process ();
                    return Source.REMOVE;
                });
            });
            command.run ();
        }
    }

    public int main (string[] args) {
        Posix.umask (0022);
        if (Posix.geteuid () != 0) {
            printerr ("menta-sources-helper: must run as root\n");
            return 1;
        }
        return new Server ().run ();
    }
}
