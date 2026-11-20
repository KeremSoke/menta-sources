namespace Menta.Helper {
    public class AptCommand : Object {
        public signal void progress (double percent, string description);
        public signal void finished (bool success, string[] errors);

        private string[] args;
        private string[] environment;
        private int pending = 0;
        private string stdout_text = "";
        private string stderr_text = "";
        private Subprocess? process = null;

        public AptCommand (string[] args, string[] environment) {
            this.args = args;
            this.environment = environment;
        }

        public void run () {
            int fds[2];
            try {
                if (!Unix.open_pipe (fds, Posix.FD_CLOEXEC)) {
                    throw new IOError.FAILED ("pipe: %s", strerror (errno));
                }
            } catch (Error e) {
                var message = e.message;
                Idle.add (() => {
                    finished (false, { message });
                    return Source.REMOVE;
                });
                return;
            }
            string[] argv = {
                "apt-get", "--quiet", "--yes",
                "-o", "APT::Status-Fd=3",
                "-o", "Dpkg::Options::=--force-confdef",
                "-o", "Dpkg::Options::=--force-confold"
            };
            foreach (var arg in args) {
                argv += arg;
            }
            try {
                var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
                launcher.setenv ("DEBIAN_FRONTEND", "noninteractive", true);
                launcher.setenv ("APT_LISTCHANGES_FRONTEND", "none", true);
                foreach (var item in environment) {
                    var position = item.index_of ("=");
                    launcher.setenv (item.substring (0, position), item.substring (position + 1), true);
                }
                launcher.take_fd (fds[1], 3);
                fds[1] = -1;
                process = launcher.spawnv (argv);
                launcher.close ();
            } catch (Error e) {
                Posix.close (fds[0]);
                if (fds[1] >= 0) {
                    Posix.close (fds[1]);
                }
                var message = e.message;
                Idle.add (() => {
                    finished (false, { message });
                    return Source.REMOVE;
                });
                return;
            }
            pending = 2;
            read_status.begin (new DataInputStream (new UnixInputStream (fds[0], true)));
            wait_process.begin ();
        }

        private async void read_status (DataInputStream status) {
            while (true) {
                string? line = null;
                try {
                    line = yield status.read_line_utf8_async (Priority.DEFAULT, null);
                } catch (Error e) {
                    line = null;
                }
                if (line == null) {
                    break;
                }
                var fields = line.split (":", 4);
                if (fields.length == 4 && (fields[0] == "dlstatus" || fields[0] == "pmstatus")) {
                    double percent;
                    if (double.try_parse (fields[2], out percent)) {
                        progress (percent, fields[3]);
                    }
                }
            }
            try {
                status.close ();
            } catch (Error e) {
            }
            complete_part ();
        }

        private async void wait_process () {
            try {
                Bytes out_bytes;
                Bytes err_bytes;
                yield process.communicate_async (null, null, out out_bytes, out err_bytes);
                stdout_text = bytes_text (out_bytes);
                stderr_text = bytes_text (err_bytes);
                yield process.wait_async (null);
            } catch (Error e) {
                stderr_text += e.message;
            }
            complete_part ();
        }

        private void complete_part () {
            pending--;
            if (pending > 0) {
                return;
            }
            string[] errors = {};
            foreach (var line in stderr_text.split ("\n")) {
                if (line.has_prefix ("E:") || line.has_prefix ("W:") || line.has_prefix ("Err:")) {
                    errors += line;
                }
            }
            foreach (var line in stdout_text.split ("\n")) {
                if (line.has_prefix ("Err:")) {
                    errors += line;
                }
            }
            var status = process.get_if_exited () ? process.get_exit_status () : 128 + process.get_term_sig ();
            if (status != 0 && errors.length == 0) {
                string[] lines = {};
                foreach (var line in stderr_text.strip ().split ("\n")) {
                    if (line.strip () != "") {
                        lines += line;
                    }
                }
                if (lines.length > 5) {
                    lines = lines[lines.length - 5:lines.length];
                }
                errors = lines.length > 0 ? lines : new string[] { "apt-get exited with status %d".printf (status) };
            }
            finished (status == 0, errors);
        }
    }
}
