//! Allocation policy and diagnostic ownership for a C ABI context.

const std = @import("std");
const builtin = @import("builtin");
const failure_diagnostics = @import("failure_diagnostics.zig");

/// Host allocation callbacks must be thread-safe. The surface deliberately
/// omits `realloc`: both callbacks receive the exact allocation size and the
/// adapter never asks an opaque allocator to preserve alignment while moving.
pub const PancakeAllocFn = *const fn (user_data: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque;
pub const PancakeFreeFn = *const fn (user_data: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void;

pub const PancakeAllocator = extern struct {
    alloc: ?PancakeAllocFn,
    free: ?PancakeFreeFn,
    user_data: ?*anyopaque,
};

pub const PancakeContext = opaque {};

/// Library-owned policy used by constructors without an explicit Context.
pub const library_allocator = if (builtin.target.cpu.arch.isWasm() and builtin.target.os.tag == .freestanding)
    std.heap.wasm_allocator
else
    std.heap.smp_allocator;

pub const ContextAllocator = struct {
    alloc_fn: PancakeAllocFn,
    free_fn: PancakeFreeFn,
    user_data: ?*anyopaque,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = hostAlloc,
        .resize = hostResize,
        .remap = hostRemap,
        .free = hostFree,
    };

    pub fn allocator(self: *ContextAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn hostAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *ContextAllocator = @ptrCast(@alignCast(ctx));
        const raw = self.alloc_fn(self.user_data, len, alignment.toByteUnits()) orelse return null;
        return @ptrCast(raw);
    }

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
        const self: *ContextAllocator = @ptrCast(@alignCast(ctx));
        self.free_fn(self.user_data, memory.ptr, memory.len, alignment.toByteUnits());
    }
};

pub const default_failure_capacity: usize = 64;
pub const default_failure_payload_cap: usize = 512;

pub const LifecycleIds = struct {
    value: if (builtin.single_threaded) u64 else std.atomic.Value(u64),

    pub fn init() LifecycleIds {
        return .{ .value = if (builtin.single_threaded) 1 else .init(1) };
    }

    pub fn allocate(self: *LifecycleIds) error{IdentifierExhausted}!u64 {
        if (comptime builtin.single_threaded) {
            if (self.value == std.math.maxInt(u64)) return error.IdentifierExhausted;
            const current = self.value;
            self.value += 1;
            return current;
        }
        var current = self.value.load(.monotonic);
        while (current != std.math.maxInt(u64)) {
            if (self.value.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |observed| {
                current = observed;
            } else {
                return current;
            }
        }
        return error.IdentifierExhausted;
    }
};

const AllocatorPolicy = union(enum) {
    library,
    embedder: ContextAllocator,
};

pub const Context = struct {
    allocator_policy: AllocatorPolicy,
    failures: failure_diagnostics.Journal,
    lifecycle_ids: LifecycleIds,

    pub fn allocator(self: *Context) std.mem.Allocator {
        return switch (self.allocator_policy) {
            .library => library_allocator,
            .embedder => |*embedder| embedder.allocator(),
        };
    }
};

pub fn fromOpaque(context: ?*PancakeContext) ?*Context {
    const ptr = context orelse return null;
    return @ptrCast(@alignCast(ptr));
}
