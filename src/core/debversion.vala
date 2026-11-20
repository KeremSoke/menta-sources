namespace Menta.DebVersion {
    private int order (char c) {
        if (c.isdigit ()) {
            return 0;
        }
        if (c.isalpha ()) {
            return (int) c;
        }
        if (c == '~') {
            return -1;
        }
        if (c != '\0') {
            return (int) c + 256;
        }
        return 0;
    }

    private char at (string text, int index) {
        return index < text.length ? text[index] : '\0';
    }

    private int compare_part (string a, string b) {
        int i = 0;
        int j = 0;
        while (i < a.length || j < b.length) {
            int first_diff = 0;
            while ((i < a.length && !at (a, i).isdigit ()) || (j < b.length && !at (b, j).isdigit ())) {
                int ac = order (at (a, i));
                int bc = order (at (b, j));
                if (ac != bc) {
                    return ac - bc;
                }
                i++;
                j++;
            }
            while (at (a, i) == '0') {
                i++;
            }
            while (at (b, j) == '0') {
                j++;
            }
            while (at (a, i).isdigit () && at (b, j).isdigit ()) {
                if (first_diff == 0) {
                    first_diff = (int) at (a, i) - (int) at (b, j);
                }
                i++;
                j++;
            }
            if (at (a, i).isdigit ()) {
                return 1;
            }
            if (at (b, j).isdigit ()) {
                return -1;
            }
            if (first_diff != 0) {
                return first_diff;
            }
        }
        return 0;
    }

    private void split (string version, out int64 epoch, out string upstream, out string revision) {
        var rest = version.strip ();
        epoch = 0;
        var colon = rest.index_of (":");
        if (colon > 0) {
            epoch = int64.parse (rest.substring (0, colon));
            rest = rest.substring (colon + 1);
        }
        var dash = rest.last_index_of ("-");
        if (dash >= 0) {
            upstream = rest.substring (0, dash);
            revision = rest.substring (dash + 1);
        } else {
            upstream = rest;
            revision = "";
        }
    }

    public int compare (string a, string b) {
        int64 epoch_a, epoch_b;
        string upstream_a, upstream_b, revision_a, revision_b;
        split (a, out epoch_a, out upstream_a, out revision_a);
        split (b, out epoch_b, out upstream_b, out revision_b);
        if (epoch_a != epoch_b) {
            return epoch_a > epoch_b ? 1 : -1;
        }
        var result = compare_part (upstream_a, upstream_b);
        if (result != 0) {
            return result;
        }
        return compare_part (revision_a, revision_b);
    }
}
