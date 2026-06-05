const std = @import("std");
const pancake = @import("pancake");
const session = pancake.session;

test "registerBootstrapCap maps a swissnum to a fresh export; lookup round-trips" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();

    const export_id = try s.registerBootstrapCap("thermostat");
    try std.testing.expect(s.hasExport(export_id));
    try std.testing.expectEqual(@as(?u64, export_id), s.bootstrapLookup("thermostat"));
    try std.testing.expectEqual(@as(?u64, null), s.bootstrapLookup("unknown"));
}

test "re-registering a swissnum replaces the export id" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();

    const first = try s.registerBootstrapCap("k");
    const second = try s.registerBootstrapCap("k");
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(?u64, second), s.bootstrapLookup("k"));
}
