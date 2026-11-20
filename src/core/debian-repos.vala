namespace Menta.DebianRepos {
    public const string OFFICIAL_FILE = "/etc/apt/sources.list.d/debian.sources";
    public const string BACKUP_DIR = "/var/backups/menta-sources";
    public const string DEBIAN_KEYRING = "/usr/share/keyrings/debian-archive-keyring.gpg";

    public const string[] SUITES = { "security", "updates", "backports", "proposed-updates", "experimental" };

    public const string HEADER = "# Official Debian repositories, managed by Software Sources (menta-sources).\n# Use Software Sources to change them, manual edits may be overwritten.\n";

    public errordomain ReleaseError {
        NOT_FOUND,
        INVALID,
        UNKNOWN_SUITE
    }

    private string trim_slash (string value) {
        return AptSources.strip_slash (value.strip ());
    }

    public class Release : Object {
        public string codename;
        public string description;
        public string alias;
        public string keyring;
        public string mirror;
        public string security_mirror;
        public string debug_mirror;
        public string security_debug_mirror;
        public string masterlist;
        public string masterlist_url;
        public string[] components;
        public string[] default_components;
        public string[] suites;
        public string[] default_suites;
        public string keyserver;

        public Release (string path) throws Error {
            if (!FileUtils.test (path, FileTest.IS_REGULAR)) {
                throw new ReleaseError.NOT_FOUND ("%s", path);
            }
            var file = new KeyFile ();
            file.set_list_separator (' ');
            file.load_from_file (path, KeyFileFlags.NONE);
            codename = file.get_string ("general", "codename").strip ();
            if (codename == "") {
                throw new ReleaseError.INVALID ("%s: codename", path);
            }
            description = optional (file, "general", "description", codename);
            alias = optional (file, "general", "alias", "");
            keyring = optional (file, "general", "keyring", DEBIAN_KEYRING);
            mirror = trim_slash (file.get_string ("mirrors", "default"));
            security_mirror = trim_slash (optional (file, "mirrors", "security", ""));
            debug_mirror = trim_slash (optional (file, "mirrors", "debug", ""));
            security_debug_mirror = trim_slash (optional (file, "mirrors", "security_debug", ""));
            masterlist = optional (file, "mirrors", "masterlist", "");
            masterlist_url = optional (file, "mirrors", "masterlist_url", "");
            components = AptSources.split_words (file.get_string ("components", "available"));
            default_components = AptSources.split_words (file.get_string ("components", "default"));
            var available = AptSources.split_words (optional (file, "suites", "available", ""));
            string[] ordered = {};
            foreach (var suite in SUITES) {
                if (AptSources.contains (available, suite)) {
                    ordered += suite;
                }
            }
            suites = ordered;
            default_suites = AptSources.split_words (optional (file, "suites", "default", ""));
            keyserver = optional (file, "keys", "keyserver", "hkps://keyserver.ubuntu.com");
        }

        private static string optional (KeyFile file, string group, string key, string fallback) {
            try {
                if (file.has_key (group, key)) {
                    return file.get_string (group, key).strip ();
                }
            } catch (KeyFileError e) {
            }
            return fallback;
        }

        public string suite_name (string suite, string? base_name = null) {
            if (suite == "experimental") {
                return "experimental";
            }
            return "%s-%s".printf (base_name ?? codename, suite);
        }

        public string[] base_names () {
            string[] names = {};
            if (codename != "") {
                names += codename;
            }
            if (alias != "") {
                names += alias;
            }
            return names;
        }

        public string? classify_suite (string full_name, out bool debug) throws ReleaseError {
            var name = full_name;
            debug = name.has_suffix ("-debug");
            if (debug) {
                name = name.substring (0, name.length - "-debug".length);
            }
            foreach (var base_name in base_names ()) {
                if (name == base_name) {
                    return null;
                }
                foreach (var suite in SUITES) {
                    if (name == suite_name (suite, base_name)) {
                        return suite;
                    }
                }
                if (name == "%s/updates".printf (base_name)) {
                    return "security";
                }
            }
            throw new ReleaseError.UNKNOWN_SUITE ("%s", full_name);
        }

        public bool has_component (string component) {
            return AptSources.contains (components, component);
        }

        public bool has_suite (string suite) {
            return AptSources.contains (suites, suite);
        }
    }

    public class Settings : Object {
        public string mirror;
        public string security_mirror;
        public Gee.ArrayList<string> components;
        public Gee.ArrayList<string> suites;
        public bool source_code;
        public bool debug;

        public Settings (string mirror, string security_mirror, Gee.Collection<string> components, Gee.Collection<string> suites, bool source_code = false, bool debug = false) {
            this.mirror = mirror;
            this.security_mirror = security_mirror;
            this.components = new Gee.ArrayList<string> ();
            this.components.add_all (components);
            this.suites = new Gee.ArrayList<string> ();
            this.suites.add_all (suites);
            this.source_code = source_code;
            this.debug = debug;
        }

        public bool equals (Settings other) {
            return mirror == other.mirror
                && security_mirror == other.security_mirror
                && same_list (components, other.components)
                && same_list (suites, other.suites)
                && source_code == other.source_code
                && debug == other.debug;
        }

        private static bool same_list (Gee.List<string> a, Gee.List<string> b) {
            if (a.size != b.size) {
                return false;
            }
            for (int i = 0; i < a.size; i++) {
                if (a[i] != b[i]) {
                    return false;
                }
            }
            return true;
        }

        public string to_string () {
            return "mirror=%s security=%s components=%s suites=%s source=%s debug=%s".printf (
                mirror, security_mirror,
                string.joinv (" ", components.to_array ()),
                string.joinv (" ", suites.to_array ()),
                source_code.to_string (), debug.to_string ());
        }
    }

    public class Migration : Object {
        public string path;
        public string backup;

        public Migration (string path, string backup) {
            this.path = path;
            this.backup = backup;
        }
    }

    public string config_path (string codename, string config_dir) {
        return Path.build_filename (config_dir, codename, "menta-sources.conf");
    }

    public Release load_release (string codename, string config_dir) throws Error {
        return new Release (config_path (codename, config_dir));
    }

    public Gee.HashMap<string, string> read_os_release (string path = "/etc/os-release") {
        var values = new Gee.HashMap<string, string> ();
        string content;
        try {
            content = Files.read_text (path);
        } catch (Error e) {
            return values;
        }
        foreach (var raw in AptSources.split_lines (content)) {
            var line = raw.strip ();
            var position = line.index_of ("=");
            if (position < 0 || line.has_prefix ("#")) {
                continue;
            }
            var key = line.substring (0, position);
            var value = line.substring (position + 1).strip ();
            while (value.length > 0 && (value[0] == '"' || value[0] == '\'')) {
                value = value.substring (1);
            }
            while (value.length > 0 && (value[value.length - 1] == '"' || value[value.length - 1] == '\'')) {
                value = value.substring (0, value.length - 1);
            }
            values.set (key, value);
        }
        return values;
    }

    public string detect_codename (Gee.List<AptSources.Entry> entries, string os_release = "/etc/os-release", string debian_version = "/etc/debian_version") {
        var values = read_os_release (os_release);
        var codename = values.has_key ("VERSION_CODENAME") ? values.get ("VERSION_CODENAME") : "unknown";
        string version = "";
        try {
            version = Files.read_text (debian_version).strip ();
        } catch (Error e) {
        }
        if (version.has_suffix ("/sid")) {
            foreach (var entry in entries) {
                if (entry.enabled && AptSources.contains (entry.types, "deb")
                    && (AptSources.contains (entry.suites, "sid") || AptSources.contains (entry.suites, "unstable"))) {
                    return "sid";
                }
            }
        }
        return codename;
    }

    public Settings default_settings (Release release) {
        var components = new Gee.ArrayList<string> ();
        foreach (var component in release.components) {
            if (AptSources.contains (release.default_components, component)) {
                components.add (component);
            }
        }
        var suites = new Gee.ArrayList<string> ();
        foreach (var suite in release.suites) {
            if (AptSources.contains (release.default_suites, suite)) {
                suites.add (suite);
            }
        }
        return new Settings (release.mirror, release.security_mirror, components, suites);
    }

    public string uri_host (string uri) {
        var position = uri.index_of ("://");
        if (position < 0) {
            return "";
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
            return close > 0 ? authority.substring (1, close - 1).down () : "";
        }
        var colon = authority.index_of (":");
        if (colon >= 0) {
            authority = authority.substring (0, colon);
        }
        return authority.down ();
    }

    public string uri_location (string uri) {
        var position = uri.index_of ("://");
        var rest = position >= 0 ? uri.substring (position + 3) : uri;
        var slash = rest.index_of ("/");
        var path = slash >= 0 ? rest.substring (slash) : "";
        return uri_host (uri) + AptSources.strip_slash (path);
    }

    public class MirrorHosts : Object {
        public Gee.HashSet<string> hosts = new Gee.HashSet<string> ();
        public Gee.HashSet<string> locations = new Gee.HashSet<string> ();

        public MirrorHosts () {
        }

        public MirrorHosts.from_mirrors (Gee.Collection<Mirror> mirrors) {
            foreach (var mirror in mirrors) {
                hosts.add (uri_host (mirror.url));
                locations.add (uri_location (mirror.url));
            }
        }
    }

    public bool is_official (Release release, AptSources.Entry entry, MirrorHosts? mirror_hosts = null) {
        foreach (var suite in entry.suites) {
            try {
                bool debug;
                release.classify_suite (suite, out debug);
            } catch (ReleaseError e) {
                return false;
            }
        }
        return is_debian_archive (release, entry, mirror_hosts);
    }

    private bool known_mirror_location (MirrorHosts? mirror_hosts, string uri) {
        if (mirror_hosts == null) {
            return false;
        }
        var location = uri_location (uri);
        if (mirror_hosts.locations.contains (location)) {
            return true;
        }
        foreach (var suffix in new string[] { "-security-debug", "-security", "-debug" }) {
            if (location.has_suffix (suffix) && mirror_hosts.locations.contains (location.substring (0, location.length - suffix.length))) {
                return true;
            }
        }
        return false;
    }

    public bool is_debian_archive (Release release, AptSources.Entry entry, MirrorHosts? mirror_hosts = null) {
        Regex path_pattern;
        try {
            path_pattern = new Regex ("/debian(-security)?(-debug)?/?$");
        } catch (RegexError e) {
            return false;
        }
        foreach (var uri in entry.uris) {
            var host = uri_host (uri);
            if (known_mirror_location (mirror_hosts, uri)) {
                continue;
            }
            var trusted = host == "debian.org" || host.has_suffix (".debian.org") || entry.signed_by == release.keyring;
            if (!trusted || !path_pattern.match (uri)) {
                return false;
            }
        }
        return entry.uris.length > 0;
    }

    public Settings? detect_settings (Release release, Gee.List<AptSources.Entry> entries) {
        bool has_base;
        var settings = collect_settings (release, entries, out has_base);
        return has_base ? settings : null;
    }

    public Settings collect_settings (Release release, Gee.List<AptSources.Entry> entries, out bool has_base) {
        string? mirror = null;
        string? security_mirror = null;
        var components = new Gee.ArrayList<string> ();
        var suites = new Gee.ArrayList<string> ();
        bool source_code = false;
        bool debug = false;
        foreach (var entry in entries) {
            if (!entry.enabled) {
                continue;
            }
            foreach (var name in entry.suites) {
                string? suite;
                bool is_debug;
                try {
                    suite = release.classify_suite (name, out is_debug);
                } catch (ReleaseError e) {
                    continue;
                }
                if (is_debug) {
                    debug = true;
                    continue;
                }
                if (suite == null && AptSources.contains (entry.types, "deb") && mirror == null) {
                    mirror = AptSources.strip_slash (entry.uris[0]);
                }
                if (suite == "security" && security_mirror == null) {
                    security_mirror = AptSources.strip_slash (entry.uris[0]);
                }
                if (suite != null && release.has_suite (suite) && !suites.contains (suite)) {
                    suites.add (suite);
                }
                if (suite == null && AptSources.contains (entry.types, "deb-src")) {
                    source_code = true;
                }
                foreach (var component in entry.components) {
                    if (!components.contains (component)) {
                        components.add (component);
                    }
                }
            }
        }
        has_base = mirror != null;
        var ordered = new Gee.ArrayList<string> ();
        foreach (var component in release.components) {
            if (components.contains (component)) {
                ordered.add (component);
            }
        }
        foreach (var component in components) {
            if (!ordered.contains (component)) {
                ordered.add (component);
            }
        }
        var ordered_suites = new Gee.ArrayList<string> ();
        foreach (var suite in release.suites) {
            if (suites.contains (suite)) {
                ordered_suites.add (suite);
            }
        }
        return new Settings (mirror ?? release.mirror, security_mirror ?? release.security_mirror, ordered, ordered_suites, source_code, debug);
    }

    public Settings merge_settings (Release release, Settings settings, Settings other) {
        foreach (var component in other.components) {
            if (!settings.components.contains (component)) {
                settings.components.add (component);
            }
        }
        var suites = new Gee.ArrayList<string> ();
        foreach (var suite in release.suites) {
            if (settings.suites.contains (suite) || other.suites.contains (suite)) {
                suites.add (suite);
            }
        }
        settings.suites = suites;
        settings.source_code = settings.source_code || other.source_code;
        settings.debug = settings.debug || other.debug;
        return settings;
    }

    private string stanza (string[] types, string uri, string[] suites, string[] components, string? keyring) {
        var builder = new StringBuilder ();
        builder.append_printf ("Types: %s\n", string.joinv (" ", types));
        builder.append_printf ("URIs: %s\n", uri);
        builder.append_printf ("Suites: %s\n", string.joinv (" ", suites));
        builder.append_printf ("Components: %s\n", string.joinv (" ", components));
        if (keyring != null && keyring != "") {
            builder.append_printf ("Signed-By: %s\n", keyring);
        }
        return builder.str;
    }

    public string render (Release release, Settings settings) {
        string[] types = settings.source_code ? new string[] { "deb", "deb-src" } : new string[] { "deb" };
        string[] components = {};
        if (!settings.components.contains ("main")) {
            components += "main";
        }
        foreach (var component in settings.components) {
            components += component;
        }
        var keyring = release.keyring;

        string[] main_suites = { release.codename };
        foreach (var suite in settings.suites) {
            if (suite != "security") {
                main_suites += release.suite_name (suite);
            }
        }
        string[] stanzas = { stanza (types, settings.mirror, main_suites, components, keyring) };

        var security = settings.suites.contains ("security") && settings.security_mirror != "";
        if (security) {
            stanzas += stanza (types, settings.security_mirror, { release.suite_name ("security") }, components, keyring);
        }

        if (settings.debug && release.debug_mirror != "") {
            string[] debug_suites = { "%s-debug".printf (release.codename) };
            foreach (var suite in settings.suites) {
                if (suite == "backports" || suite == "proposed-updates" || suite == "experimental") {
                    debug_suites += "%s-debug".printf (release.suite_name (suite));
                }
            }
            stanzas += stanza ({ "deb" }, release.debug_mirror, debug_suites, components, keyring);
            if (security && release.security_debug_mirror != "") {
                stanzas += stanza ({ "deb" }, release.security_debug_mirror, { "%s-debug".printf (release.suite_name ("security")) }, components, keyring);
            }
        }

        return HEADER + "\n" + string.joinv ("\n", stanzas);
    }

    public void write (Release release, Settings settings, string? path = null) throws Error {
        Files.storage ().write_file (path ?? OFFICIAL_FILE, render (release, settings).data, 0644);
    }

    public string backup (string path, string? backup_dir = null) throws Error {
        return Files.storage ().backup_file (path, backup_dir ?? BACKUP_DIR);
    }

    public Settings prepare (Release release, Gee.List<AptSources.SourceFile> files, MirrorHosts? mirror_hosts, Gee.List<Migration> migrated, string? official_path = null, string? backup_dir = null) throws Error {
        var official = official_path ?? OFFICIAL_FILE;

        AptSources.SourceFile? official_file = null;
        foreach (var file in files) {
            if (file.path == official) {
                official_file = file;
                break;
            }
        }

        var official_entries = new Gee.ArrayList<AptSources.Entry> ();
        var foreign_entries = new Gee.ArrayList<AptSources.Entry> ();
        if (official_file != null) {
            foreach (var entry in official_file.entries) {
                if (is_official (release, entry, mirror_hosts)) {
                    official_entries.add (entry);
                } else {
                    foreign_entries.add (entry);
                }
            }
        }
        Settings? settings = official_file != null ? detect_settings (release, official_entries) : null;

        var legacy = new Gee.ArrayList<AptSources.Entry> ();
        foreach (var file in files) {
            if (file.path == official) {
                continue;
            }
            foreach (var entry in file.entries) {
                if (is_official (release, entry, mirror_hosts)) {
                    legacy.add (entry);
                }
            }
        }
        bool legacy_has_base;
        var legacy_settings = collect_settings (release, legacy, out legacy_has_base);

        if (settings == null) {
            if (legacy_has_base) {
                settings = legacy_settings;
            } else {
                settings = default_settings (release);
                if (official_entries.size > 0) {
                    bool official_has_base;
                    merge_settings (release, settings, collect_settings (release, official_entries, out official_has_base));
                }
                if (legacy.size > 0) {
                    merge_settings (release, settings, legacy_settings);
                }
            }
        } else if (legacy.size > 0) {
            merge_settings (release, settings, legacy_settings);
        }

        if (foreign_entries.size > 0) {
            var backup_path = backup (official, backup_dir);
            var moved_path = Path.build_filename (Path.get_dirname (official), "moved-from-debian.sources");
            var moved = new AptSources.SourceFile (moved_path).load ();
            if (moved.load_error != null) {
                throw new StorageError.FAILED ("%s", moved.load_error);
            }
            foreach (var entry in foreign_entries) {
                if (is_debian_archive (release, entry, mirror_hosts)) {
                    entry.set_enabled (false);
                }
                moved.items.add (new AptSources.RawText (entry.text ()));
            }
            var text = moved.text ();
            Files.storage ().write_file (moved_path, text.data, 0644);
            migrated.add (new Migration (official, backup_path));
        }

        if (official_file == null || legacy.size > 0 || foreign_entries.size > 0) {
            write (release, settings, official);
        }

        var sources = new Gee.ArrayList<AptSources.SourceFile> ();
        foreach (var entry in legacy) {
            if (!sources.contains (entry.file)) {
                sources.add (entry.file);
            }
        }
        foreach (var file in sources) {
            var backup_path = backup (file.path, backup_dir);
            foreach (var entry in legacy) {
                if (entry.file == file) {
                    file.remove (entry);
                }
            }
            if (file.entries.size == 0) {
                file.replace_with_text ("# The official Debian repositories are configured in %s".printf (official));
            }
            file.save ();
            migrated.add (new Migration (file.path, backup_path));
        }

        return settings;
    }
}
