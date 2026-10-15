//! Runs the shared durable Loam suite over LMDB, plus LMDB's own physical tests.
test {
    _ = @import("loam/engines/storage_test.zig");
    _ = @import("loam/lmdb/storage_test.zig");
    _ = @import("loam/lmdb/page_io_test.zig");
    _ = @import("loam/lmdb/borrow_test.zig");
    _ = @import("loam/lmdb/commit_test.zig");
    _ = @import("loam/lmdb/missing_metadata_test.zig");
    _ = @import("loam/lmdb/compaction_test.zig");
    _ = @import("loam/engines/access_test.zig");
    _ = @import("loam/lmdb/owner_test.zig");
    _ = @import("loam/engines/history_test.zig");
    _ = @import("loam/engines/observation_test.zig");
    _ = @import("loam/engines/maintenance_test.zig");
    _ = @import("loam/lmdb/maintenance_test.zig");
    _ = @import("loam/engines/capability_test.zig");
    _ = @import("loam/engines/managed_hosting_test.zig");
    _ = @import("loam/engines/content_graph_test.zig");
    _ = @import("loam/engines/sharing_test.zig");
    _ = @import("loam/lmdb/reference_test.zig");
    _ = @import("loam/engines/mutation_test.zig");
    _ = @import("loam/engines/management_test.zig");
    _ = @import("loam/engines/resource_lifecycle_test.zig");
    _ = @import("loam/engines/tree_crash_test.zig");
}
