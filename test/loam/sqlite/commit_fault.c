/* Only the test module renames sqlite3_step. Model errors on both sides of
 * COMMIT without requiring a particular OS fault to hit its sync point. */
#include <sqlite3.h>
#include <string.h>

static _Thread_local int failure;
static _Thread_local int sync_failure;
int loam_test_real_step(sqlite3_stmt *statement);

void loam_test_commit_unknown(int before) {
    failure = before ? 1 : 2;
}

void loam_test_recovery_failure(void) {
    sync_failure = 1;
}

int sqlite3_step(sqlite3_stmt *statement) {
    const char *sql = sqlite3_sql(statement);
    if (sync_failure && sql && !strcmp(sql, "PRAGMA wal_checkpoint(FULL)")) {
        sync_failure = 0;
        return SQLITE_IOERR;
    }
    if (!failure || !sql || strcmp(sql, "COMMIT"))
        return loam_test_real_step(statement);
    int injected = failure;
    failure = 0;
    if (injected == 1) {
        int rc = sqlite3_exec(sqlite3_db_handle(statement), "ROLLBACK", NULL, NULL, NULL);
        return rc == SQLITE_OK ? SQLITE_IOERR : rc;
    }
    int rc = loam_test_real_step(statement);
    return rc == SQLITE_DONE ? SQLITE_IOERR : rc;
}
