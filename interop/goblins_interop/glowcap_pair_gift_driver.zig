//! Live three-party handoff where *two* of the three vats are glowcap, and the
//! two profiles that produces are the point.
//!
//! Every other live handoff driver here puts one glowcap peer among two Goblins
//! vats, so every session in the run is the v1.0 Syrup baseline and the
//! question this one asks cannot come up. The cast here is the one
//! `apps/ocapnviz/src/fixtures/three-vat-handoff-mixed.ts` draws:
//!
//!   Exporter (glowcap)  publishes a greeter for every session and listens.
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
//! per-session negotiation this run could not exist: a glowcap exporter
//! refused a Goblins dial outright, so proving a handoff across the two
//! required giving up the glowcap session entirely.
//!
//! What the handoff itself has to survive is that split. The give is minted on
//! the Cap'n Proto session between the glowcap pair and redeemed on Carol's
//! Syrup session to the exporter, which is the case `codec.signed` exists for:
//! a signed envelope is Syrup whatever each session negotiated, so the two
//! ends verify the same bytes.
//!
//! Needs `racket` + the `goblins` collection on PATH, runs as the sibling step
//! `zig build goblins-glowcap-pair-gift`, not in the in-tree check.

const std = @import("std");
const glowcap = @import("glowcap");
const goblins_child = @import("goblins_child.zig");
const harness = @import("interop_harness");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const tcp = glowcap.net.tcp;

const host_addr = "127.0.0.1";
const default_carol_port: u16 = 22150;
const frame_cap: usize = 1 << 16;
const recipient_script = "conformance/goblins-peer/racket/gift-recipient.rkt";
const exporter_peer = @import("glowcap_pair_exporter.zig");
const greeter_swiss = exporter_peer.greeter_swiss;
const exporter_exe_path = "zig-out/bin/glowcap-pair-exporter";
const introducer_swiss = "introducer";
const deadline_ms: u64 = 60_000;

/// The profile both glowcap hosts ask for. Neither gets it on every session,
/// and that mismatch is what the run is about.
const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .codec = .capnp,
    .captp_version = .next,
    .handshake = .{ .ms = 20_000 },
    .settle = .{ .ms = 20_000 },
};

/// The profile each session settled on, counted so the run asserts the split
/// rather than assuming it.
const ProfileLog = struct {
    glowcap_sessions: usize = 0,
    baseline_sessions: usize = 0,
    other_sessions: usize = 0,

    fn note(self: *ProfileLog, label: []const u8, codec: model.CodecId, version: model.CaptpVersion) void {
        std.debug.print(
            "goblins-glowcap-pair-gift: {s} session settled codec={s} captp={s}\n",
            .{ label, @tagName(codec), @tagName(version) },
        );
        if (codec == .capnp and version == .next) {
            self.glowcap_sessions += 1;
        } else if (codec == .syrup and version == .v1_0) {
            self.baseline_sessions += 1;
        } else {
            self.other_sessions += 1;
        }
    }

    fn noteSession(self: *ProfileLog, label: []const u8, session: *driver.Session) void {
        const state = &session.hs.served.port.peer.session_state;
        self.note(label, state.codec, state.captp_version);
    }
};

const Introducer = struct {
    greeter: driver.Capability,

    pub fn handle(self: *Introducer, ht: *driver.HostTurn, verb: []const u8, args: driver.Args) !driver.Value {
        _ = ht;
        _ = args;
        if (!std.mem.eql(u8, verb, "get-greeter")) return error.NoSuchMethod;
        return .{ .capability = self.greeter };
    }
};

/// Dial the exporter, fetch its greeter, publish the introducer that hands it
/// out, then serve Carol until the run ends. Owns `log` until joined.
fn serveGifter(
    gifter: *driver.Server,
    exporter_bound: []const u8,
    log: *ProfileLog,
    settled: *std.atomic.Value(bool),
    published: *std.atomic.Value(bool),
    done: *std.atomic.Value(bool),
) anyerror!void {
    defer settled.store(true, .release);
    const exporter_session = try gifter.runtime.connectLocator(.{
        .transport = tcp.transport_name,
        .designator = exporter_bound,
        .hints = model.Hints.emptyFalse(),
    }, .inherit);
    const exporter = try driver.Session.adopt(gifter.runtime, exporter_session);
    defer exporter.deinit();
    log.noteSession("gifter", exporter);
    const greeter = try exporter.fetch(greeter_swiss);
    std.debug.print("goblins-glowcap-pair-gift: gifter fetched the exporter's greeter\n", .{});
    try gifter.publish(introducer_swiss, Introducer, .{ .greeter = greeter });
    published.store(true, .release);
    settled.store(true, .release);

    var carol: ?*driver.Session = null;
    defer if (carol) |session| session.deinit();
    while (!done.load(.acquire)) {
        if (carol == null and try gifter.waitAcceptable(20)) {
            carol = try gifter.accept();
            log.noteSession("gifter", carol.?);
        }
        _ = exporter.stepReadable(10) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => {},
            else => |e| return e,
        };
        if (carol) |session| _ = session.stepReadable(10) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => {},
            else => |e| return e,
        };
    }
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
    while (log.glowcap_sessions + log.baseline_sessions + log.other_sessions < 2) {
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
        std.debug.print("goblins-glowcap-pair-gift: {s}", .{line});
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

    const carol_port = try harness.parsePortFlag(init.minimal.args, "goblins-glowcap-pair-gift", default_carol_port, .{
        .max = 65534,
    });
    var carol_port_buf: [8]u8 = undefined;
    const carol_port_str = try std.fmt.bufPrint(&carol_port_buf, "{d}", .{carol_port});

    try run(io, allocator, init.environ_map, carol_port_str);

    std.debug.print(
        "goblins-glowcap-pair-gift OK: the glowcap pair held a glowcap-next Cap'n Proto session while live Goblins " ++
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
    // The peers talk over a real socket, so the run cannot depend on how two
    // runtimes in one process interleave.
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
    std.debug.print("goblins-glowcap-pair-gift: glowcap exporter on {s}\n", .{exporter_bound});

    // ── The glowcap gifter ──────────────────────────────────────────────────
    var gifter = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = host_addr ++ ":0" }, .ephemeral, opts);
    defer gifter.deinit();
    var gifter_bound_buf: [64]u8 = undefined;
    const gifter_bound = try allocator.dupe(u8, try gifter.localDesignator(&gifter_bound_buf));
    defer allocator.free(gifter_bound);

    var log = ProfileLog{};
    var settled = std.atomic.Value(bool).init(false);
    var published = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);
    var serving = try io.concurrent(serveGifter, .{ gifter, exporter_bound, &log, &settled, &published, &done });
    var serving_joined = false;
    defer if (!serving_joined) {
        done.store(true, .release);
        // best-effort: this unwind already returns the run's own error, and the serving thread's failure would only repeat it.
        serving.await(io) catch {};
    };

    harness.untilFlag(io, deadline_ms, &settled) catch |err| {
        goblins_child.dumpChildStderr(io, "goblins-glowcap-pair-gift exporter", &exporter);
        return err;
    };
    if (!published.load(.acquire)) {
        done.store(true, .release);
        serving_joined = true;
        try serving.await(io);
        return error.FetchFailed;
    }

    // ── Goblins Carol ───────────────────────────────────────────────────────
    std.debug.print(
        "goblins-glowcap-pair-gift: glowcap gifter publishing introducer swiss={s} on {s}\n",
        .{ introducer_swiss, gifter_bound },
    );
    var carol_argv: [8][]const u8 = undefined;
    var carol = try std.process.spawn(io, .{
        .argv = goblins_child.racketArgv(&carol_argv, &.{
            recipient_script,
            gifter_bound,
            introducer_swiss,
            carol_port_str,
        }),
        .environ_map = environ_map,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var carol_reaped = false;
    defer if (!carol_reaped) carol.kill(io);

    readCarolOk(io, &carol) catch |err| {
        goblins_child.dumpChildStderr(io, "goblins-glowcap-pair-gift", &carol);
        return err;
    };
    carol.kill(io);
    carol_reaped = true;

    done.store(true, .release);
    serving_joined = true;
    try serving.await(io);

    // The claim the run exists to make. The gifter holds one glowcap session
    // (to the exporter) and one baseline session (Carol's dial); the exporter
    // holds the mirror glowcap session and the baseline session Carol's redeem
    // opened.
    if (log.glowcap_sessions != 1) return error.GifterMissingGlowcapSession;
    if (log.baseline_sessions != 1) return error.GifterMissingBaselineSession;
    if (log.other_sessions != 0) return error.UnexpectedProfile;

    // The exporter reports its own, so the assertion covers the process that
    // actually negotiated them rather than this one's view.
    var exporter_log = ProfileLog{};
    try readExporterProfiles(io, &exporter_reader, &exporter_log);
    exporter.kill(io);
    exporter_reaped = true;
    if (exporter_log.glowcap_sessions != 1) return error.ExporterMissingGlowcapSession;
    if (exporter_log.baseline_sessions != 1) return error.ExporterMissingBaselineSession;
    if (exporter_log.other_sessions != 0) return error.UnexpectedProfile;
}
