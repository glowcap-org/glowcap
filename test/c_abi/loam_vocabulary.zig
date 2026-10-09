//! C vocabulary unit proof through an attachment's actual registered decoders.
//! Shared Zig access scenarios own admission; this checks shape and held scope.
const std = @import("std");
const access = @import("loam_access");
const core = access.core;
const Value = @import("driver_core").Value;

pub fn check(service: *access.hosting.Service) !void {
    const resource: core.ResourceId = .{ .owner = @fromBackingInt(81), .slot = 4, .generation = 2 };
    const identity: [16]u8 = @splat(5);
    const unsigned: [8]u8 = @splat(255);
    const mask = [_]Value{.{ .bytes = &unsigned }};
    const bounds = [_]Value{.{ .bytes = &unsigned }};
    const args = [_]Value{ .{ .bytes = &identity }, .{ .list = &mask }, .{ .list = &bounds } };
    const derive_args = [_]Value{ args[0], args[1], args[2], .{ .integer = 0 } };
    const terms: core.Terms = .{ .scope = .{ .object = resource }, .policy = (try service.decode_derive.?(service.context, std.testing.allocator, resource, &derive_args)).ceiling.policy };
    const bound: core.Control.Powers = .{ .policy_ceiling = terms };
    const edit = [_]Value{ .{ .bytes = &unsigned }, args[0], args[1], args[2] };
    const decoded = try service.decode_control(service.context, std.testing.allocator, bound, "set-policy", &edit);
    try std.testing.expect(decoded.set_policy.scope.object.eql(resource));
    try std.testing.expectEqual(std.math.maxInt(u64), decoded.set_policy.policy.permissions);
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), decoded.set_policy.policy.bounds[0]);
    try std.testing.expectEqual(std.math.maxInt(u64), @backingInt(try service.decode_control_revision.?("set-policy", &edit)));
    try std.testing.expectError(error.Denied, service.decode_control(service.context, std.testing.allocator, .{}, "set-policy", &edit));
    for (0..edit.len) |length| try std.testing.expectError(error.InvalidArguments, service.decode_control(service.context, std.testing.allocator, bound, "set-policy", edit[0..length]));
    var invalid = edit;
    invalid[1] = .{ .bytes = identity[0..15] };
    try std.testing.expectError(error.InvalidArguments, service.decode_control(service.context, std.testing.allocator, bound, "set-policy", &invalid));
    const too_many: [17]Value = @splat(.{ .void = {} });
    invalid = edit;
    invalid[3] = .{ .list = &too_many };
    try std.testing.expectError(error.InvalidArguments, service.decode_control(service.context, std.testing.allocator, bound, "set-policy", &invalid));
    var selection = [_]Value{ .{ .void = {} }, .{ .void = {} }, .{ .integer = 1 } };
    const attenuation = [_]Value{.{ .list = &selection }};
    const lifecycle = try service.decode_attenuation.?(service.context, std.testing.allocator, .{}, &attenuation);
    try std.testing.expect(lifecycle.pause and lifecycle.policy_ceiling == null);
    selection[0] = .{ .list = &args };
    try std.testing.expectError(error.Denied, service.decode_attenuation.?(service.context, std.testing.allocator, .{}, &attenuation));
    try std.testing.expect((try service.decode_attenuation.?(service.context, std.testing.allocator, bound, &attenuation)).policy_ceiling.?.scope.object.eql(resource));
    selection[2] = .{ .integer = 32 };
    try std.testing.expectError(error.InvalidArguments, service.decode_attenuation.?(service.context, std.testing.allocator, bound, &attenuation));
}
