//! Issuer-bound handoff-count preparations.
//!
//! A count becomes wire-visible only when its captured issuer commits it. The
//! binding makes stale, duplicate, and fabricated preparations fail without
//! moving replay authority.

pub const CommitError = error{StaleHandoffCountPreparation};

pub const Prepared = struct {
    count: u64,
    issuer: *anyopaque,
    commit_fn: *const fn (*anyopaque, u64) CommitError!void,

    pub fn bind(
        issuer: anytype,
        count: u64,
        comptime commit_prepared: fn (@TypeOf(issuer), u64) CommitError!void,
    ) Prepared {
        const Issuer = @TypeOf(issuer);
        const Adapter = struct {
            fn commitPrepared(erased: *anyopaque, prepared: u64) CommitError!void {
                return @call(.always_inline, commit_prepared, .{
                    @as(Issuer, @ptrCast(@alignCast(erased))),
                    prepared,
                });
            }
        };
        return .{
            .count = count,
            .issuer = issuer,
            .commit_fn = Adapter.commitPrepared,
        };
    }

    pub fn commit(self: Prepared) CommitError!void {
        try self.commit_fn(self.issuer, self.count);
    }
};
