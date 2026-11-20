namespace Menta {
    public const string[] DEBIAN_KEYRINGS = {
        "/usr/share/keyrings/debian-archive-keyring.gpg",
        "/usr/share/keyrings/debian-archive-removed-keys.gpg"
    };

    public class ScannedKey : Object {
        public string fingerprint;
        public bool secret = false;
        public Gee.ArrayList<string> uids = new Gee.ArrayList<string> ();

        public ScannedKey (string fingerprint) {
            this.fingerprint = fingerprint;
        }
    }

    public string format_fingerprint (string fingerprint) {
        string[] groups = {};
        for (int i = 0; i < fingerprint.length; i += 4) {
            groups += fingerprint.substring (i, int.min (4, fingerprint.length - i));
        }
        var first = groups.length > 5 ? groups[0:5] : groups;
        var rest = groups.length > 5 ? groups[5:groups.length] : new string[] {};
        return "%s  %s".printf (string.joinv (" ", first), string.joinv (" ", rest));
    }

    public string bytes_to_string (Bytes? bytes) {
        if (bytes == null || bytes.get_size () == 0) {
            return "";
        }
        var buffer = new uint8[bytes.get_size () + 1];
        Memory.copy (buffer, bytes.get_data (), bytes.get_size ());
        buffer[bytes.get_size ()] = 0;
        return ((string) buffer).make_valid ((ssize_t) bytes.get_size ());
    }

    public class GpgHome : Object {
        public string path;

        public GpgHome () throws Error {
            path = DirUtils.make_tmp ("menta-sources-XXXXXX");
            if (Environment.get_variable ("http_proxy") != null && Environment.get_variable ("http_proxy") != "") {
                FileUtils.set_contents (Path.build_filename (path, "dirmngr.conf"), "honor-http-proxy\n");
            }
        }

        public int last_status = 0;

        private bool may_have_daemons = false;

        ~GpgHome () {
            if (may_have_daemons) {
                try {
                    var process = new Subprocess.newv ({ "gpgconf", "--homedir", path, "--kill", "all" }, SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
                    process.wait (null);
                } catch (Error e) {
                }
                terminate_daemons ();
                try {
                    var process = new Subprocess.newv ({ "gpgconf", "--homedir", path, "--remove-socketdir" }, SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
                    process.wait (null);
                } catch (Error e) {
                }
            }
            remove_tree (path);
        }

        private void terminate_daemons () {
            var pids = daemon_pids ();
            if (pids.size == 0) {
                return;
            }
            foreach (var pid in pids) {
                Posix.kill ((Posix.pid_t) pid, Posix.Signal.TERM);
            }
            for (int i = 0; i < 10 && daemon_pids ().size > 0; i++) {
                Thread.usleep (100000);
            }
            foreach (var pid in daemon_pids ()) {
                Posix.kill ((Posix.pid_t) pid, Posix.Signal.KILL);
            }
        }

        private Gee.ArrayList<int> daemon_pids () {
            var result = new Gee.ArrayList<int> ();
            var uid = Posix.getuid ();
            try {
                var proc = Dir.open ("/proc");
                string? name;
                while ((name = proc.read_name ()) != null) {
                    if (!Regex.match_simple ("^[0-9]+$", name)) {
                        continue;
                    }
                    Posix.Stat info;
                    if (Posix.stat ("/proc/" + name, out info) != 0 || info.st_uid != uid) {
                        continue;
                    }
                    uint8[] data;
                    try {
                        FileUtils.get_data ("/proc/%s/cmdline".printf (name), out data);
                    } catch (FileError e) {
                        continue;
                    }
                    string[] args = {};
                    var current = new StringBuilder ();
                    foreach (var b in data) {
                        if (b == 0) {
                            args += current.str;
                            current = new StringBuilder ();
                        } else {
                            current.append_c ((char) b);
                        }
                    }
                    for (int i = 0; i + 1 < args.length; i++) {
                        if (args[i] == "--homedir" && args[i + 1] == path) {
                            result.add (int.parse (name));
                            break;
                        }
                    }
                }
            } catch (FileError e) {
            }
            return result;
        }

        private static void remove_tree (string directory) {
            try {
                var dir = Dir.open (directory);
                string? name;
                while ((name = dir.read_name ()) != null) {
                    var child = Path.build_filename (directory, name);
                    if (FileUtils.test (child, FileTest.IS_DIR) && !FileUtils.test (child, FileTest.IS_SYMLINK)) {
                        remove_tree (child);
                    } else {
                        FileUtils.unlink (child);
                    }
                }
            } catch (FileError e) {
            }
            DirUtils.remove (directory);
        }

        public string[] command (string[] args) {
            string[] argv = { "gpg", "--homedir", path, "--batch", "--no-tty", "--quiet" };
            foreach (var arg in args) {
                argv += arg;
            }
            return argv;
        }

        public bool run (string[] args, out string stdout_text, out string stderr_text, out Bytes? stdout_bytes = null, int timeout_seconds = 0) {
            foreach (var arg in args) {
                if (arg == "--recv-keys" || arg == "--import" || arg.has_prefix ("--delete-") || arg == "--verify") {
                    may_have_daemons = true;
                }
            }
            stdout_text = "";
            stderr_text = "";
            stdout_bytes = null;
            try {
                var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
                launcher.setenv ("LC_ALL", "C", true);
                string[] argv = {};
                if (timeout_seconds > 0) {
                    argv = { "timeout", "--kill-after=5", timeout_seconds.to_string () };
                }
                foreach (var item in command (args)) {
                    argv += item;
                }
                var process = launcher.spawnv (argv);
                Bytes out_bytes;
                Bytes err_bytes;
                process.communicate (null, null, out out_bytes, out err_bytes);
                last_status = process.get_if_exited () ? process.get_exit_status () : 128 + process.get_term_sig ();
                stdout_bytes = out_bytes;
                stdout_text = bytes_to_string (out_bytes);
                stderr_text = bytes_to_string (err_bytes);
                return process.get_if_exited () && process.get_exit_status () == 0;
            } catch (Error e) {
                stderr_text = e.message;
                return false;
            }
        }

        private static string unescape (string text) {
            var bytes = new ByteArray ();
            int i = 0;
            while (i < text.length) {
                if (text[i] == '\\' && i + 3 < text.length && text[i + 1] == 'x' && text[i + 2].isxdigit () && text[i + 3].isxdigit ()) {
                    bytes.append ({ (uint8) (text[i + 2].xdigit_value () * 16 + text[i + 3].xdigit_value ()) });
                    i += 4;
                } else {
                    bytes.append ({ (uint8) text[i] });
                    i++;
                }
            }
            bytes.append ({ 0 });
            return ((string) bytes.data).make_valid ();
        }

        public static Gee.ArrayList<ScannedKey> parse_colons (string output) {
            var keys = new Gee.ArrayList<ScannedKey> ();
            ScannedKey? current = null;
            bool want_fingerprint = false;
            bool current_secret = false;
            foreach (var line in output.split ("\n")) {
                var fields = line.split (":");
                if (fields.length < 2) {
                    continue;
                }
                switch (fields[0]) {
                    case "pub":
                    case "sec":
                        current = null;
                        want_fingerprint = true;
                        current_secret = fields[0] == "sec";
                        break;
                    case "sub":
                    case "ssb":
                        want_fingerprint = false;
                        break;
                    case "fpr":
                        if (want_fingerprint && fields.length > 9) {
                            current = new ScannedKey (fields[9]);
                            current.secret = current_secret;
                            keys.add (current);
                            want_fingerprint = false;
                        }
                        break;
                    case "uid":
                        if (current != null && fields.length > 9) {
                            current.uids.add (unescape (fields[9]));
                        }
                        break;
                }
            }
            return keys;
        }

        public Gee.ArrayList<ScannedKey> show_keys (string file) {
            string output;
            string errors;
            run ({ "--with-colons", "--fixed-list-mode", "--with-fingerprint", "--show-keys", file }, out output, out errors);
            var keys = parse_colons (output);
            foreach (var key in keys) {
                if (key.secret) {
                    may_have_daemons = true;
                }
            }
            return keys;
        }

        public Gee.ArrayList<ScannedKey> list_keys () {
            string output;
            string errors;
            run ({ "--with-colons", "--fixed-list-mode", "--with-fingerprint", "--list-keys" }, out output, out errors);
            return parse_colons (output);
        }

        public bool import_file (string file) {
            string output;
            string errors;
            return run ({ "--import", file }, out output, out errors) || list_keys ().size > 0;
        }

        public Bytes? export (string[] fingerprints, bool armor) {
            string[] args = {};
            if (armor) {
                args += "--armor";
            }
            args += "--export";
            foreach (var fingerprint in fingerprints) {
                args += fingerprint;
            }
            string output;
            string errors;
            Bytes? data;
            if (!run (args, out output, out errors, out data) || data == null || data.get_size () == 0) {
                return null;
            }
            return data;
        }
    }

    public Gee.ArrayList<ScannedKey> scan_keyring (string path) {
        try {
            var home = new GpgHome ();
            return home.show_keys (path);
        } catch (Error e) {
            warning ("Could not read keyring %s: %s", path, e.message);
            return new Gee.ArrayList<ScannedKey> ();
        }
    }

    public string? normalize_fingerprint (string input) {
        var text = input.replace (" ", "").replace ("\t", "").strip ().up ();
        if (text.has_prefix ("0X")) {
            text = text.substring (2);
        }
        if ((text.length == 40 || text.length == 64) && Regex.match_simple ("^[0-9A-F]+$", text)) {
            return text;
        }
        return null;
    }

    public Bytes? fetch_remote_key (string fingerprint, string keyserver, bool armor, out string error_text, out string received = null) {
        error_text = "";
        received = fingerprint;
        try {
            var home = new GpgHome ();
            string output;
            Bytes? ignored;
            var ok = home.run ({ "--keyserver", keyserver, "--recv-keys", fingerprint }, out output, out error_text, out ignored, 60);
            var wanted = fingerprint.replace (" ", "").up ();
            if (wanted.has_prefix ("0X")) {
                wanted = wanted.substring (2);
            }
            ScannedKey? found = null;
            foreach (var key in home.list_keys ()) {
                if (key.fingerprint.up ().has_suffix (wanted)) {
                    found = key;
                    break;
                }
            }
            if (found == null) {
                if (home.last_status == 124 || home.last_status == 137 || error_text.strip () == "") {
                    error_text = "the keyserver did not answer";
                } else if (ok) {
                    error_text = "the keyserver did not return the requested key";
                }
                return null;
            }
            received = found.fingerprint;
            var data = home.export ({ found.fingerprint }, armor);
            if (data == null) {
                error_text = "no key exported";
            }
            return data;
        } catch (Error e) {
            error_text = e.message;
            return null;
        }
    }

    public string remote_key_path (string fingerprint) {
        try {
            return "/etc/apt/trusted.gpg.d/%s.gpg".printf (new Regex ("[^A-Za-z0-9]").replace (fingerprint, -1, 0, ""));
        } catch (RegexError e) {
            return "/etc/apt/trusted.gpg.d/%s.gpg".printf (fingerprint);
        }
    }

    public bool add_remote_key (string fingerprint, string keyserver, string? path = null) {
        string error_text;
        string received;
        var data = fetch_remote_key (fingerprint, keyserver, path != null && path.has_suffix (".asc"), out error_text, out received);
        if (data == null) {
            printerr ("E: Could not download key %s: %s\n", fingerprint, error_text.strip ());
            return false;
        }
        try {
            Files.storage ().write_file (path ?? remote_key_path (received), data.get_data (), 0644);
        } catch (Error e) {
            printerr ("E: Could not download key %s: %s\n", fingerprint, e.message);
            return false;
        }
        return true;
    }

    public Bytes? prepare_local_key (string filename, out string key_path) throws Error {
        key_path = "";
        var home = new GpgHome ();
        if (home.show_keys (filename).size == 0) {
            return null;
        }
        home.import_file (filename);
        var imported = home.list_keys ();
        if (imported.size == 0) {
            return null;
        }
        string[] fingerprints = {};
        foreach (var key in imported) {
            fingerprints += key.fingerprint;
        }
        var data = home.export (fingerprints, false);
        if (data == null) {
            return null;
        }
        key_path = "/etc/apt/trusted.gpg.d/%s.gpg".printf (imported[0].fingerprint);
        return data;
    }

    public string? add_local_key (string filename) throws Error {
        string key_path;
        var data = prepare_local_key (filename, out key_path);
        if (data == null) {
            return null;
        }
        Files.storage ().write_file (key_path, data.get_data (), 0644);
        return key_path;
    }

    public class Key : Object {
        public string pub;
        public string fingerprint;
        public string uid;
        public Gee.ArrayList<string> paths = new Gee.ArrayList<string> ();
        public bool removable;
        public Gee.ArrayList<string> sources = new Gee.ArrayList<string> ();

        public Key (string fingerprint, string uid, string path, bool removable, Gee.Collection<string> sources) {
            this.fingerprint = fingerprint;
            this.pub = format_fingerprint (fingerprint);
            this.uid = uid;
            this.paths.add (path);
            this.removable = removable;
            this.sources.add_all (sources);
        }

        public void delete () throws Error {
            foreach (var path in paths) {
                var armored = path.has_suffix (".asc");
                var home = new GpgHome ();
                var secret = new Gee.HashSet<string> ();
                foreach (var key in home.show_keys (path)) {
                    if (key.secret) {
                        secret.add (key.fingerprint.up ());
                    }
                }
                home.import_file (path);
                string output;
                string errors;
                home.run ({ "--yes", "--delete-secret-and-public-keys", fingerprint }, out output, out errors);
                home.run ({ "--yes", "--delete-keys", fingerprint }, out output, out errors);
                string[] remaining = {};
                foreach (var key in home.list_keys ()) {
                    if (key.fingerprint.up () == fingerprint.up ()) {
                        throw new StorageError.FAILED ("%s: the key %s could not be removed", path, fingerprint);
                    }
                    if (!secret.contains (key.fingerprint.up ())) {
                        remaining += key.fingerprint;
                    }
                }
                Bytes? data = remaining.length > 0 ? home.export (remaining, armored) : null;
                if (data != null) {
                    Files.storage ().write_file (path, data.get_data (), 0644);
                } else {
                    Files.storage ().remove_file (path);
                }
            }
        }

        public string markup () {
            var builder = new StringBuilder (Markup.escape_text (uid));
            var details = new Gee.ArrayList<string> ();
            details.add (pub);
            details.add_all (paths);
            if (sources.size > 0) {
                var unique = new Gee.TreeSet<string> ();
                unique.add_all (sources);
                details.add (_("Used by: %s").printf (string.joinv (", ", unique.to_array ())));
            }
            foreach (var detail in details) {
                builder.append ("\n<small>    %s</small>".printf (Markup.escape_text (detail)));
            }
            return builder.str;
        }
    }
}
