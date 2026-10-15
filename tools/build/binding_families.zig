//! The per-binding client families: one emitter over every `bindings-*`
//! aggregate: Goblins interop/listen/handoff/gift, iroh loop/handoff/redeem/
//! reachability, and keyed-tcp restart, with rows ordered deno → python →
//! rust → racket wherever a language is present. Zig one-off drivers stay
//! in the goblins family module.

const std = @import("std");
const common = @import("common.zig");
const execution = @import("execution.zig");

const addInstalledSystemRun = common.addInstalledSystemRun;
const iroh_rows = @import("binding_families/iroh.zig");
const webrtc_rows = @import("binding_families/webrtc.zig");

/// One per-binding client row under a `bindings-*` family aggregate.
pub const BindingClientRow = struct {
    step_name: []const u8,
    description: []const u8,
    argv: []const []const u8,
    posture: execution.Posture,
    /// True when the runner needs a `--` separator before program args
    /// (cargo run forwards trailing args to the example only after one).
    dashdash_before_args: bool = false,
};

/// One per-binding client family: an aggregate step plus its language rows.
const BindingFamily = struct {
    aggregate_name: []const u8,
    aggregate_desc: []const u8,
    needs_iroh_abi: bool,
    /// The rows dial the Zig WebRTC answerer and accept the Zig WebRTC
    /// offerer over the WebRTC C library, so all three are built first.
    needs_webrtc_peers: bool = false,
    /// The family's harness delegates every child to the shared proof process
    /// owner, whose injected-timeout regression must gate the aggregate.
    uses_proof_process_owner: bool = false,
    rows: []const BindingClientRow,
};

/// The WebRTC steps a live dial-and-listen family depends on.
pub const WebrtcSteps = struct {
    abi_step: *std.Build.Step,
    answerer_step: *std.Build.Step,
    offerer_step: *std.Build.Step,
};

/// Register a `bindings-*` aggregate and every per-binding step under it.
fn addBindingFamily(
    b: *std.Build,
    family: BindingFamily,
    pin_port: ?u16,
    iroh_abi_step: *std.Build.Step,
    webrtc: WebrtcSteps,
) *std.Build.Step {
    const aggregate = b.step(family.aggregate_name, family.aggregate_desc);
    for (family.rows) |client| {
        const run = addInstalledSystemRun(b, client.posture, client.argv);
        addClientCaches(b, client, run);
        if (family.needs_iroh_abi) run.step.dependOn(iroh_abi_step);
        if (family.needs_webrtc_peers) {
            run.step.dependOn(webrtc.abi_step);
            run.step.dependOn(webrtc.answerer_step);
            run.step.dependOn(webrtc.offerer_step);
        }
        if (pin_port) |p| {
            if (client.dashdash_before_args) run.addArg("--");
            run.addArg(b.fmt("--port={d}", .{p}));
        }
        b.step(client.step_name, client.description).dependOn(&run.step);
        aggregate.dependOn(&run.step);
    }
    return aggregate;
}

/// Keep cold Cargo compilation and Deno dependency resolution outside the
/// bounded live proof. The row remains the command authority. This derives
/// only the cache/build prefix and never executes the scenario twice.
fn addClientCaches(b: *std.Build, client: BindingClientRow, run: *std.Build.Step.Run) void {
    for (client.argv, 0..) |word, cargo_index| {
        if (!std.mem.eql(u8, word, "cargo") or cargo_index + 1 >= client.argv.len) continue;
        const is_test = std.mem.eql(u8, client.argv[cargo_index + 1], "test");
        const is_run = std.mem.eql(u8, client.argv[cargo_index + 1], "run");
        if (!is_test and !is_run) continue;
        const cache = addInstalledSystemRun(b, .build_tool, if (is_test)
            &.{ "cargo", "test", "--no-run" }
        else
            &.{ "cargo", "build" });
        for (client.argv[cargo_index + 2 ..]) |arg| {
            if (std.mem.eql(u8, arg, "--")) break;
            cache.addArg(arg);
        }
        run.step.dependOn(&cache.step);
    }
    var deno_cache: ?*std.Build.Step.Run = null;
    for (client.argv) |arg| {
        if (!std.mem.endsWith(u8, arg, ".ts")) continue;
        if (deno_cache == null) {
            deno_cache = common.addRootedSystemCommand(b, .build_tool, &.{ "deno", "cache" });
            run.step.dependOn(&deno_cache.?.step);
        }
        deno_cache.?.addArg(arg);
    }
}

// ── Per-binding client families ──────────────────────────────────────────
// One emitter over every `bindings-*` aggregate: Goblins interop/handoff/gift,
// iroh loop/handoff/redeem/reachability, and keyed-tcp restart. Row order is
// deno → python → rust → racket wherever a language is present. Zig
// one-offs (`goblins-interop`, `goblins-handoff`, `tcp-loop`) stay above,
// they are Zig drivers, not binding clients.

// Each binding drives the same keyed conversation against a real Goblins
// vat through the installed C ABI archives. Every entry needs `racket` + the
// `goblins` collection on PATH plus its own runtime; each script spawns and
// tears down the Goblins vat itself. The Rust entry runs a feature-gated
// tokio example, so it needs the async feature.
const goblins_interop_clients = [_]BindingClientRow{
    .{
        .step_name = "deno-goblins-interop",
        .description = "Live keyed OCapN conversation: Deno binding vs a real Goblins vat (needs deno + racket + goblins)",
        .argv = &.{ "deno", "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "--v8-flags=--expose-gc", "interop/goblins_interop/deno_client.ts" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "python-goblins-interop",
        .description = "Live keyed OCapN conversation: Python binding vs a real Goblins vat (needs python3 + racket + goblins)",
        .argv = &.{ "python3", "interop/goblins_interop/python_client.py" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "rust-goblins-interop",
        .description = "Live keyed OCapN conversation: Rust binding vs a real Goblins vat (needs cargo + racket + goblins)",
        .argv = &.{ "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async", "--example", "rust_client" },
        .posture = .{ .deterministic = 30 },
        .dashdash_before_args = true,
    },
    .{
        .step_name = "racket-goblins-interop",
        .description = "Live keyed OCapN conversation: Racket binding vs a real Goblins vat (needs racket + goblins)",
        .argv = &.{ "racket", "-y", "interop/goblins_interop/racket_client.rkt" },
        .posture = .{ .deterministic = 30 },
    },
};

// The reciprocal application direction: a real Goblins vat dials each binding,
// enlivens one Host-wide actor, and calls it. One Deno harness owns the outside
// peer and exact reply assertion; each row varies only the binding listener.
const goblins_listen_clients = [_]BindingClientRow{
    .{
        .step_name = "deno-goblins-listen",
        .description = "Live listener conversation: Goblins dials, enlivens, and calls a Deno binding host (needs deno + racket + goblins)",
        .argv = &.{ "deno", "run", "-A", "interop/goblins_interop/binding_listen_harness.ts", "--", "deno", "run", "-A", "interop/goblins_interop/deno_listen_client.ts" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "python-goblins-listen",
        .description = "Live listener conversation: Goblins dials, enlivens, and calls a Python binding host (needs deno + uv + racket + goblins)",
        .argv = &.{ "deno", "run", "-A", "interop/goblins_interop/binding_listen_harness.ts", "--", "uv", "run", "--project", "bindings/python", "--locked", "python3", "interop/goblins_interop/python_listen_client.py" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "rust-goblins-listen",
        .description = "Live listener conversation: Goblins dials, enlivens, and calls a Rust binding host (needs deno + cargo + racket + goblins)",
        .argv = &.{ "deno", "run", "-A", "interop/goblins_interop/binding_listen_harness.ts", "--", "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async", "--example", "goblins_listen", "--" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "racket-goblins-listen",
        .description = "Live listener conversation: Goblins dials, enlivens, and calls a Racket binding host (needs deno + racket + goblins)",
        .argv = &.{ "deno", "run", "-A", "interop/goblins_interop/binding_listen_harness.ts", "--", "racket", "-y", "interop/goblins_interop/racket_listen_client.rkt" },
        .posture = .{ .deterministic = 30 },
    },
};

// Binding as recipient: redeems a `desc:handoff-give` from a real Goblins
// introducer, then calls the exporter directly. Counterpart of the Zig
// `goblins-handoff` driver. `-Dport=N` pins the introducer (exporter on N+1).
const goblins_handoff_clients = [_]BindingClientRow{
    .{
        .step_name = "deno-goblins-handoff",
        .description = "Live three-party handoff: the Deno binding redeems a give from a real Goblins introducer and calls the exporter (needs deno + racket + goblins)",
        .argv = &.{ "deno", "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "interop/goblins_interop/deno_handoff_client.ts" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "python-goblins-handoff",
        .description = "Live three-party handoff: the Python binding redeems a give from a real Goblins introducer and calls the exporter (needs python3 + racket + goblins)",
        .argv = &.{ "python3", "interop/goblins_interop/python_handoff_client.py" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "rust-goblins-handoff",
        .description = "Live three-party handoff: the Rust binding redeems a give from a real Goblins introducer and calls the exporter (needs cargo + racket + goblins)",
        .argv = &.{ "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async", "--example", "rust_handoff_client" },
        .posture = .{ .deterministic = 30 },
        .dashdash_before_args = true,
    },
    .{
        .step_name = "racket-goblins-handoff",
        .description = "Live three-party handoff: the Racket binding redeems a give from a real Goblins introducer and calls the exporter (needs racket + goblins)",
        .argv = &.{ "racket", "-y", "interop/goblins_interop/racket_handoff_client.rkt" },
        .posture = .{ .deterministic = 30 },
    },
};

// Binding as gifter: mints a give a real Goblins recipient redeems. Proves
// the exporter half of ADR-0009. `-Dport=N` pins the exporter (recipient on
// N+1; gifter takes an ephemeral port). Deno needs `--allow-env`.
const goblins_gift_clients = [_]BindingClientRow{
    .{
        .step_name = "deno-goblins-gift",
        .description = "Live three-party handoff: the Deno binding mints a give a real Goblins recipient redeems, reaching the exporter (needs deno + racket + goblins)",
        .argv = &.{ "deno", "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "--allow-env", "interop/goblins_interop/deno_gift_client.ts" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "python-goblins-gift",
        .description = "Live three-party handoff: the Python binding mints a give a real Goblins recipient redeems, reaching the exporter (needs python3 + racket + goblins)",
        .argv = &.{ "python3", "interop/goblins_interop/python_gift_client.py" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "rust-goblins-gift",
        .description = "Live three-party handoff: the Rust binding mints a give a real Goblins recipient redeems, reaching the exporter (needs cargo + racket + goblins)",
        .argv = &.{ "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async", "--example", "rust_gift_client" },
        .posture = .{ .deterministic = 30 },
        .dashdash_before_args = true,
    },
    .{
        .step_name = "racket-goblins-gift",
        .description = "Live three-party handoff: the Racket binding mints a give a real Goblins recipient redeems, reaching the exporter (needs racket + goblins)",
        .argv = &.{ "racket", "-y", "interop/goblins_interop/racket_gift_client.rkt" },
        .posture = .{ .deterministic = 30 },
    },
};

// Keyed-tcp restart proof (ADR-0075): happy path, squatter refusal, same-
// seed fresh-port restart. No iroh companion needed.
const keyed_tcp_restart_clients = [_]BindingClientRow{
    .{
        .step_name = "deno-keyed-tcp-restart",
        .description = "Keyed-tcp restart proof: the Deno binding (happy, squatter, restart)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/keyed_tcp_restart/deno_client.ts" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "python-keyed-tcp-restart",
        .description = "Keyed-tcp restart proof: the Python binding (happy, squatter, restart)",
        .argv = &.{ "python3", "bindings/proofs/keyed_tcp_restart/python_client.py" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "rust-keyed-tcp-restart",
        .description = "Keyed-tcp restart proof: the Rust binding (happy, squatter, and restart cases, needs cargo)",
        .argv = &.{ "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async", "--example", "keyed_tcp_restart" },
        .posture = .{ .deterministic = 30 },
        .dashdash_before_args = true,
    },
    .{
        .step_name = "racket-keyed-tcp-restart",
        .description = "Keyed-tcp restart proof: the Racket binding (happy, squatter, and restart cases, needs racket)",
        .argv = &.{ "racket", "-y", "bindings/proofs/keyed_tcp_restart/racket_client.rkt" },
        .posture = .{ .deterministic = 30 },
    },
};

// Keyed-relay rendezvous proof (ADR-0088): the binding cold-dials a
// registered non-listening peer by key designator through the reference
// relay's rendezvous bridge, the core classifies the locator as the
// rendezvous dial shape, and the host's configured relay mapping opens it.
// The shared harness stands up the relay and the registered Deno peer.
const keyed_relay_rendezvous_clients = [_]BindingClientRow{
    .{
        .step_name = "deno-keyed-relay-rendezvous",
        .description = "Keyed-relay rendezvous cold-dial proof: the Deno binding dials a registered peer through the reference relay (needs deno)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/keyed_relay_rendezvous/harness.ts", "--", "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/keyed_relay_rendezvous/deno_client.ts" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "python-keyed-relay-rendezvous",
        .description = "Keyed-relay rendezvous cold-dial proof: the Python binding dials a registered peer through the reference relay (needs deno + uv)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/keyed_relay_rendezvous/harness.ts", "--", "uv", "run", "--project", "bindings/python", "--extra", "rendezvous", "--locked", "python3", "bindings/proofs/keyed_relay_rendezvous/python_client.py" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "racket-keyed-relay-rendezvous",
        .description = "Keyed-relay rendezvous cold-dial proof: the Racket binding dials a registered peer through the reference relay (needs deno + racket)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/keyed_relay_rendezvous/harness.ts", "--", "racket", "-y", "bindings/proofs/keyed_relay_rendezvous/racket_client.rkt" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "rust-keyed-relay-rendezvous",
        .description = "Keyed-relay rendezvous cold-dial proof: the Rust binding dials a registered peer through the reference relay (needs deno + cargo)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/keyed_relay_rendezvous/harness.ts", "--", "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "relay", "--example", "keyed_relay_rendezvous", "--" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "zig-keyed-relay-register",
        .description = "Keyed-relay register proof: the Zig glowcap CLI registers at the reference relay (no listening socket) and answers a cold dial (needs deno)",
        .argv = &.{ "bash", "bindings/proofs/keyed_relay_rendezvous/zig_register.sh" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "zig-keyed-relay-rendezvous",
        .description = "Keyed-relay rendezvous cold-dial proof: the Zig glowcap CLI dials a registered peer through the reference relay via GLOWCAP_RENDEZVOUS (needs deno)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/keyed_relay_rendezvous/harness.ts", "--", "bash", "bindings/proofs/keyed_relay_rendezvous/zig_client.sh" },
        .posture = .{ .deterministic = 30 },
    },
};

// The verb spine as behavior: each binding walks promise (a far send's handle,
// its `index`/`untag`/`get` projections, and the settled failure a send that
// could never be issued comes back as), dial (a happy connect and a typed
// refusal), listen (its own listener, served and closed), and GC (a lifted
// capability released, then refused) against one fixed Deno peer over loopback
// TCP. The shared harness owns the peer, the dead address, and the marker
// contract every client prints.
const verb_spine_clients = [_]BindingClientRow{
    .{
        .step_name = "deno-verb-spine",
        .description = "Verb-spine behavior proof: the Deno binding walks promise, dial, listen, and GC against one fixed peer (needs deno)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/verb_spine/harness.ts", "--", "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/verb_spine/deno_client.ts" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "python-verb-spine",
        .description = "Verb-spine behavior proof: the Python binding walks promise, dial, listen, and GC against one fixed peer (needs deno + uv)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/verb_spine/harness.ts", "--", "uv", "run", "--project", "bindings/python", "--locked", "python3", "bindings/proofs/verb_spine/python_client.py" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "rust-verb-spine",
        .description = "Verb-spine behavior proof: the Rust binding walks promise, dial, listen, and GC against one fixed peer (needs deno + cargo)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/verb_spine/harness.ts", "--", "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async", "--example", "verb_spine", "--" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "racket-verb-spine",
        .description = "Verb-spine behavior proof: the Racket binding walks promise, dial, listen, and GC against one fixed peer (needs deno + racket)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/verb_spine/harness.ts", "--", "racket", "-y", "bindings/proofs/verb_spine/racket_client.rkt" },
        .posture = .{ .deterministic = 30 },
    },
};

// The managed noise-relay listen half: each binding's `noise` listen helper
// registers a durable key at the reference relay and serves an accepted
// Noise_XK-sealed session, dialed by one fixed known-good Deno client. The
// shared harness stands up the relay and dials the listener's printed
// locator; a red run points at the listener's binding.
const noise_relay_listen_clients = [_]BindingClientRow{
    .{
        .step_name = "deno-noise-relay-listen",
        .description = "Noise-relay managed-listen proof: the Deno binding registers, advertises, and serves a sealed session (needs deno)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/noise_relay_listen/harness.ts", "--", "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/noise_relay_listen/deno_listener.ts" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "python-noise-relay-listen",
        .description = "Noise-relay managed-listen proof: the Python binding registers, advertises, and serves a sealed session (needs deno + uv)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/noise_relay_listen/harness.ts", "--", "uv", "run", "--project", "bindings/python", "--locked", "python3", "bindings/proofs/noise_relay_listen/python_listener.py" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "racket-noise-relay-listen",
        .description = "Noise-relay managed-listen proof: the Racket binding registers, advertises, and serves a sealed session (needs deno + racket)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/noise_relay_listen/harness.ts", "--", "racket", "-y", "bindings/proofs/noise_relay_listen/racket_listener.rkt" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "rust-noise-relay-listen",
        .description = "Noise-relay managed-listen proof: the Rust binding registers, advertises, and serves a sealed session (needs deno + cargo)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/noise_relay_listen/harness.ts", "--", "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "relay", "--example", "noise_relay_listen", "--" },
        .posture = .{ .deterministic = 30 },
    },
};

// The same rendezvous conversation over the Mbed TLS WSS provider in every
// binding. The shared harness supplies one copied test CA and makes each
// client prove wrong-host and unknown-CA projection before the successful
// call. Managed registration remains the peer/runtime-owned side of ADR-0117.
const wss_relay_clients = [_]BindingClientRow{
    .{
        .step_name = "deno-wss-relay",
        .description = "WSS relay success and exact TLS refusals through the Deno binding (needs deno)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/keyed_relay_rendezvous/harness.ts", "--wss", "--", "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/keyed_relay_rendezvous/deno_client.ts" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "python-wss-relay",
        .description = "WSS relay success and exact TLS refusals through the Python binding (needs deno + uv)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/keyed_relay_rendezvous/harness.ts", "--wss", "--", "uv", "run", "--project", "bindings/python", "--locked", "python3", "bindings/proofs/keyed_relay_rendezvous/python_client.py" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "rust-wss-relay",
        .description = "WSS relay success and exact TLS refusals through the Rust binding (needs deno + cargo)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/keyed_relay_rendezvous/harness.ts", "--wss", "--", "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "relay", "--example", "keyed_relay_rendezvous", "--" },
        .posture = .{ .deterministic = 30 },
    },
    .{
        .step_name = "racket-wss-relay",
        .description = "WSS relay success and exact TLS refusals through the Racket binding (needs deno + racket)",
        .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "bindings/proofs/keyed_relay_rendezvous/harness.ts", "--wss", "--", "racket", "-y", "bindings/proofs/keyed_relay_rendezvous/racket_client.rkt" },
        .posture = .{ .deterministic = 30 },
    },
};

const binding_families = [_]BindingFamily{
    .{
        .aggregate_name = "bindings-goblins-interop",
        .aggregate_desc = "Live keyed conversation vs a real Goblins vat through Deno, Python, Rust, and Racket bindings (needs racket + goblins + the runtimes)",
        .needs_iroh_abi = false,
        .rows = &goblins_interop_clients,
    },
    .{
        .aggregate_name = "bindings-goblins-listen",
        .aggregate_desc = "Live listener conversation: a real Goblins vat dials and calls Deno, Python, Rust, and Racket binding hosts",
        .needs_iroh_abi = false,
        .rows = &goblins_listen_clients,
    },
    .{
        .aggregate_name = "bindings-goblins-handoff",
        .aggregate_desc = "Three-party handoff through Deno, Python, Rust, and Racket bindings as recipient (needs racket + goblins + the runtimes)",
        .needs_iroh_abi = false,
        .rows = &goblins_handoff_clients,
    },
    .{
        .aggregate_name = "bindings-goblins-gift",
        .aggregate_desc = "Three-party handoff through Deno, Python, Rust, and Racket bindings as gifter (needs racket + goblins + the runtimes)",
        .needs_iroh_abi = false,
        .rows = &goblins_gift_clients,
    },
    .{
        .aggregate_name = "bindings-iroh-loop",
        .aggregate_desc = "Per-binding iroh scale proof: many connections served from one loop, every binding (needs cargo + the runtimes)",
        .needs_iroh_abi = true,
        .rows = &iroh_rows.iroh_loop_clients,
    },
    .{
        .aggregate_name = "bindings-webrtc-driver-provider",
        .aggregate_desc = "Live WebRTC through the C provider: every binding dials the Zig answerer (ADR-0226) and accepts the Zig offerer (ADR-0232) with its own signaling (needs cargo + deno + python3 + racket)",
        .needs_iroh_abi = false,
        .needs_webrtc_peers = true,
        .rows = &webrtc_rows.webrtc_driver_provider_clients,
    },
    .{
        .aggregate_name = "bindings-iroh-handoff",
        .aggregate_desc = "Per-binding three-party handoff over iroh: every binding mints and redeems an iroh handoff give in one process (needs cargo + the runtimes)",
        .needs_iroh_abi = true,
        .rows = &iroh_rows.iroh_handoff_clients,
    },
    .{
        .aggregate_name = "bindings-iroh-redeem-posture",
        .aggregate_desc = "Per-binding hermetic proof that a configured redeem posture governs a hint-less iroh give, every binding (needs cargo + the runtimes)",
        .needs_iroh_abi = true,
        .rows = &iroh_rows.iroh_redeem_clients,
    },
    .{
        .aggregate_name = "bindings-keyed-tcp-restart",
        .aggregate_desc = "Per-binding keyed-tcp restart proof: happy path, squatter refusal, same-seed fresh-port restart, every binding",
        .needs_iroh_abi = false,
        .rows = &keyed_tcp_restart_clients,
    },
    .{
        .aggregate_name = "bindings-keyed-relay-rendezvous",
        .aggregate_desc = "Per-consumer keyed-relay rendezvous cold-dial proof: each language binding and the Zig CLI dial a registered non-listening peer through the reference relay's rendezvous bridge (needs deno + the runtimes)",
        .needs_iroh_abi = false,
        .uses_proof_process_owner = true,
        .rows = &keyed_relay_rendezvous_clients,
    },
    .{
        .aggregate_name = "bindings-verb-spine",
        .aggregate_desc = "Per-binding verb-spine behavior proof: each binding walks promise, dial, listen, and GC end to end against one fixed peer over loopback TCP (needs deno + the runtimes)",
        .needs_iroh_abi = false,
        .uses_proof_process_owner = true,
        .rows = &verb_spine_clients,
    },
    .{
        .aggregate_name = "bindings-noise-relay-listen",
        .aggregate_desc = "Per-binding managed noise-relay listen proof: each binding registers a durable key at the reference relay, advertises its locator, and serves a sealed session dialed by one fixed client (needs deno + the runtimes)",
        .needs_iroh_abi = false,
        .uses_proof_process_owner = true,
        .rows = &noise_relay_listen_clients,
    },
    .{
        .aggregate_name = "bindings-wss-relay",
        .aggregate_desc = "Per-binding WSS relay success and exact TLS refusal projection through one local CA fixture",
        .needs_iroh_abi = false,
        .rows = &wss_relay_clients,
    },
    .{
        .aggregate_name = "bindings-iroh-reachability",
        .aggregate_desc = "Per-binding live dial-by-id over n0 relays + DNS/pkarr discovery, every binding (opt-in; needs cargo + the runtimes + internet)",
        .needs_iroh_abi = true,
        .rows = &iroh_rows.iroh_reach_clients,
    },
};
/// Register every family: the aggregate steps, their per-binding rows, and
/// the iroh ABI dependency where a family needs it.
pub fn register(b: *std.Build, pin_port: ?u16, iroh_abi_step: *std.Build.Step, webrtc: WebrtcSteps) void {
    // The process-owned harnesses share this injected-timeout regression. A
    // family declares that dependency beside its rows, so the table remains
    // the authority when another harness adopts the owner.
    const harness_test = common.addRootedSystemCommand(b, .{ .deterministic = 5 }, &.{
        "deno", "test", "-A", "bindings/proofs/_support/harness_test.ts",
    });
    for (binding_families) |family| {
        const aggregate = addBindingFamily(b, family, pin_port, iroh_abi_step, webrtc);
        if (family.uses_proof_process_owner) {
            aggregate.dependOn(&harness_test.step);
        }
    }
}
