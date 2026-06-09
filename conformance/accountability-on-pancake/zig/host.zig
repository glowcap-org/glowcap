//! Standalone host for the accountability-on-pancake application.
//!
//! Listens on 127.0.0.1:0 (ephemeral port), prints the port on stdout
//! so a foreign caller can connect, then serves one connection:
//! publishes the Affordance, processes invocations, and exits on EOF.
//!
//! The cross-seam demo script starts this, reads the port, and points
//! its Deno/Python/Racket caller at it.

const std = @import("std");
const pancake = @import("pancake");

const identity = @import("identity.zig");
const episode = @import("episode.zig");
const accountable = @import("accountable.zig");

const model = pancake.model;
const engine = pancake.engine;
const actors = pancake.actors;
const tcp = pancake.net_adapter.tcp;
const net = std.Io.net;

const AFFORDANCE_EXPORT: u64 = 5;
const frame_cap: usize = 1 << 16;
const data_root = "conformance/accountability-on-pancake/.data";

fn strArg(a: model.Argument) ?[]const u8 {
    return switch (a) {
        .string => |s| s,
        else => null,
    };
}

fn decodeKey(b64: []const u8) ![32]u8 {
    if (b64.len != 1 + std.base64.url_safe_no_pad.Encoder.calcSize(32)) return error.BadKey;
    var out: [32]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&out, b64[1..]);
    return out;
}

fn decodeSig(b64: []const u8) ![64]u8 {
    if (b64.len != std.base64.url_safe_no_pad.Encoder.calcSize(64)) return error.BadSig;
    var out: [64]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&out, b64);
    return out;
}

fn attestation(buf: []u8, request: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "invoke|{s}", .{request}) catch unreachable;
}

const Affordance = struct {
    store: *accountable.Store,
    served: *usize,

    pub fn handle(self: *Affordance, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "invoke")) return error.NoSuchMethod;
        if (msg.args.len != 4) return error.BadInvocation;
        const subject = strArg(msg.args[0]) orelse return error.BadInvocation;
        const verkey_b64 = strArg(msg.args[1]) orelse return error.BadInvocation;
        const request = strArg(msg.args[2]) orelse return error.BadInvocation;
        const sig_b64 = strArg(msg.args[3]) orelse return error.BadInvocation;

        const verkey = decodeKey(verkey_b64) catch return error.UnattestedCaller;
        const sig = decodeSig(sig_b64) catch return error.UnattestedCaller;
        var att_buf: [512]u8 = undefined;
        const att = attestation(&att_buf, request);
        identity.verify(verkey, att, sig) catch return error.UnattestedCaller;

        const result = try std.fmt.allocPrint(turn.arena, "ack:{s}", .{request});
        _ = try self.store.record(.outcome, subject, "demo", result);
        self.served.* += 1;
        return .{ .string = result };
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var host_id = try identity.Identity.incept(allocator, io);
    defer host_id.deinit();

    var store = try accountable.Store.init(allocator, io, &host_id, data_root ++ "/host");
    defer store.deinit();

    var listener = try tcp.Listener.bind(io, .{ .ip4 = net.Ip4Address.loopback(0) });
    defer listener.deinit();
    const address = listener.localAddress();
    const port: u16 = switch (address) {
        .ip4 => |a| a.port,
        .ip6 => |a| a.port,
    };

    // The orchestrator parses this line to learn the port.
    std.debug.print("ACCOUNTABILITY-HOST-LISTENING {d}\n", .{port});

    var served: usize = 0;

    // The host and its foreign callers (Deno, Python) establish a real OCapN
    // session: a negotiating peer that completes the keyed `op:start-session`
    // handshake, the same exchange the application surface and a live Goblins
    // peer require.
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var conn = try listener.accept(&peer, read_buf, write_buf);
    defer conn.deinit();

    // Responder half of the keyed handshake: sign a `tcp` locator with a random
    // session seed (entropy at the I/O boundary, never in the core) and pump
    // until the caller's start-session opens the session.
    var seed: [pancake.foundation.crypto.SEED_BYTES]u8 = undefined;
    if (std.os.linux.getrandom(&seed, seed.len, 0) != seed.len) return error.HandshakeEntropyFailed;
    const secret = try pancake.foundation.crypto.SecretKey.fromSeed(seed);
    try peer.sendKeyedStartSession(.v1_0, .{
        .transport = "tcp",
        .designator = "127.0.0.1:0",
        .hints = model.Hints.emptyFalse(),
    }, secret);
    while (!peer.sessionIsOpen()) {
        const progress = conn.pump() catch break;
        if (progress == .closed) break;
    }

    var vat = actors.Vat.initOver(allocator, &peer);
    defer vat.deinit();
    const affordance = try vat.spawn(Affordance, .{
        .store = &store,
        .served = &served,
    });
    try vat.publish(affordance, AFFORDANCE_EXPORT);

    while (true) {
        const progress = conn.pump() catch |err| switch (err) {
            error.ConnectionLost, error.TruncatedFrame => break,
            else => return err,
        };
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            _ = vat.serve(&event) catch {};
        }
        if (progress == .closed) break;
    }

    std.debug.print("ACCOUNTABILITY-HOST-SERVED {d}\n", .{served});
}
