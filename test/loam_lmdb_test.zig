//! Native Loam storage and managed-record tests share the optional LMDB graph.
test {
    _ = @import("loam/lmdb/storage_test.zig");
    _ = @import("loam/lmdb/compaction_test.zig");
    _ = @import("loam/lmdb/access_test.zig");
    _ = @import("loam/lmdb/owner_test.zig");
    _ = @import("loam/lmdb/history_test.zig");
    _ = @import("loam/lmdb/observation_test.zig");
    _ = @import("loam/lmdb/maintenance_test.zig");
    _ = @import("loam/lmdb/capability_test.zig");
    _ = @import("loam/lmdb/managed_hosting_test.zig");
    _ = @import("loam/lmdb/sharing_test.zig");
    _ = @import("loam/lmdb/reference_test.zig");
    _ = @import("loam/lmdb/mutation_test.zig");
    _ = @import("loam/lmdb/management_test.zig");
    _ = @import("loam/lmdb/resource_lifecycle_test.zig");
}
