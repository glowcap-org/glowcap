//! Live Goblins GC evidence: glowcap introduces a near export into Goblins'
//! suite-echo actor and waits for inbound `op:gc-exports` naming that export.
//!
//! Mirrors the suite's `OpGcExportsTest` shape against a live Spritely Goblins
//! vat instead of the glowcap conformance peer: fetch echo, deliver a
//! glowcap-owned near object with no answer, pump until Goblins releases its
//! import of that export. This driver is evidence-only (no engine change of
//! its own); export-side promise listen ships separately under ADR-0007.
//!
//! Needs `racket` + the `goblins` collection on PATH; runs as the sibling step
//! `zig build goblins-gc`, not in the in-tree check. Compiling the driver is
//! still part of `check` so an API change cannot silently rot it.

const std = @import("std");
const glowcap = @import("glowcap");
const goblins_child = @import("goblins_child.zig");
const harness = @import("interop_harness");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const tcp = glowcap.net.tcp;

const host = "127.0.0.1";
/// Default listen port for the Goblins host. `--port=N` overrides when taken.
const default_port: u16 = 22130;
const frame_cap: usize = 1 << 16;
/// Dedicated host: suite echo swiss plus a background `collect-garbage` loop so
/// CapTP's will-executor can emit `op:gc-exports` within the interop deadline.
const host_script = "conformance/goblins-peer/racket/gc-echo-host.rkt";
/// CapTP suite timeout for the same shape; Goblins GC waits on Racket wills.
const gc_deadline_ms: u64 = 15_000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const port = try harness.parsePortFlag(init.minimal.args, "goblins-gc", default_port, .{});
    var port_buf: [8]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{port});

    const hosted = try goblins_child.spawnHostAwaitSwiss(io, allocator, init.environ_map, "goblins-gc", "echo cap", &.{ host_script, host, port_str });
    var child = hosted.child;
    var reaped = false;
    defer if (!reaped) child.kill(io);

    const swiss = hosted.swiss;
    defer allocator.free(swiss);
    std.debug.print("goblins-gc: goblins published echo swiss={s} on {s}:{s}\n", .{ swiss, host, port_str });

    try proveExportGc(io, allocator, swiss, port);

    child.kill(io);
    reaped = true;
    std.debug.print("goblins-gc: OK — inbound op:gc-exports from live Goblins after echo consumed a near export\n", .{});
}

fn proveExportGc(
    io: std.Io,
    allocator: std.mem.Allocator,
    swiss: []const u8,
    port: u16,
) !void {
    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();
    const peer = &scaffold.peer;

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const designator_addr = try tcp.parseHostPort(host, port);
    const dial = tcp.locatorFromAddress(&designator_buf, designator_addr);
    // Retry a refused dial briefly: the vat's readiness line can race its
    // listener's actual bind.
    var conn = try harness.tcpConnectRetry(io, peer, dial, scaffold.read_buf, scaffold.write_buf, 5_000);
    defer conn.deinit();

    _ = try goblins_child.openKeyedSession(io, peer, &conn, dial.designator);
    std.debug.print("goblins-gc: session open\n", .{});

    const echo = try goblins_child.fetchCap(allocator, peer, &conn, swiss);
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
    const deadline = harness.deadlineAfter(io, gc_deadline_ms);
    while (seen_delta < 1) {
        if (harness.expired(io, deadline)) {
            std.debug.print(
                "goblins-gc: timed out waiting for inbound op:gc-exports naming export {d} (seen delta {d})\n",
                .{ export_pos, seen_delta },
            );
            return error.GcNeverArrived;
        }
        const progress = try goblins_child.pumpPoll(&conn);
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view() catch |err| return err;
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
