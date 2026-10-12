//! Live Goblins interop: a native glowcap peer holds a real OCapN conversation
//! with a Spritely Goblins vat over TCP, in *both* directions. The vat build
//! pin is `.devcontainer/pins.sh` `GOBLINS_VERSION` (not runtime-enforced).
//!
//! The client bracket: this file spawns the conformance Goblins host
//! (`goblins-host.rkt`), reads its NDJSON readiness to learn the listen
//! port and the published echo cap's swiss-num, then `converse.zig` dials it
//! over `net.tcp` and runs the keyed `op:start-session` handshake (real Ed25519, a `tcp` locator
//! with `#f` hints so the signed bytes match what Goblins re-encodes), verifies
//! Goblins' own signed start-session, then bootstrap-fetches the echo cap and
//! calls it, asserting it resolves fulfilled. The same bracket pipelines the
//! two projection ops Goblins can answer: an `op:index` against the settled
//! echo answer, and an `op:get` against a still-pending answer that settles to
//! a Struct, and asserts Goblins resolves each projection. Finally it enlivens
//! the echo swiss-num through the engine's ADR-0012 dedup-cache API
//! (`prepareEnliven`/`recordEnlivenment`, the surface every binding's `enliven`
//! rides), calls the enlivened cap, and asserts a repeat enliven hits the cache
//! with no wire traffic, which proves enliven against a real Goblins-published cap.
//!
//! The listener bracket: glowcap then binds its own TCP listener on an
//! ephemeral port and a real Goblins client dials in. Five scenarios share
//! that bracket: a settled call to a published Greeter actor
//! (`glowcap-actor-call.rkt`), a pipelined enliven-and-call in one breath
//! (`goblins-tap-dialer.rkt`), the break path (`glowcap-break-call.rkt`),
//! where the client fetches a swiss-num glowcap never registered and asserts
//! its vow breaks with glowcap's reason, an export-side `op:listen`
//! (`glowcap-export-listen.rkt`), where Goblins subscribes on a live glowcap
//! object export and hears the settlement, and a projection asker
//! (`glowcap-projection-asker.rkt`), where Goblins writes canonical `op:get`
//! and `op:index` at glowcap's responders, then observes glowcap's
//! resolver-callback fulfillments for those projected answers. Together the
//! brackets prove the
//! bidirectional capability: glowcap drives Goblins, and Goblins drives a
//! glowcap actor.
//!
//! This is not part of the hermetic `zig build check`: it needs `racket` + the
//! `goblins` collection on PATH, so it runs as the sibling step
//! `zig build goblins-interop`, the way the binding dogfoods need their runtimes.

const std = @import("std");
const glowcap = @import("glowcap");
const goblins_child = @import("goblins_child.zig");
const converse = @import("converse.zig");
const harness = @import("interop_harness");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const tcp = glowcap.net.tcp;

const host = "127.0.0.1";
/// The Goblins host's listening port in the dial direction. `--port=N` (from
/// `zig build goblins-interop -Dport=N`) overrides it when 22099 is taken. The
/// listener scenarios bind ephemeral ports and need no override.
const default_port: u16 = 22099;
const frame_cap: usize = 1 << 16;

/// The wait each scenario allows its Goblins child, matching every sibling
/// driver in this directory. Finite is the contract (an unbounded wait is a
/// hang, not a slow test), 60s rather than 20s because these scenarios run
/// inside `check-external` beside other Racket and uv steps, and a child
/// starved of CPU by that concurrency was timing out the projection-asker
/// scenario in the aggregate while passing standalone.
const deadline_ms: u64 = 60_000;

const host_script = "conformance/goblins-peer/racket/goblins-host.rkt";
const dialer_script = "conformance/goblins-peer/racket/glowcap-actor-call.rkt";
// The pipelining client: it enlivens and calls in one breath (`<-` to the
// unresolved enliven vow), so the call arrives as an inbound pipelined deliver.
const pipelined_dialer_script = "conformance/goblins-peer/racket/goblins-tap-dialer.rkt";
// The break-path client: it enlivens a swiss-num glowcap never registered and
// asserts its vow breaks with glowcap's reason, proving Goblins unmarshals
// glowcap's V1.0 `['break, reason-symbol]` resolver callback.
const break_dialer_script = "conformance/goblins-peer/racket/glowcap-break-call.rkt";
// Goblins-as-asker projection: sends canonical `op:get` / `op:index` against
// glowcap's ADR-0050 responders (Goblins 0.18.0 has no app-level send yet).
const projection_asker_script = "conformance/goblins-peer/racket/glowcap-projection-asker.rkt";
// Export-side `op:listen`: Goblins `listen` on a settled remote object export.
const export_listen_dialer_script = "conformance/goblins-peer/racket/glowcap-export-listen.rkt";

// The swiss-num the glowcap actor is published behind in the listener scenarios.
const actor_swiss = "glowcapActorSwissnumABCDEFGH1234";
// Swiss-num for the projection-responder actor (Struct + List replies).
const projection_swiss = "glowcapProjectionSwissnumABCDEF1234";
// Never registered on the glowcap side: fetching it makes the
// bootstrap auto-serve break the answer with "unknown swissnum".
const unregistered_swiss = "glowcapUnknownSwissnumZZZZZZ9999";

/// The actor the listener scenarios publish for a live Goblins peer to call.
const Greeter = harness.PositionalReplyActor("Hello {s}, from a glowcap actor!");

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
            // bracket also proves the glowcap-to-Goblins Struct reply live.
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
    converse.run(io, allocator, swiss, port) catch |err| {
        std.debug.print("goblins-interop: client dial failed: {s}\n", .{@errorName(err)});
        // Dump before kill: the reap closes the pipes, and a silently dropped
        // stderr is the difference between a diagnosis and a mystery.
        goblins_child.dumpChildStderr(io, "goblins-interop", &child);
        child.kill(io);
        reaped = true;
        return err;
    };

    std.debug.print("goblins-interop: OK (glowcap as client), handshake + bootstrap fetch + echo deliver/resolve with live Goblins\n", .{});

    // Tear the client-scenario vat down before opening the reverse direction.
    child.kill(io);
    reaped = true;

    // Second bracket: Goblins dials *us* and calls a glowcap actor over the wire.
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
    std.debug.print("goblins-interop: OK, bidirectional: glowcap called Goblins, and Goblins called a glowcap actor\n", .{});

    // Third bracket: Goblins enlivens and calls in one breath, so the call arrives
    // as an inbound pipelined deliver against the enliven answer. glowcap auto-serves
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
    std.debug.print("goblins-interop: OK, inbound promise pipelining: goblins enlivened and called a glowcap actor in one breath\n", .{});

    // Fourth bracket: the break path. Goblins enlivens a swiss-num glowcap never
    // registered; glowcap breaks the fetch answer, which on the V1.0 wire is a
    // resolver-callback deliver carrying `['break, reason-symbol]`. The client
    // asserts its vow broke *with glowcap's reason*, an `<error …>` record here
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
    std.debug.print("goblins-interop: OK — break path: goblins observed glowcap's broken vow with its reason\n", .{});

    // Fifth bracket: export-side `op:listen`, Goblins listens on a live
    // glowcap object export and receives immediate fulfill.
    try runListenerScenario(init, .{
        .dialer = export_listen_dialer_script,
        .swiss = actor_swiss,
        .success_needle = "LISTEN OK",
        .serves_actor = true,
        .kind = "export listen",
        .actor = .greeter,
    });
    std.debug.print("goblins-interop: OK — export-side op:listen: goblins listened on a live glowcap export\n", .{});

    // Sixth bracket: Goblins-as-asker sends canonical `op:get` / `op:index`
    // frames through its own netlayer against glowcap's ADR-0050 responders.
    // The pinned Goblins release has inbound projection support but no public
    // outbound app API for those ops, so the Racket asker uses Goblins'
    // canonical records and test-only netlayer writer, then observes glowcap's
    // V1.0 resolver-callback settlements on the live Goblins TCP netlayer.
    try runListenerScenario(init, .{
        .dialer = projection_asker_script,
        .swiss = projection_swiss,
        .success_needle = "PROJECTION OK",
        .serves_actor = true,
        .kind = "projection asker",
        .actor = .projection,
        // `PROJECTION OK` means the Goblins-side probe observed fulfill
        // resolver callbacks for both projection answer positions, with the
        // expected payloads. The kind latches stay as a guard that the
        // canonical projection frames themselves reached glowcap.
        .expect_inbound_ops = &.{ .get, .index },
    });
    std.debug.print("goblins-interop: OK, glowcap accepted canonical op:get/op:index frames a Goblins netlayer wrote\n", .{});
}

/// One Goblins-dials-glowcap scenario over the shared listener bracket.
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
    /// Whether glowcap publishes and serves an actor behind `swiss`. The break
    /// scenario leaves this false: the client fetches an unregistered swiss-num,
    /// and the engine auto-breaks the fetch with no vat turn involved.
    serves_actor: bool,
    /// Labels the scenario in the success line.
    kind: []const u8,
    /// Which actor type to publish when `serves_actor` is true.
    actor: enum { greeter, projection } = .greeter,
    /// Inbound frame kinds this run must see arrive, the arrival proof for
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

/// The reverse direction: a glowcap peer listens on an ephemeral port, and a
/// real Goblins client (`scenario.dialer`) dials in and drives the scenario.
/// We assert the client printed `scenario.success_needle`, Goblins' own
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
    var script_argv: [4][]const u8 = .{ scenario.dialer, port_text, scenario.swiss, "" };
    var script_len: usize = 3;
    if (scenario.call_arg) |arg| {
        script_argv[3] = arg;
        script_len = 4;
    }
    var argv_buf: [6][]const u8 = undefined;
    var child = try std.process.spawn(io, .{
        .argv = goblins_child.racketArgv(&argv_buf, script_argv[0..script_len]),
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
    std.debug.print("goblins-interop: session open (glowcap as listener, {s})\n", .{scenario.kind});

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
    var seen_ops = @as([8]bool, @splat(false));
    std.debug.assert(scenario.expect_inbound_ops.len <= seen_ops.len);
    const pump_deadline = harness.deadlineAfter(io, deadline_ms);
    while (true) {
        if (harness.expired(io, pump_deadline)) break;
        const progress = try goblins_child.pumpPoll(&conn);
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
    std.debug.print("goblins-interop: goblins drove the glowcap listener ({s}) and printed `{s}`\n", .{ scenario.kind, scenario.success_needle });
}
