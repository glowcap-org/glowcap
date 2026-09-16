/* Cooperating Loam owners hold this advisory lock for the entire open lifetime;
 * LMDB separately serializes write transactions. Keep the lock file after close:
 * unlinking it races with a new owner and permits locks on different inodes at
 * the same path. Uses BSD flock(), available on macOS and Linux. */
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <sys/file.h>
#include <unistd.h>

int loam_lmdb_lock(const char *directory) {
    char path[PATH_MAX];
    int length = snprintf(path, sizeof(path), "%s/loam-owner.lock", directory);
    if (length < 0 || (size_t)length >= sizeof(path)) return -1;
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

void loam_lmdb_unlock(int fd) {
    close(fd);
}
