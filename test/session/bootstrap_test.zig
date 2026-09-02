const std = @import("std");
const glowcap = @import("glowcap");
const session = glowcap.ocapn.session;
const model = glowcap.ocapn.model;

test "registerBootstrapCap maps a swissnum to a fresh export; lookup round-trips" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();

    const export_position = try s.registerBootstrapCap("thermostat");
    try std.testing.expect(s.hasExport(export_position));
    try std.testing.expectEqual(@as(?model.ExportPosition, export_position), s.bootstrapLookup("thermostat"));
    try std.testing.expectEqual(@as(?model.ExportPosition, null), s.bootstrapLookup("unknown"));
}

test "re-registering a swissnum replaces the export id" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();

    const first = try s.registerBootstrapCap("k");
    const second = try s.registerBootstrapCap("k");
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(?model.ExportPosition, second), s.bootstrapLookup("k"));
}
