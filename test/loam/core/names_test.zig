//! Exact discovery index contract, exercised against volatile storage.
const std = @import("std");
const loam = @import("glowcap").loam;
const f = @import("fixture.zig");

test "loam named records preserve atomicity immutable targets and retirement floors" {
    var backend = try loam.Volatile.init(std.testing.allocator, f.id, 1024 * 1024);
    defer backend.deinit();
    const meta = try backend.open();
    defer backend.close();
    try @import("names_scenario.zig").exercise(f, &backend, meta);
}

test "loam indexed format refuses pre-index metadata even with a valid checksum" {
    var bytes = (loam.core.Metadata{ .store = f.id }).encode();
    bytes[7] = 1;
    std.mem.writeInt(u32, bytes[170..174], std.hash.Crc32.hash(bytes[0..170]), .big);
    try std.testing.expectError(error.Corrupt, loam.core.Metadata.decode(&bytes));
}
