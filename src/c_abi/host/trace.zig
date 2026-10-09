//! Trace configuration and projection for the byte-fed C ABI Host subject.
//!
//! Core trace events remain typed facts. This leaf owns their optional callback
//! and bounded-ring projections; the public archive symbols stay in `host.zig`.
//! Callback event views are borrowed for that call and may not re-enter a
//! Host-driving verb. The pull queue owns `capacity` fixed records with
//! `payload_cap` bytes each; overflow drops the newest fact and reports loss on
//! a later retained record, so observation never blocks protocol progress.
//! A popped record stays borrowed only until the next pop.

const driver_core = @import("driver_core");

const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const common = @import("common.zig");
const trace_queue = @import("trace_queue.zig");

pub fn setTrace(
    host: ?*c.GlowcapHost,
    callback: ?c.GlowcapTraceCallback,
    ctx: ?*anyopaque,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (callback == null and inst.trace_queue == null) {
        inst.core.setTrace(null) catch |err| return common.errToCode(err);
    } else {
        inst.core.setTrace(.{ .ctx = inst, .emit = traceEmit }) catch |err| return common.errToCode(err);
    }
    inst.trace_cb = callback;
    inst.trace_ctx = ctx;
    if (callback != null) inst.core.replayTrace() catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}

pub fn setTraceQueue(host: ?*c.GlowcapHost, capacity: usize, payload_cap: usize) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (capacity == 0) {
        if (inst.trace_cb == null)
            inst.core.setTrace(null) catch |err| return common.errToCode(err);
        if (inst.trace_queue) |queue| {
            queue.deinit(inst.allocator);
            inst.allocator.destroy(queue);
            inst.trace_queue = null;
        }
        return shared.GLOWCAP_OK;
    }
    if (payload_cap == 0) {
        shared.setLastError("host: set_trace_queue: payload_cap must be positive", .{});
        return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    const queue = inst.allocator.create(trace_queue.TraceQueue) catch |err|
        return common.errToCode(err);
    queue.* = trace_queue.TraceQueue.init(inst.allocator, capacity, payload_cap) catch |err| {
        inst.allocator.destroy(queue);
        if (err == error.SizeOverflow) {
            shared.setLastError("host: set_trace_queue: capacity times payload_cap overflows", .{});
            return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
        }
        return common.errToCode(err);
    };
    inst.core.setTrace(.{ .ctx = inst, .emit = traceEmit }) catch |err| {
        queue.deinit(inst.allocator);
        inst.allocator.destroy(queue);
        return common.errToCode(err);
    };
    const previous = inst.trace_queue;
    inst.trace_queue = queue;
    if (previous) |old| {
        old.deinit(inst.allocator);
        inst.allocator.destroy(old);
    }
    inst.core.replayTrace() catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}

pub fn nextTrace(host: ?*c.GlowcapHost, out: ?*c.GlowcapTraceEvent) i32 {
    const inst = common.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const slot = out orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const queue = inst.trace_queue orelse return shared.GLOWCAP_ERR_WOULD_BLOCK;
    if (!queue.pop(slot)) return shared.GLOWCAP_ERR_WOULD_BLOCK;
    return shared.GLOWCAP_OK;
}

fn traceEmit(ctx: ?*anyopaque, event: driver_core.trace.Event) void {
    const inst: *common.Instance = @ptrCast(@alignCast(ctx.?));
    if (inst.trace_queue) |queue| queue.push(event);
    const callback = inst.trace_cb orelse return;
    var out = c.GlowcapTraceEvent{
        .kind = 0,
        .session = 0,
        .outbound = 0,
        .provenance = c.GLOWCAP_DURABLE_PROVENANCE_UNAUTHENTICATED,
        .codec = shared.GLOWCAP_CODEC_UNKNOWN,
        .captp_version = shared.GLOWCAP_CAPTP_V1_0,
        .designator = null,
        .designator_len = 0,
        .transport = null,
        .transport_len = 0,
        .session_id = null,
        .session_id_len = 0,
        .verb = null,
        .verb_len = 0,
        .frame = null,
        .frame_len = 0,
        .frame_total_len = 0,
        .dropped = 0,
        .digest = @splat(0),
    };
    switch (event) {
        .session_open => |open| {
            out.kind = c.GLOWCAP_TRACE_SESSION_OPEN;
            out.session = open.session.int();
            out.provenance = common.provenanceToC(open.provenance);
            out.codec = shared.codecToC(open.codec);
            out.captp_version = shared.captpVersionToC(open.captp_version);
            out.designator = open.designator.ptr;
            out.designator_len = open.designator.len;
            out.transport = open.transport.ptr;
            out.transport_len = open.transport.len;
            if (open.session_id.len > 0) {
                out.session_id = open.session_id.ptr;
                out.session_id_len = open.session_id.len;
            }
        },
        .message => |message| {
            out.kind = c.GLOWCAP_TRACE_MESSAGE;
            out.session = message.session.int();
            out.outbound = @intFromBool(message.outbound);
            out.verb = message.verb.ptr;
            out.verb_len = message.verb.len;
            out.digest = message.digest;
            if (message.frame.len > 0) {
                out.frame = message.frame.ptr;
                out.frame_len = message.frame.len;
                out.frame_total_len = message.frame.len;
            }
        },
        .session_close => |close| {
            out.kind = c.GLOWCAP_TRACE_SESSION_CLOSE;
            out.session = close.session.int();
        },
    }
    callback(inst.trace_ctx, &out);
}
