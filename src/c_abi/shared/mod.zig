//! Shared C-ABI vocabulary: the C-visible frame/context types, the OCapN value
//! types (`PancakeReference`/`PancakeArgument` and their model<->C
//! marshalling), the return and codec codes, the allocation policy,
//! the managed-frame machinery, and the per-thread last-error slot that
//! `libpancake_ocapn`'s handle families, the tcp/inproc transport families (the
//! frame boundary and the owning `pancake_tcp_session_*` surface, ADR-0062), and
//! the out-of-graph iroh C ABI (`src/c_abi/net_transport/iroh/mod.zig`) all speak.
//!
//! This leaf declares **no `export fn`**. The public `pancake_*` entry points
//! live in the `c_abi/ocapn` families (context, frame, peer, uri) and
//! the `c_abi/net_transport/{tcp,inproc}` transport families, and the
//! `pancake_iroh_*` entry points in `c_abi_net_transport_iroh`; all reach this
//! vocabulary through `@import("c_abi_shared")`. Because importing the leaf pulls the
//! vocabulary without pulling either library's exported surface, `libpancake_ocapn`
//! carries the core families and `libpancake_net_transport_iroh` carries only
//! the iroh family, each reusing these types, and each from `pancake_ocapn.h`
//! on the C side
//! (ADR-0055 companion split). The two artifacts therefore share no exported
//! core symbol; they share the *layout* of these types, exactly as a C consumer
//! including both headers does.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");

// ── Return codes ─────────────────────────────────────────────────────────────

pub const PANCAKE_OK: i32 = 0;
pub const PANCAKE_ERR_NULL_POINTER: i32 = -1;
// -2 is retired (an unimplemented stale-handle check); the value is never
// reused, so an old consumer comparing against it cannot mistake a new code.
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
// -12 is retired (the pairwise typed polls' wrong-kind refusal;
// `pancake_peer_next_event` routes every kind itself). Never reused.
/// A value *sent* across the typed surface uses a variant the C ABI cannot carry:
/// a `handoff` argument, an OCapN Struct argument (there is no `PANCAKE_ARG_STRUCT`),
/// or a `sturdy`/`broken` reference target. Those are refused loudly with this
/// code rather than marshalled wrong. (`set`, `tagged`, and `keyword` arguments
/// do carry, both directions.) A *received* Struct, `sturdy`, or `broken` value
/// is a separate case: a Struct projects as its raw wire frame, and a `sturdy`/
/// `broken` reference projects lossily — the kind is reported but its
/// swissnum/detail is dropped — since the deliver was authored by the partner,
/// not refused on this consumer's behalf.
pub const PANCAKE_ERR_UNSUPPORTED_VALUE: i32 = -13;
/// A promise the partner broke: a `send`/`fetch` the remote side refused with a
/// reason, not a fault in this peer or the transport. The sans-io peer surface
/// never *returns* this — a break arrives there as a `PANCAKE_RESOLUTION_BREAK`
/// resolve event carrying its message. The owning-session transport surfaces do
/// return it: `pancake_tcp_session_fetch` reports a partner break with this code,
/// and a binding reuses it when it turns that break into its own error type, so
/// the reason stays distinct from a real failure.
pub const PANCAKE_ERR_BROKEN: i32 = -14;
/// A lookup found nothing: the `pancake_locator_hint` key names no hint on the
/// locator. Distinct from `_INVALID_ARGUMENT` (the request was malformed) — the
/// request was well-formed, the thing asked for is simply absent.
pub const PANCAKE_ERR_NOT_FOUND: i32 = -15;

// ── Codec selector ───────────────────────────────────────────────────────────

/// Codec selector: the wire grammar a peer's session speaks
/// (`pancake_peer_new_negotiated`) and the framing an endpoint delimits
/// frames with (`pancake_tcp_connect` / `pancake_tcp_accept`). The
/// two must match, the endpoint splits the stream with the same grammar the
/// session encodes in.
pub const PANCAKE_CODEC_SYRUP: u32 = 0;
pub const PANCAKE_CODEC_CAPNP: u32 = 1;

/// Decode a `PANCAKE_CODEC_*` value, or null for anything outside the family.
pub fn codecFromC(codec: u32) ?model.CodecId {
    return switch (codec) {
        PANCAKE_CODEC_SYRUP => .syrup,
        PANCAKE_CODEC_CAPNP => .capnp,
        else => null,
    };
}

// ── Frame storage shape ──────────────────────────────────────────────────────

pub const PANCAKE_FRAME_SHAPE_BYTE: u32 = 0;
/// Word-aligned frame storage: the pointer must be 8-byte aligned and the
/// length divisible by 8. Anything else is refused with
/// `PANCAKE_ERR_INVALID_ARGUMENT`.
pub const PANCAKE_FRAME_SHAPE_WORD: u32 = 1;

pub fn frameShapeFromC(shape: u32) ?foundation.FrameShape {
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

// ── Frame types ──────────────────────────────────────────────────────────────

/// A frame whose bytes are *borrowed* from the C caller for the duration of one
/// call. The engine reads them during the call and retains nothing; the caller
/// keeps ownership and frees them on its own schedule. Used for inbound feeds.
pub const PancakeFrame = extern struct {
    bytes: ?[*]const u8,
    len: usize,
    shape: u32,
};

/// Internal self-release hook a `PancakeManagedFrame` carries. Do not invoke
/// this pointer directly: free the frame through `pancake_managed_frame_release`,
/// which is idempotent and nulls the hook first. Calling it directly after the
/// wrapper has run is a null function-pointer call.
pub const ReleaseFn = *const fn (*PancakeManagedFrame) callconv(.c) void;

/// A frame the engine *owns* and hands to the C caller (outbound frames, event
/// frames). It is self-describing and self-releasing: free it exactly once
/// through `pancake_managed_frame_release` (idempotent), never with a host `free`
/// and never by calling the `release` field directly.
pub const PancakeManagedFrame = extern struct {
    bytes: ?[*]u8,
    len: usize,
    shape: u32,
    release: ?ReleaseFn,
    private_data: ?*anyopaque,
};

const ManagedFramePayload = struct {
    frame: foundation.Frame,
    allocator: std.mem.Allocator,
};

/// Wrap an owned `foundation.Frame` as a self-releasing managed frame. The frame
/// moves into a heap payload; the descriptor's `release` frees the payload and
/// the frame through `alloc`.
pub fn tryManagedFrame(alloc: std.mem.Allocator, frame: foundation.Frame) !PancakeManagedFrame {
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

/// The one body behind every `pancake_*_take_outbound`: dequeue the peer's next
/// encoded frame into `slot` as an owned managed frame. Returns
/// `PANCAKE_ERR_WOULD_BLOCK` when the outbound queue is empty (the family-wide
/// "nothing pending" code), and `PANCAKE_ERR_INTERNAL` (last error set, the
/// dequeued frame freed and not retrievable) when the frame could not be
/// wrapped for C. Shared so no two archives can drift on these codes.
pub fn takeOutboundManaged(peer: *engine.Peer, alloc: std.mem.Allocator, slot: *PancakeManagedFrame) i32 {
    const out = peer.takeOutbound() orelse return PANCAKE_ERR_WOULD_BLOCK;
    slot.* = tryManagedFrame(alloc, out) catch {
        var owned = out;
        owned.deinit();
        setLastError("take_outbound: frame wrap allocation failed", .{});
        return PANCAKE_ERR_INTERNAL;
    };
    return PANCAKE_OK;
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

// ── Allocation policy ────────────────────────────────────────────────────────

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
/// exactly equal to `alloc`'s, correct even for a size-tracking host allocator.
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

/// The allocator the *simple* C ABI path uses, the constructors that take no
/// `PancakeContext` (`pancake_peer_new`, `pancake_tcp_netlayer_new`) and
/// everything those handles own. `smp_allocator` is a thread-safe
/// general-purpose allocator: a managed frame per outbound message or event
/// costs an arena-style bump, not the `mmap`/`munmap` round-trip
/// `page_allocator` paid per frame on the wire path.
///
/// A caller that needs allocation policy creates a `PancakeContext` and uses the
/// `*_in` constructors instead; this default is the library-owned policy for the
/// callers that do not.
pub const library_allocator = std.heap.smp_allocator;

/// Adapts the C host allocation callbacks to a `std.mem.Allocator`. Heap-pinned
/// inside its `Context`, so the vtable's `ptr` (`&context.host`) stays valid for
/// the context's whole life.
pub const HostAllocator = struct {
    alloc_fn: PancakeAllocFn,
    free_fn: PancakeFreeFn,
    user_data: ?*anyopaque,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = hostAlloc,
        .resize = hostResize,
        .remap = hostRemap,
        .free = hostFree,
    };

    pub fn allocator(self: *HostAllocator) std.mem.Allocator {
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

pub const Context = struct {
    allocator: std.mem.Allocator,
    backing: Backing,
    /// Meaningful only when `backing == .host`; the heap-pinned state the
    /// `allocator` vtable points into.
    host: HostAllocator,

    pub const Backing = enum { library, host };
};

pub fn ctxFromOpaque(context: ?*PancakeContext) ?*Context {
    const ptr = context orelse return null;
    return @ptrCast(@alignCast(ptr));
}

// ── Per-thread last error ────────────────────────────────────────────────────
//
// The Zig side would otherwise hide the concrete `ReadFailed` / `WriteFailed`
// behind a flat `PANCAKE_ERR_IO`. This per-thread slot re-exposes it: a function
// that returns `_IO` first records a human-readable cause here. Each library
// that imports this leaf compiles its own copy of the slot, so libpancake_ocapn and
// libpancake_net_transport_iroh keep independent last-error state, read each through its own
// reader (`pancake_last_error` / `pancake_iroh_last_error`).

threadlocal var last_error_buf: [256]u8 = undefined;
threadlocal var last_error_len: usize = 0;

pub fn setLastError(comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(&last_error_buf, fmt, args) catch blk: {
        // Message longer than the slot: keep the truncated prefix.
        break :blk last_error_buf[0..];
    };
    last_error_len = written.len;
}

/// Copy the calling thread's last error message into `out_buf` (the body of the
/// `pancake_last_error` / `pancake_iroh_last_error` exports). Copies at most
/// `cap - 1` bytes and always NUL-terminates when `cap > 0`. Returns the full
/// message length.
pub fn lastErrorRead(out_buf: ?[*]u8, cap: usize) usize {
    const dest = out_buf orelse return last_error_len;
    if (cap == 0) return last_error_len;
    const n = @min(last_error_len, cap - 1);
    @memcpy(dest[0..n], last_error_buf[0..n]);
    dest[n] = 0;
    return last_error_len;
}

/// Clear the calling thread's last error slot.
pub fn lastErrorClear() void {
    last_error_len = 0;
}

// ── Typed OCapN value vocabulary ─────────────────────────────────────────────
//
// The fixed-layout reference/argument structs and their discriminants, plus the
// model<->C marshalling, live in this leaf so both `libpancake_ocapn`'s peer
// family and the transport archives' owning sessions
// (`pancake_tcp_session_*`, ADR-0062) speak them by layout without either
// pulling the other's exported surface (ADR-0055 / ADR-0059). The ocapn root
// (`src/c_abi/ocapn/mod.zig`) re-exports the names so `tools/header_gen.zig`'s
// reflection emits them into `pancake_ocapn.h`; the transport archives include
// that one header on the C side.

pub const PANCAKE_REF_NEAR: u32 = 0;
pub const PANCAKE_REF_FAR: u32 = 1;
pub const PANCAKE_REF_PROMISE: u32 = 2;
pub const PANCAKE_REF_STURDY: u32 = 3;
pub const PANCAKE_REF_BROKEN: u32 = 4;

/// `sub_kind` for a near/far reference: whether the position names an object or a
/// promise (the `desc:import-object` vs `desc:import-promise` distinction). The
/// SUB names are their own namespace so a `kind` value (`PANCAKE_REF_PROMISE`)
/// can never be mistaken for a `sub_kind` value or assigned to the wrong field
/// unnoticed.
pub const PANCAKE_REF_SUB_OBJECT: u32 = 0;
pub const PANCAKE_REF_SUB_PROMISE: u32 = 1;

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
/// An arbitrary-precision OCapN Integer outside `int64_t`: `bytes`/`bytes_len`
/// carry the canonical decimal magnitude (ASCII digits, no leading zero) and
/// `boolean` carries the sign (1 = negative). A magnitude that fits `int64_t`
/// belongs in `PANCAKE_ARG_INTEGER` and is refused here.
pub const PANCAKE_ARG_BIG_INTEGER: u32 = 12;

pub const PANCAKE_RESOLUTION_FULFILL: u32 = 0;
pub const PANCAKE_RESOLUTION_BREAK: u32 = 1;
/// The answer fulfilled to a three-party handoff (ADR-0009/ADR-0056): the
/// resolution carries a `desc:handoff-give` the recipient must redeem against
/// the named exporter rather than an immediate value. `PancakeResolve.handoff`
/// carries the verbatim give and the exporter's dialable locator.
pub const PANCAKE_RESOLUTION_HANDOFF: u32 = 2;

/// A capability reference. `kind` selects the meaning of `id`: a `_NEAR` export
/// position, a `_FAR` import position, or a `_PROMISE` answer position.
/// `sub_kind` is the object/promise distinction for near/far. `_STURDY` and
/// `_BROKEN` carry no payload here (use the resolution's break message for a
/// broken target).
pub const PancakeReference = extern struct {
    kind: u32,
    sub_kind: u32,
    id: u64,
};

/// A passable argument value. `kind` selects which field is live. `bytes`/
/// `bytes_len` carry `_BYTES`/`_STRING`/`_SYMBOL`/`_KEYWORD`; `items`/
/// `items_len` carry a `_LIST`'s or `_SET`'s elements. A `_TAGGED` uses both:
/// the tag in `bytes`/`bytes_len` and the value list in `items`/`items_len`.
/// A `_BIG_INTEGER` carries the canonical decimal magnitude in `bytes`/
/// `bytes_len` (ASCII digits, no leading zero) and the sign in `boolean`
/// (1 = negative); a magnitude that fits `int64_t` belongs in `_INTEGER` and
/// is refused here. On a projected (received) value the pointers alias the
/// owning arena and are valid until the matching `*_release`.
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

pub const zero_reference: PancakeReference = .{ .kind = PANCAKE_REF_BROKEN, .sub_kind = 0, .id = 0 };
pub const zero_argument: PancakeArgument = .{
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

pub const MarshalError = error{ UnsupportedValue, NullPointer, OutOfMemory };

/// Classify an inbound-dispatch error into a C ABI return code. Derived from the
/// single error taxonomy (`engine.abort_projection.classify`) so the C codes
/// cannot drift from the abort projection — and defined once here so no two
/// archives can disagree on the same error: codec/decode malformations report
/// `CODEC`, session state-machine refusals (a partner protocol violation, a
/// resource cap, an already-closed session) report `SESSION`, and host-internal
/// failures (allocation, …) report `INTERNAL`.
pub fn feedErrorToCode(err: anyerror) i32 {
    return switch (engine.abort_projection.classify(err).domain) {
        .codec => PANCAKE_ERR_CODEC,
        .session => PANCAKE_ERR_SESSION,
        .foreign => PANCAKE_ERR_INTERNAL,
    };
}

pub fn marshalErrorToCode(err: MarshalError) i32 {
    return switch (err) {
        error.UnsupportedValue => PANCAKE_ERR_UNSUPPORTED_VALUE,
        error.NullPointer => PANCAKE_ERR_NULL_POINTER,
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
    };
}

/// `PancakeLastAbort.domain`: which layer classified the failure. Codec is a
/// decode/encode malformation, session is a state-machine refusal, foreign is
/// a host-internal failure (allocation, …).
pub const PANCAKE_ABORT_DOMAIN_CODEC: u32 = 0;
pub const PANCAKE_ABORT_DOMAIN_SESSION: u32 = 1;
pub const PANCAKE_ABORT_DOMAIN_FOREIGN: u32 = 2;

/// The typed cause of a peer's most recent local dispatch failure, projected
/// to C — the ABI counterpart of `engine.Peer.lastAbort`. `domain` is a
/// `PANCAKE_ABORT_DOMAIN_*` value. When `has_kind` is nonzero, `kind_name`
/// is the wire name of the projected `op:abort` kind (e.g. "MalformedFrame");
/// when zero, the failure projected no abort (a closed session, an allocation
/// failure). All byte views are process-static — read them, never free them.
/// Declared in this leaf so the ocapn peer family and the byte-fed driver
/// family (`pancake_host_conn_last_abort`) share it by layout.
pub const PancakeLastAbort = extern struct {
    domain: u32,
    has_kind: u32,
    kind_name: ?[*]const u8,
    kind_name_len: usize,
    message: ?[*]const u8,
    message_len: usize,
    error_name: ?[*]const u8,
    error_name_len: usize,
};

/// Project an `engine.AbortInfo` into the C `PancakeLastAbort` — the one body
/// behind `pancake_peer_last_abort` and `pancake_host_conn_last_abort`, so the
/// two archives cannot drift on the projection. Every view written is
/// process-static.
pub fn lastAbortToC(info: engine.AbortInfo) PancakeLastAbort {
    return .{
        .domain = switch (info.domain) {
            .codec => PANCAKE_ABORT_DOMAIN_CODEC,
            .session => PANCAKE_ABORT_DOMAIN_SESSION,
            .foreign => PANCAKE_ABORT_DOMAIN_FOREIGN,
        },
        .has_kind = if (info.kind != null) 1 else 0,
        .kind_name = if (info.kind) |k| k.wireName().ptr else null,
        .kind_name_len = if (info.kind) |k| k.wireName().len else 0,
        .message = info.message.ptr,
        .message_len = info.message.len,
        .error_name = info.error_name.ptr,
        .error_name_len = info.error_name.len,
    };
}

pub fn sliceFromC(ptr: ?[*]const u8, len: usize) MarshalError![]const u8 {
    if (len == 0) return &.{};
    const p = ptr orelse return error.NullPointer;
    return p[0..len];
}

pub fn referenceFromC(c_ref: PancakeReference) MarshalError!model.Reference {
    const promise_sub = c_ref.sub_kind == PANCAKE_REF_SUB_PROMISE;
    return switch (c_ref.kind) {
        PANCAKE_REF_NEAR => .{ .near = .{ .export_position = model.ExportPosition.from(c_ref.id), .kind = if (promise_sub) .promise else .object } },
        PANCAKE_REF_FAR => .{ .far = .{ .import_position = model.ImportPosition.from(c_ref.id), .kind = if (promise_sub) .promise else .object } },
        PANCAKE_REF_PROMISE => .{ .promise = .{ .answer_position = model.AnswerPosition.from(c_ref.id) } },
        else => error.UnsupportedValue,
    };
}

/// Depth bound on a host-supplied argument tree. A foreign caller could nest
/// `PancakeArgument` lists/sets/tagged values arbitrarily deep and overflow the
/// native stack inside `argumentFromC`, exactly as a hostile wire frame could in
/// the codec. The value mirrors the session's default `max_nesting_depth` (64).
pub const max_marshal_depth: usize = 64;

pub fn argumentFromC(arena: std.mem.Allocator, c_arg: PancakeArgument, depth: usize) MarshalError!model.Argument {
    return argumentFromCImpl(arena, c_arg, depth, false);
}

/// `argumentFromC` with every leaf byte slice duped into `arena` as it
/// converts, so the result owns its bytes in ONE tree build. This is the
/// marshal for a caller that must sever the C storage's lifetime — the actors
/// bridge copying a behavior's reply clear of the consumer's `out_reply` —
/// where the borrowing variant would force a second full `cloneArgument` pass
/// over arrays the first build already allocated.
pub fn argumentFromCOwned(arena: std.mem.Allocator, c_arg: PancakeArgument, depth: usize) MarshalError!model.Argument {
    return argumentFromCImpl(arena, c_arg, depth, true);
}

/// The one conversion recursion behind both marshal lifetimes; `own_bytes` is
/// comptime, so each variant compiles to its own straight-line specialization
/// with no runtime mode.
fn argumentFromCImpl(arena: std.mem.Allocator, c_arg: PancakeArgument, depth: usize, comptime own_bytes: bool) MarshalError!model.Argument {
    if (depth > max_marshal_depth) return error.UnsupportedValue;
    const next = depth + 1;
    return switch (c_arg.kind) {
        PANCAKE_ARG_INTEGER => .{ .integer = c_arg.integer },
        PANCAKE_ARG_FLOAT64 => .{ .float64 = c_arg.float64 },
        PANCAKE_ARG_BOOLEAN => .{ .boolean = c_arg.boolean != 0 },
        PANCAKE_ARG_BYTES => .{ .bytes = try leafFromC(arena, c_arg, own_bytes) },
        PANCAKE_ARG_STRING => .{ .string = try leafFromC(arena, c_arg, own_bytes) },
        PANCAKE_ARG_SYMBOL => .{ .symbol = try leafFromC(arena, c_arg, own_bytes) },
        PANCAKE_ARG_VOID => .{ .void = {} },
        PANCAKE_ARG_REFERENCE => .{ .reference = try referenceFromC(c_arg.reference) },
        PANCAKE_ARG_LIST => .{ .list = try argsFromCImpl(arena, c_arg.items, c_arg.items_len, next, own_bytes) },
        PANCAKE_ARG_SET => .{ .set = try argsFromCImpl(arena, c_arg.items, c_arg.items_len, next, own_bytes) },
        PANCAKE_ARG_TAGGED => .{ .tagged = .{
            .tag = try leafFromC(arena, c_arg, own_bytes),
            .value = try argsFromCImpl(arena, c_arg.items, c_arg.items_len, next, own_bytes),
        } },
        PANCAKE_ARG_KEYWORD => .{ .keyword = try leafFromC(arena, c_arg, own_bytes) },
        PANCAKE_ARG_BIG_INTEGER => blk: {
            const big = model.BigInteger{
                .negative = c_arg.boolean != 0,
                .digits = try leafFromC(arena, c_arg, own_bytes),
            };
            // Fail closed at the boundary, like the codecs: leading zeros,
            // non-digits, or a magnitude that belongs in PANCAKE_ARG_INTEGER.
            if (!big.isCanonical()) break :blk error.UnsupportedValue;
            break :blk .{ .big_integer = big };
        },
        else => error.UnsupportedValue,
    };
}

/// A leaf's byte slice: borrowed from the C argument, or duped into `arena`
/// when the caller asked for owned bytes.
fn leafFromC(arena: std.mem.Allocator, c_arg: PancakeArgument, comptime own_bytes: bool) MarshalError![]const u8 {
    const borrowed = try sliceFromC(c_arg.bytes, c_arg.bytes_len);
    return if (own_bytes) try arena.dupe(u8, borrowed) else borrowed;
}

pub fn argsFromC(arena: std.mem.Allocator, items: ?[*]const PancakeArgument, len: usize, depth: usize) MarshalError![]const model.Argument {
    return argsFromCImpl(arena, items, len, depth, false);
}

fn argsFromCImpl(arena: std.mem.Allocator, items: ?[*]const PancakeArgument, len: usize, depth: usize, comptime own_bytes: bool) MarshalError![]const model.Argument {
    if (len == 0) return &.{};
    const p = items orelse return error.NullPointer;
    const out = try arena.alloc(model.Argument, len);
    for (0..len) |i| out[i] = try argumentFromCImpl(arena, p[i], depth, own_bytes);
    return out;
}

pub fn referenceToC(reference: model.Reference) PancakeReference {
    return switch (reference) {
        .near => |near| .{ .kind = PANCAKE_REF_NEAR, .sub_kind = if (near.kind == .promise) PANCAKE_REF_SUB_PROMISE else PANCAKE_REF_SUB_OBJECT, .id = near.export_position.int() },
        .far => |far| .{ .kind = PANCAKE_REF_FAR, .sub_kind = if (far.kind == .promise) PANCAKE_REF_SUB_PROMISE else PANCAKE_REF_SUB_OBJECT, .id = far.import_position.int() },
        .promise => |promise| .{ .kind = PANCAKE_REF_PROMISE, .sub_kind = 0, .id = promise.answer_position.int() },
        .sturdy => .{ .kind = PANCAKE_REF_STURDY, .sub_kind = 0, .id = 0 },
        .broken => .{ .kind = PANCAKE_REF_BROKEN, .sub_kind = 0, .id = 0 },
    };
}

pub fn argumentToC(arena: std.mem.Allocator, arg: model.Argument) MarshalError!PancakeArgument {
    var c_arg = zero_argument;
    switch (arg) {
        .integer => |v| {
            c_arg.kind = PANCAKE_ARG_INTEGER;
            c_arg.integer = v;
        },
        .float64 => |v| {
            c_arg.kind = PANCAKE_ARG_FLOAT64;
            c_arg.float64 = v;
        },
        .boolean => |v| {
            c_arg.kind = PANCAKE_ARG_BOOLEAN;
            c_arg.boolean = if (v) 1 else 0;
        },
        .bytes => |b| {
            c_arg.kind = PANCAKE_ARG_BYTES;
            c_arg.bytes = b.ptr;
            c_arg.bytes_len = b.len;
        },
        .string => |b| {
            c_arg.kind = PANCAKE_ARG_STRING;
            c_arg.bytes = b.ptr;
            c_arg.bytes_len = b.len;
        },
        .symbol => |b| {
            c_arg.kind = PANCAKE_ARG_SYMBOL;
            c_arg.bytes = b.ptr;
            c_arg.bytes_len = b.len;
        },
        .void => c_arg.kind = PANCAKE_ARG_VOID,
        .reference => |r| {
            c_arg.kind = PANCAKE_ARG_REFERENCE;
            c_arg.reference = referenceToC(r);
        },
        .list => |items| {
            c_arg.kind = PANCAKE_ARG_LIST;
            const arr = try argsToC(arena, items);
            c_arg.items = arr.ptr;
            c_arg.items_len = arr.len;
        },
        .set => |items| {
            c_arg.kind = PANCAKE_ARG_SET;
            const arr = try argsToC(arena, items);
            c_arg.items = arr.ptr;
            c_arg.items_len = arr.len;
        },
        .tagged => |tagged| {
            c_arg.kind = PANCAKE_ARG_TAGGED;
            c_arg.bytes = tagged.tag.ptr;
            c_arg.bytes_len = tagged.tag.len;
            const arr = try argsToC(arena, tagged.value);
            c_arg.items = arr.ptr;
            c_arg.items_len = arr.len;
        },
        .keyword => |keyword| {
            c_arg.kind = PANCAKE_ARG_KEYWORD;
            c_arg.bytes = keyword.ptr;
            c_arg.bytes_len = keyword.len;
        },
        .big_integer => |big| {
            c_arg.kind = PANCAKE_ARG_BIG_INTEGER;
            c_arg.boolean = if (big.negative) 1 else 0;
            c_arg.bytes = big.digits.ptr;
            c_arg.bytes_len = big.digits.len;
        },
        // Exhaustive on purpose: the model arms with no C mapping are named
        // here, so a new `model.Argument` arm stops this build at the boundary
        // that must decide how (or whether) the typed surface carries it,
        // rather than degrading silently to the opaque-frame fallback. `.@"struct"`
        // has no PANCAKE_ARG_STRUCT and rides the raw-frame projection instead.
        .@"error", .handoff, .@"struct" => return error.UnsupportedValue,
    }
    return c_arg;
}

pub fn argsToC(arena: std.mem.Allocator, args: []const model.Argument) MarshalError![]PancakeArgument {
    const out = try arena.alloc(PancakeArgument, args.len);
    for (args, 0..) |arg, i| out[i] = try argumentToC(arena, arg);
    return out;
}

/// Allocate a heap-pinned arena (child = the peer's allocator) to own a received
/// projection. `pancake_*_release` deinits and destroys it through that same child.
pub fn newProjectionArena(alloc: std.mem.Allocator) ?*std.heap.ArenaAllocator {
    const arena = alloc.create(std.heap.ArenaAllocator) catch return null;
    arena.* = std.heap.ArenaAllocator.init(alloc);
    return arena;
}

pub fn freeProjectionArena(owner: ?*anyopaque) void {
    const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(owner orelse return));
    const child = arena.child_allocator;
    arena.deinit();
    child.destroy(arena);
}

// ── Transport connection payload lifecycle ───────────────────────────────────

/// Modest caps on a stream-shaped transport endpoint's per-connection buffers.
/// Neither buffer needs to hold a whole frame: `writeAll` streams a large
/// outbound frame straight through the write buffer, and an inbound frame
/// larger than the read buffer accumulates in the connection's bounded spill
/// (`net.Spill`) while it is in flight. Steady per-connection memory is
/// therefore these two buffers, not `max_frame_bytes`.
pub const endpoint_read_buf_bytes: usize = 16 * 1024;
pub const endpoint_write_buf_bytes: usize = 64 * 1024;

/// The buffer/payload lifecycle every stream-shaped transport archive's
/// connection handles share (tcp and inproc; iroh's loop connections carry no
/// buffers). `Payload` declares `stream` (with `deinit`), `read_buf`,
/// `write_buf`, and `allocator`. A comptime helper, not an `export fn`, so each
/// archive compiles its own copy and the shared leaf stays symbol-free.
pub fn ConnLifecycle(comptime Payload: type) type {
    return struct {
        /// Allocate a connection payload and its buffers, leaving `.stream` for
        /// the caller to install once the connection is established. On any
        /// failure before install, release it with `abort`.
        pub fn begin(alloc: std.mem.Allocator, max_frame_bytes: usize) ?*Payload {
            const read_buf = alloc.alloc(u8, @min(max_frame_bytes, endpoint_read_buf_bytes)) catch return null;
            const write_buf = alloc.alloc(u8, @min(max_frame_bytes, endpoint_write_buf_bytes)) catch {
                alloc.free(read_buf);
                return null;
            };
            const payload = alloc.create(Payload) catch {
                alloc.free(read_buf);
                alloc.free(write_buf);
                return null;
            };
            payload.read_buf = read_buf;
            payload.write_buf = write_buf;
            payload.allocator = alloc;
            return payload;
        }

        /// Release a payload whose `.stream` was never installed.
        pub fn abort(payload: *Payload) void {
            const alloc = payload.allocator;
            alloc.free(payload.read_buf);
            alloc.free(payload.write_buf);
            alloc.destroy(payload);
        }

        /// Release an established payload: close the stream, then the buffers.
        pub fn destroy(payload: *Payload) void {
            const alloc = payload.allocator;
            payload.stream.deinit();
            alloc.free(payload.read_buf);
            alloc.free(payload.write_buf);
            alloc.destroy(payload);
        }
    };
}
