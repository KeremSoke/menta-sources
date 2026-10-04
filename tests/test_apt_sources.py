import sys, os

tests_path = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, tests_path + "/../usr/lib/menta-sources/")

import shutil
import tempfile
import unittest

import apt_sources

SOURCES_DIR = os.path.join(tests_path, "testdata", "sources.list.d")


class RepoKeyPath(unittest.TestCase):
    def setUp(self):
        self.entries = apt_sources.all_entries(
            apt_sources.load_files("/nonexistent/sources.list", SOURCES_DIR))

    def test_repo_key_path(self):
        repo_key_path = lambda uri: apt_sources.repo_key_path(uri, self.entries)
        # Deb822 source format.
        self.assertEqual(repo_key_path("https://deb822.example.com"), "/usr/share/keyrings/deb822.gpg")
        # Legacy source format.
        self.assertEqual(repo_key_path("https://legacy.example.com"), "/usr/share/keyrings/legacy.gpg")
        # Input URI with trailing slash.
        self.assertEqual(repo_key_path("https://deb822.example.com/"), "/usr/share/keyrings/deb822.gpg")
        # Source repository URI with trailing slash, and other options.
        self.assertEqual(repo_key_path("https://legacy-dev.example.com"), "/usr/share/keyrings/legacy-dev.gpg")
        # Not signed-by source.
        self.assertEqual(repo_key_path("https://unsigned.example.com"), None)
        # Signed but disabled Deb822 source format.
        self.assertEqual(repo_key_path("https://deb822-disabled.example.com"), None)
        # Signed but disabled legacy source format.
        self.assertEqual(repo_key_path("https://disabled.example.com"), None)

    def test_ignored_files(self):
        self.assertFalse(any("ignored" in entry.uris[0] for entry in self.entries))
        self.assertEqual(len(self.entries), 6)


class EditFiles(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.parts = os.path.join(self.tmpdir, "sources.list.d")
        shutil.copytree(SOURCES_DIR, self.parts)

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def read(self, name):
        with open(os.path.join(self.parts, name)) as f:
            return f.read()

    def load(self, name):
        return apt_sources.SourceFile(os.path.join(self.parts, name)).load()

    def test_round_trip(self):
        for name in ("legacy.list", "deb822.sources", "deb822-disabled.sources"):
            self.assertEqual(self.load(name).text(), self.read(name))

    def test_toggle_legacy(self):
        source_file = self.load("legacy.list")
        entry = source_file.entries[0]
        entry.set_enabled(False)
        source_file.save()
        self.assertIn("# deb [signed-by=/usr/share/keyrings/legacy.gpg] https://legacy.example.com trixie main", self.read("legacy.list"))
        source_file = self.load("legacy.list")
        self.assertFalse(source_file.entries[0].enabled)
        source_file.entries[0].set_enabled(True)
        source_file.save()
        self.assertEqual(self.read("legacy.list").splitlines()[1],
                         "deb [signed-by=/usr/share/keyrings/legacy.gpg] https://legacy.example.com trixie main")

    def test_toggle_deb822(self):
        source_file = self.load("deb822.sources")
        source_file.entries[0].set_enabled(False)
        source_file.save()
        content = self.read("deb822.sources")
        self.assertIn("Enabled: no", content)
        self.assertNotIn("Enabled: yes", content)
        self.assertFalse(self.load("deb822.sources").entries[0].enabled)

        source_file = self.load("deb822-disabled.sources")
        source_file.entries[0].set_enabled(True)
        source_file.save()
        content = self.read("deb822-disabled.sources")
        self.assertNotIn("Enabled", content)
        self.assertTrue(content.startswith("# A comment before the stanza\n"))
        self.assertTrue(self.load("deb822-disabled.sources").entries[0].enabled)

    def test_remove_last_entry_deletes_file(self):
        source_file = self.load("unsigned.list")
        source_file.remove(source_file.entries[0])
        source_file.save()
        self.assertFalse(os.path.exists(os.path.join(self.parts, "unsigned.list")))

    def test_remove_one_entry(self):
        source_file = self.load("legacy.list")
        source_file.remove(source_file.entries[0])
        source_file.save()
        self.assertEqual(self.read("legacy.list"),
                         "# Legacy one-line entries\n"
                         "deb [arch=amd64 signed-by=/usr/share/keyrings/legacy-dev.gpg] https://legacy-dev.example.com/ trixie main\n")

    def test_deb822_multiple_stanzas(self):
        path = os.path.join(self.parts, "multi.sources")
        with open(path, "w") as f:
            f.write("Types: deb deb-src\nURIs: https://a.example.com\nSuites: trixie\nComponents: main\n\n\n"
                    "Types: deb\nURIs: https://b.example.com\nSuites: trixie\nComponents: main\n"
                    "Signed-By:\n -----BEGIN PGP PUBLIC KEY BLOCK-----\n .\n abc\n -----END PGP PUBLIC KEY BLOCK-----\n")
        source_file = apt_sources.SourceFile(path).load()
        self.assertEqual(len(source_file.entries), 2)
        self.assertEqual(source_file.entries[0].types, ["deb", "deb-src"])
        # Inline keys aren't keyring paths
        self.assertIsNone(source_file.entries[1].signed_by)
        source_file.remove(source_file.entries[0])
        source_file.save()
        reloaded = apt_sources.SourceFile(path).load()
        self.assertEqual(len(reloaded.entries), 1)
        self.assertEqual(reloaded.entries[0].uris, ["https://b.example.com"])

    def test_add_line(self):
        path = os.path.join(self.parts, "additional-repositories.list")
        source_file = apt_sources.SourceFile(path).load()
        source_file.add_line("deb https://new.example.com trixie main")
        source_file.save()
        self.assertEqual(self.read("additional-repositories.list"), "deb https://new.example.com trixie main\n")

    def test_remove_duplicates(self):
        with open(os.path.join(self.parts, "zz-duplicate.list"), "w") as f:
            f.write("deb https://unsigned.example.com/ trixie main\ndeb https://unique.example.com trixie main\n")
        files = apt_sources.load_files("/nonexistent", self.parts)
        modified = apt_sources.remove_duplicates(files)
        self.assertEqual([f.name for f in modified], ["zz-duplicate"])
        for source_file in modified:
            source_file.save()
        self.assertEqual(self.read("zz-duplicate.list"), "deb https://unique.example.com trixie main\n")


class Lines(unittest.TestCase):
    def test_expand_http_line(self):
        self.assertEqual(apt_sources.expand_http_line("http://example.com/debian", "trixie"),
                         "deb http://example.com/debian trixie main")
        self.assertEqual(apt_sources.expand_http_line("http://example.com/debian contrib non-free", "trixie"),
                         "deb http://example.com/debian trixie contrib non-free")
        self.assertEqual(apt_sources.expand_http_line("deb http://example.com/debian sid main", "trixie"),
                         "deb http://example.com/debian sid main")

    def test_repo_malformed(self):
        self.assertFalse(apt_sources.repo_malformed("deb http://example.com/debian trixie main"))
        self.assertFalse(apt_sources.repo_malformed("deb [signed-by=/k.gpg arch=amd64] http://example.com/debian trixie main"))
        self.assertFalse(apt_sources.repo_malformed("deb-src http://example.com/debian ./"))
        self.assertTrue(apt_sources.repo_malformed("deb http://example.com/debian"))
        self.assertTrue(apt_sources.repo_malformed("ppa:someone/something"))
        self.assertTrue(apt_sources.repo_malformed("# deb http://example.com/debian trixie main"))

    def test_cdrom(self):
        entry = apt_sources.LegacyEntry.parse(None, "# deb cdrom:[Debian GNU/Linux 13.0.0 _Trixie_ - Official amd64 DVD Binary-1]/ trixie contrib main")
        self.assertIsNotNone(entry)
        self.assertFalse(entry.enabled)
        self.assertEqual(entry.suites, ["trixie"])
        self.assertEqual(entry.components, ["contrib", "main"])

    def test_repo_exists(self):
        entries = [apt_sources.LegacyEntry.parse(None, "deb http://example.com/debian/ trixie main contrib")]
        self.assertTrue(apt_sources.repo_exists("deb http://example.com/debian trixie main", entries))
        self.assertTrue(apt_sources.repo_exists("deb [signed-by=/k.gpg] http://example.com/debian trixie contrib main", entries))
        self.assertFalse(apt_sources.repo_exists("deb http://example.com/debian trixie main non-free", entries))
        self.assertFalse(apt_sources.repo_exists("deb-src http://example.com/debian trixie main", entries))


if __name__ == "__main__":
    unittest.main()
