namespace Menta {
    public errordomain StorageError {
        FAILED,
        DENIED
    }

    public interface Storage : Object {
        public abstract void write_file (string path, uint8[] data, int mode) throws Error;
        public abstract void remove_file (string path) throws Error;
        public abstract string backup_file (string path, string backup_dir) throws Error;
    }

    public class DirectStorage : Object, Storage {
        public void write_file (string path, uint8[] data, int mode) throws Error {
            write_atomically (path, data, mode);
        }

        public void remove_file (string path) throws Error {
            if (FileUtils.test (path, FileTest.EXISTS) || FileUtils.test (path, FileTest.IS_SYMLINK)) {
                if (FileUtils.unlink (path) != 0) {
                    throw new StorageError.FAILED ("%s: %s", path, strerror (errno));
                }
            }
        }

        public string backup_file (string path, string backup_dir) throws Error {
            return copy_to_backup (path, backup_dir);
        }

        public static string resolve_target (string path) throws Error {
            var current = path;
            for (int depth = 0; depth < 16; depth++) {
                if (!FileUtils.test (current, FileTest.IS_SYMLINK)) {
                    return current;
                }
                var target = FileUtils.read_link (current);
                current = Path.is_absolute (target) ? target : Path.build_filename (Path.get_dirname (current), target);
            }
            throw new StorageError.FAILED ("%s: too many levels of symbolic links", path);
        }

        public static void write_atomically (string link_path, uint8[] data, int mode) throws Error {
            var path = resolve_target (link_path);
            var directory = Path.get_dirname (path);
            if (DirUtils.create_with_parents (directory, 0755) != 0) {
                throw new StorageError.FAILED ("%s: %s", directory, strerror (errno));
            }
            var temporary = Path.build_filename (directory, ".%s.%s.tmp".printf (Path.get_basename (path), Uuid.string_random ().substring (0, 8)));
            try {
                FileUtils.set_data (temporary, data);
                if (FileUtils.chmod (temporary, mode) != 0) {
                    throw new StorageError.FAILED ("%s: %s", temporary, strerror (errno));
                }
                if (FileUtils.rename (temporary, path) != 0) {
                    throw new StorageError.FAILED ("%s: %s", path, strerror (errno));
                }
            } catch (Error e) {
                FileUtils.unlink (temporary);
                throw e;
            }
        }

        public static string copy_to_backup (string path, string backup_dir) throws Error {
            if (DirUtils.create_with_parents (backup_dir, 0755) != 0) {
                throw new StorageError.FAILED ("%s: %s", backup_dir, strerror (errno));
            }
            var stamp = new DateTime.now_local ().format ("%Y%m%d-%H%M%S");
            var destination = Path.build_filename (backup_dir, "%s.%s".printf (Path.get_basename (path), stamp));
            var source = File.new_for_path (path);
            source.copy (File.new_for_path (destination), FileCopyFlags.OVERWRITE | FileCopyFlags.ALL_METADATA | FileCopyFlags.NOFOLLOW_SYMLINKS);
            return destination;
        }
    }

    namespace Files {
        private Storage? current_storage = null;

        public Storage storage () {
            if (current_storage == null) {
                current_storage = new DirectStorage ();
            }
            return current_storage;
        }

        public void set_storage (Storage storage) {
            current_storage = storage;
        }

        public string read_text (string path) throws Error {
            string content;
            size_t length;
            FileUtils.get_contents (path, out content, out length);
            if (content.length != length) {
                throw new StorageError.FAILED ("%s contains NUL bytes", path);
            }
            return content.make_valid ();
        }
    }
}
