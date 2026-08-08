//! Shared helpers for the Goblins interop drivers: the spawned Racket child's
//! NDJSON readiness protocol (the spawn-and-await bracket, field extraction,
//! the readiness-block wait, the stdout drain, the best-effort stderr dump),
//! the keyed `op:start-session` bracket, and the bootstrap-fetch pump loop.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const net = pancake.net;
const crypto = pancake.foundation.crypto;

/// Resolved through PATH so the live interop runs on any host with a working
/// Racket, not only the devcontainer's install location. The spawned child
/// still self-locates its `collects` from its own resolved executable path.
pub const racket_path = "racket";

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
    // A `tcp` address designator carries no durable identity or hint and stays
    // byte-identical to what Goblins expects.
    try peer.sendKeyedStartSession(.{
        .transport = "tcp",
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    }, secret);
    _ = try conn.runUntil(isOpen, 0);
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
    // The swiss-num alone keys the enliven; dialing is the adapter's job, so
    // the core takes no peer locator here.
    const start = try engine.sturdyref.prepareEnliven(allocator, &peer.session_state, swiss);
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

/// Read the host's NDJSON stdout up to and including the first line carrying
/// `needle`, returning every byte read. A host that announces itself over more
/// than one line — an endpoint id on its `vat-ready` line and a swiss-num on the
/// `cap-published` line after it — keeps them all here, so a caller reads each
/// field it needs out of the block with `extractField`. Caller owns the bytes.
fn readReadinessBlock(
    io: std.Io,
    allocator: std.mem.Allocator,
    child: *std.process.Child,
    needle: []const u8,
) ![]u8 {
    const out = child.stdout orelse return error.NoChildStdout;
    var rbuf: [8192]u8 = undefined;
    var reader = out.readerStreaming(io, &rbuf);
    var block: std.ArrayList(u8) = .empty;
    // The one free on every error path. The success path hands the storage out
    // through `toOwnedSlice`, which leaves nothing for this to release.
    errdefer block.deinit(allocator);
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.GoblinsExitedBeforeReady,
            else => return err,
        };
        try block.appendSlice(allocator, line);
        if (std.mem.indexOf(u8, line, needle) != null) return block.toOwnedSlice(allocator);
    }
}

/// The readiness field a published capability announces itself with, and what
/// `spawnHostAwaitSwiss` waits for. A driver that waits on the readiness block
/// itself names it here rather than respelling the JSON.
pub const swiss_field = "\"swiss\":\"";

/// A spawned Racket host and the swiss-num its readiness line published.
pub const SpawnedHost = struct {
    child: std.process.Child,
    /// Caller owns the bytes.
    swiss: []u8,
};

/// Spawn a Racket host script (`argv_tail` follows the `racket` executable)
/// and wait for its NDJSON readiness line. On failure this prints the missed
/// `ready_what` readiness under `prefix`, dumps the child's stderr, and kills
/// the child; on success the caller owns the child (kill it when done) and
/// the swiss bytes.
pub fn spawnHostAwaitSwiss(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    prefix: []const u8,
    ready_what: []const u8,
    argv_tail: []const []const u8,
) !SpawnedHost {
    return spawnHostAwaitSwissStdio(io, allocator, environ_map, prefix, ready_what, argv_tail, .inherit);
}

/// The same bracket, with the child's stdin a pipe the caller writes to. A host
/// that waits for a line before doing something — settling a promise it
/// published unresolved — lets the driver choose the moment, so the scenario's
/// ordering is the driver's to state rather than a sleep's to guess. The caller
/// writes through `child.stdin.?` and owns the child exactly as above.
pub fn spawnHostAwaitSwissWithStdin(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    prefix: []const u8,
    ready_what: []const u8,
    argv_tail: []const []const u8,
) !SpawnedHost {
    return spawnHostAwaitSwissStdio(io, allocator, environ_map, prefix, ready_what, argv_tail, .pipe);
}

fn spawnHostAwaitSwissStdio(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    prefix: []const u8,
    ready_what: []const u8,
    argv_tail: []const []const u8,
    stdin: std.process.SpawnOptions.StdIo,
) !SpawnedHost {
    const ready = try spawnHostAwaitReadiness(io, allocator, environ_map, prefix, ready_what, swiss_field, argv_tail, stdin);
    defer allocator.free(ready.block);
    var child = ready.child;
    const swiss = extractField(ready.block, swiss_field) orelse {
        child.kill(io);
        return error.GoblinsExitedBeforeReady;
    };
    return .{ .child = child, .swiss = try allocator.dupe(u8, swiss) };
}

/// A spawned Racket host and every readiness line it printed up to the one that
/// carried `needle`.
pub const SpawnedHostReadiness = struct {
    child: std.process.Child,
    /// Caller owns the bytes. Read fields out with `extractField`.
    block: []u8,
};

/// Spawn a Racket host script and wait for the readiness line carrying `needle`,
/// answering with every line printed up to it. A host whose locator takes more
/// than one field — an iroh endpoint id and its direct addresses beside the cap's
/// swiss-num — announces them across those lines, and the caller reads each out
/// of the block. On failure this prints the missed `ready_what` readiness under
/// `prefix`, dumps the child's stderr, and kills the child; on success the caller
/// owns the child and the bytes.
pub fn spawnHostAwaitReadiness(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    prefix: []const u8,
    ready_what: []const u8,
    needle: []const u8,
    argv_tail: []const []const u8,
    stdin: std.process.SpawnOptions.StdIo,
) !SpawnedHostReadiness {
    var argv_buf: [8][]const u8 = undefined;
    argv_buf[0] = racket_path;
    for (argv_tail, 0..) |arg, i| argv_buf[i + 1] = arg;
    var child = try std.process.spawn(io, .{
        .argv = argv_buf[0 .. argv_tail.len + 1],
        .environ_map = environ_map,
        .stdin = stdin,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    const block = readReadinessBlock(io, allocator, &child, needle) catch |err| {
        std.debug.print("{s}: never saw the {s} readiness line: {s}\n", .{ prefix, ready_what, @errorName(err) });
        dumpChildStderr(io, prefix, &child);
        child.kill(io); // kill terminates and reaps
        return err;
    };
    return .{ .child = child, .block = block };
}

/// Read whatever the child has written to stdout into `scratch`, returning the
/// byte count. Best-effort: a read failure just ends the drain.
pub fn drainChildStdout(io: std.Io, child: *std.process.Child, scratch: []u8) usize {
    const out = child.stdout orelse return 0;
    var rbuf: [4096]u8 = undefined;
    var reader = out.readerStreaming(io, &rbuf);
    var seen: usize = 0;
    while (seen < scratch.len) {
        const n = reader.interface.readSliceShort(scratch[seen..]) catch break;
        if (n == 0) break;
        seen += n;
    }
    return seen;
}

/// Wait for a line on the child's stdout carrying `needle`, and answer it
/// without its newline. A host that keeps running has more to say after its
/// readiness lines — what its own netlayer concluded about the session a driver
/// just opened — and the driver reads that verdict back here.
///
/// Bounded by `budget_ms` and answering null when it expires: the child outlives
/// this read by design, so a line that never comes must end the wait rather than
/// park the driver forever. `scratch` accumulates everything read, so a line
/// that arrives split across reads is still found whole, and null is also the
/// answer once it fills.
pub fn awaitChildStdoutLine(
    io: std.Io,
    child: *std.process.Child,
    needle: []const u8,
    scratch: []u8,
    budget_ms: i32,
) ?[]const u8 {
    const out = child.stdout orelse return null;
    const fd = out.handle;
    const deadline = net.clock.nowMs(io) + budget_ms;
    var seen: usize = 0;
    while (seen < scratch.len) {
        if (lineWith(scratch[0..seen], needle)) |line| return line;
        const remaining = deadline - net.clock.nowMs(io);
        if (remaining <= 0) return null;
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&pfd, @intCast(@min(remaining, std.math.maxInt(i32)))) catch return null;
        if (ready == 0) return null;
        const n = std.posix.read(fd, scratch[seen..]) catch return null;
        if (n == 0) return null; // the child ended its stdout
        seen += n;
    }
    return null;
}

/// The first complete line of `text` carrying `needle`, without its newline.
/// A partial trailing line is never answered, so a caller reading more bytes
/// sees the whole line rather than a prefix that happened to contain the needle.
fn lineWith(text: []const u8, needle: []const u8) ?[]const u8 {
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |end| {
        const line = rest[0..end];
        if (std.mem.indexOf(u8, line, needle) != null) return line;
        rest = rest[end + 1 ..];
    }
    return null;
}

/// Best-effort dump of the child's stderr under `prefix`, to surface why
/// Goblins died. The read end is flipped non-blocking first: a dead child
/// EOFs immediately, while a live, silent child (a hung dialer, a bind race)
/// yields whatever is buffered and then would-block — the dump path exists to
/// explain a failure and must never park the driver itself. Call this before
/// `child.kill` (the reap closes and nulls the pipes).
pub fn dumpChildStderr(io: std.Io, prefix: []const u8, child: *std.process.Child) void {
    _ = io;
    const err_file = child.stderr orelse return;
    const fd = err_file.handle;
    const fl = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
    if (std.posix.errno(fl) == .SUCCESS) {
        const nonblock = @as(usize, @intCast(fl)) | @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));
        _ = std.posix.system.fcntl(fd, std.posix.F.SETFL, nonblock);
    }
    std.debug.print("{s}: --- goblins stderr ---\n", .{prefix});
    var scratch: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &scratch) catch break;
        if (n == 0) break;
        std.debug.print("{s}", .{scratch[0..n]});
    }
    std.debug.print("\n--- end goblins stderr ---\n", .{});
}
