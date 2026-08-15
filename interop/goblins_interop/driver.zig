//! Live Goblins interop: a native pancake peer holds a real OCapN conversation
//! with a Spritely Goblins vat over TCP, in *both* directions. The vat build
//! pin is `.devcontainer/pins.sh` `GOBLINS_VERSION` (not runtime-enforced).
//!
//! The client bracket: pancake spawns the conformance Goblins host
//! (`goblins-host.rkt`), reads its NDJSON readiness to learn the listen
//! port and the published echo cap's swiss-num, dials it over `net.tcp`,
//! runs the keyed `op:start-session` handshake (real Ed25519, a `tcp` locator
//! with `#f` hints so the signed bytes match what Goblins re-encodes), verifies
//! Goblins' own signed start-session, then bootstrap-fetches the echo cap and
//! calls it, asserting it resolves fulfilled. The same bracket pipelines the
//! two projection ops Goblins can answer: an `op:index` against the settled
//! echo answer, and an `op:get` against a still-pending answer that settles to
//! a Struct — and asserts Goblins resolves each projection. Finally it enlivens
//! the echo swiss-num through the engine's ADR-0012 dedup-cache API
//! (`prepareEnliven`/`recordEnlivenment`, the surface every binding's `enliven`
//! rides), calls the enlivened cap, and asserts a repeat enliven hits the cache
//! with no wire traffic, which proves enliven against a real Goblins-published cap.
//!
//! The listener bracket: pancake then binds its own TCP listener on an
//! ephemeral port and a real Goblins client dials in. Five scenarios share
//! that bracket: a settled call to a published Greeter actor
//! (`pancake-actor-call.rkt`), a pipelined enliven-and-call in one breath
//! (`goblins-tap-dialer.rkt`), the break path (`pancake-break-call.rkt`),
//! where the client fetches a swiss-num pancake never registered and asserts
//! its vow breaks with pancake's reason, an export-side `op:listen`
//! (`pancake-export-listen.rkt`), where Goblins subscribes on a live pancake
//! object export and hears the settlement, and a projection asker
//! (`pancake-projection-asker.rkt`), where Goblins writes canonical `op:get`
//! and `op:index` at pancake's responders, then observes pancake's
//! resolver-callback fulfillments for those projected answers. Together the
//! brackets prove the
//! bidirectional capability: pancake drives Goblins, and Goblins drives a
//! pancake actor.
//!
//! This is not part of the hermetic `zig build check`: it needs `racket` + the
//! `goblins` collection on PATH, so it runs as the sibling step
//! `zig build goblins-interop`, the way the binding dogfoods need their runtimes.

const std = @import("std");
const pancake = @import("pancake");
const goblins_child = @import("goblins_child.zig");
const harness = @import("interop_harness");

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
const default_port: u16 = 22099;
const frame_cap: usize = 1 << 16;

/// The wait each scenario allows its Goblins child, matching every sibling
/// driver in this directory. Finite is the contract (an unbounded wait is a
/// hang, not a slow test); 60s rather than 20s because these scenarios run
/// inside `check-external` beside other Racket and uv steps, and a child
/// starved of CPU by that concurrency was timing out the projection-asker
/// scenario in the aggregate while passing standalone.
const deadline_ms: u64 = 60_000;

const host_script = "conformance/goblins-peer/racket/goblins-host.rkt";
const dialer_script = "conformance/goblins-peer/racket/pancake-actor-call.rkt";
// The pipelining client: it enlivens and calls in one breath (`<-` to the
// unresolved enliven vow), so the call arrives as an inbound pipelined deliver.
const pipelined_dialer_script = "conformance/goblins-peer/racket/goblins-tap-dialer.rkt";
// The break-path client: it enlivens a swiss-num pancake never registered and
// asserts its vow breaks with pancake's reason, proving Goblins unmarshals
// pancake's V1.0 `['break, reason-symbol]` resolver callback.
const break_dialer_script = "conformance/goblins-peer/racket/pancake-break-call.rkt";
// Goblins-as-asker projection: sends canonical `op:get` / `op:index` against
// pancake's ADR-0050 responders (Goblins 0.18.0 has no app-level send yet).
const projection_asker_script = "conformance/goblins-peer/racket/pancake-projection-asker.rkt";
// Export-side `op:listen`: Goblins `listen` on a settled remote object export.
const export_listen_dialer_script = "conformance/goblins-peer/racket/pancake-export-listen.rkt";

// The swiss-num the pancake actor is published behind in the listener scenarios.
const actor_swiss = "pancakeActorSwissnumABCDEFGH1234";
// Swiss-num for the projection-responder actor (Struct + List replies).
const projection_swiss = "pancakeProjectionSwissnumABCDEF1234";
// The record cap goblins-host.rkt publishes for the op:get leg: calling it
// returns a string-keyed hash (an OCapN Struct). Fixed in the host script —
// like the listener scenarios' actor swiss-num — so the echo readiness line
// stays the first `swiss` line every interop client parses.
const record_swiss = "pancakeRecordSwissnumABCDEF12345";
/// The stateful cap the one-way-deliver leg drives (`goblins-host.rkt`'s
/// `^tally`). A `tell` carries no answer, so proving it arrived means
/// changing something and reading it back.
const tally_swiss = "pancakeTallySwissnumABCDEF123456";
// Deliberately never registered on the pancake side: fetching it makes the
// bootstrap auto-serve break the answer with "unknown swissnum".
const unregistered_swiss = "pancakeUnknownSwissnumZZZZZZ9999";

/// The actor the listener scenarios publish for a live Goblins peer to call.
const Greeter = harness.PositionalReplyActor("Hello {s}, from a pancake actor!");

/// Returns an OCapN Struct or List so inbound `op:get` / `op:index` can project
/// (ADR-0050).
const ProjectionResponder = struct {
    pub fn handle(self: *ProjectionResponder, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        const tag: []const u8 = if (msg.verb.len > 0)
            msg.verb
        else switch (try msg.arg(0)) {
            .string => |s| s,
            .bytes => |b| b,
            .symbol => |s| s,
            else => return error.UnknownMethod,
        };
        const name_index: usize = if (msg.verb.len > 0) 0 else 1;
        if (std.mem.eql(u8, tag, "record")) {
            const name: []const u8 = switch (try msg.arg(name_index)) {
                .string => |s| s,
                .bytes => |b| b,
                else => "anon",
            };
            // A Struct-shaped reply, built on the turn arena (the reply's
            // documented lifetime): Goblins unmarshals it as a hash, so this
            // bracket also proves the pancake-to-Goblins Struct reply live.
            const entries = try turn.arena.alloc(model.StructEntry, 1);
            entries[0] = .{
                .key = try turn.arena.dupe(u8, "name"),
                .value = .{ .string = try std.fmt.allocPrint(turn.arena, "{s}", .{name}) },
            };
            return .{ .@"struct" = entries };
        }
        if (std.mem.eql(u8, tag, "list")) {
            // The slice backing must outlive this call: the vat clones the
            // reply after `handle` returns, so `&.{…}` (a stack temporary)
            // would dangle. The turn arena owns the reply's documented
            // lifetime.
            const items = try turn.arena.alloc(model.Argument, 2);
            items[0] = .{ .string = try turn.arena.dupe(u8, "alpha") };
            items[1] = .{ .string = try turn.arena.dupe(u8, "beta") };
            return .{ .list = items };
        }
        return error.UnknownMethod;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const port = try harness.parsePortFlag(init.minimal.args, "goblins-interop", default_port, .{});
    var port_buf: [8]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{port});

    // 1. Launch the Goblins vat and wait for it to publish its echo cap.
    // The bracket spawns Racket by absolute path (it locates its main
    // `collects` relative to its own executable) and inherits our environment
    // (`init.environ_map`) so it finds Goblins in `PLTUSERHOME`.
    const hosted = try goblins_child.spawnHostAwaitSwiss(io, allocator, init.environ_map, "goblins-interop", "echo cap", &.{ host_script, host, port_str });
    var child = hosted.child;
    var reaped = false;
    defer if (!reaped) child.kill(io); // kill terminates and reaps

    const swiss = hosted.swiss;
    defer allocator.free(swiss);
    std.debug.print("goblins-interop: goblins published echo swiss={s} on {s}:{s}\n", .{ swiss, host, port_str });

    // 2. Dial the vat and drive the conversation.
    converse(io, allocator, swiss, port) catch |err| {
        std.debug.print("goblins-interop: client dial failed: {s}\n", .{@errorName(err)});
        // Dump before kill: the reap closes the pipes, and a silently dropped
        // stderr is the difference between a diagnosis and a mystery.
        goblins_child.dumpChildStderr(io, "goblins-interop", &child);
        child.kill(io);
        reaped = true;
        return err;
    };

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

    // Fifth bracket: export-side `op:listen` — Goblins listens on a live
    // pancake object export and receives immediate fulfill.
    try runListenerScenario(init, .{
        .dialer = export_listen_dialer_script,
        .swiss = actor_swiss,
        .success_needle = "LISTEN OK",
        .serves_actor = true,
        .kind = "export listen",
        .actor = .greeter,
    });
    std.debug.print("goblins-interop: OK — export-side op:listen: goblins listened on a live pancake export\n", .{});

    // Sixth bracket: Goblins-as-asker sends canonical `op:get` / `op:index`
    // frames through its own netlayer against pancake's ADR-0050 responders.
    // The pinned Goblins release has inbound projection support but no public
    // outbound app API for those ops, so the Racket asker uses Goblins'
    // canonical records and test-only netlayer writer, then observes pancake's
    // V1.0 resolver-callback settlements on the live Goblins TCP netlayer.
    try runListenerScenario(init, .{
        .dialer = projection_asker_script,
        .swiss = projection_swiss,
        .success_needle = "PROJECTION OK",
        .serves_actor = true,
        .kind = "projection asker",
        .actor = .projection,
        // `PROJECTION OK` now means the Goblins-side probe observed fulfill
        // resolver callbacks for both projection answer positions, with the
        // expected payloads. The kind latches stay as a guard that the
        // canonical projection frames themselves reached pancake.
        .expect_inbound_ops = &.{ .get, .index },
    });
    std.debug.print("goblins-interop: OK, pancake accepted canonical op:get/op:index frames a Goblins netlayer wrote\n", .{});
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
    /// Whether pancake publishes and serves an actor behind `swiss`. The break
    /// scenario leaves this false: the client fetches an unregistered swiss-num,
    /// and the engine auto-breaks the fetch with no vat turn involved.
    serves_actor: bool,
    /// Labels the scenario in the success line.
    kind: []const u8,
    /// Which actor type to publish when `serves_actor` is true.
    actor: enum { greeter, projection } = .greeter,
    /// Inbound frame kinds this run must see arrive — the arrival proof for
    /// frames the client writes fire-and-forget (the projection asker's
    /// `op:get` / `op:index`), whose success needle says only that the client
    /// was satisfied, not that the frames reached this peer.
    ///
    /// Kinds and not answer positions. A position is a name in the PARTNER's
    /// namespace: Goblins mints them from its own counter, and a released
    /// position is legally reused. Pinning one here made this bracket assert a
    /// number neither side owns, which held only while the partner's send
    /// order held, and broke under the load that reorders it.
    expect_inbound_ops: []const engine.EventKind = &.{},
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
    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();
    const peer = &scaffold.peer;
    // Session init already reserves export 0 for the bootstrap; app exports
    // mint from 1 through the session's one allocator, so the Greeter can
    // never land on the bootstrap position.

    var vat: ?actors.Vat = null;
    defer if (vat) |*v| v.deinit();
    var port: ?actors.Port = null;
    defer if (port) |*p| p.deinit(&vat.?);
    if (scenario.serves_actor) {
        const export_position = try peer.registerBootstrapCap(scenario.swiss);
        vat = actors.Vat.init(allocator);
        port = actors.Port.init(allocator, peer);
        switch (scenario.actor) {
            .greeter => {
                const greeter = try vat.?.spawn(Greeter, .{});
                try port.?.bindExport(&vat.?, greeter, export_position);
            },
            .projection => {
                const provider = try vat.?.spawn(ProjectionResponder, .{});
                try port.?.bindExport(&vat.?, provider, export_position);
            },
        }
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

    // 4. Accept the inbound connection and weld it to our peer. The wait is
    //    deadline-guarded: a dialer that dies before dialing must fail loud
    //    with its stderr, not park the driver in a bare kernel accept.
    harness.untilAcceptable(io, deadline_ms, &listener) catch |err| {
        std.debug.print("goblins-interop: dialer never connected ({s} scenario): {s}\n", .{ scenario.kind, @errorName(err) });
        goblins_child.dumpChildStderr(io, "goblins-interop", &child);
        return err;
    };
    var conn = listener.accept(peer, scaffold.read_buf, scaffold.write_buf, .{}) catch |err| {
        std.debug.print("goblins-interop: accept failed ({s} scenario): {s}\n", .{ scenario.kind, @errorName(err) });
        goblins_child.dumpChildStderr(io, "goblins-interop", &child);
        return err;
    };
    defer conn.deinit();

    // 5. Keyed op:start-session, signed over a `tcp`/`#f`-hints locator so Goblins
    //    verifies it the same way the client scenario verifies Goblins'.
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const port_num = try std.fmt.parseInt(u16, port_text, 10);
    const designator_addr = try tcp.parseHostPort(host, port_num);
    const designator = tcp.locatorFromAddress(&designator_buf, designator_addr).designator;
    _ = try goblins_child.openKeyedSession(io, peer, &conn, designator);
    std.debug.print("goblins-interop: session open (pancake as listener, {s})\n", .{scenario.kind});

    // 6. Drive until Goblins has what it came for and hangs up. Some scenarios
    //    exit before the TCP session closes; a wall-clock cap prevents wedging.
    var served = false;
    // Arrival is latched off the frame that mints it, never read out of the
    // session's answer table: a partner that has resolved its question may
    // legally release the row with `op:gc-answers` before it hangs up, and
    // Goblins does. One `pump` consumes every byte that has arrived, so the
    // deliver and the release are both applied before the loop could look, and
    // under load they routinely land together. `latchInboundAnswer` reads the
    // position off the deliver itself, which is the one place it is still
    // visible.
    var seen_ops = [_]bool{false} ** 8;
    std.debug.assert(scenario.expect_inbound_ops.len <= seen_ops.len);
    const pump_deadline = harness.deadlineAfter(io, deadline_ms);
    while (true) {
        if (harness.expired(io, pump_deadline)) break;
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            for (scenario.expect_inbound_ops, 0..) |kind, i| {
                if (event.tag == kind) seen_ops[i] = true;
            }
            if (vat) |*v| {
                if (port.?.serve(v, &event) catch false) served = true;
            }
        }
        if (progress == .closed) break;
    }

    if (harness.expired(io, pump_deadline)) {
        child.kill(io);
        reaped = true;
    }

    var child_out: [4096]u8 = undefined;
    const child_out_len = goblins_child.drainChildStdout(io, &child, &child_out);
    const stdout_text = child_out[0..child_out_len];

    if (scenario.serves_actor and !served and
        std.mem.indexOf(u8, stdout_text, scenario.success_needle) == null)
    {
        std.debug.print("goblins-interop: listener never served an actor deliver\n", .{});
        goblins_child.dumpChildStderr(io, "goblins-interop", &child);
        return error.ActorNeverInvoked;
    }

    // 7. The proof: Goblins printed the scenario's success line.
    if (std.mem.indexOf(u8, stdout_text, scenario.success_needle) == null) {
        if (harness.expired(io, pump_deadline)) {
            std.debug.print("goblins-interop: listener pump timed out ({s})\n", .{scenario.kind});
        }
        goblins_child.dumpChildStderr(io, "goblins-interop", &child);
        std.debug.print("goblins-interop: dialer stdout: {s}\n", .{stdout_text});
        return error.GoblinsScenarioFailed;
    }

    // 8. Arrival proof for frames the client's needle does not imply: every
    //    expected partner-minted answer position must have landed in the
    //    session's inbound answer table, or the "accepted the frames" claim
    //    rode a teardown race instead of the wire.
    for (scenario.expect_inbound_ops, 0..) |kind, i| {
        if (!seen_ops[i]) {
            std.debug.print(
                "goblins-interop: expected inbound {s} never arrived ({s} scenario)\n",
                .{ @tagName(kind), scenario.kind },
            );
            goblins_child.dumpChildStderr(io, "goblins-interop", &child);
            return error.ExpectedAnswerNeverArrived;
        }
    }
    std.debug.print("goblins-interop: {s}", .{stdout_text});
    child.kill(io);
    reaped = true;
    std.debug.print("goblins-interop: goblins drove the pancake listener ({s}) and printed `{s}`\n", .{ scenario.kind, scenario.success_needle });
}

fn converse(io: std.Io, allocator: std.mem.Allocator, swiss: []const u8, port: u16) !void {
    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();
    const peer = &scaffold.peer;

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const designator_addr = try tcp.parseHostPort(host, port);
    const dial = tcp.locatorFromAddress(&designator_buf, designator_addr);
    // Retry a refused dial briefly: the vat's readiness line can race its
    // listener's actual bind.
    var conn = try harness.tcpConnectRetry(io, peer, dial, scaffold.read_buf, scaffold.write_buf, 5_000);
    defer conn.deinit();

    // 1. Keyed op:start-session. Our location is signed with a `tcp`/`#f`-hints
    //    locator so Goblins' verification (which re-encodes `#f`) matches.
    _ = try goblins_child.openKeyedSession(io, peer, &conn, dial.designator);
    try verifyGoblinsStartSession(allocator, peer);
    std.debug.print("goblins-interop: session open, goblins start-session signature verified\n", .{});

    // 2. Bootstrap-fetch the echo cap by its swiss-num.
    const echo = try goblins_child.fetchCap(allocator, peer, &conn, swiss);
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
        .answer = model.AnswerPosition.from(echo_answer),
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
        .receiver = .{ .promise = .{ .answer_position = model.AnswerPosition.from(echo_answer) } },
        .index = .{ .integer = 0 },
        .answer = model.AnswerPosition.from(index_answer),
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
    const record = try goblins_child.fetchCap(allocator, peer, &conn, record_swiss);
    defer model.freeReference(allocator, record);
    std.debug.print("goblins-interop: fetched goblins record cap, pipelining op:get against its answer\n", .{});

    const record_answer: u64 = 4444;
    try peer.sendCopying(.{ .deliver = .{
        .target = record,
        .args = &.{.{ .string = "pancake-get" }},
        .answer = model.AnswerPosition.from(record_answer),
    } });
    const get_answer: u64 = 4545;
    try peer.sendCopying(.{ .get = .{
        .receiver = .{ .promise = .{ .answer_position = model.AnswerPosition.from(record_answer) } },
        .field = "name",
        .answer = model.AnswerPosition.from(get_answer),
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

    // 6. One-way deliver (`tell`): the frame pancake sends for a
    //    fire-and-forget send is an `op:deliver` with no answer and no
    //    resolver, which is what the pinned draft folds one-way delivery
    //    into. Nothing comes back by construction, so the proof is a state
    //    change: bump the tally twice with no answer, then call `read` with
    //    one and assert live Goblins counted both.
    const tally = try goblins_child.fetchCap(allocator, peer, &conn, tally_swiss);
    defer model.freeReference(allocator, tally);
    std.debug.print("goblins-interop: fetched goblins tally cap, sending two one-way delivers\n", .{});

    try peer.sendCopying(.{ .deliver = .{
        .target = tally,
        .args = &.{.{ .symbol = "bump" }},
        .answer = null,
    } });
    try peer.sendCopying(.{ .deliver = .{
        .target = tally,
        .args = &.{.{ .symbol = "bump" }},
        .answer = null,
    } });

    // Distinct from every other answer this conversation opens: the driver
    // numbers them by hand, so a reused position is a collision, not a reuse.
    const tally_answer: u64 = 4747;
    try peer.sendCopying(.{ .deliver = .{
        .target = tally,
        .args = &.{.{ .symbol = "read" }},
        .answer = model.AnswerPosition.from(tally_answer),
    } });

    var tallied = false;
    while (!tallied) {
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view() catch continue;
            if (body == .resolve and body.resolve.answer.int() == tally_answer) {
                switch (body.resolve.resolution) {
                    .fulfill => |payload| {
                        const count = switch (payload) {
                            .integer => |n| n,
                            else => return error.TallyWrongPayload,
                        };
                        // Both one-way delivers landed, in order, ahead of the
                        // answered call that read them.
                        if (count != 2) {
                            std.debug.print("goblins-interop: tally read {d}, wanted 2\n", .{count});
                            return error.TallyWrongCount;
                        }
                        tallied = true;
                    },
                    .@"break" => |err| {
                        std.debug.print("goblins-interop: tally read broke: {s}\n", .{err.message});
                        return error.TallyBroke;
                    },
                }
            }
        }
        if (progress == .closed) break;
    }
    if (!tallied) return error.TallyNeverResolved;
    std.debug.print("goblins-interop: two one-way delivers counted by live goblins\n", .{});

    // 7. Enliven the echo cap by its swiss-num through the engine's ADR-0012
    //    dedup-cache API (the same surface every binding's `enliven` rides), not a
    //    bare bootstrap fetch. The first enliven runs a real bootstrap-fetch to
    //    Goblins and caches the resolved far reference; calling the enlivened cap
    //    proves it is live. A second enliven for the same swiss-num then short-
    //    circuits on the cache with no wire traffic, returning the same import.
    const enlivened = try goblins_child.enlivenCap(allocator, peer, &conn, swiss);
    defer model.freeReference(allocator, enlivened);
    std.debug.print("goblins-interop: enlivened goblins echo cap via the dedup-cache API, calling it\n", .{});

    const enliven_answer: u64 = 4646;
    try peer.sendCopying(.{ .deliver = .{
        .target = enlivened,
        .args = &.{.{ .bytes = "pancake-enliven" }},
        .answer = model.AnswerPosition.from(enliven_answer),
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
    const repeat = try engine.sturdyref.prepareEnliven(allocator, &peer.session_state, swiss);
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
                const loc = try ss.acceptable_location.toOwned(allocator);
                defer model.freePeerLocator(allocator, loc);
                const signed = try codec.syrup.canonicalLocationSignedBytes(allocator, loc);
                defer allocator.free(signed);
                crypto.verify(pubkey, signed, sig) catch return error.GoblinsSigInvalid;
                saw = true;
            },
            else => {},
        }
    }
    if (!saw) return error.NoGoblinsStartSession;
}
