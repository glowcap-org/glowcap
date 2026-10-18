//! Streaming equality check before a replacement can become authoritative.
const std = @import("std");
const core = @import("loam_core");
const c = @import("c.zig");
const kv = @import("kv.zig");

pub fn verify(source: *c.Env, source_dbi: c_uint, expected: core.Metadata, copy_path: [*:0]const u8) !void {
    var copy: ?*c.Env = null;
    try kv.check(c.mdb_env_create(&copy));
    defer c.mdb_env_close(copy.?);
    // The candidate is private under lifetime owner custody. A read-only,
    // lock-free validation creates no companion lock file or new incarnation.
    try kv.check(c.mdb_env_open(copy.?, copy_path, c.no_subdir | c.readonly | c.no_lock | c.notls, 0o600));
    var original: ?*c.Txn = null;
    try kv.check(c.mdb_txn_begin(source, null, c.readonly, &original));
    defer c.mdb_txn_abort(original.?);
    var candidate: ?*c.Txn = null;
    try kv.check(c.mdb_txn_begin(copy.?, null, c.readonly, &candidate));
    defer c.mdb_txn_abort(candidate.?);
    var copy_dbi: c_uint = 0;
    try kv.check(c.mdb_dbi_open(candidate.?, null, 0, &copy_dbi));
    const source_metadata = try metadata(original.?, source_dbi);
    if (source_metadata.store != expected.store or source_metadata.incarnation != expected.incarnation) return error.StoreMismatch;
    if (!std.meta.eql(source_metadata, try metadata(candidate.?, copy_dbi))) return error.CopyMismatch;
    try equalRows(original.?, source_dbi, candidate.?, copy_dbi);
}

fn metadata(txn: *c.Txn, dbi: c_uint) !core.Metadata {
    var key = kv.val(core.metadata_key);
    var value: c.Val = undefined;
    try kv.check(c.mdb_get(txn, dbi, &key, &value));
    return core.Metadata.decode(kv.valueBytes(value));
}

fn equalRows(source: *c.Txn, source_dbi: c_uint, copy: *c.Txn, copy_dbi: c_uint) !void {
    var original: ?*c.Cursor = null;
    try kv.check(c.mdb_cursor_open(source, source_dbi, &original));
    defer c.mdb_cursor_close(original.?);
    var candidate: ?*c.Cursor = null;
    try kv.check(c.mdb_cursor_open(copy, copy_dbi, &candidate));
    defer c.mdb_cursor_close(candidate.?);
    while (true) {
        var source_key: c.Val = undefined;
        var source_value: c.Val = undefined;
        var copy_key: c.Val = undefined;
        var copy_value: c.Val = undefined;
        const source_rc = c.mdb_cursor_get(original.?, &source_key, &source_value, c.next); // MDB_NEXT selects first on a new cursor
        const copy_rc = c.mdb_cursor_get(candidate.?, &copy_key, &copy_value, c.next);
        if (source_rc == c.not_found and copy_rc == c.not_found) return;
        if (source_rc == c.not_found or copy_rc == c.not_found) return error.CopyMismatch;
        try kv.check(source_rc);
        try kv.check(copy_rc);
        if (!std.mem.eql(u8, kv.valueBytes(source_key), kv.valueBytes(copy_key)) or
            !std.mem.eql(u8, kv.valueBytes(source_value), kv.valueBytes(copy_value))) return error.CopyMismatch;
    }
}
