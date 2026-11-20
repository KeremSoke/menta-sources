namespace Menta {
    public class CountryData : Object {
        public string cca2;
        public string cca3;
        public string region;
        public string subregion;
        public Gee.HashSet<string> borders = new Gee.HashSet<string> ();
        public Gee.HashSet<string> network_neighbors = new Gee.HashSet<string> ();
    }

    public class Countries : Object {
        private Gee.HashMap<string, string> names = new Gee.HashMap<string, string> ();
        public Gee.ArrayList<CountryData> all = new Gee.ArrayList<CountryData> ();

        public Countries () {
            load_names ();
            load_geography (Path.build_filename (Config.PKGDATADIR, "countries.json"));
        }

        private void load_names () {
            var parser = new Json.Parser ();
            try {
                parser.load_from_file ("/usr/share/iso-codes/json/iso_3166-1.json");
            } catch (Error e) {
                warning ("%s", e.message);
                return;
            }
            var root = parser.get_root ().get_object ();
            if (!root.has_member ("3166-1")) {
                return;
            }
            root.get_array_member ("3166-1").foreach_element ((array, index, node) => {
                var item = node.get_object ();
                var name = item.has_member ("common_name") ? item.get_string_member ("common_name") : item.get_string_member ("name");
                var code = item.has_member ("alpha_2") ? item.get_string_member ("alpha_2") : item.get_string_member ("alpha_3");
                if (code != null && name != null) {
                    names.set (code, dgettext ("iso_3166-1", name));
                }
            });
        }

        private static void add_strings (Json.Object item, string member, Gee.HashSet<string> target) {
            if (!item.has_member (member)) {
                return;
            }
            item.get_array_member (member).foreach_element ((array, index, node) => {
                target.add (node.get_string ());
            });
        }

        private void load_geography (string path) {
            var parser = new Json.Parser ();
            try {
                parser.load_from_file (path);
            } catch (Error e) {
                warning ("%s", e.message);
                return;
            }
            parser.get_root ().get_array ().foreach_element ((array, index, node) => {
                var item = node.get_object ();
                var country = new CountryData ();
                country.cca2 = item.get_string_member ("cca2");
                country.cca3 = item.get_string_member ("cca3");
                country.region = item.has_member ("region") ? item.get_string_member ("region") : "";
                country.subregion = item.has_member ("subregion") ? item.get_string_member ("subregion") : "";
                add_strings (item, "borders", country.borders);
                add_strings (item, "networkNeighbors", country.network_neighbors);
                all.add (country);
            });
        }

        public string name (string code) {
            if (code == WORLDWIDE) {
                return _("Worldwide");
            }
            if (code == "") {
                return _("Unknown");
            }
            return names.has_key (code) ? names.get (code) : code;
        }

        public CountryData? find (string code) {
            foreach (var country in all) {
                if (country.cca2 == code) {
                    return country;
                }
            }
            return null;
        }

        private static string? timezone_name () {
            var tz = Environment.get_variable ("TZ");
            if (tz != null && tz != "") {
                var zone = tz.has_prefix (":") ? tz.substring (1) : tz;
                var position = zone.index_of ("zoneinfo/");
                if (position >= 0) {
                    zone = zone.substring (position + "zoneinfo/".length);
                }
                if (zone.has_prefix ("posix/") || zone.has_prefix ("right/")) {
                    zone = zone.substring (6);
                }
                return zone;
            }
            try {
                var content = Files.read_text ("/etc/timezone").strip ();
                if (content != "") {
                    return content;
                }
            } catch (Error e) {
            }
            try {
                var target = FileUtils.read_link ("/etc/localtime");
                var position = target.index_of ("zoneinfo/");
                if (position >= 0) {
                    var zone = target.substring (position + "zoneinfo/".length);
                    if (zone.has_prefix ("posix/") || zone.has_prefix ("right/")) {
                        zone = zone.substring (6);
                    }
                    return zone;
                }
            } catch (FileError e) {
            }
            return null;
        }

        private static string resolve_link (string zone) {
            string content;
            try {
                content = Files.read_text ("/usr/share/zoneinfo/tzdata.zi");
            } catch (Error e) {
                return zone;
            }
            foreach (var line in content.split ("\n")) {
                if (!line.has_prefix ("L ")) {
                    continue;
                }
                var parts = AptSources.split_words (line);
                if (parts.length == 3 && parts[2] == zone) {
                    return parts[1];
                }
            }
            return zone;
        }

        private static string? zone_country (string zone, string table) {
            string content;
            try {
                content = Files.read_text (table);
            } catch (Error e) {
                return null;
            }
            foreach (var line in content.split ("\n")) {
                if (line.has_prefix ("#")) {
                    continue;
                }
                var parts = line.split ("\t");
                if (parts.length >= 3 && parts[2] == zone) {
                    return parts[0].split (",")[0].strip ().up ();
                }
            }
            return null;
        }

        public static string? local_country_code () {
            var zone = timezone_name ();
            if (zone != null) {
                foreach (var candidate in new string[] { zone, resolve_link (zone) }) {
                    var code = zone_country (candidate, "/usr/share/zoneinfo/zone.tab") ?? zone_country (candidate, "/usr/share/zoneinfo/zone1970.tab");
                    if (code != null && code.length == 2) {
                        return code;
                    }
                }
            }
            foreach (var variable in new string[] { "LC_ALL", "LC_MESSAGES", "LANG" }) {
                var value = Environment.get_variable (variable);
                if (value == null || value == "") {
                    continue;
                }
                var base_locale = value.split (".")[0].split ("@")[0];
                var position = base_locale.last_index_of ("_");
                if (position >= 0) {
                    var code = base_locale.substring (position + 1).up ();
                    if (code.length == 2) {
                        return code;
                    }
                }
            }
            return null;
        }
    }
}
