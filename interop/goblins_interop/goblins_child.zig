//! Shared helpers for the Goblins interop drivers: the spawned Racket child's
//! NDJSON readiness protocol (field extraction, the published-swiss wait, the
//! best-effort stderr dump), the keyed `op:start-session` bracket, and the
//! bootstrap-fetch pump loop.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const crypto = pancake.foundation.crypto;

/// Absolute path to `racket`, so it can self-locate its `collects` (a bare
/// PATH-resolved `argv[0]` doesn't give it that), the devcontainer symlink,
/// which is where the gated interop steps' `racket` always lives.
pub const racket_path = "/usr/local/bin/racket";

/// True once the peer's session has completed the handshake, the `runUntil`
/// predicate every interop driver pumps toward.
pub fn isOpen(peer: *engine.Peer) bool {
    return peer.session_state.state == .open;
}

/// Run the keyed `op:start-session` bracket against a live Goblins peer: draw
/// a fresh Ed25519 seed, sign a `tcp`/`#f`-hints locator for `designator` (so
/// Goblins' verification, which re-encodes `#f`, matches), and pump until the
/// session opens. Returns the drawn secret: a handoff recipient reuses it,
/// because the deposited gift names this session key.
pub fn openKeyedSession(
    io: std.Io,
    peer: *engine.Peer,
    conn: anytype,
    designator: []const u8,
) !crypto.SecretKey {
    var seed: [crypto.SEED_BYTES]u8 = undefined;
    io.randomSecure(&seed) catch return error.HandshakeEntropyFailed;
    const secret = crypto.SecretKey.fromSeed(seed);
    try openKeyedSessionWith(peer, conn, designator, secret);
    return secret;
}

/// The same bracket for a caller that already holds its session secret, the
/// handoff withdraw, which must present the key the gift was deposited under.
pub fn openKeyedSessionWith(
    peer: *engine.Peer,
    conn: anytype,
    designator: []const u8,
    secret: crypto.SecretKey,
) !void {
    try peer.sendKeyedStartSession(.v1_0, .{
        .transport = "tcp",
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    }, secret);
    _ = try conn.runUntil(isOpen);
}

/// Bootstrap-fetch a cap by its swiss-num over the live connection, pumping
/// until the fetch settles. The caller owns the returned reference. Events
/// not consumed by the fetch match stay queued on the peer for later loops.
pub fn fetchCap(
    allocator: std.mem.Allocator,
    peer: *engine.Peer,
    conn: anytype,
    swiss: []const u8,
) !model.Reference {
    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &peer.session_state, swiss);
    try peer.send(prepared.message);

    while (true) {
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const owned = try event.decodeOwned(allocator);
            const match = try engine.fetch.tryMatchFetchOutcome(
                allocator,
                prepared.resolver_export,
                prepared.answer_position,
                owned,
            );
            switch (match) {
                .settled => |outcome| switch (outcome) {
                    .fulfilled => |reference| return reference,
                    .broken => |reason| {
                        defer allocator.free(reason);
                        std.debug.print("goblins-child: fetch broke: {s}\n", .{reason});
                        return error.FetchBroke;
                    },
                    .malformed => return error.FetchMalformed,
                },
                .unrelated => |msg| model.freeMessage(allocator, msg),
            }
        }
        if (progress == .closed) return error.FetchNeverSettled;
    }
}

/// Enliven a sturdyref by its swiss-num over the live connection, exercising the
/// engine's ADR-0012 dedup-cache API (`prepareEnliven`/`recordEnlivenment`) rather
/// than a bare bootstrap fetch. Pumps a fresh enliven to settlement and caches it;
/// the caller owns the returned reference. The session must have negotiated the
/// sturdyref feature (the negotiating peer offers `FeatureSet.full()`, so it has).
pub fn enlivenCap(
    allocator: std.mem.Allocator,
    peer: *engine.Peer,
    conn: anytype,
    swiss: []const u8,
) !model.Reference {
    const sturdyref: model.SturdyRef = .{
        // The core ignores the peer locator on enliven (dialing is the adapter's
        // job); only the swiss-num keys the bootstrap fetch.
        .peer = .{ .transport = "tcp", .designator = "", .hints = model.Hints.emptyFalse() },
        .swissnum = swiss,
    };
    const start = try engine.sturdyref.prepareEnliven(allocator, &peer.session_state, sturdyref);
    const prepared = switch (start) {
        // A first enliven on a fresh session can never be cached or in flight.
        .cached, .in_flight => return error.EnlivenUnexpectedlyDeduped,
        .fresh => |p| p,
    };
    try peer.send(prepared.message);

    while (true) {
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const owned = try event.decodeOwned(allocator);
            const match = try engine.fetch.tryMatchFetchOutcome(
                allocator,
                prepared.resolver_export,
                prepared.answer_position,
                owned,
            );
            switch (match) {
                .settled => |outcome| return engine.sturdyref.recordEnlivenment(
                    allocator,
                    &peer.session_state,
                    swiss,
                    outcome,
                ),
                .unrelated => |msg| model.freeMessage(allocator, msg),
            }
        }
        if (progress == .closed) return error.EnlivenNeverSettled;
    }
}

/// Pull the value out of a `"<key>":"<value>"` NDJSON line — pass the needle
/// up to and including the opening quote, e.g. `"swiss":"` — or null if the
/// needle is absent.
pub fn extractField(line: []const u8, needle: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, line, needle) orelse return null) + needle.len;
    const rest = line[start..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

/// Read the host's NDJSON stdout until a `"swiss":"<value>"` cap-published
/// line arrives, returning its swiss-num. Caller owns the returned bytes.
pub fn readPublishedSwiss(io: std.Io, allocator: std.mem.Allocator, child: *std.process.Child) ![]u8 {
    const out = child.stdout orelse return error.NoChildStdout;
    var rbuf: [8192]u8 = undefined;
    var reader = out.readerStreaming(io, &rbuf);
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.GoblinsExitedBeforeReady,
            else => return err,
        };
        if (extractField(line, "\"swiss\":\"")) |swiss| return allocator.dupe(u8, swiss);
    }
}

/// Best-effort dump of the child's stderr under `prefix`, to surface why
/// Goblins died.
pub fn dumpChildStderr(io: std.Io, prefix: []const u8, child: *std.process.Child) void {
    const err_file = child.stderr orelse return;
    var buf: [4096]u8 = undefined;
    var reader = err_file.readerStreaming(io, &buf);
    std.debug.print("{s}: --- goblins stderr ---\n", .{prefix});
    var scratch: [1024]u8 = undefined;
    while (true) {
        const n = reader.interface.readSliceShort(&scratch) catch break;
        if (n == 0) break;
        std.debug.print("{s}", .{scratch[0..n]});
    }
    std.debug.print("\n--- end goblins stderr ---\n", .{});
}
