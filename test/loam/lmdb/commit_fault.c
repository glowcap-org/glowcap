/* Model a failure reported after metadata became visible, without relying on
 * LMDB to fence itself. Only the test module renames the real entry point. */
#include <lmdb.h>
#include <errno.h>

static _Thread_local int failure;
static _Thread_local int refuse_before;
static _Thread_local int sync_failure;
int loam_test_real_commit(MDB_txn *txn);

void loam_test_commit_failure(int error) {
    failure = error;
    refuse_before = 0;
}

void loam_test_commit_unknown(int before) {
    failure = EIO; /* Deliberately uncertain at either stage. */
    refuse_before = before;
}

int mdb_txn_commit(MDB_txn *txn) {
    int injected = failure;
    failure = 0;
    if (injected && refuse_before) {
        refuse_before = 0;
        mdb_txn_abort(txn);
        return injected;
    }
    int result = loam_test_real_commit(txn);
    return result ? result : injected;
}

void loam_test_recovery_failure(void) {
    sync_failure = 1;
}

int loam_test_real_sync(MDB_env *env, int force);
int mdb_env_sync(MDB_env *env, int force) {
    if (sync_failure) {
        sync_failure = 0;
        return EIO;
    }
    return loam_test_real_sync(env, force);
}
