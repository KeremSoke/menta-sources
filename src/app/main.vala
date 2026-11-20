namespace Menta {
    private void show_startup_error (string primary, string secondary) {
        var dialog = new Gtk.MessageDialog (null, Gtk.DialogFlags.MODAL, Gtk.MessageType.ERROR, Gtk.ButtonsType.CLOSE, "%s", primary);
        dialog.format_secondary_text ("%s", secondary);
        dialog.set_title (_("Software Sources"));
        dialog.set_icon_name ("menta-sources");
        dialog.run ();
        dialog.destroy ();
    }

    private DebianRepos.Release? load_release () {
        var entries = AptSources.all_entries (AptSources.load_files ());
        var codename = DebianRepos.detect_codename (entries);
        try {
            return DebianRepos.load_release (codename, Config.PKGDATADIR);
        } catch (Error e) {
            print ("OS codename: '%s'.\n", codename);
            print ("This codename isn't currently supported: %s\n", e.message);
            print ("Please check your OS release information with \"cat /etc/os-release\" (identified as VERSION_CODENAME).\n");
            show_startup_error (_("This version of Debian isn't supported."),
                                _("The release \"%s\" is not supported by Software Sources.").printf (codename));
            return null;
        }
    }

    public int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        Intl.bindtextdomain (Config.GETTEXT_PACKAGE, Config.LOCALEDIR);
        Intl.bind_textdomain_codeset (Config.GETTEXT_PACKAGE, "UTF-8");
        Intl.textdomain (Config.GETTEXT_PACKAGE);
        Posix.umask (0022);

        bool no_update = false;
        foreach (var arg in args[1:args.length]) {
            if (arg == "-n" || arg == "--no-update") {
                no_update = true;
            } else if (arg == "-h" || arg == "--help") {
                print ("usage: %s [-h] [-n]\n\nSoftware sources for Debian\n\noptions:\n  -h, --help       show this help message and exit\n  -n, --no-update  Disable cache refresh prompting\n", Path.get_basename (args[0]));
                return 0;
            } else if (arg == "--version") {
                print ("menta-sources %s\n", Config.VERSION);
                return 0;
            }
        }

        Environment.set_prgname ("menta-sources");
        Environment.set_application_name (_("Software Sources"));
        Gtk.init (ref args);
        Gtk.Window.set_default_icon_name ("menta-sources");

        Unix.signal_add (Posix.Signal.INT, () => {
            print ("\n");
            Process.exit (128 + Posix.Signal.INT);
        });

        var release = load_release ();
        if (release == null) {
            return 1;
        }

        var privileged = new Privileged ();
        try {
            if (!privileged.start ()) {
                show_startup_error (_("Administrator privileges are required."),
                                    _("Software Sources needs administrator privileges to change the software sources of the system."));
                return 1;
            }
        } catch (Error e) {
            show_startup_error (_("Administrator privileges are required."), e.message);
            return 1;
        }
        Files.set_storage (privileged);

        Application application;
        try {
            application = new Application (release, privileged, no_update);
        } catch (Error e) {
            show_startup_error (_("The software sources could not be loaded."), e.message);
            privileged.stop ();
            return 1;
        }
        application.run ();
        privileged.stop ();
        return application.sources_changed ? 1 : 0;
    }
}
