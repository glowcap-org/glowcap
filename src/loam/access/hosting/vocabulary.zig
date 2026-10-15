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
    if (args.len != 5 or args[4] != .integer or args[4].integer < 0 or args[4].integer > 64) return error.InvalidArguments;
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
    if (values.len != 0) return error.InvalidArguments;
    if (std.mem.eql(u8, verb, "pause")) return .pause;
    if (std.mem.eql(u8, verb, "resume")) return .resume_access;
    if (std.mem.eql(u8, verb, "revoke")) return .revoke;
    return error.NoSuchMethod;
}

pub fn revision(_: []const u8, args: []const Value) !core.Revision {
    if (args.len == 0 or args[0] != .bytes or args[0].bytes.len != 8) return error.InvalidArguments;
    return @fromBackingInt(std.mem.readInt(u64, args[0].bytes[0..8], .big));
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
    if (mask != .integer or mask.integer < 0 or mask.integer > 31) return error.InvalidArguments;
    var result: core.Control.Powers = .{ .pause = mask.integer & 1 != 0, .resume_access = mask.integer & 2 != 0, .revoke = mask.integer & 4 != 0, .inspect = mask.integer & 8 != 0, .delegate_control = mask.integer & 16 != 0 };
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

fn policy(args: []const Value) !core.Policy.Value {
    if (args.len != 3 or args[0] != .bytes or args[0].bytes.len != 16 or args[1] != .list or args[1].list.len != 1 or args[2] != .list or args[2].list.len > 16) return error.InvalidArguments;
    const mask = args[1].list[0];
    if (mask != .bytes or mask.bytes.len != 8) return error.InvalidArguments;
    var result: core.Policy.Value = .{ .schema = @fromBackingInt(std.mem.readInt(u128, args[0].bytes[0..16], .big)), .permissions = std.mem.readInt(u64, mask.bytes[0..8], .big) };
    for (args[2].list, 0..) |item, i| {
        if (item == .void) continue;
        if (item != .bytes or item.bytes.len != 8) return error.InvalidArguments;
        result.setBound(i, std.mem.readInt(u64, item.bytes[0..8], .big));
    }
    return result;
}
