namespace Menta {
    public delegate void ProgressFunc (double percent, string description);
    public delegate void FinishedFunc (bool success, string[] errors);

    public class HelperReply : Object {
        public bool ok;
        public string error;
        public string result;
        public string[] errors;

        public HelperReply (bool ok, string error, string result, string[] errors) {
            this.ok = ok;
            this.error = error;
            this.result = result;
            this.errors = errors;
        }
    }

    private class PendingCall : Object {
        public MainLoop? loop = null;
        public HelperReply? reply = null;
        public ProgressFunc? on_progress = null;
        public FinishedFunc? on_finished = null;
    }

    public class Privileged : Object, Storage {
        private Subprocess? process = null;
        private DataInputStream? input = null;
        private OutputStream? output = null;
        private int64 next_id = 1;
        private Gee.HashMap<int64?, PendingCall> pending;
        private bool stopped = false;

        public Privileged () {
            pending = new Gee.HashMap<int64?, PendingCall> (
                (key) => int64_hash (key),
                (a, b) => int64_equal (a, b));
        }

        public bool start () throws Error {
            string[] argv;
            if (Posix.geteuid () == 0) {
                argv = { Config.HELPER_PATH };
            } else {
                argv = { "pkexec", Config.HELPER_PATH };
            }
            process = new Subprocess.newv (argv, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);
            input = new DataInputStream (process.get_stdout_pipe ());
            output = process.get_stdin_pipe ();
            while (true) {
                var line = input.read_line_utf8 (null);
                if (line == null) {
                    stopped = true;
                    return false;
                }
                var object = parse (line);
                if (object != null && object.has_member ("event") && object.get_string_member ("event") == "ready") {
                    break;
                }
            }
            read_next ();
            return true;
        }

        public void stop () {
            if (output != null) {
                try {
                    output.close ();
                } catch (Error e) {
                }
            }
        }

        private static Json.Object? parse (string line) {
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (line);
            } catch (Error e) {
                return null;
            }
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                return null;
            }
            return root.get_object ();
        }

        private void read_next () {
            input.read_line_utf8_async.begin (Priority.DEFAULT, null, (obj, res) => {
                string? line = null;
                try {
                    line = input.read_line_utf8_async.end (res);
                } catch (Error e) {
                    line = null;
                }
                if (line == null) {
                    helper_stopped ();
                    return;
                }
                var object = parse (line);
                if (object != null) {
                    dispatch (object);
                }
                read_next ();
            });
        }

        private void helper_stopped () {
            stopped = true;
            var calls = new Gee.ArrayList<int64?> ();
            calls.add_all (pending.keys);
            foreach (var id in calls) {
                PendingCall call;
                pending.unset (id, out call);
                complete (call, new HelperReply (false, _("The privileged helper stopped unexpectedly."), "", { _("The privileged helper stopped unexpectedly.") }));
            }
        }

        private void complete (PendingCall call, HelperReply reply) {
            call.reply = reply;
            if (call.loop != null) {
                call.loop.quit ();
            } else if (call.on_finished != null) {
                call.on_finished (reply.ok, reply.errors);
            }
        }

        private void dispatch (Json.Object object) {
            if (!object.has_member ("id")) {
                return;
            }
            var id = object.get_int_member ("id");
            var call = pending.get (id);
            if (call == null) {
                return;
            }
            var event = object.has_member ("event") ? object.get_string_member ("event") : "";
            if (event == "progress") {
                if (call.on_progress != null) {
                    call.on_progress (object.get_double_member ("percent"), object.get_string_member ("text") ?? "");
                }
                return;
            }
            if (event != "done") {
                return;
            }
            pending.unset (id);
            string[] errors = {};
            if (object.has_member ("errors")) {
                var array = object.get_array_member ("errors");
                for (uint i = 0; i < array.get_length (); i++) {
                    errors += array.get_string_element (i);
                }
            }
            var error = object.has_member ("error") ? (object.get_string_member ("error") ?? "") : "";
            if (errors.length == 0 && error != "") {
                errors = { error };
            }
            complete (call, new HelperReply (object.get_boolean_member ("ok"), error,
                                             object.has_member ("result") ? (object.get_string_member ("result") ?? "") : "",
                                             errors));
        }

        private int64 send (Json.Object request, PendingCall call) throws Error {
            if (stopped || output == null) {
                throw new StorageError.FAILED (_("The privileged helper is not running."));
            }
            var id = next_id++;
            request.set_int_member ("id", id);
            foreach (var name in new string[] { "LANG", "LANGUAGE", "LC_ALL", "LC_MESSAGES" }) {
                var value = Environment.get_variable (name);
                if (value != null && value != "") {
                    request.set_string_member (name, value);
                }
            }
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (request);
            var generator = new Json.Generator ();
            generator.set_root (node);
            pending.set (id, call);
            try {
                output.write_all ((generator.to_data (null) + "\n").data, null);
                output.flush ();
            } catch (Error e) {
                pending.unset (id);
                throw e;
            }
            return id;
        }

        public HelperReply call_sync (Json.Object request) throws Error {
            var call = new PendingCall ();
            call.loop = new MainLoop ();
            send (request, call);
            if (call.reply == null) {
                call.loop.run ();
            }
            return call.reply;
        }

        public void call_async (Json.Object request, owned ProgressFunc? on_progress, owned FinishedFunc on_finished) {
            var call = new PendingCall ();
            call.on_progress = (owned) on_progress;
            call.on_finished = (owned) on_finished;
            try {
                send (request, call);
            } catch (Error e) {
                var message = e.message;
                Idle.add (() => {
                    call.on_finished (false, { message });
                    return Source.REMOVE;
                });
            }
        }

        private HelperReply checked (Json.Object request) throws Error {
            var reply = call_sync (request);
            if (!reply.ok) {
                throw new StorageError.FAILED ("%s", reply.error != "" ? reply.error : string.joinv ("\n", reply.errors));
            }
            return reply;
        }

        public void write_file (string path, uint8[] data, int mode) throws Error {
            var request = new Json.Object ();
            request.set_string_member ("op", "write");
            request.set_string_member ("path", path);
            request.set_string_member ("data", Base64.encode (data));
            checked (request);
        }

        public void remove_file (string path) throws Error {
            var request = new Json.Object ();
            request.set_string_member ("op", "remove");
            request.set_string_member ("path", path);
            checked (request);
        }

        public string backup_file (string path, string backup_dir) throws Error {
            var request = new Json.Object ();
            request.set_string_member ("op", "backup");
            request.set_string_member ("path", path);
            return checked (request).result;
        }

        public void clear_lists () throws Error {
            var request = new Json.Object ();
            request.set_string_member ("op", "clear-lists");
            checked (request);
        }

        public HelperReply purge (string[] packages) throws Error {
            var request = new Json.Object ();
            request.set_string_member ("op", "purge");
            var array = new Json.Array ();
            foreach (var name in packages) {
                array.add_string_element (name);
            }
            request.set_array_member ("packages", array);
            return call_sync (request);
        }

        public void apt (string action, string[] packages, owned ProgressFunc on_progress, owned FinishedFunc on_finished) {
            var request = new Json.Object ();
            request.set_string_member ("op", "apt");
            request.set_string_member ("action", action);
            var array = new Json.Array ();
            foreach (var name in packages) {
                array.add_string_element (name);
            }
            request.set_array_member ("packages", array);
            call_async (request, (owned) on_progress, (owned) on_finished);
        }
    }
}
