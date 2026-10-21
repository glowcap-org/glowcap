//! Issuer-bound handoff-count preparations.
//!
//! A count becomes wire-visible only when its captured issuer applies it. The
//! binding makes a stale, duplicate, or fabricated preparation fail at `check`
//! without moving replay authority. `apply` runs once the withdrawal is queued,
//! after the one place that may refuse, so the wire effect and the count never
//! disagree.

pub const CheckError = error{StaleHandoffCountPreparation};

pub const Prepared = struct {
    count: u64,
    issuer: *anyopaque,
    check_fn: *const fn (*anyopaque, u64) CheckError!void,
    apply_fn: *const fn (*anyopaque, u64) void,

    pub fn bind(
        issuer: anytype,
        count: u64,
        comptime check_prepared: fn (@TypeOf(issuer), u64) CheckError!void,
        comptime apply_prepared: fn (@TypeOf(issuer), u64) void,
    ) Prepared {
        const Issuer = @TypeOf(issuer);
        const Adapter = struct {
            fn check(erased: *anyopaque, prepared: u64) CheckError!void {
                return @call(.always_inline, check_prepared, .{
                    @as(Issuer, @ptrCast(@alignCast(erased))),
                    prepared,
                });
            }
            fn apply(erased: *anyopaque, prepared: u64) void {
                return @call(.always_inline, apply_prepared, .{
                    @as(Issuer, @ptrCast(@alignCast(erased))),
                    prepared,
                });
            }
        };
        return .{
            .count = count,
            .issuer = issuer,
            .check_fn = Adapter.check,
            .apply_fn = Adapter.apply,
        };
    }

    /// Refuse a preparation the issuer no longer stands at. Runs before the status-allow: lifecycle transition
    /// withdrawal is queued.
    pub fn check(self: Prepared) CheckError!void {
        try self.check_fn(self.issuer, self.count);
    }

    /// Consume the count. `check` passed and nothing prepared another count
    /// since, so the issuer still stands at `count`.
    pub fn apply(self: Prepared) void {
        self.apply_fn(self.issuer, self.count);
    }
};
