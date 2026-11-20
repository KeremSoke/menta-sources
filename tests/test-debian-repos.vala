using Menta;

const string TRIXIE_SOURCES_LIST = """#deb cdrom:[Debian GNU/Linux 13.0.0 _Trixie_ - Official amd64 DVD Binary-1]/ trixie contrib main

deb http://ftp.de.debian.org/debian/ trixie main non-free-firmware
deb-src http://ftp.de.debian.org/debian/ trixie main non-free-firmware

deb http://security.debian.org/debian-security trixie-security main non-free-firmware
deb-src http://security.debian.org/debian-security trixie-security main non-free-firmware

# trixie-updates, to get updates before a point release is made;
deb http://ftp.de.debian.org/debian/ trixie-updates main non-free-firmware
deb-src http://ftp.de.debian.org/debian/ trixie-updates main non-free-firmware

deb https://thirdparty.example.com/debian trixie main
""";

string releases () {
    return Environment.get_variable ("MENTA_RELEASES");
}

DebianRepos.Release release (string codename) {
    try {
        return DebianRepos.load_release (codename, releases ());
    } catch (Error e) {
        error ("%s", e.message);
    }
}

string temp_dir () {
    try {
        return DirUtils.make_tmp ("menta-test-XXXXXX");
    } catch (FileError e) {
        error ("%s", e.message);
    }
}

void remove_dir (string path) {
    try {
        var dir = Dir.open (path);
        string? name;
        while ((name = dir.read_name ()) != null) {
            var child = Path.build_filename (path, name);
            if (FileUtils.test (child, FileTest.IS_DIR)) {
                remove_dir (child);
            } else {
                FileUtils.unlink (child);
            }
        }
    } catch (FileError e) {
    }
    DirUtils.remove (path);
}

string read_file (string path) {
    string content;
    try {
        FileUtils.get_contents (path, out content);
    } catch (FileError e) {
        error ("%s", e.message);
    }
    return content;
}

void write_file (string path, string content) {
    try {
        FileUtils.set_contents (path, content);
    } catch (FileError e) {
        error ("%s", e.message);
    }
}

Gee.ArrayList<string> list (string[] items) {
    var result = new Gee.ArrayList<string> ();
    foreach (var item in items) {
        result.add (item);
    }
    return result;
}

string joined (Gee.List<string> items) {
    return string.joinv (" ", items.to_array ());
}

void test_all_configs_load () {
    var names = new Gee.ArrayList<string> ();
    try {
        var dir = Dir.open (releases ());
        string? name;
        while ((name = dir.read_name ()) != null) {
            names.add (name);
        }
    } catch (FileError e) {
        error ("%s", e.message);
    }
    names.sort ((a, b) => strcmp (a, b));
    assert_cmpstr (joined (names), CompareOperator.EQ, "bookworm forky sid trixie");
    foreach (var codename in names) {
        var item = release (codename);
        assert_cmpstr (item.codename, CompareOperator.EQ, codename);
        assert_true (item.has_component ("main"));
        assert_cmpstr (item.masterlist_url, CompareOperator.EQ, "https://mirror-master.debian.org/status/Mirrors.masterlist");
    }
}

void check_suite (DebianRepos.Release item, string name, string? expected, bool expected_debug) {
    try {
        bool debug;
        var suite = item.classify_suite (name, out debug);
        assert_cmpstr (suite, CompareOperator.EQ, expected);
        assert_true (debug == expected_debug);
    } catch (Error e) {
        error ("%s: %s", name, e.message);
    }
}

void check_foreign_suite (DebianRepos.Release item, string name) {
    try {
        bool debug;
        item.classify_suite (name, out debug);
        assert_not_reached ();
    } catch (DebianRepos.ReleaseError e) {
    }
}

void test_classify_suite () {
    var trixie = release ("trixie");
    check_suite (trixie, "trixie", null, false);
    check_suite (trixie, "stable", null, false);
    check_suite (trixie, "trixie-security", "security", false);
    check_suite (trixie, "stable-updates", "updates", false);
    check_suite (trixie, "trixie-backports-debug", "backports", true);
    check_suite (trixie, "trixie/updates", "security", false);
    check_foreign_suite (trixie, "sid");
    check_foreign_suite (trixie, "bookworm");
}

DebianRepos.Settings round_trip (DebianRepos.Release item, DebianRepos.Settings settings) {
    var dir = temp_dir ();
    var path = Path.build_filename (dir, "debian.sources");
    try {
        DebianRepos.write (item, settings, path);
    } catch (Error e) {
        error ("%s", e.message);
    }
    var result = DebianRepos.detect_settings (item, new AptSources.SourceFile (path).load ().entries);
    remove_dir (dir);
    return result;
}

void test_trixie_defaults () {
    var trixie = release ("trixie");
    var settings = DebianRepos.default_settings (trixie);
    var content = DebianRepos.render (trixie, settings);
    assert_true ("Types: deb\nURIs: https://deb.debian.org/debian\nSuites: trixie trixie-updates\nComponents: main contrib non-free non-free-firmware\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n" in content);
    assert_true ("URIs: https://security.debian.org/debian-security\nSuites: trixie-security\n" in content);
    assert_false ("debug" in content);
    assert_true (round_trip (trixie, settings).equals (settings));
}

void test_everything_enabled () {
    var trixie = release ("trixie");
    var settings = new DebianRepos.Settings ("http://ftp.fr.debian.org/debian", trixie.security_mirror, list ({ "main", "contrib" }), list (trixie.suites), true, true);
    var content = DebianRepos.render (trixie, settings);
    assert_true ("Types: deb deb-src\nURIs: http://ftp.fr.debian.org/debian\nSuites: trixie trixie-updates trixie-backports trixie-proposed-updates\n" in content);
    assert_true ("URIs: https://deb.debian.org/debian-debug\nSuites: trixie-debug trixie-backports-debug trixie-proposed-updates-debug\n" in content);
    assert_true ("URIs: https://deb.debian.org/debian-security-debug\nSuites: trixie-security-debug\n" in content);
    assert_true (round_trip (trixie, settings).equals (settings));
}

void test_sid () {
    var sid = release ("sid");
    var settings = DebianRepos.default_settings (sid);
    var content = DebianRepos.render (sid, settings);
    assert_true ("Suites: sid\n" in content);
    assert_false ("security" in content);
    settings.suites = list ({ "experimental" });
    settings.debug = true;
    content = DebianRepos.render (sid, settings);
    assert_true ("Suites: sid experimental\n" in content);
    assert_true ("Suites: sid-debug experimental-debug\n" in content);
    assert_true (round_trip (sid, settings).equals (settings));
}

class MigrationFixture {
    public string dir;
    public string sources_list;
    public string parts;
    public string official;
    public string backups;
    public DebianRepos.Release release;

    public MigrationFixture () {
        dir = temp_dir ();
        sources_list = Path.build_filename (dir, "sources.list");
        parts = Path.build_filename (dir, "sources.list.d");
        official = Path.build_filename (parts, "debian.sources");
        backups = Path.build_filename (dir, "backups");
        DirUtils.create_with_parents (parts, 0755);
        write_file (sources_list, TRIXIE_SOURCES_LIST);
        release = global::release ("trixie");
    }

    public DebianRepos.Settings prepare (Gee.ArrayList<DebianRepos.Migration> migrated) {
        var files = AptSources.load_files (sources_list, parts);
        try {
            return DebianRepos.prepare (release, files, new DebianRepos.MirrorHosts (), migrated, official, backups);
        } catch (Error e) {
            error ("%s", e.message);
        }
    }

    ~MigrationFixture () {
        remove_dir (dir);
    }
}

void test_is_official () {
    var fixture = new MigrationFixture ();
    var entries = AptSources.all_entries (AptSources.load_files (fixture.sources_list, fixture.parts));
    int count = 0;
    foreach (var entry in entries) {
        if (DebianRepos.is_official (fixture.release, entry)) {
            count++;
            assert_false ("example.com" in entry.uris[0] || "cdrom" in entry.uris[0]);
        }
    }
    assert_cmpint (count, CompareOperator.EQ, 6);
}

void test_masterlist_hosts_are_official () {
    var trixie = release ("trixie");
    var entry = AptSources.LegacyEntry.parse (null, "deb http://mirror.example.org/pub/linux/debian trixie main");
    var hosts = new DebianRepos.MirrorHosts.from_mirrors (Masterlist.parse ("Site: mirror.example.org\nCountry: DE Germany\nArchive-architecture: amd64\nArchive-http: /pub/linux/debian/\n", { "amd64" }));
    assert_false (DebianRepos.is_official (trixie, entry));
    assert_true (DebianRepos.is_official (trixie, entry, hosts));
}

void test_migrate_sources_list () {
    var fixture = new MigrationFixture ();
    var migrated = new Gee.ArrayList<DebianRepos.Migration> ();
    var settings = fixture.prepare (migrated);
    assert_cmpstr (settings.mirror, CompareOperator.EQ, "http://ftp.de.debian.org/debian");
    assert_cmpstr (settings.security_mirror, CompareOperator.EQ, "http://security.debian.org/debian-security");
    assert_cmpstr (joined (settings.components), CompareOperator.EQ, "main non-free-firmware");
    assert_cmpstr (joined (settings.suites), CompareOperator.EQ, "security updates");
    assert_true (settings.source_code);
    assert_false (settings.debug);

    assert_cmpint (migrated.size, CompareOperator.EQ, 1);
    assert_cmpstr (migrated[0].path, CompareOperator.EQ, fixture.sources_list);
    assert_cmpstr (read_file (migrated[0].backup), CompareOperator.EQ, TRIXIE_SOURCES_LIST);

    var remaining = new AptSources.SourceFile (fixture.sources_list).load ().entries;
    assert_cmpint (remaining.size, CompareOperator.EQ, 2);
    assert_cmpstr (remaining[0].uris[0], CompareOperator.EQ, "cdrom:[Debian GNU/Linux 13.0.0 _Trixie_ - Official amd64 DVD Binary-1]/");
    assert_cmpstr (remaining[1].uris[0], CompareOperator.EQ, "https://thirdparty.example.com/debian");

    var official_entries = new AptSources.SourceFile (fixture.official).load ().entries;
    assert_true (DebianRepos.detect_settings (fixture.release, official_entries).equals (settings));

    var again = new Gee.ArrayList<DebianRepos.Migration> ();
    assert_true (fixture.prepare (again).equals (settings));
    assert_cmpint (again.size, CompareOperator.EQ, 0);
}

void test_existing_official_file_wins () {
    var fixture = new MigrationFixture ();
    var settings = new DebianRepos.Settings ("https://ftp.us.debian.org/debian", fixture.release.security_mirror, list ({ "main" }), list ({ "security", "backports" }));
    try {
        DebianRepos.write (fixture.release, settings, fixture.official);
    } catch (Error e) {
        error ("%s", e.message);
    }
    var migrated = new Gee.ArrayList<DebianRepos.Migration> ();
    var result = fixture.prepare (migrated);
    assert_cmpstr (result.mirror, CompareOperator.EQ, "https://ftp.us.debian.org/debian");
    assert_cmpstr (joined (result.components), CompareOperator.EQ, "main non-free-firmware");
    assert_cmpstr (joined (result.suites), CompareOperator.EQ, "security updates backports");
    assert_true (result.source_code);
    assert_cmpint (migrated.size, CompareOperator.EQ, 1);
}

void test_nothing_configured () {
    var fixture = new MigrationFixture ();
    FileUtils.unlink (fixture.sources_list);
    var migrated = new Gee.ArrayList<DebianRepos.Migration> ();
    var settings = fixture.prepare (migrated);
    assert_true (settings.equals (DebianRepos.default_settings (fixture.release)));
    assert_cmpint (migrated.size, CompareOperator.EQ, 0);
    assert_true (FileUtils.test (fixture.official, FileTest.EXISTS));
}

void test_modernized_sources_are_kept () {
    var fixture = new MigrationFixture ();
    FileUtils.unlink (fixture.sources_list);
    var content = "Types: deb\nURIs: http://ftp.de.debian.org/debian/\nSuites: trixie trixie-updates\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n";
    write_file (fixture.official, content);
    var migrated = new Gee.ArrayList<DebianRepos.Migration> ();
    var settings = fixture.prepare (migrated);
    assert_cmpstr (settings.mirror, CompareOperator.EQ, "http://ftp.de.debian.org/debian");
    assert_cmpstr (joined (settings.suites), CompareOperator.EQ, "updates");
    assert_cmpstr (read_file (fixture.official), CompareOperator.EQ, content);
}

void test_partial_official_lines_are_merged () {
    foreach (var line in new string[] {
        "deb http://deb.debian.org/debian trixie-backports main contrib",
        "deb http://security.debian.org/debian-security trixie-security main",
        "deb http://deb.debian.org/debian-debug trixie-debug main",
        "deb-src http://deb.debian.org/debian trixie main"
    }) {
        var fixture = new MigrationFixture ();
        FileUtils.unlink (fixture.sources_list);
        var settings = new DebianRepos.Settings ("https://deb.debian.org/debian", fixture.release.security_mirror, list ({ "main" }), list ({}));
        try {
            DebianRepos.write (fixture.release, settings, fixture.official);
        } catch (Error e) {
            error ("%s", e.message);
        }
        write_file (Path.build_filename (fixture.parts, "extra.list"), line + "\n");
        var migrated = new Gee.ArrayList<DebianRepos.Migration> ();
        var result = fixture.prepare (migrated);
        assert_cmpint (migrated.size, CompareOperator.EQ, 1);
        if ("backports" in line) {
            assert_cmpstr (joined (result.suites), CompareOperator.EQ, "backports");
            assert_cmpstr (joined (result.components), CompareOperator.EQ, "main contrib");
        } else if ("security" in line) {
            assert_cmpstr (joined (result.suites), CompareOperator.EQ, "security");
        } else if ("debug" in line) {
            assert_true (result.debug);
        } else {
            assert_true (result.source_code);
        }
        var reread = DebianRepos.detect_settings (fixture.release, new AptSources.SourceFile (fixture.official).load ().entries);
        assert_true (reread.equals (result));
    }
}

void test_third_party_on_mirror_host_is_not_official () {
    var trixie = release ("trixie");
    var hosts = new DebianRepos.MirrorHosts.from_mirrors (Masterlist.parse ("Site: mirrors.ustc.edu.cn\nCountry: CN China\nArchive-architecture: amd64\nArchive-http: /debian/\n", { "amd64" }));
    var docker = AptSources.LegacyEntry.parse (null, "deb [signed-by=/etc/apt/keyrings/docker.asc] https://mirrors.ustc.edu.cn/docker-ce/linux/debian trixie stable");
    var mirror = AptSources.LegacyEntry.parse (null, "deb https://mirrors.ustc.edu.cn/debian trixie main");
    assert_false (DebianRepos.is_official (trixie, docker, hosts));
    assert_true (DebianRepos.is_official (trixie, mirror, hosts));
    var security = AptSources.LegacyEntry.parse (null, "deb http://mirrors.ustc.edu.cn/debian-security trixie-security main");
    assert_true (DebianRepos.is_official (trixie, security, hosts));
}

void test_other_release_stanza_is_moved_disabled () {
    var fixture = new MigrationFixture ();
    FileUtils.unlink (fixture.sources_list);
    write_file (fixture.official, "Types: deb\nURIs: https://deb.debian.org/debian\nSuites: bookworm bookworm-updates\nComponents: main\n");
    var migrated = new Gee.ArrayList<DebianRepos.Migration> ();
    fixture.prepare (migrated);
    var moved = new AptSources.SourceFile (Path.build_filename (fixture.parts, "moved-from-debian.sources")).load ();
    assert_cmpint (moved.entries.size, CompareOperator.EQ, 1);
    assert_false (moved.entries[0].enabled);
    assert_true ("Suites: trixie" in read_file (fixture.official));
}

void test_foreign_stanza_in_official_file_is_moved () {
    var fixture = new MigrationFixture ();
    FileUtils.unlink (fixture.sources_list);
    write_file (fixture.official, "Types: deb\nURIs: https://deb.debian.org/debian\nSuites: trixie\nComponents: main\n\nTypes: deb\nURIs: https://download.docker.com/linux/debian\nSuites: trixie\nComponents: stable\n");
    var migrated = new Gee.ArrayList<DebianRepos.Migration> ();
    var settings = fixture.prepare (migrated);
    assert_cmpstr (joined (settings.components), CompareOperator.EQ, "main");
    assert_cmpint (migrated.size, CompareOperator.EQ, 1);
    assert_true ("download.docker.com" in read_file (migrated[0].backup));
    assert_false ("docker" in read_file (fixture.official));
    var moved = new AptSources.SourceFile (Path.build_filename (fixture.parts, "moved-from-debian.sources")).load ();
    assert_cmpint (moved.entries.size, CompareOperator.EQ, 1);
    assert_cmpstr (moved.entries[0].uris[0], CompareOperator.EQ, "https://download.docker.com/linux/debian");
}

string detect (string os_release, string debian_version, string[] lines) {
    var dir = temp_dir ();
    var os_path = Path.build_filename (dir, "os-release");
    var version_path = Path.build_filename (dir, "debian_version");
    write_file (os_path, os_release);
    write_file (version_path, debian_version);
    var entries = new Gee.ArrayList<AptSources.Entry> ();
    foreach (var line in lines) {
        entries.add (AptSources.LegacyEntry.parse (null, line));
    }
    var result = DebianRepos.detect_codename (entries, os_path, version_path);
    remove_dir (dir);
    return result;
}

void test_codename_stable () {
    assert_cmpstr (detect ("PRETTY_NAME=\"Debian GNU/Linux 13 (trixie)\"\nVERSION_CODENAME=trixie\n\nID=debian\n", "13.1\n", {}), CompareOperator.EQ, "trixie");
}

void test_codename_testing_and_unstable () {
    var os_release = "PRETTY_NAME=\"Debian GNU/Linux forky/sid\"\nVERSION_CODENAME=\"forky\"\n";
    assert_cmpstr (detect (os_release, "forky/sid\n", { "deb http://deb.debian.org/debian forky main" }), CompareOperator.EQ, "forky");
    assert_cmpstr (detect (os_release, "forky/sid\n", { "deb http://deb.debian.org/debian unstable main" }), CompareOperator.EQ, "sid");
    assert_cmpstr (detect (os_release, "forky/sid\n", { "# deb http://deb.debian.org/debian sid main" }), CompareOperator.EQ, "forky");
}

public int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/releases/all-configs-load", test_all_configs_load);
    Test.add_func ("/releases/classify-suite", test_classify_suite);
    Test.add_func ("/render/trixie-defaults", test_trixie_defaults);
    Test.add_func ("/render/everything-enabled", test_everything_enabled);
    Test.add_func ("/render/sid", test_sid);
    Test.add_func ("/migration/is-official", test_is_official);
    Test.add_func ("/migration/masterlist-hosts", test_masterlist_hosts_are_official);
    Test.add_func ("/migration/migrate-sources-list", test_migrate_sources_list);
    Test.add_func ("/migration/existing-official-file-wins", test_existing_official_file_wins);
    Test.add_func ("/migration/nothing-configured", test_nothing_configured);
    Test.add_func ("/migration/modernized-sources-are-kept", test_modernized_sources_are_kept);
    Test.add_func ("/migration/partial-official-lines", test_partial_official_lines_are_merged);
    Test.add_func ("/migration/third-party-on-mirror-host", test_third_party_on_mirror_host_is_not_official);
    Test.add_func ("/migration/foreign-stanza-moved", test_foreign_stanza_in_official_file_is_moved);
    Test.add_func ("/migration/other-release-moved-disabled", test_other_release_stanza_is_moved_disabled);
    Test.add_func ("/codename/stable", test_codename_stable);
    Test.add_func ("/codename/testing-and-unstable", test_codename_testing_and_unstable);
    return Test.run ();
}
