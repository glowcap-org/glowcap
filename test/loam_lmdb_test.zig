//! Native Loam storage and managed-record tests share the optional LMDB graph.
test {
    _ = @import("loam/lmdb/storage_test.zig");
    _ = @import("loam/lmdb/access_test.zig");
    _ = @import("loam/lmdb/owner_test.zig");
    _ = @import("loam/lmdb/capability_test.zig");
    _ = @import("loam/lmdb/managed_hosting_test.zig");
    _ = @import("loam/lmdb/sharing_test.zig");
}
