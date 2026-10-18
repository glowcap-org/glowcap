//! The share and control wire vocabulary every binding speaks: each decoder
//! scopes a request to the one resource it names. Decoding grants no
//! authority. The shared engine validates policy identities, ceilings,
//! ancestry and control powers.
const std = @import("std");
const core = @import("loam_access_core");
const Value = @import("driver_core").Value;
const Service = @import("service.zig").Service;

/// Derivation arguments: scope, identity, mask list, ordered bounds, depth.
/// The scope is the symbol `object` for the named resource alone or `subtree`
/// for it and every descendant, including ones added later.
pub fn derive(_: ?*anyopaque, _: std.mem.Allocator, resource: core.ResourceId, args: []const Value) !core.GrantLedger.Issue {
    if (args.len != 5 or args[4] != .integer or args[4].integer < 0 or args[4].integer > core.max_depth) return error.InvalidArguments;
    const terms: core.Terms = .{ .scope = try shareScope(resource, args[0]), .policy = try policy(args[1..4]) };
    return .{ .ceiling = terms, .configured = terms, .delegation_depth = @intCast(args[4].integer) };
}

/// [derivation arguments, powers], or [scope, ceiling policy, initial policy,
/// depth, powers, label, paused]. Ceiling and initial policy share one scope.
pub fn managed(ctx: ?*anyopaque, arena: std.mem.Allocator, resource: core.ResourceId, args: []const Value) !Service.ManagedIssue {
    if (args.len != 6 and args.len != 11) return error.InvalidArguments;
    var request = try derive(ctx, arena, resource, if (args.len == 11) &.{ args[0], args[1], args[2], args[3], args[7] } else args[0..5]);
    if (args.len == 11) {
        // Control issuance declares immutable ceiling and initial policy
        // independently. Management powers never widen the declared ceiling.
        request.configured.policy = try policy(args[4..7]);
        if (args[9] != .string or args[10] != .boolean) return error.InvalidArguments;
        request.label = try core.GrantLedger.Label.init(args[9].string);
        request.initial_status = if (args[10].boolean) .paused else .active;
    }
    return .{ .request = request, .powers = try powers(request.ceiling.scope, args[if (args.len == 11) 8 else 5]) };
}

fn shareScope(resource: core.ResourceId, value: Value) !core.Scope {
    if (value != .symbol) return error.InvalidArguments;
    if (std.mem.eql(u8, value.symbol, "object")) return .{ .object = resource };
    if (std.mem.eql(u8, value.symbol, "subtree")) return .{ .owned_subtree = resource };
    return error.InvalidArguments;
}

/// Policy edits preserve the held control's management scope. No wire object
/// identity or trusted embedding callback can replace that scope in this profile.
pub fn edit(_: ?*anyopaque, _: std.mem.Allocator, bound: core.Control.Powers, verb: []const u8, args: []const Value) !core.Control.Edit {
    _ = try revision(verb, args);
    const values = args[1..];
    if (std.mem.eql(u8, verb, "set-policy")) {
        const ceiling = bound.policy_ceiling orelse return error.Denied;
        return .{ .set_policy = .{ .scope = ceiling.scope, .policy = try policy(values) } };
    }
    if (std.mem.eql(u8, verb, "set-label")) {
        if (values.len != 1 or values[0] != .string) return error.InvalidArguments;
        return .{ .set_label = try core.GrantLedger.Label.init(values[0].string) };
    }
    return lifecycle(verb, values);
}

/// The lifecycle edits every control speaks, each without arguments.
pub fn lifecycle(verb: []const u8, args: []const Value) !core.Control.Edit {
    if (args.len != 0) return error.InvalidArguments;
    if (std.mem.eql(u8, verb, "pause")) return .pause;
    if (std.mem.eql(u8, verb, "resume")) return .resume_access;
    if (std.mem.eql(u8, verb, "revoke")) return .revoke;
    return error.NoSuchMethod;
}

pub fn revision(_: []const u8, args: []const Value) !core.Revision {
    if (args.len == 0) return error.InvalidArguments;
    return revisionOf(args[0]);
}

/// A revision on the wire: its big-endian bytes.
pub fn revisionOf(value: Value) !core.Revision {
    return @fromBackingInt(try unsigned(u64, value));
}

/// An unsigned scalar on the wire: exactly its big-endian bytes.
fn unsigned(comptime T: type, value: Value) !T {
    if (value != .bytes or value.bytes.len != @sizeOf(T)) return error.InvalidArguments;
    return std.mem.readInt(T, value.bytes[0..@sizeOf(T)], .big);
}

pub fn attenuate(_: ?*anyopaque, _: std.mem.Allocator, bound: core.Control.Powers, args: []const Value) !core.Control.Powers {
    if (args.len != 1) return error.InvalidArguments;
    // A control without policy-edit authority can still narrow lifecycle powers.
    // Requesting an editing ceiling requires a held scope; it never mints one.
    const scope = if (bound.policy_ceiling) |ceiling| ceiling.scope else if (bound.issue_ceiling) |ceiling| ceiling.scope else null;
    return powers(scope, args[0]);
}

/// [optional edit policy, optional issuance policy, independent power mask].
/// slices borrow the retained invocation and no additional call allocation exists.
fn powers(scope: ?core.Scope, value: Value) !core.Control.Powers {
    if (value != .list or value.list.len != 3) return error.InvalidArguments;
    const mask = value.list[2];
    if (mask != .integer or mask.integer < 0 or mask.integer > std.math.maxInt(PowerMask)) return error.InvalidArguments;
    const bits: PowerBits = @bitCast(@as(PowerMask, @intCast(mask.integer)));
    var result: core.Control.Powers = .{ .pause = bits.pause, .resume_access = bits.resume_access, .revoke = bits.revoke, .inspect = bits.inspect, .delegate_control = bits.delegate_control };
    if (value.list[0] != .void) {
        if (value.list[0] != .list) return error.InvalidArguments;
        result.policy_ceiling = .{ .scope = scope orelse return error.Denied, .policy = try policy(value.list[0].list) };
    }
    if (value.list[1] != .void) {
        if (value.list[1] != .list) return error.InvalidArguments;
        result.issue_ceiling = .{ .scope = scope orelse return error.Denied, .policy = try policy(value.list[1].list) };
    }
    return result;
}

/// The independent power mask on the wire, lowest bit first.
const PowerMask = u5;
const PowerBits = packed struct(PowerMask) { pause: bool, resume_access: bool, revoke: bool, inspect: bool, delegate_control: bool };

fn policy(args: []const Value) !core.Policy.Value {
    if (args.len != 3 or args[1] != .list or args[1].list.len != 1 or args[2] != .list or args[2].list.len > core.Policy.max_constraints) return error.InvalidArguments;
    var result: core.Policy.Value = .{ .schema = @fromBackingInt(try unsigned(u128, args[0])), .permissions = try unsigned(u64, args[1].list[0]) };
    for (args[2].list, 0..) |item, i| {
        if (item == .void) continue;
        result.setBound(i, try unsigned(u64, item));
    }
    return result;
}
