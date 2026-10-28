//! A cooperative fetch-then-deliver send parked on a promise's resolution.
//!
//! The caller owns the in-flight state machine between its own turns. `Served`
//! orchestrates the begins and the vow listeners complete it. This module owns
//! the parked state and its staging invariants.

const std = @import("std");

const model = @import("model");
const actors = @import("actors");
const served_mod = @import("served.zig");

/// A cooperative fetch-then-deliver in flight, the caller-owned context
/// `beginSendNamed` / `beginTellNamed` chain through. The caller keeps it
/// alive and address-stable until the terminal listener fires (or the
/// session tears down), then frees the owned message clone with `deinit`.
/// `stage` says which leg an outcome came from: a break delivered while
/// `stage == .fetching` is the fetch's own refusal (an unpublished name),
/// so a UI can attribute it without parsing reasons.
pub const PendingSend = struct {
    served: *served_mod.Served,
    vat: *actors.Vat,
    /// Owns the verb and args clone from begin until `deinit`: the send
    /// happens later, inside the fetch vow's listener, after the caller's
    /// borrowed message may already be gone.
    msg_arena: std.heap.ArenaAllocator,
    verb: []const u8 = "",
    args: []const model.Argument = &.{},
    mode: Mode = .send,
    stage: Stage = .fetching,
    terminal: actors.Listener,
    completion: ?Completion = null,

    pub const Mode = enum { send, tell };
    pub const Stage = enum { fetching, delivering };
    pub const Completion = struct {
        ctx: ?*anyopaque,
        func: *const fn (?*anyopaque) void,
    };

    pub fn deinit(self: *PendingSend) void {
        self.msg_arena.deinit();
    }

    /// The fetch leg's listener: the serve core registers it on the bootstrap
    /// fetch vow it arms in `beginDeliverNamed`.
    pub fn onFetch(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *PendingSend = @ptrCast(@alignCast(ctx.?));
        const target: actors.Ref = switch (resolution) {
            .fulfilled => |value| switch (value) {
                .reference => |reference| switch (reference) {
                    .far => |far| .{ .far = far },
                    else => return self.fireBroken("fetch did not resolve to a capability"),
                },
                else => return self.fireBroken("fetch did not resolve to a capability"),
            },
            // A fetch break forwards verbatim (a cancel or timeout arrives
            // here too); `stage` still reads `.fetching`, which is how the
            // caller attributes it. A bootstrap fetch never fulfills with
            // an introduction, so `.give` rides the same forward rather
            // than an arm it cannot reach.
            .broken, .give => return self.fire(resolution),
        };
        self.stage = .delivering;
        const msg: actors.Message = .{ .verb = self.verb, .args = self.args };
        switch (self.mode) {
            .send => {
                // Registering the terminal on the new vow inside this
                // listener call is the vat's documented re-entrancy: the
                // fire removed this entry first, and a disconnect's
                // `breakFarVows` re-checks for registrations made during
                // the break, so the chained vow can never strand.
                const listener = self.served.port.reserveListener(self.vat, .far) catch |err| return self.fireBroken(@errorName(err));
                const vow = self.served.send(self.vat, target, msg) catch |err| return self.fireBroken(@errorName(err));
                self.served.port.onReserved(self.vat, listener, vow, .{ .ctx = self, .func = onTerminal });
            },
            .tell => {
                self.served.tell(self.vat, target, msg) catch |err| return self.fireBroken(@errorName(err));
                self.fire(.{ .fulfilled = .{ .void = {} } });
            },
        }
    }

    fn onTerminal(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *PendingSend = @ptrCast(@alignCast(ctx.?));
        self.fire(resolution);
    }

    fn fireBroken(self: *PendingSend, reason: []const u8) void {
        self.fire(.{ .broken = reason });
    }

    fn fire(self: *PendingSend, resolution: actors.Resolution) void {
        const terminal = self.terminal;
        if (self.completion) |completion| {
            self.completion = null;
            completion.func(completion.ctx);
        }
        terminal.func(terminal.ctx, resolution);
    }
};
