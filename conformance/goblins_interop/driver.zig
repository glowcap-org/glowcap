//! Live interop proof: a native pancake peer holds a real OCapN conversation
//! with a Spritely Goblins v0.18.0 vat over TCP, in *both* directions.
//!
//! The client bracket: pancake spawns the conformance Goblins host
//! (`goblins-host.rkt`), reads its NDJSON readiness to learn the listen
//! port and the published echo cap's swiss-num, dials it over `net_adapter.tcp`,
//! runs the keyed `op:start-session` handshake (real Ed25519, a `tcp` locator
//! with `#f` hints so the signed bytes match what Goblins re-encodes), verifies
//! Goblins' own signed start-session, then bootstrap-fetches the echo cap and
//! calls it, asserting it resolves fulfilled.
//!
//! The listener bracket: pancake then binds its own TCP listener and publishes a
//! Greeter actor behind a swiss-num, and a real Goblins client
//! (`pancake-actor-call.rkt`) dials in, enlivens the actor, and calls it. The
//! actor runs a vat turn and resolves the answer; we assert Goblins received the
//! reply. Together the two brackets prove the bidirectional capability — pancake
//! drives Goblins, and Goblins drives a pancake actor.
//!
//! This is not part of the hermetic `zig build check`: it needs `racket` + the
//! `goblins` collection on PATH, so it runs as the sibling step
//! `zig build goblins-interop`, the way the binding dogfoods need their runtimes.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.model;
const engine = pancake.engine;
const codec = pancake.codec;
const actors = pancake.actors;
const crypto = pancake.foundation.crypto;
const tcp = pancake.net_adapter.tcp;
const net = std.Io.net;

const host = "127.0.0.1";
const port_str = "22099";
const port: u16 = 22099;
const frame_cap: usize = 1 << 16;

const host_script = "conformance/goblins-peer/racket/goblins-host.rkt";
const dialer_script = "conformance/goblins-peer/racket/pancake-actor-call.rkt";
// The pipelining client: it enlivens and calls in one breath (`<-` to the
// unresolved enliven vow), so the call arrives as an inbound pipelined deliver.
const pipelined_dialer_script = "conformance/goblins-peer/racket/goblins-tap-dialer.rkt";

// Listener-scenario wire constants: the ports pancake binds for Goblins to dial,
// and the swiss-num the pancake actor is published behind.
const listen_port_str = "22100";
const listen_port: u16 = 22100;
const pipelined_port_str = "22101";
const pipelined_port: u16 = 22101;
const actor_swiss = "pancakeActorSwissnumABCDEFGH1234";

/// A pancake actor that a live Goblins peer calls over the wire. Goblins invokes
/// a cap positionally — `(<- actor "world")` — so the call arrives with no method
/// symbol: the first argument is the name. The reply is freshly built from
/// `turn.arena`, the per-turn allocator the vat reclaims, so the handler allocates
/// without leaking (ADR-0036).
const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        const name: []const u8 = switch (msg.arg(0)) {
            .string => |s| s,
            .bytes => |b| b,
            else => "stranger",
        };
        const reply = try std.fmt.allocPrint(turn.arena, "Hello {s}, from a pancake actor!", .{name});
        return .{ .string = reply };
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // 1. Launch the Goblins vat and wait for it to publish its echo cap.
    // Spawn by absolute path: Racket locates its main `collects` relative to its
    // own executable, which a bare PATH-resolved `argv[0]` doesn't give it. The
    // child inherits our environment (`init.environ_map`) so it finds Goblins in
    // `PLTUSERHOME` — `std.process.spawn` carries no ambient env of its own.
    const racket = try resolveRacket(allocator);
    defer allocator.free(racket);

    var child = try std.process.spawn(io, .{
        .argv = &.{ racket, host_script, host, port_str },
        .environ_map = init.environ_map,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var reaped = false;
    defer if (!reaped) child.kill(io); // kill terminates and reaps

    const swiss = readEchoSwiss(io, allocator, &child) catch |err| {
        std.debug.print("goblins-interop: never saw the echo cap readiness line: {s}\n", .{@errorName(err)});
        dumpChildStderr(io, &child);
        return err;
    };
    defer allocator.free(swiss);
    std.debug.print("goblins-interop: goblins published echo swiss={s} on {s}:{s}\n", .{ swiss, host, port_str });

    // 2. Dial the vat and drive the conversation.
    try converse(io, allocator, swiss);

    std.debug.print("goblins-interop: OK (pancake as client) — handshake + bootstrap fetch + echo deliver/resolve with live Goblins\n", .{});

    // Tear the client-scenario vat down before opening the reverse direction.
    child.kill(io);
    reaped = true;

    // Second bracket: Goblins dials *us* and calls a pancake actor over the wire.
    // The Goblins client resolves the cap before calling, so the call is a settled
    // (non-pipelined) deliver.
    try runListenerScenario(init, dialer_script, listen_port, listen_port_str, "settled call");
    std.debug.print("goblins-interop: OK — bidirectional: pancake called Goblins, and Goblins called a pancake actor\n", .{});

    // Third bracket: Goblins enlivens and calls in one breath, so the call arrives
    // as an inbound pipelined deliver against the enliven answer. pancake auto-serves
    // the fetch synchronously, so the answer is already resolved when the pipelined
    // deliver arrives; the engine redirects it to the resolved local export.
    try runListenerScenario(init, pipelined_dialer_script, pipelined_port, pipelined_port_str, "pipelined call");
    std.debug.print("goblins-interop: OK — inbound promise pipelining: goblins enlivened and called a pancake actor in one breath\n", .{});
}

/// The reverse direction: a pancake peer listens, publishes an actor behind a
/// bootstrap swiss-num, and a real Goblins client (`dialer`, dialing `port_num`)
/// enlivens the actor and calls it. We assert Goblins received the actor's reply
/// (it prints `DIAL OK: <reply>`), which proves a Goblins peer can drive a pancake
/// actor end to end. `kind` labels the scenario in the success line — a settled
/// call versus a pipelined one.
fn runListenerScenario(
    init: std.process.Init,
    dialer: []const u8,
    port_num: u16,
    port_text: []const u8,
    kind: []const u8,
) !void {
    const io = init.io;
    const allocator = init.gpa;

    // 1. Bind a TCP listener for Goblins to dial.
    const listen_addr = try tcp.parseHostPort(host, port_num);
    var listener = try tcp.Listener.bind(io, listen_addr);
    defer listener.deinit();

    // 2. A responder peer that publishes a Greeter actor behind the swiss-num.
    //    `registerBootstrapCap` allocates the export the inbound `'fetch` resolves
    //    to; `publish` binds the actor to that same export so the vat dispatches a
    //    deliver to it. (`registerExport` is idempotent, so re-exporting is safe.)
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    // Keep app exports clear of the bootstrap export (0): if the Greeter landed on
    // export 0, an inbound `'fetch` to the bootstrap would be both auto-answered
    // *and* served to the Greeter, whose string reply would clobber the fetch
    // answer's stored reference — breaking a pipelined call that redirects through
    // it. App exports start at 1, exactly as the conformance peer arranges.
    peer.session_state.next_export_id = 1;
    const export_id = try peer.registerBootstrapCap(actor_swiss);

    var vat = actors.Vat.initOver(allocator, &peer);
    defer vat.deinit();
    const greeter = try vat.spawn(Greeter, .{});
    try vat.publish(greeter, export_id);

    // 3. Spawn the Goblins client. It dials our listener, so bind before spawn.
    const racket = try resolveRacket(allocator);
    defer allocator.free(racket);
    var child = try std.process.spawn(io, .{
        .argv = &.{ racket, dialer, port_text, actor_swiss, "world" },
        .environ_map = init.environ_map,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var reaped = false;
    defer if (!reaped) child.kill(io);

    // 4. Accept the inbound connection and weld it to our peer.
    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);
    var conn = listener.accept(&peer, read_buf, write_buf) catch |err| {
        std.debug.print("goblins-interop: accept failed: {s}\n", .{@errorName(err)});
        dumpChildStderr(io, &child);
        return err;
    };
    defer conn.deinit();

    // 5. Keyed op:start-session, signed over a `tcp`/`#f`-hints locator so Goblins
    //    verifies it the same way the client scenario verifies Goblins'.
    const secret = try crypto.SecretKey.fromSeed([_]u8{0x3b} ** crypto.SEED_BYTES);
    const pubkey = secret.publicKey();
    var designator_buf: [64]u8 = undefined;
    const designator = try std.fmt.bufPrint(&designator_buf, "{s}:{s}", .{ host, port_text });
    const my_loc: model.PeerLocator = .{
        .transport = "tcp",
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    };
    const signed = try codec.syrup.canonicalLocationSignedBytes(allocator, my_loc);
    defer allocator.free(signed);
    const sig = crypto.sign(&secret, signed);
    try peer.sendCopying(.{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = pubkey.asBytes() },
        .acceptable_location = my_loc,
        .acceptable_location_sig = .{ .bytes = sig.asBytes() },
    } });

    _ = try conn.runUntil(isOpen);
    std.debug.print("goblins-interop: session open (pancake as listener)\n", .{});

    // 6. Drive: the inbound `'fetch` is auto-served to the actor's export, then
    //    Goblins delivers the call to the actor. `vat.serve` runs the turn and
    //    resolves the answer; we pump until Goblins has the reply and hangs up.
    var served = false;
    while (true) {
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            if (vat.serve(&event) catch false) served = true;
        }
        if (progress == .closed) break;
    }

    if (!served) {
        std.debug.print("goblins-interop: listener never served an actor deliver\n", .{});
        dumpChildStderr(io, &child);
        return error.ActorNeverInvoked;
    }

    // 7. The proof: Goblins printed the actor's reply.
    if (!childStdoutHasDialOk(io, &child)) {
        dumpChildStderr(io, &child);
        return error.GoblinsDidNotReceiveReply;
    }
    child.kill(io);
    reaped = true;
    std.debug.print("goblins-interop: goblins called the pancake greeter ({s}) and received its reply\n", .{kind});
}

/// Read the dialer's stdout and report whether it printed a `DIAL OK` line — the
/// signal that Goblins received and accepted the pancake actor's reply.
fn childStdoutHasDialOk(io: std.Io, child: *std.process.Child) bool {
    const out = child.stdout orelse return false;
    var rbuf: [4096]u8 = undefined;
    var reader = out.readerStreaming(io, &rbuf);
    var scratch: [4096]u8 = undefined;
    var seen: usize = 0;
    while (seen < scratch.len) {
        const n = reader.interface.readSliceShort(scratch[seen..]) catch break;
        if (n == 0) break;
        seen += n;
    }
    const text = scratch[0..seen];
    if (std.mem.indexOf(u8, text, "DIAL OK") != null) {
        std.debug.print("goblins-interop: {s}", .{text});
        return true;
    }
    std.debug.print("goblins-interop: dialer stdout: {s}\n", .{text});
    return false;
}

/// Read the host's NDJSON stdout until the `cap-published` line for the echo cap,
/// returning its swiss-num. Caller owns the returned bytes.
fn readEchoSwiss(io: std.Io, allocator: std.mem.Allocator, child: *std.process.Child) ![]u8 {
    const out = child.stdout orelse return error.NoChildStdout;
    var rbuf: [8192]u8 = undefined;
    var reader = out.readerStreaming(io, &rbuf);
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.GoblinsExitedBeforeReady,
            else => return err,
        };
        if (extractSwiss(line)) |swiss| return allocator.dupe(u8, swiss);
    }
}

/// Resolve `racket` to an absolute path so it can self-locate its `collects`
/// (a bare PATH-resolved `argv[0]` doesn't give it that) — the devcontainer
/// symlink, which is where this gated step's `racket` always lives. Caller owns
/// the slice.
fn resolveRacket(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "/usr/local/bin/racket");
}

/// Best-effort dump of the child's stderr, to surface why Goblins died.
fn dumpChildStderr(io: std.Io, child: *std.process.Child) void {
    const err_file = child.stderr orelse return;
    var buf: [4096]u8 = undefined;
    var reader = err_file.readerStreaming(io, &buf);
    std.debug.print("goblins-interop: --- goblins stderr ---\n", .{});
    var scratch: [1024]u8 = undefined;
    while (true) {
        const n = reader.interface.readSliceShort(&scratch) catch break;
        if (n == 0) break;
        std.debug.print("{s}", .{scratch[0..n]});
    }
    std.debug.print("\n--- end goblins stderr ---\n", .{});
}

/// Pull the value out of a `"swiss":"<value>"` NDJSON line, or null if absent.
fn extractSwiss(line: []const u8) ?[]const u8 {
    const needle = "\"swiss\":\"";
    const start = (std.mem.indexOf(u8, line, needle) orelse return null) + needle.len;
    const rest = line[start..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

fn converse(io: std.Io, allocator: std.mem.Allocator, swiss: []const u8) !void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const dial: model.PeerLocator = .{
        .transport = tcp.transport_name, // "tcp"
        .designator = host ++ ":" ++ port_str,
        .hints = model.Hints.emptyFalse(),
    };
    var conn = try tcp.connect(io, &peer, dial, read_buf, write_buf);
    defer conn.deinit();

    // 1. Keyed op:start-session. Our location is signed with a `tcp`/`#f`-hints
    //    locator so Goblins' verification (which re-encodes `#f`) matches.
    const secret = try crypto.SecretKey.fromSeed([_]u8{0x2a} ** crypto.SEED_BYTES);
    const pubkey = secret.publicKey();
    const my_loc: model.PeerLocator = .{
        .transport = "tcp",
        .designator = host ++ ":1",
        .hints = model.Hints.emptyFalse(),
    };
    const signed = try codec.syrup.canonicalLocationSignedBytes(allocator, my_loc);
    defer allocator.free(signed);
    const sig = crypto.sign(&secret, signed);
    try peer.sendCopying(.{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = pubkey.asBytes() },
        .acceptable_location = my_loc,
        .acceptable_location_sig = .{ .bytes = sig.asBytes() },
    } });

    _ = try conn.runUntil(isOpen);
    try verifyGoblinsStartSession(allocator, &peer);
    std.debug.print("goblins-interop: session open, goblins start-session signature verified\n", .{});

    // 2. Bootstrap-fetch the echo cap by its swiss-num.
    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &peer.session_state, swiss);
    try peer.send(prepared.message);

    var echo_ref: ?model.Reference = null;
    while (echo_ref == null) {
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const owned = try event.decodeOwned(allocator);
            const match = try engine.fetch.tryMatchFetchOutcome(
                allocator,
                prepared.resolver_export,
                prepared.answer_id,
                owned,
            );
            switch (match) {
                .settled => |outcome| switch (outcome) {
                    .fulfilled => |reference| echo_ref = reference, // keep it: we call it next
                    .broken => |reason| {
                        defer allocator.free(reason);
                        std.debug.print("goblins-interop: fetch broke: {s}\n", .{reason});
                        return error.FetchBroke;
                    },
                    .malformed => return error.FetchMalformed,
                },
                .unrelated => |msg| model.freeMessage(allocator, msg),
            }
        }
        if (progress == .closed) break;
    }
    const echo = echo_ref orelse return error.FetchNeverSettled;
    defer model.freeReference(allocator, echo);
    std.debug.print("goblins-interop: fetched goblins echo cap, calling it\n", .{});

    // 3. Call echo("pancake-ping") and assert Goblins resolves it fulfilled. On
    //    V1.0 the runtime attaches a resolver to the answer; Goblins replies by
    //    delivering the resolution to it (it has no op:resolve), which
    //    Event.view() re-projects as a Resolve.
    const echo_answer: u64 = 4242;
    try peer.sendCopying(.{ .deliver = .{
        .target = echo,
        .args = &.{.{ .bytes = "pancake-ping" }},
        .answer = echo_answer,
    } });

    var echoed = false;
    while (!echoed) {
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view() catch continue;
            if (body == .resolve and body.resolve.answer == echo_answer) {
                switch (body.resolve.resolution) {
                    .fulfill => echoed = true,
                    .break_ => |err| {
                        std.debug.print("goblins-interop: echo broke: {s}\n", .{err.message});
                        return error.EchoBroke;
                    },
                }
            }
        }
        if (progress == .closed) break;
    }
    if (!echoed) return error.EchoNeverResolved;
    std.debug.print("goblins-interop: echo call resolved fulfilled by goblins\n", .{});
}

fn isOpen(peer: *engine.Peer) bool {
    return peer.session_state.state == .open;
}

/// Verify the Ed25519 signature Goblins put on its own `op:start-session` over
/// `<my-location <ocapn-peer …>>` — the proof we parsed real Goblins bytes.
fn verifyGoblinsStartSession(allocator: std.mem.Allocator, peer: *engine.Peer) !void {
    var saw = false;
    while (peer.pollEvent()) |event| {
        var e = event;
        defer e.deinit();
        const view = try e.view();
        switch (view) {
            .start_session => |ss| {
                const pubkey = crypto.PeerKey.fromSlice(ss.session_pubkey) catch return error.BadGoblinsKey;
                const sig = switch (ss.acceptable_location_sig) {
                    .halves => |h| crypto.Signature.fromParts(h.r, h.s) catch return error.BadGoblinsSig,
                    .raw => |raw| blk: {
                        if (raw.len != crypto.SIGNATURE_BYTES) return error.BadGoblinsSig;
                        break :blk crypto.Signature.fromBytes(raw[0..crypto.SIGNATURE_BYTES].*);
                    },
                };
                const signed = try codec.syrup.canonicalLocationSignedBytes(allocator, .{
                    .transport = ss.acceptable_location.transport,
                    .designator = ss.acceptable_location.designator,
                    .hints = ss.acceptable_location.hints,
                });
                defer allocator.free(signed);
                crypto.verify(pubkey, signed, sig) catch return error.GoblinsSigInvalid;
                saw = true;
            },
            else => {},
        }
    }
    if (!saw) return error.NoGoblinsStartSession;
}
