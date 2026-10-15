/* The owner lock the disk engines share. One Loam process holds this
 * advisory lock for the entire open lifetime of a store directory; each
 * engine serializes its own write transactions. Keep the lock file after
 * close: unlinking it races with a new owner and permits locks on different
 * inodes at the same path. Uses BSD flock(), available on macOS and Linux. */
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/file.h>
#include <unistd.h>

int loam_owner_lock_canonical_path(const char *path, char *result, size_t capacity) {
    char resolved[PATH_MAX];
    if (!realpath(path, resolved)) return errno;
    size_t length = strlen(resolved);
    if (length >= capacity) return ENAMETOOLONG;
    memcpy(result, resolved, length + 1);
    return 0;
}

int loam_owner_lock_directory(const char *path) {
    return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
}

int loam_owner_lock_acquire(int directory) {
    int fd = openat(directory, "loam-owner.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int loam_owner_lock_release(int fd) {
    /* close alone leaves a flock held by a child between fork and exec. */
    while (flock(fd, LOCK_UN) < 0) {
        if (errno != EINTR) return errno;
    }
    return 0;
}

void loam_owner_lock_close_fd(int fd) {
    close(fd);
}
