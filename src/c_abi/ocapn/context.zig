//! The `glowcap_context_*` `export fn`s: the explicit owner of allocation policy
//! for a family of handles.
//!
//! `glowcap_context_new` routes through `library_allocator`.
//! `glowcap_context_new_with_allocator` routes every allocation through host
//! callbacks. Handles created in a context (`glowcap_tcp_netlayer_new_in`,
//! for example) and everything they own (managed frames, transport payloads, and
//! their read/write buffers) allocate and free through that one context. C
//! callers still free only through the explicit release functions. The context is
//! the policy, not a `free` a caller invokes by hand.
//!
//! Lifetime: the context must outlive every handle created in it. A host-backed
//! context's allocator vtable lives inside the context object, so the handles
//! borrow it. Releasing the context first would dangle that borrow. The context
//! object itself is allocated through the host allocator, so a host-backed
//! handle family, context included, frees through host policy.
//!
//! The allocator machinery itself (`library_allocator`, `ContextAllocator`,
//! `Context`, `ctxFromOpaque`) lives in the shared leaf (`src/c_abi/shared/`) so the iroh
//! transport ABI shares one allocation policy without this file's `export fn`s.

const c = @import("mod.zig");
const abi = @import("c_abi_shared");

const GlowcapContext = c.GlowcapContext;
const GlowcapAllocator = c.GlowcapAllocator;
const GLOWCAP_OK = c.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = c.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INTERNAL = c.GLOWCAP_ERR_INTERNAL;
const GLOWCAP_ERR_INVALID_ARGUMENT = c.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_BUFFER_TOO_SMALL = c.GLOWCAP_ERR_BUFFER_TOO_SMALL;
const GLOWCAP_ERR_WOULD_BLOCK = c.GLOWCAP_ERR_WOULD_BLOCK;

const Context = abi.Context;

/// Re-exported from the shared leaf so the handle families keep reading them as
/// `ctx.library_allocator` / `ctx.ctxFromOpaque`.
pub const library_allocator = abi.library_allocator;
pub const ctxFromOpaque = abi.ctxFromOpaque;

/// Create a context that allocates through the library-owned allocator. Release
/// it with `glowcap_context_release` after releasing every handle created in it.
pub export fn glowcap_context_new(out_context: ?*?*GlowcapContext) i32 {
    abi.lastErrorClear();
    const slot = out_context orelse return GLOWCAP_ERR_NULL_POINTER;
    const ctx = library_allocator.create(Context) catch {
        abi.setLastError("context_new: OutOfMemory", .{});
        return GLOWCAP_ERR_INTERNAL;
    };
    ctx.allocator_policy = .library;
    ctx.lifecycle_ids = .init();
    ctx.failures = abi.failure_diagnostics.Journal.init(
        library_allocator,
        abi.default_failure_capacity,
        abi.default_failure_payload_cap,
    ) catch {
        library_allocator.destroy(ctx);
        abi.setLastError("context_new: OutOfMemory", .{});
        return GLOWCAP_ERR_INTERNAL;
    };
    slot.* = @ptrCast(ctx);
    return GLOWCAP_OK;
}

/// Create a context that routes every allocation in its handle family through
/// the host callbacks in `spec` (`alloc` and `free` required). The context
/// object itself is allocated through `spec.alloc`, so a later
/// `glowcap_context_release` returns it through `spec.free`. The context stores
/// the callbacks and `user_data` themselves, not a copy of what they point at:
/// both must stay valid until `glowcap_context_release`, or every later
/// allocation through the context's handles is undefined behavior.
pub export fn glowcap_context_new_with_allocator(spec: ?*const GlowcapAllocator, out_context: ?*?*GlowcapContext) i32 {
    abi.lastErrorClear();
    const slot = out_context orelse return GLOWCAP_ERR_NULL_POINTER;
    const s = spec orelse return GLOWCAP_ERR_NULL_POINTER;
    const alloc_fn = s.alloc orelse return GLOWCAP_ERR_NULL_POINTER;
    const free_fn = s.free orelse return GLOWCAP_ERR_NULL_POINTER;

    const raw = alloc_fn(s.user_data, @sizeOf(Context), @alignOf(Context)) orelse {
        abi.setLastError("context_new_with_allocator: allocator returned NULL", .{});
        return GLOWCAP_ERR_INTERNAL;
    };
    const ctx: *Context = @ptrCast(@alignCast(raw));
    ctx.allocator_policy = .{ .embedder = .{
        .alloc_fn = alloc_fn,
        .free_fn = free_fn,
        .user_data = s.user_data,
    } };
    ctx.lifecycle_ids = .init();
    const allocator = ctx.allocator();
    ctx.failures = abi.failure_diagnostics.Journal.init(
        allocator,
        abi.default_failure_capacity,
        abi.default_failure_payload_cap,
    ) catch {
        free_fn(s.user_data, ctx, @sizeOf(Context), @alignOf(Context));
        abi.setLastError("context_new_with_allocator: diagnostic storage allocation failed", .{});
        return GLOWCAP_ERR_INTERNAL;
    };
    slot.* = @ptrCast(ctx);
    return GLOWCAP_OK;
}

/// Release a context, freeing the context object through its own policy. Every
/// handle created in the context must already be released. The context's
/// allocator outlives those handles by contract, not by reference counting.
/// Releasing while a handle is still live leaves that handle's allocator
/// pointing into freed context memory, so its next allocation or release is
/// undefined behavior. There is no runtime check.
pub export fn glowcap_context_release(context: ?*GlowcapContext) void {
    const ctx = ctxFromOpaque(context) orelse return;
    const allocator = ctx.allocator();
    ctx.failures.deinit(allocator);
    switch (ctx.allocator_policy) {
        .library => library_allocator.destroy(ctx),
        .embedder => |*e| e.free_fn(e.user_data, ctx, @sizeOf(Context), @alignOf(Context)),
    }
}

/// Allocate one stable Context-local lifecycle identity. Zero is the
/// "no identity" value in diagnostic records and is never returned.
pub export fn glowcap_context_allocate_lifecycle_id(
    context: ?*GlowcapContext,
    out_id: ?*u64,
) i32 {
    abi.lastErrorClear();
    const ctx = ctxFromOpaque(context) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_id orelse return GLOWCAP_ERR_NULL_POINTER;
    slot.* = ctx.lifecycle_ids.allocate() catch {
        abi.setLastError("context_allocate_lifecycle_id: IdentifierExhausted", .{});
        return GLOWCAP_ERR_INTERNAL;
    };
    return GLOWCAP_OK;
}

/// Record one failure after its last deterministic return recipient has gone.
/// The Context copies bounded prefixes during this call and retains no pointer
/// from `report`. Ordinary returned errors must not also be reported here.
pub export fn glowcap_context_report_failure(
    context: ?*GlowcapContext,
    report: ?*const abi.GlowcapFailureReport,
) i32 {
    abi.lastErrorClear();
    const ctx = ctxFromOpaque(context) orelse return GLOWCAP_ERR_NULL_POINTER;
    const report_ptr = report orelse return GLOWCAP_ERR_NULL_POINTER;
    // Read only the fixed prefix until the caller has proved that the complete
    // current layout is present. This keeps a truthful short struct from
    // causing us to inspect bytes beyond the layout it supplied.
    if (report_ptr.abi_version != abi.GLOWCAP_FAILURE_EVENT_ABI_VERSION or
        report_ptr.struct_size < @sizeOf(abi.GlowcapFailureReport))
    {
        abi.setLastError("context_report_failure: InvalidLayout", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    const value = report_ptr.*;
    if (!abi.hasValidFailureCauses(value)) {
        abi.setLastError("context_report_failure: InvalidCause", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    const input = abi.failure_diagnostics.inputFromReport(value) catch |err| {
        abi.setLastError("context_report_failure: {s}", .{@errorName(err)});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    };
    ctx.failures.record(input);
    return GLOWCAP_OK;
}

/// Atomically claim the oldest unreturned failure. Byte views in `out_event`
/// point into `out_payload`, which remains caller-owned. When the buffer is too
/// small, `out_required` receives the exact retained byte count and the record
/// remains queued. Returns WOULD_BLOCK with required zero when the queue is
/// empty.
pub export fn glowcap_context_next_failure(
    context: ?*GlowcapContext,
    out_event: ?*abi.GlowcapFailureEvent,
    out_payload: ?[*]u8,
    payload_cap: usize,
    out_required: ?*usize,
) i32 {
    abi.lastErrorClear();
    const ctx = ctxFromOpaque(context) orelse return GLOWCAP_ERR_NULL_POINTER;
    const event = out_event orelse return GLOWCAP_ERR_NULL_POINTER;
    const required = out_required orelse return GLOWCAP_ERR_NULL_POINTER;
    var empty: [0]u8 = .{};
    const payload: []u8 = if (payload_cap == 0)
        &empty
    else
        (out_payload orelse return GLOWCAP_ERR_NULL_POINTER)[0..payload_cap];
    var claim: abi.failure_diagnostics.Claim = undefined;
    const found = ctx.failures.pop(&claim, payload, required) catch return GLOWCAP_ERR_BUFFER_TOO_SMALL;
    if (found) event.* = abi.failure_diagnostics.eventFromClaim(claim);
    return if (found) GLOWCAP_OK else GLOWCAP_ERR_WOULD_BLOCK;
}
