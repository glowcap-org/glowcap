//! The drained half of the live trace: a bounded ring an embedder pops from,
//! for embedders that cannot hand the library a C function pointer.
//!
//! `pancake_host_set_trace` reports each fact through a callback, which is
//! what a native embedder wants — synchronous, allocation-free, and exact.
//! A browser cannot take that seam: the wasm module admits exactly the fixed
//! behavior and hosted-retirement callback imports (`zig build
//! wasm-import-check` holds that set), so a trace callback has nowhere to land.
//! What such an embedder already does have is the action queue: the host
//! surfaces its effects as rows the embedder drains on its own schedule
//! (`pancake_host_next_action`). This is the same shape for the same reason.
//!
//! It is a separate queue from the action queue, and deliberately so. An
//! action is a promise the host must keep, so the action FIFO reserves
//! capacity ahead of every push and can never refuse one
//! (`host_action.reserveActions`). A trace record is an observation: it must
//! never make the protocol wait, fail a send, or grow without bound. So this
//! ring is fixed at install, refuses nothing, and drops instead — counting
//! what it dropped so a consumer reads a gap rather than inventing continuity.
//!
//! Storage is two allocations, both made at install and neither resized: the
//! slot array, and one payload block the slots carve fixed windows out of.
//! With no queue installed the host carries one null pointer.

const std = @import("std");

const driver_core = @import("driver_core");

const c = @import("mod.zig");
const common = @import("common.zig");
const shared = @import("c_abi_shared");

/// One captured fact. The byte fields index this slot's payload window, since
/// the emit site's views die when the callback returns.
const Slot = struct {
    kind: u32 = 0,
    session: u64 = 0,
    outbound: u8 = 0,
    provenance: u32 = c.PANCAKE_DURABLE_PROVENANCE_UNAUTHENTICATED,
    codec: u32 = 0,
    captp_version: u32 = 0,
    /// Byte counts, in payload order: designator, transport, session id,
    /// verb, frame. The two halves of the locator sit together, as they
    /// are read.
    designator_len: usize = 0,
    transport_len: usize = 0,
    session_id_len: usize = 0,
    verb_len: usize = 0,
    /// What was captured of the frame; `frame_total` is how long it really was.
    frame_len: usize = 0,
    frame_total: usize = 0,
    /// Records dropped between the previous captured record and this one.
    dropped: u64 = 0,
    /// The message's wire-bytes tag. Fixed width, so it rides the slot itself
    /// rather than the payload window a clipped frame competes for: the tag is
    /// what lets a consumer fold two observers' sightings of one message
    /// together, and clipping it would defeat that exactly when payload
    /// capture is turned down.
    digest: [c.PANCAKE_TRACE_DIGEST_BYTES]u8 = @splat(0),
};

/// A fixed ring of captured trace records.
pub const TraceQueue = struct {
    slots: []Slot,
    /// `slots.len * payload_cap` bytes; slot `i` owns the window at
    /// `i * payload_cap`.
    payload: []u8,
    payload_cap: usize,
    head: usize = 0,
    len: usize = 0,
    /// Records dropped since the last one that was captured; folded into the
    /// next captured record's `dropped` so the count reaches the consumer
    /// attached to the gap it describes.
    pending_dropped: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        capacity: usize,
        payload_cap: usize,
    ) !TraceQueue {
        const payload_bytes = std.math.mul(usize, capacity, payload_cap) catch
            return error.SizeOverflow;
        const slots = try allocator.alloc(Slot, capacity);
        errdefer allocator.free(slots);
        const payload = try allocator.alloc(u8, payload_bytes);
        return .{ .slots = slots, .payload = payload, .payload_cap = payload_cap };
    }

    pub fn deinit(self: *TraceQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        allocator.free(self.slots);
        self.* = undefined;
    }

    fn window(self: *TraceQueue, index: usize) []u8 {
        const start = index * self.payload_cap;
        return self.payload[start .. start + self.payload_cap];
    }

    /// Capture one fact. A full ring drops the NEWEST record rather than the
    /// oldest: the oldest is the causal prefix a consumer keys everything
    /// else by — a lost `session-open` mis-files every message after it,
    /// where a lost tail is just a gap. The drop is counted either way.
    pub fn push(self: *TraceQueue, event: driver_core.trace.Event) void {
        if (self.len == self.slots.len) {
            self.pending_dropped +|= 1;
            return;
        }
        const index = (self.head + self.len) % self.slots.len;
        const buf = self.window(index);
        var slot: Slot = .{ .dropped = self.pending_dropped };
        var used: usize = 0;
        // Copy as much of each borrowed view as the window still holds, in
        // payload order. Truncation is visible: a short `frame_len` beside a
        // true `frame_total` says the bytes were clipped, never that the
        // frame was small.
        const take = struct {
            fn copy(dst: []u8, cursor: *usize, src: []const u8) usize {
                const room = dst.len - cursor.*;
                const n = @min(room, src.len);
                @memcpy(dst[cursor.* .. cursor.* + n], src[0..n]);
                cursor.* += n;
                return n;
            }
        }.copy;
        switch (event) {
            .session_open => |open| {
                slot.kind = c.PANCAKE_TRACE_SESSION_OPEN;
                slot.session = open.session.int();
                slot.provenance = common.provenanceToC(open.provenance);
                slot.codec = shared.codecToC(open.codec);
                slot.captp_version = shared.captpVersionToC(open.captp_version);
                slot.designator_len = take(buf, &used, open.designator);
                slot.transport_len = take(buf, &used, open.transport);
                slot.session_id_len = take(buf, &used, open.session_id);
            },
            .message => |msg| {
                slot.kind = c.PANCAKE_TRACE_MESSAGE;
                slot.session = msg.session.int();
                slot.outbound = @intFromBool(msg.outbound);
                slot.verb_len = take(buf, &used, msg.verb);
                slot.digest = msg.digest;
                slot.frame_total = msg.frame.len;
                slot.frame_len = take(buf, &used, msg.frame);
            },
            .session_close => |close| {
                slot.kind = c.PANCAKE_TRACE_SESSION_CLOSE;
                slot.session = close.session.int();
            },
        }
        self.slots[index] = slot;
        self.len += 1;
        self.pending_dropped = 0;
    }

    /// Fill `out` from the oldest captured record and drop it from the ring.
    /// The byte views point into this queue's payload block and stay valid
    /// until the next pop overwrites that window, the same until-the-next-pop
    /// borrow `pancake_host_next_action` carries. False when empty.
    pub fn pop(self: *TraceQueue, out: *c.PancakeTraceEvent) bool {
        if (self.len == 0) return false;
        const index = self.head;
        const slot = self.slots[index];
        const buf = self.window(index);
        var cursor: usize = 0;
        const view = struct {
            fn slice(src: []u8, cursor_ptr: *usize, len: usize) ?[*]const u8 {
                if (len == 0) return null;
                const start = cursor_ptr.*;
                cursor_ptr.* += len;
                return src[start..].ptr;
            }
        }.slice;
        out.* = .{
            .kind = slot.kind,
            .session = slot.session,
            .outbound = slot.outbound,
            .provenance = slot.provenance,
            .codec = slot.codec,
            .captp_version = slot.captp_version,
            .designator = view(buf, &cursor, slot.designator_len),
            .designator_len = slot.designator_len,
            .transport = view(buf, &cursor, slot.transport_len),
            .transport_len = slot.transport_len,
            .session_id = view(buf, &cursor, slot.session_id_len),
            .session_id_len = slot.session_id_len,
            .verb = view(buf, &cursor, slot.verb_len),
            .verb_len = slot.verb_len,
            .frame = view(buf, &cursor, slot.frame_len),
            .frame_len = slot.frame_len,
            .frame_total_len = slot.frame_total,
            .dropped = slot.dropped,
            .digest = slot.digest,
        };
        self.head = (self.head + 1) % self.slots.len;
        self.len -= 1;
        return true;
    }
};
