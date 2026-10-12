//! Fixed-resource wire vocabulary. Decoding grants no authority. The shared
//! engine validates policy identities, ceilings, ancestry and control powers.
const std = @import("std");
const common = @import("common.zig");
const core = common.access.core;
const Value = common.driver.Value;

/// Existing derivation arguments: identity, mask list, ordered bounds, depth.
pub fn derive(_: ?*anyopaque, _: std.mem.Allocator, resource: core.ResourceId, args: []const Value) !core.GrantLedger.Issue {
    if (args.len != 4 or args[3] != .integer or args[3].integer < 0 or args[3].integer > 64) return error.InvalidArguments;
    const terms: core.Terms = .{ .scope = .{ .object = resource }, .policy = try policy(args[0..3]) };
    return .{ .ceiling = terms, .configured = terms, .delegation_depth = @intCast(args[3].integer) };
}

pub fn managed(ctx: ?*anyopaque, arena: std.mem.Allocator, resource: core.ResourceId, args: []const Value) !common.access.hosting.Service.ManagedIssue {
    if (args.len != 5 and args.len != 10) return error.InvalidArguments;
    var request = try derive(ctx, arena, resource, if (args.len == 10) &.{ args[0], args[1], args[2], args[6] } else args[0..4]);
    if (args.len == 10) {
        // Control issuance declares immutable ceiling and initial policy
        // independently. Management powers never widen the declared ceiling.
        request.configured.policy = try policy(args[3..6]);
        if (args[8] != .string or args[9] != .boolean) return error.InvalidArguments;
        request.label = try core.GrantLedger.Label.init(args[8].string);
        request.initial_status = if (args[9].boolean) .paused else .active;
    }
    return .{ .request = request, .powers = try powers(request.ceiling.scope, args[if (args.len == 10) 7 else 4]) };
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
    var result: core.Policy.Value = .{ .schema = @fromBackingInt(std.mem.readInt(u128, args[0].bytes[0..16], .big)), .permissions = std.mem.readInt(u64, mask.bytes[0..8], .big), .bounds = @splat(null) };
    for (args[2].list, 0..) |item, i| {
        if (item == .void) continue;
        if (item != .bytes or item.bytes.len != 8) return error.InvalidArguments;
        result.bounds[i] = std.mem.readInt(u64, item.bytes[0..8], .big);
    }
    return result;
}
