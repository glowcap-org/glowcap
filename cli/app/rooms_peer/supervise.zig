//! Start/stop supervision, and the JSON emitter every rooms-peer verb reports
//! through, for `pancake app rooms-peer`.
const std = @import("std");
const signals = @import("../../operability/signals.zig");
const log = @import("../../operability/log.zig");
const common = @import("common.zig");
const harness = @import("harness.zig");
const Flags = @import("flags.zig").Flags;

const Io = common.Io;
const Allocator = common.Allocator;
const emitStdout = common.emitStdout;
const emitStdoutFmt = common.emitStdoutFmt;
const default_locator = common.default_locator;
const resolveLocator = common.resolveLocator;

const pathIn = harness.pathIn;
const readFile = harness.readFile;
const removeFile = harness.removeFile;
const stateField = harness.stateField;
const writeJsonString = harness.writeJsonString;
const writeState = harness.writeState;

// --- json emit --------------------------------------------------------------

/// One JSON document, built member by member. The braces, the commas, and the
/// string escaping are written here so an emitter names its fields instead of
/// spelling punctuation, and every method is fallible: a builder runs under
/// `try`, and its caller reports a single failure rather than a document that
/// stops mid-string.
///
/// Containers nest by `beginObject` / `arrayMember` and a matching `end`; the
/// depth this area needs is an object holding an array of objects.
pub const Json = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Whether the container open at each depth already holds a member.
    filled: [4]bool = @splat(false),
    /// The byte that closes the container open at each depth.
    closer: [4]u8 = @splat('}'),
    depth: usize = 0,

    pub fn init(gpa: Allocator) Json {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Json) void {
        self.buf.deinit(self.gpa);
    }

    /// Open an object: the document root, or one element of an open array.
    pub fn beginObject(self: *Json) !void {
        if (self.depth > 0) try self.separate();
        try self.push('{', '}');
    }

    /// Open an array-valued member. Elements follow until `end`.
    pub fn arrayMember(self: *Json, key: []const u8) !void {
        try self.member(key);
        try self.push('[', ']');
    }

    pub fn string(self: *Json, key: []const u8, value: []const u8) !void {
        try self.member(key);
        try writeJsonString(&self.buf, self.gpa, value);
    }

    pub fn boolean(self: *Json, key: []const u8, value: bool) !void {
        try self.member(key);
        try self.buf.appendSlice(self.gpa, if (value) "true" else "false");
    }

    pub fn number(self: *Json, key: []const u8, value: anytype) !void {
        try self.member(key);
        try self.buf.print(self.gpa, "{d}", .{value});
    }

    /// A value that is already JSON: `null`, or a document read off disk.
    pub fn rawValue(self: *Json, key: []const u8, value: []const u8) !void {
        try self.member(key);
        try self.buf.appendSlice(self.gpa, value);
    }

    /// Close the innermost container.
    pub fn end(self: *Json) !void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
        try self.buf.append(self.gpa, self.closer[self.depth]);
    }

    /// The finished document plus its trailing newline, ready for one write.
    /// Only a builder that reached here has a document worth emitting.
    pub fn line(self: *Json) ![]const u8 {
        std.debug.assert(self.depth == 0);
        try self.buf.append(self.gpa, '\n');
        return self.buf.items;
    }

    fn push(self: *Json, open: u8, close: u8) !void {
        std.debug.assert(self.depth < self.filled.len);
        try self.buf.append(self.gpa, open);
        self.filled[self.depth] = false;
        self.closer[self.depth] = close;
        self.depth += 1;
    }

    fn separate(self: *Json) !void {
        if (self.filled[self.depth - 1]) try self.buf.append(self.gpa, ',');
        self.filled[self.depth - 1] = true;
    }

    fn member(self: *Json, key: []const u8) !void {
        try self.separate();
        try writeJsonString(&self.buf, self.gpa, key);
        try self.buf.append(self.gpa, ':');
    }
};

/// The one failure door for a rooms-peer JSON emitter. A document that did not
/// build is reported as a whole, parseable error object and fails with the
/// internal exit code, so the agent reading this stdout never parses a
/// truncated document or takes a half report for success.
pub fn emitInternalError(io: Io) error{PeerFailed} {
    emitStdout(io, "{\"ok\":false,\"error\":\"internal\"}\n");
    return error.PeerFailed;
}

// --- start ------------------------------------------------------------------

/// Whether `pid` names a live process. A zombie (state `Z` — exited but not yet
/// reaped) reads as dead: under a non-reaping container init (`sleep infinity` as
/// PID 1) a cleanly-stopped daemon lingers as a zombie table entry, and treating
/// that as "up" would make `stop` escalate to SIGKILL against an already-dead
/// process and `status` misreport it. A reaping init (tini/systemd) clears the
/// entry outright, so this only matters in the bare-container case.
pub fn pidAlive(io: Io, gpa: Allocator, pid: i32) bool {
    _ = gpa;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return false;
    // /proc/<pid>/stat is a synthetic file that reports size 0, so a size-based
    // read gets nothing — read into a fixed buffer instead. Opening at all means
    // a table entry exists; the state token distinguishes live from zombie.
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var read_buf: [512]u8 = undefined;
    var fr = file.reader(io, &read_buf);
    var data_buf: [512]u8 = undefined;
    const n = fr.interface.readSliceShort(&data_buf) catch return true;
    const data = data_buf[0..n];
    // `comm` can hold spaces and parens, so the state is the token after the
    // last ')'.
    const rp = std.mem.lastIndexOfScalar(u8, data, ')') orelse return true;
    var i = rp + 1;
    while (i < data.len and data[i] == ' ') i += 1;
    if (i >= data.len) return true;
    const st = data[i];
    return st != 'Z' and st != 'X' and st != 'x';
}

/// The absolute path to this running binary, so a command we print for the
/// agent is copy-pasteable from any working directory. Falls back to the bare
/// name if `/proc/self/exe` cannot be read.
pub fn selfExePath(io: Io, buf: []u8) []const u8 {
    const n = Io.Dir.readLinkAbsolute(io, "/proc/self/exe", buf) catch return "pancake";
    return buf[0..n];
}

pub fn readPid(io: Io, gpa: Allocator, dir: []const u8) ?i32 {
    const text = readFile(io, gpa, dir, "peer.pid") catch return null;
    defer gpa.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i32, trimmed, 10) catch null;
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
        emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"usage\",\"detail\":\"start needs --dir and --nick\"}}\n", .{});
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
            emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"locator\",\"detail\":\"could not resolve {s}: {s}\"}}\n", .{ bootstrap, @errorName(err) });
            return error.PeerFailed;
        };
        gpa.free(probe);
    }
    Io.Dir.cwd().createDirPath(io, dir) catch {};

    var exe_buf: [4096]u8 = undefined;
    const exe = selfExePath(io, &exe_buf);

    // Idempotent: never launch a second peer for a live dir.
    if (readPid(io, gpa, dir)) |pid| {
        if (pidAlive(io, gpa, pid)) {
            try waitJoinedAndReport(io, gpa, exe, dir, flags.nick, flags.room, pid, false);
            return;
        }
    }

    // Spawn path only (an adopted live pid keeps its own state): reset
    // state.json before the spawn so the join wait below observes only this
    // daemon's progress — a dead-pid restart must not report ok off the
    // previous run's stale "joined" bytes.
    writeState(io, gpa, dir, "starting", flags.nick, flags.room, bootstrap, false, 0);

    // Raw daemon stdout/stderr (a startup crash before state.json) land here.
    var out_path_buf: [512]u8 = undefined;
    const out_path = pathIn(&out_path_buf, dir, "peer.out");
    const out_file = Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true }) catch {
        emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"peer-out\",\"detail\":\"could not open peer.out\"}}\n", .{});
        return error.PeerFailed;
    };

    var child_env = try init.environ_map.clone(gpa);
    defer child_env.deinit();
    // ROOMS_PEER_SUPERVISED is set only on this detached child, so `peer` refuses
    // any other launch path.
    try child_env.put("ROOMS_PEER_SUPERVISED", "1");

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
        emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"spawn\",\"detail\":\"{s}\"}}\n", .{@errorName(err)});
        return error.PeerFailed;
    };
    out_file.close(io);
    // Do not wait: the peer detached (setsid) and reparents to init. A reaping
    // init (tini/systemd) collects it on exit; under a bare-container PID 1 it
    // lingers as a harmless zombie table entry until container teardown.
    const pid: i32 = @intCast(child.id orelse 0);
    try waitJoinedAndReport(io, gpa, exe, dir, flags.nick, flags.room, pid, true);
}

fn waitJoinedAndReport(io: Io, gpa: Allocator, exe: []const u8, dir: []const u8, nick: []const u8, room: []const u8, pid: i32, started: bool) !void {
    var waited: u64 = 0;
    const join_deadline_ms: u64 = 45_000;
    // Presence (subscribe) and DM introducibility (register) are different
    // capabilities; wait for join first, then briefly for register.
    const register_grace_ms: u64 = 15_000;
    var joined_at: ?u64 = null;
    while (waited < join_deadline_ms + register_grace_ms) {
        const status = stateField(io, gpa, dir, "status");
        defer gpa.free(status);
        if (std.mem.eql(u8, status, "joined")) {
            if (joined_at == null) joined_at = waited;
            const registered = stateField(io, gpa, dir, "registered");
            defer gpa.free(registered);
            const is_reg = std.mem.eql(u8, registered, "true");
            const grace_done = waited - joined_at.? >= register_grace_ms;
            if (is_reg or grace_done) {
                const locator = stateField(io, gpa, dir, "locator");
                defer gpa.free(locator);
                return reportStarted(io, gpa, exe, dir, nick, room, pid, started, locator, is_reg);
            }
        } else if (waited >= join_deadline_ms) {
            return failJoinTimeout(io, gpa, dir, pid, started);
        }
        if (!pidAlive(io, gpa, pid)) {
            const tail = readFile(io, gpa, dir, "peer.out") catch gpa.dupe(u8, "") catch "";
            defer gpa.free(tail);
            var doc = Json.init(gpa);
            defer doc.deinit();
            const bytes = buildPeerExited(&doc, tailOf(tail, 600)) catch return emitInternalError(io);
            emitStdout(io, bytes);
            return error.PeerFailed;
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(300), .real) catch {};
        waited += 300;
    }
    return failJoinTimeout(io, gpa, dir, pid, started);
}

fn buildPeerExited(doc: *Json, peer_out: []const u8) ![]const u8 {
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
fn stateJoinAttempts(io: Io, gpa: Allocator, dir: []const u8) u32 {
    const raw = readFile(io, gpa, dir, "state.json") catch return 0;
    defer gpa.free(raw);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch return 0;
    defer parsed.deinit();
    if (parsed.value == .object) {
        if (parsed.value.object.get("join_attempts")) |v| {
            if (v == .integer and v.integer >= 0 and v.integer <= std.math.maxInt(u32)) {
                return @intCast(v.integer);
            }
        }
    }
    return 0;
}

/// The join deadline passed. A peer this `start` spawned is stopped so a
/// never-joined daemon is not left as an orphan; an adopted pre-existing peer
/// is left running — it may be mid-outage on its own backoff, and this `start`
/// does not own it. The JSON detail says which happened; `status` and
/// `join_attempts` carry the peer's last observed phase and how many join
/// tries it has abandoned.
fn failJoinTimeout(io: Io, gpa: Allocator, dir: []const u8, pid: i32, started: bool) error{PeerFailed} {
    const status = stateField(io, gpa, dir, "status");
    defer gpa.free(status);
    const join_attempts = stateJoinAttempts(io, gpa, dir);
    if (started) _ = stopPeerPid(io, gpa, dir, pid);
    var doc = Json.init(gpa);
    defer doc.deinit();
    const bytes = buildJoinTimeout(&doc, status, join_attempts, started) catch return emitInternalError(io);
    emitStdout(io, bytes);
    return error.PeerFailed;
}

fn buildJoinTimeout(doc: *Json, status: []const u8, join_attempts: u32, started: bool) ![]const u8 {
    try doc.beginObject();
    try doc.boolean("ok", false);
    try doc.string("error", "join-timeout");
    try doc.string("status", status);
    try doc.number("join_attempts", join_attempts);
    try doc.string("detail", if (started)
        "peer did not report joined in time and was stopped; check the locator and that the room is reachable"
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
    var doc = Json.init(gpa);
    defer doc.deinit();
    const bytes = buildStarted(&doc, exe, dir, nick, room, pid, started, locator, registered) catch
        return emitInternalError(io);
    emitStdout(io, bytes);
}

fn buildStarted(
    doc: *Json,
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
    try doc.string("loop_cmd", std.fmt.bufPrint(&cb, "{s} {s}tick --dir {s} --wait 120", .{ exe, prefix, dir }) catch "");
    try doc.string("reply_cmd", std.fmt.bufPrint(&cb, "{s} {s}reply --dir {s} --id <ID> --text '…'", .{ exe, prefix, dir }) catch "");
    try doc.string("stop_cmd", std.fmt.bufPrint(&cb, "{s} {s}stop --dir {s}", .{ exe, prefix, dir }) catch "");
    try doc.string("next", "Run loop_cmd repeatedly and wait for each return (up to 120s): reply/dismiss pending, then loop. A durable member Task must not final-answer after arming tick — that orphans the wake. Run stop_cmd only when human/lead ends the session. registered=true means DM introduce works.");
    try doc.end();
    return doc.line();
}

// --- stop -------------------------------------------------------------------

/// What a stop attempt did: whether any signal was sent, and whether it
/// escalated to SIGKILL.
const StopOutcome = struct {
    signaled: bool,
    sigkill: bool,
};

/// SIGTERM then SIGKILL a live peer pid and clear `peer.pid`.
fn stopPeerPid(io: Io, gpa: Allocator, dir: []const u8, target: i32) StopOutcome {
    if (!pidAlive(io, gpa, target)) {
        removeFile(io, dir, "peer.pid");
        return .{ .signaled = false, .sigkill = false };
    }
    std.posix.kill(target, std.posix.SIG.TERM) catch {};
    var waited: u64 = 0;
    while (waited < 6000 and pidAlive(io, gpa, target)) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
        waited += 100;
    }
    var sigkill = false;
    if (pidAlive(io, gpa, target)) {
        sigkill = true;
        std.posix.kill(target, std.posix.SIG.KILL) catch {};
        var w2: u64 = 0;
        while (w2 < 3000 and pidAlive(io, gpa, target)) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
            w2 += 100;
        }
    }
    removeFile(io, dir, "peer.pid");
    return .{ .signaled = true, .sigkill = sigkill };
}

pub fn runStop(init: std.process.Init, flags: Flags) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (flags.dir.len == 0) {
        emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"usage\",\"detail\":\"stop needs --dir\"}}\n", .{});
        return error.UsageFailed;
    }
    const pid = readPid(io, gpa, flags.dir) orelse {
        // Missing or unparseable pid file: clear it and report nothing to stop.
        removeFile(io, flags.dir, "peer.pid");
        emitStdoutFmt(io, "{{\"ok\":true,\"stopped\":false,\"detail\":\"no peer running for this dir\"}}\n", .{});
        return;
    };
    // stopPeerPid owns the dead-pid arm too (clears the stale pid file).
    const outcome = stopPeerPid(io, gpa, flags.dir, pid);
    if (!outcome.signaled) {
        emitStdoutFmt(io, "{{\"ok\":true,\"stopped\":false,\"detail\":\"no peer running for this dir\"}}\n", .{});
        return;
    }
    emitStdoutFmt(io, "{{\"ok\":true,\"stopped\":true,\"pid\":{d},\"sigkill\":{s}}}\n", .{
        pid,
        if (outcome.sigkill) "true" else "false",
    });
}
