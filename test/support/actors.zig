//! Canonical scenario actors for the driver and transport tests.
//! Consumers: `test/driver/blocking_session/`,
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

/// The owning-tier twin of `StaticReplyActor`: the same one-verb static reply
/// as a Value-shaped behavior for `driver.Session.publish` / `spawn`, whose
/// behaviors speak opaque capabilities (`driver.Hosting`).
pub fn StaticReplyValueActor(comptime verb: []const u8, comptime reply: []const u8) type {
    return struct {
        pub fn handle(self: *@This(), ht: *pancake.driver.HostTurn, v: []const u8, args: []const pancake.driver.Value) !pancake.driver.Value {
            _ = self;
            _ = ht;
            _ = args;
            if (!std.mem.eql(u8, v, verb)) return error.NoSuchMethod;
            return .{ .string = reply };
        }
    };
}

/// A counting target: every `hit` is one local turn and the reply is the
/// running count, which makes it the actor to reach for when a test counts
/// deliveries or drives amplification.
pub const Counter = struct {
    hits: i64 = 0,
    pub fn handle(self: *Counter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "hit")) return error.NoSuchMethod;
        self.hits += 1;
        return .{ .integer = self.hits };
    }
};
