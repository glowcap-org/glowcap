//! 06: Pipeline a dependent call, receive an attenuated capability.
//!
//! The two moves that make capabilities compose. A listener asks a record desk
//! to `checkout` its house record. Without waiting for the answer, it
//! addresses `play` and `eject` at the unresolved checkout answer. All three
//! delivers cross the wire as one batch. The desk queues the dependent calls
//! on its pending answer and drains them onto the record the moment `checkout`
//! resolves. No round trip is paid to learn an answer only the partner needs.
//!
//! The desk, meanwhile, never hands out the record itself. It wraps it in an
//! attenuator that forwards only `play`, so the refused authority is
//! unrepresentable rather than permission-checked: `play` resolves with the
//! song, and the pipelined `eject` comes back a broken vow without the record
//! ever hearing the verb. Chapter 01's session pipelines this same way over a
//! real socket.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;

const Record = struct {
    title: []const u8,

    pub fn handle(self: *Record, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        if (msg.is("play"))
            return .{ .string = try std.fmt.allocPrint(turn.arena, "spinning: {s}", .{self.title}) };
        if (msg.is("eject")) return .{ .string = self.title };
        return error.NoSuchMethod;
    }
};

const Desk = struct {
    pub fn handle(self: *Desk, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        _ = self;
        if (!msg.is("checkout")) return error.NoSuchMethod;
        // Spawn the record, then export only a play-attenuated view of it: the
        // proxy is an ordinary actor whose handler forwards `play` and breaks
        // everything else, so the reply grants exactly one verb of authority.
        const record = try turn.spawn(Record, .{ .title = "Blue Train" });
        const guarded = try actors.ocap.attenuate(turn.vat, record, &.{"play"});
        const port = turn.port() orelse return error.NotConnected;
        return .{ .reference = .{ .near = try port.projectActor(turn.vat, guarded) } };
    }
};

const Outcome = struct {
    done: bool = false,
    broken: bool = false,
    text: [64]u8 = undefined,
    text_len: usize = 0,

    fn record(self: *Outcome, broken: bool, s: []const u8) void {
        self.done = true;
        self.broken = broken;
        const n = @min(s.len, self.text.len);
        @memcpy(self.text[0..n], s[0..n]);
        self.text_len = n;
    }

    fn slice(self: *const Outcome) []const u8 {
        return self.text[0..self.text_len];
    }
};

fn onResolve(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const outcome: *Outcome = @ptrCast(@alignCast(ctx.?));
    switch (resolution) {
        .fulfilled => |arg| outcome.record(false, switch (arg) {
            .string => |s| s,
            else => "(unexpected)",
        }),
        .broken => |reason| outcome.record(true, reason),
        .give => {},
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer if (gpa.deinit() == .leak) @panic("leaked memory");
    const allocator = gpa.allocator();

    var pair = try engine.pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();
    const desk_peer = &pair.p1;
    const listener_peer = &pair.p2;

    var desk_vat = actors.Vat.init(allocator);
    defer desk_vat.deinit();
    var desk_port = actors.Port.init(allocator, desk_peer);
    defer desk_port.deinit(&desk_vat);
    const desk = try desk_vat.spawn(Desk, .{});
    try desk_port.bindExport(&desk_vat, desk, 5);
    // The listener learns the desk's position out-of-band (this example wires
    // both peers by hand), so the desk takes an explicit grant. The record the
    // desk checks out later needs none: its reference rides the checkout reply,
    // and that first marshal is the grant.
    try desk_peer.exportObject(5);
    try listener_peer.importObject(5);

    var listener_vat = actors.Vat.init(allocator);
    defer listener_vat.deinit();
    var listener_port = actors.Port.init(allocator, listener_peer);
    defer listener_port.deinit(&listener_vat);

    // The whole dependent chain leaves before anything resolves: `checkout`,
    // then `play` and `eject` aimed at checkout's still-pending answer.
    const desk_ref: actors.Ref = .{ .far = model.FarRef.object(5) };
    const checkout = try listener_port.send(&listener_vat, desk_ref, .{ .verb = "checkout" });
    const play = try listener_port.sendToAnswer(&listener_vat, checkout.far, .{ .verb = "play" });
    const eject = try listener_port.sendToAnswer(&listener_vat, checkout.far, .{ .verb = "eject" });

    var played = Outcome{};
    var ejected = Outcome{};
    try listener_port.on(&listener_vat, play, .{ .ctx = &played, .func = onResolve });
    try listener_port.on(&listener_vat, eject, .{ .ctx = &ejected, .func = onResolve });

    // Shuttle frames until both sides go quiet: the desk drains the pipelined
    // calls onto the freshly attenuated record when `checkout` resolves. Each
    // `serve` is followed by `drive`, the attenuator answers by *forwarding*,
    // which queues a local send the drive loop runs (the serve-then-drive pump
    // `driver.Session.step` does over a real socket).
    var progressed = true;
    while (progressed) {
        progressed = false;
        while ((try listener_peer.step()) != .idle) {}
        while (listener_peer.takeOutbound()) |frame| {
            try desk_peer.feedOwned(frame);
            progressed = true;
        }
        while ((try desk_peer.step()) != .idle) {}
        while (desk_peer.pollEvent()) |ev| {
            var e = ev;
            defer e.deinit();
            _ = try desk_port.serve(&desk_vat, &e);
            progressed = true;
        }
        try desk_vat.drive();
        while ((try desk_peer.step()) != .idle) {}
        while (desk_peer.takeOutbound()) |frame| {
            try listener_peer.feedOwned(frame);
            progressed = true;
        }
        while ((try listener_peer.step()) != .idle) {}
        while (listener_peer.pollEvent()) |ev| {
            var e = ev;
            defer e.deinit();
            _ = try listener_port.serve(&listener_vat, &e);
            progressed = true;
        }
        try listener_vat.drive();
    }

    if (!played.done or !ejected.done) {
        std.debug.print("pipelined vows did not settle\n", .{});
        std.process.exit(1);
    }
    if (played.broken or !ejected.broken) {
        std.debug.print("attenuation went wrong: play='{s}' eject='{s}'\n", .{ played.slice(), ejected.slice() });
        std.process.exit(1);
    }
    std.debug.print("pipelined play resolved: {s}\n", .{played.slice()});
    std.debug.print("pipelined eject refused: {s}\n", .{ejected.slice()});
}
