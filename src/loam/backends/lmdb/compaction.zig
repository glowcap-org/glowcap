//! Streaming equality check before a replacement can become authoritative.
const std = @import("std");
const core = @import("loam_core");
const c = @import("c.zig");

pub fn verify(source: *c.Env, source_dbi: c_uint, expected: core.Metadata, copy_path: [*:0]const u8) !void {
    var copy: ?*c.Env = null;
    try check(c.mdb_env_create(&copy));
    defer c.mdb_env_close(copy.?);
    // The candidate is private under lifetime owner custody. A read-only,
    // lock-free validation creates no companion lock file or new incarnation.
    try check(c.mdb_env_open(copy.?, copy_path, c.no_subdir | c.readonly | c.no_lock | c.notls, 0o600));
    var original: ?*c.Txn = null;
    try check(c.mdb_txn_begin(source, null, c.readonly, &original));
    defer c.mdb_txn_abort(original.?);
    var candidate: ?*c.Txn = null;
    try check(c.mdb_txn_begin(copy.?, null, c.readonly, &candidate));
    defer c.mdb_txn_abort(candidate.?);
    var copy_dbi: c_uint = 0;
    try check(c.mdb_dbi_open(candidate.?, null, 0, &copy_dbi));
    const source_metadata = try metadata(original.?, source_dbi);
    if (source_metadata.store != expected.store or source_metadata.incarnation != expected.incarnation) return error.StoreMismatch;
    if (!std.meta.eql(source_metadata, try metadata(candidate.?, copy_dbi))) return error.CopyMismatch;
    try equalRows(original.?, source_dbi, candidate.?, copy_dbi);
}

fn metadata(txn: *c.Txn, dbi: c_uint) !core.Metadata {
    var key: c.Val = .{ .size = core.metadata_key.len, .data = @ptrCast(@constCast(core.metadata_key.ptr)) };
    var value: c.Val = undefined;
    try check(c.mdb_get(txn, dbi, &key, &value));
    return core.Metadata.decode(bytes(value));
}

fn equalRows(source: *c.Txn, source_dbi: c_uint, copy: *c.Txn, copy_dbi: c_uint) !void {
    var original: ?*c.Cursor = null;
    try check(c.mdb_cursor_open(source, source_dbi, &original));
    defer c.mdb_cursor_close(original.?);
    var candidate: ?*c.Cursor = null;
    try check(c.mdb_cursor_open(copy, copy_dbi, &candidate));
    defer c.mdb_cursor_close(candidate.?);
    while (true) {
        var source_key: c.Val = undefined;
        var source_value: c.Val = undefined;
        var copy_key: c.Val = undefined;
        var copy_value: c.Val = undefined;
        const source_rc = c.mdb_cursor_get(original.?, &source_key, &source_value, 8); // MDB_NEXT, first on new cursor
        const copy_rc = c.mdb_cursor_get(candidate.?, &copy_key, &copy_value, 8);
        if (source_rc == c.not_found and copy_rc == c.not_found) return;
        if (source_rc == c.not_found or copy_rc == c.not_found) return error.CopyMismatch;
        try check(source_rc);
        try check(copy_rc);
        if (!std.mem.eql(u8, bytes(source_key), bytes(copy_key)) or
            !std.mem.eql(u8, bytes(source_value), bytes(copy_value))) return error.CopyMismatch;
    }
}

fn bytes(value: c.Val) []const u8 {
    const pointer: [*]const u8 = @ptrCast(value.data);
    return pointer[0..value.size];
}

fn check(rc: c_int) !void {
    if (rc != 0) return error.CopyInvalid;
}
