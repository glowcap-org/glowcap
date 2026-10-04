/* Cooperating Loam owners hold this advisory lock for the entire open lifetime;
 * LMDB separately serializes write transactions. Keep the lock file after close:
 * unlinking it races with a new owner and permits locks on different inodes at
 * the same path. Uses BSD flock(), available on macOS and Linux. */
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/file.h>
#include <unistd.h>

int loam_lmdb_canonical_path(const char *path, char *result, size_t capacity) {
    char resolved[PATH_MAX];
    if (!realpath(path, resolved)) return errno;
    size_t length = strlen(resolved);
    if (length >= capacity) return ENAMETOOLONG;
    memcpy(result, resolved, length + 1);
    return 0;
}

int loam_lmdb_directory(const char *path) {
    return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
}

int loam_lmdb_lock(int directory) {
    int fd = openat(directory, "loam-owner.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

void loam_lmdb_close_fd(int fd) {
    close(fd);
}
