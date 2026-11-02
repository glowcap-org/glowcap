//! The byte-fed host's instance state: the `Instance` a `GlowcapHost` handle
//! points at, its drive owner and scratch arenas, the handle-recovery casts,
//! and the release paths both archive faces share. Declares no `export fn`.

const std = @import("std");

const actors = @import("actors");
const driver_core = @import("driver_core");
const shared = @import("c_abi_shared");

const c = @import("mod.zig");
const trace_queue = @import("trace_queue.zig");

/// The retained-capacity ceiling for the per-call scratch arenas: capacity a
/// burst grew above this is freed at the next reset, the steady-bytes posture
/// the actor layer holds on its own arenas.
pub const steady_scratch_bytes = 4096;

/// Which adapter owns transport execution and terminal release for this Host.
/// Application verbs remain Host verbs in either state. The distinction owns
/// the I/O/action-drain half and prevents two drivers from driving or freeing
/// the same core.
pub const DriveOwner = enum {
    embedder,
    driver,
};

/// The host handle's owned state: the byte-fed core plus the C-side bridge
/// registries. The `core` field is embedded by value so a `*Host` reached
/// through a session (`HostSession.host`) recovers the instance with one
/// `@fieldParentPtr`.
pub const Instance = struct {
    core: driver_core.Host,
    allocator: std.mem.Allocator,
    /// Stable identity in the owning Context's diagnostic namespace, or zero
    /// for the context-less convenience constructor, which has no Context
    /// diagnostic namespace to allocate from.
    diagnostic_id: u64,
    drive_owner: DriveOwner = .embedder,
    /// Companion attachments borrow this Host until their successful release.
    attachment_borrows: usize = 0,
    /// The C trace callback (`glowcap_host_set_trace`), bridged onto the
    /// core's sink. Null when tracing is off.
    trace_cb: ?c.GlowcapTraceCallback = null,
    trace_ctx: ?*anyopaque = null,
    /// The drained trace ring (`glowcap_host_set_trace_queue`), for an
    /// embedder that cannot take the callback. Null when none is installed.
    /// Host-scope, so a session pays nothing for it.
    trace_queue: ?*trace_queue.TraceQueue = null,
    /// Scratch for one call's inbound argument marshalling,
    /// reset at the head of each *top-level* send-shaped call. A nested
    /// (in-callback) verb bumps without resetting: a composed `turn_forward`
    /// runs its target synchronously on the outer call's marshalled argument
    /// arrays (byte payloads stay borrowed from the C caller), so the reset
    /// waits for the next top-level call to reclaim the lot.
    arg_scratch: std.heap.ArenaAllocator,
    /// Scratch owning a turn verb's projected reply (`turn_forward`), reset at
    /// the head of each projection. The reply is borrowed until the next
    /// turn verb or drive, the same lifetime the underlying near reply has.
    turn_scratch: std.heap.ArenaAllocator,
    /// Scratch owning a SETTLE action's projected `value` sub-structure
    /// (`valueToC`'s child arrays), reset at the head of each
    /// `glowcap_host_next_action`. The C children and the model value in the
    /// popped action row both die at the next `next_action` call, one
    /// lifetime sentence, the one DIAL already carries.
    completion_scratch: std.heap.ArenaAllocator,
};

/// Destroy one Host instance after its drive owner has ended all access.
/// Both archive faces call this no-export implementation. Neither calls the
/// other archive's public release symbol.
pub fn releaseInstance(inst: *Instance) ?anyerror {
    const alloc = inst.allocator;
    const failure = inst.core.deinitAfterOwnershipTransfer();
    inst.arg_scratch.deinit();
    inst.turn_scratch.deinit();
    inst.completion_scratch.deinit();
    if (inst.trace_queue) |queue| {
        queue.deinit(alloc);
        alloc.destroy(queue);
    }
    alloc.destroy(inst);
    return failure;
}

pub fn releaseFromDriver(handle: *c.GlowcapHost) ?anyerror {
    const inst = instanceFrom(handle).?;
    std.debug.assert(inst.drive_owner == .driver);
    std.debug.assert(!inst.core.withinCallback());
    return releaseInstance(inst);
}

pub fn instanceFrom(handle: ?*c.GlowcapHost) ?*Instance {
    return @ptrCast(@alignCast(handle orelse return null));
}

/// Whether the byte-fed embedder still owns transport execution for this
/// Host. Application verbs remain valid after driver adoption. Action-drain,
/// listener metadata, session mint/release, and byte-pump verbs do not.
pub fn embedderOwnsDrive(inst: *Instance, operation: []const u8) bool {
    if (inst.drive_owner == .embedder) return true;
    shared.setLastError("host: {s} refused because the Zig driver owns transport execution", .{operation});
    return false;
}

pub fn sessionFrom(handle: ?*c.GlowcapHostSession) ?*driver_core.HostSession {
    return @ptrCast(@alignCast(handle orelse return null));
}

pub fn turnFrom(handle: ?*c.GlowcapHostTurn) ?*actors.Turn {
    return @ptrCast(@alignCast(handle orelse return null));
}

/// The instance a host core is embedded in. `Instance.core` is by value, so
/// this is one field-parent hop.
pub fn instOf(core: *driver_core.Host) *Instance {
    return @fieldParentPtr("core", core);
}
