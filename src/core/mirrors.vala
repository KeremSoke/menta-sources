namespace Menta {
    public const string WORLDWIDE = "WD";

    public class Mirror : Object {
        public string country_code;
        public string url;
        public string name;
        public string site;
        public string location;
        public int rating;

        public Mirror (string country_code, string url, string name, string site = "", string location = "", int rating = 1) {
            this.country_code = country_code;
            this.url = url;
            this.name = name;
            this.site = site;
            this.location = location;
            this.rating = rating;
        }
    }

    namespace Masterlist {
        public string cache_path () {
            return Path.build_filename (Environment.get_user_cache_dir (), "menta-sources", "Mirrors.masterlist");
        }

        public string? current_path (string shipped) {
            var cached = cache_path ();
            if (FileUtils.test (cached, FileTest.IS_REGULAR)) {
                try {
                    if (parse (Files.read_text (cached), {}).size > 0) {
                        return cached;
                    }
                } catch (Error e) {
                }
            }
            if (shipped != "" && FileUtils.test (shipped, FileTest.IS_REGULAR)) {
                return shipped;
            }
            return null;
        }

        public string[] architectures () {
            string[] result = {};
            string output;
            try {
                Process.spawn_command_line_sync ("dpkg --print-architecture", out output);
                var native = output.strip ();
                if (native != "") {
                    result += native;
                }
                Process.spawn_command_line_sync ("dpkg --print-foreign-architectures", out output);
                foreach (var arch in AptSources.split_words (output)) {
                    if (!AptSources.contains (result, arch)) {
                        result += arch;
                    }
                }
            } catch (SpawnError e) {
                warning ("%s", e.message);
            }
            if (result.length == 0) {
                result += "amd64";
            }
            return result;
        }

        private bool carries (string? field, string[] wanted) {
            if (field == null || field.strip () == "" || field.strip () == "any") {
                return true;
            }
            var arches = AptSources.split_words (field);
            var excluded = new Gee.HashSet<string> ();
            var included = new Gee.HashSet<string> ();
            foreach (var arch in arches) {
                if (arch.has_prefix ("!")) {
                    excluded.add (arch.substring (1));
                } else {
                    included.add (arch);
                }
            }
            foreach (var arch in wanted) {
                if (excluded.size > 0) {
                    if (excluded.contains (arch)) {
                        return false;
                    }
                } else if (!included.contains (arch)) {
                    return false;
                }
            }
            return true;
        }

        private Mirror? make_mirror (Gee.HashMap<string, string> stanza, string[] wanted) {
            var site = stanza.get ("site");
            var path = stanza.get ("archive-http");
            if (site == null || path == null || "$" in site) {
                return null;
            }
            if (!carries (stanza.get ("archive-architecture"), wanted)) {
                return null;
            }
            var type = (stanza.get ("type") ?? "").down ();
            var geodns = "geodns" in type;
            var clean_path = AptSources.strip_slash (path.strip ());
            if (!clean_path.has_prefix ("/")) {
                clean_path = "/" + clean_path;
            }
            var scheme = site == "deb.debian.org" ? "https" : "http";
            var url = AptSources.strip_slash ("%s://%s%s".printf (scheme, site, clean_path));
            int rating = 1;
            if (geodns) {
                rating = 0;
            }
            if (site.has_prefix ("ftp") && site.has_suffix (".debian.org")) {
                rating = 2;
            }
            if (site == "deb.debian.org") {
                rating = 3;
            }
            string country = "";
            if (geodns) {
                country = WORLDWIDE;
            } else if (stanza.has_key ("country")) {
                country = AptSources.split_words (stanza.get ("country"))[0].up ();
            }
            return new Mirror (country, url, url, site, stanza.get ("location") ?? "", rating);
        }

        public Gee.ArrayList<Mirror> parse (string content, string[] wanted) {
            var result = new Gee.ArrayList<Mirror> ();
            Regex field;
            try {
                field = new Regex ("^([^:\\s][^:]*):\\s*(.*)$");
            } catch (RegexError e) {
                return result;
            }
            Gee.HashMap<string, string>? stanza = null;
            var stanzas = new Gee.ArrayList<Gee.HashMap<string, string>> ();
            foreach (var line in AptSources.split_lines (content)) {
                if (line.strip () == "") {
                    stanza = null;
                    continue;
                }
                MatchInfo match;
                if (!field.match (line, 0, out match)) {
                    continue;
                }
                var key = match.fetch (1).strip ().down ();
                var value = match.fetch (2).strip ();
                if (stanza == null || (key == "site" && stanza.has_key ("site"))) {
                    stanza = new Gee.HashMap<string, string> ();
                    stanzas.add (stanza);
                }
                if (key == "country" && stanza.has_key ("country")) {
                    continue;
                }
                stanza.set (key, value);
            }
            var seen = new Gee.HashSet<string> ();
            foreach (var item in stanzas) {
                var mirror = make_mirror (item, wanted);
                if (mirror != null && !seen.contains (mirror.url)) {
                    seen.add (mirror.url);
                    result.add (mirror);
                }
            }
            result.sort ((a, b) => b.rating - a.rating);
            return result;
        }

        public Gee.ArrayList<Mirror> load (string shipped, string[] wanted) {
            var path = current_path (shipped);
            if (path != null) {
                try {
                    return parse (Files.read_text (path), wanted);
                } catch (Error e) {
                    warning ("%s", e.message);
                }
            }
            return new Gee.ArrayList<Mirror> ();
        }

        public DebianRepos.MirrorHosts hosts (string shipped) {
            return new DebianRepos.MirrorHosts.from_mirrors (load (shipped, {}));
        }
    }
}
