using Menta;

string testdata () {
    return Path.build_filename (Environment.get_variable ("MENTA_TESTDATA"), "sources.list.d");
}

string make_temp_copy () {
    string dir;
    try {
        dir = DirUtils.make_tmp ("menta-test-XXXXXX");
    } catch (FileError e) {
        error ("%s", e.message);
    }
    var parts = Path.build_filename (dir, "sources.list.d");
    DirUtils.create (parts, 0755);
    try {
        var source = Dir.open (testdata ());
        string? name;
        while ((name = source.read_name ()) != null) {
            string content;
            FileUtils.get_contents (Path.build_filename (testdata (), name), out content);
            FileUtils.set_contents (Path.build_filename (parts, name), content);
        }
    } catch (Error e) {
        error ("%s", e.message);
    }
    return parts;
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

void test_repo_key_path () {
    var entries = AptSources.all_entries (AptSources.load_files ("/nonexistent/sources.list", testdata ()));
    assert_cmpstr (AptSources.repo_key_path ("https://deb822.example.com", entries), CompareOperator.EQ, "/usr/share/keyrings/deb822.gpg");
    assert_cmpstr (AptSources.repo_key_path ("https://legacy.example.com", entries), CompareOperator.EQ, "/usr/share/keyrings/legacy.gpg");
    assert_cmpstr (AptSources.repo_key_path ("https://deb822.example.com/", entries), CompareOperator.EQ, "/usr/share/keyrings/deb822.gpg");
    assert_cmpstr (AptSources.repo_key_path ("https://legacy-dev.example.com", entries), CompareOperator.EQ, "/usr/share/keyrings/legacy-dev.gpg");
    assert_null (AptSources.repo_key_path ("https://unsigned.example.com", entries));
    assert_null (AptSources.repo_key_path ("https://deb822-disabled.example.com", entries));
    assert_null (AptSources.repo_key_path ("https://disabled.example.com", entries));
}

void test_ignored_files () {
    var entries = AptSources.all_entries (AptSources.load_files ("/nonexistent/sources.list", testdata ()));
    foreach (var entry in entries) {
        assert_false ("ignored" in entry.uris[0]);
    }
    assert_cmpint (entries.size, CompareOperator.EQ, 6);
}

void test_round_trip () {
    var parts = make_temp_copy ();
    foreach (var name in new string[] { "legacy.list", "deb822.sources", "deb822-disabled.sources" }) {
        var path = Path.build_filename (parts, name);
        assert_cmpstr (new AptSources.SourceFile (path).load ().text (), CompareOperator.EQ, read_file (path));
    }
    remove_dir (Path.get_dirname (parts));
}

void test_toggle_legacy () {
    var parts = make_temp_copy ();
    var path = Path.build_filename (parts, "legacy.list");
    try {
        var file = new AptSources.SourceFile (path).load ();
        file.entries[0].set_enabled (false);
        file.save ();
        assert_true ("# deb [signed-by=/usr/share/keyrings/legacy.gpg] https://legacy.example.com trixie main" in read_file (path));
        file = new AptSources.SourceFile (path).load ();
        assert_false (file.entries[0].enabled);
        file.entries[0].set_enabled (true);
        file.save ();
        assert_cmpstr (read_file (path).split ("\n")[1], CompareOperator.EQ, "deb [signed-by=/usr/share/keyrings/legacy.gpg] https://legacy.example.com trixie main");
    } catch (Error e) {
        error ("%s", e.message);
    }
    remove_dir (Path.get_dirname (parts));
}

void test_toggle_deb822 () {
    var parts = make_temp_copy ();
    try {
        var path = Path.build_filename (parts, "deb822.sources");
        var file = new AptSources.SourceFile (path).load ();
        file.entries[0].set_enabled (false);
        file.save ();
        var content = read_file (path);
        assert_true ("Enabled: no" in content);
        assert_false ("Enabled: yes" in content);
        assert_false (new AptSources.SourceFile (path).load ().entries[0].enabled);

        path = Path.build_filename (parts, "deb822-disabled.sources");
        file = new AptSources.SourceFile (path).load ();
        file.entries[0].set_enabled (true);
        file.save ();
        content = read_file (path);
        assert_false ("Enabled" in content);
        assert_true (content.has_prefix ("# A comment before the stanza\n"));
        assert_true (new AptSources.SourceFile (path).load ().entries[0].enabled);
    } catch (Error e) {
        error ("%s", e.message);
    }
    remove_dir (Path.get_dirname (parts));
}

void test_remove_last_entry_deletes_file () {
    var parts = make_temp_copy ();
    var path = Path.build_filename (parts, "unsigned.list");
    try {
        var file = new AptSources.SourceFile (path).load ();
        file.remove (file.entries[0]);
        file.save ();
    } catch (Error e) {
        error ("%s", e.message);
    }
    assert_false (FileUtils.test (path, FileTest.EXISTS));
    remove_dir (Path.get_dirname (parts));
}

void test_remove_one_entry () {
    var parts = make_temp_copy ();
    var path = Path.build_filename (parts, "legacy.list");
    try {
        var file = new AptSources.SourceFile (path).load ();
        file.remove (file.entries[0]);
        file.save ();
    } catch (Error e) {
        error ("%s", e.message);
    }
    assert_cmpstr (read_file (path), CompareOperator.EQ,
                   "# Legacy one-line entries\ndeb [arch=amd64 signed-by=/usr/share/keyrings/legacy-dev.gpg] https://legacy-dev.example.com/ trixie main\n");
    remove_dir (Path.get_dirname (parts));
}

void test_deb822_multiple_stanzas () {
    var parts = make_temp_copy ();
    var path = Path.build_filename (parts, "multi.sources");
    write_file (path, "Types: deb deb-src\nURIs: https://a.example.com\nSuites: trixie\nComponents: main\n\n\n"
           + "Types: deb\nURIs: https://b.example.com\nSuites: trixie\nComponents: main\n"
           + "Signed-By:\n -----BEGIN PGP PUBLIC KEY BLOCK-----\n .\n abc\n -----END PGP PUBLIC KEY BLOCK-----\n");
    var file = new AptSources.SourceFile (path).load ();
    assert_cmpint (file.entries.size, CompareOperator.EQ, 2);
    assert_cmpstrv (file.entries[0].types, { "deb", "deb-src" });
    assert_null (file.entries[1].signed_by);
    try {
        file.remove (file.entries[0]);
        file.save ();
    } catch (Error e) {
        error ("%s", e.message);
    }
    var reloaded = new AptSources.SourceFile (path).load ();
    assert_cmpint (reloaded.entries.size, CompareOperator.EQ, 1);
    assert_cmpstrv (reloaded.entries[0].uris, { "https://b.example.com" });
    remove_dir (Path.get_dirname (parts));
}

void test_add_line () {
    var parts = make_temp_copy ();
    var path = Path.build_filename (parts, "additional-repositories.list");
    try {
        var file = new AptSources.SourceFile (path).load ();
        file.add_line ("deb https://new.example.com trixie main");
        file.save ();
    } catch (Error e) {
        error ("%s", e.message);
    }
    assert_cmpstr (read_file (path), CompareOperator.EQ, "deb https://new.example.com trixie main\n");
    var mode = 0;
    Posix.Stat info;
    Posix.stat (path, out info);
    mode = (int) (info.st_mode & 0777);
    assert_cmpint (mode, CompareOperator.EQ, 0644);
    remove_dir (Path.get_dirname (parts));
}

void test_remove_duplicates () {
    var parts = make_temp_copy ();
    var path = Path.build_filename (parts, "zz-duplicate.list");
    write_file (path, "deb https://unsigned.example.com/ trixie main\ndeb https://unique.example.com trixie main\n");
    var files = AptSources.load_files ("/nonexistent", parts);
    var modified = AptSources.remove_duplicates (files);
    assert_cmpint (modified.size, CompareOperator.EQ, 1);
    assert_cmpstr (modified[0].name, CompareOperator.EQ, "zz-duplicate");
    try {
        foreach (var file in modified) {
            file.save ();
        }
    } catch (Error e) {
        error ("%s", e.message);
    }
    assert_cmpstr (read_file (path), CompareOperator.EQ, "deb https://unique.example.com trixie main\n");
    remove_dir (Path.get_dirname (parts));
}

void test_expand_http_line () {
    assert_cmpstr (AptSources.expand_http_line ("http://example.com/debian", "trixie"), CompareOperator.EQ, "deb http://example.com/debian trixie main");
    assert_cmpstr (AptSources.expand_http_line ("http://example.com/debian contrib non-free", "trixie"), CompareOperator.EQ, "deb http://example.com/debian trixie contrib non-free");
    assert_cmpstr (AptSources.expand_http_line ("deb http://example.com/debian sid main", "trixie"), CompareOperator.EQ, "deb http://example.com/debian sid main");
}

void test_repo_malformed () {
    assert_false (AptSources.repo_malformed ("deb http://example.com/debian trixie main"));
    assert_false (AptSources.repo_malformed ("deb [signed-by=/k.gpg arch=amd64] http://example.com/debian trixie main"));
    assert_false (AptSources.repo_malformed ("deb-src http://example.com/debian ./"));
    assert_true (AptSources.repo_malformed ("deb http://example.com/debian"));
    assert_true (AptSources.repo_malformed ("ppa:someone/something"));
    assert_true (AptSources.repo_malformed ("# deb http://example.com/debian trixie main"));
}

void test_cdrom () {
    var entry = AptSources.LegacyEntry.parse (null, "# deb cdrom:[Debian GNU/Linux 13.0.0 _Trixie_ - Official amd64 DVD Binary-1]/ trixie contrib main");
    assert_nonnull (entry);
    assert_false (entry.enabled);
    assert_cmpstrv (entry.suites, { "trixie" });
    assert_cmpstrv (entry.components, { "contrib", "main" });
}

void test_repo_exists () {
    var entries = new Gee.ArrayList<AptSources.Entry> ();
    entries.add (AptSources.LegacyEntry.parse (null, "deb http://example.com/debian/ trixie main contrib"));
    assert_true (AptSources.repo_exists ("deb http://example.com/debian trixie main", entries));
    assert_true (AptSources.repo_exists ("deb [signed-by=/k.gpg] http://example.com/debian trixie contrib main", entries));
    assert_false (AptSources.repo_exists ("deb http://example.com/debian trixie main non-free", entries));
    assert_false (AptSources.repo_exists ("deb-src http://example.com/debian trixie main", entries));
}

void test_versions () {
    assert_cmpint (DebVersion.compare ("1.0", "1.0"), CompareOperator.EQ, 0);
    assert_cmpint (DebVersion.compare ("1.0-1", "1.0-2"), CompareOperator.LT, 0);
    assert_cmpint (DebVersion.compare ("1:0.1", "2.0"), CompareOperator.GT, 0);
    assert_cmpint (DebVersion.compare ("1.0~rc1", "1.0"), CompareOperator.LT, 0);
    assert_cmpint (DebVersion.compare ("1.0+b1", "1.0"), CompareOperator.GT, 0);
    assert_cmpint (DebVersion.compare ("2.10", "2.9"), CompareOperator.GT, 0);
    assert_cmpint (DebVersion.compare ("1.0a", "1.0"), CompareOperator.GT, 0);
    assert_cmpint (DebVersion.compare ("1.0~", "1.0~~"), CompareOperator.GT, 0);
    assert_cmpint (DebVersion.compare ("5.3-4+b1", "5.3-4"), CompareOperator.GT, 0);
    assert_cmpint (DebVersion.compare ("1.01", "1.1"), CompareOperator.EQ, 0);
}

void test_nul_byte_is_never_rewritten () {
    var parts = make_temp_copy ();
    var path = Path.build_filename (parts, "nul.list");
    uint8[] bytes = "deb http://x.org/d stable main\n# bad".data;
    bytes += 0;
    foreach (var b in "byte\ndeb http://y.org/d stable main\n".data) {
        bytes += b;
    }
    try {
        FileUtils.set_data (path, bytes);
    } catch (FileError e) {
        error ("%s", e.message);
    }
    var file = new AptSources.SourceFile (path).load ();
    assert_nonnull (file.load_error);
    assert_cmpint (file.entries.size, CompareOperator.EQ, 0);
    try {
        file.save ();
        assert_not_reached ();
    } catch (Error e) {
    }
    assert_true (FileUtils.test (path, FileTest.EXISTS));
    uint8[] data;
    try {
        FileUtils.get_data (path, out data);
    } catch (FileError e) {
        error ("%s", e.message);
    }
    assert_cmpint (data.length, CompareOperator.EQ, bytes.length);
    remove_dir (Path.get_dirname (parts));
}

void test_symlink_target_is_written () {
    var parts = make_temp_copy ();
    var real = Path.build_filename (Path.get_dirname (parts), "real.list");
    write_file (real, "deb http://a.org/d stable main\ndeb http://b.org/d stable main\n");
    var link = Path.build_filename (parts, "link.list");
    FileUtils.symlink ("../real.list", link);
    try {
        var file = new AptSources.SourceFile (link).load ();
        file.remove (file.entries[0]);
        file.save ();
    } catch (Error e) {
        error ("%s", e.message);
    }
    assert_true (FileUtils.test (link, FileTest.IS_SYMLINK));
    assert_cmpstr (read_file (real), CompareOperator.EQ, "deb http://b.org/d stable main\n");
    FileUtils.unlink (real);
    remove_dir (Path.get_dirname (parts));
}

void test_lone_cr_deb822 () {
    var parts = make_temp_copy ();
    var path = Path.build_filename (parts, "cr.sources");
    write_file (path, "Types: deb\rURIs: http://x.org/d\rSuites: stable\rComponents: main\r\rTypes: deb\rURIs: http://y.org\rSuites: s\r");
    assert_cmpint (new AptSources.SourceFile (path).load ().entries.size, CompareOperator.EQ, 2);
    remove_dir (Path.get_dirname (parts));
}

void test_newline_file_name_ignored () {
    var parts = make_temp_copy ();
    write_file (Path.build_filename (parts, "bad.list\n"), "deb http://x.org/d stable main\n");
    foreach (var path in AptSources.source_file_paths ("/nonexistent", parts)) {
        assert_false ("\n" in path);
    }
    remove_dir (Path.get_dirname (parts));
}

void test_main_list_is_kept_when_empty () {
    var parts = make_temp_copy ();
    var main_path = Path.build_filename (Path.get_dirname (parts), "sources.list");
    write_file (main_path, "# my main\ndeb http://x.org/d stable main\n");
    var official = Path.build_filename (parts, "debian.sources");
    write_file (official, "Types: deb\nURIs: http://x.org/d\nSuites: stable\nComponents: main\n");
    AptSources.main_list = main_path;
    var modified = AptSources.remove_duplicates_keeping (AptSources.load_files (main_path, parts), official);
    try {
        foreach (var file in modified) {
            file.save ();
        }
    } catch (Error e) {
        error ("%s", e.message);
    }
    AptSources.main_list = AptSources.SOURCES_LIST;
    assert_cmpstr (read_file (main_path), CompareOperator.EQ, "# my main\n");
    assert_true (FileUtils.test (official, FileTest.EXISTS));
    remove_dir (Path.get_dirname (parts));
}

void test_unicode_input () {
    assert_cmpstr (AptSources.unicode_strip ("\u00a0 deb http://nb.example/ sid main\u00a0\n"), CompareOperator.EQ, "deb http://nb.example/ sid main");
    assert_cmpstr (AptSources.unicode_strip ("  \t "), CompareOperator.EQ, "");
    assert_cmpstr (AptSources.unicode_strip ("\vdeb x"), CompareOperator.EQ, "deb x");
    assert_cmpstr (AptSources.unicode_strip ("é"), CompareOperator.EQ, "é");
    assert_true (AptSources.repo_malformed ("deb [a=b\ndeb http://evil/ sid main] http://x/ sid main"));
    assert_true (AptSources.repo_malformed ("deb http://x/ sid main\r"));
}

void test_entry_outlives_file_list () {
    var parts = make_temp_copy ();
    var files = AptSources.load_files ("/nonexistent", parts);
    var entry = files[0].entries[0];
    assert_true (entry.file == files[0]);
    entry.set_enabled (!entry.enabled);
    try {
        entry.file.save ();
    } catch (Error e) {
        error ("%s", e.message);
    }
    remove_dir (Path.get_dirname (parts));
}

void test_empty_uri_values () {
    var parts = make_temp_copy ();
    var path = Path.build_filename (parts, "blank.sources");
    write_file (path, "Types: deb\nURIs:\n \u00a0\nSuites: sid\n");
    assert_cmpint (new AptSources.SourceFile (path).load ().entries.size, CompareOperator.EQ, 0);
    remove_dir (Path.get_dirname (parts));
}

public int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/apt-sources/repo-key-path", test_repo_key_path);
    Test.add_func ("/apt-sources/ignored-files", test_ignored_files);
    Test.add_func ("/apt-sources/round-trip", test_round_trip);
    Test.add_func ("/apt-sources/toggle-legacy", test_toggle_legacy);
    Test.add_func ("/apt-sources/toggle-deb822", test_toggle_deb822);
    Test.add_func ("/apt-sources/remove-last-entry-deletes-file", test_remove_last_entry_deletes_file);
    Test.add_func ("/apt-sources/remove-one-entry", test_remove_one_entry);
    Test.add_func ("/apt-sources/deb822-multiple-stanzas", test_deb822_multiple_stanzas);
    Test.add_func ("/apt-sources/add-line", test_add_line);
    Test.add_func ("/apt-sources/remove-duplicates", test_remove_duplicates);
    Test.add_func ("/lines/expand-http-line", test_expand_http_line);
    Test.add_func ("/lines/repo-malformed", test_repo_malformed);
    Test.add_func ("/lines/cdrom", test_cdrom);
    Test.add_func ("/lines/repo-exists", test_repo_exists);
    Test.add_func ("/versions/compare", test_versions);
    Test.add_func ("/robustness/nul-byte", test_nul_byte_is_never_rewritten);
    Test.add_func ("/robustness/symlink-target", test_symlink_target_is_written);
    Test.add_func ("/robustness/lone-cr-deb822", test_lone_cr_deb822);
    Test.add_func ("/robustness/newline-file-name", test_newline_file_name_ignored);
    Test.add_func ("/robustness/main-list-kept", test_main_list_is_kept_when_empty);
    Test.add_func ("/robustness/unicode-input", test_unicode_input);
    Test.add_func ("/robustness/entry-outlives-file-list", test_entry_outlives_file_list);
    Test.add_func ("/robustness/empty-uri-values", test_empty_uri_values);
    return Test.run ();
}
