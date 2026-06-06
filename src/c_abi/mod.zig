//! The C ABI for `libpancake`. Deliberately boring.
//!
//! The thing that makes this layer easy to use is that ownership is right there in
//! the type names, so you never have to dig through comments to find it. A
//! `PancakeFrame` is borrowed: it's yours for the length of one call, and you keep
//! owning the bytes. A `PancakeManagedFrame` is owned and releases itself: it's
//! yours to keep, and you call its `release` exactly once when you're done. Return
//! codes are a plain `i32`, either `PANCAKE_OK` or a negative `PANCAKE_ERR_*`.
//! Handles like `PancakePeer` are opaque. And an event hands you back the original
//! wire frame, in whatever codec the session negotiated, with no re-encoding in
//! between.

const std = @import("std");

const foundation = @import("../foundation/mod.zig");
const model = @import("../model/mod.zig");
const engine = @import("../engine/mod.zig");
const net_adapter = @import("../net_adapter/mod.zig");

/// ABI version the library implements. While `major` is 0 the ABI is unstable
/// (see `pancake.h`); the shared library's soname tracks `major`.
pub const PANCAKE_VERSION_MAJOR: u32 = 0;
pub const PANCAKE_VERSION_MINOR: u32 = 1;
pub const PANCAKE_VERSION_PATCH: u32 = 0;

/// Report the ABI version the linked library implements. Any out-pointer may be
/// null to skip that component. Lets a consumer detect header/library skew by
/// comparing against the `PANCAKE_VERSION_*` macros it compiled against.
pub export fn pancake_abi_version(out_major: ?*u32, out_minor: ?*u32, out_patch: ?*u32) void {
    if (out_major) |p| p.* = PANCAKE_VERSION_MAJOR;
    if (out_minor) |p| p.* = PANCAKE_VERSION_MINOR;
    if (out_patch) |p| p.* = PANCAKE_VERSION_PATCH;
}

pub const PANCAKE_OK: i32 = 0;
pub const PANCAKE_ERR_NULL_POINTER: i32 = -1;
pub const PANCAKE_ERR_INVALID_HANDLE: i32 = -2;
/// A non-pointer argument was out of range or unparseable (e.g. a zero frame
/// cap, or a host string that is not an address). Distinct from `_NULL_POINTER`
/// (a required pointer was null) and `_IO` (the network itself failed).
pub const PANCAKE_ERR_INVALID_ARGUMENT: i32 = -3;
pub const PANCAKE_ERR_SESSION: i32 = -4;
pub const PANCAKE_ERR_CODEC: i32 = -5;
pub const PANCAKE_ERR_INTERNAL: i32 = -6;
pub const PANCAKE_ERR_WOULD_BLOCK: i32 = -7;
/// The peer closed the stream gracefully on a frame boundary (clean EOF).
pub const PANCAKE_ERR_CLOSED: i32 = -8;
/// An underlying socket read/write failed; `pancake_last_error` carries the
/// concrete cause.
pub const PANCAKE_ERR_IO: i32 = -9;
/// Inbound bytes were not a structurally valid frame.
pub const PANCAKE_ERR_MALFORMED: i32 = -10;
/// An inbound frame exceeded the endpoint's `max_frame_bytes`.
pub const PANCAKE_ERR_FRAME_TOO_LARGE: i32 = -11;
/// A typed `poll_event_*` was called but the next event is a different kind.
/// The event is left queued; route on `pancake_peer_peek_event` first.
pub const PANCAKE_ERR_WRONG_EVENT: i32 = -12;
/// A value handed across the typed surface uses a variant the C ABI does not yet
/// carry (a `set`/`tagged`/`handoff`/`keyword` argument, or a `sturdy`/`broken`
/// reference target). Refused loudly rather than dropped.
pub const PANCAKE_ERR_UNSUPPORTED_VALUE: i32 = -13;

/// Codec selector for endpoint framing (the grammar that delimits frames).
pub const PANCAKE_CODEC_SYRUP: u32 = 0;
pub const PANCAKE_CODEC_CAPNP: u32 = 1;

pub const PANCAKE_FRAME_SHAPE_BYTE: u32 = 0;
pub const PANCAKE_FRAME_SHAPE_WORD: u32 = 1;
pub const PANCAKE_EVENT_DELIVER: u32 = 1;
pub const PANCAKE_EVENT_RESOLVE: u32 = 2;
pub const PANCAKE_EVENT_GC_EXPORT: u32 = 3;
pub const PANCAKE_EVENT_GC_ANSWER: u32 = 4;
pub const PANCAKE_EVENT_HANDOFF: u32 = 5;
pub const PANCAKE_EVENT_START_SESSION: u32 = 6;
pub const PANCAKE_EVENT_ABORT: u32 = 7;
pub const PANCAKE_EVENT_LISTEN: u32 = 8;
pub const PANCAKE_EVENT_GET: u32 = 9;
pub const PANCAKE_EVENT_INDEX: u32 = 10;

/// A frame whose bytes are *borrowed* from the C caller for the duration of one
/// call. The engine reads them during the call and retains nothing; the caller
/// keeps ownership and frees them on its own schedule. Used for inbound feeds.
pub const PancakeFrame = extern struct {
    bytes: ?[*]const u8,
    len: usize,
    shape: u32,
};

/// Release hook a `PancakeManagedFrame` carries; the caller invokes it once to
/// free the frame.
pub const ReleaseFn = *const fn (*PancakeManagedFrame) callconv(.c) void;

/// A frame the engine *owns* and hands to the C caller (outbound frames, event
/// frames). It is self-describing and self-releasing: the caller must invoke
/// `release` exactly once to free it — never a host `free`.
pub const PancakeManagedFrame = extern struct {
    bytes: ?[*]u8,
    len: usize,
    shape: u32,
    release: ?ReleaseFn,
    private_data: ?*anyopaque,
};

pub const PancakeEvent = extern struct {
    kind: u32,
    frame: PancakeManagedFrame,
};

pub const PancakePeer = opaque {};

/// The allocator the *simple* C ABI path uses — the constructors that take no
/// `PancakeContext` (`pancake_peer_new`, `pancake_tcp_netlayer_new`) and
/// everything those handles own. `smp_allocator` is a thread-safe
/// general-purpose allocator: a managed frame per outbound message or event
/// costs an arena-style bump, not the `mmap`/`munmap` round-trip
/// `page_allocator` paid per frame on the wire path.
///
/// A caller that needs allocation policy creates a `PancakeContext` and uses the
/// `*_in` constructors instead; this default is the library-owned policy for the
/// callers that do not.
const library_allocator = std.heap.smp_allocator;

// ── Allocation context ───────────────────────────────────────────────────────
//
// `PancakeContext` is the explicit owner of allocation policy for a family of
// handles. `pancake_context_new_default` routes through `library_allocator`;
// `pancake_context_new_with_allocator` routes every allocation through host
// callbacks. Handles created *in* a context (`pancake_peer_new_in`,
// `pancake_tcp_netlayer_new_in`) and everything they own — managed outbound and
// event frames, adopted inbound frames, TCP connection/listener payloads and
// their read/write buffers — allocate and free through that one context. C
// callers still free only through the explicit release functions; the context is
// the policy, never a `free` a caller invokes by hand.
//
// Lifetime: the context must outlive every handle created in it. A host-backed
// context's allocator vtable lives inside the context object, so the handles
// borrow it; releasing the context first would dangle that borrow. The context
// object itself is allocated through the host allocator, so a host-backed
// handle family — context included — frees entirely through host policy.

/// Host allocation callbacks (`pancake_context_new_with_allocator`). `alloc`
/// returns memory aligned to `alignment` (a power of two) or null on failure;
/// `free` receives the same `size`/`alignment` the allocation was made with.
/// `user_data` is passed back to every callback unchanged. The callbacks must be
/// thread-safe: a context backing a TCP netlayer is driven from its threaded I/O
/// backend.
///
/// The surface is deliberately `alloc` + `free` only. With both sides told the
/// size, the only sound resize policy for an opaque host allocator is "never
/// resize in place" (see `HostAllocator`), which keeps `free`'s size argument
/// exactly equal to `alloc`'s — correct even for a size-tracking host allocator.
/// A `realloc` callback cannot preserve that invariant or guarantee alignment of
/// the relocated block, so it is intentionally absent rather than a footgun.
pub const PancakeAllocFn = *const fn (user_data: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque;
pub const PancakeFreeFn = *const fn (user_data: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void;

/// Host allocator specification passed by value to
/// `pancake_context_new_with_allocator`. `alloc` and `free` are required;
/// `user_data` may be null.
pub const PancakeAllocator = extern struct {
    alloc: ?PancakeAllocFn,
    free: ?PancakeFreeFn,
    user_data: ?*anyopaque,
};

pub const PancakeContext = opaque {};

/// Adapts the C host allocation callbacks to a `std.mem.Allocator`. Heap-pinned
/// inside its `Context`, so the vtable's `ptr` (`&context.host`) stays valid for
/// the context's whole life.
const HostAllocator = struct {
    alloc_fn: PancakeAllocFn,
    free_fn: PancakeFreeFn,
    user_data: ?*anyopaque,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = hostAlloc,
        .resize = hostResize,
        .remap = hostRemap,
        .free = hostFree,
    };

    fn allocator(self: *HostAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn hostAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *HostAllocator = @ptrCast(@alignCast(ctx));
        const raw = self.alloc_fn(self.user_data, len, alignment.toByteUnits()) orelse return null;
        return @ptrCast(raw);
    }

    /// No in-place resize and no relocation: a grow becomes alloc-copy-free.
    /// This is the only sound policy for an opaque host allocator told the size
    /// on both `alloc` and `free` — it keeps every `free` size exactly equal to
    /// its `alloc` size, and never asks a relocated block to honor the original
    /// over-alignment (which a C `realloc` cannot promise).
    fn hostResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = .{ ctx, memory, alignment, new_len, ret_addr };
        return false;
    }

    fn hostRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = .{ ctx, memory, alignment, new_len, ret_addr };
        return null;
    }

    fn hostFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = ret_addr;
        const self: *HostAllocator = @ptrCast(@alignCast(ctx));
        self.free_fn(self.user_data, memory.ptr, memory.len, alignment.toByteUnits());
    }
};

const Context = struct {
    allocator: std.mem.Allocator,
    backing: Backing,
    /// Meaningful only when `backing == .host`; the heap-pinned state the
    /// `allocator` vtable points into.
    host: HostAllocator,

    const Backing = enum { library, host };
};

const ManagedFramePayload = struct {
    frame: foundation.Frame,
    allocator: std.mem.Allocator,
};

const AdoptedManagedFramePayload = struct {
    managed: PancakeManagedFrame,
    allocator: std.mem.Allocator,
};

/// Classify an inbound-dispatch error into a C ABI return code. Derived from the
/// single error taxonomy ([`engine.abort_projection.classify`]) so the C codes
/// cannot drift from the abort projection: codec/decode malformations report
/// `CODEC`, session state-machine refusals (a partner protocol violation, a
/// resource cap, an already-closed session) report `SESSION`, and host-internal
/// failures (allocation, …) report `INTERNAL`.
fn feedErrorToCode(err: anyerror) i32 {
    return switch (engine.abort_projection.classify(err).domain) {
        .codec => PANCAKE_ERR_CODEC,
        .session => PANCAKE_ERR_SESSION,
        .foreign => PANCAKE_ERR_INTERNAL,
    };
}

/// Create a context that allocates through the library-owned allocator. Release
/// it with `pancake_context_release` after releasing every handle created in it.
pub export fn pancake_context_new_default(out_context: ?*?*PancakeContext) i32 {
    const slot = out_context orelse return PANCAKE_ERR_NULL_POINTER;
    const ctx = library_allocator.create(Context) catch return PANCAKE_ERR_INTERNAL;
    ctx.* = .{ .allocator = library_allocator, .backing = .library, .host = undefined };
    slot.* = @ptrCast(ctx);
    return PANCAKE_OK;
}

/// Create a context that routes every allocation in its handle family through
/// the host callbacks in `spec` (`alloc` and `free` required). The context
/// object itself is allocated through `spec.alloc`, so a later
/// `pancake_context_release` returns it through `spec.free`.
pub export fn pancake_context_new_with_allocator(spec: ?*const PancakeAllocator, out_context: ?*?*PancakeContext) i32 {
    const slot = out_context orelse return PANCAKE_ERR_NULL_POINTER;
    const s = spec orelse return PANCAKE_ERR_NULL_POINTER;
    const alloc_fn = s.alloc orelse return PANCAKE_ERR_NULL_POINTER;
    const free_fn = s.free orelse return PANCAKE_ERR_NULL_POINTER;

    const raw = alloc_fn(s.user_data, @sizeOf(Context), @alignOf(Context)) orelse return PANCAKE_ERR_INTERNAL;
    const ctx: *Context = @ptrCast(@alignCast(raw));
    ctx.* = .{
        .allocator = undefined,
        .backing = .host,
        .host = .{
            .alloc_fn = alloc_fn,
            .free_fn = free_fn,
            .user_data = s.user_data,
        },
    };
    // The vtable borrows `&ctx.host`, valid because `ctx` is heap-pinned.
    ctx.allocator = ctx.host.allocator();
    slot.* = @ptrCast(ctx);
    return PANCAKE_OK;
}

/// Release a context, freeing the context object through its own policy. Every
/// handle created in the context must already be released; the context's
/// allocator outlives those handles by contract, not by reference counting.
pub export fn pancake_context_release(context: ?*PancakeContext) void {
    const ctx = ctxFromOpaque(context) orelse return;
    switch (ctx.backing) {
        .library => library_allocator.destroy(ctx),
        .host => ctx.host.free_fn(ctx.host.user_data, ctx, @sizeOf(Context), @alignOf(Context)),
    }
}

fn ctxFromOpaque(context: ?*PancakeContext) ?*Context {
    const ptr = context orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub export fn pancake_managed_frame_release(frame: ?*PancakeManagedFrame) void {
    const managed = frame orelse return;
    const release = managed.release orelse return;

    managed.release = null;
    // The callback owns payload cleanup and any remaining descriptor
    // normalization. Do not touch `managed` after this call; a producer may
    // allocate descriptors whose release reclaims the whole object.
    release(managed);
}

pub export fn pancake_event_release(event: ?*PancakeEvent) void {
    const managed = event orelse return;
    pancake_managed_frame_release(&managed.frame);
    managed.kind = 0;
}

pub export fn pancake_peer_new(out_peer: ?*?*PancakePeer) i32 {
    const slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    return peerNewIn(library_allocator, slot);
}

/// Create a peer whose every allocation — the peer object, session tables, and
/// the managed frames it later hands out — routes through `context`. The peer is
/// released with the same `pancake_peer_release`; it remembers its context's
/// allocator, so the caller does not name it again.
pub export fn pancake_peer_new_in(context: ?*PancakeContext, out_peer: ?*?*PancakePeer) i32 {
    const ctx = ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    return peerNewIn(ctx.allocator, slot);
}

fn peerNewIn(alloc: std.mem.Allocator, slot: *?*PancakePeer) i32 {
    const peer = alloc.create(engine.Peer) catch return PANCAKE_ERR_INTERNAL;
    peer.* = engine.Peer.init(alloc);
    slot.* = @ptrCast(peer);
    return PANCAKE_OK;
}

pub export fn pancake_peer_release(peer: ?*PancakePeer) void {
    const ptr = peerFromOpaque(peer) orelse return;
    // The peer holds the allocator it was created with (`pancake_peer_new` or
    // `pancake_peer_new_in`), so release routes back to the same policy.
    const alloc = ptr.allocator;
    ptr.deinit();
    alloc.destroy(ptr);
}

/// Dispatch one inbound frame whose bytes are *borrowed* for this call only. The
/// peer reads and retains nothing; the caller keeps ownership of `frame`'s bytes.
pub export fn pancake_peer_feed_borrowed(peer: ?*PancakePeer, frame: ?*const PancakeFrame) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const borrowed = frame orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes_ptr = borrowed.bytes orelse return PANCAKE_ERR_NULL_POINTER;
    const shape = frameShapeFromC(borrowed.shape) orelse return PANCAKE_ERR_CODEC;

    ptr.recvBorrowed(.{
        .bytes = bytes_ptr[0..borrowed.len],
        .shape = shape,
    }) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Adopt an inbound managed frame, transferring ownership to the peer for queued
/// dispatch. On success the caller's `frame` struct is nulled out (bytes/len/
/// release cleared) so it is not released twice; the peer releases it later.
pub export fn pancake_peer_feed_owned(peer: ?*PancakePeer, frame: ?*PancakeManagedFrame) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const managed = frame orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes_ptr = managed.bytes orelse return PANCAKE_ERR_NULL_POINTER;
    const shape = frameShapeFromC(managed.shape) orelse return PANCAKE_ERR_CODEC;

    const alloc = ptr.allocator;
    const payload = alloc.create(AdoptedManagedFramePayload) catch return PANCAKE_ERR_INTERNAL;
    var queued = false;
    defer if (!queued) alloc.destroy(payload);
    payload.* = .{ .managed = managed.*, .allocator = alloc };

    const owned = foundation.Frame.initExternal(
        bytes_ptr[0..managed.len],
        shape,
        payload,
        releaseAdoptedManagedFrame,
    ) catch return PANCAKE_ERR_CODEC;

    ptr.feedInbound(owned) catch return PANCAKE_ERR_INTERNAL;
    queued = true;
    managed.bytes = null;
    managed.len = 0;
    managed.release = null;
    managed.private_data = null;
    return PANCAKE_OK;
}

/// Frame and dispatch one inbound frame from a byte-stream buffer. `bytes[0..len]`
/// is whatever has accumulated from the wire so far; this finds the next complete
/// frame in the negotiated codec, dispatches it synchronously (queuing any reply
/// or abort on the outbound queue and any application event), and writes the
/// number of leading bytes it consumed into `out_consumed` — drop those before
/// the next call, then call again to drain further buffered frames.
///
/// Returns `PANCAKE_OK` with `*out_consumed` set when one frame was consumed;
/// `PANCAKE_ERR_WOULD_BLOCK` with `*out_consumed == 0` when the buffer holds only
/// part of a frame (read more and retry with the extended buffer);
/// `PANCAKE_ERR_MALFORMED` or `PANCAKE_ERR_FRAME_TOO_LARGE` on a fatal framing
/// violation (an `op:abort` is queued and the session closes); other codes on a
/// dispatch failure. This is the sans-I/O stream-input primitive: the caller owns
/// the socket and the buffer, the peer never blocks, and it retains no borrow
/// past the call.
pub export fn pancake_peer_recv_stream(
    peer: ?*PancakePeer,
    bytes: ?[*]const u8,
    len: usize,
    out_consumed: ?*usize,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const buf = bytes orelse return PANCAKE_ERR_NULL_POINTER;
    const consumed = out_consumed orelse return PANCAKE_ERR_NULL_POINTER;
    consumed.* = 0;

    const outcome = ptr.recvStreamPrefix(buf[0..len]) catch |err| switch (err) {
        error.MalformedFrame => return PANCAKE_ERR_MALFORMED,
        error.FrameTooLarge => return PANCAKE_ERR_FRAME_TOO_LARGE,
        else => return feedErrorToCode(err),
    };
    switch (outcome) {
        .incomplete => return PANCAKE_ERR_WOULD_BLOCK,
        .consumed => |n| {
            consumed.* = n;
            return PANCAKE_OK;
        },
    }
}

/// Advance the peer: validate-and-apply queued inbound frames and encode pending
/// outbound work. No I/O — the caller drains `take_outbound` and `poll_event`
/// afterward.
pub export fn pancake_peer_step(peer: ?*PancakePeer) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    _ = ptr.step() catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Take the next outbound frame, writing an *owned* managed frame into
/// `out_frame` that the caller must `release`. Returns `PANCAKE_ERR_WOULD_BLOCK`
/// when the outbound queue is empty.
pub export fn pancake_peer_take_outbound(peer: ?*PancakePeer, out_frame: ?*PancakeManagedFrame) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_frame orelse return PANCAKE_ERR_NULL_POINTER;
    const frame = ptr.takeOutbound() orelse return PANCAKE_ERR_WOULD_BLOCK;

    slot.* = tryManagedFrame(ptr.allocator, frame) catch {
        var owned = frame;
        owned.deinit();
        return PANCAKE_ERR_INTERNAL;
    };
    return PANCAKE_OK;
}

/// Take the next application event, writing it into `out_event`. The event's
/// frame is the originating wire bytes in the negotiated codec (no re-encode),
/// handed over as an *owned* managed frame the caller must `release`. Returns
/// `PANCAKE_ERR_WOULD_BLOCK` when no event is pending.
pub export fn pancake_peer_poll_event(peer: ?*PancakePeer, out_event: ?*PancakeEvent) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_event orelse return PANCAKE_ERR_NULL_POINTER;
    var event = ptr.pollEvent() orelse return PANCAKE_ERR_WOULD_BLOCK;

    // Hand back the originating frame bytes in the session's negotiated codec.
    // The frame moves into the managed payload; no decode and no re-encode.
    slot.* = .{
        .kind = eventKindToC(event.kind()),
        .frame = tryManagedFrame(ptr.allocator, event.frame) catch {
            event.deinit();
            return PANCAKE_ERR_INTERNAL;
        },
    };
    return PANCAKE_OK;
}

fn tryManagedFrame(alloc: std.mem.Allocator, frame: foundation.Frame) !PancakeManagedFrame {
    const payload = try alloc.create(ManagedFramePayload);
    payload.* = .{ .frame = frame, .allocator = alloc };
    return .{
        .bytes = @constCast(payload.frame.bytes().ptr),
        .len = payload.frame.bytes().len,
        .shape = frameShapeToC(payload.frame.view().shape),
        .release = releaseOwnedFrame,
        .private_data = payload,
    };
}

fn eventKindToC(kind: engine.EventKind) u32 {
    return switch (kind) {
        .deliver => PANCAKE_EVENT_DELIVER,
        .resolve => PANCAKE_EVENT_RESOLVE,
        .gc_export => PANCAKE_EVENT_GC_EXPORT,
        .gc_answer => PANCAKE_EVENT_GC_ANSWER,
        .handoff => PANCAKE_EVENT_HANDOFF,
        .start_session => PANCAKE_EVENT_START_SESSION,
        .abort => PANCAKE_EVENT_ABORT,
        .listen => PANCAKE_EVENT_LISTEN,
        .get => PANCAKE_EVENT_GET,
        .index => PANCAKE_EVENT_INDEX,
    };
}

fn releaseOwnedFrame(frame: *PancakeManagedFrame) callconv(.c) void {
    const payload_ptr = frame.private_data orelse return;
    const payload: *ManagedFramePayload = @ptrCast(@alignCast(payload_ptr));
    const alloc = payload.allocator;
    payload.frame.deinit();
    alloc.destroy(payload);
    frame.bytes = null;
    frame.len = 0;
    frame.release = null;
    frame.private_data = null;
}

fn releaseAdoptedManagedFrame(context: *anyopaque) void {
    const payload: *AdoptedManagedFramePayload = @ptrCast(@alignCast(context));
    const alloc = payload.allocator;
    pancake_managed_frame_release(&payload.managed);
    alloc.destroy(payload);
}

fn peerFromOpaque(peer: ?*PancakePeer) ?*engine.Peer {
    const ptr = peer orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn frameShapeFromC(shape: u32) ?foundation.FrameShape {
    return switch (shape) {
        PANCAKE_FRAME_SHAPE_BYTE => .byte,
        PANCAKE_FRAME_SHAPE_WORD => .word,
        else => null,
    };
}

fn frameShapeToC(shape: foundation.FrameShape) u32 {
    return switch (shape) {
        .byte => PANCAKE_FRAME_SHAPE_BYTE,
        .word => PANCAKE_FRAME_SHAPE_WORD,
    };
}

// ── Per-thread last error ────────────────────────────────────────────────────
//
// The Zig side would otherwise hide the concrete `ReadFailed` / `WriteFailed`
// behind a flat `PANCAKE_ERR_IO`. This per-thread slot re-exposes it: a function
// that returns `_IO` first records a human-readable cause here.

threadlocal var last_error_buf: [256]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn setLastError(comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(&last_error_buf, fmt, args) catch blk: {
        // Message longer than the slot: keep the truncated prefix.
        break :blk last_error_buf[0..];
    };
    last_error_len = written.len;
}

/// Copy the calling thread's last error message into `out_buf` (NUL-terminated
/// if it fits), returning the full message length (which may exceed `cap`, in
/// which case the copy was truncated). errno-style: meaningful only right after
/// a call that returned a cause-bearing code (`_IO`, or the address-parse
/// `_INVALID_ARGUMENT`); a later success does not clear it. Returns 0 when none
/// is set.
pub export fn pancake_last_error(out_buf: ?[*]u8, cap: usize) usize {
    const dest = out_buf orelse return last_error_len;
    if (cap == 0) return last_error_len;
    const n = @min(last_error_len, cap - 1);
    @memcpy(dest[0..n], last_error_buf[0..n]);
    dest[n] = 0;
    return last_error_len;
}

/// Clear the calling thread's last error slot.
pub export fn pancake_clear_last_error() void {
    last_error_len = 0;
}

// ── Bootstrap registration ───────────────────────────────────────────────────

/// Expose a local capability behind `swissnum` for inbound bootstrap-fetch
/// (ADR-0006 responder half). Writes the allocated export id into
/// `out_export_id`. The swissnum bytes are borrowed for the call.
pub export fn pancake_peer_register_bootstrap_cap(
    peer: ?*PancakePeer,
    swissnum: ?[*]const u8,
    swissnum_len: usize,
    out_export_id: ?*u64,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_export_id orelse return PANCAKE_ERR_NULL_POINTER;
    const swiss_ptr = swissnum orelse return PANCAKE_ERR_NULL_POINTER;
    const export_id = ptr.registerBootstrapCap(swiss_ptr[0..swissnum_len]) catch |err|
        return feedErrorToCode(err);
    slot.* = export_id;
    return PANCAKE_OK;
}

/// Register a local export position so inbound deliveries targeting it surface as
/// events. The bare-position sibling of `register_bootstrap_cap` (no swissnum).
pub export fn pancake_peer_register_export(peer: ?*PancakePeer, export_id: u64) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    ptr.session_state.registerExport(export_id) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Track a partner-hosted import position this peer holds, so a typed
/// `send_deliver` to it as a `_FAR` reference is admitted. Partner-allocated
/// imports normally arrive through a resolution; this names a known one (e.g. the
/// bootstrap import) directly.
pub export fn pancake_peer_register_import(peer: ?*PancakePeer, import_id: u64) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    ptr.session_state.registerImport(import_id) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

// ── Typed OCapN driving surface ──────────────────────────────────────────────
//
// The opaque-frame path (`feed_*` / `take_outbound` / `poll_event`) shuttles wire
// bytes. This surface lets a C consumer *drive* OCapN: construct a call and read
// a delivery as structured values, without authoring or parsing a codec itself.
//
// Send marshals caller-owned C structs into a `model` message and routes through
// `Peer.sendCopying` — the named boundary copy that owns the clone, so the C
// bytes are borrowed only for the call. Receive materializes the event once into
// a per-event arena and projects C views whose byte pointers alias that arena;
// the matching `*_free` releases it. The struct layouts are frozen ABI (ADR-0032).

pub const PANCAKE_REF_NEAR: u32 = 0;
pub const PANCAKE_REF_FAR: u32 = 1;
pub const PANCAKE_REF_PROMISE: u32 = 2;
pub const PANCAKE_REF_STURDY: u32 = 3;
pub const PANCAKE_REF_BROKEN: u32 = 4;

/// `sub_kind` for a near/far reference: whether the position names an object or a
/// promise (the `desc:import-object` vs `desc:import-promise` distinction).
pub const PANCAKE_REF_OBJECT: u32 = 0;
pub const PANCAKE_REF_PROMISE_KIND: u32 = 1;

pub const PANCAKE_ARG_INTEGER: u32 = 0;
pub const PANCAKE_ARG_FLOAT64: u32 = 1;
pub const PANCAKE_ARG_BOOLEAN: u32 = 2;
pub const PANCAKE_ARG_BYTES: u32 = 3;
pub const PANCAKE_ARG_STRING: u32 = 4;
pub const PANCAKE_ARG_SYMBOL: u32 = 5;
pub const PANCAKE_ARG_VOID: u32 = 6;
pub const PANCAKE_ARG_REFERENCE: u32 = 7;
pub const PANCAKE_ARG_LIST: u32 = 8;
/// A `set` reuses `items`; a `tagged` reuses `bytes` (the tag) and `items` (the
/// value list); a `keyword` reuses `bytes`.
pub const PANCAKE_ARG_SET: u32 = 9;
pub const PANCAKE_ARG_TAGGED: u32 = 10;
pub const PANCAKE_ARG_KEYWORD: u32 = 11;

pub const PANCAKE_RESOLUTION_FULFILL: u32 = 0;
pub const PANCAKE_RESOLUTION_BREAK: u32 = 1;

/// A capability reference. `kind` selects the meaning of `id`: a `_NEAR` export
/// id, a `_FAR` import id, or a `_PROMISE` answer id. `sub_kind` is the
/// object/promise distinction for near/far. `_STURDY` and `_BROKEN` carry no
/// payload here (use the resolution's break message for a broken target).
pub const PancakeReference = extern struct {
    kind: u32,
    sub_kind: u32,
    id: u64,
};

/// A passable argument value. `kind` selects which field is live. `bytes`/
/// `bytes_len` carry `_BYTES`/`_STRING`/`_SYMBOL`; `items`/`items_len` carry a
/// `_LIST`'s children. On a projected (received) value the pointers alias the
/// owning arena and are valid until the matching `*_free`.
pub const PancakeArgument = extern struct {
    kind: u32,
    boolean: u32,
    integer: i64,
    float64: f64,
    bytes: ?[*]const u8,
    bytes_len: usize,
    reference: PancakeReference,
    items: ?[*]const PancakeArgument,
    items_len: usize,
};

/// A received `op:deliver` projected to C. `args` aliases an internal arena;
/// release the whole projection with `pancake_deliver_free` exactly once.
pub const PancakeDeliver = extern struct {
    target: PancakeReference,
    args: ?[*]const PancakeArgument,
    args_len: usize,
    has_answer: u32,
    answer: u64,
    owner: ?*anyopaque,
};

/// A received `op:resolve` projected to C. `resolution_kind` selects `fulfill`
/// (a value) or the `break_message` bytes. Release with `pancake_resolve_free`.
pub const PancakeResolve = extern struct {
    answer: u64,
    resolution_kind: u32,
    fulfill: PancakeArgument,
    break_message: ?[*]const u8,
    break_message_len: usize,
    owner: ?*anyopaque,
};

const zero_reference: PancakeReference = .{ .kind = PANCAKE_REF_BROKEN, .sub_kind = 0, .id = 0 };
const zero_argument: PancakeArgument = .{
    .kind = PANCAKE_ARG_VOID,
    .boolean = 0,
    .integer = 0,
    .float64 = 0,
    .bytes = null,
    .bytes_len = 0,
    .reference = zero_reference,
    .items = null,
    .items_len = 0,
};

const MarshalError = error{ UnsupportedValue, NullPointer, OutOfMemory };

fn marshalErrorToCode(err: MarshalError) i32 {
    return switch (err) {
        error.UnsupportedValue => PANCAKE_ERR_UNSUPPORTED_VALUE,
        error.NullPointer => PANCAKE_ERR_NULL_POINTER,
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
    };
}

fn sliceFromC(ptr: ?[*]const u8, len: usize) MarshalError![]const u8 {
    if (len == 0) return &.{};
    const p = ptr orelse return error.NullPointer;
    return p[0..len];
}

fn referenceFromC(c: PancakeReference) MarshalError!model.Reference {
    const promise_sub = c.sub_kind == PANCAKE_REF_PROMISE_KIND;
    return switch (c.kind) {
        PANCAKE_REF_NEAR => .{ .near = .{ .export_id = c.id, .kind = if (promise_sub) .promise else .object } },
        PANCAKE_REF_FAR => .{ .far = .{ .import_id = c.id, .kind = if (promise_sub) .promise else .object } },
        PANCAKE_REF_PROMISE => .{ .promise = .{ .answer_id = c.id } },
        else => error.UnsupportedValue,
    };
}

fn argumentFromC(arena: std.mem.Allocator, c: PancakeArgument) MarshalError!model.Argument {
    return switch (c.kind) {
        PANCAKE_ARG_INTEGER => .{ .integer = c.integer },
        PANCAKE_ARG_FLOAT64 => .{ .float64 = c.float64 },
        PANCAKE_ARG_BOOLEAN => .{ .boolean = c.boolean != 0 },
        PANCAKE_ARG_BYTES => .{ .bytes = try sliceFromC(c.bytes, c.bytes_len) },
        PANCAKE_ARG_STRING => .{ .string = try sliceFromC(c.bytes, c.bytes_len) },
        PANCAKE_ARG_SYMBOL => .{ .symbol = try sliceFromC(c.bytes, c.bytes_len) },
        PANCAKE_ARG_VOID => .{ .void = {} },
        PANCAKE_ARG_REFERENCE => .{ .reference = try referenceFromC(c.reference) },
        PANCAKE_ARG_LIST => .{ .list = try argsFromC(arena, c.items, c.items_len) },
        PANCAKE_ARG_SET => .{ .set = try argsFromC(arena, c.items, c.items_len) },
        PANCAKE_ARG_TAGGED => .{ .tagged = .{
            .tag = try sliceFromC(c.bytes, c.bytes_len),
            .value = try argsFromC(arena, c.items, c.items_len),
        } },
        PANCAKE_ARG_KEYWORD => .{ .keyword = try sliceFromC(c.bytes, c.bytes_len) },
        else => error.UnsupportedValue,
    };
}

fn argsFromC(arena: std.mem.Allocator, items: ?[*]const PancakeArgument, len: usize) MarshalError![]const model.Argument {
    if (len == 0) return &.{};
    const p = items orelse return error.NullPointer;
    const out = try arena.alloc(model.Argument, len);
    for (0..len) |i| out[i] = try argumentFromC(arena, p[i]);
    return out;
}

fn referenceToC(reference: model.Reference) PancakeReference {
    return switch (reference) {
        .near => |near| .{ .kind = PANCAKE_REF_NEAR, .sub_kind = if (near.kind == .promise) PANCAKE_REF_PROMISE_KIND else PANCAKE_REF_OBJECT, .id = near.export_id },
        .far => |far| .{ .kind = PANCAKE_REF_FAR, .sub_kind = if (far.kind == .promise) PANCAKE_REF_PROMISE_KIND else PANCAKE_REF_OBJECT, .id = far.import_id },
        .promise => |promise| .{ .kind = PANCAKE_REF_PROMISE, .sub_kind = 0, .id = promise.answer_id },
        .sturdy => .{ .kind = PANCAKE_REF_STURDY, .sub_kind = 0, .id = 0 },
        .broken => .{ .kind = PANCAKE_REF_BROKEN, .sub_kind = 0, .id = 0 },
    };
}

fn argumentToC(arena: std.mem.Allocator, arg: model.Argument) MarshalError!PancakeArgument {
    var c = zero_argument;
    switch (arg) {
        .integer => |v| {
            c.kind = PANCAKE_ARG_INTEGER;
            c.integer = v;
        },
        .float64 => |v| {
            c.kind = PANCAKE_ARG_FLOAT64;
            c.float64 = v;
        },
        .boolean => |v| {
            c.kind = PANCAKE_ARG_BOOLEAN;
            c.boolean = if (v) 1 else 0;
        },
        .bytes => |b| {
            c.kind = PANCAKE_ARG_BYTES;
            c.bytes = b.ptr;
            c.bytes_len = b.len;
        },
        .string => |b| {
            c.kind = PANCAKE_ARG_STRING;
            c.bytes = b.ptr;
            c.bytes_len = b.len;
        },
        .symbol => |b| {
            c.kind = PANCAKE_ARG_SYMBOL;
            c.bytes = b.ptr;
            c.bytes_len = b.len;
        },
        .void => c.kind = PANCAKE_ARG_VOID,
        .reference => |r| {
            c.kind = PANCAKE_ARG_REFERENCE;
            c.reference = referenceToC(r);
        },
        .list => |items| {
            c.kind = PANCAKE_ARG_LIST;
            const arr = try argsToC(arena, items);
            c.items = arr.ptr;
            c.items_len = arr.len;
        },
        .set => |items| {
            c.kind = PANCAKE_ARG_SET;
            const arr = try argsToC(arena, items);
            c.items = arr.ptr;
            c.items_len = arr.len;
        },
        .tagged => |tagged| {
            c.kind = PANCAKE_ARG_TAGGED;
            c.bytes = tagged.tag.ptr;
            c.bytes_len = tagged.tag.len;
            const arr = try argsToC(arena, tagged.value);
            c.items = arr.ptr;
            c.items_len = arr.len;
        },
        .keyword => |keyword| {
            c.kind = PANCAKE_ARG_KEYWORD;
            c.bytes = keyword.ptr;
            c.bytes_len = keyword.len;
        },
        else => return error.UnsupportedValue,
    }
    return c;
}

fn argsToC(arena: std.mem.Allocator, args: []const model.Argument) MarshalError![]PancakeArgument {
    const out = try arena.alloc(PancakeArgument, args.len);
    for (args, 0..) |arg, i| out[i] = try argumentToC(arena, arg);
    return out;
}

/// Allocate a heap-pinned arena (child = the peer's allocator) to own a received
/// projection. `pancake_*_free` deinits and destroys it through that same child.
fn newProjectionArena(alloc: std.mem.Allocator) ?*std.heap.ArenaAllocator {
    const arena = alloc.create(std.heap.ArenaAllocator) catch return null;
    arena.* = std.heap.ArenaAllocator.init(alloc);
    return arena;
}

fn freeProjectionArena(owner: ?*anyopaque) void {
    const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(owner orelse return));
    const child = arena.child_allocator;
    arena.deinit();
    child.destroy(arena);
}

/// The kind of the next queued event without consuming it: a positive
/// `PANCAKE_EVENT_*`, or `PANCAKE_ERR_WOULD_BLOCK` when the queue is empty. Route
/// to the matching typed `poll_event_*`.
pub export fn pancake_peer_peek_event(peer: ?*PancakePeer) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const kind = ptr.peekEventKind() orelse return PANCAKE_ERR_WOULD_BLOCK;
    return @intCast(eventKindToC(kind));
}

/// Construct and queue an `op:deliver` to `target` carrying `args`. When
/// `has_answer` is nonzero the call expects a reply on `answer`. The C structs
/// are borrowed for the call (the clone owns the copy). `pancake_peer_step`
/// encodes it; drain with `pancake_peer_take_outbound`.
pub export fn pancake_peer_send_deliver(
    peer: ?*PancakePeer,
    target: ?*const PancakeReference,
    args: ?[*]const PancakeArgument,
    args_len: usize,
    has_answer: u32,
    answer: u64,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const tref = target orelse return PANCAKE_ERR_NULL_POINTER;

    var arena = std.heap.ArenaAllocator.init(ptr.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const model_target = referenceFromC(tref.*) catch |err| return marshalErrorToCode(err);
    const model_args = argsFromC(a, args, args_len) catch |err| return marshalErrorToCode(err);
    ptr.sendCopying(.{ .deliver = .{
        .target = model_target,
        .args = model_args,
        .answer = if (has_answer != 0) answer else null,
    } }) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Construct and queue an `op:resolve` settling `answer`. `resolution_kind`
/// selects a `_FULFILL` value (`fulfill`) or a `_BREAK` reason (`break_message`).
pub export fn pancake_peer_send_resolve(
    peer: ?*PancakePeer,
    answer: u64,
    resolution_kind: u32,
    fulfill: ?*const PancakeArgument,
    break_message: ?[*]const u8,
    break_message_len: usize,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;

    var arena = std.heap.ArenaAllocator.init(ptr.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const resolution: model.Resolution = switch (resolution_kind) {
        PANCAKE_RESOLUTION_FULFILL => blk: {
            const f = fulfill orelse return PANCAKE_ERR_NULL_POINTER;
            break :blk .{ .fulfill = argumentFromC(a, f.*) catch |err| return marshalErrorToCode(err) };
        },
        PANCAKE_RESOLUTION_BREAK => .{ .break_ = .{
            .message = sliceFromC(break_message, break_message_len) catch |err| return marshalErrorToCode(err),
        } },
        else => return PANCAKE_ERR_INVALID_ARGUMENT,
    };
    ptr.sendCopying(.{ .resolve = .{ .answer = answer, .resolution = resolution } }) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Take the next event as a structured `op:deliver`, writing it into `out`.
/// Returns `_WRONG_EVENT` (event left queued) when the next event is not a
/// deliver, `_WOULD_BLOCK` when none is queued. Release `out` with
/// `pancake_deliver_free`.
pub export fn pancake_peer_poll_event_deliver(peer: ?*PancakePeer, out: ?*PancakeDeliver) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    const next = ptr.peekEventKind() orelse return PANCAKE_ERR_WOULD_BLOCK;
    if (next != .deliver) return PANCAKE_ERR_WRONG_EVENT;

    var event = ptr.pollEvent() orelse return PANCAKE_ERR_WOULD_BLOCK;
    defer event.deinit();
    const body = event.view() catch return PANCAKE_ERR_CODEC;

    const arena = newProjectionArena(ptr.allocator) orelse return PANCAKE_ERR_INTERNAL;
    errdefer freeProjectionArena(arena);
    const a = arena.allocator();
    const owned = body.toOwned(a) catch return PANCAKE_ERR_INTERNAL;
    const deliver = owned.deliver;
    const args_c = argsToC(a, deliver.args) catch |err| return marshalErrorToCode(err);

    slot.* = .{
        .target = referenceToC(deliver.target),
        .args = args_c.ptr,
        .args_len = args_c.len,
        .has_answer = if (deliver.answer != null) 1 else 0,
        .answer = deliver.answer orelse 0,
        .owner = @ptrCast(arena),
    };
    return PANCAKE_OK;
}

/// Take the next event as a structured `op:resolve`. Same routing/return
/// contract as `poll_event_deliver`. Release `out` with `pancake_resolve_free`.
pub export fn pancake_peer_poll_event_resolve(peer: ?*PancakePeer, out: ?*PancakeResolve) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    const next = ptr.peekEventKind() orelse return PANCAKE_ERR_WOULD_BLOCK;
    if (next != .resolve) return PANCAKE_ERR_WRONG_EVENT;

    var event = ptr.pollEvent() orelse return PANCAKE_ERR_WOULD_BLOCK;
    defer event.deinit();
    const body = event.view() catch return PANCAKE_ERR_CODEC;

    const arena = newProjectionArena(ptr.allocator) orelse return PANCAKE_ERR_INTERNAL;
    errdefer freeProjectionArena(arena);
    const a = arena.allocator();
    const owned = body.toOwned(a) catch return PANCAKE_ERR_INTERNAL;
    const resolve = owned.resolve;

    slot.* = .{
        .answer = resolve.answer,
        .resolution_kind = switch (resolve.resolution) {
            .fulfill => PANCAKE_RESOLUTION_FULFILL,
            .break_ => PANCAKE_RESOLUTION_BREAK,
        },
        .fulfill = switch (resolve.resolution) {
            .fulfill => |arg| argumentToC(a, arg) catch |err| return marshalErrorToCode(err),
            .break_ => zero_argument,
        },
        .break_message = switch (resolve.resolution) {
            .fulfill => null,
            .break_ => |e| e.message.ptr,
        },
        .break_message_len = switch (resolve.resolution) {
            .fulfill => 0,
            .break_ => |e| e.message.len,
        },
        .owner = @ptrCast(arena),
    };
    return PANCAKE_OK;
}

/// Release a `PancakeDeliver` projection exactly once; the descriptor is cleared.
pub export fn pancake_deliver_free(deliver: ?*PancakeDeliver) void {
    const d = deliver orelse return;
    freeProjectionArena(d.owner);
    d.* = .{ .target = zero_reference, .args = null, .args_len = 0, .has_answer = 0, .answer = 0, .owner = null };
}

/// Release a `PancakeResolve` projection exactly once; the descriptor is cleared.
pub export fn pancake_resolve_free(resolve: ?*PancakeResolve) void {
    const r = resolve orelse return;
    freeProjectionArena(r.owner);
    r.* = .{ .answer = 0, .resolution_kind = 0, .fulfill = zero_argument, .break_message = null, .break_message_len = 0, .owner = null };
}

// ── Blocking TCP endpoint handles (`tcp-testing-only`) ────────────────────────
//
// The host-driven netlayer boundary: the C host owns the peer and shuttles frames
// (`read_frame -> feed_owned -> step -> take_outbound -> write_frame`). The C
// side cannot name an `Io`, so the backend is an explicit owned handle
// (`PancakeTcpNetlayer` owns one `std.Io.Threaded`); endpoints created from it
// borrow that backend and must be closed before it is released. Cleartext,
// loopback-grade; production transports layer above the same `net_adapter` types.

pub const PancakeTcpNetlayer = opaque {};
pub const PancakeTcpConn = opaque {};
pub const PancakeTcpListener = opaque {};

/// The netlayer handle owns the one I/O backend the endpoints run on. It is
/// created and released explicitly by the host — `std.Io` cannot cross the C ABI,
/// so this is the boring-handle translation of "pass `Io` in" rather than a
/// hidden process-global runtime. Endpoints created from it borrow its `Io`, so
/// the handle must outlive every connection and listener made from it.
const TcpNetlayerPayload = struct {
    threaded: std.Io.Threaded,
    /// The allocator the netlayer and every endpoint made from it use. Endpoints
    /// copy it onto their own payload so a conn/listener frees through the same
    /// policy as the netlayer that minted it.
    allocator: std.mem.Allocator,

    /// `Threaded.io()` captures `&self.threaded`, so the payload must be heap-
    /// pinned (it is — `create`) for the borrowed `Io` to stay valid.
    fn io(self: *TcpNetlayerPayload) std.Io {
        return self.threaded.io();
    }
};

/// Create a netlayer handle allocating through the library-owned allocator.
/// Release it with `pancake_tcp_netlayer_release` after closing every endpoint
/// made from it.
pub export fn pancake_tcp_netlayer_new(out_netlayer: ?*?*PancakeTcpNetlayer) i32 {
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(library_allocator, slot);
}

/// Create a netlayer handle whose backend, endpoints, and per-connection buffers
/// all allocate through `context`. Released with `pancake_tcp_netlayer_release`.
pub export fn pancake_tcp_netlayer_new_in(context: ?*PancakeContext, out_netlayer: ?*?*PancakeTcpNetlayer) i32 {
    const ctx = ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(ctx.allocator, slot);
}

fn netlayerNewIn(alloc: std.mem.Allocator, slot: *?*PancakeTcpNetlayer) i32 {
    const payload = alloc.create(TcpNetlayerPayload) catch return PANCAKE_ERR_INTERNAL;
    payload.* = .{ .threaded = std.Io.Threaded.init(alloc, .{}), .allocator = alloc };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

pub export fn pancake_tcp_netlayer_release(netlayer: ?*PancakeTcpNetlayer) void {
    const payload = netlayerFromOpaque(netlayer) orelse return;
    const alloc = payload.allocator;
    payload.threaded.deinit();
    alloc.destroy(payload);
}

const TcpConnPayload = struct {
    stream: net_adapter.FrameStream,
    read_buf: []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,
};

const TcpListenerPayload = struct {
    listener: net_adapter.tcp.Listener,
    allocator: std.mem.Allocator,
};

fn codecFromC(codec: u32) ?model.CodecId {
    return switch (codec) {
        PANCAKE_CODEC_SYRUP => .syrup,
        PANCAKE_CODEC_CAPNP => .capnp,
        else => null,
    };
}

fn destroyConn(payload: *TcpConnPayload) void {
    const alloc = payload.allocator;
    payload.stream.deinit();
    alloc.free(payload.read_buf);
    alloc.free(payload.write_buf);
    alloc.destroy(payload);
}

/// Modest cap on the write buffer: `writeAll` streams a frame larger than its
/// buffer straight through, so the writer never needs to hold a whole frame
/// (unlike the read buffer, which slice-1 sizes to `max_frame_bytes` so an
/// admissible frame frames whole). Caps per-connection memory at
/// `max_frame_bytes + this` instead of `2 * max_frame_bytes`.
const endpoint_write_buf_bytes: usize = 64 * 1024;

/// Allocate a connection payload and its buffers, leaving `.stream` for the
/// caller to install once the socket is established. On any failure before
/// install, release it with [`abortConn`]. Both endpoint constructors share this
/// so the buffer/payload lifecycle lives in one place.
fn beginConn(alloc: std.mem.Allocator, max_frame_bytes: usize) ?*TcpConnPayload {
    const read_buf = alloc.alloc(u8, max_frame_bytes) catch return null;
    const write_buf = alloc.alloc(u8, @min(max_frame_bytes, endpoint_write_buf_bytes)) catch {
        alloc.free(read_buf);
        return null;
    };
    const payload = alloc.create(TcpConnPayload) catch {
        alloc.free(read_buf);
        alloc.free(write_buf);
        return null;
    };
    payload.read_buf = read_buf;
    payload.write_buf = write_buf;
    payload.allocator = alloc;
    return payload;
}

fn abortConn(payload: *TcpConnPayload) void {
    const alloc = payload.allocator;
    alloc.free(payload.read_buf);
    alloc.free(payload.write_buf);
    alloc.destroy(payload);
}

/// Connect to `host:port` and return an owned connection handle framing on
/// `codec`. Blocking. Runs on `netlayer`'s I/O backend.
pub export fn pancake_endpoint_tcp_testing_connect(
    netlayer: ?*PancakeTcpNetlayer,
    host: ?[*]const u8,
    host_len: usize,
    port: u16,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeTcpConn,
) i32 {
    const nl = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    const host_ptr = host orelse return PANCAKE_ERR_NULL_POINTER;
    const codec_id = codecFromC(codec) orelse return PANCAKE_ERR_CODEC;
    if (max_frame_bytes == 0) return PANCAKE_ERR_INVALID_ARGUMENT;

    const address = net_adapter.tcp.parseHostPort(host_ptr[0..host_len], port) catch |err| {
        setLastError("connect: invalid address: {s}", .{@errorName(err)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };

    const payload = beginConn(nl.allocator, max_frame_bytes) orelse return PANCAKE_ERR_INTERNAL;
    payload.stream = net_adapter.tcp.connectFrameStream(nl.io(), address, codec_id, max_frame_bytes, payload.read_buf, payload.write_buf) catch |err| {
        abortConn(payload);
        setLastError("connect: {s}", .{@errorName(err)});
        return PANCAKE_ERR_IO;
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Bind + listen on `host:port` (port 0 = OS-chosen). Returns an owned listener
/// handle. Runs on `netlayer`'s I/O backend.
pub export fn pancake_endpoint_tcp_testing_listen(
    netlayer: ?*PancakeTcpNetlayer,
    host: ?[*]const u8,
    host_len: usize,
    port: u16,
    out_listener: ?*?*PancakeTcpListener,
) i32 {
    const nl = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_listener orelse return PANCAKE_ERR_NULL_POINTER;
    const host_ptr = host orelse return PANCAKE_ERR_NULL_POINTER;

    const address = net_adapter.tcp.parseHostPort(host_ptr[0..host_len], port) catch |err| {
        setLastError("listen: invalid address: {s}", .{@errorName(err)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };

    const payload = nl.allocator.create(TcpListenerPayload) catch return PANCAKE_ERR_INTERNAL;
    payload.* = .{
        .listener = net_adapter.tcp.Listener.bind(nl.io(), address) catch |err| {
            nl.allocator.destroy(payload);
            setLastError("listen: {s}", .{@errorName(err)});
            return PANCAKE_ERR_IO;
        },
        .allocator = nl.allocator,
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// The OS-resolved local port of a listener (useful after binding to port 0).
pub export fn pancake_endpoint_tcp_listener_port(listener: ?*PancakeTcpListener, out_port: ?*u16) i32 {
    const payload = listenerFromOpaque(listener) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_port orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = payload.listener.localAddress().getPort();
    return PANCAKE_OK;
}

/// Block until a client connects, returning an owned connection handle framing
/// on `codec`.
pub export fn pancake_endpoint_tcp_testing_accept(
    listener: ?*PancakeTcpListener,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeTcpConn,
) i32 {
    const lpayload = listenerFromOpaque(listener) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    const codec_id = codecFromC(codec) orelse return PANCAKE_ERR_CODEC;
    if (max_frame_bytes == 0) return PANCAKE_ERR_INVALID_ARGUMENT;

    const payload = beginConn(lpayload.allocator, max_frame_bytes) orelse return PANCAKE_ERR_INTERNAL;
    payload.stream = lpayload.listener.acceptFrameStream(codec_id, max_frame_bytes, payload.read_buf, payload.write_buf) catch |err| {
        abortConn(payload);
        setLastError("accept: {s}", .{@errorName(err)});
        return PANCAKE_ERR_IO;
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Block until one whole frame arrives, writing it as an *owned* managed frame
/// into `out_frame` (the caller `release`s it, or hands it to
/// `pancake_peer_feed_owned`). Returns `_CLOSED` on graceful EOF, `_IO` on a
/// socket fault (see `pancake_last_error`), `_MALFORMED` / `_FRAME_TOO_LARGE`
/// for a bad frame.
pub export fn pancake_endpoint_tcp_read_frame(conn: ?*PancakeTcpConn, out_frame: ?*PancakeManagedFrame) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_frame orelse return PANCAKE_ERR_NULL_POINTER;

    const frame = payload.stream.readFrame(payload.allocator) catch |err| return frameReadErrorToCode(payload, err);

    slot.* = tryManagedFrame(payload.allocator, frame) catch {
        var owned = frame;
        owned.deinit();
        return PANCAKE_ERR_INTERNAL;
    };
    return PANCAKE_OK;
}

/// Write one frame's *borrowed* bytes and flush. Returns `_IO` on a socket fault.
pub export fn pancake_endpoint_tcp_write_frame(conn: ?*PancakeTcpConn, frame: ?*const PancakeFrame) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const borrowed = frame orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes_ptr = borrowed.bytes orelse return PANCAKE_ERR_NULL_POINTER;

    payload.stream.writeFrame(bytes_ptr[0..borrowed.len]) catch |err| {
        if (payload.stream.lastWriteError()) |cause| {
            setLastError("write_frame: {s}", .{@errorName(cause)});
        } else {
            setLastError("write_frame: {s}", .{@errorName(err)});
        }
        return PANCAKE_ERR_IO;
    };
    return PANCAKE_OK;
}

pub export fn pancake_endpoint_tcp_conn_close(conn: ?*PancakeTcpConn) void {
    const payload = connFromOpaque(conn) orelse return;
    destroyConn(payload);
}

pub export fn pancake_endpoint_tcp_listener_close(listener: ?*PancakeTcpListener) void {
    const payload = listenerFromOpaque(listener) orelse return;
    const alloc = payload.allocator;
    payload.listener.deinit();
    alloc.destroy(payload);
}

fn frameReadErrorToCode(payload: *TcpConnPayload, err: net_adapter.FrameError) i32 {
    return switch (err) {
        error.Closed => PANCAKE_ERR_CLOSED,
        error.MalformedFrame => PANCAKE_ERR_MALFORMED,
        error.FrameTooLarge => PANCAKE_ERR_FRAME_TOO_LARGE,
        error.TruncatedFrame => blk: {
            setLastError("read_frame: stream closed mid-frame", .{});
            break :blk PANCAKE_ERR_IO;
        },
        error.ConnectionLost => blk: {
            if (payload.stream.lastReadError()) |cause| {
                setLastError("read_frame: {s}", .{@errorName(cause)});
            } else {
                setLastError("read_frame: connection lost", .{});
            }
            break :blk PANCAKE_ERR_IO;
        },
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
    };
}

fn netlayerFromOpaque(netlayer: ?*PancakeTcpNetlayer) ?*TcpNetlayerPayload {
    const ptr = netlayer orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn connFromOpaque(conn: ?*PancakeTcpConn) ?*TcpConnPayload {
    const ptr = conn orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn listenerFromOpaque(listener: ?*PancakeTcpListener) ?*TcpListenerPayload {
    const ptr = listener orelse return null;
    return @ptrCast(@alignCast(ptr));
}
