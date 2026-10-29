//! Differential probe: one seeded set of mutated frames, fed to a live Spritely
//! Goblins vat and to a glowcap listener, one fresh session per frame.
//!
//! The valid frame is the echo `op:deliver` a client sends to the fetched
//! capability. Each probe builds it inside its own session, because the
//! target's export position differs per session and a frame built elsewhere
//! names an unknown target. Frame 0 is that frame unmutated, the control: both
//! sides must accept it, or the procedure is broken. Every later frame flips
//! one to four bytes, seeded by the frame number. The two sides' frames differ
//! only in the digits of the target's export position. Flips land in the fixed
//! windows on either side of those digits: the 29 bytes before them and the
//! bytes after them. The digits are left alone because their value and width
//! differ per side, and a flip there would not be the same mutation. Both
//! windows are checked against literals at every probe, so a change in the
//! deliver's encoding fails loudly.
//!
//! A probe dials, opens a keyed session, fetches the echo capability, writes
//! the frame raw as one stream unit, then sends a valid follow-up echo. The side
//! accepted the frame when the follow-up's answer arrives, refused it when the
//! connection ends or an `op:abort` arrives first, and was silent when the
//! deadline passed with neither. This driver never decides which side is right.
//! A difference between the two columns is a case for a person to triage
//! against the OCapN draft. It is not part of `zig build check`: it needs
//! `racket` and the `goblins` collection, so it runs as `zig build goblins-differential`.

const std = @import("std");
const glowcap = @import("glowcap");
const goblins_child = @import("goblins_child.zig");
const harness = @import("interop_harness");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const driver = glowcap.driver;
const tcp = glowcap.net.tcp;
const stream_framing = glowcap.foundation.stream_framing;

const host = "127.0.0.1";
const default_port: u16 = 22098;
const default_count: usize = 64;
const default_deadline_ms: u64 = 3_000;
const max_deadline_ms: u64 = 10_000;
const frame_cap: usize = 1 << 16;
/// The wait for the vat's listener and for each session's handshake.
const setup_ms: u64 = 5_000;
/// The wait for the vat's readiness line is the child's own, finite by the
/// harness. The corpus answer position: the valid frame asks for this one.
const corpus_answer: u64 = 7001;
/// The deliver's bytes before the target's export position, identical on both
/// sides. `front_window` is its length.
const front_literal = "<10'op:deliver<11'desc:export";
const front_window: usize = front_literal.len;
/// The deliver's bytes after the export position, identical on both sides.
/// `back_window` is its length. The export digits between the two windows
/// differ per session and per side, so flips never touch them.
const back_literal = "+>[13:glowcap-probe]7001+<18'desc:import-object2+>>";
const back_window: usize = back_literal.len;
/// The follow-up's answer position, distinct so a mutated frame cannot answer it.
const follow_answer: u64 = 7002;

const host_script = "conformance/goblins-peer/racket/goblins-host.rkt";
const glowcap_swiss = "glowcapDifferentialEchoSwissnum01";

pub const Outcome = enum { accepted, refused, silent };

/// Echoes its first argument, the way the Goblins echo cap returns its list.
const Echo = struct {
    pub fn handle(_: *Echo, _: *driver.HostTurn, _: ?[]const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        if (arg_values.len == 0) return .{ .string = "" };
        return arg_values[0];
    }
};

/// What the follow-up predicate saw. Probes run on the main thread only.
const Watch = struct {
    var answered: bool = false;
    var aborted: bool = false;
    var deadline: ?std.Io.Clock.Timestamp = null;
    var io: ?std.Io = null;
    var expired_flag: bool = false;
};

fn watching(peer: *engine.Peer) bool {
    while (peer.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit();
        if (event.tag == .abort) Watch.aborted = true;
        const body = event.view();
        if (body.* == .resolve and body.resolve.answer.int() == follow_answer) Watch.answered = true;
    }
    if (!Watch.answered and !Watch.aborted and harness.expired(Watch.io.?, Watch.deadline.?)) Watch.expired_flag = true;
    return Watch.answered or Watch.aborted or Watch.expired_flag;
}

/// Send the echo `op:deliver` aimed at `target` through `peer.sendBorrowed`.
fn sendEcho(peer: *engine.Peer, target: model.Reference, answer: u64) !void {
    try peer.sendBorrowed(.{ .deliver = .{
        .target = target,
        .args = &.{.{ .bytes = "glowcap-probe" }},
        .answer = model.AnswerPosition.from(answer),
    } });
}

/// Dial `locator`, open a keyed session, and fetch `swiss`. The caller owns
/// the returned reference and keeps `conn` and `scaffold` alive around it.
fn openSession(
    io: std.Io,
    allocator: std.mem.Allocator,
    scaffold: *harness.PeerScaffold,
    locator: model.PeerLocator,
    swiss: []const u8,
) !struct { conn: glowcap.net.Connection, cap: model.Reference } {
    const peer = &scaffold.peer;
    var conn = try harness.tcpConnectRetry(io, peer, locator, scaffold.read_buf, scaffold.write_buf, setup_ms);
    errdefer conn.deinit();
    _ = try goblins_child.openKeyedSession(io, peer, &conn, locator.designator);
    const cap = try goblins_child.fetchCap(allocator, peer, &conn, swiss);
    return .{ .conn = conn, .cap = cap };
}

/// One probe: a fresh session, the mutated frame raw, then a valid follow-up.
pub fn probe(
    io: std.Io,
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
    swiss: []const u8,
    seed: ?u64,
    deadline_ms: u64,
    written: *std.ArrayList(u8),
) !Outcome {
    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();
    const peer = &scaffold.peer;
    var opened = try openSession(io, allocator, &scaffold, locator, swiss);
    defer {
        opened.conn.deinit();
    }
    defer model.freeReference(allocator, opened.cap);
    const conn = &opened.conn;

    try conn.flush();
    // The valid frame, built in this session. The send is queued, so stepping
    // to idle encodes it without writing it.
    try sendEcho(peer, opened.cap, corpus_answer);
    try peer.stepToIdle();
    var frame = peer.takeOutbound() orelse return error.NoCorpusFrame;
    defer frame.deinit();
    try written.appendSlice(allocator, frame.bytes());
    if (written.items.len == 0) return error.NoCorpusFrame;
    // The windows are the bytes a mutation may touch, so the encoding must match.
    if (written.items.len <= front_window + back_window or
        !std.mem.startsWith(u8, written.items, front_literal) or
        !std.mem.endsWith(u8, written.items, back_literal)) return error.UnexpectedFrameShape;
    if (seed) |n| mutate(written.items, n);
    const mutated = written.items;
    var prefix_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
    const prefix = stream_framing.renderPrefix(&prefix_buf, mutated.len);
    // A write the peer already closed on is a refusal of the frame before it.
    const wrote = blk: {
        conn.w.writeAll(prefix) catch break :blk false;
        conn.w.writeAll(mutated) catch break :blk false;
        conn.w.flush() catch break :blk false;
        break :blk true;
    };
    if (!wrote) return .refused;

    Watch.answered = false;
    Watch.aborted = false;
    Watch.expired_flag = false;
    Watch.io = io;
    Watch.deadline = harness.deadlineAfter(io, deadline_ms);
    sendEcho(peer, opened.cap, follow_answer) catch return .refused;
    const slice_ms: i32 = @intCast(@min(deadline_ms, std.math.maxInt(i32)));
    const progress = conn.runUntil(watching, slice_ms) catch |err| switch (err) {
        error.Timeout => return .silent,
        else => return .refused,
    };
    if (Watch.answered) return .accepted;
    if (Watch.aborted or progress == .closed) return .refused;
    return .silent;
}

/// Accept in a loop until `done`, attending every session. A refused handshake
/// or a failed step is the case under test, so neither ends the loop. A
/// session is released once its wire has ended, whether the probe's mutated
/// frame ended it or the probe hung up, so the listener runs the whole set
/// with a bounded number of live sessions.
fn serveEcho(allocator: std.mem.Allocator, server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    var sessions: std.ArrayList(*driver.Session) = .empty;
    defer {
        for (sessions.items) |session| session.deinit();
        sessions.deinit(allocator);
    }
    while (!done.load(.acquire)) {
        var i: usize = 0;
        while (i < sessions.items.len) {
            if (sessions.items[i].closeOutcome() == .pending) {
                i += 1;
                continue;
            }
            sessions.swapRemove(i).deinit();
        }
        const acceptable = server.waitAcceptable(10) catch false;
        if (acceptable) {
            // tolerant: a failed accept costs one dial, which the peer's own timeout reports, and the next loop iteration accepts again.
            const session = server.accept() catch continue;
            sessions.append(allocator, session) catch {
                session.deinit();
                continue;
            };
            // best-effort: a session the mutated frame killed reports on its next step.
            session.attend() catch {};
            continue;
        }
        // best-effort: a step error belongs to one session, the loop serves the rest.
        _ = server.runtime.stepAny(10) catch {};
    }
}

const Flags = struct {
    port: u16 = default_port,
    count: usize = default_count,
    deadline_ms: u64 = default_deadline_ms,
};

fn parseFlags(minimal_args: anytype) !Flags {
    var flags: Flags = .{};
    var args = std.process.Args.Iterator.init(minimal_args);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            flags.port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch return error.BadPort;
            if (flags.port == 0) return error.BadPort;
        } else if (std.mem.startsWith(u8, arg, "--count=")) {
            flags.count = std.fmt.parseInt(usize, arg["--count=".len..], 10) catch return error.BadArgument;
            if (flags.count == 0) return error.BadArgument;
        } else if (std.mem.startsWith(u8, arg, "--deadline-ms=")) {
            flags.deadline_ms = std.fmt.parseInt(u64, arg["--deadline-ms=".len..], 10) catch return error.BadArgument;
            if (flags.deadline_ms == 0 or flags.deadline_ms > max_deadline_ms) return error.BadArgument;
        } else {
            std.debug.print("goblins-differential: unknown argument '{s}'\n", .{arg});
            return error.BadArgument;
        }
    }
    return flags;
}

/// Flip one to four bytes of `bytes` in place, seeded by the frame number. Each
/// flip draws which window, then the offset inside it, then the xor value, in
/// that order, so both sides consume the generator alike and flip the same
/// bytes of the same two windows.
fn mutate(bytes: []u8, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var flips = 1 + (random.int(u32) % 4);
    while (flips > 0) : (flips -= 1) {
        const front = random.int(u32) % 2 == 0;
        const window_len: usize = if (front) front_window else back_window;
        const offset = random.int(u32) % window_len;
        const at = if (front) offset else bytes.len - back_window + offset;
        bytes[at] ^= @intCast(1 + (random.int(u32) % 255));
    }
}

fn printHex(label: []const u8, bytes: []const u8) void {
    std.debug.print("  {s}=", .{label});
    for (bytes) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\n", .{});
}

/// True once nothing listens on the vat's port, which means the vat exited.
fn vatGone(io: std.Io, allocator: std.mem.Allocator, locator: model.PeerLocator) bool {
    var scaffold = harness.PeerScaffold.init(allocator, frame_cap) catch return false;
    defer scaffold.deinit();
    var conn = harness.tcpConnectRetry(io, &scaffold.peer, locator, scaffold.read_buf, scaffold.write_buf, 300) catch return true;
    conn.deinit();
    return false;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const flags = parseFlags(init.minimal.args) catch |err| {
        std.debug.print("goblins-differential: bad flags: {s}\n", .{@errorName(err)});
        return err;
    };

    var port_buf: [8]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{flags.port});
    const hosted = try goblins_child.spawnHostAwaitSwiss(io, allocator, init.environ_map, "goblins-differential", "echo cap", &.{ host_script, host, port_str });
    var child = hosted.child;
    defer child.kill(io);
    const goblins_swiss = hosted.swiss;
    defer allocator.free(goblins_swiss);

    var goblins_designator: [tcp.designator_buf_len]u8 = undefined;
    const goblins_locator = tcp.locatorFromAddress(&goblins_designator, try tcp.parseHostPort(host, flags.port));

    var server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, .{
        .frame_cap = frame_cap,
        .handshake = .{ .ms = 10_000 },
        .settle = .{ .ms = 10_000 },
    });
    defer server.deinit();
    try server.publish(glowcap_swiss, Echo, .{});
    var local_buf: [64]u8 = undefined;
    const local_address = try tcp.parseDesignator(try server.localDesignator(&local_buf));
    var glowcap_designator: [tcp.designator_buf_len]u8 = undefined;
    const glowcap_locator = tcp.locatorFromAddress(&glowcap_designator, local_address);

    var done = std.atomic.Value(bool).init(false);
    var serving = try io.concurrent(serveEcho, .{ allocator, server, &done });
    var stopped = false;
    defer if (!stopped) {
        done.store(true, .release);
        // best-effort: this unwind already returns the run's own error, and the serving thread's failure would only repeat it.
        serving.await(io) catch {};
    };

    var agree: usize = 0;
    var differ: usize = 0;
    var control_ok = true;
    var vat_died = false;
    for (0..flags.count) |i| {
        const seed: ?u64 = if (i == 0) null else i;
        var g_bytes: std.ArrayList(u8) = .empty;
        defer g_bytes.deinit(allocator);
        var c_bytes: std.ArrayList(u8) = .empty;
        defer c_bytes.deinit(allocator);
        const g = probe(io, allocator, goblins_locator, goblins_swiss, seed, flags.deadline_ms, &g_bytes) catch |err| blk: {
            std.debug.print("goblins-differential: goblins probe {d} failed: {s}\n", .{ i, @errorName(err) });
            if (i == 0) control_ok = false;
            break :blk Outcome.refused;
        };
        const c = probe(io, allocator, glowcap_locator, glowcap_swiss, seed, flags.deadline_ms, &c_bytes) catch |err| blk: {
            std.debug.print("goblins-differential: glowcap probe {d} failed: {s}\n", .{ i, @errorName(err) });
            if (i == 0) control_ok = false;
            break :blk Outcome.refused;
        };
        std.debug.print("frame={d} goblins={s} glowcap={s}\n", .{ i, @tagName(g), @tagName(c) });
        if (g == c) agree += 1 else {
            differ += 1;
            printHex("goblins", g_bytes.items);
            printHex("glowcap", c_bytes.items);
        }
        if (i == 0 and (g != .accepted or c != .accepted)) control_ok = false;
        if (!control_ok) break;
        if (g != .accepted and vatGone(io, allocator, goblins_locator)) {
            std.debug.print("goblins-differential: the vat exited after frame {d}\n", .{i});
            vat_died = true;
            break;
        }
    }

    done.store(true, .release);
    stopped = true;
    try serving.await(io);
    std.debug.print("goblins-differential: {d} frames, {d} agree, {d} differ\n", .{ agree + differ, agree, differ });
    if (!control_ok) {
        std.debug.print("goblins-differential: the control frame was not accepted by both sides, so the procedure is broken\n", .{});
        return error.ControlFailed;
    }
    if (vat_died) return error.VatDied;
}
