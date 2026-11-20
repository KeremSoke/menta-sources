namespace Menta.AddAptRepository {
    private bool force_yes = false;
    private bool remove = false;

    private const OptionEntry[] OPTIONS = {
        { "yes", 'y', OptionFlags.NONE, OptionArg.NONE, ref force_yes, N_("force yes on all confirmation questions"), null },
        { "remove", 'r', OptionFlags.NONE, OptionArg.NONE, ref remove, N_("Remove the specified repository"), null },
        { null }
    };

    public int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        Intl.bindtextdomain (Config.GETTEXT_PACKAGE, Config.LOCALEDIR);
        Intl.bind_textdomain_codeset (Config.GETTEXT_PACKAGE, "UTF-8");
        Intl.textdomain (Config.GETTEXT_PACKAGE);
        Posix.umask (0022);

        var context = new OptionContext (_("repository"));
        context.add_main_entries (OPTIONS, Config.GETTEXT_PACKAGE);
        try {
            context.parse (ref args);
        } catch (OptionError e) {
            printerr ("%s\n", e.message);
            return 2;
        }

        if (Posix.geteuid () != 0) {
            print ("%s\n", _("Error: must run as root"));
            return 1;
        }

        if (args.length < 2) {
            print ("%s\n", _("Error: need a repository as argument"));
            return 1;
        }

        var line = AptSources.unicode_strip (string.joinv (" ", args[1:args.length]));

        if (line.has_prefix ("ppa:") || "launchpad" in line) {
            print ("%s\n", _("PPAs are built for Ubuntu and are not supported on Debian."));
            return 1;
        }

        var files = AptSources.load_files ();
        var codename = DebianRepos.detect_codename (AptSources.all_entries (files));
        line = AptSources.expand_http_line (line, codename);

        if (AptSources.repo_malformed (line)) {
            print ("%s\n", _("Malformed input, repository not added."));
            return 1;
        }

        try {
            if (remove) {
                var matches = new Gee.ArrayList<AptSources.Entry> ();
                foreach (var entry in AptSources.find_entries (line, files)) {
                    if (entry.file.path != DebianRepos.OFFICIAL_FILE) {
                        matches.add (entry);
                    }
                }
                if (matches.size == 0) {
                    print ("%s\n", _("Repository not found."));
                    return 1;
                }
                foreach (var entry in matches) {
                    print ("%s %s\n", _("Removing from %s:").printf (entry.file.path), entry.text ());
                    var file = entry.file;
                    file.remove (entry);
                    file.save ();
                }
            } else if (AptSources.repo_exists (line, AptSources.all_entries (files))) {
                print ("%s\n", _("Repository already exists."));
            } else {
                var file = new AptSources.SourceFile (AptSources.ADDITIONAL_REPOSITORIES).load ();
                file.add_line (line);
                file.save ();
                print ("%s %s\n", _("Added to %s:").printf (file.path), line);
            }
        } catch (Error e) {
            printerr ("E: %s\n", e.message);
            return 1;
        }
        return 0;
    }
}
