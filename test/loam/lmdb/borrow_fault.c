/* The next LMDB call may invalidate the preceding returned row before it
 * consumes its input. Reject an input still borrowing that row, without
 * relying on a particular cache eviction order or actually unmapping it.
 * Only the test module renames the real entry points. */
#include <errno.h>
#include <stdint.h>
#include <lmdb.h>

static _Thread_local struct {
    uintptr_t first;
    size_t length;
    unsigned checks;
} borrow;

int loam_test_real_get(MDB_txn *, MDB_dbi, MDB_val *, MDB_val *);
int loam_test_real_cursor_get(MDB_cursor *, MDB_val *, MDB_val *, MDB_cursor_op);

void loam_test_borrow_arm(const void *bytes, size_t length) {
    borrow.first = (uintptr_t)bytes;
    borrow.length = length;
    borrow.checks = 0;
}

void loam_test_borrow_stop(void) { borrow.length = 0; }
unsigned loam_test_borrow_checks(void) { return borrow.checks; }

static int borrowed_input(const MDB_val *key) {
    size_t length = borrow.length;
    if (!length) return 0;
    borrow.length = 0;
    borrow.checks++;
    if (!key->mv_size) return 0;
    uintptr_t first = (uintptr_t)key->mv_data;
    return first >= borrow.first ? first - borrow.first < length
                                 : borrow.first - first < key->mv_size;
}

int mdb_get(MDB_txn *txn, MDB_dbi dbi, MDB_val *key, MDB_val *value) {
    if (borrowed_input(key)) return EINVAL;
    return loam_test_real_get(txn, dbi, key, value);
}

int mdb_cursor_get(MDB_cursor *cursor, MDB_val *key, MDB_val *value,
                   MDB_cursor_op operation) {
    /* Other operations treat key as output, possibly uninitialized. */
    if (operation == MDB_SET_RANGE && borrowed_input(key)) return EINVAL;
    return loam_test_real_cursor_get(cursor, key, value, operation);
}
