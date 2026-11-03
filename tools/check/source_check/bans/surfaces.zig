//! Ban rows: unowned deferral markers, the test-only surface, and the Rooms
//! environment namespace.

const bans = @import("../bans.zig");
const Ban = bans.Ban;
const Where = bans.Where;

/// An unowned deferral marker in first-party source is a decision hidden in a
/// comment. The boundary it defers belongs where the release bar can see it:
/// `docs/boundaries.md`, `docs/roadmap.md`, or an ADR, or the fix lands now,
/// which prerelease already names as the default verdict. Third-party and
/// generated trees (extracted Zig packages, cargo `target/`) are skipped, and
/// this file is excluded because the table must name the markers it bans.
pub const deferral_markers: []const Ban = blk: {
    const needles: []const []const u8 = &.{ "TODO", "FIXME", "XXX:", "HACK:" };
    const why = "an unowned deferral marker hides a decision; fix it now (prerelease) or record the boundary in docs/boundaries.md, docs/roadmap.md, or an ADR";
    const dirs = [_][]const u8{
        "src",        "cli",      "test", "tools",
        "examples",   "bench",    "apps", "interop",
        "transports", "bindings", "ui",   "ci",
    };
    var rows: [dirs.len + 1]Ban = undefined;
    for (rows[0..dirs.len], dirs) |*row, dir| {
        row.* = .{
            .where = .{
                .tree = .{
                    .dir = dir,
                    .suffixes = &.{
                        ".zig", ".rs", ".py", ".rkt", ".ts",   ".js",
                        ".c",   ".h",  ".sh", ".css", ".html",
                    },
                    .exclude = &.{"tools/check/source_check/bans/surfaces.zig"},
                },
            },
            .kind = .forbid,
            .needles = needles,
            .check = "deferral-markers",
            .why = why,
        };
    }
    // The build scripts live at their roots, outside every tree above.
    rows[dirs.len] = .{
        .where = .{ .files = &.{ "build.zig", "site/build.zig" } },
        .kind = .forbid,
        .needles = needles,
        .check = "deferral-markers",
        .why = why,
    };
    const frozen = rows;
    break :blk &frozen;
};

/// White-box helpers stay behind the conditional `driver.core.testing`
/// namespace instead of becoming methods or direct exports on production
/// types and barrels.
pub const test_only_surface: []const Ban = &.{
    .{
        .where = .{ .file = "src/driver/core/host.zig" },
        .kind = .forbid,
        .needles = &.{ "pub fn testing", "pub const testing" },
        .check = "test-only-surface",
        .why = "Host white-box helpers belong under the test-build-only driver.core.testing namespace",
    },
    .{
        .where = .{ .file = "src/driver/core/mod.zig" },
        .kind = .forbid,
        .needles = &.{ "\npub fn emitStatelessAfter", "\npub const emitStatelessAfter" },
        .check = "test-only-surface",
        .why = "direct stateless-GC emission is white-box support, not a production driver.core export",
    },
    .{
        .where = .{ .files = &.{
            "src/driver/core/host/action.zig",
            "src/driver/core/host/pump.zig",
        } },
        .kind = .forbid,
        .needles = &.{ "pub fn testingMarkDirty", "pub fn testingQueueUniqueSessionAction" },
        .check = "test-only-surface",
        .why = "white-box pump helpers live under a compile-time-empty testing namespace, never as ordinary public functions",
    },
    .{
        .where = .{ .file = "src/driver/core/host.zig" },
        .kind = .forbid,
        .needles = &.{ "pub const markSessionTerminating", "pub const advanceCloseLifecycle" },
        .check = "host-internal-surface",
        .why = "close transaction steps belong to the private host_close sibling, not the public Host method set",
    },
    .{
        .where = .{ .files = &.{
            "src/c_abi/host/host.zig",
            "src/driver/host_runtime.zig",
        } },
        .kind = .forbid,
        .needles = &.{
            "inst.core.closeDeadline()",
            "inst.core.nextSessionCloseDeadline()",
            "self.core.closeDeadline()",
            "self.core.nextSessionCloseDeadline()",
        },
        .check = "c-abi-policy-surface",
        .why = "adapters project Host.closeWaitMs; Host/session deadline selection stays in the sans-I/O core",
    },
};

/// The rooms application's environment namespace: every env var it reads or
/// documents is `GLOWCAP_ROOMS_*`, so a deployment's environment sorts by
/// product. A bare `ROOMS_*` string is either a stale name or a new knob
/// minted outside the namespace. The announce tokens (`ROOMS-…`) are dashes
/// and stay untouched.
pub const rooms_env_namespace: []const Ban = &.{
    .{
        .where = .{ .tree = .{
            .dir = "apps/rooms",
            .suffixes = &.{ ".ts", ".tsx", ".md", ".py", ".rkt", ".rs", ".zig", ".yml" },
        } },
        .kind = .forbid,
        .needles = &.{ "\"ROOMS_", "'ROOMS_", "`ROOMS_" },
        .check = "rooms-env-namespace",
        .why = "rooms env vars are namespaced GLOWCAP_ROOMS_*; a bare ROOMS_* name is outside the product's namespace",
    },
    .{
        .where = .{ .tree = .{
            .dir = "interop",
            .suffixes = &.{ ".ts", ".md" },
        } },
        .kind = .forbid,
        .needles = &.{ "\"ROOMS_", "'ROOMS_", "`ROOMS_" },
        .check = "rooms-env-namespace",
        .why = "rooms env vars are namespaced GLOWCAP_ROOMS_*; a bare ROOMS_* name is outside the product's namespace",
    },
    .{
        .where = .{ .tree = .{
            .dir = "conformance/goblins-peer/racket",
            .suffixes = &.{".rkt"},
        } },
        .kind = .forbid,
        .needles = &.{ "\"ROOMS_", "'ROOMS_", "`ROOMS_" },
        .check = "rooms-env-namespace",
        .why = "rooms env vars are namespaced GLOWCAP_ROOMS_*; a bare ROOMS_* name is outside the product's namespace",
    },
};
