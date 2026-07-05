//! Live interop proof: a native pancake peer holds a real OCapN conversation
//! with a Spritely Goblins v0.18.0 vat over TCP, in *both* directions.
//!
//! The client bracket: pancake spawns the conformance Goblins host
//! (`goblins-host.rkt`), reads its NDJSON readiness to learn the listen
//! port and the published echo cap's swiss-num, dials it over `net.tcp`,
//! runs the keyed `op:start-session` handshake (real Ed25519, a `tcp` locator
//! with `#f` hints so the signed bytes match what Goblins re-encodes), verifies
//! Goblins' own signed start-session, then bootstrap-fetches the echo cap and
//! calls it, asserting it resolves fulfilled. The same bracket pipelines the
//! two projection ops Goblins can answer — an `op:index` against the settled
//! echo answer, and an `op:get` against a still-pending answer that settles to
//! a Struct — and asserts Goblins resolves each projection. Finally it enlivens
//! the echo swiss-num through the engine's ADR-0012 dedup-cache API
//! (`prepareEnliven`/`recordEnlivenment`, the surface every binding's `enliven`
//! rides), calls the enlivened cap, and asserts a repeat enliven hits the cache
//! with no wire traffic — proving enliven against a real Goblins-published cap.
//!
//! The listener bracket: pancake then binds its own TCP listener on an
//! ephemeral port and a real Goblins client dials in. Three scenarios share
//! that bracket: a settled call to a published Greeter actor
//! (`pancake-actor-call.rkt`), a pipelined enliven-and-call in one breath
//! (`goblins-tap-dialer.rkt`), and the break path (`pancake-break-call.rkt`),
//! where the client fetches a swiss-num pancake never registered and asserts
//! its vow breaks with pancake's reason. Together the brackets prove the
//! bidirectional capability — pancake drives Goblins, and Goblins drives a
//! pancake actor.
//!
//! This is not part of the hermetic `zig build check`: it needs `racket` + the
//! `goblins` collection on PATH, so it runs as the sibling step
//! `zig build goblins-interop`, the way the binding dogfoods need their runtimes.

const std = @import("std");
const pancake = @import("pancake");
const goblins_child = @import("goblins_child.zig");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const codec = pancake.ocapn.codec;
const actors = pancake.actors;
const crypto = pancake.foundation.crypto;
const tcp = pancake.net.tcp;

const host = "127.0.0.1";
/// The Goblins host's listening port in the dial direction. `--port=N` (from
/// `zig build goblins-interop -Dport=N`) overrides it when 22099 is taken; the
/// listener scenarios bind ephemeral ports and need no override.
const default_port_str = "22099";
const frame_cap: usize = 1 << 16;

const host_script = "conformance/goblins-peer/racket/goblins-host.rkt";
const dialer_script = "conformance/goblins-peer/racket/pancake-actor-call.rkt";
// The pipelining client: it enlivens and calls in one breath (`<-` to the
// unresolved enliven vow), so the call arrives as an inbound pipelined deliver.
const pipelined_dialer_script = "conformance/goblins-peer/racket/goblins-tap-dialer.rkt";
// The break-path client: it enlivens a swiss-num pancake never registered and
// asserts its vow breaks with pancake's reason, proving Goblins unmarshals
// pancake's V1.0 `['break, reason-symbol]` resolver callback.
const break_dialer_script = "conformance/goblins-peer/racket/pancake-break-call.rkt";

// The swiss-num the pancake actor is published behind in the listener scenarios.
const actor_swiss = "pancakeActorSwissnumABCDEFGH1234";
// The record cap goblins-host.rkt publishes for the op:get leg: calling it
// returns a string-keyed hash (an OCapN Struct). Fixed in the host script —
// like the listener scenarios' actor swiss-num — so the echo readiness line
// stays the first `swiss` line every interop client parses.
const record_swiss = "pancakeRecordSwissnumABCDEF12345";
// Deliberately never registered on the pancake side: fetching it makes the
// bootstrap auto-serve break the answer with "unknown swissnum".
const unregistered_swiss = "pancakeUnknownSwissnumZZZZZZ9999";

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

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program name
    var port_str: []const u8 = default_port_str;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            port_str = arg["--port=".len..];
            _ = std.fmt.parseInt(u16, port_str, 10) catch {
                std.debug.print("goblins-interop: --port must be an integer in 1..65535\n", .{});
                return error.BadPort;
            };
        } else {
            std.debug.print("goblins-interop: unknown argument '{s}'\n", .{arg});
            return error.BadArgument;
        }
    }

    // 1. Launch the Goblins vat and wait for it to publish its echo cap.
    // Spawn by absolute path: Racket locates its main `collects` relative to its
    // own executable, which a bare PATH-resolved `argv[0]` doesn't give it. The
    // child inherits our environment (`init.environ_map`) so it finds Goblins in
    // `PLTUSERHOME` — `std.process.spawn` carries no ambient env of its own.
    var child = try std.process.spawn(io, .{
        .argv = &.{ goblins_child.racket_path, host_script, host, port_str },
        .environ_map = init.environ_map,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var reaped = false;
    defer if (!reaped) child.kill(io); // kill terminates and reaps

    const swiss = goblins_child.readPublishedSwiss(io, allocator, &child) catch |err| {
        std.debug.print("goblins-interop: never saw the echo cap readiness line: {s}\n", .{@errorName(err)});
        goblins_child.dumpChildStderr(io, "goblins-interop", &child);
        return err;
    };
    defer allocator.free(swiss);
    std.debug.print("goblins-interop: goblins published echo swiss={s} on {s}:{s}\n", .{ swiss, host, port_str });

    // 2. Dial the vat and drive the conversation.
    try converse(io, allocator, swiss, port_str);

    std.debug.print("goblins-interop: OK (pancake as client), handshake + bootstrap fetch + echo deliver/resolve with live Goblins\n", .{});

    // Tear the client-scenario vat down before opening the reverse direction.
    child.kill(io);
    reaped = true;

    // Second bracket: Goblins dials *us* and calls a pancake actor over the wire.
    // The Goblins client resolves the cap before calling, so the call is a settled
    // (non-pipelined) deliver.
    try runListenerScenario(init, .{
        .dialer = dialer_script,
        .swiss = actor_swiss,
        .call_arg = "world",
        .success_needle = "DIAL OK",
        .serves_actor = true,
        .kind = "settled call",
    });
    std.debug.print("goblins-interop: OK, bidirectional: pancake called Goblins, and Goblins called a pancake actor\n", .{});

    // Third bracket: Goblins enlivens and calls in one breath, so the call arrives
    // as an inbound pipelined deliver against the enliven answer. pancake auto-serves
    // the fetch synchronously, so the answer is already resolved when the pipelined
    // deliver arrives; the engine redirects it to the resolved local export.
    try runListenerScenario(init, .{
        .dialer = pipelined_dialer_script,
        .swiss = actor_swiss,
        .call_arg = "world",
        .success_needle = "DIAL OK",
        .serves_actor = true,
        .kind = "pipelined call",
    });
    std.debug.print("goblins-interop: OK, inbound promise pipelining: goblins enlivened and called a pancake actor in one breath\n", .{});

    // Fourth bracket: the break path. Goblins enlivens a swiss-num pancake never
    // registered; pancake breaks the fetch answer, which on the V1.0 wire is a
    // resolver-callback deliver carrying `['break, reason-symbol]`. The client
    // asserts its vow broke *with pancake's reason* — an `<error …>` record here
    // would instead die in Goblins' unmarshaller (`captp-unknown-record-rag`)
    // and surface as a timeout or severed-session error. The fetch is auto-served
    // by the engine with no vat turn, so the bracket publishes nothing.
    try runListenerScenario(init, .{
        .dialer = break_dialer_script,
        .swiss = unregistered_swiss,
        .success_needle = "BREAK OK",
        .serves_actor = false,
        .kind = "break path",
    });
    std.debug.print("goblins-interop: OK — break path: goblins observed pancake's broken vow with its reason\n", .{});
}

/// One Goblins-dials-pancake scenario over the shared listener bracket.
const ListenerScenario = struct {
    /// The Racket client script that dials our listener.
    dialer: []const u8,
    /// The swiss-num the client fetches.
    swiss: []const u8,
    /// An extra trailing argv for the dialer (the greeting name), or null when
    /// the dialer takes only port and swiss-num.
    call_arg: ?[]const u8 = null,
    /// The stdout line that proves the scenario from the Goblins side.
    success_needle: []const u8,
    /// Whether pancake publishes and serves the Greeter actor behind
    /// `actor_swiss`. The break scenario leaves this false: the client fetches
    /// an unregistered swiss-num, and the engine auto-breaks the fetch with no
    /// vat turn involved.
    serves_actor: bool,
    /// Labels the scenario in the success line.
    kind: []const u8,
};

/// The reverse direction: a pancake peer listens on an ephemeral port, and a
/// real Goblins client (`scenario.dialer`) dials in and drives the scenario.
/// We assert the client printed `scenario.success_needle` — Goblins' own
/// confirmation that it received the actor's reply, or observed the broken vow.
fn runListenerScenario(init: std.process.Init, scenario: ListenerScenario) !void {
    const io = init.io;
    const allocator = init.gpa;

    // 1. Bind a TCP listener on an ephemeral port for Goblins to dial; the
    //    resolved port is read back and handed to the dialer's argv.
    const listen_addr = try tcp.parseHostPort(host, 0);
    var listener = try tcp.Listener.bind(io, listen_addr);
    defer listener.deinit();
    var port_buf: [8]u8 = undefined;
    const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{listener.localAddress().getPort()});

    // 2. A responder peer; the call scenarios publish a Greeter actor behind the
    //    swiss-num. `registerBootstrapCap` allocates the export the inbound
    //    `'fetch` resolves to; `bindExport` binds the actor to that same export
    //    so the vat dispatches a deliver to it.
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    // Keep app exports clear of the bootstrap export (0): if the Greeter landed on
    // export 0, an inbound `'fetch` to the bootstrap would be both auto-answered
    // *and* served to the Greeter, whose string reply would clobber the fetch
    // answer's stored reference, breaking a pipelined call that redirects through
    // it. App exports start at 1, exactly as the conformance peer arranges.
    peer.session_state.next_export_position = 1;

    var vat: ?actors.Vat = null;
    defer if (vat) |*v| v.deinit();
    if (scenario.serves_actor) {
        const export_position = try peer.registerBootstrapCap(actor_swiss);
        vat = actors.Vat.initOver(allocator, &peer);
        const greeter = try vat.?.spawn(Greeter, .{});
        try vat.?.bindExport(greeter, export_position);
    }

    // 3. Spawn the Goblins client. It dials our listener, so bind before spawn.
    var argv_buf: [5][]const u8 = .{ goblins_child.racket_path, scenario.dialer, port_text, scenario.swiss, "" };
    var argv_len: usize = 4;
    if (scenario.call_arg) |arg| {
        argv_buf[4] = arg;
        argv_len = 5;
    }
    var child = try std.process.spawn(io, .{
        .argv = argv_buf[0..argv_len],
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
        std.debug.print("goblins-interop: accept failed ({s} scenario): {s}\n", .{ scenario.kind, @errorName(err) });
        goblins_child.dumpChildStderr(io, "goblins-interop", &child);
        return err;
    };
    defer conn.deinit();

    // 5. Keyed op:start-session, signed over a `tcp`/`#f`-hints locator so Goblins
    //    verifies it the same way the client scenario verifies Goblins'.
    var designator_buf: [64]u8 = undefined;
    const designator = try std.fmt.bufPrint(&designator_buf, "{s}:{s}", .{ host, port_text });
    _ = try goblins_child.openKeyedSession(io, &peer, &conn, designator);
    std.debug.print("goblins-interop: session open (pancake as listener, {s})\n", .{scenario.kind});

    // 6. Drive until Goblins has what it came for and hangs up. In the call
    //    scenarios the inbound `'fetch` is auto-served to the actor's export and
    //    `vat.serve` runs the turn that resolves the answer; in the break
    //    scenario the engine auto-breaks the fetch, so events only need draining.
    var served = false;
    while (true) {
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            if (vat) |*v| {
                if (v.serve(&event) catch false) served = true;
            }
        }
        if (progress == .closed) break;
    }

    if (scenario.serves_actor and !served) {
        std.debug.print("goblins-interop: listener never served an actor deliver\n", .{});
        goblins_child.dumpChildStderr(io, "goblins-interop", &child);
        return error.ActorNeverInvoked;
    }

    // 7. The proof: Goblins printed the scenario's success line.
    if (!childStdoutHas(io, &child, scenario.success_needle)) {
        goblins_child.dumpChildStderr(io, "goblins-interop", &child);
        return error.GoblinsScenarioFailed;
    }
    child.kill(io);
    reaped = true;
    std.debug.print("goblins-interop: goblins drove the pancake listener ({s}) and printed `{s}`\n", .{ scenario.kind, scenario.success_needle });
}

/// Read the dialer's stdout and report whether it printed `needle` — each
/// scenario's success line.
fn childStdoutHas(io: std.Io, child: *std.process.Child, needle: []const u8) bool {
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
    if (std.mem.indexOf(u8, text, needle) != null) {
        std.debug.print("goblins-interop: {s}", .{text});
        return true;
    }
    std.debug.print("goblins-interop: dialer stdout: {s}\n", .{text});
    return false;
}

fn converse(io: std.Io, allocator: std.mem.Allocator, swiss: []const u8, port_str: []const u8) !void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var designator_buf: [64]u8 = undefined;
    const designator = try std.fmt.bufPrint(&designator_buf, "{s}:{s}", .{ host, port_str });
    const dial: model.PeerLocator = .{
        .transport = tcp.transport_name, // "tcp"
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    };
    var conn = try tcp.connect(io, &peer, dial, read_buf, write_buf);
    defer conn.deinit();

    // 1. Keyed op:start-session. Our location is signed with a `tcp`/`#f`-hints
    //    locator so Goblins' verification (which re-encodes `#f`) matches.
    _ = try goblins_child.openKeyedSession(io, &peer, &conn, host ++ ":1");
    try verifyGoblinsStartSession(allocator, &peer);
    std.debug.print("goblins-interop: session open, goblins start-session signature verified\n", .{});

    // 2. Bootstrap-fetch the echo cap by its swiss-num.
    const echo = try goblins_child.fetchCap(allocator, &peer, &conn, swiss);
    defer model.freeReference(allocator, echo);
    std.debug.print("goblins-interop: fetched goblins echo cap, calling it\n", .{});

    // 3. Call echo("pancake-ping") and assert Goblins resolves it fulfilled. On
    //    V1.0 the runtime attaches a resolver to the answer; Goblins replies by
    //    delivering the resolution to it (it has no op:resolve), which
    //    Event.view() re-projects as a Resolve.
    const echo_answer: u64 = 4242;
    // The second argument is 2^100: Goblins materializes it as a Racket bignum
    // and marshals it back, so the round-trip proves the arbitrary-precision
    // Integer (ADR-0049) against live Goblins in both directions.
    const big_digits = "1267650600228229401496703205376";
    try peer.sendCopying(.{ .deliver = .{
        .target = echo,
        .args = &.{
            .{ .bytes = "pancake-ping" },
            .{ .big_integer = .{ .negative = true, .digits = big_digits } },
        },
        .answer = model.AnswerId.from(echo_answer),
    } });

    var echoed = false;
    while (!echoed) {
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view() catch continue;
            if (body == .resolve and body.resolve.answer.int() == echo_answer) {
                switch (body.resolve.resolution) {
                    // The echo actor is `(lambda args args)`: it returns its
                    // argument list. Assert the content survived the
                    // round-trip, not merely that something resolved.
                    .fulfill => |payload| {
                        if (payload != .list) return error.EchoWrongPayload;
                        if ((try payload.list.len()) != 2) return error.EchoWrongPayload;
                        const text: []const u8 = switch (try payload.list.at(0)) {
                            .bytes, .string => |t| t,
                            else => return error.EchoWrongPayload,
                        };
                        if (!std.mem.eql(u8, text, "pancake-ping")) {
                            return error.EchoWrongPayload;
                        }
                        const big = switch (try payload.list.at(1)) {
                            .big_integer => |b| b,
                            else => return error.EchoWrongPayload,
                        };
                        if (!big.negative or !std.mem.eql(u8, big.digits, big_digits)) {
                            return error.EchoWrongPayload;
                        }
                        echoed = true;
                    },
                    .@"break" => |err| {
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

    // 4. Pipeline an op:index against the settled echo answer (ADR-0050,
    //    pancake as the asker): Goblins exports a promise at the new answer
    //    position and resolves it to element 0 of the echoed list. V1.0 has no
    //    op:resolve push, so the engine auto-installs a listener on the
    //    projected answer (`engine.v1_0.installListenerForOutboundProjection`);
    //    Goblins fires it and the projected resolution surfaces back here as an
    //    ordinary resolve event, exactly as the bindings see it.
    const index_answer: u64 = 4343;
    try peer.sendCopying(.{ .index = .{
        .receiver = .{ .promise = .{ .answer_position = model.AnswerId.from(echo_answer) } },
        .index = 0,
        .answer = model.AnswerId.from(index_answer),
    } });

    var projected = false;
    while (!projected) {
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view() catch continue;
            if (body == .resolve and body.resolve.answer.int() == index_answer) {
                switch (body.resolve.resolution) {
                    .fulfill => |payload| {
                        const text: []const u8 = switch (payload) {
                            .bytes, .string => |t| t,
                            else => return error.ProjectionWrongPayload,
                        };
                        if (!std.mem.eql(u8, text, "pancake-ping")) return error.ProjectionWrongPayload;
                        projected = true;
                    },
                    .@"break" => return error.ProjectionBroke,
                }
            }
        }
        if (progress == .closed) break;
    }
    if (!projected) return error.ProjectionNeverResolved;
    std.debug.print("goblins-interop: op:index pipelined against the echo answer; goblins resolved the projected element\n", .{});

    // 5. Pipeline an op:get (ADR-0050, pancake as the asker), the same way:
    //    fetch the record cap — calling it returns a string-keyed hash, the
    //    OCapN Struct — and project the "name" field out of the call's answer.
    //    The op:get is sent *before* the call settles, so Goblins anchors its
    //    `hash-ref` vow on a still-pending answer; the engine's auto-installed
    //    listener carries the projected field back as a resolve event.
    const record = try goblins_child.fetchCap(allocator, &peer, &conn, record_swiss);
    defer model.freeReference(allocator, record);
    std.debug.print("goblins-interop: fetched goblins record cap, pipelining op:get against its answer\n", .{});

    const record_answer: u64 = 4444;
    try peer.sendCopying(.{ .deliver = .{
        .target = record,
        .args = &.{.{ .string = "pancake-get" }},
        .answer = model.AnswerId.from(record_answer),
    } });
    const get_answer: u64 = 4545;
    try peer.sendCopying(.{ .get = .{
        .receiver = .{ .promise = .{ .answer_position = model.AnswerId.from(record_answer) } },
        .field = "name",
        .answer = model.AnswerId.from(get_answer),
    } });

    var got = false;
    while (!got) {
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view() catch continue;
            if (body == .resolve and body.resolve.answer.int() == get_answer) {
                switch (body.resolve.resolution) {
                    .fulfill => |payload| {
                        const text: []const u8 = switch (payload) {
                            .bytes, .string => |t| t,
                            else => return error.GetProjectionWrongPayload,
                        };
                        if (!std.mem.eql(u8, text, "pancake-get")) return error.GetProjectionWrongPayload;
                        got = true;
                    },
                    .@"break" => return error.GetProjectionBroke,
                }
            }
        }
        if (progress == .closed) break;
    }
    if (!got) return error.GetProjectionNeverResolved;
    std.debug.print("goblins-interop: op:get pipelined against the pending record answer; goblins resolved the projected field\n", .{});

    // 6. Enliven the echo cap by its swiss-num through the engine's ADR-0012
    //    dedup-cache API (the same surface every binding's `enliven` rides), not a
    //    bare bootstrap fetch. The first enliven runs a real bootstrap-fetch to
    //    Goblins and caches the resolved far reference; calling the enlivened cap
    //    proves it is live. A second enliven for the same swiss-num then short-
    //    circuits on the cache with no wire traffic, returning the same import.
    const enlivened = try goblins_child.enlivenCap(allocator, &peer, &conn, swiss);
    defer model.freeReference(allocator, enlivened);
    std.debug.print("goblins-interop: enlivened goblins echo cap via the dedup-cache API, calling it\n", .{});

    const enliven_answer: u64 = 4646;
    try peer.sendCopying(.{ .deliver = .{
        .target = enlivened,
        .args = &.{.{ .bytes = "pancake-enliven" }},
        .answer = model.AnswerId.from(enliven_answer),
    } });
    var enliven_echoed = false;
    while (!enliven_echoed) {
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view() catch continue;
            if (body == .resolve and body.resolve.answer.int() == enliven_answer) {
                switch (body.resolve.resolution) {
                    .fulfill => |payload| {
                        if (payload != .list or (try payload.list.len()) != 1) return error.EnlivenWrongPayload;
                        const text: []const u8 = switch (try payload.list.at(0)) {
                            .bytes, .string => |t| t,
                            else => return error.EnlivenWrongPayload,
                        };
                        if (!std.mem.eql(u8, text, "pancake-enliven")) return error.EnlivenWrongPayload;
                        enliven_echoed = true;
                    },
                    .@"break" => return error.EnlivenBroke,
                }
            }
        }
        if (progress == .closed) break;
    }
    if (!enliven_echoed) return error.EnlivenNeverResolved;

    // The repeat enliven must hit the cache: same import position, no wire traffic.
    const repeat = try engine.sturdyref.prepareEnliven(allocator, &peer.session_state, .{
        .peer = .{ .transport = tcp.transport_name, .designator = designator, .hints = model.Hints.emptyFalse() },
        .swissnum = swiss,
    });
    switch (repeat) {
        .cached => |reference| {
            if (reference != .far or enlivened != .far or
                reference.far.import_position != enlivened.far.import_position)
                return error.EnlivenCacheMismatch;
        },
        .in_flight, .fresh => return error.EnlivenCacheMissed,
    }
    std.debug.print("goblins-interop: enliven dedup cache hit on repeat, same import, no wire traffic\n", .{});
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
