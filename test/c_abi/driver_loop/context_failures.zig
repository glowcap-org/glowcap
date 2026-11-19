//! Drain the public driver failure journal from the Context that owns it.

const std = @import("std");
const c = @import("c_abi");

const Expected = struct {
    scope: u32,
    id: u64,
    operation: []const u8,
    primary: i32,
    name: []const u8,
    secondary: i32 = c.GLOWCAP_OK,
    secondary_name: []const u8 = "",
    secondary_count: u32 = 0,
};

pub fn expectOne(context: *c.GlowcapContext, expected: Expected) !void {
    var event: c.GlowcapFailureEvent = undefined;
    var payload: [1024]u8 = undefined;
    var required: usize = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_context_next_failure(context, &event, &payload, payload.len, &required));
    try std.testing.expectEqual(c.GLOWCAP_FAILURE_LAYER_DRIVER, event.layer);
    try std.testing.expectEqual(expected.scope, event.scope_kind);
    try std.testing.expectEqual(expected.id, event.scope_id);
    try std.testing.expectEqualStrings(expected.operation, event.operation.?[0..event.operation_len]);
    try std.testing.expectEqual(expected.primary, event.primary_result);
    try std.testing.expectEqualStrings(expected.name, event.primary_name.?[0..event.primary_name_len]);
    try std.testing.expectEqual(expected.secondary, event.secondary_result);
    const secondary = if (event.secondary_name) |name| name[0..event.secondary_name_len] else "";
    try std.testing.expectEqualStrings(expected.secondary_name, secondary);
    try std.testing.expectEqual(expected.secondary_count, event.secondary_count);
    try expectEmpty(context);
}

pub fn expectEmpty(context: *c.GlowcapContext) !void {
    var event: c.GlowcapFailureEvent = undefined;
    var required: usize = 0;
    try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, c.glowcap_context_next_failure(context, &event, null, 0, &required));
    try std.testing.expectEqual(@as(usize, 0), required);
}
