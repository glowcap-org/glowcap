//! Standalone host for the accountability-on-pancake application.
//!
//! Listens on 127.0.0.1 — an ephemeral port by default, or the one named by
//! `--port=N` — prints the port so a foreign caller can connect, then serves
//! one connection: publishes the Affordance under the name "affordance",
//! processes invocations, and exits when the caller leaves.
//!
//! The cross-seam demo script starts this, reads the port, and points
//! its Deno or Python caller at it; the caller fetches the Affordance
//! by name.

const std = @import("std");
const pancake = @import("pancake");

const identity = @import("identity.zig");
const episode = @import("episode.zig");
const accountable = @import("accountable.zig");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net_adapter.tcp;
const net = std.Io.net;

const AFFORDANCE_NAME = "affordance";
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

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program name
    var bind_port: u16 = 0;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            bind_port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch {
                std.debug.print("accountability-host: --port must be an integer in 1..65535\n", .{});
                return error.BadPort;
            };
        } else {
            std.debug.print("accountability-host: unknown argument '{s}'\n", .{arg});
            return error.BadArgument;
        }
    }

    var listener = try tcp.Listener.bind(io, .{ .ip4 = net.Ip4Address.loopback(bind_port) });
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

    var vat = try driver.acceptTcp(allocator, &peer, &listener, read_buf, write_buf);
    defer vat.deinit();

    _ = try vat.publish(AFFORDANCE_NAME, Affordance, .{
        .store = &store,
        .served = &served,
    });

    try vat.serve();

    std.debug.print("ACCOUNTABILITY-HOST-SERVED {d}\n", .{served});
}
