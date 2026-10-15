/* Compiled into the pinned LMDB source just after its MDB_env definition.
 * tools/gen/checked_lmdb.zig applies the patch.
 *
 * Stock LMDB reads its file through a memory map, so a disk error during a
 * read raises SIGBUS. Here each page is read with pread into anonymous memory,
 * and LMDB sees it only after the whole read succeeds. A failed or short read
 * returns an error before LMDB parses a byte, with no signal handler.
 *
 * LMDB's own read-page cache holds those pages and decides what to evict. A
 * miss reads one page, or one whole large value. A returned value borrows the
 * cache until the next operation on its transaction.
 *
 * Data pages use anonymous memory, so writes do not update them on their own. Each
 * successful write copies its bytes into any cached page it covers before
 * LMDB publishes the transaction. LMDB only writes pages no snapshot still
 * reads, so no reader sees a page change under it. The two metadata pages are
 * the exception, and a read-write lock keeps a transaction from copying them
 * mid-update. The reader table, LMDB's shared lock file, is still mapped. */

static void *loam_lmdb_load(MDB_env *env, size_t length, off_t offset) {
    void *pages = mmap(NULL, length, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (pages == MAP_FAILED) return MAP_FAILED;
    size_t done = 0;
    while (done < length) {
        ssize_t count = pread(env->me_fd, (char *)pages + done,
                              length - done, offset + done);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            int failure = count == 0 ? EIO : errno;
            munmap(pages, length);
            errno = failure;
            return MAP_FAILED;
        }
        done += count;
    }
    return pages;
}

static void loam_lmdb_copy_range(void *pages, size_t length, off_t base,
                                 off_t offset, const void *bytes, size_t count) {
    off_t first = offset > base ? offset : base;
    off_t last = offset + count < base + length ? offset + count : base + length;
    if (first < last)
        memcpy((char *)pages + (first - base),
               (const char *)bytes + (first - offset), last - first);
}

static void loam_lmdb_written(MDB_env *env, off_t offset,
                              const void *bytes, size_t count) {
    if (!env->me_map || !count) return;
    if (offset < NUM_METAS * env->me_psize) {
        pthread_rwlock_wrlock(&env->loam_meta_lock);
        loam_lmdb_copy_range(env->me_map, NUM_METAS * env->me_psize, 0,
                             offset, bytes, count);
        pthread_rwlock_unlock(&env->loam_meta_lock);
    }
    if (!env->me_rpages) return;
    pthread_mutex_lock(&env->me_rpmutex);
    MDB_ID3L pages = env->me_rpages;
    for (unsigned i = 1; i <= pages[0].mid; i++) {
        off_t base = pages[i].mid * env->me_psize;
        if (base >= offset + count) break;
        loam_lmdb_copy_range(pages[i].mptr, pages[i].mcnt * env->me_psize,
                             base, offset, bytes, count);
    }
    pthread_mutex_unlock(&env->me_rpmutex);
}

static ssize_t loam_lmdb_pwrite(MDB_env *env, int fd, const void *bytes,
                                size_t length, off_t offset) {
    ssize_t count = pwrite(fd, bytes, length, offset);
    if (count > 0) loam_lmdb_written(env, offset, bytes, count);
    return count;
}

static int loam_lmdb_begin(MDB_env *, MDB_txn *, unsigned int, MDB_txn **);
static int loam_lmdb_stat(MDB_env *, MDB_stat *);
static int loam_lmdb_info(MDB_env *, MDB_envinfo *);

/* The engine admits one writer before it calls begin, so a writer never waits
 * here behind a commit while holding the metadata read lock. */
int mdb_txn_begin(MDB_env *env, MDB_txn *parent, unsigned int flags, MDB_txn **out) {
    if (!env) return EINVAL;
    int rc = pthread_rwlock_rdlock(&env->loam_meta_lock);
    if (rc) return rc;
    rc = loam_lmdb_begin(env, parent, flags, out);
    pthread_rwlock_unlock(&env->loam_meta_lock);
    return rc;
}

int mdb_env_stat(MDB_env *env, MDB_stat *out) {
    if (!env) return EINVAL;
    int rc = pthread_rwlock_rdlock(&env->loam_meta_lock);
    if (rc) return rc;
    rc = loam_lmdb_stat(env, out);
    pthread_rwlock_unlock(&env->loam_meta_lock);
    return rc;
}

int mdb_env_info(MDB_env *env, MDB_envinfo *out) {
    if (!env) return EINVAL;
    int rc = pthread_rwlock_rdlock(&env->loam_meta_lock);
    if (rc) return rc;
    rc = loam_lmdb_info(env, out);
    pthread_rwlock_unlock(&env->loam_meta_lock);
    return rc;
}

static ssize_t loam_lmdb_writev(MDB_env *env, int fd, const struct iovec *iov,
                                int length, off_t offset) {
#ifdef MDB_USE_PWRITEV
    ssize_t count = pwritev(fd, iov, length, offset);
#else
    /* LMDB has already sought to offset on its private writer descriptor. */
    ssize_t count = writev(fd, iov, length);
#endif
    ssize_t remaining = count;
    for (int i = 0; i < length && remaining > 0; i++) {
        size_t accepted = (size_t)remaining < iov[i].iov_len ? (size_t)remaining : iov[i].iov_len;
        loam_lmdb_written(env, offset, iov[i].iov_base, accepted);
        remaining -= accepted;
        offset += accepted;
    }
    return count;
}
