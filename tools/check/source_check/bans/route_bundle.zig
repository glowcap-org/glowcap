//! Ban rows: route-bundle parser authority.

const bans = @import("../bans.zig");
const Ban = bans.Ban;

/// Handoff fallback and id route lists share one model-owned parser and cap
/// table, id dialability has one Session owner.
pub const rows: []const Ban = &.{
    .{
        .where = .{ .file = "src/ocapn/model/route_bundle.zig" },
        .kind = .require,
        .needles = &.{"max_route_list_count"},
        .check = "route-bundle-authority",
        .why = "model.route_bundle owns route-list count limits",
    },
    .{
        .where = .{ .file = "src/ocapn/model/route_bundle.zig" },
        .kind = .require,
        .needles = &.{"max_route_list_bytes"},
        .check = "route-bundle-authority",
        .why = "model.route_bundle owns route-list byte limits",
    },
    .{
        .where = .{ .file = "src/ocapn/model/route_bundle.zig" },
        .kind = .require,
        .needles = &.{"fromExporterUri"},
        .check = "route-bundle-authority",
        .why = "model.route_bundle owns handoff exporter URI parsing",
    },
    .{
        .where = .{ .file = "src/ocapn/model/route_bundle.zig" },
        .kind = .require,
        .needles = &.{"fromIdLocator"},
        .check = "route-bundle-authority",
        .why = "model.route_bundle owns id route-list parsing",
    },
    .{
        .where = .{ .file = "src/ocapn/model/route_bundle.zig" },
        .kind = .require,
        .needles = &.{"fromPeerLocator"},
        .check = "route-bundle-authority",
        .why = "model.route_bundle owns route-list parsing from decoded locators",
    },
    .{
        .where = .{ .file = "src/ocapn/engine/node/redeem/plan.zig" },
        .kind = .require,
        .needles = &.{"model.parseExporterRouteBundleUri"},
        .check = "route-bundle-authority",
        .why = "Node redeem asks the model-owned route-bundle parser before applying dialability policy",
    },
    .{
        .where = .{ .file = "src/ocapn/session/id_route.zig" },
        .kind = .require,
        .needles = &.{ "validateBundle", "provesKeyDesignator", "route_key.eql(expected)" },
        .check = "route-bundle-authority",
        .why = "session.id_route owns id route admission and same-key proof",
    },
    .{
        .where = .{ .file = "src/ocapn/engine/node/redeem/plan.zig" },
        .kind = .require,
        .needles = &.{"id_route.validateBundle"},
        .check = "route-bundle-authority",
        .why = "Node redeem applies the shared id route admission policy",
    },
    .{
        .where = .{ .file = "src/ocapn/engine/node/redeem/plan.zig" },
        .kind = .forbid,
        .needles = &.{ "splitScalar", "max_alt_locator_count", "max_alt_locator_bytes" },
        .check = "route-bundle-authority",
        .why = "Node redeem must not duplicate route-list splitting or caps",
    },
};
