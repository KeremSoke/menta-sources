namespace Menta {
    public const string USER_AGENT = "menta-sources (Debian; +https://www.debian.org/mirror/)";
    public const int SPEED_PIX_WIDTH = 125;

    public class MirrorDialog : Object {
        private enum Column {
            MIRROR,
            URL,
            COUNTRY,
            SPEED,
            SPEED_LABEL,
            TOOLTIP,
            NAME
        }

        private Gtk.Dialog dialog;
        private Gtk.TreeView treeview;
        private Gtk.ListStore model;
        private Gee.LinkedList<Gtk.TreeRowReference> queue = new Gee.LinkedList<Gtk.TreeRowReference> ();
        private Countries countries;
        private Soup.Session session;
        private Cancellable? cancellable = null;
        private DateTime? default_mirror_date = null;
        private string codename = "";
        private string arch = "amd64";
        private Application application;

        public MirrorDialog (Application application, Gtk.Builder builder) {
            this.application = application;
            dialog = (Gtk.Dialog) builder.get_object ("mirror_selection_dialog");
            dialog.set_transient_for (application.main_window);
            dialog.delete_event.connect (() => {
                dialog.response (Gtk.ResponseType.CANCEL);
                return true;
            });

            model = new Gtk.ListStore (7, typeof (Mirror), typeof (string), typeof (string), typeof (double), typeof (string), typeof (string), typeof (string));
            treeview = (Gtk.TreeView) builder.get_object ("mirrors_treeview");
            treeview.set_model (model);
            treeview.set_headers_clickable (true);
            treeview.row_activated.connect (() => dialog.response (Gtk.ResponseType.APPLY));
            model.set_sort_column_id (Column.SPEED, Gtk.SortType.DESCENDING);

            var column = new Gtk.TreeViewColumn.with_attributes (_("Country"), new Gtk.CellRendererText (), "text", Column.COUNTRY);
            column.set_sort_column_id (Column.COUNTRY);
            treeview.append_column (column);

            column = new Gtk.TreeViewColumn.with_attributes (_("Server"), new Gtk.CellRendererText (), "text", Column.NAME);
            column.set_expand (true);
            column.set_sort_column_id (Column.NAME);
            treeview.append_column (column);

            column = new Gtk.TreeViewColumn.with_attributes (_("Speed"), new Gtk.CellRendererText (), "text", Column.SPEED_LABEL);
            column.set_sort_column_id (Column.SPEED);
            column.set_min_width ((int) (1.1 * SPEED_PIX_WIDTH));
            treeview.append_column (column);

            treeview.set_tooltip_column (Column.TOOLTIP);

            countries = new Countries ();
            session = new Soup.Session ();
            session.user_agent = USER_AGENT;
            session.timeout = 10;

            string output;
            try {
                Process.spawn_command_line_sync ("dpkg --print-architecture", out output);
                if (output.strip () != "") {
                    arch = output.strip ();
                }
            } catch (SpawnError e) {
            }
        }

        private async void refresh_masterlist (DebianRepos.Release release, Cancellable cancel) {
            if (release.masterlist_url == "") {
                return;
            }
            var cache = Masterlist.cache_path ();
            var message = new Soup.Message ("GET", release.masterlist_url);
            if (message == null) {
                return;
            }
            if (FileUtils.test (cache, FileTest.IS_REGULAR)) {
                try {
                    var info = File.new_for_path (cache).query_info (FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                    var modified = info.get_modification_date_time ();
                    if (modified != null) {
                        message.request_headers.append ("If-Modified-Since", Soup.date_time_to_string (modified.to_utc (), Soup.DateFormat.HTTP));
                    }
                } catch (Error e) {
                }
            }
            try {
                var bytes = yield session.send_and_read_async (message, Priority.DEFAULT, cancel);
                if (message.status_code != Soup.Status.OK) {
                    return;
                }
                var content = bytes_to_string (bytes);
                if (Masterlist.parse (content, {}).size == 0) {
                    return;
                }
                DirectStorage.write_atomically (cache, content.data, 0644);
            } catch (Error e) {
                printerr ("W: Could not refresh the Debian mirror list: %s\n", e.message);
            }
        }

        private async DateTime? last_modified (string url, Cancellable? cancel, out bool answered = null) {
            answered = false;
            var message = new Soup.Message ("HEAD", url);
            if (message == null) {
                return null;
            }
            try {
                yield session.send_and_read_async (message, Priority.DEFAULT, cancel);
            } catch (Error e) {
                return null;
            }
            answered = message.status_code >= 100;
            if (message.status_code != Soup.Status.OK) {
                return null;
            }
            var header = message.response_headers.get_one ("Last-Modified");
            if (header == null) {
                return null;
            }
            return Soup.date_time_new_from_http_string (header);
        }

        private Gee.ArrayList<Mirror> visible_mirrors (Gee.List<Mirror> mirrors, DebianRepos.Release release) {
            var local_code = Countries.local_country_code ();
            var local = local_code != null ? countries.find (local_code) : null;
            var bordering = new Gee.HashSet<string> ();
            var neighbors = new Gee.HashSet<string> ();
            var subregion = new Gee.HashSet<string> ();
            var region = new Gee.HashSet<string> ();
            if (local != null) {
                foreach (var country in countries.all) {
                    if (country.region == local.region) {
                        if (country.subregion == local.subregion) {
                            subregion.add (country.cca2);
                        } else {
                            region.add (country.cca2);
                        }
                    }
                    if (local.borders.contains (country.cca3)) {
                        bordering.add (country.cca2);
                    } else if (local.network_neighbors.contains (country.cca3)) {
                        neighbors.add (country.cca2);
                    }
                }
            }

            var worldwide = new Gee.ArrayList<Mirror> ();
            var local_mirrors = new Gee.ArrayList<Mirror> ();
            var bordering_mirrors = new Gee.ArrayList<Mirror> ();
            var neighbor_mirrors = new Gee.ArrayList<Mirror> ();
            var subregional = new Gee.ArrayList<Mirror> ();
            var regional = new Gee.ArrayList<Mirror> ();
            var official = new Gee.ArrayList<Mirror> ();
            foreach (var mirror in mirrors) {
                if (mirror.country_code == WORLDWIDE) {
                    worldwide.add (mirror);
                } else if (local_code != null && mirror.country_code == local_code) {
                    local_mirrors.add (mirror);
                } else if (bordering.contains (mirror.country_code)) {
                    bordering_mirrors.add (mirror);
                } else if (neighbors.contains (mirror.country_code)) {
                    neighbor_mirrors.add (mirror);
                } else if (subregion.contains (mirror.country_code)) {
                    subregional.add (mirror);
                } else if (region.contains (mirror.country_code)) {
                    regional.add (mirror);
                } else if (mirror.url == release.mirror) {
                    official.add (mirror);
                }
            }
            CompareDataFunc<Mirror> by_country = (a, b) => strcmp (a.country_code, b.country_code);
            bordering_mirrors.sort ((owned) by_country);
            by_country = (a, b) => strcmp (a.country_code, b.country_code);
            neighbor_mirrors.sort ((owned) by_country);
            by_country = (a, b) => strcmp (a.country_code, b.country_code);
            subregional.sort ((owned) by_country);
            by_country = (a, b) => strcmp (a.country_code, b.country_code);
            regional.sort ((owned) by_country);

            var result = new Gee.ArrayList<Mirror> ();
            result.add_all (worldwide);
            result.add_all (local_mirrors);
            result.add_all (bordering_mirrors);
            result.add_all (neighbor_mirrors);
            result.add_all (subregional);
            result.add_all (regional);
            result.add_all (official);

            if (local == null || result.size - worldwide.size < 1) {
                result.clear ();
                result.add_all (mirrors);
            }
            return result;
        }

        private void fill (Gee.List<Mirror> mirrors) {
            model.clear ();
            queue.clear ();
            foreach (var mirror in mirrors) {
                var country = countries.name (mirror.country_code);
                var tooltip = country;
                if (mirror.location != "") {
                    tooltip = "%s, %s".printf (country, mirror.location);
                }
                if (mirror.name != mirror.url) {
                    tooltip = "%s: %s".printf (tooltip, mirror.url);
                }
                Gtk.TreeIter iter;
                model.insert_with_values (out iter, -1,
                    Column.MIRROR, mirror,
                    Column.URL, mirror.url,
                    Column.COUNTRY, country,
                    Column.SPEED, 0.0,
                    Column.SPEED_LABEL, null,
                    Column.TOOLTIP, tooltip,
                    Column.NAME, mirror.name);
                queue.offer_tail (new Gtk.TreeRowReference (model, model.get_path (iter)));
            }
        }

        public static string speed_label (double speed) {
            if (speed <= 0) {
                return "0 %s".printf (_("kB/s"));
            }
            double divider = 1024.0;
            double value = speed / divider;
            string unit = _("kB/s");
            if (value > divider) {
                value = value / divider;
                unit = _("MB/s");
            }
            if (value > divider) {
                value = value / divider;
                unit = _("GB/s");
            }
            string text;
            if ("%d".printf ((int) value).length > 2) {
                text = "%d %s".printf ((int) value, unit);
            } else {
                text = "%.1f %s".printf (value, unit);
            }
            return text.replace (".0 ", " ").replace (",0 ", " ");
        }

        private async double measure (string url, Cancellable cancel) {
            if (default_mirror_date != null) {
                bool answered;
                var mirror_date = yield last_modified ("%s/project/trace/master".printf (url), cancel, out answered);
                if (cancel.is_cancelled ()) {
                    return 0;
                }
                if (mirror_date == null) {
                    printerr ("Error: Can't find the age of %s !!\n", url);
                    return answered ? -1 : 0;
                }
                var age = default_mirror_date.difference (mirror_date) / TimeSpan.DAY;
                if (age > 2) {
                    printerr ("Error: %s is out of date by %d days!\n", url, (int) age);
                    return -1;
                }
            }
            var test_url = "%s/dists/%s/main/binary-%s/Packages.xz".printf (url, codename, arch);
            var message = new Soup.Message ("GET", test_url);
            if (message == null) {
                return 0;
            }
            var transfer = new Cancellable ();
            var cancel_handler = cancel.connect (() => transfer.cancel ());
            uint timeout = 0;
            timeout = Timeout.add_seconds (20, () => {
                timeout = 0;
                transfer.cancel ();
                return Source.REMOVE;
            });
            int64 received = 0;
            int64 started = 0;
            bool complete = false;
            try {
                var stream = yield session.send_async (message, Priority.DEFAULT, transfer);
                started = get_monotonic_time ();
                if (message.status_code == Soup.Status.OK) {
                    while (true) {
                        var chunk = yield stream.read_bytes_async (65536, Priority.DEFAULT, transfer);
                        if (chunk.get_size () == 0) {
                            complete = true;
                            break;
                        }
                        received += chunk.get_size ();
                    }
                }
                try {
                    yield stream.close_async (Priority.DEFAULT, null);
                } catch (Error e) {
                }
            } catch (Error e) {
                if (!(e is IOError.CANCELLED)) {
                    printerr ("Error '%s' on url %s\n", e.message, url);
                }
            }
            if (timeout != 0) {
                Source.remove (timeout);
            }
            cancel.disconnect (cancel_handler);
            if (cancel.is_cancelled () || message.status_code != Soup.Status.OK || received == 0) {
                return 0;
            }
            var elapsed = (get_monotonic_time () - started) / 1000000.0;
            if (elapsed <= 0) {
                return 0;
            }
            if (!complete && received < 65536) {
                return 0;
            }
            return received / elapsed;
        }

        private async void speed_tests (Cancellable cancel) {
            while (!queue.is_empty && !cancel.is_cancelled ()) {
                var reference = queue.poll_head ();
                if (!reference.valid ()) {
                    continue;
                }
                Gtk.TreeIter iter;
                model.get_iter (out iter, reference.get_path ());
                string url;
                model.get (iter, Column.URL, out url);
                var speed = yield measure (url, cancel);
                if (cancel.is_cancelled () || !reference.valid ()) {
                    return;
                }
                model.get_iter (out iter, reference.get_path ());
                if (speed == -1) {
                    model.set (iter, Column.SPEED_LABEL, _("Obsolete"));
                } else if (speed == 0) {
                    model.set (iter, Column.SPEED_LABEL, _("Unreachable"));
                } else {
                    model.set (iter, Column.SPEED, speed, Column.SPEED_LABEL, speed_label (speed));
                }
            }
        }

        public string? run (DebianRepos.Release release) {
            codename = release.codename;
            var loop = new MainLoop ();
            var preparation = new Cancellable ();
            uint limit = 0;
            limit = Timeout.add_seconds (15, () => {
                limit = 0;
                preparation.cancel ();
                return Source.REMOVE;
            });
            application.main_window.set_sensitive (false);
            application.set_busy (true);
            refresh_masterlist.begin (release, preparation, (obj, res) => {
                refresh_masterlist.end (res);
                if (preparation.is_cancelled ()) {
                    preparation = new Cancellable ();
                    limit = Timeout.add_seconds (10, () => {
                        limit = 0;
                        preparation.cancel ();
                        return Source.REMOVE;
                    });
                }
                last_modified.begin ("%s/project/trace/master".printf (release.mirror), preparation, (obj2, res2) => {
                    default_mirror_date = last_modified.end (res2);
                    loop.quit ();
                });
            });
            loop.run ();
            if (limit != 0) {
                Source.remove (limit);
            }
            application.set_busy (false);
            application.main_window.set_sensitive (true);

            var mirrors = Masterlist.load (release.masterlist, Masterlist.architectures ());
            bool has_default = false;
            foreach (var mirror in mirrors) {
                if (mirror.url == release.mirror) {
                    has_default = true;
                }
            }
            if (!has_default && release.mirror != "") {
                mirrors.insert (0, new Mirror (WORLDWIDE, release.mirror, release.mirror, DebianRepos.uri_host (release.mirror), "", 3));
            }

            fill (visible_mirrors (mirrors, release));
            cancellable = new Cancellable ();
            speed_tests.begin (cancellable);

            dialog.show_all ();
            var response = dialog.run ();
            string? result = null;
            if (response == Gtk.ResponseType.APPLY) {
                Gtk.TreeModel selected_model;
                Gtk.TreeIter iter;
                if (treeview.get_selection ().get_selected (out selected_model, out iter)) {
                    selected_model.get (iter, Column.URL, out result);
                }
            }
            cancellable.cancel ();
            queue.clear ();
            dialog.hide ();
            model.clear ();
            return result;
        }
    }
}
