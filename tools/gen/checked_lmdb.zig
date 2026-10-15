//! Writes the LMDB source this build compiles: the pinned mdb.c with page
//! reads moved from the memory map to pread (src/loam/engines/lmdb/page_io.h).
//! Arguments are mdb.c, page_io.h, and the output path. Each patch must match
//! an exact number of times, so a changed upstream source fails the build
//! instead of compiling unreviewed. The downloaded dependency is never edited.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const input = args.next() orelse return error.InvalidArguments;
    const helpers = args.next() orelse return error.InvalidArguments;
    const output = args.next() orelse return error.InvalidArguments;
    if (args.next() != null) return error.InvalidArguments;
    const cwd = std.Io.Dir.cwd();
    var source = try cwd.readFileAlloc(init.io, input, init.gpa, .limited(1 << 20));
    defer init.gpa.free(source);
    const Patch = struct { before: []const u8, after: []const u8, count: usize = 1 };
    const patches = [_]Patch{
        .{ .before = "\tvoid\t\t*me_userctx;", .after = "\tpthread_rwlock_t loam_meta_lock;\n\tvoid\t\t*me_userctx;" },
        .{ .before = "\te->me_maxreaders = DEFAULT_READERS;", .after = "\tint loam_rc = pthread_rwlock_init(&e->loam_meta_lock, NULL);\n\tif (loam_rc) { free(e); return loam_rc; }\n\te->me_maxreaders = DEFAULT_READERS;" },
        .{ .before = "\tfree(env);", .after = "\tpthread_rwlock_destroy(&env->loam_meta_lock);\n\tfree(env);" },
        .{ .before = "\nmdb_txn_begin(MDB_env", .after = "\nloam_lmdb_begin(MDB_env" },
        .{ .before = "\nmdb_env_stat(MDB_env", .after = "\nloam_lmdb_stat(MDB_env" },
        .{ .before = "\nmdb_env_info(MDB_env", .after = "\nloam_lmdb_info(MDB_env" },
        // Every byte loaded belongs to a requested page. No zero-filled tail.
        .{ .before = "#define MDB_RPAGE_CHUNK\t16", .after = "#define MDB_RPAGE_CHUNK\t1" },
        .{ .before = "env->me_map = mmap(addr, NUM_METAS * env->me_psize, prot, mmap_flags,\n\t\t\tenv->me_fd, 0);", .after = "env->me_map = loam_lmdb_load(env, NUM_METAS * env->me_psize, 0);" },
        .{ .before = "addr = mmap(NULL, len, PROT_READ, MAP_SHARED, env->me_fd, off);", .after = "addr = loam_lmdb_load(env, len, off);" },
        // Mirror accepted bytes before LMDB publishes its new transaction ID.
        .{ .before = "pwrite(", .after = "loam_lmdb_pwrite(env, ", .count = 5 },
        .{ .before = "pwritev(fd, iov, n, wpos)", .after = "loam_lmdb_writev(env, fd, iov, n, wpos)" },
        .{ .before = "writev(fd, iov, n)", .after = "loam_lmdb_writev(env, fd, iov, n, wpos)" },
    };
    for (patches) |patch| try replace(init.gpa, &source, patch.before, patch.after, patch.count);
    const body = try cwd.readFileAlloc(init.io, helpers, init.gpa, .limited(64 << 10));
    defer init.gpa.free(body);
    const marker = "\n\t/** Nested transaction */";
    const inserted = try std.fmt.allocPrint(init.gpa, "\n{s}{s}", .{ body, marker });
    defer init.gpa.free(inserted);
    try replace(init.gpa, &source, marker, inserted, 1);
    try cwd.writeFile(init.io, .{ .sub_path = output, .data = source });
}

fn replace(gpa: std.mem.Allocator, source: *[]u8, before: []const u8, after: []const u8, expected: usize) !void {
    const actual = std.mem.count(u8, source.*, before);
    if (actual != expected) {
        std.debug.print("LMDB page-I/O patch expected {d} matches, found {d}: {s}\n", .{ expected, actual, before });
        return error.UnexpectedLmdbSource;
    }
    const next = try std.mem.replaceOwned(u8, gpa, source.*, before, after);
    gpa.free(source.*);
    source.* = next;
}
