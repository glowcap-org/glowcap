//! Start/stop supervision for `pancake app rooms-peer`.
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

const pathIn = harness.pathIn;
const readFile = harness.readFile;
const removeFile = harness.removeFile;
const stateField = harness.stateField;
const writeJsonString = harness.writeJsonString;

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

/// Resolve a CapTP dial target. An `http(s)://…/locator` bootstrap is fetched
/// and its first line taken as the `ocapn://` URI (the rooms web UI serves it);
/// an `ocapn://` URI or bare designator passes through. Returns an owned string.
fn resolveLocator(io: Io, gpa: Allocator, locator: []const u8) ![]u8 {
    const is_http = std.mem.startsWith(u8, locator, "http://") or std.mem.startsWith(u8, locator, "https://");
    if (!is_http) return gpa.dupe(u8, locator);

    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();
    var body = std.Io.Writer.Allocating.init(gpa);
    defer body.deinit();
    const result = client.fetch(.{ .location = .{ .url = locator }, .response_writer = &body.writer }) catch {
        return error.BootstrapFailed;
    };
    if (result.status != .ok) return error.BootstrapFailed;
    const text = body.writer.buffered();
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = std.mem.trim(u8, lines.next() orelse "", " \t\r\n");
    if (first.len == 0) return error.BootstrapEmpty;
    return gpa.dupe(u8, first);
}

fn absDir(io: Io, gpa: Allocator, dir: []const u8) []u8 {
    if (dir.len > 0 and dir[0] == '/') return gpa.dupe(u8, dir) catch @constCast(dir);
    var buf: [4096]u8 = undefined;
    const n = std.process.currentPath(io, &buf) catch return gpa.dupe(u8, dir) catch @constCast(dir);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ buf[0..n], dir }) catch gpa.dupe(u8, dir) catch @constCast(dir);
}

pub fn runStart(init: std.process.Init, flags: Flags) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (flags.nick.len == 0 or flags.dir.len == 0) {
        emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"usage\",\"detail\":\"start needs --dir and --nick\"}}\n", .{});
        return error.UsageFailed;
    }
    const dir = absDir(io, gpa, flags.dir);
    defer gpa.free(dir);
    const bootstrap = if (flags.locator.len > 0) flags.locator else default_locator;
    const locator = resolveLocator(io, gpa, bootstrap) catch |err| {
        emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"locator\",\"detail\":\"could not resolve {s}: {s}\"}}\n", .{ bootstrap, @errorName(err) });
        return error.PeerFailed;
    };
    defer gpa.free(locator);
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
    argv_buf[n] = locator;
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
    const deadline_ms: u64 = 45_000;
    while (waited < deadline_ms) {
        const status = stateField(io, gpa, dir, "status");
        defer gpa.free(status);
        if (std.mem.eql(u8, status, "joined")) {
            const locator = stateField(io, gpa, dir, "locator");
            defer gpa.free(locator);
            reportStarted(io, gpa, exe, dir, nick, room, pid, started, locator);
            return;
        }
        if (!pidAlive(io, gpa, pid)) {
            const tail = readFile(io, gpa, dir, "peer.out") catch gpa.dupe(u8, "") catch "";
            defer gpa.free(tail);
            var esc: std.ArrayList(u8) = .empty;
            defer esc.deinit(gpa);
            writeJsonString(&esc, gpa, tailOf(tail, 600)) catch {};
            emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"peer-exited\",\"detail\":\"peer exited during startup\",\"peer_out\":{s}}}\n", .{esc.items});
            return error.PeerFailed;
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(300), .real) catch {};
        waited += 300;
    }
    emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"join-timeout\",\"detail\":\"peer did not report joined in time; check the locator and that the room is reachable\"}}\n", .{});
    return error.PeerFailed;
}

fn tailOf(s: []const u8, n: usize) []const u8 {
    return if (s.len > n) s[s.len - n ..] else s;
}

pub fn peerCliPrefix(exe: []const u8) []const u8 {
    // Product binary is always `pancake` after the rooms-peer shim; keep a
    // basename check so a renamed install still emits copy-pasteable commands.
    return if (std.mem.eql(u8, std.fs.path.basename(exe), "pancake")) "app rooms-peer " else "";
}

fn reportStarted(io: Io, gpa: Allocator, exe: []const u8, dir: []const u8, nick: []const u8, room: []const u8, pid: i32, started: bool, locator: []const u8) void {
    const prefix = peerCliPrefix(exe);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "{\"ok\":true,\"started\":") catch {};
    out.appendSlice(gpa, if (started) "true" else "false") catch {};
    out.appendSlice(gpa, ",\"pid\":") catch {};
    var pb: [16]u8 = undefined;
    out.appendSlice(gpa, std.fmt.bufPrint(&pb, "{d}", .{pid}) catch "0") catch {};
    out.appendSlice(gpa, ",\"nick\":") catch {};
    writeJsonString(&out, gpa, nick) catch {};
    out.appendSlice(gpa, ",\"room\":") catch {};
    writeJsonString(&out, gpa, room) catch {};
    out.appendSlice(gpa, ",\"locator\":") catch {};
    writeJsonString(&out, gpa, locator) catch {};
    out.appendSlice(gpa, ",\"dir\":") catch {};
    writeJsonString(&out, gpa, dir) catch {};
    var cb: [4608]u8 = undefined;
    out.appendSlice(gpa, ",\"loop_cmd\":") catch {};
    writeJsonString(&out, gpa, std.fmt.bufPrint(&cb, "{s} {s}tick --dir {s} --wait 20", .{ exe, prefix, dir }) catch "") catch {};
    out.appendSlice(gpa, ",\"reply_cmd\":") catch {};
    writeJsonString(&out, gpa, std.fmt.bufPrint(&cb, "{s} {s}reply --dir {s} --id <ID> --text '…'", .{ exe, prefix, dir }) catch "") catch {};
    out.appendSlice(gpa, ",\"stop_cmd\":") catch {};
    writeJsonString(&out, gpa, std.fmt.bufPrint(&cb, "{s} {s}stop --dir {s}", .{ exe, prefix, dir }) catch "") catch {};
    out.appendSlice(gpa, ",\"next\":") catch {};
    writeJsonString(&out, gpa, "Run loop_cmd repeatedly: it returns pending messages (waits up to 20s); reply to each with its prefilled reply command, then loop. Do your own work between ticks. Run stop_cmd when done.") catch {};
    out.append(gpa, '}') catch {};
    emitStdoutFmt(io, "{s}\n", .{out.items});
}

// --- stop -------------------------------------------------------------------

pub fn runStop(init: std.process.Init, flags: Flags) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (flags.dir.len == 0) {
        emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"usage\",\"detail\":\"stop needs --dir\"}}\n", .{});
        return error.UsageFailed;
    }
    const pid = readPid(io, gpa, flags.dir);
    if (pid == null or !pidAlive(io, gpa, pid.?)) {
        removeFile(io, flags.dir, "peer.pid");
        emitStdoutFmt(io, "{{\"ok\":true,\"stopped\":false,\"detail\":\"no peer running for this dir\"}}\n", .{});
        return;
    }
    const target = pid.?;
    std.posix.kill(target, std.posix.SIG.TERM) catch {};
    // Give the clean SIGTERM path a few seconds before escalating.
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
    removeFile(io, flags.dir, "peer.pid");
    emitStdoutFmt(io, "{{\"ok\":true,\"stopped\":true,\"pid\":{d},\"sigkill\":{s}}}\n", .{ target, if (sigkill) "true" else "false" });
}
