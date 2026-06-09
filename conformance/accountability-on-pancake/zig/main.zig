//! accountability-on-pancake — a real application on pancake's own runtime.
//!
//! The same shape as the Goblins worked example, moved onto pancake as its CapTP
//! runtime: a vat hosts an Affordance behind an OCapN capability, a caller invokes
//! it across a real TCP/OCapN session, and every invocation produces a signed,
//! transparency-logged Episode attributing the caller. Identity (KERI), Episodes,
//! and the transparency log all live above pancake; pancake provides only the
//! capability-secure wire.
//!
//! Run it with one command:
//!
//!   zig build accountability
//!
//! Two real `engine.Peer`s talk over a 127.0.0.1 socket pair on a
//! `std.Io.Threaded` backend — the host accepts on a concurrent fiber, the caller
//! drives this one. The host publishes the Affordance at an export; the caller
//! imports it and eventual-sends an `invoke`. Attribution is not a trusted
//! header: the caller signs the request with its KERI key, and the host refuses
//! to account for an invocation it cannot attest. That signed attribution is the
//! thing an ambient-authority HTTP call structurally cannot produce — see
//! `../why-this-couldnt-be-http.md`.

const std = @import("std");
const pancake = @import("pancake");

const identity = @import("identity.zig");
const episode = @import("episode.zig");
const accountable = @import("accountable.zig");
const log = @import("log.zig");

const model = pancake.model;
const engine = pancake.engine;
const actors = pancake.actors;
const tcp = pancake.net_adapter.tcp;
const crypto = pancake.foundation.crypto;
const net = std.Io.net;

const AFFORDANCE_EXPORT: u64 = 5;
const frame_cap: usize = 1 << 16;
const data_root = "conformance/accountability-on-pancake/.data";

/// Queue a keyed `op:start-session` over a fresh random session key, signing a
/// `tcp` locator with `designator`. Entropy is drawn here at the I/O boundary,
/// never in the no-I/O core. Both peers verify the partner's signature (the
/// `initNegotiating` default), so the conversation opens only on an authenticated
/// handshake. These session keys are pancake's wire identity, distinct from the
/// application's KERI identity, which lives above pancake and carries the
/// accountability claims.
fn sendKeyedHello(peer: *engine.Peer, designator: []const u8) !void {
    var seed: [crypto.SEED_BYTES]u8 = undefined;
    if (std.os.linux.getrandom(&seed, seed.len, 0) != seed.len) return error.HandshakeEntropyFailed;
    const secret = crypto.SecretKey.fromSeed(seed) catch return error.HandshakeEntropyFailed;
    const locator: model.PeerLocator = .{
        .transport = tcp.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    };
    try peer.sendKeyedStartSession(.v1_0, locator, secret);
}

fn isOpen(peer: *engine.Peer) bool {
    return peer.session_state.state == .open;
}

/// The signed preimage that binds a caller to a request. The caller signs it; the
/// host verifies it before attributing an Episode.
fn attestation(buf: []u8, request: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "invoke|{s}", .{request}) catch unreachable;
}

/// The Affordance: a published actor whose every invocation the host accounts
/// for. It verifies the caller's attestation, then emits an Outcome Episode
/// attributing the true caller before returning the result.
const Affordance = struct {
    store: *accountable.Store,
    served: *usize,
    last_subject: *[identity.SAID_LEN]u8,

    pub fn handle(self: *Affordance, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "invoke")) return error.NoSuchMethod;
        if (msg.args.len != 4) return error.BadInvocation;
        const subject = strArg(msg.args[0]) orelse return error.BadInvocation;
        const verkey_b64 = strArg(msg.args[1]) orelse return error.BadInvocation;
        const request = strArg(msg.args[2]) orelse return error.BadInvocation;
        const sig_b64 = strArg(msg.args[3]) orelse return error.BadInvocation;

        // Attribution is attested, not trusted. Verify the caller's signature
        // over the request against the presented verkey; refuse otherwise.
        const verkey = decodeKey(verkey_b64) catch return error.UnattestedCaller;
        const sig = decodeSig(sig_b64) catch return error.UnattestedCaller;
        var att_buf: [512]u8 = undefined;
        const att = attestation(&att_buf, request);
        identity.verify(verkey, att, sig) catch return error.UnattestedCaller;

        // The capability invocation succeeds; account for it.
        const result = try std.fmt.allocPrint(turn.arena, "ack:{s}", .{request});
        _ = try self.store.record(.outcome, subject, "demo", result);
        self.served.* += 1;
        @memcpy(self.last_subject, subject[0..identity.SAID_LEN]);
        return .{ .string = result };
    }
};

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

const HostArgs = struct {
    listener: *tcp.Listener,
    allocator: std.mem.Allocator,
    store: *accountable.Store,
    served: *usize,
    last_subject: *[identity.SAID_LEN]u8,
};

/// Accept one connection, publish the Affordance, and serve invocations until
/// the caller closes (graceful EOF).
fn hostServe(args: HostArgs) !void {
    const allocator = args.allocator;
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var conn = try args.listener.accept(&peer, read_buf, write_buf);
    defer conn.deinit();

    var vat = actors.Vat.initOver(allocator, &peer);
    defer vat.deinit();
    const affordance = try vat.spawn(Affordance, .{
        .store = args.store,
        .served = args.served,
        .last_subject = args.last_subject,
    });
    try vat.publish(affordance, AFFORDANCE_EXPORT);

    try sendKeyedHello(&peer, "host");

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
}

/// What the caller's resolve listener captures from the far promise.
const CallerOutcome = struct {
    done: bool = false,
    ok: bool = false,
    result: [256]u8 = undefined,
    result_len: usize = 0,
};

fn onResolve(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const out: *CallerOutcome = @ptrCast(@alignCast(ctx.?));
    out.done = true;
    switch (resolution) {
        .fulfilled => |arg| {
            out.ok = true;
            if (strArg(arg)) |s| {
                const n = @min(s.len, out.result.len);
                @memcpy(out.result[0..n], s[0..n]);
                out.result_len = n;
            }
        },
        .broken => |reason| {
            out.ok = false;
            const n = @min(reason.len, out.result.len);
            @memcpy(out.result[0..n], reason[0..n]);
            out.result_len = n;
        },
    }
}

fn banner(step: u8, msg: []const u8) void {
    std.debug.print("[{d}/8] {s}\n", .{ step, msg });
}

/// Drive one capability invocation to its resolution over the live session.
/// `tamper` corrupts the signature so the host refuses to attest it — the path
/// that must surface as a clean broken promise, not a crash or a silent success.
fn invoke(
    vat: *actors.Vat,
    peer: *engine.Peer,
    conn: *tcp.Connection,
    caller: *const identity.Identity,
    request: []const u8,
    tamper: bool,
) !CallerOutcome {
    var att_buf: [512]u8 = undefined;
    const att = attestation(&att_buf, request);
    var sig = caller.current.sign(att);
    if (tamper) sig[0] ^= 0xff;

    var sig_b64: [std.base64.url_safe_no_pad.Encoder.calcSize(64)]u8 = undefined;
    const sig_enc = std.base64.url_safe_no_pad.Encoder.encode(&sig_b64, &sig);
    var verkey_b64: [1 + std.base64.url_safe_no_pad.Encoder.calcSize(32)]u8 = undefined;
    verkey_b64[0] = 'D';
    _ = std.base64.url_safe_no_pad.Encoder.encode(verkey_b64[1..], &caller.current.verkey());

    const affordance_ref: actors.Ref = .{ .far = model.FarRef.object(AFFORDANCE_EXPORT) };
    var outcome = CallerOutcome{};
    const promise = try vat.send(affordance_ref, .{
        .verb = "invoke",
        .args = &.{
            .{ .string = caller.aidSlice() },
            .{ .string = &verkey_b64 },
            .{ .string = request },
            .{ .string = sig_enc },
        },
    });
    try vat.on(promise, .{ .ctx = &outcome, .func = onResolve });

    var spins: usize = 0;
    while (!outcome.done and spins < 10_000) : (spins += 1) {
        const progress = conn.pump() catch |err| {
            std.debug.print("      caller pump error: {s}\n", .{@errorName(err)});
            break;
        };
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            _ = vat.serve(&event) catch {};
        }
        if (progress == .closed) break;
    }
    return outcome;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("accountability-on-pancake — a real application on pancake's runtime\n\n", .{});

    // ---- Identities (above pancake) -------------------------------------------
    banner(1, "Host vat and caller each incept a KERI-anchored identity");
    var host_id = try identity.Identity.incept(allocator, io);
    defer host_id.deinit();
    var caller_id = try identity.Identity.incept(allocator, io);
    defer caller_id.deinit();
    std.debug.print("      host AID:   {s}\n", .{host_id.aidSlice()});
    std.debug.print("      caller AID: {s}\n", .{caller_id.aidSlice()});

    banner(2, "Caller rotates its key (pre-rotation discipline holds)");
    const rot_said = try caller_id.rotate(io);
    std.debug.print("      caller rotated; new key-event SAID: {s}\n", .{&rot_said});

    var host_store = try accountable.Store.init(allocator, io, &host_id, data_root ++ "/host");
    defer host_store.deinit();
    var caller_store = try accountable.Store.init(allocator, io, &caller_id, data_root ++ "/caller");
    defer caller_store.deinit();

    // ---- The capability wire (pancake) ----------------------------------------
    banner(3, "Host publishes the Affordance behind an OCapN capability");
    var listener = try tcp.Listener.bind(io, .{ .ip4 = net.Ip4Address.loopback(0) });
    defer listener.deinit();
    const address = listener.localAddress();

    var served: usize = 0;
    var last_subject: [identity.SAID_LEN]u8 = undefined;
    var host_future = try io.concurrent(hostServe, .{HostArgs{
        .listener = &listener,
        .allocator = allocator,
        .store = &host_store,
        .served = &served,
        .last_subject = &last_subject,
    }});

    // Caller side.
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    try peer.importObject(AFFORDANCE_EXPORT);

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var conn = try tcp.connectAddress(io, &peer, address, read_buf, write_buf);

    var vat = actors.Vat.initOver(allocator, &peer);
    defer vat.deinit();

    try sendKeyedHello(&peer, "caller");
    _ = try conn.runUntil(isOpen);
    while (peer.pollEvent()) |ev| {
        var e = ev;
        e.deinit();
    }
    std.debug.print("      session open over TCP {f}\n", .{address});

    // ---- The invocation, accounted on both sides ------------------------------
    const request = "read-thermostat";

    banner(4, "Caller writes an Attempt Episode, then invokes the capability");
    // The Attempt Episode is durable *before* the wire send — intent recorded
    // first, exactly as the documented seam requires.
    _ = try caller_store.record(.attempt, caller_id.aidSlice(), "demo", request);

    const outcome = try invoke(&vat, &peer, &conn, &caller_id, request, false);
    if (!outcome.ok) {
        std.debug.print("      invocation did not resolve fulfilled (done={}, reason='{s}')\n", .{ outcome.done, outcome.result[0..outcome.result_len] });
        conn.deinit();
        _ = host_future.await(io) catch |err| std.debug.print("      host fiber error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    }

    banner(5, "Host verifies the attestation and resolves the invocation");
    std.debug.print("      result: {s}\n", .{outcome.result[0..outcome.result_len]});
    _ = try caller_store.record(.outcome, caller_id.aidSlice(), "demo", outcome.result[0..outcome.result_len]);

    banner(6, "A caller it cannot attest is refused — a clean broken promise, no Episode");
    // Same caller, same request, but a corrupted signature: the host must refuse
    // to account for what it cannot attribute. The refusal travels back as a
    // broken promise (not a session abort), and the host writes no Episode for it.
    const served_before = served;
    const refused = try invoke(&vat, &peer, &conn, &caller_id, request, true);
    if (refused.ok or !refused.done) {
        std.debug.print("      a tampered invocation was NOT refused (ok={}, done={})\n", .{ refused.ok, refused.done });
        conn.deinit();
        _ = host_future.await(io) catch {};
        std.process.exit(1);
    }
    if (served != served_before) {
        std.debug.print("      host accounted for an unattested invocation\n", .{});
        std.process.exit(1);
    }
    std.debug.print("      refused: {s}\n", .{refused.result[0..refused.result_len]});

    // Let the host observe EOF and finish.
    conn.deinit();
    _ = host_future.await(io) catch |err| {
        std.debug.print("      host fiber error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    banner(7, "Host's Outcome Episode attributes the TRUE caller");
    if (served == 0) {
        std.debug.print("      host served no invocation\n", .{});
        std.process.exit(1);
    }
    const attributed = std.mem.eql(u8, &last_subject, caller_id.aidSlice());
    std.debug.print("      host attributed: {s}\n", .{&last_subject});
    std.debug.print("      matches caller AID: {}\n", .{attributed});
    if (!attributed) std.process.exit(1);

    // ---- Audit -----------------------------------------------------------------
    banner(8, "Every Episode is auditable; transparency roots are stable");
    const caller_count = try caller_store.auditAll();
    const host_count = try host_store.auditAll();
    const caller_root = log.toHex(try caller_store.currentRoot());
    const host_root = log.toHex(try host_store.currentRoot());
    std.debug.print("      caller episodes: {d} (root {s})\n", .{ caller_count, &caller_root });
    std.debug.print("      host episodes:   {d} (root {s})\n", .{ host_count, &host_root });

    if (caller_count != 2 or host_count != 1) {
        std.debug.print("      unexpected episode counts (caller={d} host={d})\n", .{ caller_count, host_count });
        std.process.exit(1);
    }

    std.debug.print(
        \\
        \\accountability-on-pancake OK: a capability invocation crossed a real
        \\OCapN/TCP session between two pancake peers, and the host produced a
        \\verifiable Episode attributing the attested caller. pancake hosted the
        \\wire; identity, Episodes, and the transparency log stayed above it.
        \\
    , .{});
}
