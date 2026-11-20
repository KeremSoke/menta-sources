namespace Menta {
    public class RepositorySource : Object {
        public AptSources.Entry entry;
        public string filename;
        public string name;
        public string ui_name;

        public RepositorySource (AptSources.Entry entry) {
            this.entry = entry;
            this.filename = entry.file != null ? entry.file.path : "";
            this.name = display_name (entry.uris[0]);
            var details = Markup.escape_text (entry.describe ());
            ui_name = "<b>%s</b>\n<small><i>%s\n%s</i></small>".printf (Markup.escape_text (name), details, Markup.escape_text (filename));
        }

        public static string display_name (string uri) {
            if (uri.has_prefix ("cdrom:")) {
                return _("CD-ROM (Installation Disc)");
            }
            if (uri.has_prefix ("file:")) {
                return _("Local Repository");
            }
            var position = uri.index_of ("://");
            if (position < 0) {
                return uri;
            }
            var rest = uri.substring (position + 3);
            var slash = rest.index_of ("/");
            var authority = slash >= 0 ? rest.substring (0, slash) : rest;
            var at = authority.last_index_of ("@");
            if (at >= 0) {
                authority = authority.substring (at + 1);
            }
            if (authority.has_prefix ("[")) {
                var close = authority.index_of ("]");
                return close > 0 ? authority.substring (1, close - 1) : authority;
            }
            var colon = authority.index_of (":");
            var host = colon >= 0 ? authority.substring (0, colon) : authority;
            if (host == "") {
                return uri;
            }
            if (Regex.match_simple ("^[0-9.]+$", host)) {
                return host;
            }
            var parts = host.split (".");
            var count = parts.length;
            if (count > 2 && (parts[count - 2] == "co" || parts[count - 2] == "com" || parts[count - 2] == "org" || parts[count - 2] == "net" || parts[count - 2] == "ac") && parts[count - 1].length == 2) {
                return capitalize (parts[count - 3]);
            }
            if (count >= 2) {
                return capitalize (parts[count - 2]);
            }
            return host;
        }

        private static string capitalize (string text) {
            if (text == "") {
                return text;
            }
            var first = text.get_char (0);
            var rest = text.substring (text.index_of_nth_char (1));
            return first.toupper ().to_string () + rest.down ();
        }

        public bool is_enabled () {
            return entry.enabled;
        }

        public void switch_state () throws Error {
            var previous = entry.enabled;
            entry.set_enabled (!previous);
            try {
                entry.file.save ();
            } catch (Error e) {
                entry.set_enabled (previous);
                throw e;
            }
        }

        public void delete () throws Error {
            entry.file.remove (entry);
            entry.file.save ();
        }
    }
}
