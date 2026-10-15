/* Linux-only fault injection for loam-io-fault-test. The probe overrides
 * libc's write, sync and read calls, and the engines compile unchanged. An
 * armed call fails before or after the real call, or moves only part of its
 * bytes. Persistent modes also fail every later write, sync and read, so
 * rollback cannot lean on a healthy disk. Counters prove the injection was
 * reached. A read through a memory map makes no call, so they never see one. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stddef.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>

static _Thread_local struct {
    int active, kind, action, error, fired;
    unsigned target, writes, syncs, reads;
} fault;

void loam_fault_arm(int kind, unsigned target, int action, int error) {
    fault.active = 1;
    fault.kind = kind;
    fault.target = target;
    fault.action = action;
    fault.error = error;
    fault.fired = 0;
    fault.writes = fault.syncs = fault.reads = 0;
}
void loam_fault_stop(void) { fault.active = 0; }
unsigned loam_fault_writes(void) { return fault.writes; }
unsigned loam_fault_syncs(void) { return fault.syncs; }
unsigned loam_fault_reads(void) { return fault.reads; }
int loam_fault_fired(void) { return fault.fired; }

static int intercept(int kind) {
    if (!fault.active) return 0;
    unsigned count = kind == 1 ? ++fault.writes : kind == 2 ? ++fault.syncs : ++fault.reads;
    if (fault.fired) return fault.action >= 4 ? fault.action - 3 : 0;
    if (kind != fault.kind || count != fault.target) return 0;
    fault.fired = 1;
    return fault.action >= 4 ? fault.action - 3 : fault.action;
}

#define POSITIONED_WRITE(name, offset_type) \
ssize_t name(int fd, const void *bytes, size_t length, offset_type offset) { \
    ssize_t (*real)(int, const void *, size_t, offset_type) = dlsym(RTLD_NEXT, #name); \
    int action = intercept(1); \
    if (action == 1) { errno = fault.error; return -1; } \
    ssize_t result = real(fd, bytes, action == 3 ? length / 2 : length, offset); \
    if (action == 2 && result >= 0) { errno = fault.error; return -1; } \
    return result; \
}
POSITIONED_WRITE(pwrite, off_t)
POSITIONED_WRITE(pwrite64, off64_t)

#define VECTOR_WRITE(name, offset_type) \
ssize_t name(int fd, const struct iovec *vectors, int count, offset_type offset) { \
    ssize_t (*real)(int, const struct iovec *, int, offset_type) = dlsym(RTLD_NEXT, #name); \
    int action = intercept(1); \
    if (action == 1) { errno = fault.error; return -1; } \
    struct iovec partial; \
    if (action == 3 && count > 0) { \
        partial = vectors[0]; \
        partial.iov_len /= 2; \
        vectors = &partial; \
        count = 1; \
    } \
    ssize_t result = real(fd, vectors, count, offset); \
    if (action == 2 && result >= 0) { errno = fault.error; return -1; } \
    return result; \
}
VECTOR_WRITE(pwritev, off_t)
VECTOR_WRITE(pwritev64, off64_t)

ssize_t writev(int fd, const struct iovec *vectors, int count) {
    ssize_t (*real)(int, const struct iovec *, int) = dlsym(RTLD_NEXT, "writev");
    int action = intercept(1);
    if (action == 1) { errno = fault.error; return -1; }
    struct iovec partial;
    if (action == 3 && count > 0) {
        partial = vectors[0];
        partial.iov_len /= 2;
        vectors = &partial;
        count = 1;
    }
    ssize_t result = real(fd, vectors, count);
    if (action == 2 && result >= 0) { errno = fault.error; return -1; }
    return result;
}

#define SYNC(name) \
int name(int fd) { \
    int (*real)(int) = dlsym(RTLD_NEXT, #name); \
    int action = intercept(2); \
    if (action == 1) { errno = fault.error; return -1; } \
    int result = real(fd); \
    if (action == 2 && result == 0) { errno = fault.error; return -1; } \
    return result; \
}
SYNC(fsync)
SYNC(fdatasync)

#define POSITIONED_READ(name, offset_type) \
ssize_t name(int fd, void *bytes, size_t length, offset_type offset) { \
    ssize_t (*real)(int, void *, size_t, offset_type) = dlsym(RTLD_NEXT, #name); \
    int action = intercept(3); \
    if (action == 1) { errno = fault.error; return -1; } \
    ssize_t result = real(fd, bytes, action == 3 ? length / 2 : length, offset); \
    if (action == 2 && result >= 0) { errno = fault.error; return -1; } \
    return result; \
}
POSITIONED_READ(pread, off_t)
POSITIONED_READ(pread64, off64_t)

ssize_t read(int fd, void *bytes, size_t length) {
    ssize_t (*real)(int, void *, size_t) = dlsym(RTLD_NEXT, "read");
    int action = intercept(3);
    if (action == 1) { errno = fault.error; return -1; }
    ssize_t result = real(fd, bytes, action == 3 ? length / 2 : length);
    if (action == 2 && result >= 0) { errno = fault.error; return -1; }
    return result;
}
