//! Live Goblins GC evidence: pancake introduces a near export into Goblins'
//! suite-echo actor and waits for inbound `op:gc-exports` naming that export.
//!
//! Mirrors the suite's `OpGcExportsTest` shape against a live Spritely Goblins
//! vat instead of the pancake conformance peer: fetch echo, deliver a
//! pancake-owned near object with no answer, pump until Goblins releases its
//! import of that export. This driver is evidence-only (no engine change of
//! its own); export-side promise listen ships separately under ADR-0007.
//!
//! Needs `racket` + the `goblins` collection on PATH; runs as the sibling step
//! `zig build goblins-gc`, not in the in-tree check. Compiling the driver is
//! still part of `check` so an API change cannot silently rot it.

const std = @import("std");
const pancake = @import("pancake");
const goblins_child = @import("goblins_child.zig");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const tcp = pancake.net.tcp;

const host = "127.0.0.1";
/// Default listen port for the Goblins host. `--port=N` overrides when taken.
const default_port_str = "22130";
const frame_cap: usize = 1 << 16;
/// Dedicated host: suite echo swiss plus a background `collect-garbage` loop so
/// CapTP's will-executor can emit `op:gc-exports` within the interop deadline.
const host_script = "conformance/goblins-peer/racket/gc-echo-host.rkt";
/// CapTP suite timeout for the same shape; Goblins GC waits on Racket wills.
const gc_deadline_ms: u64 = 15_000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var port_str: []const u8 = default_port_str;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            port_str = arg["--port=".len..];
            _ = std.fmt.parseInt(u16, port_str, 10) catch {
                std.debug.print("goblins-gc: --port must be an integer in 1..65535\n", .{});
                return error.BadPort;
            };
        } else {
            std.debug.print("goblins-gc: unknown argument '{s}'\n", .{arg});
            return error.BadArgument;
        }
    }

    var child = try std.process.spawn(io, .{
        .argv = &.{ goblins_child.racket_path, host_script, host, port_str },
        .environ_map = init.environ_map,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var reaped = false;
    defer if (!reaped) child.kill(io);

    const swiss = goblins_child.readPublishedSwiss(io, allocator, &child) catch |err| {
        std.debug.print("goblins-gc: never saw the echo cap readiness line: {s}\n", .{@errorName(err)});
        goblins_child.dumpChildStderr(io, "goblins-gc", &child);
        return err;
    };
    defer allocator.free(swiss);
    std.debug.print("goblins-gc: goblins published echo swiss={s} on {s}:{s}\n", .{ swiss, host, port_str });

    try proveExportGc(io, allocator, swiss, port_str);

    child.kill(io);
    reaped = true;
    std.debug.print("goblins-gc: OK — inbound op:gc-exports from live Goblins after echo consumed a near export\n", .{});
}

fn proveExportGc(
    io: std.Io,
    allocator: std.mem.Allocator,
    swiss: []const u8,
    port_str: []const u8,
) !void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const port_num = try std.fmt.parseInt(u16, port_str, 10);
    const designator_addr = try tcp.parseHostPort(host, port_num);
    const dial = tcp.locator(&designator_buf, designator_addr);
    var conn = try tcp.connect(io, &peer, dial, read_buf, write_buf, .{});
    defer conn.deinit();

    _ = try goblins_child.openKeyedSession(io, &peer, &conn, dial.designator);
    std.debug.print("goblins-gc: session open\n", .{});

    const echo = try goblins_child.fetchCap(allocator, &peer, &conn, swiss);
    defer model.freeReference(allocator, echo);
    std.debug.print("goblins-gc: fetched goblins echo; introducing a near export\n", .{});

    // Suite shape: introduce a local object into echo with no answer. Goblins
    // holds the import only for the echo turn, then releases it with
    // op:gc-exports naming our export position.
    const export_pos = try peer.exportNextObject();
    try peer.sendCopying(.{ .deliver = .{
        .target = echo,
        .args = &.{.{ .reference = .{ .near = .{ .export_position = model.ExportPosition.from(export_pos) } } }},
        .answer = null,
    } });

    var seen_delta: u64 = 0;
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = std.Io.Duration.fromMilliseconds(gc_deadline_ms),
        .clock = .real,
    });
    while (seen_delta < 1) {
        if (std.Io.Clock.Timestamp.now(io, .real).compare(.gte, deadline)) {
            std.debug.print(
                "goblins-gc: timed out waiting for inbound op:gc-exports naming export {d} (seen delta {d})\n",
                .{ export_pos, seen_delta },
            );
            return error.GcNeverArrived;
        }
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view() catch continue;
            if (body != .gc_export) continue;
            const gc = body.gc_export;
            const n = try gc.positions.len();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if ((try gc.positions.at(i)) == export_pos) {
                    seen_delta += try gc.deltas.at(i);
                }
            }
        }
        if (progress == .closed and seen_delta < 1) return error.GcNeverArrived;
    }
    std.debug.print(
        "goblins-gc: inbound op:gc-exports named export {d} with cumulative delta {d}\n",
        .{ export_pos, seen_delta },
    );
}
