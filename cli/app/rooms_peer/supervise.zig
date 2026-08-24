//! Start/stop supervision for `pancake app rooms-peer`.
const std = @import("std");
const builtin = @import("builtin");
const signals = @import("../../operability/signals.zig");
const log = @import("../../operability/log.zig");
const common = @import("common.zig");
const harness = @import("harness.zig");
const files = @import("harness/files.zig");
const json = @import("supervise/json.zig");
const Flags = @import("flags.zig").Flags;

const Io = common.Io;
const Allocator = common.Allocator;
const emitStdout = common.emitStdout;
const emitStdoutFmt = common.emitStdoutFmt;
const default_locator = common.default_locator;
const resolveLocator = common.resolveLocator;

const pathIn = files.pathIn;
const readFile = files.readFile;
const stateField = harness.stateField;
const writeState = harness.writeState;

fn stateReadFailure(io: Io, err: anyerror) error{PeerFailed} {
    // best-effort: the returned PeerFailed still carries the failure; only
    // the JSON detail line is lost if stdout refuses.
    emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"state\",\"detail\":\"{s}\"}}\n", .{@errorName(err)}) catch {};
    return error.PeerFailed;
}

// --- start ------------------------------------------------------------------

pub const ProcessLiveness = enum { running, absent, unknown };

/// Probe liveness without turning an observation failure into process death.
/// `kill(pid, 0)` is portable; Linux's proc state additionally distinguishes a
/// zombie, which can otherwise make a stopped daemon look live in a bare
/// container until its init process reaps it.
pub fn processLiveness(io: Io, pid: i32) ProcessLiveness {
    if (pid <= 0) return .unknown;
    const no_signal: std.posix.SIG = @fromBackingInt(@intCast(0));
    std.posix.kill(@intCast(pid), no_signal) catch |err| switch (err) {
        error.ProcessNotFound => return .absent,
        error.PermissionDenied => return .running,
        else => return .unknown,
    };

    if (comptime builtin.os.tag != .linux) return .running;

    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return .unknown;
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return .unknown;
    defer file.close(io);
    var read_buf: [512]u8 = undefined;
    var fr = file.reader(io, &read_buf);
    var data_buf: [512]u8 = undefined;
    const n = fr.interface.readSliceShort(&data_buf) catch return .unknown;
    const data = data_buf[0..n];
    const rp = std.mem.lastIndexOfScalar(u8, data, ')') orelse return .unknown;
    var i = rp + 1;
    while (i < data.len and data[i] == ' ') i += 1;
    if (i >= data.len) return .unknown;
    return switch (data[i]) {
        'Z', 'X', 'x' => .absent,
        else => .running,
    };
}

pub fn pidAlive(io: Io, gpa: Allocator, pid: i32) bool {
    _ = gpa;
    return processLiveness(io, pid) == .running;
}

/// The absolute path to this running binary, so detached launches and printed
/// commands do not depend on the caller's working directory or PATH.
pub fn selfExePath(io: Io, buf: []u8) ![]const u8 {
    const n = try std.process.executablePath(io, buf);
    return buf[0..n];
}

pub fn readPid(io: Io, gpa: Allocator, dir: []const u8) ?i32 {
    const text = readFile(io, gpa, dir, "peer.pid") catch return null;
    defer gpa.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i32, trimmed, 10) catch null;
}

pub const ProcessObservation = union(enum) {
    none,
    running: i32,
    unconfirmed,
};

/// The lease, not the PID text, is the process identity. An unlocked sidecar
/// means the PID is stale even if the operating system has since reused it.
pub fn observeProcess(io: Io, gpa: Allocator, dir: []const u8) !ProcessObservation {
    const lease = files.tryLockLeaf(io, dir, "peer.pid") catch |err| switch (err) {
        error.Busy => {
            const pid = readPid(io, gpa, dir) orelse return .unconfirmed;
            return if (pidAlive(io, gpa, pid)) .{ .running = pid } else .unconfirmed;
        },
        else => return err,
    };
    lease.unlock();
    return .none;
}

/// Always returns an owned copy the caller frees; an unreadable working
/// directory degrades to the relative spelling, still owned.
fn absDir(io: Io, gpa: Allocator, dir: []const u8) ![]u8 {
    if (dir.len > 0 and dir[0] == '/') return gpa.dupe(u8, dir);
    var buf: [4096]u8 = undefined;
    const n = std.process.currentPath(io, &buf) catch return gpa.dupe(u8, dir);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ buf[0..n], dir });
}

pub fn runStart(init: std.process.Init, flags: Flags) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (flags.nick.len == 0 or flags.dir.len == 0) {
        try emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"usage\",\"detail\":\"start needs --dir and --nick\"}}\n", .{});
        return error.UsageFailed;
    }
    const dir = try absDir(io, gpa, flags.dir);
    defer gpa.free(dir);
    // Keep the bootstrap URL (often `http(s)://…/locator`) for the daemon so each
    // reconnect re-fetches a fresh `ocapn://` after the room CapTP child remints.
    // Resolve once here only to fail fast when the bootstrap is already unreachable.
    const bootstrap = if (flags.locator.len > 0) flags.locator else default_locator;
    {
        const probe = resolveLocator(io, gpa, bootstrap) catch |err| {
            var doc = json.Document.init(gpa);
            defer doc.deinit();
            doc.beginObject() catch return json.emitInternalError(io);
            doc.boolean("ok", false) catch return json.emitInternalError(io);
            doc.string("error", "locator") catch return json.emitInternalError(io);
            doc.string("locator", bootstrap) catch return json.emitInternalError(io);
            doc.string("detail", @errorName(err)) catch return json.emitInternalError(io);
            doc.end() catch return json.emitInternalError(io);
            const bytes = doc.line() catch return json.emitInternalError(io);
            emitStdout(io, bytes) catch return error.PeerFailed;
            return error.PeerFailed;
        };
        gpa.free(probe);
    }
    try Io.Dir.cwd().createDirPath(io, dir);

    const lifecycle = files.tryLockLeaf(io, dir, "lifecycle") catch |err| {
        // best-effort: the failure return still lands; only the JSON line is lost.
        emitStdout(io, "{\"ok\":false,\"error\":\"busy\",\"detail\":\"another rooms-peer lifecycle operation is active\"}\n") catch {};
        return if (err == error.Busy) error.PeerFailed else err;
    };
    defer lifecycle.unlock();

    var exe_buf: [4096]u8 = undefined;
    const exe = selfExePath(io, &exe_buf) catch |err| {
        try emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"executable\",\"detail\":\"{s}\"}}\n", .{@errorName(err)});
        return error.PeerFailed;
    };

    // Idempotent: never launch a second peer for a live lease. A stale PID is
    // disposable; a held lease with an unreadable/dead PID is not safe to adopt.
    switch (try observeProcess(io, gpa, dir)) {
        .running => |pid| {
            try waitJoinedAndReport(io, gpa, exe, dir, flags.nick, flags.room, pid, false);
            return;
        },
        .unconfirmed => {
            try emitStdout(io, "{\"ok\":false,\"error\":\"peer-identity\",\"detail\":\"peer lease is held but its PID cannot be confirmed; inspect peer.out and stop manually\"}\n");
            return error.PeerFailed;
        },
        .none => {},
    }

    // Spawn path only (an adopted live pid keeps its own state): reset
    // state.json before the spawn so the join wait below observes only this
    // daemon's progress — a dead-pid restart must not report ok off the
    // previous run's stale "joined" bytes.
    try writeState(io, gpa, dir, "starting", flags.nick, flags.room, bootstrap, false, 0);

    // Raw daemon stdout/stderr (a startup crash before state.json) land here.
    var out_path_buf: [512]u8 = undefined;
    const out_path = try pathIn(&out_path_buf, dir, "peer.out");
    const out_file = Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true }) catch {
        try emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"peer-out\",\"detail\":\"could not open peer.out\"}}\n", .{});
        return error.PeerFailed;
    };

    var child_env = try init.environ_map.clone(gpa);
    defer child_env.deinit();
    // PANCAKE_ROOMS_PEER_SUPERVISED is set only on this detached child, so `peer` refuses
    // any other launch path.
    try child_env.put("PANCAKE_ROOMS_PEER_SUPERVISED", "1");

    // Always `pancake app rooms-peer peer` — the `rooms-peer` install name is a thin
    // exec shim (cli/rooms_peer_shim.zig), so `selfExe` is the product binary.
    var argv_buf: [16][]const u8 = undefined;
    var n: usize = 0;
    argv_buf[n] = exe;
    n += 1;
    argv_buf[n] = "app";
    n += 1;
    argv_buf[n] = "rooms-peer";
    n += 1;
    argv_buf[n] = "peer";
    n += 1;
    argv_buf[n] = "--dir";
    n += 1;
    argv_buf[n] = dir;
    n += 1;
    argv_buf[n] = "--nick";
    n += 1;
    argv_buf[n] = flags.nick;
    n += 1;
    argv_buf[n] = "--room";
    n += 1;
    argv_buf[n] = flags.room;
    n += 1;
    argv_buf[n] = "--locator";
    n += 1;
    argv_buf[n] = bootstrap;
    n += 1;
    if (flags.identity.len > 0) {
        argv_buf[n] = "--identity";
        n += 1;
        argv_buf[n] = flags.identity;
        n += 1;
    }
    const argv = argv_buf[0..n];
    const child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &child_env,
        .stdin = .ignore,
        .stdout = .{ .file = out_file },
        .stderr = .{ .file = out_file },
    }) catch |err| {
        out_file.close(io);
        try emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"spawn\",\"detail\":\"{s}\"}}\n", .{@errorName(err)});
        return error.PeerFailed;
    };
    out_file.close(io);
    // Do not wait: the peer detached (setsid) and reparents to init. A reaping
    // init (tini/systemd) collects it on exit; under a bare-container PID 1 it
    // lingers as a harmless zombie table entry until container teardown.
    const pid: i32 = @intCast(child.id orelse 0);
    var reported = false;
    defer if (!reported) switch (processLiveness(io, pid)) {
        .running => _ = stopPeerPid(io, gpa, dir, pid) catch |err|
            log.err(io, "failed to stop peer after startup observer failure: {s}", .{@errorName(err)}),
        .absent => {},
        .unknown => log.err(io, "peer liveness became unobservable after startup failure; peer.pid retained", .{}),
    };
    try waitJoinedAndReport(io, gpa, exe, dir, flags.nick, flags.room, pid, true);
    reported = true;
}

fn waitJoinedAndReport(io: Io, gpa: Allocator, exe: []const u8, dir: []const u8, nick: []const u8, room: []const u8, pid: i32, started: bool) !void {
    var waited: u64 = 0;
    const join_deadline_ms: u64 = 45_000;
    // Presence (subscribe) and DM introducibility (register) are different
    // capabilities; wait for join first, then briefly for register.
    const register_grace_ms: u64 = 15_000;
    var joined_at: ?u64 = null;
    while (waited < join_deadline_ms + register_grace_ms) {
        const status = stateField(io, gpa, dir, "status") catch |err|
            return stateReadFailure(io, err);
        defer gpa.free(status);
        if (std.mem.eql(u8, status, "joined")) {
            if (joined_at == null) joined_at = waited;
            const registered = stateField(io, gpa, dir, "registered") catch |err|
                return stateReadFailure(io, err);
            defer gpa.free(registered);
            const is_reg = std.mem.eql(u8, registered, "true");
            const grace_done = waited - joined_at.? >= register_grace_ms;
            if (is_reg or grace_done) {
                const locator = stateField(io, gpa, dir, "locator") catch |err|
                    return stateReadFailure(io, err);
                defer gpa.free(locator);
                return reportStarted(io, gpa, exe, dir, nick, room, pid, started, locator, is_reg);
            }
        } else if (waited >= join_deadline_ms) {
            return failJoinTimeout(io, gpa, dir, pid, started);
        }
        switch (processLiveness(io, pid)) {
            .running => {},
            .unknown => {
                // best-effort: the failure return still lands; only the JSON line is lost.
                emitStdout(io, "{\"ok\":false,\"error\":\"peer-identity\",\"detail\":\"could not verify the peer process; peer.pid was retained\"}\n") catch {};
                return error.PeerFailed;
            },
            .absent => {
                const tail = readFile(io, gpa, dir, "peer.out") catch gpa.dupe(u8, "") catch "";
                defer gpa.free(tail);
                var doc = json.Document.init(gpa);
                defer doc.deinit();
                const bytes = buildPeerExited(&doc, tailOf(tail, 600)) catch return json.emitInternalError(io);
                try emitStdout(io, bytes);
                return error.PeerFailed;
            },
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(300), .real) catch |err| {
            // best-effort: the failure return still lands; only the JSON line is lost.
            emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"startup-wait\",\"detail\":\"{s}\"}}\n", .{@errorName(err)}) catch {};
            return error.PeerFailed;
        };
        waited += 300;
    }
    return failJoinTimeout(io, gpa, dir, pid, started);
}

fn buildPeerExited(doc: *json.Document, peer_out: []const u8) ![]const u8 {
    try doc.beginObject();
    try doc.boolean("ok", false);
    try doc.string("error", "peer-exited");
    try doc.string("detail", "peer exited during startup");
    try doc.string("peer_out", peer_out);
    try doc.end();
    return doc.line();
}

/// The `join_attempts` counter out of state.json. `stateField` extracts
/// strings and bools only, so the one numeric field gets its own read.
fn stateJoinAttempts(io: Io, gpa: Allocator, dir: []const u8) !u32 {
    const raw = readFile(io, gpa, dir, "state.json") catch |err| return err;
    defer gpa.free(raw);
    if (raw.len == 0) return 0;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.StateCorrupt,
    };
    defer parsed.deinit();
    if (parsed.value == .object) {
        if (parsed.value.object.get("join_attempts")) |v| {
            if (v == .integer and v.integer >= 0 and v.integer <= std.math.maxInt(u32)) {
                return @intCast(v.integer);
            }
        }
    }
    return error.StateCorrupt;
}

/// The join deadline passed. A peer this `start` spawned is stopped so a
/// never-joined daemon is not left as an orphan; an adopted pre-existing peer
/// is left running — it may be mid-outage on its own backoff, and this `start`
/// does not own it. The JSON detail says which happened; `status` and
/// `join_attempts` carry the peer's last observed phase and how many join
/// tries it has abandoned.
fn failJoinTimeout(io: Io, gpa: Allocator, dir: []const u8, pid: i32, started: bool) error{PeerFailed} {
    const status = stateField(io, gpa, dir, "status") catch |err|
        return stateReadFailure(io, err);
    defer gpa.free(status);
    const join_attempts = stateJoinAttempts(io, gpa, dir) catch |err|
        return stateReadFailure(io, err);
    var stop_error: ?[]const u8 = null;
    if (started) {
        _ = stopPeerPid(io, gpa, dir, pid) catch |err| {
            stop_error = @errorName(err);
            log.err(io, "failed to stop peer after join timeout: {s}", .{stop_error.?});
        };
    }
    var doc = json.Document.init(gpa);
    defer doc.deinit();
    const bytes = buildJoinTimeout(&doc, status, join_attempts, started, stop_error) catch return json.emitInternalError(io);
    emitStdout(io, bytes) catch return error.PeerFailed;
    return error.PeerFailed;
}

fn buildJoinTimeout(doc: *json.Document, status: []const u8, join_attempts: u32, started: bool, stop_error: ?[]const u8) ![]const u8 {
    try doc.beginObject();
    try doc.boolean("ok", false);
    try doc.string("error", "join-timeout");
    try doc.string("status", status);
    try doc.number("join_attempts", join_attempts);
    if (stop_error) |err| try doc.string("stop_error", err);
    try doc.string("detail", if (started)
        if (stop_error == null)
            "peer did not report joined in time and was stopped; check the locator and that the room is reachable"
        else
            "peer did not report joined in time; termination was not confirmed and peer.pid was retained"
    else
        "existing peer has not joined; left running (its own backoff may recover it) — rooms-peer stop if wedged");
    try doc.end();
    return doc.line();
}

fn tailOf(s: []const u8, n: usize) []const u8 {
    return if (s.len > n) s[s.len - n ..] else s;
}

pub fn peerCliPrefix(exe: []const u8) []const u8 {
    // Product binary is always `pancake` after the rooms-peer shim; keep a
    // basename check so a renamed install still emits copy-pasteable commands.
    return if (std.mem.eql(u8, std.fs.path.basename(exe), "pancake")) "app rooms-peer " else "";
}

fn reportStarted(
    io: Io,
    gpa: Allocator,
    exe: []const u8,
    dir: []const u8,
    nick: []const u8,
    room: []const u8,
    pid: i32,
    started: bool,
    locator: []const u8,
    registered: bool,
) error{PeerFailed}!void {
    var doc = json.Document.init(gpa);
    defer doc.deinit();
    const bytes = buildStarted(&doc, exe, dir, nick, room, pid, started, locator, registered) catch
        return json.emitInternalError(io);
    emitStdout(io, bytes) catch return error.PeerFailed;
}

fn buildStarted(
    doc: *json.Document,
    exe: []const u8,
    dir: []const u8,
    nick: []const u8,
    room: []const u8,
    pid: i32,
    started: bool,
    locator: []const u8,
    registered: bool,
) ![]const u8 {
    const prefix = peerCliPrefix(exe);
    // One scratch buffer for the three commands: each is escaped into the
    // document before the next overwrites it.
    var cb: [4608]u8 = undefined;
    try doc.beginObject();
    try doc.boolean("ok", true);
    try doc.boolean("started", started);
    try doc.number("pid", pid);
    try doc.string("nick", nick);
    try doc.string("room", room);
    try doc.string("locator", locator);
    try doc.boolean("registered", registered);
    try doc.string("dir", dir);
    try doc.string("loop_cmd", try std.fmt.bufPrint(&cb, "{s} {s}tick --dir {s} --wait 120", .{ exe, prefix, dir }));
    try doc.string("reply_cmd", try std.fmt.bufPrint(&cb, "{s} {s}reply --dir {s} --id <ID> --text '…'", .{ exe, prefix, dir }));
    try doc.string("stop_cmd", try std.fmt.bufPrint(&cb, "{s} {s}stop --dir {s}", .{ exe, prefix, dir }));
    try doc.string("next", "Run loop_cmd repeatedly and wait for each return (up to 120s): reply/dismiss pending, then loop. A durable member Task must not final-answer after arming tick — that orphans the wake. Run stop_cmd only when human/lead ends the session. registered=true means DM introduce works.");
    try doc.end();
    return doc.line();
}

// --- stop -------------------------------------------------------------------

/// What a stop attempt did: whether any signal was sent, and whether it
/// escalated to SIGKILL.
const StopOutcome = struct {
    sigkill: bool,
};

/// SIGTERM then SIGKILL a live peer pid. The PID sidecar is removed only after
/// death is observed; a signal or observation failure leaves ownership state
/// intact and returns an operational failure.
fn stopPeerPid(io: Io, gpa: Allocator, dir: []const u8, target: i32) !StopOutcome {
    if (processLiveness(io, target) != .running) return error.TerminationUnconfirmed;
    std.posix.kill(target, std.posix.SIG.TERM) catch |err| switch (err) {
        error.ProcessNotFound => if (pidAlive(io, gpa, target)) return error.SignalFailed,
        else => return error.SignalFailed,
    };
    var waited: u64 = 0;
    var liveness = processLiveness(io, target);
    while (waited < 6000 and liveness == .running) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .real) catch return error.TerminationWaitFailed;
        waited += 100;
        liveness = processLiveness(io, target);
    }
    if (liveness == .unknown) return error.TerminationUnconfirmed;
    var sigkill = false;
    if (liveness == .running) {
        sigkill = true;
        std.posix.kill(target, std.posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => if (pidAlive(io, gpa, target)) return error.SignalFailed,
            else => return error.SignalFailed,
        };
        var w2: u64 = 0;
        liveness = processLiveness(io, target);
        while (w2 < 3000 and liveness == .running) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .real) catch return error.TerminationWaitFailed;
            w2 += 100;
            liveness = processLiveness(io, target);
        }
    }
    if (liveness != .absent) return error.TerminationUnconfirmed;
    var path_buf: [512]u8 = undefined;
    const path = try pathIn(&path_buf, dir, "peer.pid");
    Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    return .{ .sigkill = sigkill };
}

pub fn runStop(init: std.process.Init, flags: Flags) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (flags.dir.len == 0) {
        try emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"usage\",\"detail\":\"stop needs --dir\"}}\n", .{});
        return error.UsageFailed;
    }
    const lifecycle = files.tryLockLeaf(io, flags.dir, "lifecycle") catch |err| {
        // best-effort: the failure return still lands; only the JSON line is lost.
        emitStdout(io, "{\"ok\":false,\"error\":\"busy\",\"detail\":\"another rooms-peer lifecycle operation is active\"}\n") catch {};
        return if (err == error.Busy) error.PeerFailed else err;
    };
    defer lifecycle.unlock();

    switch (try observeProcess(io, gpa, flags.dir)) {
        .none => {
            // Only an unlocked lease permits stale PID cleanup.
            var path_buf: [512]u8 = undefined;
            const path = try pathIn(&path_buf, flags.dir, "peer.pid");
            Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            try emitStdout(io, "{\"ok\":true,\"stopped\":false,\"detail\":\"no peer running for this dir\"}\n");
        },
        .unconfirmed => {
            try emitStdout(io, "{\"ok\":false,\"error\":\"peer-identity\",\"detail\":\"peer lease is held but its PID cannot be confirmed; peer.pid was retained\"}\n");
            return error.PeerFailed;
        },
        .running => |pid| {
            const outcome = stopPeerPid(io, gpa, flags.dir, pid) catch |err| {
                try emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"stop\",\"detail\":\"could not confirm peer termination: {s}\",\"pid\":{d}}}\n", .{ @errorName(err), pid });
                return error.PeerFailed;
            };
            try emitStdoutFmt(io, "{{\"ok\":true,\"stopped\":true,\"pid\":{d},\"sigkill\":{s}}}\n", .{
                pid,
                if (outcome.sigkill) "true" else "false",
            });
        },
    }
}
