//! Dial-direction Goblins conversation: glowcap is the client.
//!
//! `driver.zig` owns spawning the vat and the listener scenarios. This
//! module dials that vat, verifies Goblins' signed start-session, fetches
//! the published caps, and asserts echo / projection / tell / enliven
//! against live Goblins bytes.

const std = @import("std");
const glowcap = @import("glowcap");
const goblins_child = @import("goblins_child.zig");
const harness = @import("interop_harness");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const codec = glowcap.ocapn.codec;
const crypto = glowcap.foundation.crypto;
const tcp = glowcap.net.tcp;

const host = "127.0.0.1";
const frame_cap: usize = 1 << 16;

// The record cap goblins-host.rkt publishes for the op:get leg: calling it
// returns a string-keyed hash (an OCapN Struct). Fixed in the host script,
// like the listener scenarios' actor swiss-num, so the echo readiness line
// stays the first `swiss` line every interop client parses.
const record_swiss = "glowcapRecordSwissnumABCDEF12345";
/// The stateful cap the one-way-deliver leg drives (`goblins-host.rkt`'s
/// `^tally`). A `tell` carries no answer, so proving it arrived means
/// changing something and reading it back.
const tally_swiss = "glowcapTallySwissnumABCDEF123456";

pub fn run(io: std.Io, allocator: std.mem.Allocator, swiss: []const u8, port: u16) !void {
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

    // 3. Call echo("glowcap-ping") and assert Goblins resolves it fulfilled. On
    //    V1.0 the runtime attaches a resolver to the answer; Goblins replies by
    //    delivering the resolution to it (it has no op:resolve), which
    //    Event.view() re-projects as a Resolve.
    const echo_answer: u64 = 4242;
    // The second argument is 2^100: Goblins materializes it as a Racket bignum
    // and marshals it back, so the round-trip proves the arbitrary-precision
    // Integer (ADR-0005) against live Goblins in both directions.
    const big_digits = "1267650600228229401496703205376";
    try peer.sendBorrowed(.{ .deliver = .{
        .target = echo,
        .args = &.{
            .{ .bytes = "glowcap-ping" },
            .{ .big_integer = .{ .negative = true, .digits = big_digits } },
        },
        .answer = model.AnswerPosition.from(echo_answer),
    } });

    var echoed = false;
    while (!echoed) {
        const progress = try goblins_child.pumpBounded(&conn);
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view();
            if (body.* == .resolve and body.resolve.answer.int() == echo_answer) {
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
                        if (!std.mem.eql(u8, text, "glowcap-ping")) {
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

    // 4. Pipeline an op:index against the settled echo answer (ADR-0004,
    //    glowcap as the asker): Goblins exports a promise at the new answer
    //    position and resolves it to element 0 of the echoed list. V1.0 has no
    //    op:resolve push, so the engine auto-installs a listener on the
    //    projected answer (`engine.v1_0.installListenerForOutboundProjection`);
    //    Goblins fires it and the projected resolution surfaces back here as an
    //    ordinary resolve event, exactly as the bindings see it.
    const index_answer: u64 = 4343;
    try peer.sendBorrowed(.{ .index = .{
        .receiver = .{ .promise = .{ .answer_position = model.AnswerPosition.from(echo_answer) } },
        .index = .{ .integer = 0 },
        .answer = model.AnswerPosition.from(index_answer),
    } });

    var projected = false;
    while (!projected) {
        const progress = try goblins_child.pumpBounded(&conn);
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view();
            if (body.* == .resolve and body.resolve.answer.int() == index_answer) {
                switch (body.resolve.resolution) {
                    .fulfill => |payload| {
                        const text: []const u8 = switch (payload) {
                            .bytes, .string => |t| t,
                            else => return error.ProjectionWrongPayload,
                        };
                        if (!std.mem.eql(u8, text, "glowcap-ping")) return error.ProjectionWrongPayload;
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

    // 5. Pipeline an op:get (ADR-0004, glowcap as the asker), the same way:
    //    fetch the record cap, calling it returns a string-keyed hash, the
    //    OCapN Struct, and project the "name" field out of the call's answer.
    //    The op:get is sent *before* the call settles, so Goblins anchors its
    //    `hash-ref` vow on a still-pending answer; the engine's auto-installed
    //    listener carries the projected field back as a resolve event.
    const record = try goblins_child.fetchCap(allocator, peer, &conn, record_swiss);
    defer model.freeReference(allocator, record);
    std.debug.print("goblins-interop: fetched goblins record cap, pipelining op:get against its answer\n", .{});

    const record_answer: u64 = 4444;
    try peer.sendBorrowed(.{ .deliver = .{
        .target = record,
        .args = &.{.{ .string = "glowcap-get" }},
        .answer = model.AnswerPosition.from(record_answer),
    } });
    const get_answer: u64 = 4545;
    try peer.sendBorrowed(.{ .get = .{
        .receiver = .{ .promise = .{ .answer_position = model.AnswerPosition.from(record_answer) } },
        .field = "name",
        .answer = model.AnswerPosition.from(get_answer),
    } });

    var got = false;
    while (!got) {
        const progress = try goblins_child.pumpBounded(&conn);
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view();
            if (body.* == .resolve and body.resolve.answer.int() == get_answer) {
                switch (body.resolve.resolution) {
                    .fulfill => |payload| {
                        const text: []const u8 = switch (payload) {
                            .bytes, .string => |t| t,
                            else => return error.GetProjectionWrongPayload,
                        };
                        if (!std.mem.eql(u8, text, "glowcap-get")) return error.GetProjectionWrongPayload;
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

    // 6. One-way deliver (`tell`): the frame glowcap sends for a
    //    fire-and-forget send is an `op:deliver` with no answer and no
    //    resolver, the shape pinned Goblins speaks for one-way delivery.
    //    Nothing comes back by construction, so the proof is a state
    //    change: bump the tally twice with no answer, then call `read` with
    //    one and assert live Goblins counted both.
    const tally = try goblins_child.fetchCap(allocator, peer, &conn, tally_swiss);
    defer model.freeReference(allocator, tally);
    std.debug.print("goblins-interop: fetched goblins tally cap, sending two one-way delivers\n", .{});

    try peer.sendBorrowed(.{ .deliver = .{
        .target = tally,
        .args = &.{.{ .symbol = "bump" }},
        .answer = null,
    } });
    try peer.sendBorrowed(.{ .deliver = .{
        .target = tally,
        .args = &.{.{ .symbol = "bump" }},
        .answer = null,
    } });

    // Distinct from every other answer this conversation opens: the driver
    // numbers them by hand, so a reused position is a collision, not a reuse.
    const tally_answer: u64 = 4747;
    try peer.sendBorrowed(.{ .deliver = .{
        .target = tally,
        .args = &.{.{ .symbol = "read" }},
        .answer = model.AnswerPosition.from(tally_answer),
    } });

    var tallied = false;
    while (!tallied) {
        const progress = try goblins_child.pumpBounded(&conn);
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view();
            if (body.* == .resolve and body.resolve.answer.int() == tally_answer) {
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

    // 7. Enliven the echo cap by its swiss-num through the engine's ADR-0007
    //    dedup-cache API (the same surface every binding's `enliven` rides), not a
    //    bare bootstrap fetch. The first enliven runs a real bootstrap-fetch to
    //    Goblins and caches the resolved far reference; calling the enlivened cap
    //    proves it is live. A second enliven for the same swiss-num then short-
    //    circuits on the cache with no wire traffic, returning the same import.
    const enlivened = try goblins_child.enlivenCap(allocator, peer, &conn, swiss);
    defer model.freeReference(allocator, enlivened);
    std.debug.print("goblins-interop: enlivened goblins echo cap via the dedup-cache API, calling it\n", .{});

    const enliven_answer: u64 = 4646;
    try peer.sendBorrowed(.{ .deliver = .{
        .target = enlivened,
        .args = &.{.{ .bytes = "glowcap-enliven" }},
        .answer = model.AnswerPosition.from(enliven_answer),
    } });
    var enliven_echoed = false;
    while (!enliven_echoed) {
        const progress = try goblins_child.pumpBounded(&conn);
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view();
            if (body.* == .resolve and body.resolve.answer.int() == enliven_answer) {
                switch (body.resolve.resolution) {
                    .fulfill => |payload| {
                        if (payload != .list or (try payload.list.len()) != 1) return error.EnlivenWrongPayload;
                        const text: []const u8 = switch (try payload.list.at(0)) {
                            .bytes, .string => |t| t,
                            else => return error.EnlivenWrongPayload,
                        };
                        if (!std.mem.eql(u8, text, "glowcap-enliven")) return error.EnlivenWrongPayload;
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
/// `<my-location <ocapn-peer …>>`: the proof we parsed real Goblins bytes.
fn verifyGoblinsStartSession(allocator: std.mem.Allocator, peer: *engine.Peer) !void {
    var saw = false;
    while (peer.pollEvent()) |event| {
        var e = event;
        defer e.deinit();
        const view = e.view();
        switch (view.*) {
            .start_session => |ss| {
                const pubkey = crypto.PeerKey.fromSlice(ss.session_pubkey) catch return error.BadGoblinsKey;
                const sig = switch (ss.acceptable_location_sig) {
                    .halves => |h| crypto.Signature.fromParts(h.r, h.s) catch return error.BadGoblinsSig,
                    .raw => |raw| blk: {
                        if (raw.len != crypto.signature_bytes) return error.BadGoblinsSig;
                        break :blk crypto.Signature.fromBytes(raw[0..crypto.signature_bytes].*);
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
