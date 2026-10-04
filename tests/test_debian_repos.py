import sys, os

tests_path = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, tests_path + "/../usr/lib/menta-sources/")

import shutil
import tempfile
import unittest

import apt_sources
import debian_repos

CONFIG_DIR = os.path.join(tests_path, "..", "usr", "share", "menta-sources")

TRIXIE_SOURCES_LIST = """#deb cdrom:[Debian GNU/Linux 13.0.0 _Trixie_ - Official amd64 DVD Binary-1]/ trixie contrib main

deb http://ftp.de.debian.org/debian/ trixie main non-free-firmware
deb-src http://ftp.de.debian.org/debian/ trixie main non-free-firmware

deb http://security.debian.org/debian-security trixie-security main non-free-firmware
deb-src http://security.debian.org/debian-security trixie-security main non-free-firmware

# trixie-updates, to get updates before a point release is made;
deb http://ftp.de.debian.org/debian/ trixie-updates main non-free-firmware
deb-src http://ftp.de.debian.org/debian/ trixie-updates main non-free-firmware

deb https://thirdparty.example.com/debian trixie main
"""


class Releases(unittest.TestCase):
    def test_all_configs_load(self):
        codenames = sorted(os.listdir(CONFIG_DIR))
        self.assertEqual(codenames, ["bookworm", "forky", "sid", "trixie"])
        for codename in codenames:
            release = debian_repos.load_release(codename, CONFIG_DIR)
            self.assertEqual(release.codename, codename)
            self.assertIn("main", release.components)

    def test_classify_suite(self):
        release = debian_repos.load_release("trixie", CONFIG_DIR)
        self.assertEqual(release.classify_suite("trixie"), (None, False))
        self.assertEqual(release.classify_suite("stable"), (None, False))
        self.assertEqual(release.classify_suite("trixie-security"), ("security", False))
        self.assertEqual(release.classify_suite("stable-updates"), ("updates", False))
        self.assertEqual(release.classify_suite("trixie-backports-debug"), ("backports", True))
        self.assertEqual(release.classify_suite("trixie/updates"), ("security", False))
        self.assertRaises(ValueError, release.classify_suite, "sid")
        self.assertRaises(ValueError, release.classify_suite, "bookworm")


class Render(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.path = os.path.join(self.tmpdir, "debian.sources")

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def round_trip(self, release, settings):
        debian_repos.write(release, settings, self.path)
        entries = apt_sources.SourceFile(self.path).load().entries
        return debian_repos.detect_settings(release, entries)

    def test_trixie_defaults(self):
        release = debian_repos.load_release("trixie", CONFIG_DIR)
        settings = debian_repos.default_settings(release)
        content = debian_repos.render(release, settings)
        self.assertIn("Types: deb\nURIs: https://deb.debian.org/debian\nSuites: trixie trixie-updates\n"
                      "Components: main contrib non-free non-free-firmware\n"
                      "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg\n", content)
        self.assertIn("URIs: https://security.debian.org/debian-security\nSuites: trixie-security\n", content)
        self.assertNotIn("debug", content)
        self.assertEqual(self.round_trip(release, settings), settings)

    def test_everything_enabled(self):
        release = debian_repos.load_release("trixie", CONFIG_DIR)
        settings = debian_repos.Settings("http://ftp.fr.debian.org/debian", release.security_mirror,
                                         ["main", "contrib"], release.suites, source_code=True, debug=True)
        content = debian_repos.render(release, settings)
        self.assertIn("Types: deb deb-src\nURIs: http://ftp.fr.debian.org/debian\n"
                      "Suites: trixie trixie-updates trixie-backports trixie-proposed-updates\n", content)
        self.assertIn("URIs: https://deb.debian.org/debian-debug\n"
                      "Suites: trixie-debug trixie-backports-debug trixie-proposed-updates-debug\n", content)
        self.assertIn("URIs: https://deb.debian.org/debian-security-debug\nSuites: trixie-security-debug\n", content)
        self.assertEqual(self.round_trip(release, settings), settings)

    def test_sid(self):
        release = debian_repos.load_release("sid", CONFIG_DIR)
        settings = debian_repos.default_settings(release)
        content = debian_repos.render(release, settings)
        self.assertIn("Suites: sid\n", content)
        self.assertNotIn("security", content)
        settings.suites = ["experimental"]
        settings.debug = True
        content = debian_repos.render(release, settings)
        self.assertIn("Suites: sid experimental\n", content)
        self.assertIn("Suites: sid-debug experimental-debug\n", content)
        self.assertEqual(self.round_trip(release, settings), settings)


class Migration(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.sources_list = os.path.join(self.tmpdir, "sources.list")
        self.parts = os.path.join(self.tmpdir, "sources.list.d")
        self.official = os.path.join(self.parts, "debian.sources")
        self.backups = os.path.join(self.tmpdir, "backups")
        os.makedirs(self.parts)
        with open(self.sources_list, "w") as f:
            f.write(TRIXIE_SOURCES_LIST)
        self.release = debian_repos.load_release("trixie", CONFIG_DIR)

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def prepare(self):
        files = apt_sources.load_files(self.sources_list, self.parts)
        return debian_repos.prepare(self.release, files, self.official, self.backups)

    def test_is_official(self):
        entries = apt_sources.all_entries(apt_sources.load_files(self.sources_list, self.parts))
        official = [e for e in entries if debian_repos.is_official(self.release, e)]
        self.assertEqual(len(official), 6)
        self.assertFalse(any("example.com" in e.uris[0] or "cdrom" in e.uris[0] for e in official))

    def test_migrate_sources_list(self):
        settings, migrated = self.prepare()
        self.assertEqual(settings.mirror, "http://ftp.de.debian.org/debian")
        self.assertEqual(settings.security_mirror, "http://security.debian.org/debian-security")
        self.assertEqual(settings.components, ["main", "non-free-firmware"])
        self.assertEqual(settings.suites, ["security", "updates"])
        self.assertTrue(settings.source_code)
        self.assertFalse(settings.debug)

        self.assertEqual([path for path, backup in migrated], [self.sources_list])
        with open(migrated[0][1]) as f:
            self.assertEqual(f.read(), TRIXIE_SOURCES_LIST)

        # Only the third party repository and the cdrom are left
        remaining = apt_sources.SourceFile(self.sources_list).load().entries
        self.assertEqual([e.uris[0] for e in remaining],
                         ["cdrom:[Debian GNU/Linux 13.0.0 _Trixie_ - Official amd64 DVD Binary-1]/",
                          "https://thirdparty.example.com/debian"])

        official_entries = apt_sources.SourceFile(self.official).load().entries
        self.assertEqual(debian_repos.detect_settings(self.release, official_entries), settings)

        # Nothing left to migrate the second time
        self.assertEqual(self.prepare(), (settings, []))

    def test_existing_official_file_wins(self):
        settings = debian_repos.Settings("https://ftp.us.debian.org/debian", self.release.security_mirror,
                                         ["main"], ["security", "backports"])
        debian_repos.write(self.release, settings, self.official)
        result, migrated = self.prepare()
        self.assertEqual(result.mirror, "https://ftp.us.debian.org/debian")
        # What sources.list provided is merged in so that nothing apt used is lost
        self.assertEqual(result.components, ["main", "non-free-firmware"])
        self.assertEqual(result.suites, ["security", "updates", "backports"])
        self.assertTrue(result.source_code)
        self.assertEqual(len(migrated), 1)

    def test_nothing_configured(self):
        os.unlink(self.sources_list)
        settings, migrated = self.prepare()
        self.assertEqual(settings, debian_repos.default_settings(self.release))
        self.assertEqual(migrated, [])
        self.assertTrue(os.path.exists(self.official))

    def test_modernized_sources_are_kept(self):
        # The file written by "apt modernize-sources" isn't rewritten on startup
        os.unlink(self.sources_list)
        content = ("Types: deb\nURIs: http://ftp.de.debian.org/debian/\nSuites: trixie trixie-updates\n"
                   "Components: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n")
        with open(self.official, "w") as f:
            f.write(content)
        settings, migrated = self.prepare()
        self.assertEqual(settings.mirror, "http://ftp.de.debian.org/debian")
        self.assertEqual(settings.suites, ["updates"])
        with open(self.official) as f:
            self.assertEqual(f.read(), content)


class Codename(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.os_release = os.path.join(self.tmpdir, "os-release")
        self.debian_version = os.path.join(self.tmpdir, "debian_version")

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def write(self, os_release, debian_version):
        with open(self.os_release, "w") as f:
            f.write(os_release)
        with open(self.debian_version, "w") as f:
            f.write(debian_version)

    def detect(self, lines=()):
        entries = [apt_sources.LegacyEntry.parse(None, line) for line in lines]
        return debian_repos.detect_codename(entries, self.os_release, self.debian_version)

    def test_stable(self):
        self.write('PRETTY_NAME="Debian GNU/Linux 13 (trixie)"\nVERSION_CODENAME=trixie\n\nID=debian\n', "13.1\n")
        self.assertEqual(self.detect(), "trixie")

    def test_testing_and_unstable(self):
        self.write('PRETTY_NAME="Debian GNU/Linux forky/sid"\nVERSION_CODENAME="forky"\n', "forky/sid\n")
        self.assertEqual(self.detect(["deb http://deb.debian.org/debian forky main"]), "forky")
        self.assertEqual(self.detect(["deb http://deb.debian.org/debian unstable main"]), "sid")
        self.assertEqual(self.detect(["# deb http://deb.debian.org/debian sid main"]), "forky")


if __name__ == "__main__":
    unittest.main()
