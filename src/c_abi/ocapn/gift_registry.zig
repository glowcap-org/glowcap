//! The `PancakeGiftRegistry` surface: a vat-scoped deposited-gift table a host
//! shares across the peers of one node (ADR-0009/ADR-0056). An exporter receives
//! a gift's `deposit-gift` on the gifter session and its `withdraw-gift` on the
//! recipient's separate session; binding both peers to one registry is what lets
//! the second find what the first deposited. The registry is *borrowed* by every
//! peer it is set on and must outlive all of them, free it last.

const std = @import("std");

const engine = @import("engine");

const c = @import("mod.zig");
const ctx = @import("context.zig");

const PancakePeer = c.PancakePeer;
const PancakeGiftRegistry = c.PancakeGiftRegistry;

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;

/// A library-owned gift registry plus the allocator it was created with, so
/// `pancake_gift_registry_free` releases the table's owned rows (deposited
/// references, recipient/gifter keys, handoff-count ids) through the same policy.
const RegistryHandle = struct {
    registry: engine.bootstrap.GiftRegistry = .{},
    allocator: std.mem.Allocator,
};

fn handleFromOpaque(registry: ?*PancakeGiftRegistry) ?*RegistryHandle {
    const ptr = registry orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn peerFromOpaque(peer: ?*PancakePeer) ?*engine.Peer {
    const ptr = peer orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Create a shared gift registry backed by the library allocator, writing the
/// handle into `out_registry`. Bind it onto each peer of a node with
/// `pancake_peer_set_gift_registry` before the peers exchange handoff traffic,
/// and release it with `pancake_gift_registry_free` only after every peer that
/// referenced it is released.
pub export fn pancake_gift_registry_new(out_registry: ?*?*PancakeGiftRegistry) i32 {
    const slot = out_registry orelse return PANCAKE_ERR_NULL_POINTER;
    return registryNewIn(ctx.library_allocator, slot);
}

/// Context-backed counterpart of `pancake_gift_registry_new`: the registry and
/// every gift row it owns allocate and free through `context`'s allocator
/// (ADR-0059). The context must outlive the registry.
pub export fn pancake_gift_registry_new_in(context: ?*c.PancakeContext, out_registry: ?*?*PancakeGiftRegistry) i32 {
    const c_ctx = ctx.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_registry orelse return PANCAKE_ERR_NULL_POINTER;
    return registryNewIn(c_ctx.allocator, slot);
}

fn registryNewIn(alloc: std.mem.Allocator, slot: *?*PancakeGiftRegistry) i32 {
    const handle = alloc.create(RegistryHandle) catch return PANCAKE_ERR_INTERNAL;
    handle.* = .{ .allocator = alloc };
    slot.* = @ptrCast(handle);
    return PANCAKE_OK;
}

/// Release a shared gift registry and every gift row it still owns. The caller
/// must have released (or never set this registry on) every peer first; a peer
/// still holding it would dereference freed memory. NULL is a no-op.
pub export fn pancake_gift_registry_free(registry: ?*PancakeGiftRegistry) void {
    const handle = handleFromOpaque(registry) orelse return;
    const alloc = handle.allocator;
    handle.registry.deinit(alloc);
    alloc.destroy(handle);
}

/// Bind `registry` as `peer`'s shared gift registry, so the peer's inbound
/// `deposit-gift` / `withdraw-gift` resolve against the shared table instead of
/// its private one. Set this before the peer's handshake; the registry must
/// outlive the peer. Re-binding is allowed (the peer simply points at the new
/// registry); passing a NULL registry detaches the peer back to its own table.
pub export fn pancake_peer_set_gift_registry(peer: ?*PancakePeer, registry: ?*PancakeGiftRegistry) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    if (handleFromOpaque(registry)) |handle| {
        ptr.shared_gift_registry = &handle.registry;
    } else {
        ptr.shared_gift_registry = null;
    }
    return PANCAKE_OK;
}
