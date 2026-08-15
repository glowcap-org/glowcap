const std = @import("std");
const iroh = @import("iroh");
const model = @import("model");

comptime {
    _ = @import("iroh_sidecar_stub");
}

test "iroh locator constructors preserve discovery and direct-address postures" {
    const designator = "0000000000000000000000000000000000000000000000000000000000000000";
    const discovery = iroh.locator(designator);
    try std.testing.expectEqualStrings(iroh.transport_name, discovery.transport);
    try std.testing.expectEqualStrings(designator, discovery.designator);
    try std.testing.expectEqual(@as(usize, 0), discovery.hints.entries.len);
    try std.testing.expectEqual(model.Hints.WireForm.boolean_false, discovery.hints.wire_form);

    const direct_addresses = "127.0.0.1:9099";
    var hint_storage: [1]model.HintEntry = undefined;
    const direct = iroh.locatorWithDirectAddresses(designator, direct_addresses, &hint_storage);
    try std.testing.expectEqual(@as(usize, 1), direct.hints.entries.len);
    try std.testing.expect(@intFromPtr(direct.hints.entries.ptr) == @intFromPtr(&hint_storage[0]));
    try std.testing.expectEqualStrings(direct_addresses, direct.hints.entries[0].value.string);
}
