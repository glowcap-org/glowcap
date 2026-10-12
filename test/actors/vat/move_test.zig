//! moveOut and the sever it skips: a moved reply transfers with pointer
//! identity, only the turn's own moves skip the sever, a move under a live
//! snapshot moves the clone, and errors after a move leak nothing.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const Turn = actors.Turn;
const Message = actors.Message;
const promise_capture = @import("../../support/capture.zig");
const cross_peer = @import("../../support/cross_peer.zig");
const peer_fixture = @import("../../support/peer_fixture.zig");
const poison = @import("../../support/poison.zig");

const harness = @import("harness.zig");
const Counter = harness.Counter;
const Greeter = harness.Greeter;
const getN = harness.getN;
const Forwarder = harness.Forwarder;
const MutateThenRead = harness.MutateThenRead;
const Sink = harness.Sink;
const LabelHolder = harness.LabelHolder;
const PersistentCounter = harness.PersistentCounter;
const Captured = promise_capture.CapturedBytes;
const StringCapture = promise_capture.CapturedString;

/// A persistent actor whose reply aliases its own heap state while it becomes a
/// fresh state in the same turn. The become frees this box when the turn
/// unwinds, so the reply, a borrow into that box, would dangle unless the vat
/// severs it onto the turn arena before promoting. The label is a separate heap
/// allocation freed by `deinit`, so a stale read lands on memory the testing
/// allocator has already reclaimed.
const AliasingSwapper = struct {
    pub const snapshot_persistent = true;
    allocator: std.mem.Allocator,
    label: []u8,

    pub fn handle(self: *const AliasingSwapper, turn: *Turn, msg: Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "swap")) return error.NoSuchMethod;
        // Reply with the current label (borrowed from this box's state), then
        // transition to the next. The next label's heap moves into the new box;
        // a failed become frees it here rather than leaking.
        const reply = model.Argument{ .bytes = self.label };
        const next = try self.allocator.dupe(u8, try msg.argBytes(0));
        turn.become(AliasingSwapper, .{ .allocator = self.allocator, .label = next }) catch |err| {
            self.allocator.free(next);
            return err;
        };
        return reply;
    }

    pub fn deinit(self: *AliasingSwapper, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
    }
};

test "a reply aliasing state survives a same-turn become" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const swapper = try vat.spawn(AliasingSwapper, .{
        .allocator = allocator,
        .label = try allocator.dupe(u8, "alpha"),
    });

    // Near-call: the returned reply must still read "alpha" after the become
    // freed the box "alpha" lived in. Read it before any later top-level turn
    // resets the arena the severed copy lives in.
    const near_reply = try vat.near(swapper, .{ .verb = "swap", .args = &.{.{ .bytes = "beta" }} });
    try std.testing.expectEqualStrings("alpha", near_reply.bytes);

    // Eventual-send + drive: `settleLocal` clones the reply, reading the box the
    // become freed unless `callLocal` severed it first.
    var captured = Captured{};
    const promise = try vat.send(swapper, .{ .verb = "swap", .args = &.{.{ .bytes = "gamma" }} });
    try vat.on(promise, .{ .ctx = &captured, .func = Captured.record });
    try vat.drive();
    try std.testing.expectEqualStrings("beta", captured.buf[0..captured.len]);
}

/// A mutable actor that swaps its owned label for a fresh one and hands the old
/// buffer to the reply with `turn.moveOut`, the headline use of the move: an
/// O(1) transfer where copying the buffer onto the turn arena would be O(len).
/// No `become` in sight. The move stands on its own.
const BufferHandoff = struct {
    allocator: std.mem.Allocator,
    label: []u8,

    pub fn handle(self: *BufferHandoff, turn: *Turn, msg: Message) !model.Argument {
        if (std.mem.eql(u8, msg.verb, "swap")) {
            const reply = try turn.moveOut(&self.label);
            self.label = try self.allocator.dupe(u8, try msg.argBytes(0));
            return reply;
        }
        if (std.mem.eql(u8, msg.verb, "swap-then-fail")) {
            _ = try turn.moveOut(&self.label);
            return error.Boom;
        }
        if (std.mem.eql(u8, msg.verb, "len")) return .{ .integer = @intCast(self.label.len) };
        return error.NoSuchMethod;
    }

    pub fn clone(self: *const BufferHandoff, allocator: std.mem.Allocator) std.mem.Allocator.Error!BufferHandoff {
        return .{ .allocator = self.allocator, .label = try allocator.dupe(u8, self.label) };
    }

    pub fn deinit(self: *BufferHandoff, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
    }
};

test "moveOut transfers the reply buffer with zero copies (pointer identity)" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const original = try allocator.dupe(u8, "alpha");
    const actor = try vat.spawn(BufferHandoff, .{ .allocator = allocator, .label = original });

    // The near reply is the very allocation the state held, moved, not copied.
    const near_reply = try vat.near(actor, .{ .verb = "swap", .args = &.{.{ .bytes = "beta" }} });
    try std.testing.expectEqualStrings("alpha", near_reply.bytes);
    try std.testing.expectEqual(@intFromPtr(original.ptr), @intFromPtr(near_reply.bytes.ptr));

    // The eventual path still reads the moved bytes live: the vat frees them
    // only when its next outermost turn begins.
    var captured = Captured{};
    const promise = try vat.send(actor, .{ .verb = "swap", .args = &.{.{ .bytes = "gamma" }} });
    try vat.on(promise, .{ .ctx = &captured, .func = Captured.record });
    try vat.drive();
    try std.testing.expectEqualStrings("beta", captured.buf[0..captured.len]);
}

test "a handler error after moveOut leaks nothing and leaves the field cleared" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const actor = try vat.spawn(BufferHandoff, .{
        .allocator = allocator,
        .label = try allocator.dupe(u8, "alpha"),
    });
    // The moved bytes are vat-held from the moment `moveOut` returns, so the
    // error path frees them on schedule (the testing allocator would report a
    // leak otherwise); the cleared field stays cleared, mutable-actor state
    // changes never roll back.
    try std.testing.expectError(error.Boom, vat.near(actor, .{ .verb = "swap-then-fail" }));
    try std.testing.expectEqual(@as(i64, 0), (try vat.near(actor, .{ .verb = "len" })).integer);
}

test "moveOut under a live snapshot moves the copy-on-write clone, not the shared state" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const actor = try vat.spawn(BufferHandoff, .{
        .allocator = allocator,
        .label = try allocator.dupe(u8, "v0"),
    });
    var snap = try vat.snapshot();
    defer snap.deinit();

    // The mutating turn runs against the copy-on-write clone, so the buffer
    // `moveOut` hands the vat is the clone's, the snapshot's "v0" is never
    // moved or freed under it.
    const reply = try vat.near(actor, .{ .verb = "swap", .args = &.{.{ .bytes = "v1" }} });
    try std.testing.expectEqualStrings("v0", reply.bytes);

    try vat.restore(&snap);
    const restored = try vat.near(actor, .{ .verb = "swap", .args = &.{.{ .bytes = "v2" }} });
    try std.testing.expectEqualStrings("v0", restored.bytes);
}

/// A mutable actor that `become`s while its reply rides `moveOut`, the moved
/// bytes are vat-owned, so they outlive the old box with no sever-copy.
const MovingSwapper = struct {
    allocator: std.mem.Allocator,
    label: []u8,

    pub fn handle(self: *MovingSwapper, turn: *Turn, msg: Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "swap")) return error.NoSuchMethod;
        const reply = try turn.moveOut(&self.label);
        try turn.become(MovingSwapper, .{
            .allocator = self.allocator,
            .label = try self.allocator.dupe(u8, try msg.argBytes(0)),
        });
        return reply;
    }

    pub fn deinit(self: *MovingSwapper, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
    }
};

test "moveOut hands an owned reply to the vat with no sever-copy across a become" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const original = try allocator.dupe(u8, "alpha");
    const swapper = try vat.spawn(MovingSwapper, .{ .allocator = allocator, .label = original });

    // Pointer identity across the become: the reply is the moved allocation
    // itself, proving the sever-copy was skipped and the become still landed.
    const near_reply = try vat.near(swapper, .{ .verb = "swap", .args = &.{.{ .bytes = "beta" }} });
    try std.testing.expectEqualStrings("alpha", near_reply.bytes);
    try std.testing.expectEqual(@intFromPtr(original.ptr), @intFromPtr(near_reply.bytes.ptr));

    var captured = Captured{};
    const promise = try vat.send(swapper, .{ .verb = "swap", .args = &.{.{ .bytes = "gamma" }} });
    try vat.on(promise, .{ .ctx = &captured, .func = Captured.record });
    try vat.drive();
    try std.testing.expectEqualStrings("beta", captured.buf[0..captured.len]);
}

/// A mutable actor that moves one field out but replies with a borrow of a
/// *different* field, and `become`s. The moved bytes are vat-owned, but the
/// reply is not them, it borrows the old box, which the become frees, so the
/// vat must still sever it. The pointer-identity gate in `callLocal` is what
/// this pins: `moveOut` must never blanket-disable the sever for a reply it
/// does not actually own.
const MisdirectedMover = struct {
    allocator: std.mem.Allocator,
    scratch: []u8,
    label: []u8,

    pub fn handle(self: *MisdirectedMover, turn: *Turn, msg: Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "swap")) return error.NoSuchMethod;
        _ = try turn.moveOut(&self.scratch);
        try turn.become(MisdirectedMover, .{
            .allocator = self.allocator,
            .scratch = try self.allocator.dupe(u8, "scratch"),
            .label = try self.allocator.dupe(u8, try msg.argBytes(0)),
        });
        return .{ .bytes = self.label };
    }

    pub fn deinit(self: *MisdirectedMover, allocator: std.mem.Allocator) void {
        allocator.free(self.scratch);
        allocator.free(self.label);
    }
};

test "a reply borrowing state other than the moved bytes is still severed across a become" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const mover = try vat.spawn(MisdirectedMover, .{
        .allocator = allocator,
        .scratch = try allocator.dupe(u8, "scratch"),
        .label = try allocator.dupe(u8, "alpha"),
    });

    // The reply borrows `label` in the box the become frees; without the
    // sever this reads freed memory (the testing allocator poisons it).
    const near_reply = try vat.near(mover, .{ .verb = "swap", .args = &.{.{ .bytes = "beta" }} });
    try std.testing.expectEqualStrings("alpha", near_reply.bytes);

    var captured = Captured{};
    const promise = try vat.send(mover, .{ .verb = "swap", .args = &.{.{ .bytes = "gamma" }} });
    try vat.on(promise, .{ .ctx = &captured, .func = Captured.record });
    try vat.drive();
    try std.testing.expectEqualStrings("beta", captured.buf[0..captured.len]);
}

/// A mutable actor that moves TWO fields out in one turn and replies with the
/// FIRST, then `become`s. The sever gate scans every allocation the turn
/// moved, not just the last, so this reply is recognized as vat-owned and
/// returned with pointer identity, no sever-copy.
const DoubleMover = struct {
    allocator: std.mem.Allocator,
    first: []u8,
    second: []u8,

    pub fn handle(self: *DoubleMover, turn: *Turn, msg: Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "swap")) return error.NoSuchMethod;
        const reply = try turn.moveOut(&self.first);
        _ = try turn.moveOut(&self.second);
        try turn.become(DoubleMover, .{
            .allocator = self.allocator,
            .first = try self.allocator.dupe(u8, try msg.argBytes(0)),
            .second = try self.allocator.dupe(u8, try msg.argBytes(0)),
        });
        return reply;
    }

    pub fn deinit(self: *DoubleMover, allocator: std.mem.Allocator) void {
        allocator.free(self.first);
        allocator.free(self.second);
    }
};

test "a turn that moves two fields and returns the first still skips the sever" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const original = try allocator.dupe(u8, "alpha");
    const mover = try vat.spawn(DoubleMover, .{
        .allocator = allocator,
        .first = original,
        .second = try allocator.dupe(u8, "sigma"),
    });

    // Pointer identity across the become: the reply is the first moved
    // allocation itself. A last-move-only gate would miss it and pay a
    // spurious (safe) sever-copy; the whole-turn scan recognizes it.
    const reply = try vat.near(mover, .{ .verb = "swap", .args = &.{.{ .bytes = "beta" }} });
    try std.testing.expectEqualStrings("alpha", reply.bytes);
    try std.testing.expectEqual(@intFromPtr(original.ptr), @intFromPtr(reply.bytes.ptr));
}

/// The `moveOutString` mirror of `MovingSwapper`: the moved buffer returns as
/// a `string` argument and still outlives a same-turn become with no copy.
const StringSwapper = struct {
    allocator: std.mem.Allocator,
    label: []u8,

    pub fn handle(self: *StringSwapper, turn: *Turn, msg: Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "swap")) return error.NoSuchMethod;
        const reply = try turn.moveOutString(&self.label);
        try turn.become(StringSwapper, .{
            .allocator = self.allocator,
            .label = try self.allocator.dupe(u8, try msg.argBytes(0)),
        });
        return reply;
    }

    pub fn deinit(self: *StringSwapper, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
    }
};

test "moveOutString hands an owned string reply to the vat with no sever-copy across a become" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const original = try allocator.dupe(u8, "alpha");
    const swapper = try vat.spawn(StringSwapper, .{ .allocator = allocator, .label = original });

    // The near reply is the very allocation the state held, returned through
    // the string arm, the sever gate covers `.string` exactly as `.bytes`.
    const near_reply = try vat.near(swapper, .{ .verb = "swap", .args = &.{.{ .bytes = "beta" }} });
    try std.testing.expectEqualStrings("alpha", near_reply.string);
    try std.testing.expectEqual(@intFromPtr(original.ptr), @intFromPtr(near_reply.string.ptr));

    // The eventual path clones the string for the listener like any reply.
    var captured = StringCapture{};
    const promise = try vat.send(swapper, .{ .verb = "swap", .args = &.{.{ .bytes = "gamma" }} });
    try vat.on(promise, .{ .ctx = &captured, .func = StringCapture.record });
    try vat.drive();
    try std.testing.expectEqualStrings("beta", captured.buf[0..captured.len]);
}
