//! Canonical scenario actors for the driver and transport tests.
//! Consumers: `test/driver/blocking_session_test.zig`,
//! `test/driver/session_target_test.zig`, `test/driver/inproc_netlayer_test.zig`,
//! `test/driver/keyed_tcp_restart_test.zig`, `test/driver/pluggability_test.zig`.

const std = @import("std");
const pancake = @import("pancake");

const actors = pancake.actors;
const model = pancake.ocapn.model;

/// A published actor that answers exactly one verb with a fixed string reply
/// and refuses everything else with `error.NoSuchMethod`. Each test picks a
/// distinct reply text, so a cross-wired session fails its reply assertion
/// instead of passing on another scenario's greeting.
pub fn StaticReplyActor(comptime verb: []const u8, comptime reply: []const u8) type {
    return struct {
        pub fn handle(self: *@This(), turn: *actors.Turn, msg: actors.Message) !model.Argument {
            _ = self;
            _ = turn;
            if (!std.mem.eql(u8, msg.verb, verb)) return error.NoSuchMethod;
            return .{ .string = reply };
        }
    };
}
