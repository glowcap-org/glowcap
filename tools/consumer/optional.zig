//! Force linking the optional transports and both disk engines in one consumer.
const std = @import("std");

pub fn exercise() void {
    const options = @import("options");
    if (options.iroh) {
        const partner = @import("iroh").locator("<64 lowercase hex characters from the server>");
        std.mem.doNotOptimizeAway(&partner);
        std.mem.doNotOptimizeAway(&@import("iroh").Resident.init);
    }
    if (options.webrtc) std.mem.doNotOptimizeAway(&@import("webrtc").Resident.init);
    if (options.optional) {
        std.mem.doNotOptimizeAway(&@import("relay_tls").Provider.init);
        std.mem.doNotOptimizeAway(&@import("loam_lmdb").Lmdb.open);
        std.mem.doNotOptimizeAway(&@import("loam_sqlite").Sqlite.open);
    }
}
