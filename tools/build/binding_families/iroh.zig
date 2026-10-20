//! The per-binding iroh live-proof rows under their `bindings-*` aggregates. The parent
//! module registers them.
const BindingClientRow = @import("../binding_families.zig").BindingClientRow;

// Binding sibling of `iroh-loop`: many concurrent connections from one
// readiness loop through the iroh C ABI (ADR-0019).
pub const iroh_loop_clients = [_]BindingClientRow{
    .{
        .step_name = "deno-iroh-loop",
        .description = "Live iroh scale: the Deno binding serves many connections from one readiness loop (ADR-0019, needs cargo + deno)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "interop/iroh_loop/deno_client.ts" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "python-iroh-loop",
        .description = "Live iroh scale: the Python binding serves many connections from one readiness loop (ADR-0019, needs cargo + python3)",
        .argv = &.{ "python3", "interop/iroh_loop/python_client.py" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "rust-iroh-driver-provider",
        .description = "Live ADR-0024 Rust parity: the byte-fed iroh surface serves while the driver archive dials the same endpoint through the C multiplexed-transport table (needs cargo)",
        .argv = &.{ "cargo", "test", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "iroh", "iroh_provider_dials_live", "--", "--ignored", "--nocapture" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "python-iroh-driver-provider",
        .description = "Live ADR-0024 Python parity: the byte-fed iroh surface serves while the driver archive dials the same endpoint through the C multiplexed-transport table (needs cargo + python3)",
        .argv = &.{ "python3", "interop/iroh_driver_provider/python_client.py" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "rust-iroh-loop",
        .description = "Live iroh scale: the Rust binding serves many connections from one readiness loop (ADR-0019, needs cargo)",
        .argv = &.{ "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "iroh", "--example", "iroh_loop" },
        .posture = .{ .deterministic = 30 },
        .dashdash_before_args = true,
    },
    .{
        .step_name = "racket-iroh-loop",
        .description = "Live iroh scale: the Racket binding serves many connections from one readiness loop (ADR-0019, needs cargo + racket)",
        .argv = &.{ "racket", "-y", "interop/iroh_loop/racket_client.rkt" },
        .posture = .{ .deterministic = 30 },
    },
};

// Binding sibling of demo-rooms-dm-iroh: mint + redeem an iroh handoff give
// in one process (relay-less Direct posture). Deterministic, flake-free.
pub const iroh_handoff_clients = [_]BindingClientRow{
    .{
        .step_name = "deno-iroh-handoff",
        .description = "Three-party handoff over iroh: the Deno binding mints and redeems an iroh handoff give in one process (needs cargo + deno)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "interop/iroh_handoff/deno_client.ts" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "python-iroh-handoff",
        .description = "Three-party handoff over iroh: the Python binding mints and redeems an iroh handoff give in one process (needs cargo + python3)",
        .argv = &.{ "python3", "interop/iroh_handoff/python_client.py" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "rust-iroh-handoff",
        .description = "Three-party handoff over iroh: the Rust binding mints and redeems an iroh handoff give in one process (needs cargo)",
        .argv = &.{ "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "iroh", "--example", "iroh_handoff" },
        .posture = .{ .deterministic = 30 },
        .dashdash_before_args = true,
    },
    .{
        .step_name = "racket-iroh-handoff",
        .description = "Three-party handoff over iroh: the Racket binding mints and redeems an iroh handoff give in one process (needs cargo + racket)",
        .argv = &.{ "racket", "-y", "interop/iroh_handoff/racket_client.rkt" },
        .posture = .{ .deterministic = 30 },
    },
};

// Hermetic proof that configured redeem posture governs a hint-less iroh
// give (node id alone, in-process address book). Flake-free like handoff.
pub const iroh_redeem_clients = [_]BindingClientRow{
    .{
        .step_name = "deno-iroh-redeem-posture",
        .description = "In-tree configured-redeem-posture proof for a hint-less iroh give: the Deno binding (needs cargo + deno)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/iroh_redeem_posture/deno_client.ts" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "python-iroh-redeem-posture",
        .description = "In-tree configured-redeem-posture proof for a hint-less iroh give: the Python binding (needs cargo + python3)",
        .argv = &.{ "python3", "bindings/proofs/iroh_redeem_posture/python_client.py" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "rust-iroh-redeem-posture",
        .description = "In-tree configured-redeem-posture proof for a hint-less iroh give: the Rust binding (needs cargo)",
        .argv = &.{ "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "iroh", "--example", "iroh_redeem_posture" },
        .posture = .{ .deterministic = 30 },
        .dashdash_before_args = true,
    },
    .{
        .step_name = "racket-iroh-redeem-posture",
        .description = "In-tree configured-redeem-posture proof for a hint-less iroh give: the Racket binding (needs cargo + racket)",
        .argv = &.{ "racket", "-y", "bindings/proofs/iroh_redeem_posture/racket_client.rkt" },
        .posture = .{ .deterministic = 30 },
    },
};

// Opt-in live dial-by-id over n0 relays + DNS/pkarr. Touches public infra;
// never part of `check`. Offline dial-by-id is `local_discovery` in *-iroh-loop.
pub const iroh_reach_clients = [_]BindingClientRow{
    .{
        .step_name = "deno-iroh-reachability",
        .description = "Live dial-by-id over n0 relays + DNS/pkarr discovery: the Deno binding (opt-in; needs cargo + deno + internet)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "interop/iroh_reachability/deno_client.ts" },
        .posture = .real_internet,
    },
    .{
        .step_name = "python-iroh-reachability",
        .description = "Live dial-by-id over n0 relays + DNS/pkarr discovery: the Python binding (opt-in; needs cargo + python3 + internet)",
        .argv = &.{ "python3", "interop/iroh_reachability/python_client.py" },
        .posture = .real_internet,
    },
    .{
        .step_name = "rust-iroh-reachability",
        .description = "Live dial-by-id over n0 relays + DNS/pkarr discovery: the Rust binding (opt-in; needs cargo + internet)",
        .argv = &.{ "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "iroh", "--example", "iroh_reachability" },
        .posture = .real_internet,
        .dashdash_before_args = true,
    },
    .{
        .step_name = "racket-iroh-reachability",
        .description = "Live dial-by-id over n0 relays + DNS/pkarr discovery: the Racket binding (opt-in; needs cargo + racket + internet)",
        .argv = &.{ "racket", "-y", "interop/iroh_reachability/racket_client.rkt" },
        .posture = .real_internet,
    },
};
