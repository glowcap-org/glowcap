/* The owner lock remains on its original inode throughout replacement. These
 * operations touch only the reserved temporary data file and data.mdb in the
 * same directory. A leftover copy is always discarded, never selected. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

struct replacement_files { int directory; int copy; };
static const char temporary[] = "loam-compact.mdb";

int loam_lmdb_replacement_begin(int source_directory, const char *source_path,
    char *copy_path, size_t capacity, struct replacement_files *files) {
    int length = snprintf(copy_path, capacity, "%s/%s", source_path, temporary);
    if (length < 0 || (size_t)length >= capacity) return ENAMETOOLONG;
    int directory = fcntl(source_directory, F_DUPFD_CLOEXEC, 0);
    if (directory < 0) return errno;
    if (unlinkat(directory, temporary, 0) < 0 && errno != ENOENT) {
        int error = errno;
        close(directory);
        return error;
    }
    int copy = openat(directory, temporary,
        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (copy < 0) {
        int error = errno;
        close(directory);
        return error;
    }
    files->directory = directory;
    files->copy = copy;
    return 0;
}

int loam_lmdb_replacement_sync_copy(const struct replacement_files *files) {
    return fsync(files->copy) == 0 ? 0 : errno;
}

int loam_lmdb_replacement_install(const struct replacement_files *files) {
    return renameat(files->directory, temporary, files->directory, "data.mdb") == 0 ? 0 : errno;
}

int loam_lmdb_replacement_sync_directory(const struct replacement_files *files) {
    return fsync(files->directory) == 0 ? 0 : errno;
}

void loam_lmdb_replacement_end(const struct replacement_files *files) {
    close(files->copy);
    /* After installation this name is absent. Cleanup failure leaves a copy
     * the next operation discards while holding the same owner lock. */
    unlinkat(files->directory, temporary, 0);
    close(files->directory);
}
