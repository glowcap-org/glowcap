//! Discovery index metadata refuses the pre-index format.
const std = @import("std");
const loam = @import("glowcap").loam;
const f = @import("fixture.zig");

test "loam indexed format refuses pre-index metadata even with a valid checksum" {
    var bytes = (loam.core.Metadata{ .store = f.id }).encode();
    bytes[7] = 1;
    const crc = loam.core.Metadata.encoded_size - 4;
    std.mem.writeInt(u32, bytes[crc..][0..4], std.hash.Crc32.hash(bytes[0..crc]), .big);
    try std.testing.expectError(error.Corrupt, loam.core.Metadata.decode(&bytes));
}
