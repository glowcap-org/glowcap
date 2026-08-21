const std = @import("std");
const sidecar = @import("iroh_sidecar_internal");

test "endpoint config layout stays exact" {
    const fields = @typeInfo(sidecar.CEndpointConfig).@"struct".field_names;
    try std.testing.expectEqual(@as(usize, 4), fields.len);
    try std.testing.expectEqualStrings("reachability", fields[0]);
    try std.testing.expectEqualStrings("connect_timeout_ms", fields[1]);
    try std.testing.expectEqualStrings("idle_timeout_ms", fields[2]);
    try std.testing.expectEqualStrings("worker_threads", fields[3]);

    try std.testing.expectEqual(@as(usize, 32), @sizeOf(sidecar.CEndpointConfig));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(sidecar.CEndpointConfig));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(sidecar.CEndpointConfig, "reachability"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(sidecar.CEndpointConfig, "connect_timeout_ms"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(sidecar.CEndpointConfig, "idle_timeout_ms"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(sidecar.CEndpointConfig, "worker_threads"));
}
