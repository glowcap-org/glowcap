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
            .needles = &.{ "glowcap_locator_swissnum", "is_sturdyref" },
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
            "bindings/python/glowcap/_action.py",
            "bindings/python/glowcap/_ffi_host.py",
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
            "GlowcapHostAction-conn",
            "session-vow-conn",
            "fn raw_conn(&self) -> *mut ffi::GlowcapHostSession",
            "self.shared.raw_conn()",
        },
        .check = "host-action-session-vocabulary",
        .why = "Host actions and GlowcapHostSession mirrors use session vocabulary directly; prerelease keeps no connection-named aliases",
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
        .where = .{ .file = "bindings/python/glowcap/_locator.py" },
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

/// `CallbackLatch` is the one writer of the Host's reentrancy latch. A site
/// that sets or clears the flag by hand can unlatch an outer holder.
pub const callback_latch_owner: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"}, .exclude = &.{"src/driver/core/host/admission.zig"} } },
        .kind = .forbid,
        .needles = &.{"callback_latch.held"},
        .check = "callback-latch-owner",
        .why = "hold the Host's callback latch through CallbackLatch.hold so every holder restores the state it found",
    },
    .{
        .where = .{ .tree = .{ .dir = "test", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{"callback_latch.held"},
        .check = "callback-latch-owner",
        .why = "hold the Host's callback latch through CallbackLatch.hold so every holder restores the state it found",
    },
};

/// `IdIssuer` alone advances an id counter, so an id is spent only when its
/// operation commits and the counter cannot overflow.
pub const id_issuer_owner: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"}, .exclude = &.{"src/foundation/id_issuer.zig"} } },
        .kind = .forbid,
        .needles = &.{"_ids.next"},
        .check = "id-issuer-owner",
        .why = "peek and commit ids through IdIssuer so a refusal spends nothing and the counter never overflows",
    },
};

/// `settlement.retireRow` is the one exit for a published Host vow row, so a
/// row retires only once settled and never strands the pending count.
pub const vow_row_retirement: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src/driver", .suffixes = &.{".zig"}, .exclude = &.{"src/driver/core/vows/settlement.zig"} } },
        .kind = .forbid,
        .needles = &.{ ".vows.remove(", ".vows.fetchRemove(" },
        .check = "vow-row-retirement",
        .why = "retire a Host vow row through settlement.retireRow so only a settled row leaves the table",
    },
};
