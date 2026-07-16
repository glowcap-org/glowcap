//! Bootstrap-fetch settlement choreography shared by the net
//! loopback tests.
//!
//! Test support (not a production module): the blocking-pump clients
//! (`tcp_test`, `netlayer_test`, the completion loop's dialed-in clients),
//! the completion dialer's serve callback, and the C-ABI endpoint/inproc
//! loopback tests all drive the same scenario, open the handshake, send a
//! prepared bootstrap fetch, then match every inbound event against it with
//! one fulfilled/broken/malformed switch. That choreography lives here once;
//! each test keeps only the transport seam it is actually proving.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const net = pancake.net;

/// True once the peer's session has reached `open` — the `runUntil` predicate
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
    try peer.sendCopying(start_session);
    _ = try conn.runUntil(isOpen, 0);
    drainEvents(peer);
}

/// Decode one peer event and match it against the pending fetch identified by
/// `(resolver_export, answer_position)`. Returns the fulfilled reference —
/// owned by the caller, released with `model.freeReference` — or null when the
/// event is unrelated to the fetch (the decoded message is freed). A broken
/// settlement frees its reason and fails as `error.FetchBroke`; a malformed
/// one fails as `error.FetchMalformed`.
pub fn matchFetchEvent(
    allocator: std.mem.Allocator,
    resolver_export: model.ExportPosition,
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
/// fails as `error.ClosedBeforeSettled`; a broken or malformed settlement
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
                prepared.answer_position,
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
