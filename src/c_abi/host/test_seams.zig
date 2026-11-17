//! Zig-only seams a test reaches the C boundary through, so it can exercise a
//! transaction without another ABI symbol. Only a test build names this file.

const std = @import("std");
const actors = @import("actors");
const engine = @import("engine");
const model = @import("model");
const shared = @import("c_abi_shared");

const c = @import("mod.zig");
const hosted_behavior = @import("hosted_behavior.zig");
const instance = @import("instance.zig");
const marshal = @import("marshal.zig");

pub const error_projection = @import("error.zig");

pub fn importObject(raw: ?*c.GlowcapHostSession, position: u64) !void {
    const session_ptr = instance.sessionFrom(raw) orelse return error.NullPointer;
    try session_ptr.served.port.peer.importObject(position);
}

/// Project owned arguments through the lift onto the C layout and drop them.
pub fn projectArgs(
    host_handle: ?*c.GlowcapHost,
    raw: ?*c.GlowcapHostSession,
    allocator: std.mem.Allocator,
    args: []const model.Argument,
) !void {
    _ = try projectLifted(host_handle, raw, allocator, .fromOwnedSlice(args));
}

/// The lift's projection of views onto the C argument layout, for a test to
/// compare with `shared.viewsToC`.
pub fn projectLifted(
    host_handle: ?*c.GlowcapHost,
    raw: ?*c.GlowcapHostSession,
    arena: std.mem.Allocator,
    args: model.view.Args,
) ![]shared.GlowcapArgument {
    const inst = instance.instanceFrom(host_handle) orelse return error.NullPointer;
    const session_ptr = instance.sessionFrom(raw) orelse return error.NullPointer;
    return inst.core.projectValues(session_ptr, arena, args, arena, marshal.valuesToC, .partner);
}

/// The C behavior bridge a test wraps to hand it a delivery it shapes.
pub const hostedBridge = hosted_behavior.hostedBridge;

/// Publish a hosted actor a test built, in place of a C behavior, and return
/// the reference a C behavior can reply with.
pub fn publishHosted(raw: ?*c.GlowcapHostSession, name: []const u8, hosted: actors.HostedActor) !shared.GlowcapReference {
    const session_ptr = instance.sessionFrom(raw) orelse return error.NullPointer;
    const reference = try instance.instOf(session_ptr.host).core.sessionPublishHosted(session_ptr, name, hosted);
    return .{ .id = reference.raw() };
}

pub fn liveCapabilityCount(host_handle: ?*c.GlowcapHost) !usize {
    const inst = instance.instanceFrom(host_handle) orelse return error.NullPointer;
    return inst.core.capabilities.liveCount();
}

pub fn configuredSessionLimits(host_handle: ?*c.GlowcapHost) !engine.SessionLimits {
    const inst = instance.instanceFrom(host_handle) orelse return error.NullPointer;
    return inst.core.opts.limits;
}

pub fn importRefcount(raw: ?*c.GlowcapHostSession, position: u64) !u64 {
    const session_ptr = instance.sessionFrom(raw) orelse return error.NullPointer;
    return session_ptr.served.port.peer.session_state.importRefcount(.from(position));
}
