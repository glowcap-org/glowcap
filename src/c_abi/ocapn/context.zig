//! The `pancake_context_*` `export fn`s: the explicit owner of allocation policy
//! for a family of handles.
//!
//! `pancake_context_new` routes through `library_allocator`;
//! `pancake_context_new_with_allocator` routes every allocation through host
//! callbacks. Handles created *in* a context (`pancake_tcp_netlayer_new_in`,
//! for example) and everything they own — managed frames, transport payloads and
//! their read/write buffers — allocate and free through that one context. C
//! callers still free only through the explicit release functions; the context is
//! the policy, never a `free` a caller invokes by hand.
//!
//! Lifetime: the context must outlive every handle created in it. A host-backed
//! context's allocator vtable lives inside the context object, so the handles
//! borrow it; releasing the context first would dangle that borrow. The context
//! object itself is allocated through the host allocator, so a host-backed
//! handle family — context included — frees entirely through host policy.
//!
//! The allocator machinery itself (`library_allocator`, `ContextAllocator`,
//! `Context`, `ctxFromOpaque`) lives in the shared leaf (`src/c_abi/shared/`) so the iroh
//! transport ABI shares one allocation policy without this file's `export fn`s.

const c = @import("mod.zig");
const abi = @import("c_abi_shared");

const PancakeContext = c.PancakeContext;
const PancakeAllocator = c.PancakeAllocator;
const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_BUFFER_TOO_SMALL = c.PANCAKE_ERR_BUFFER_TOO_SMALL;
const PANCAKE_ERR_WOULD_BLOCK = c.PANCAKE_ERR_WOULD_BLOCK;

const Context = abi.Context;

/// Re-exported from the shared leaf so the handle families keep reading them as
/// `ctx.library_allocator` / `ctx.ctxFromOpaque`.
pub const library_allocator = abi.library_allocator;
pub const ctxFromOpaque = abi.ctxFromOpaque;

/// Create a context that allocates through the library-owned allocator. Release
/// it with `pancake_context_release` after releasing every handle created in it.
pub export fn pancake_context_new(out_context: ?*?*PancakeContext) i32 {
    const slot = out_context orelse return PANCAKE_ERR_NULL_POINTER;
    const ctx = library_allocator.create(Context) catch {
        abi.setLastError("context_new: OutOfMemory", .{});
        return PANCAKE_ERR_INTERNAL;
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
        return PANCAKE_ERR_INTERNAL;
    };
    slot.* = @ptrCast(ctx);
    return PANCAKE_OK;
}

/// Create a context that routes every allocation in its handle family through
/// the host callbacks in `spec` (`alloc` and `free` required). The context
/// object itself is allocated through `spec.alloc`, so a later
/// `pancake_context_release` returns it through `spec.free`. The context stores
/// the callbacks and `user_data` themselves, not a copy of what they point at:
/// both must stay valid until `pancake_context_release`, or every later
/// allocation through the context's handles is undefined behavior.
pub export fn pancake_context_new_with_allocator(spec: ?*const PancakeAllocator, out_context: ?*?*PancakeContext) i32 {
    const slot = out_context orelse return PANCAKE_ERR_NULL_POINTER;
    const s = spec orelse return PANCAKE_ERR_NULL_POINTER;
    const alloc_fn = s.alloc orelse return PANCAKE_ERR_NULL_POINTER;
    const free_fn = s.free orelse return PANCAKE_ERR_NULL_POINTER;

    const raw = alloc_fn(s.user_data, @sizeOf(Context), @alignOf(Context)) orelse {
        abi.setLastError("context_new_with_allocator: allocator returned NULL", .{});
        return PANCAKE_ERR_INTERNAL;
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
        return PANCAKE_ERR_INTERNAL;
    };
    slot.* = @ptrCast(ctx);
    return PANCAKE_OK;
}

/// Release a context, freeing the context object through its own policy. Every
/// handle created in the context must already be released; the context's
/// allocator outlives those handles by contract, not by reference counting.
/// Releasing while a handle is still live leaves that handle's allocator
/// pointing into freed context memory, so its next allocation or release is
/// undefined behavior; there is no runtime check.
pub export fn pancake_context_release(context: ?*PancakeContext) void {
    const ctx = ctxFromOpaque(context) orelse return;
    const allocator = ctx.allocator();
    ctx.failures.deinit(allocator);
    switch (ctx.allocator_policy) {
        .library => library_allocator.destroy(ctx),
        .embedder => |*e| e.free_fn(e.user_data, ctx, @sizeOf(Context), @alignOf(Context)),
    }
}

/// Allocate one stable Context-local lifecycle identity. Zero remains the
/// explicit "no identity" value in diagnostic records and is never returned.
pub export fn pancake_context_allocate_lifecycle_id(
    context: ?*PancakeContext,
    out_id: ?*u64,
) i32 {
    const ctx = ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_id orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = ctx.lifecycle_ids.allocate() catch {
        abi.setLastError("context_allocate_lifecycle_id: IdentifierExhausted", .{});
        return PANCAKE_ERR_INTERNAL;
    };
    return PANCAKE_OK;
}

/// Record one failure after its last deterministic return recipient has gone.
/// The Context copies bounded prefixes during this call and retains no pointer
/// from `report`. Ordinary returned errors must not also be reported here.
pub export fn pancake_context_report_failure(
    context: ?*PancakeContext,
    report: ?*const abi.PancakeFailureReport,
) i32 {
    const ctx = ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const report_ptr = report orelse return PANCAKE_ERR_NULL_POINTER;
    // Read only the fixed prefix until the caller has proved that the complete
    // current layout is present. This keeps a truthful short struct from
    // causing us to inspect bytes beyond the layout it supplied.
    if (report_ptr.abi_version != abi.PANCAKE_FAILURE_EVENT_ABI_VERSION or
        report_ptr.struct_size < @sizeOf(abi.PancakeFailureReport))
    {
        abi.setLastError("context_report_failure: InvalidLayout", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    const value = report_ptr.*;
    if (!abi.hasValidFailureCauses(value)) {
        abi.setLastError("context_report_failure: InvalidCause", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    const input = abi.failure_diagnostics.inputFromReport(value) catch |err| {
        abi.setLastError("context_report_failure: {s}", .{@errorName(err)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    ctx.failures.record(input);
    return PANCAKE_OK;
}

/// Atomically claim the oldest unreturned failure. Byte views in `out_event`
/// point into `out_payload`, which remains caller-owned. When the buffer is too
/// small, `out_required` receives the exact retained byte count and the record
/// remains queued. Returns WOULD_BLOCK with required zero when the queue is
/// empty.
pub export fn pancake_context_next_failure(
    context: ?*PancakeContext,
    out_event: ?*abi.PancakeFailureEvent,
    out_payload: ?[*]u8,
    payload_cap: usize,
    out_required: ?*usize,
) i32 {
    const ctx = ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const event = out_event orelse return PANCAKE_ERR_NULL_POINTER;
    const required = out_required orelse return PANCAKE_ERR_NULL_POINTER;
    var empty: [0]u8 = .{};
    const payload: []u8 = if (payload_cap == 0)
        &empty
    else
        (out_payload orelse return PANCAKE_ERR_NULL_POINTER)[0..payload_cap];
    var claim: abi.failure_diagnostics.Claim = undefined;
    const found = ctx.failures.pop(&claim, payload, required) catch return PANCAKE_ERR_BUFFER_TOO_SMALL;
    if (found) event.* = abi.failure_diagnostics.eventFromClaim(claim);
    return if (found) PANCAKE_OK else PANCAKE_ERR_WOULD_BLOCK;
}
