//! Bootstrap-fetch settlement choreography shared by the net
//! loopback tests.
//!
//! Test support (not a production module): the blocking-pump clients
//! (`tcp_test`, `netlayer_test`, the completion loop's dialed-in clients),
//! the completion dialer's serve callback, and the C-ABI endpoint/inproc
//! loopback tests all drive the same scenario, open the handshake, send a
//! prepared bootstrap fetch, then match every inbound event against it with
//! one fulfilled/broken/malformed switch. That choreography lives here once.
//! Each test keeps only the transport seam it proves.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const net = glowcap.net;
const tcp = net.tcp;
const handshake = @import("handshake.zig");

/// True once the peer's session has reached `open`, the `runUntil` predicate
/// for handshake completion.
pub fn isOpen(peer: *engine.Peer) bool {
    return peer.session_state.state == .open;
}

/// Drop every queued peer event, deinitializing each.
pub fn drainEvents(peer: *engine.Peer) void {
    while (peer.pollEvent()) |event| {
        var e = event;
        e.deinit();
    }
}

/// Queue `start_session` (copying, the caller keeps its borrowed fields),
/// pump the connection until the session opens, and drop the handshake events.
pub fn handshakeToOpen(
    peer: *engine.Peer,
    conn: *net.Connection,
    start_session: model.Message,
) !void {
    try peer.sendBorrowed(start_session);
    const progress = try conn.runUntil(isOpen, 0);
    if (progress == .closed and !isOpen(peer)) return error.ClosedBeforeOpen;
    drainEvents(peer);
}

/// Decode one peer event and match it against the pending fetch identified by
/// `(resolver_export, answer_position)`. Returns the fulfilled reference,
/// owned by the caller, released with `model.freeReference`, or null when the
/// event is unrelated to the fetch (the decoded message is freed). A broken
/// settlement frees its reason and fails as `error.FetchBroke`. A malformed
/// one fails as `error.FetchMalformed`.
pub fn matchFetchEvent(
    allocator: std.mem.Allocator,
    resolver_export: ?model.ExportPosition,
    answer_position: model.AnswerPosition,
    event: *engine.Event,
) !?model.Reference {
    const owned = try event.decodeOwned(allocator);
    const match = try engine.fetch.tryMatchFetchOutcome(
        allocator,
        resolver_export,
        answer_position,
        owned,
    );
    switch (match) {
        .settled => |outcome| switch (outcome) {
            .fulfilled => |reference| return reference,
            .broken => |reason| {
                allocator.free(reason);
                return error.FetchBroke;
            },
            .malformed => return error.FetchMalformed,
        },
        .unrelated => |msg| {
            model.freeMessage(allocator, msg);
            return null;
        },
    }
}

/// Fetch `swissnum` from the partner's bootstrap over an open blocking
/// connection: prepare the fetch, send it, and pump until it settles.
/// Returns the fulfilled reference, owned by the caller, released with
/// `model.freeReference`. The connection closing before the fetch settles
/// fails as `error.ClosedBeforeSettled`. A broken or malformed settlement
/// fails through `matchFetchEvent`.
pub fn settleFetch(
    allocator: std.mem.Allocator,
    peer: *engine.Peer,
    conn: *net.Connection,
    swissnum: []const u8,
) !model.Reference {
    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &peer.session_state, swissnum);
    try peer.send(prepared.message);

    var settled: ?model.Reference = null;
    errdefer if (settled) |reference| model.freeReference(allocator, reference);
    while (settled == null) {
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const matched = try matchFetchEvent(
                allocator,
                prepared.resolver_export,
                prepared.answer.position,
                &event,
            );
            if (matched) |reference| {
                if (settled == null) {
                    settled = reference;
                } else {
                    model.freeReference(allocator, reference);
                }
            }
        }
        if (progress == .closed) break;
    }
    return settled orelse error.ClosedBeforeSettled;
}

/// The one-shot tcp client the completion-loop tests dial with: a stub peer
/// capped at `frame_cap` connects to 127.0.0.1:`port`, opens the session with
/// `hello`, fetches "thermostat", and frees the reference.
pub fn dialAndFetchOnce(
    io: std.Io,
    port: u16,
    allocator: std.mem.Allocator,
    frame_cap: usize,
    hello: model.Message,
) anyerror!void {
    var peer = handshake.stubPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const designator_addr = try tcp.parseHostPort("127.0.0.1", port);
    const designator = tcp.locatorFromAddress(&designator_buf, designator_addr).designator;
    const locator: model.PeerLocator = .{
        .transport = tcp.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyMap(),
    };
    var conn = try tcp.connect(io, &peer, locator, read_buf, write_buf, .{});
    defer conn.deinit();

    try handshakeToOpen(&peer, &conn, hello);
    const reference = try settleFetch(allocator, &peer, &conn, "thermostat");
    model.freeReference(allocator, reference);
}
