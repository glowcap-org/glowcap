//! The `pancake_context_*` `export fn`s: the explicit owner of allocation policy
//! for a family of handles.
//!
//! `pancake_context_new` routes through `library_allocator`;
//! `pancake_context_new_with_allocator` routes every allocation through host
//! callbacks. Handles created *in* a context (`pancake_peer_new_in`,
//! `pancake_tcp_netlayer_new_in`) and everything they own — managed outbound and
//! event frames, adopted inbound frames, TCP connection/listener payloads and
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

const Context = abi.Context;

/// Re-exported from the shared leaf so the handle families keep reading them as
/// `ctx.library_allocator` / `ctx.ctxFromOpaque`.
pub const library_allocator = abi.library_allocator;
pub const ctxFromOpaque = abi.ctxFromOpaque;

/// Create a context that allocates through the library-owned allocator. Release
/// it with `pancake_context_release` after releasing every handle created in it.
pub export fn pancake_context_new(out_context: ?*?*PancakeContext) i32 {
    const slot = out_context orelse return PANCAKE_ERR_NULL_POINTER;
    const ctx = library_allocator.create(Context) catch return PANCAKE_ERR_INTERNAL;
    ctx.* = .library;
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

    const raw = alloc_fn(s.user_data, @sizeOf(Context), @alignOf(Context)) orelse return PANCAKE_ERR_INTERNAL;
    const ctx: *Context = @ptrCast(@alignCast(raw));
    ctx.* = .{ .embedder = .{
        .alloc_fn = alloc_fn,
        .free_fn = free_fn,
        .user_data = s.user_data,
    } };
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
    switch (ctx.*) {
        .library => library_allocator.destroy(ctx),
        .embedder => |*e| e.free_fn(e.user_data, ctx, @sizeOf(Context), @alignOf(Context)),
    }
}
