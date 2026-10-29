//! Canonical scenario actors for the driver and transport tests under
//! `test/driver/`: the one-verb greeter in both its wire-tier `actors.Turn`
//! form (byte-fed `Served` hosts and `driver.spawnAt`) and its owning-tier
//! `driver.HostTurn` form (`driver.Session.publish` and `spawn`), and the
//! counting target the budget and reclaim scenarios drive.

const std = @import("std");
const glowcap = @import("glowcap");

const actors = glowcap.actors;
const model = glowcap.ocapn.model;

/// A published actor that answers exactly one verb with a fixed string reply
/// and refuses everything else with `error.NoSuchMethod`. Each test picks a
/// distinct reply text, so a cross-wired session fails its reply assertion
/// instead of passing on another scenario's greeting.
pub fn StaticReplyActor(comptime verb: []const u8, comptime reply: []const u8) type {
    return struct {
        pub fn handle(self: *@This(), turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
            _ = self;
            _ = turn;
            if (!msg.is(verb)) return error.NoSuchMethod;
            return .{ .string = reply };
        }
    };
}

/// The owning-tier twin of `StaticReplyActor`: the same one-verb static reply
/// as a Value-shaped behavior for `driver.Session.publish` / `spawn`, whose
/// behaviors speak opaque capabilities (`driver.Hosting`).
pub fn StaticReplyValueActor(comptime verb: []const u8, comptime reply: []const u8) type {
    return struct {
        pub fn handle(self: *@This(), ht: *glowcap.driver.HostTurn, v: ?[]const u8, args: glowcap.driver.Args) !glowcap.driver.Value {
            _ = self;
            _ = ht;
            _ = args;
            if (!std.mem.eql(u8, v orelse return error.NoSuchMethod, verb)) return error.NoSuchMethod;
            return .{ .string = reply };
        }
    };
}

/// A counting target: every `hit` is one local turn and the reply is the
/// running count, which makes it the actor to reach for when a test counts
/// deliveries or drives amplification.
pub const Counter = struct {
    hits: i64 = 0,
    pub fn handle(self: *Counter, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        _ = turn;
        if (!msg.is("hit")) return error.NoSuchMethod;
        self.hits += 1;
        return .{ .integer = self.hits };
    }
};
