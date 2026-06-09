//! Allocation policy for the C ABI: the default library allocator and the
//! `PancakeContext` that routes a handle family through host callbacks.
//!
//! `PancakeContext` is the explicit owner of allocation policy for a family of
//! handles. `pancake_context_new_default` routes through `library_allocator`;
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

const std = @import("std");

const c = @import("mod.zig");

const PancakeContext = c.PancakeContext;
const PancakeAllocator = c.PancakeAllocator;
const PancakeAllocFn = c.PancakeAllocFn;
const PancakeFreeFn = c.PancakeFreeFn;
const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;

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

pub const Context = struct {
    allocator: std.mem.Allocator,
    backing: Backing,
    /// Meaningful only when `backing == .host`; the heap-pinned state the
    /// `allocator` vtable points into.
    host: HostAllocator,

    const Backing = enum { library, host };
};

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

pub fn ctxFromOpaque(context: ?*PancakeContext) ?*Context {
    const ptr = context orelse return null;
    return @ptrCast(@alignCast(ptr));
}
