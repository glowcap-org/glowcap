//! The owner lock the disk engines share. One Loam process holds a store
//! directory for its whole open lifetime, because LMDB's and SQLite's own
//! locks let several processes share a database and Loam's contract is one
//! owner. The lock file stays after close, since unlinking it would let a
//! new owner lock a different inode at the same path.
const std = @import("std");

/// A held store directory: its descriptor and the lock inside it.
pub const Held = struct {
    directory: c_int,
    lock: c_int,

    /// Release the lock and close both descriptors. A refused unlock is
    /// reported after the descriptors are closed, so nothing stays held, and
    /// a later release finds nothing to close. An engine whose close reported
    /// the refusal can retry close without touching a reused descriptor.
    pub fn release(self: *Held) !void {
        if (self.lock < 0) return;
        const rc = loam_owner_lock_release(self.lock);
        loam_owner_lock_close_fd(self.lock);
        loam_owner_lock_close_fd(self.directory);
        self.* = .{ .directory = -1, .lock = -1 };
        if (rc != 0) return error.StorageFailure;
    }
};

/// Resolve `path` into `canonical`, open the directory, and take its lock.
/// A directory another process holds is `error.CustodyUnavailable`.
pub fn acquire(path: [:0]const u8, canonical: *[std.fs.max_path_bytes:0]u8) !Held {
    switch (loam_owner_lock_canonical_path(path.ptr, canonical, canonical.len)) {
        0 => {},
        @backingInt(std.posix.E.NOENT) => return error.FileNotFound,
        @backingInt(std.posix.E.NAMETOOLONG) => return error.NameTooLong,
        else => return error.StorageFailure,
    }
    const directory = loam_owner_lock_directory(canonical);
    if (directory < 0) return error.StorageFailure;
    errdefer loam_owner_lock_close_fd(directory);
    const lock = loam_owner_lock_acquire(directory);
    if (lock < 0) return error.CustodyUnavailable;
    return .{ .directory = directory, .lock = lock };
}

extern "c" fn loam_owner_lock_canonical_path(path: [*:0]const u8, result: [*]u8, capacity: usize) c_int;
extern "c" fn loam_owner_lock_directory(path: [*:0]const u8) c_int;
extern "c" fn loam_owner_lock_acquire(directory: c_int) c_int;
extern "c" fn loam_owner_lock_release(fd: c_int) c_int;
extern "c" fn loam_owner_lock_close_fd(fd: c_int) void;
