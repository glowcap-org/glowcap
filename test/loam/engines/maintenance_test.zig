//! Cleanup receipts, churn, and retired-result refusal run over any durable engine.
const std = @import("std");
const h = @import("../access/hosting_fixture.zig");
const fixture = @import("engine_fixture");

test "loam engine maintenance terminal receipts and publication barriers share the live CapTP path" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try fixture.open(tmp.path, .create, h.f.store_id);
    defer db.close() catch unreachable;
    var store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    try @import("../access/maintenance_hosted_cases.zig").replay(&store, &db, @import("loam_test_support").collect);
    try @import("loam_test_support").collect(&store, &db);
    try std.testing.expectEqual(@as(u64, 1), store.metadata.objects);
}

test "loam engine maintenance churn reclaims payload while preserving delegation and allocation floors" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try fixture.open(tmp.path, .create, h.f.store_id);
    defer db.close() catch unreachable;
    var store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    try @import("../access/maintenance_cases.zig").churn(&store, &db, @import("loam_test_support").collect);
}

test "loam engine maintenance refuses a retired mutation result without retiring issuer control" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try fixture.open(tmp.path, .create, h.f.store_id);
    defer db.close() catch unreachable;
    var store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    try @import("../access/maintenance_hosted_cases.zig").controlReceipt(&store, &db);
}
