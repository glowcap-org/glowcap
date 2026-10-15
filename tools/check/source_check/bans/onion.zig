//! Ban rows for the onion transport's cross-binding contract.

const bans = @import("../bans.zig");
const Ban = bans.Ban;

/// Onion service restoration key sizing is enforced by the onion transport and
/// projected through generated binding constants.
pub const service_key_cap_rows: []const Ban = &.{
    .{
        .where = .{ .file = "src/net/transport/onion/session.zig" },
        .kind = .require,
        .needles = &.{"pub const service_key_cap: usize = 256;"},
        .check = "onion-service-key-cap",
        .why = "the onion control session owns the service-key backing-store cap",
    },
    .{
        .where = .{ .file = "src/c_abi/net_transport/onion/contract.zig" },
        .kind = .require,
        .needles = &.{"GLOWCAP_ONION_SERVICE_KEY_CAP: usize = net.onion.session.service_key_cap"},
        .check = "onion-service-key-cap",
        .why = "the onion C ABI projects the transport-owned service-key cap",
    },
    .{
        .where = .{ .file = "bindings/python/glowcap/onion.py" },
        .kind = .require,
        .needles = &.{"_SERVICE_KEY_CAP = _c.ONION_SERVICE_KEY_CAP"},
        .check = "onion-service-key-cap",
        .why = "Python onion listen uses the generated service-key cap instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/rust/src/sys/onion.rs" },
        .kind = .require,
        .needles = &.{"ONION_SERVICE_KEY_CAP: usize = crate::abi_constants_gen::ONION_SERVICE_KEY_CAP"},
        .check = "onion-service-key-cap",
        .why = "Rust onion FFI uses the generated service-key cap instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/ts/onion/ffi_archive.ts" },
        .kind = .require,
        .needles = &.{"new Uint8Array(ONION_SERVICE_KEY_CAP)"},
        .check = "onion-service-key-cap",
        .why = "TypeScript onion listen uses the generated service-key cap instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/racket/glowcap-onion.rkt" },
        .kind = .require,
        .needles = &.{"(define SERVICE-KEY-CAP ONION-SERVICE-KEY-CAP)"},
        .check = "onion-service-key-cap",
        .why = "Racket onion listen uses the generated service-key cap instead of carrying its own literal",
    },
    .{
        .where = .{ .files = &.{
            "bindings/python/glowcap/onion.py",
            "bindings/rust/src/sys/onion.rs",
            "bindings/ts/onion/mod.ts",
            "bindings/racket/glowcap-onion.rkt",
        } },
        .kind = .forbid,
        .needles = &.{ "_SERVICE_KEY_CAP = 256", "ONION_SERVICE_KEY_CAP: usize = 256", "new Uint8Array(256)", "(define SERVICE-KEY-CAP 256)" },
        .check = "onion-service-key-cap",
        .why = "onion binding service-key buffers use generated constants, not local 256-byte guesses",
    },
};
