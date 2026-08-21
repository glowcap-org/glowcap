//! Ban rows: sturdyref and host-action authority vocabulary.

const bans = @import("../bans.zig");
const Ban = bans.Ban;
const Where = bans.Where;

pub const sturdyref_authority: []const Ban = blk: {
    const dirs = [_][]const u8{ "src", "include", "bindings", "test", "tools", "interop", "examples", "apps", "cli" };
    var rows: [dirs.len]Ban = undefined;
    for (rows[0..], dirs) |*row, dir| {
        row.* = .{
            .where = .{ .tree = .{
                .dir = dir,
                .suffixes = &.{ ".zig", ".h", ".rs", ".py", ".rkt", ".ts" },
                .skip_dirs = &.{ "zig-pkg/", "target/", "node_modules/", ".zig-cache/", "zig-out/" },
                .exclude = &.{"tools/check/source_check/bans/authority.zig"},
            } },
            .kind = .forbid,
            .needles = &.{ "pancake_locator_swissnum", "is_sturdyref" },
            .check = "sturdyref-authority",
            .why = "peer locators and authority-bearing sturdyrefs are distinct values and handles; do not restore a discriminator-shaped union",
        };
    }
    const frozen = rows;
    break :blk &frozen;
};

/// Host actions carry CapTP sessions, not transport connections. Keep the
/// generated mirrors and their hand-written consumers on that one contract
/// without banning legitimate connection vocabulary in transport adapters.
pub const host_action_session_vocabulary: []const Ban = &.{
    .{
        .where = .{ .files = &.{
            "bindings/python/pancake/_action.py",
            "bindings/python/pancake/_ffi_host.py",
            "bindings/racket/private/host-action-gen.rkt",
            "bindings/racket/private/loop/core.rkt",
            "bindings/rust/src/session.rs",
            "bindings/rust/src/session_shared.rs",
            "tools/gen/binding/host_action.zig",
        } },
        .kind = .forbid,
        .needles = &.{
            "a.conn_ptr",
            "aliases={\"session\": \"conn\"}",
            "PancakeHostAction-conn",
            "session-vow-conn",
            "fn raw_conn(&self) -> *mut ffi::PancakeHostSession",
            "self.shared.raw_conn()",
        },
        .check = "host-action-session-vocabulary",
        .why = "Host actions and PancakeHostSession mirrors use session vocabulary directly; prerelease keeps no connection-named aliases",
    },
};

/// Sturdyref swissnum path spelling is a CapTP profile fact. A generic C or
/// binding helper must receive that profile explicitly instead of falling back
/// to the model's 1.0 convenience verbs.
pub const sturdyref_profile_authority: []const Ban = &.{
    .{
        .where = .{ .file = "src/c_abi/ocapn/uri.zig" },
        .kind = .forbid,
        .needles = &.{
            "model.uri.parseSturdyref(allocator",
            "model.uri.writeSturdyref(alloc",
        },
        .check = "sturdyref-profile-authority",
        .why = "the C URI surface must select swissnum spelling through the caller's CapTP profile",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/locator.ts" },
        .kind = .require,
        .needles = &.{"parseSturdyRef(uri: string, captpVersion: CaptpVersion)"},
        .check = "sturdyref-profile-authority",
        .why = "TypeScript sturdyref parsing requires the profile that owns its swissnum spelling",
    },
    .{
        .where = .{ .file = "bindings/rust/src/uri.rs" },
        .kind = .require,
        .needles = &.{"pub fn parse_sturdyref(uri: &str, captp_version: CaptpVersion)"},
        .check = "sturdyref-profile-authority",
        .why = "Rust sturdyref parsing requires the profile that owns its swissnum spelling",
    },
    .{
        .where = .{ .file = "bindings/python/pancake/_locator.py" },
        .kind = .require,
        .needles = &.{"def parse_sturdyref(uri: str, captp_version: str)"},
        .check = "sturdyref-profile-authority",
        .why = "Python sturdyref parsing requires the profile that owns its swissnum spelling",
    },
    .{
        .where = .{ .file = "bindings/racket/private/locator.rkt" },
        .kind = .require,
        .needles = &.{"(define (parse-sturdyref uri #:captp-version captp-version)"},
        .check = "sturdyref-profile-authority",
        .why = "Racket sturdyref parsing requires the profile that owns its swissnum spelling",
    },
};
