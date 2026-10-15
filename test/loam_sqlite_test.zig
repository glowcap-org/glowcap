//! Runs the shared durable Loam suite over SQLite, plus SQLite's own physical tests.
test {
    _ = @import("loam/engines/storage_test.zig");
    _ = @import("loam/sqlite/engine_test.zig");
    _ = @import("loam/engines/recovery_test.zig");
    _ = @import("loam/sqlite/maintenance_test.zig");
    _ = @import("loam/engines/access_test.zig");
    _ = @import("loam/engines/history_test.zig");
    _ = @import("loam/engines/observation_test.zig");
    _ = @import("loam/engines/maintenance_test.zig");
    _ = @import("loam/engines/capability_test.zig");
    _ = @import("loam/engines/managed_hosting_test.zig");
    _ = @import("loam/engines/content_graph_test.zig");
    _ = @import("loam/engines/sharing_test.zig");
    _ = @import("loam/engines/mutation_test.zig");
    _ = @import("loam/engines/management_test.zig");
    _ = @import("loam/engines/resource_lifecycle_test.zig");
    _ = @import("loam/engines/tree_crash_test.zig");
}
