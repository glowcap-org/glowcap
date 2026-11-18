//! The C ABI integer constants a binding constant registry leaves out, each
//! with the reason. `constants.zig` (the Rust, Python, and Racket mirrors)
//! and `ts_abi_constants.zig` (the TypeScript mirror) each walk every integer
//! `GLOWCAP_*` declaration of the archive modules they import (`c_abi`,
//! `c_abi_host`, `c_abi_driver`, and the iroh, tcp, inproc, onion, webrtc, and
//! relay transport archives, never the Loam archives) and hold each against
//! their registry rows, these tables, and `covered`. A constant added to one of
//! those modules is a compile error in the generator that should have carried
//! it.
//!
//! `shared` lists constants no registry carries and `rust_python_racket` the
//! constants only that registry leaves out. A row is
//! `.{ .name = "<declaration>", .reason = "<why>" }`. `covered` names the
//! owners whose constants a declaration shares by value and needs no row. The
//! guard refuses a name no module declares, a name also in the registry or in
//! `covered`, a repeated name, and an empty reason.

const reflect = @import("reflect");
const cp = @import("c_abi_shared");

const ConstOmission = reflect.ConstOmission;

const plan_dial = "Vocabulary of glowcap_host_plan_dial, which every binding omits (bindings/ffi_omissions/shared.zig): driver providers plan dials inside Zig, and plan_dial serves a C embedder that opens its own sockets.";
const host_action = "Reaches Rust, Python, and Racket through the generated host-action mirror (zig build gen-binding-host-action).";

/// The provider contract: glowcap_transport_provider.h declares these and a
/// transport archive fills the structs they describe. No binding writes a
/// provider field or passes a callback into a provider slot: Rust
/// zero-initializes the struct, Python and Racket construct it empty, and
/// TypeScript allocates a zeroed buffer, each before the archive's
/// `*_transport_provider` call.
/// Both namespaces are shared by every archive, so their header guard emits every
/// constant and neither owner omits any.
pub const covered = .{
    reflect.ConstOwner{ .by = "the GlowcapTransportProvider contract (glowcap_transport_provider.h)", .module = cp.transport_provider, .omits = &.{} },
    reflect.ConstOwner{ .by = "the GlowcapMultiplexedTransport contract (glowcap_transport_provider.h)", .module = cp.multiplexed_transport, .omits = &.{} },
};

pub const shared = [_]ConstOmission{
    .{ .name = "GLOWCAP_DIAL_SHAPE_HOST_PORT", .reason = plan_dial },
    .{ .name = "GLOWCAP_DIAL_SHAPE_PEER_ID", .reason = plan_dial },
    .{ .name = "GLOWCAP_DIAL_SHAPE_SIGNALING", .reason = plan_dial },
    .{ .name = "GLOWCAP_DIAL_SHAPE_RENDEZVOUS", .reason = plan_dial },
    .{ .name = "GLOWCAP_DIAL_REACH_DIRECT", .reason = plan_dial },
    .{ .name = "GLOWCAP_DIAL_REACH_CONFIGURED", .reason = plan_dial },
    .{ .name = "GLOWCAP_DIAL_REACH_EXPLICIT", .reason = plan_dial },
    .{ .name = "GLOWCAP_DIAL_POSTURE_REDEEM", .reason = plan_dial },
    .{ .name = "GLOWCAP_DIAL_POSTURE_EXPLICIT", .reason = plan_dial },
    .{ .name = "GLOWCAP_DIAL_POSTURE_EXPLICIT_NONE", .reason = plan_dial },
};

pub const rust_python_racket = [_]ConstOmission{
    .{ .name = "GLOWCAP_HOST_ACTION_DIAL", .reason = host_action },
    .{ .name = "GLOWCAP_HOST_ACTION_FLUSH", .reason = host_action },
    .{ .name = "GLOWCAP_HOST_ACTION_NEED_GIFT_ID", .reason = host_action },
    .{ .name = "GLOWCAP_HOST_ACTION_SETTLE", .reason = host_action },
    .{ .name = "GLOWCAP_HOST_ACTION_FAIL", .reason = host_action },
    .{ .name = "GLOWCAP_HOST_ACTION_CLOSE", .reason = host_action },
    .{ .name = "GLOWCAP_HOST_ACTION_RESUME", .reason = host_action },
    .{ .name = "GLOWCAP_HOST_ACTION_CANCEL_DIAL", .reason = host_action },
};

/// The `decl` of every row that mirrors a C declaration, in row order.
pub fn declNames(comptime rows: anytype) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (rows) |row| {
            if (row.decl.len != 0) names = names ++ &[_][]const u8{row.decl};
        }
        return names;
    }
}

/// Hold a registry against the archive modules it walks: each integer
/// `GLOWCAP_*` declaration is in `decls`, has a row in `omitted`, or is owned
/// by one of `covered`. `add_hint` is the registry's instruction for a missing one.
pub fn guard(
    comptime owner: []const u8,
    comptime add_hint: []const u8,
    comptime modules: anytype,
    comptime decls: []const []const u8,
    comptime omitted: []const ConstOmission,
) void {
    reflect.guardConstants(owner, add_hint, modules, decls, omitted, covered);
}
