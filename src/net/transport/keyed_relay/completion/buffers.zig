//! Retained byte storage for one completion-backed relay connection.
//!
//! Whole platform payloads remain borrowed. This module owns only split frame
//! tails, upgrade bytes, and bounded masked-send staging, including returning
//! burst capacity to the allocator once the live prefix becomes small again.

const std = @import("std");

const protocol = @import("../../../websocket/client_protocol.zig");

pub const steady_raw_in_bytes = protocol.max_header_len + protocol.max_control_payload;

pub fn rawBytes(c: anytype) []const u8 {
    return c.raw_in.items[c.raw_in_head..];
}

pub fn clearRaw(backend: anytype, c: anytype) void {
    c.raw_in.clearRetainingCapacity();
    c.raw_in_head = 0;
    if (c.raw_in.capacity > steady_raw_in_bytes) {
        c.raw_in.deinit(backend.allocator);
        c.raw_in = .empty;
    }
}

pub fn clearSend(backend: anytype, c: anytype) void {
    if (c.ws_out.capacity > backend.send_staging_bytes) {
        c.ws_out.deinit(backend.allocator);
        c.ws_out = .empty;
    } else {
        c.ws_out.clearRetainingCapacity();
    }
    c.ws_out_off = 0;
    c.ws_send_kind = .none;
}

pub fn appendRaw(backend: anytype, c: anytype, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    const live_len = rawBytes(c).len;
    if (bytes.len > backend.raw_in_limit -| live_len) return error.RelayInputOverflow;
    if (c.raw_in_head != 0 and bytes.len > c.raw_in.capacity - c.raw_in.items.len)
        compactRaw(c);
    // Geometric ArrayList growth would silently exceed the byte budget. Grow
    // this bounded spill precisely and append without another capacity policy.
    try c.raw_in.ensureTotalCapacityPrecise(backend.allocator, c.raw_in.items.len + bytes.len);
    c.raw_in.appendSliceAssumeCapacity(bytes);
}

/// Reserve a bounded tail that a byte transform can fill directly. This is
/// the secure carrier's plaintext destination: ciphertext is copied once into
/// the TLS record window, but decrypted bytes do not take an intermediate
/// staging copy before entering the shared WebSocket parser.
pub fn rawDestination(backend: anytype, c: anytype, max_bytes: usize) ![]u8 {
    const live_len = rawBytes(c).len;
    if (live_len == backend.raw_in_limit) return error.RelayInputOverflow;
    if (c.raw_in_head != 0) compactRaw(c);
    const target = @min(backend.raw_in_limit, c.raw_in.items.len + max_bytes);
    try c.raw_in.ensureTotalCapacityPrecise(backend.allocator, target);
    return c.raw_in.allocatedSlice()[c.raw_in.items.len..target];
}

pub fn commitRaw(c: anytype, count: usize) void {
    std.debug.assert(count <= c.raw_in.capacity - c.raw_in.items.len);
    c.raw_in.items.len += count;
}

pub fn appendUpgrade(backend: anytype, c: anytype, bytes: []const u8) !void {
    const needed = try std.math.add(usize, c.upgrade_buf.items.len, bytes.len);
    if (needed > protocol.max_upgrade_response_bytes) return error.UpgradeResponseTooLarge;
    try c.upgrade_buf.ensureTotalCapacityPrecise(backend.allocator, needed);
    c.upgrade_buf.appendSliceAssumeCapacity(bytes);
}

pub fn dropRaw(backend: anytype, c: anytype, count: usize) void {
    if (count == 0) return;
    std.debug.assert(count <= rawBytes(c).len);
    c.raw_in_head += count;
    const live = rawBytes(c);
    if (live.len == 0) return clearRaw(backend, c);
    if (live.len > steady_raw_in_bytes or c.raw_in.capacity <= steady_raw_in_bytes) return;

    // A coalesced read can leave a small frame after a large consumed prefix.
    // Compact it and release burst capacity instead of retaining a new floor.
    compactRaw(c);
    c.raw_in.shrinkAndFree(backend.allocator, live.len);
}

fn compactRaw(c: anytype) void {
    if (c.raw_in_head == 0) return;
    const live = rawBytes(c);
    std.mem.copyForwards(u8, c.raw_in.items[0..live.len], live);
    c.raw_in.shrinkRetainingCapacity(live.len);
    c.raw_in_head = 0;
}

/// Number of bytes from `incoming` through an HTTP header terminator,
/// including a marker split across the retained prefix and this read.
pub fn upgradeMarkerEnd(retained: []const u8, incoming: []const u8, marker: []const u8) ?usize {
    std.debug.assert(marker.len > 1);
    const retained_tail_len = @min(retained.len, marker.len - 1);
    const incoming_head_len = @min(incoming.len, marker.len - 1);
    var boundary: [6]u8 = undefined;
    std.debug.assert(marker.len * 2 - 2 <= boundary.len);
    @memcpy(boundary[0..retained_tail_len], retained[retained.len - retained_tail_len ..]);
    @memcpy(boundary[retained_tail_len..][0..incoming_head_len], incoming[0..incoming_head_len]);
    if (std.mem.indexOf(u8, boundary[0 .. retained_tail_len + incoming_head_len], marker)) |at| {
        const end_in_boundary = at + marker.len;
        if (end_in_boundary > retained_tail_len) return end_in_boundary - retained_tail_len;
    }
    if (std.mem.indexOf(u8, incoming, marker)) |at| return at + marker.len;
    return null;
}
