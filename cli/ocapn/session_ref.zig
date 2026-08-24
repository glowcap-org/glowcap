//! One CLI verb's borrowed-or-owned session view.

const pancake = @import("pancake");
const exit_codes = @import("../exit_codes.zig");

const driver = pancake.driver;
const FailureChain = pancake.foundation.FailureChain;

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

        const code = outcome catch |primary| {
            return finishOwned(ctx, session, .cancel, primary, null);
        };
        if (code != exit_codes.ok) {
            return finishOwned(ctx, session, .cancel, null, code);
        }
        return finishOwned(ctx, session, .{ .finish = .{ .ms = close_grace_ms } }, null, code);
    }
};

fn finishOwned(
    ctx: anytype,
    session: *driver.Session,
    pending: driver.PendingWork,
    primary: ?anyerror,
    code: ?u8,
) !u8 {
    var failure: ?FailureChain = if (primary) |cause| FailureChain.init(cause) else null;
    session.close(pending) catch |cleanup| {
        if (failure) |*chain| {
            chain.note(cleanup);
        } else {
            failure = .init(cleanup);
        }
        // A failed close has not crossed the Session release boundary. Move
        // the still-live one-shot handle into the context so process teardown
        // or a later command can retry the exact barrier.
        ctx.retainOneShotSession(session);
        if (ctx.takeCallerless()) |later| {
            if (failure) |*chain| chain.noteChain(later) else failure = later;
        }
        if (primary) |cause| return cause;
        if (code.? != exit_codes.ok) return code.?;
        ctx.logCloseFailure("session close", failure.?);
        return ctx.mapCloseErr(failure.?.cause);
    };
    session.deinit();
    if (ctx.takeCallerless()) |cleanup| {
        if (failure) |*chain| {
            chain.noteChain(cleanup);
        } else {
            failure = cleanup;
        }
    }
    if (primary) |cause| {
        if (failure.?.secondary_count > 0) {
            ctx.logErr(
                "session cleanup after {s}: {s} (and {d} later failure(s))",
                .{ @errorName(cause), failure.?.secondaryName() orelse "none", failure.?.secondary_count },
            );
        }
        return cause;
    }
    if (code.? != exit_codes.ok) {
        if (failure) |chain| ctx.logCloseFailure("session cleanup consequence", chain);
        return code.?;
    }
    if (failure) |chain| {
        ctx.logCloseFailure("session close", chain);
        return ctx.mapCloseErr(chain.cause);
    }
    return code.?;
}
