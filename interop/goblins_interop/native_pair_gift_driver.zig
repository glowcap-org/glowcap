//! Live three-party handoff where *two* of the three vats are glowcap, and the
//! two profiles that produces are the point.
//!
//! Every other live handoff driver here puts one glowcap peer among two Goblins
//! vats, so every session in the run is the v1.0 Syrup baseline and the
//! question this one asks cannot come up. The cast here is the one
//! `apps/ocapnviz/src/fixtures/three-vat-handoff-mixed.ts` draws:
//!
//!   Exporter (glowcap)  publishes a giftable greeter and listens.
//!   Gifter   (glowcap)  dials the exporter, fetches the greeter, and
//!                       publishes an introducer that hands it out.
//!   Carol    (Goblins)  dials the gifter's introducer, redeems the give it
//!                       answers with, dials the exporter directly, and calls
//!                       the greeter there.
//!
//! Both glowcap hosts prefer `glowcap-next` over Cap'n Proto. The session
//! between them settles there, because both ends can. Carol's two sessions
//! settle on the baseline, because she speaks nothing else, and neither
//! glowcap host is told in advance which kind of peer is dialing. Before
//! per-session negotiation this run could not exist: a native glowcap exporter
//! refused a Goblins dial outright, so proving a handoff across the two
//! required giving up the native session entirely.
//!
//! What the handoff itself has to survive is that split. The give is minted on
//! the Cap'n Proto session between the glowcap pair and redeemed on Carol's
//! Syrup session to the exporter, which is the case `codec.signed` exists for:
//! a signed envelope is Syrup whatever each session negotiated, so the two
//! ends verify the same bytes.
//!
//! Needs `racket` + the `goblins` collection on PATH; runs as the sibling step
//! `zig build goblins-native-pair-gift`, not in the in-tree check.

const std = @import("std");
const glowcap = @import("glowcap");
const goblins_child = @import("goblins_child.zig");
const harness = @import("interop_harness");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const crypto = glowcap.foundation.crypto;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = glowcap.net.tcp;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const TcpBridge = driver.Bridge(net.TcpLoop);
const runLoop = harness.LoopRunner(net.TcpLoop).runUntilFlag;

const host_addr = "127.0.0.1";
const default_carol_port: u16 = 22150;
const frame_cap: usize = 1 << 16;
const recipient_script = "conformance/goblins-peer/racket/gift-recipient.rkt";
const exporter_peer = @import("native_pair_exporter.zig");
const greeter_swiss = exporter_peer.greeter_swiss;
const exporter_exe_path = "zig-out/bin/glowcap-native-pair-exporter";
const introducer_swiss = "introducer";
const deadline_ms: u64 = 60_000;

/// The profile both glowcap hosts ask for. Neither gets it on every session,
/// and that mismatch is what the run is about.
fn nativeOptions() Host.Options {
    var o = Host.Options.withFrameCap(frame_cap);
    o.local_turn_budget = 64;
    o.codec = .capnp;
    o.captp_version = .next;
    return o;
}

fn pokeListener(io: std.Io, port: u16) void {
    if (port == 0) return;
    const address = std.Io.net.IpAddress.parse(host_addr, port) catch return;
    var stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch return;
    stream.close(io);
}

/// The greeter Carol reaches by redeeming the give. It answers with the name
/// it was called with, so a correct reply proves the call landed on this actor
/// The profile each session settled on, counted so the run asserts the split
/// rather than assuming it.
const ProfileLog = struct {
    native_sessions: usize = 0,
    baseline_sessions: usize = 0,
    other_sessions: usize = 0,

    fn note(self: *ProfileLog, label: []const u8, codec: model.CodecId, version: model.CaptpVersion) void {
        std.debug.print(
            "goblins-native-pair-gift: {s} session settled codec={s} captp={s}\n",
            .{ label, @tagName(codec), @tagName(version) },
        );
        if (codec == .capnp and version == .next) {
            self.native_sessions += 1;
        } else if (codec == .syrup and version == .v1_0) {
            self.baseline_sessions += 1;
        } else {
            self.other_sessions += 1;
        }
    }

    fn noteSession(self: *ProfileLog, label: []const u8, session: *HostSession) void {
        const state = &session.served.port.peer.session_state;
        self.note(label, state.codec, state.captp_version);
    }
};

const GifterState = struct {
    host: *Host,
    bridge: *TcpBridge,
    greeter: ?model.Reference = null,
    fetched: *std.atomic.Value(bool),
    log: ProfileLog = .{},

    fn onFetched(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *GifterState = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| {
                if (value == .reference) {
                    self.greeter = value.reference;
                    std.debug.print("goblins-native-pair-gift: gifter fetched the exporter's greeter\n", .{});
                } else {
                    std.debug.print("goblins-native-pair-gift: fetch settled to a non-reference\n", .{});
                }
            },
            .broken => |reason| std.debug.print("goblins-native-pair-gift: fetch broke: {s}\n", .{reason}),
            .give => {},
        }
        self.fetched.store(true, .release);
    }
};

const Introducer = struct {
    state: *GifterState,

    pub fn handle(self: *Introducer, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "get-greeter")) return error.NoSuchMethod;
        const greeter = self.state.greeter orelse return error.NotReady;
        return .{ .reference = greeter };
    }
};

fn publishIntroducer(ctx: ?*anyopaque, served: *driver.Served, vat: *actors.Vat) anyerror!void {
    const state: *GifterState = @ptrCast(@alignCast(ctx.?));
    _ = try served.publish(vat, introducer_swiss, Introducer, .{ .state = state });
}

fn gifterOnOpen(ctx: ?*anyopaque, bridge: *TcpBridge, conn: *TcpBridge.Slot) anyerror!void {
    const state: *GifterState = @ptrCast(@alignCast(ctx.?));
    state.log.noteSession("gifter", conn.session);
    if (conn.leg != .app_dial or conn.session.role != .dialed) return;
    if (state.greeter != null) return;
    const vow = try state.host.fetch(conn.session, greeter_swiss);
    try state.host.vowOn(vow, .{ .ctx = state, .func = GifterState.onFetched });
    try bridge.drainActions();
}

/// The exporter child's bound address, from its announce line.
fn readExporterAddress(io: std.Io, reader: anytype, out: *[128]u8) ![]const u8 {
    const deadline = harness.deadlineAfter(io, deadline_ms);
    while (!harness.expired(io, deadline)) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.ExporterNeverListened,
            else => return err,
        };
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (std.mem.startsWith(u8, trimmed, exporter_peer.listening_prefix)) {
            const addr = trimmed[exporter_peer.listening_prefix.len..];
            if (addr.len > out.len) return error.ExporterAddressTooLong;
            @memcpy(out[0..addr.len], addr);
            return out[0..addr.len];
        }
    }
    return error.ExporterNeverListened;
}

/// The profiles the exporter child reports, one line per session it opened.
fn readExporterProfiles(io: std.Io, reader: anytype, log: *ProfileLog) !void {
    const deadline = harness.deadlineAfter(io, deadline_ms);
    while (log.native_sessions + log.baseline_sessions + log.other_sessions < 2) {
        if (harness.expired(io, deadline)) return error.ExporterProfilesMissing;
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.ExporterProfilesMissing,
            else => return err,
        };
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (!std.mem.startsWith(u8, trimmed, "EXPORTER SESSION ")) continue;
        const codec: model.CodecId = if (std.mem.indexOf(u8, trimmed, "codec=capnp") != null) .capnp else .syrup;
        const version: model.CaptpVersion = if (std.mem.indexOf(u8, trimmed, "captp=next") != null) .next else .v1_0;
        log.note("exporter", codec, version);
    }
}

fn readCarolOk(io: std.Io, child: *std.process.Child) !void {
    const out = child.stdout orelse return error.NoChildStdout;
    var rbuf: [8192]u8 = undefined;
    var reader = out.readerStreaming(io, &rbuf);
    const deadline = harness.deadlineAfter(io, deadline_ms);
    while (!harness.expired(io, deadline)) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        std.debug.print("goblins-native-pair-gift: {s}", .{line});
        if (std.mem.indexOf(u8, line, "GIFT OK:") != null and std.mem.indexOf(u8, line, "goblins-carol") != null) {
            return;
        }
        if (std.mem.indexOf(u8, line, "GIFT ERR:") != null or std.mem.indexOf(u8, line, "GIFT TIMEOUT") != null) {
            return error.GiftFailed;
        }
    }
    return error.GiftFailed;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const carol_port = try harness.parsePortFlag(init.minimal.args, "goblins-native-pair-gift", default_carol_port, .{
        .max = 65534,
    });
    var carol_port_buf: [8]u8 = undefined;
    const carol_port_str = try std.fmt.bufPrint(&carol_port_buf, "{d}", .{carol_port});

    try run(io, allocator, init.environ_map, carol_port_str);

    std.debug.print(
        "goblins-native-pair-gift OK: the glowcap pair held a glowcap-next Cap'n Proto session while live Goblins " ++
            "redeemed a give across two baseline sessions, reaching the glowcap exporter directly\n",
        .{},
    );
}

fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    carol_port_str: []const u8,
) !void {
    // ── The glowcap exporter, as its own process ────────────────────────────
    // One completion loop per process: the gifter's loop and this main task's
    // polling are already two schedulable things, and a third made the run's
    // outcome depend on how they interleaved. The peers talk over a real
    // socket either way.
    var exporter = try std.process.spawn(io, .{
        .argv = &.{exporter_exe_path},
        .environ_map = environ_map,
        .stdout = .inherit,
        .stderr = .pipe,
    });
    var exporter_reaped = false;
    defer if (!exporter_reaped) exporter.kill(io);

    var exporter_reader_buf: [4096]u8 = undefined;
    const exporter_out = exporter.stderr orelse return error.NoChildStderr;
    var exporter_reader = exporter_out.readerStreaming(io, &exporter_reader_buf);
    var exporter_bound_buf: [128]u8 = undefined;
    const exporter_bound = try readExporterAddress(io, &exporter_reader, &exporter_bound_buf);
    std.debug.print("goblins-native-pair-gift: glowcap exporter on {s}\n", .{exporter_bound});

    // ── The glowcap gifter ──────────────────────────────────────────────────
    var gifter_seed: [crypto.SEED_BYTES]u8 = undefined;
    io.randomSecure(&gifter_seed) catch return error.HandshakeEntropyFailed;
    var gifter_session_root: [crypto.SEED_BYTES]u8 = undefined;
    io.randomSecure(&gifter_session_root) catch return error.HandshakeEntropyFailed;
    var gifter = try Host.init(allocator, gifter_seed, gifter_session_root, nativeOptions());
    defer gifter.deinit();

    var fetched = std.atomic.Value(bool).init(false);
    var gifter_state: GifterState = undefined;
    var gifter_loop: net.TcpLoop = undefined;
    var gifter_bridge = TcpBridge.init(allocator, &gifter, io, &gifter_loop, .{
        .publish = publishIntroducer,
        .publish_ctx = &gifter_state,
        .on_open = gifterOnOpen,
        .on_open_ctx = &gifter_state,
    });
    defer gifter_bridge.deinit();
    gifter_state = .{ .host = &gifter, .bridge = &gifter_bridge, .fetched = &fetched };

    gifter_loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, @ptrCast(&gifter_bridge), TcpBridge.hookOptions(.{
        .max_conns = 8,
        .listen = 0,
    }));
    defer gifter_loop.deinit();
    const gifter_port = gifter_loop.port().?;
    var gifter_bound_buf: [tcp.designator_buf_len]u8 = undefined;
    const gifter_addr = try tcp.parseHostPort(host_addr, gifter_port);
    const gifter_bound = tcp.locatorFromAddress(&gifter_bound_buf, gifter_addr).designator;
    try gifter_bridge.attach(model.transport.Known.tcp.metadata(), gifter_bound, &.{});

    // Queue the dial before the loop thread starts. The bridge and its host
    // belong to whichever thread drives the loop, so reaching in from here
    // afterwards races it: the dial is sometimes lost, and the session that
    // does open arrives as an accept, whose leg this driver's `on_open`
    // correctly ignores — leaving the fetch never issued and the run parked
    // on a vow nobody will settle.
    try gifter_bridge.dialOutbound(.{
        .transport = tcp.transport_name,
        .designator = exporter_bound,
        .hints = model.Hints.emptyFalse(),
    });

    var gifter_done = std.atomic.Value(bool).init(false);
    var gifter_err: ?anyerror = null;
    var gifter_future = try io.concurrent(runLoop, .{ &gifter_loop, &gifter_done, &gifter_err });
    defer {
        gifter_done.store(true, .release);
        pokeListener(io, gifter_port);
        gifter_future.await(io);
    }

    harness.untilFlag(io, deadline_ms, &fetched) catch |err| {
        goblins_child.dumpChildStderr(io, "goblins-native-pair-gift exporter", &exporter);
        return err;
    };
    if (gifter_state.greeter == null) return error.FetchFailed;

    // ── Goblins Carol ───────────────────────────────────────────────────────
    std.debug.print(
        "goblins-native-pair-gift: glowcap gifter publishing introducer swiss={s} on {s}\n",
        .{ introducer_swiss, gifter_bound },
    );
    var carol = try std.process.spawn(io, .{
        .argv = &.{
            goblins_child.racket_path,
            recipient_script,
            gifter_bound,
            introducer_swiss,
            carol_port_str,
        },
        .environ_map = environ_map,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var carol_reaped = false;
    defer if (!carol_reaped) carol.kill(io);

    readCarolOk(io, &carol) catch |err| {
        goblins_child.dumpChildStderr(io, "goblins-native-pair-gift", &carol);
        return err;
    };
    carol.kill(io);
    carol_reaped = true;

    if (gifter_err) |err| return err;

    // The claim the run exists to make. The gifter holds one native session
    // (to the exporter) and one baseline session (Carol's dial); the exporter
    // holds the mirror native session and the baseline session Carol's redeem
    // opened.
    if (gifter_state.log.native_sessions != 1) return error.GifterMissingNativeSession;
    if (gifter_state.log.baseline_sessions != 1) return error.GifterMissingBaselineSession;
    if (gifter_state.log.other_sessions != 0) return error.UnexpectedProfile;

    // The exporter reports its own, so the assertion covers the process that
    // actually negotiated them rather than this one's view.
    var exporter_log = ProfileLog{};
    try readExporterProfiles(io, &exporter_reader, &exporter_log);
    exporter.kill(io);
    exporter_reaped = true;
    if (exporter_log.native_sessions != 1) return error.ExporterMissingNativeSession;
    if (exporter_log.baseline_sessions != 1) return error.ExporterMissingBaselineSession;
    if (exporter_log.other_sessions != 0) return error.UnexpectedProfile;
}
