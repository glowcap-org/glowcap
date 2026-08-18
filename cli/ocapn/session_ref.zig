//! One CLI verb's borrowed-or-owned session view.

const driver = @import("pancake").driver;
const exit_codes = @import("../exit_codes.zig");

const close_grace_ms: u32 = 5_000;

pub const SessionRef = union(enum) {
    borrow: *driver.Session,
    owned: *driver.Session,

    pub fn ptr(self: SessionRef) *driver.Session {
        return switch (self) {
            .borrow => |session| session,
            .owned => |session| session,
        };
    }

    pub fn deinit(self: SessionRef) void {
        switch (self) {
            .borrow => {},
            .owned => |session| session.deinit(),
        }
    }

    /// Settle one command and the session lifetime it admitted. Borrowed
    /// sessions remain owned by the REPL/MCP context. An owned one-shot closes
    /// through the returned barrier before its wrapper is destroyed, so a
    /// successful command cannot turn into an abortive transport teardown.
    pub fn finish(self: SessionRef, ctx: anytype, outcome: anyerror!u8) !u8 {
        const session = switch (self) {
            .borrow => return outcome,
            .owned => |owned| owned,
        };
        defer session.deinit();

        const code = outcome catch |primary| {
            session.close(.cancel) catch |cleanup| {
                ctx.logErr(
                    "session cleanup after {s}: {s}",
                    .{ @errorName(primary), @errorName(cleanup) },
                );
            };
            return primary;
        };
        if (code != exit_codes.ok) {
            session.close(.cancel) catch |cleanup| {
                ctx.logErr("session cleanup consequence: {s}", .{@errorName(cleanup)});
            };
            return code;
        }

        session.close(.{ .finish = .{ .ms = close_grace_ms } }) catch |close_failure| {
            ctx.logErr("session close: {s}", .{@errorName(close_failure)});
            return switch (close_failure) {
                error.CloseTimedOut => exit_codes.timeout,
                error.OutOfMemory => exit_codes.internal,
                else => exit_codes.dial,
            };
        };
        return code;
    }
};
