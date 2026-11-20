namespace Menta.AptSources {
    public const string SOURCES_LIST = "/etc/apt/sources.list";
    public const string SOURCES_PARTS = "/etc/apt/sources.list.d";
    public const string ADDITIONAL_REPOSITORIES = "/etc/apt/sources.list.d/additional-repositories.list";

    public enum Format {
        LEGACY,
        DEB822
    }

    public unowned string main_list = SOURCES_LIST;

    private Regex? valid_part_regex = null;
    private Regex? legacy_line_regex = null;
    private Regex? deb822_field_regex = null;

    private Regex valid_part () {
        if (valid_part_regex == null) {
            try {
                valid_part_regex = new Regex ("^[A-Za-z0-9_.-]+\\.(list|sources)$", RegexCompileFlags.DOLLAR_ENDONLY);
            } catch (RegexError e) {
                error ("%s", e.message);
            }
        }
        return valid_part_regex;
    }

    private Regex legacy_line () {
        if (legacy_line_regex == null) {
            try {
                legacy_line_regex = new Regex ("""
                    ^\s*(?P<disabled>\#\s*)?
                    (?P<type>deb|deb-src)\s+
                    (?:\[(?P<options>[^\]]*)\]\s+)?
                    (?P<uri>cdrom:\[[^\]]*\]/?\S*|[a-z][a-z0-9+.-]*:\S+)\s+
                    (?P<suite>[^\s\#]+)
                    (?P<components>(?:[ \t]+[^\s\#]+)*)
                    \s*(?:\#.*)?$
                    """, RegexCompileFlags.EXTENDED);
            } catch (RegexError e) {
                error ("%s", e.message);
            }
        }
        return legacy_line_regex;
    }

    private Regex deb822_field () {
        if (deb822_field_regex == null) {
            try {
                deb822_field_regex = new Regex ("^(?P<key>[^\\s:#][^\\s:]*)\\s*:\\s*(?P<value>.*)$");
            } catch (RegexError e) {
                error ("%s", e.message);
            }
        }
        return deb822_field_regex;
    }

    public string strip_slash (string uri) {
        var result = uri;
        while (result.has_suffix ("/")) {
            result = result.substring (0, result.length - 1);
        }
        return result;
    }

    public string[] split_words (string? text) {
        string[] words = {};
        if (text == null) {
            return words;
        }
        foreach (var word in Regex.split_simple ("\\s+", text.strip ())) {
            if (word != "") {
                words += word;
            }
        }
        return words;
    }

    public bool contains (string[] list, string value) {
        foreach (var item in list) {
            if (item == value) {
                return true;
            }
        }
        return false;
    }

    public string[] split_lines (string content) {
        var normalized = content.replace ("\r\n", "\n").replace ("\r", "\n");
        string[] lines = normalized.split ("\n");
        if (lines.length > 0 && lines[lines.length - 1] == "") {
            lines = lines[0:lines.length - 1];
        }
        return lines;
    }

    private string strip_char (string text, char c) {
        int start = 0;
        int end = text.length;
        while (start < end && text[start] == c) {
            start++;
        }
        while (end > start && text[end - 1] == c) {
            end--;
        }
        return text.substring (start, end - start);
    }

    public class RawText : Object {
        public string text;

        public RawText (string text) {
            this.text = text;
        }
    }

    public abstract class Entry : Object {
        public weak SourceFile? file;
        public string[] types;
        public string[] uris;
        public string[] suites;
        public string[] components;
        public Gee.HashMap<string, string> options;
        public bool enabled;

        protected Entry (SourceFile? file, string[] types, string[] uris, string[] suites, string[] components, Gee.HashMap<string, string> options, bool enabled) {
            this.file = file;
            this.types = types;
            this.uris = uris;
            this.suites = suites;
            this.components = components;
            this.options = options;
            this.enabled = enabled;
        }

        public string? signed_by {
            owned get {
                var value = options.get ("signed-by");
                if (value == null || value == "" || "\n" in value || "BEGIN PGP" in value) {
                    return null;
                }
                foreach (var item in Regex.split_simple ("[\\s,]+", value)) {
                    if (item.has_prefix ("/")) {
                        return item;
                    }
                }
                return null;
            }
        }

        public abstract void set_enabled (bool enabled);

        public abstract string text ();

        public Gee.HashSet<string> expand () {
            var result = new Gee.HashSet<string> ();
            string[] parts = components.length > 0 ? components : new string[] { "" };
            foreach (var type in types) {
                foreach (var uri in uris) {
                    foreach (var suite in suites) {
                        foreach (var component in parts) {
                            result.add (string.join ("\t", type, strip_slash (uri), suite, component));
                        }
                    }
                }
            }
            return result;
        }

        public bool matches (Entry other) {
            var mine = expand ();
            var theirs = other.expand ();
            return mine.size == theirs.size && mine.contains_all (theirs);
        }

        public string describe () {
            return "%s %s %s %s".printf (string.joinv (" ", types), string.joinv (" ", uris), string.joinv (" ", suites), string.joinv (" ", components)).strip ();
        }
    }

    public class LegacyEntry : Entry {
        public string line;

        private LegacyEntry (SourceFile? file, string line, string[] types, string[] uris, string[] suites, string[] components, Gee.HashMap<string, string> options, bool enabled) {
            base (file, types, uris, suites, components, options, enabled);
            this.line = line;
        }

        public static LegacyEntry? parse (SourceFile? file, string line) {
            MatchInfo match;
            if (!legacy_line ().match (line, 0, out match)) {
                return null;
            }
            var options = new Gee.HashMap<string, string> ();
            foreach (var option in split_words (match.fetch_named ("options"))) {
                var position = option.index_of ("=");
                if (position < 0) {
                    options.set (option.down (), "");
                } else {
                    options.set (option.substring (0, position).down (), option.substring (position + 1));
                }
            }
            var disabled = match.fetch_named ("disabled");
            return new LegacyEntry (file, line,
                                    { match.fetch_named ("type") },
                                    { match.fetch_named ("uri") },
                                    { match.fetch_named ("suite") },
                                    split_words (match.fetch_named ("components")),
                                    options,
                                    disabled == null || disabled == "");
        }

        public override void set_enabled (bool enabled) {
            if (enabled == this.enabled) {
                return;
            }
            this.enabled = enabled;
            if (enabled) {
                try {
                    line = new Regex ("^\\s*#\\s*").replace (line, -1, 0, "", RegexMatchFlags.ANCHORED);
                } catch (RegexError e) {
                    warning ("%s", e.message);
                }
            } else {
                line = "# " + line.chug ();
            }
        }

        public override string text () {
            return line;
        }
    }

    public class Deb822Entry : Entry {
        public string[] lines;

        private static bool is_disabled_value (string value) {
            var normalized = value.strip ().down ();
            return normalized == "no" || normalized == "false" || normalized == "without" || normalized == "off" || normalized == "0";
        }

        private Deb822Entry (SourceFile? file, string[] lines, Gee.HashMap<string, string> fields) {
            var options = new Gee.HashMap<string, string> ();
            foreach (var item in fields.entries) {
                if (item.key != "types" && item.key != "uris" && item.key != "suites" && item.key != "components" && item.key != "enabled") {
                    options.set (item.key, item.value);
                }
            }
            base (file,
                  split_words (fields.get ("types")),
                  split_words (fields.get ("uris")),
                  split_words (fields.get ("suites")),
                  split_words (fields.get ("components")),
                  options,
                  !fields.has_key ("enabled") || !is_disabled_value (fields.get ("enabled")));
            this.lines = lines;
        }

        public static Deb822Entry? parse (SourceFile? file, string[] lines) {
            var fields = new Gee.HashMap<string, string> ();
            string? key = null;
            foreach (var line in lines) {
                if (line.has_prefix ("#")) {
                    continue;
                }
                if ((line.has_prefix (" ") || line.has_prefix ("\t")) && key != null) {
                    fields.set (key, fields.get (key) + "\n" + line.strip ());
                    continue;
                }
                MatchInfo match;
                if (!deb822_field ().match (line, 0, out match)) {
                    key = null;
                    continue;
                }
                key = match.fetch_named ("key").down ();
                fields.set (key, match.fetch_named ("value").strip ());
            }
            if (split_words (fields.get ("types")).length == 0 || split_words (fields.get ("uris")).length == 0 || split_words (fields.get ("suites")).length == 0) {
                return null;
            }
            return new Deb822Entry (file, lines, fields);
        }

        public override void set_enabled (bool enabled) {
            if (enabled == this.enabled) {
                return;
            }
            this.enabled = enabled;
            Regex enabled_field;
            Regex types_field;
            try {
                enabled_field = new Regex ("^enabled\\s*:", RegexCompileFlags.CASELESS);
                types_field = new Regex ("^types\\s*:", RegexCompileFlags.CASELESS);
            } catch (RegexError e) {
                warning ("%s", e.message);
                return;
            }
            string[] kept = {};
            foreach (var line in lines) {
                if (!enabled_field.match (line)) {
                    kept += line;
                }
            }
            if (!enabled) {
                int position = 0;
                for (int i = 0; i < kept.length; i++) {
                    if (types_field.match (kept[i])) {
                        position = i + 1;
                        break;
                    }
                }
                string[] result = {};
                for (int i = 0; i < kept.length; i++) {
                    if (i == position) {
                        result += "Enabled: no";
                    }
                    result += kept[i];
                }
                if (position >= kept.length) {
                    result += "Enabled: no";
                }
                kept = result;
            }
            lines = kept;
        }

        public override string text () {
            return string.joinv ("\n", lines);
        }
    }

    public class SourceFile : Object {
        public string path;
        public Format format;
        public Gee.ArrayList<Object> items;
        public string? load_error = null;

        public SourceFile (string path) {
            this.path = path;
            this.format = path.has_suffix (".sources") ? Format.DEB822 : Format.LEGACY;
            this.items = new Gee.ArrayList<Object> ();
        }

        public string name {
            owned get {
                var basename = Path.get_basename (path);
                var dot = basename.last_index_of (".");
                return dot > 0 ? basename.substring (0, dot) : basename;
            }
        }

        public Gee.ArrayList<Entry> entries {
            owned get {
                var result = new Gee.ArrayList<Entry> ();
                foreach (var item in items) {
                    if (item is Entry) {
                        result.add ((Entry) item);
                    }
                }
                return result;
            }
        }

        public SourceFile load () {
            items.clear ();
            load_error = null;
            if (!FileUtils.test (path, FileTest.EXISTS)) {
                return this;
            }
            string content;
            try {
                content = Files.read_text (path);
            } catch (Error e) {
                load_error = e.message;
                printerr ("W: %s\n", e.message);
                return this;
            }
            if (format == Format.LEGACY) {
                foreach (var line in split_lines (content)) {
                    var entry = LegacyEntry.parse (this, line);
                    if (entry != null) {
                        items.add (entry);
                    } else {
                        items.add (new RawText (line));
                    }
                }
            } else {
                var normalized = content.replace ("\r\n", "\n").replace ("\r", "\n");
                string[] paragraphs;
                try {
                    paragraphs = new Regex ("\n[ \t]*\n").split (strip_char (normalized, '\n'));
                } catch (RegexError e) {
                    warning ("%s", e.message);
                    return this;
                }
                foreach (var paragraph in paragraphs) {
                    var trimmed = strip_char (paragraph, '\n');
                    var entry = Deb822Entry.parse (this, trimmed.split ("\n"));
                    if (entry != null) {
                        items.add (entry);
                    } else {
                        items.add (new RawText (trimmed));
                    }
                }
            }
            return this;
        }

        public string text () {
            var parts = new Gee.ArrayList<string> ();
            foreach (var item in items) {
                parts.add ((item is Entry) ? ((Entry) item).text () : ((RawText) item).text);
            }
            var builder = new StringBuilder ();
            if (format == Format.LEGACY) {
                bool first = true;
                foreach (var part in parts) {
                    if (!first) {
                        builder.append ("\n");
                    }
                    builder.append (part);
                    first = false;
                }
            } else {
                bool first = true;
                foreach (var part in parts) {
                    if (part.strip () == "") {
                        continue;
                    }
                    if (!first) {
                        builder.append ("\n\n");
                    }
                    builder.append (part);
                    first = false;
                }
            }
            builder.append ("\n");
            return builder.str;
        }

        public void save () throws Error {
            if (load_error != null) {
                throw new StorageError.FAILED ("%s", load_error);
            }
            if (entries.size == 0 && path != main_list) {
                if (FileUtils.test (path, FileTest.EXISTS)) {
                    Files.storage ().remove_file (path);
                }
                return;
            }
            Files.storage ().write_file (path, text ().data, 0644);
        }

        public LegacyEntry add_line (string line) throws Error {
            var entry = LegacyEntry.parse (this, line);
            if (entry == null) {
                throw new StorageError.FAILED ("%s", line);
            }
            items.add (entry);
            return entry;
        }

        public void remove (Entry entry) {
            items.remove (entry);
        }

        public void replace_with_text (string text) {
            items.clear ();
            items.add (new RawText (text));
        }
    }

    public Gee.ArrayList<string> source_file_paths (string? sources_list = null, string? parts_dir = null) {
        var list = sources_list ?? SOURCES_LIST;
        var parts = parts_dir ?? SOURCES_PARTS;
        var paths = new Gee.ArrayList<string> ();
        if (FileUtils.test (list, FileTest.IS_REGULAR)) {
            paths.add (list);
        }
        if (FileUtils.test (parts, FileTest.IS_DIR)) {
            var names = new Gee.ArrayList<string> ();
            try {
                var directory = Dir.open (parts);
                string? name;
                while ((name = directory.read_name ()) != null) {
                    names.add (name);
                }
            } catch (FileError e) {
                warning ("%s", e.message);
            }
            names.sort ((a, b) => strcmp (a, b));
            foreach (var name in names) {
                var path = Path.build_filename (parts, name);
                if (valid_part ().match (name) && FileUtils.test (path, FileTest.IS_REGULAR)) {
                    paths.add (path);
                }
            }
        }
        return paths;
    }

    public Gee.ArrayList<SourceFile> load_files (string? sources_list = null, string? parts_dir = null) {
        var files = new Gee.ArrayList<SourceFile> ();
        foreach (var path in source_file_paths (sources_list, parts_dir)) {
            files.add (new SourceFile (path).load ());
        }
        return files;
    }

    public Gee.ArrayList<Entry> all_entries (Gee.List<SourceFile> files) {
        var result = new Gee.ArrayList<Entry> ();
        foreach (var file in files) {
            result.add_all (file.entries);
        }
        return result;
    }

    public string? repo_key_path (string uri, Gee.List<Entry> entries) {
        var wanted = strip_slash (uri);
        foreach (var entry in entries) {
            if (!entry.enabled || entry.signed_by == null) {
                continue;
            }
            foreach (var candidate in entry.uris) {
                if (strip_slash (candidate) == wanted) {
                    return entry.signed_by;
                }
            }
        }
        return null;
    }

    public string expand_http_line (string line, string codename) {
        if (!line.has_prefix ("http")) {
            return line;
        }
        var pieces = split_words (line);
        var components = pieces.length > 1 ? string.joinv (" ", pieces[1:pieces.length]) : "main";
        return "deb %s %s %s".printf (pieces[0], codename, components);
    }

    public string unicode_strip (string text) {
        int start = 0;
        unichar c;
        int index = 0;
        int first_content = -1;
        int last_content_end = 0;
        while (text.get_next_char (ref index, out c)) {
            if (!(c.isspace () || c == 0x0B || c == 0xFEFF || c == 0x200B)) {
                if (first_content < 0) {
                    first_content = start;
                }
                last_content_end = index;
            }
            start = index;
        }
        if (first_content < 0) {
            return "";
        }
        return text.substring (first_content, last_content_end - first_content);
    }

    public bool repo_malformed (string line) {
        if ("\n" in line || "\r" in line) {
            return true;
        }
        MatchInfo match;
        if (!legacy_line ().match (line, 0, out match)) {
            return true;
        }
        var disabled = match.fetch_named ("disabled");
        return disabled != null && disabled != "";
    }

    public bool repo_exists (string line, Gee.List<Entry> entries) {
        var wanted = LegacyEntry.parse (null, line);
        if (wanted == null) {
            return false;
        }
        var known = new Gee.HashSet<string> ();
        foreach (var entry in entries) {
            known.add_all (entry.expand ());
        }
        return known.contains_all (wanted.expand ());
    }

    public Gee.ArrayList<Entry> find_entries (string line, Gee.List<SourceFile> files) {
        var result = new Gee.ArrayList<Entry> ();
        var wanted = LegacyEntry.parse (null, line);
        if (wanted == null) {
            return result;
        }
        foreach (var entry in all_entries (files)) {
            if (entry.matches (wanted)) {
                result.add (entry);
            }
        }
        return result;
    }

    public Gee.ArrayList<SourceFile> remove_duplicates_keeping (Gee.List<SourceFile> files, string official_path) {
        var ordered = new Gee.ArrayList<SourceFile> ();
        foreach (var file in files) {
            if (file.path == official_path) {
                ordered.add (file);
            }
        }
        foreach (var file in files) {
            if (file.path != official_path) {
                ordered.add (file);
            }
        }
        return remove_duplicates (ordered);
    }

    public Gee.ArrayList<SourceFile> remove_duplicates (Gee.List<SourceFile> files) {
        var known = new Gee.HashSet<string> ();
        var modified = new Gee.ArrayList<SourceFile> ();
        foreach (var file in files) {
            foreach (var entry in file.entries) {
                if (!entry.enabled) {
                    continue;
                }
                var provided = entry.expand ();
                if (known.contains_all (provided)) {
                    file.remove (entry);
                    if (!modified.contains (file)) {
                        modified.add (file);
                    }
                } else {
                    known.add_all (provided);
                }
            }
        }
        return modified;
    }
}
