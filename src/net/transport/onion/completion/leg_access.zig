//! What the onion leg adds to the shared leg lifecycle.
//!
//! A retained receive is returned as the row enters `closing`, a refused send
//! carries no borrowed failure, and every retry membership lives in the
//! submission-debt state. `Self.Leg` owns the lifecycle machinery this
//! access feeds, and the reference is lazy.

const adapter = @import("../../../completion/adapter.zig");
const contract = @import("../../../completion/contract.zig");
const carrier_failure = @import("../../../carrier_failure.zig");
const inner_leg = @import("../../../completion/inner_leg.zig");

pub fn Access(comptime Self: type, comptime Inner: type, comptime Types: type) type {
    return struct {
        pub fn closeUserData(id: Types.ConnId) u64 {
            return Types.Identity.userData(.close, id);
        }

        pub fn onClosing(self: *Self, _: *Inner, c: *Types.Conn, _: inner_leg.Closing) void {
            self.retries.clearDataRetries(&self.conns, c);
            if (!c.borrowed) self.releaseHeld(c);
        }

        pub fn prepareClose(_: *Self, _: *Inner, _: *Types.Conn) !void {}

        pub fn closeRefused(_: *Self, _: *Inner, _: *Types.Conn) void {}

        pub fn refuseExternalSend(self: *Self, c: *Types.Conn, cause: ?anyerror, _: carrier_failure.Phase) void {
            const ud = c.external_send_ud orelse return;
            self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1, .failure = cause });
            c.external_send_ud = null;
        }

        pub fn startClose(self: *Self, inner: *Inner, c: *Types.Conn) void {
            Self.Leg.beginInnerClose(self, inner, c);
        }

        pub fn owesClose(self: *Self, c: *Types.Conn) bool {
            return self.retries.owesSubmission(c, .close);
        }

        pub fn oweClose(self: *Self, c: *Types.Conn) void {
            self.retries.oweSubmission(&self.conns, c, .close);
        }

        pub fn clearOwedClose(self: *Self, c: *Types.Conn) void {
            self.retries.clearOwedRetries(&self.conns, c);
        }

        pub fn lendActive(c: *const Types.Conn) bool {
            return c.borrowed;
        }

        pub fn borrowFailure(_: *Self, _: *Types.Conn) contract.Borrowed {
            return .{};
        }

        pub fn prepareFinish(_: *Self, _: *Types.Conn, _: bool) bool {
            return false;
        }

        pub fn closeCause(_: *const Types.Conn) ?anyerror {
            return null;
        }

        pub fn hasBorrowedFailure(_: *const Self, _: *const Types.Conn) bool {
            return false;
        }

        pub fn retireRow(self: *Self, c: *Types.Conn) void {
            self.retries.clearOwedRetries(&self.conns, c);
        }

        pub fn deinitRow(_: *Self, inner: *Inner, c: *Types.Conn) void {
            c.deinit(inner);
        }
    };
}
