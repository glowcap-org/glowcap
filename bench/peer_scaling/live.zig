//! Coordinator for the opt-in live socket scaling measurement.
//!
//! A server child and a load child keep descriptor limits and RSS accounting
//! independent. The server publishes one loopback listener per bounded reactor
//! shard; spreading connections across destination ports avoids confusing the
//! loopback ephemeral-port range with Glowcap capacity. A step is successful
//! only after every client has completed a signed handshake and fetched the
//! published capability while all server sessions remain open.

const std = @import("std");
const worker = @import("live_worker.zig");

pub const WorkerOptions = struct {
    server_total: ?usize = null,
    client_total: ?usize = null,
    shards: ?usize = null,
    ports: ?[]const u8 = null,

    pub fn active(self: WorkerOptions) bool {
        return self.server_total != null or self.client_total != null;
    }
};

pub fn parseWorkerArg(options: *WorkerOptions, arg: []const u8) !bool {
    if (std.mem.startsWith(u8, arg, "--live-server=")) {
        options.server_total = try std.fmt.parseInt(usize, arg["--live-server=".len..], 10);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--live-client=")) {
        options.client_total = try std.fmt.parseInt(usize, arg["--live-client=".len..], 10);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--live-shards=")) {
        options.shards = try std.fmt.parseInt(usize, arg["--live-shards=".len..], 10);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--live-ports=")) {
        options.ports = arg["--live-ports=".len..];
        return true;
    }
    return false;
}

pub fn runWorker(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: WorkerOptions,
) !void {
    if (options.server_total != null and options.client_total != null) return error.AmbiguousLiveWorker;
    if (options.server_total) |total| {
        if (options.ports != null) return error.AmbiguousLiveWorker;
        return worker.runServer(io, allocator, total, options.shards orelse return error.MissingLiveShards);
    }
    if (options.client_total) |total| {
        if (options.shards != null) return error.AmbiguousLiveWorker;
        const text = options.ports orelse return error.MissingLivePorts;
        var ports_buf: [64]u16 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, text, ',');
        while (it.next()) |part| {
            if (count == ports_buf.len or part.len == 0) return error.InvalidLivePorts;
            ports_buf[count] = try std.fmt.parseInt(u16, part, 10);
            count += 1;
        }
        return worker.runClient(io, allocator, total, ports_buf[0..count]);
    }
    return error.MissingLiveWorkerMode;
}

const Child = struct {
    process: std.process.Child,

    fn signal(self: *Child, io: std.Io) !void {
        const input = self.process.stdin orelse return error.MissingChildStdin;
        try input.writeStreamingAll(io, "release\n");
    }

    fn waitOk(self: *Child, io: std.Io) !void {
        const term = try self.process.wait(io);
        if (term != .exited or term.exited != 0) return error.LiveWorkerFailed;
    }
};

fn spawnChild(io: std.Io, argv: []const []const u8) !Child {
    var process = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    errdefer process.kill(io);
    if (process.stdout == null) return error.MissingChildStdout;
    return .{ .process = process };
}

fn readLine(io: std.Io, child: *Child, allocator: std.mem.Allocator) ![]const u8 {
    const output = child.process.stdout orelse return error.MissingChildStdout;
    var read_buf: [4096]u8 = undefined;
    var reader = output.reader(io, &read_buf);
    const raw = reader.interface.takeDelimiterInclusive('\n') catch
        return error.LiveWorkerExitedBeforeReady;
    return allocator.dupe(u8, std.mem.trimEnd(u8, raw, "\r\n"));
}

fn rssKb(io: std.Io, pid: std.process.Child.Id) u64 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch return 0;
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    var text_buf: [8192]u8 = undefined;
    var len: usize = 0;
    while (len < text_buf.len) {
        const n = reader.interface.readSliceShort(text_buf[len..]) catch break;
        if (n == 0) break;
        len += n;
    }
    const text = text_buf[0..len];
    const at = std.mem.indexOf(u8, text, "VmRSS:") orelse return 0;
    var i = at + "VmRSS:".len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    const start = i;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    return std.fmt.parseInt(u64, text[start..i], 10) catch 0;
}

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}

fn runStep(
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: []const u8,
    total: usize,
    requested_shards: usize,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shards = @min(total, requested_shards);

    const server_total = try std.fmt.allocPrint(arena, "--live-server={d}", .{total});
    const server_shards = try std.fmt.allocPrint(arena, "--live-shards={d}", .{shards});
    var server = try spawnChild(io, &.{ executable, server_total, server_shards });
    defer server.process.kill(io);
    const server_pid = server.process.id orelse return error.MissingChildPid;

    const ports_line = try readLine(io, &server, arena);
    if (!std.mem.startsWith(u8, ports_line, "PORTS ")) return error.InvalidServerReady;
    const ports = ports_line["PORTS ".len..];
    const server_rss_before = rssKb(io, server_pid);

    const client_total = try std.fmt.allocPrint(arena, "--live-client={d}", .{total});
    const client_ports = try std.fmt.allocPrint(arena, "--live-ports={s}", .{ports});
    const t0 = nowNs(io);
    var client = try spawnChild(io, &.{ executable, client_total, client_ports });
    defer client.process.kill(io);
    const client_pid = client.process.id orelse return error.MissingChildPid;
    const ready = try readLine(io, &client, arena);
    const expected = try std.fmt.allocPrint(arena, "CLIENT_READY {d}", .{total});
    if (!std.mem.eql(u8, ready, expected)) return error.InvalidClientReady;
    const elapsed_ns: u64 = @intCast(@max(nowNs(io) - t0, 0));
    const server_rss_after = rssKb(io, server_pid);
    const client_rss = rssKb(io, client_pid);
    const server_delta = server_rss_after -| server_rss_before;

    std.debug.print(
        "peer_scaling phase2 n={d} ok=true live={d} shards={d} " ++
            "server_rss_kb_before={d} server_rss_kb_after={d} " ++
            "server_rss_delta_kb={d} client_rss_kb={d} elapsed_ms={d} us_per_roundtrip={d:.1}\n",
        .{
            total,
            total,
            shards,
            server_rss_before,
            server_rss_after,
            server_delta,
            client_rss,
            elapsed_ns / 1_000_000,
            @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total)) / 1_000.0,
        },
    );

    try client.signal(io);
    try server.signal(io);
    try client.waitOk(io);
    try server.waitOk(io);
}

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: []const u8,
    smoke: bool,
    live_max: usize,
) !void {
    const schedule = [_]usize{ 1_000, 10_000, 50_000, 100_000, 500_000 };
    var ran = false;
    for (schedule) |total| {
        if (total > live_max) break;
        ran = true;
        try runStep(io, allocator, executable, total, if (smoke) 4 else 32);
    }
    if (!ran) {
        if (live_max == 0) {
            std.debug.print("peer_scaling phase2: skipped (live-max=0)\n", .{});
            return;
        }
        const tiny_max: usize = if (smoke) 8 else 64;
        try runStep(io, allocator, executable, @min(live_max, tiny_max), 4);
    }
}
