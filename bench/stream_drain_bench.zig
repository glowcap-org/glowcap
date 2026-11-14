//! The byte-fed connection drain over a pipelined stream cut into chunks.
//!
//! A connection loop hands `net.drainWholeFrames` each received chunk, and a
//! chunk rarely ends on a frame boundary, so the front of one frame waits in
//! the spill until the next chunk completes it. This bench feeds one warmed,
//! sans-io peer a stream of outer-framed inbound `op:deliver` frames in three
//! chunkings and drains the peer's events after every call, as the loop does:
//!
//!   - `aligned`: every chunk ends on a frame boundary, so the spill never
//!     activates. This is the floor.
//!   - `cut-4k`: 4096-byte chunks, so nearly every chunk ends inside a frame.
//!   - `cut-64k`: 65536-byte chunks.
//!
//! Each row prints `ns_per_frame`, `frames`, `chunk_bytes`, and
//! `spill_peak_bytes`, the largest spill buffer seen after any call. Run
//! `zig build bench-stream-drain` (use `-Doptimize=fast` for absolute figures)
//! or `zig build profile-stream-drain` for the instructions per phase. The
//! `--smoke` argument runs a small count.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");
const nowNs = @import("support/clock.zig").nowNs;
const profile = @import("support/profile.zig");
const warm_turn = @import("warm_turn");

const engine = glowcap.ocapn.engine;
const net = glowcap.net;
const stream_framing = glowcap.foundation.stream_framing;

const full_frames: usize = 200_000;
const smoke_frames: usize = 2_000;

/// One outer-framed warm deliver: the prefix, then the body.
fn frameBytes(buf: *[128]u8) []const u8 {
    const body = warm_turn.deliver_to_live_export;
    var prefix_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
    const prefix = stream_framing.renderPrefix(&prefix_buf, body.len);
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..body.len], body);
    return buf[0 .. prefix.len + body.len];
}

const Row = struct {
    name: [:0]const u8,
    /// The chunk size asked for. `aligned` rounds it down to whole frames.
    chunk_bytes: usize,
    aligned: bool = false,
};

const rows = [_]Row{
    .{ .name = "aligned", .chunk_bytes = 4096, .aligned = true },
    .{ .name = "cut-4k", .chunk_bytes = 4096 },
    .{ .name = "cut-64k", .chunk_bytes = 65536 },
};

/// Feed `stream` through the drain in `chunk_len` pieces, draining events after
/// every call. Returns the events drained and records the spill's peak buffer.
fn feedAll(peer: *engine.Peer, spill: *net.Spill, stream: []const u8, chunk_len: usize, allocator: std.mem.Allocator, peak: *usize) !usize {
    var events: usize = 0;
    var offset: usize = 0;
    while (offset < stream.len) {
        const end = @min(offset + chunk_len, stream.len);
        if (net.drainWholeFrames(peer, spill, stream[offset..end], allocator) != .ok) return error.DrainRefused;
        events += warm_turn.drainEvents(peer);
        peak.* = @max(peak.*, spill.buf.len);
        offset = end;
    }
    return events;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var smoke = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) smoke = true;
    }
    const frames: usize = if (smoke) smoke_frames else full_frames;

    var frame_buf: [128]u8 = undefined;
    const frame = frameBytes(&frame_buf);
    const stream = try allocator.alloc(u8, frame.len * frames);
    defer allocator.free(stream);
    for (0..frames) |i| @memcpy(stream[i * frame.len ..][0..frame.len], frame);

    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    try peer.exportObject(7);

    // Events one frame surfaces, so a bench that stops dispatching fails
    // instead of reporting a fast number.
    var probe_spill: net.Spill = .{};
    defer probe_spill.deinit(allocator);
    var probe_peak: usize = 0;
    const events_per_frame = try feedAll(&peer, &probe_spill, frame, frame.len, allocator, &probe_peak);
    if (events_per_frame == 0) return error.NothingDispatched;

    for (rows) |row| {
        const chunk_len = if (row.aligned) row.chunk_bytes / frame.len * frame.len else row.chunk_bytes;
        var spill: net.Spill = .{};
        defer spill.deinit(allocator);
        var peak: usize = 0;

        // One untimed pass so page faults and cold code land outside the window.
        _ = try feedAll(&peer, &spill, stream, chunk_len, allocator, &peak);
        peak = 0;

        profile.begin();
        const start = nowNs(io);
        const events = try feedAll(&peer, &spill, stream, chunk_len, allocator, &peak);
        const elapsed: f64 = @floatFromInt(nowNs(io) - start);
        profile.end(row.name.ptr);

        if (events != events_per_frame * frames or spill.isActive()) return error.DispatchCountMismatch;
        // A row runs the path it is named for: only a cut row uses the spill.
        if (row.aligned != (peak == 0)) return error.RowChunkingMismatch;
        std.debug.print(
            "stream_drain row={s} ns_per_frame={d:.2} frames={d} chunk_bytes={d} spill_peak_bytes={d} mode={s}\n",
            .{ row.name, elapsed / @as(f64, @floatFromInt(frames)), frames, chunk_len, peak, @tagName(builtin.optimize) },
        );
    }
}
