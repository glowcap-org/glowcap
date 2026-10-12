//! The cross-runtime relay matrix (ADR-0086) and the live Goblins relay and
//! rooms proofs: one shared harness per proof against every runtime's relay,
//! a runtime as a row rather than a fork, plus relay scaling and the heavy
//! four-peer rooms matrix over iroh.

const std = @import("std");
const common = @import("common.zig");
const execution = @import("execution.zig");

const addRootedSystemCommand = common.addRootedSystemCommand;
const addInstalledSystemRun = common.addInstalledSystemRun;

/// One relay harness kind: which parameterized proof drives the relay under test.
const RelayHarness = enum { tcp, backpressure, idle, iroh };

/// The harness script, its Deno permissions, and the archives it needs, derived
/// from the harness kind so a row states only its runtime, not its plumbing.
const RelayHarnessSpec = struct {
    script: []const u8,
    perms: []const []const u8,
    needs_wasm: bool,
    needs_iroh_abi: bool,
};

fn relayHarnessSpec(kind: RelayHarness) RelayHarnessSpec {
    return switch (kind) {
        // The browser peer runs the wasm module in-process and dials through the
        // relay over `?to=`.
        .tcp => .{
            .script = "bindings/ts/web/test/relay_tcp_harness.ts",
            .perms = &.{ "--allow-read", "--allow-net", "--allow-run", "--allow-ffi", "--allow-env" },
            .needs_wasm = true,
            .needs_iroh_abi = false,
        },
        // Raw byte flood and a stalled WebSocket client; no wasm peer.
        .backpressure => .{
            .script = "bindings/ts/web/test/relay_backpressure_harness.ts",
            .perms = &.{ "--allow-read", "--allow-net", "--allow-run", "--allow-env" },
            .needs_wasm = false,
            .needs_iroh_abi = false,
        },
        // A silent pair whose idle timer must fire; no wasm peer.
        .idle => .{
            .script = "bindings/ts/web/test/relay_idle_harness.ts",
            .perms = &.{ "--allow-read", "--allow-net", "--allow-run", "--allow-env" },
            .needs_wasm = false,
            .needs_iroh_abi = false,
        },
        // The probe is bundled to a temp file (`--allow-write`) and run against a
        // native iroh host, so the relay's iroh leg needs the iroh ABI companion.
        .iroh => .{
            .script = "bindings/ts/web/test/relay_iroh_harness.ts",
            .perms = &.{ "--allow-read", "--allow-write", "--allow-net", "--allow-run", "--allow-env" },
            .needs_wasm = true,
            .needs_iroh_abi = true,
        },
    };
}

/// One row of the cross-runtime relay matrix: a single (runtime, harness) proof.
/// `step_name` is a literal so `source-check`'s build-step census sees it.
const RelayRow = struct {
    step_name: []const u8,
    description: []const u8,
    harness: RelayHarness,
    /// Names the greet argument and the scenario messages.
    label: []const u8,
    /// The line the relay prints when listening (`<MARKER> <port>`).
    marker: []const u8,
    /// The relay program and its args, spawned by the harness from the repository
    /// root; the trailing "0" asks for an ephemeral port.
    relay_argv: []const []const u8,
    /// Environment `{key, value}` pairs the harness merges into the relay
    /// subprocess (the idle proof sets a low `GLOWCAP_RELAY_IDLE_MS`).
    relay_env: []const [2][]const u8 = &.{},
    /// A build step that must produce the relay program first (Rust's cargo build,
    /// Deno and Python relays are scripts and need none).
    build_dep: ?*std.Build.Step = null,
    /// Point the relay's dynamic loader at `zig-out/lib`, where the iroh transport
    /// archive lives (Rust's iroh relay links it at load time).
    needs_iroh_lib_path: bool = false,
};

/// One relay matrix family: an aggregate step over its (runtime, harness) rows.
const RelayFamily = struct {
    aggregate_name: []const u8,
    aggregate_desc: []const u8,
    rows: []const RelayRow,
};

/// Register a relay matrix family: one aggregate plus every per-row proof. The
/// harness, its permissions, and its build dependencies come from the row's
/// harness kind, so proving a new runtime's relay is a row, never a forked test.
fn addRelayFamily(
    b: *std.Build,
    family: RelayFamily,
    wasm_install: *std.Build.Step,
    iroh_abi_step: *std.Build.Step,
) void {
    const aggregate = b.step(family.aggregate_name, family.aggregate_desc);
    for (family.rows) |row| {
        const spec = relayHarnessSpec(row.harness);
        const run = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{ "deno", "run" });
        run.addArgs(spec.perms);
        run.addArg(spec.script);
        run.addArgs(&.{ "--marker", row.marker, "--label", row.label });
        for (row.relay_env) |pair| {
            run.addArgs(&.{ "--env", b.fmt("{s}={s}", .{ pair[0], pair[1] }) });
        }
        if (row.needs_iroh_lib_path) {
            run.addArgs(&.{ "--env", b.fmt("LD_LIBRARY_PATH={s}", .{common.rootPath(b, "zig-out/lib")}) });
        }
        run.addArg("--");
        run.addArgs(row.relay_argv);

        if (spec.needs_wasm) run.step.dependOn(wasm_install);
        if (spec.needs_iroh_abi) run.step.dependOn(iroh_abi_step);
        if (row.build_dep) |dep| run.step.dependOn(dep);

        b.step(row.step_name, row.description).dependOn(&run.step);
        aggregate.dependOn(&run.step);
    }
}

pub fn register(
    b: *std.Build,
    pin_port: ?u16,
    wasm_driver_install_step: *std.Build.Step,
    browser_preflight_step: *std.Build.Step,
    iroh_abi_step: *std.Build.Step,
    rooms_services_install: *std.Build.Step,
) void {
    // The cross-runtime relay matrix (ADR-0086). One shared harness per proof,
    // TCP forwarding, the non-optional backpressure clause, and the iroh leg,
    // runs against every runtime's relay: the Deno reference relay
    // (`bindings/ts/relay/serve.ts`), the Python relay
    // (`bindings/python/relay.py`, WebSocket server from the binding's locked
    // rendezvous extra), and the Rust relay
    // (`bindings/rust/relay`, tokio-tungstenite). A runtime is a row, never a fork,
    // so no binding can silently lack a proof.
    //
    // The Rust relay builds twice: archive-free for the TCP and backpressure legs,
    // and with `--features iroh` (linking the iroh binding) for the iroh leg. Deno
    // and Python relays are single scripts that serve every leg.
    const rust_relay_build = addRootedSystemCommand(b, .build_tool, &.{
        "cargo", "build", "--release", "--manifest-path", "bindings/rust/relay/Cargo.toml",
    });
    const rust_relay_iroh_build = addRootedSystemCommand(b, .build_tool, &.{
        "cargo",        "build",                           "--release", "--features", "iroh", "--manifest-path", "bindings/rust/relay/Cargo.toml",
        "--target-dir", "bindings/rust/relay/target/iroh",
    });
    rust_relay_iroh_build.step.dependOn(iroh_abi_step);
    rust_relay_iroh_build.step.dependOn(b.getInstallStep());

    const deno_relay_tcp = [_][]const u8{ "deno", "run", "--allow-net", "--allow-read", "--allow-env", "bindings/ts/relay/serve.ts", "0" };
    const deno_relay_iroh = [_][]const u8{ "deno", "run", "--allow-net", "--allow-read", "--allow-ffi", "--unstable-ffi", "--allow-env", "bindings/ts/relay/serve.ts", "0" };
    const python_relay = [_][]const u8{ "uv", "run", "--project", "bindings/python", "--extra", "rendezvous", "--locked", "python3", "bindings/python/relay.py", "0" };
    const rust_relay = [_][]const u8{ "bindings/rust/relay/target/release/glowcap-relay", "0" };
    const rust_relay_iroh = [_][]const u8{ "bindings/rust/relay/target/iroh/release/glowcap-relay", "0" };
    // `-y` warms the binding's compiled bytecode so the relay starts promptly on
    // repeat runs; the iroh leg loads the iroh companion from zig-out/lib lazily.
    const racket_relay = [_][]const u8{ "racket", "-y", "bindings/racket/relay.rkt", "0" };
    const python_relay_lifecycle = addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{
        "uv",      "run",                                "--project", "bindings/python", "--extra", "rendezvous", "--locked",
        "python3", "bindings/python/test/relay_test.py",
    });

    // The core contract: byte-transparent TCP forwarding and the backpressure
    // clause, across every runtime's relay.
    addRelayFamily(b, .{
        .aggregate_name = "bindings-relay",
        .aggregate_desc = "Prove the byte-transparent relay contract (TCP forwarding + backpressure + the idle-timeout bounded-resources clause) across every runtime's relay: Deno, Python, Rust, Racket (needs deno + uv + cargo + racket)",
        .rows = &.{
            .{ .step_name = "deno-relay-test", .description = "Prove a browser peer holds a keyed session through the Deno reference relay (needs deno)", .harness = .tcp, .label = "Deno", .marker = "DENO-RELAY-READY", .relay_argv = &deno_relay_tcp },
            .{ .step_name = "python-relay-test", .description = "Prove a browser peer holds a keyed session through the Python relay (needs deno + uv)", .harness = .tcp, .label = "Python", .marker = "PYTHON-RELAY-READY", .relay_argv = &python_relay, .build_dep = &python_relay_lifecycle.step },
            .{ .step_name = "rust-relay-test", .description = "Prove a browser peer holds a keyed session through the Rust relay (needs deno + cargo)", .harness = .tcp, .label = "Rust", .marker = "RUST-RELAY-READY", .relay_argv = &rust_relay, .build_dep = &rust_relay_build.step },
            .{ .step_name = "deno-relay-backpressure-test", .description = "Prove a stalled reader backpressures the far sender through the Deno relay (needs deno)", .harness = .backpressure, .label = "Deno", .marker = "DENO-RELAY-READY", .relay_argv = &deno_relay_tcp },
            .{ .step_name = "python-relay-backpressure-test", .description = "Prove a stalled reader backpressures the far sender through the Python relay (needs deno + uv)", .harness = .backpressure, .label = "Python", .marker = "PYTHON-RELAY-READY", .relay_argv = &python_relay, .build_dep = &python_relay_lifecycle.step },
            .{ .step_name = "rust-relay-backpressure-test", .description = "Prove a stalled reader backpressures the far sender through the Rust relay (needs deno + cargo)", .harness = .backpressure, .label = "Rust", .marker = "RUST-RELAY-READY", .relay_argv = &rust_relay, .build_dep = &rust_relay_build.step },
            .{ .step_name = "deno-relay-idle-test", .description = "Prove the Deno relay reclaims an idle session (the bounded-resources clause) (needs deno)", .harness = .idle, .label = "Deno", .marker = "DENO-RELAY-READY", .relay_argv = &deno_relay_tcp, .relay_env = &.{.{ "GLOWCAP_RELAY_IDLE_MS", "500" }} },
            .{ .step_name = "python-relay-idle-test", .description = "Prove the Python relay reclaims an idle session (the bounded-resources clause) (needs deno + uv)", .harness = .idle, .label = "Python", .marker = "PYTHON-RELAY-READY", .relay_argv = &python_relay, .relay_env = &.{.{ "GLOWCAP_RELAY_IDLE_MS", "500" }}, .build_dep = &python_relay_lifecycle.step },
            .{ .step_name = "rust-relay-idle-test", .description = "Prove the Rust relay reclaims an idle session (the bounded-resources clause) (needs deno + cargo)", .harness = .idle, .label = "Rust", .marker = "RUST-RELAY-READY", .relay_argv = &rust_relay, .build_dep = &rust_relay_build.step, .relay_env = &.{.{ "GLOWCAP_RELAY_IDLE_MS", "500" }} },
            .{ .step_name = "racket-relay-test", .description = "Prove a browser peer holds a keyed session through the Racket relay (net/rfc6455) (needs deno + racket)", .harness = .tcp, .label = "Racket", .marker = "RACKET-RELAY-READY", .relay_argv = &racket_relay },
            .{ .step_name = "racket-relay-backpressure-test", .description = "Prove a stalled reader backpressures the far sender through the Racket relay (needs deno + racket)", .harness = .backpressure, .label = "Racket", .marker = "RACKET-RELAY-READY", .relay_argv = &racket_relay },
            .{ .step_name = "racket-relay-idle-test", .description = "Prove the Racket relay reclaims an idle session (the bounded-resources clause) (needs deno + racket)", .harness = .idle, .label = "Racket", .marker = "RACKET-RELAY-READY", .relay_argv = &racket_relay, .relay_env = &.{.{ "GLOWCAP_RELAY_IDLE_MS", "500" }} },
        },
    }, wasm_driver_install_step, iroh_abi_step);

    // The iroh leg: each runtime's relay dials a real iroh endpoint over QUIC and
    // carries the browser peer's live session through it. The browser probe is
    // bundled with the browser mapping so @glowcap/iroh resolves to its browser arm.
    addRelayFamily(b, .{
        .aggregate_name = "bindings-relay-iroh",
        .aggregate_desc = "Prove the relay's iroh leg across every runtime's relay: a browser peer holds a live iroh session through Deno, Python, Rust, Racket relays (needs deno + uv + cargo + racket)",
        .rows = &.{
            .{ .step_name = "deno-relay-iroh-test", .description = "Prove a browser peer holds a live iroh session through the Deno reference relay (needs deno + cargo)", .harness = .iroh, .label = "Deno", .marker = "DENO-RELAY-READY", .relay_argv = &deno_relay_iroh },
            .{ .step_name = "python-relay-iroh-test", .description = "Prove a browser peer holds a live iroh session through the Python relay (needs deno + uv + cargo)", .harness = .iroh, .label = "Python", .marker = "PYTHON-RELAY-READY", .relay_argv = &python_relay, .build_dep = &python_relay_lifecycle.step },
            .{ .step_name = "rust-relay-iroh-test", .description = "Prove a browser peer holds a live iroh session through the Rust relay (needs deno + cargo)", .harness = .iroh, .label = "Rust", .marker = "RUST-RELAY-READY", .relay_argv = &rust_relay_iroh, .build_dep = &rust_relay_iroh_build.step, .needs_iroh_lib_path = true },
            .{ .step_name = "racket-relay-iroh-test", .description = "Prove a browser peer holds a live iroh session through the Racket relay, dialing iroh via the binding's dial-locator-for-relay (needs deno + cargo + racket)", .harness = .iroh, .label = "Racket", .marker = "RACKET-RELAY-READY", .relay_argv = &racket_relay },
        },
    }, wasm_driver_install_step, iroh_abi_step);

    // The relay's own scaling figure, the sibling of `bench-peer-scaling` for the
    // core. It measures what one more relayed connection costs the byte-transparent
    // reference relay, proves the relay holds thousands of connections at once
    // (not the demo's conservative default), and extrapolates to a host's
    // descriptor and RAM ceiling. A sibling step (needs deno), not folded into the
    // Zig-hermetic `check`; it writes a report under zig-out/bench-reports/. A host
    // with a small open-file limit should lower `--conns`.
    const relay_scaling = execution.addSystemCommand(b, .benchmark, &.{
        "deno",                                    "run",      "--allow-net",  "--allow-run", "--allow-write",
        "bindings/ts/relay/test/scaling_bench.ts", "--report", "--conns=2000",
    });
    relay_scaling.setCwd(b.path("."));
    relay_scaling.has_side_effects = true;
    const relay_scaling_step = b.step("relay-scaling", "Measure the reference relay's per-connection footprint, prove it holds thousands of connections at once, and extrapolate to a host's descriptor and RAM ceiling, the relay-tier sibling of bench-peer-scaling (needs deno)");
    relay_scaling_step.dependOn(&relay_scaling.step);

    // The relay's live Goblins leg: the same keyed conversation `goblins-interop`
    // proves, held through the byte-transparent reference relay. The relay links
    // no codec, so a re-framed or reordered byte would fail the signed
    // handshake; the harness observes that consequence against a real Goblins
    // vat, then the echo round-trip and the repeat-enliven dedup. A sibling of
    // `check`, like the binding Goblins steps. The Goblins vat's fixed port
    // defaults to 22160; `-Dport` moves it.
    const goblins_relay = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{
        "deno",                                          "run",         "--allow-read",
        "--allow-net",                                   "--allow-run", "--allow-env",
        "bindings/ts/web/test/relay_goblins_harness.ts",
    });
    goblins_relay.step.dependOn(wasm_driver_install_step);
    if (pin_port) |p| goblins_relay.addArg(b.fmt("--port={d}", .{p}));
    const goblins_relay_step = b.step("goblins-relay", "Live Goblins through the byte-transparent relay: a browser peer holds a keyed OCapN session with a real Goblins vat through the Deno reference relay (needs deno + racket + goblins)");
    goblins_relay_step.dependOn(&goblins_relay.step);

    // A real Goblins vat as an ordinary member of the rooms chat. The rooms
    // fleet prefers glowcap-next over Cap'n Proto and a Goblins vat speaks only
    // the v1.0 Syrup baseline, so each session settles its own pair
    // (ADR-0103); the harness reads both profiles off the server's live trace
    // rather than taking either member's word for it.
    const goblins_rooms = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{"env"});
    goblins_rooms.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
    goblins_rooms.addArgs(&.{
        "deno",        "run",            "--allow-read",
        "--allow-net", "--allow-run",    "--allow-env",
        "--allow-ffi", "--unstable-ffi", "interop/goblins_rooms/harness.ts",
    });
    goblins_rooms.step.dependOn(rooms_services_install);
    const goblins_rooms_step = b.step("goblins-rooms", "Live Goblins in the rooms chat: a real Goblins vat and a glowcap peer hold one room, each on the profile its own session settled (needs deno + racket + goblins)");
    goblins_rooms_step.dependOn(&goblins_rooms.step);

    // Product-level Peering evidence: the generic handoff fixtures prove the
    // substrate, while this composition includes the foreign-room registry,
    // readiness lease, profile lowering, discovery revoke, and continued use
    // of the already-handed room by a real Goblins vat.
    const goblins_rooms_peering = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{
        "deno", "run", "--allow-all", "interop/goblins_rooms_peering/harness.ts",
    });
    const goblins_rooms_peering_step = b.step("goblins-rooms-peering", "Live Goblins through Rooms Peering: enter a glowcap foreign listing over v1.0/Syrup, revoke discovery, and keep using the handed room (needs deno + racket + goblins)");
    goblins_rooms_peering_step.dependOn(&goblins_rooms_peering.step);

    // Both shipped IRC application edges against the outside protocol
    // authority. The bridge phase drives a local TLS/SASL IRC fixture in both
    // directions; the front phase adds a native room, an ordinary IRC socket,
    // and a real Goblins vat, including reply on the IRC-initiated DM session.
    // They are serialized so logs and resource ownership name one edge at a
    // time, and both fit the ordinary deterministic ceiling without a browser.
    const goblins_rooms_irc_bridge = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{"env"});
    goblins_rooms_irc_bridge.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-irc-bridge" } }, .{ .prefix = "GLOWCAP_ROOMS_IRC_BRIDGE_BIN=", .make_absolute = true });
    goblins_rooms_irc_bridge.addArgs(&.{ "deno", "run", "--allow-all", "interop/goblins_rooms_irc/harness.ts", "--phase=bridge" });
    goblins_rooms_irc_bridge.step.dependOn(rooms_services_install);
    const goblins_rooms_irc_bridge_step = b.step("goblins-rooms-irc-bridge", "Live Goblins through the IRC bridge: fixture IRC and a real vat exchange room lines both ways (needs deno + racket + goblins)");
    goblins_rooms_irc_bridge_step.dependOn(&goblins_rooms_irc_bridge.step);

    const goblins_rooms_irc_front = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{"env"});
    goblins_rooms_irc_front.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
    goblins_rooms_irc_front.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-irc-front" } }, .{ .prefix = "GLOWCAP_ROOMS_IRC_FRONT_BIN=", .make_absolute = true });
    goblins_rooms_irc_front.addArgs(&.{ "deno", "run", "--allow-all", "interop/goblins_rooms_irc/harness.ts", "--phase=front" });
    goblins_rooms_irc_front.step.dependOn(&goblins_rooms_irc_bridge.step);
    const goblins_rooms_irc_front_step = b.step("goblins-rooms-irc-front", "Live Goblins through the IRC front: channel traffic both ways, then IRC initiates a DM and Goblins replies on that session (needs deno + racket + goblins)");
    goblins_rooms_irc_front_step.dependOn(&goblins_rooms_irc_front.step);

    const goblins_rooms_irc_step = b.step("goblins-rooms-irc", "Run both live Goblins compositions for the shipped IRC bridge and front (needs deno + racket + goblins)");
    goblins_rooms_irc_step.dependOn(&goblins_rooms_irc_front.step);

    // The same room over encrypted QUIC. The accepting side records the
    // endpoint key QUIC authenticated. The room server's iroh listener does that
    // for every connection it accepts, and this is where that stays true: the
    // vat is refused without it, and reads the refusal as a decode error
    // because a refusal is framed in the room's own profile.
    const goblins_rooms_iroh = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{"env"});
    goblins_rooms_iroh.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
    goblins_rooms_iroh.addArgs(&.{
        "deno",        "run",            "--allow-read",
        "--allow-net", "--allow-run",    "--allow-env",
        "--allow-ffi", "--unstable-ffi", "interop/goblins_rooms/harness.ts",
        "--iroh",
    });
    // Server and vat both reach iroh through the C ABI companion library.
    goblins_rooms_iroh.step.dependOn(iroh_abi_step);
    goblins_rooms_iroh.step.dependOn(rooms_services_install);
    const goblins_rooms_iroh_step = b.step("goblins-rooms-iroh", "Live Goblins in the rooms chat over iroh's encrypted QUIC: the accepting side records the endpoint id QUIC authenticated (needs cargo + deno + racket + goblins)");
    goblins_rooms_iroh_step.dependOn(&goblins_rooms_iroh.step);

    // A browser tab and a real Goblins vat hold a direct message. The room
    // introduces them and then carries none of it: the tab redeems the give by
    // dialing the vat's own netlayer, and the vat answers over that same
    // connection, which is the only path back to a tab that opens no listener.
    // Three peers across two implementations take the three handoff roles,
    // with nothing changed in Goblins to allow it and the whole conversation
    // drawn on the live timeline from both ends.
    const goblins_rooms_dm = execution.addSystemCommand(b, .{ .browser_proof = 240 }, &.{"env"});
    goblins_rooms_dm.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-web" } }, .{ .prefix = "GLOWCAP_ROOMS_WEB_BIN=", .make_absolute = true });
    goblins_rooms_dm.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
    goblins_rooms_dm.step.dependOn(rooms_services_install);
    goblins_rooms_dm.addArgs(&.{
        "deno", "run", "--allow-all", "interop/goblins_rooms_dm/harness.ts",
    });
    goblins_rooms_dm.setCwd(b.path("."));
    goblins_rooms_dm.has_side_effects = true;
    goblins_rooms_dm.step.dependOn(browser_preflight_step);
    goblins_rooms_dm.step.dependOn(wasm_driver_install_step);
    goblins_rooms_dm.step.dependOn(b.getInstallStep());
    const goblins_rooms_dm_step = b.step("goblins-rooms-dm", "Live Goblins direct message, both directions: a browser tab redeems a room introduction and reaches a real Goblins vat off-room over cleartext TCP, the vat answers over that same connection, and the vat starts a direct message of its own by redeeming a give that names a native glowcap member as its exporter (needs deno + racket + goblins + a Playwright Chromium)");
    goblins_rooms_dm_step.dependOn(&goblins_rooms_dm.step);

    // The same conversation over encrypted QUIC. Both Goblins-facing direct
    // lines use iroh: the browser redeems the vat's introduction, then the vat
    // redeems the native member's. Each accepting endpoint records the key
    // QUIC authenticated as its channel testimony.
    const goblins_rooms_dm_iroh = execution.addSystemCommand(b, .{ .browser_proof = 240 }, &.{"env"});
    goblins_rooms_dm_iroh.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-web" } }, .{ .prefix = "GLOWCAP_ROOMS_WEB_BIN=", .make_absolute = true });
    goblins_rooms_dm_iroh.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
    goblins_rooms_dm_iroh.step.dependOn(rooms_services_install);
    goblins_rooms_dm_iroh.addArgs(&.{
        "deno", "run", "--allow-all", "interop/goblins_rooms_dm/harness.ts", "--iroh",
    });
    goblins_rooms_dm_iroh.setCwd(b.path("."));
    goblins_rooms_dm_iroh.has_side_effects = true;
    goblins_rooms_dm_iroh.step.dependOn(browser_preflight_step);
    goblins_rooms_dm_iroh.step.dependOn(wasm_driver_install_step);
    goblins_rooms_dm_iroh.step.dependOn(iroh_abi_step);
    goblins_rooms_dm_iroh.step.dependOn(b.getInstallStep());
    const goblins_rooms_dm_iroh_step = b.step("goblins-rooms-dm-iroh", "Live Goblins direct messages both ways over encrypted iroh QUIC: the browser redeems the vat's introduction, then the vat redeems a native member's, with authenticated endpoint testimony (needs cargo + deno + racket + goblins + a Playwright Chromium)");
    goblins_rooms_dm_iroh_step.dependOn(&goblins_rooms_dm_iroh.step);

    const goblins_rooms_matrix_phases = [_][]const u8{
        "rooms-mixed",       "rooms-homogeneous", "rooms-split",
        "dms-a",             "dms-b",             "dms-goblins",
        "count-discrepancy",
    };
    var previous_goblins_rooms_matrix_phase: ?*std.Build.Step = null;
    for (goblins_rooms_matrix_phases) |phase| {
        const run = execution.addSystemCommand(b, .{ .browser_proof = 630 }, &.{"env"});
        run.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-web" } }, .{ .prefix = "GLOWCAP_ROOMS_WEB_BIN=", .make_absolute = true });
        run.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
        run.step.dependOn(rooms_services_install);
        run.addArgs(&.{
            "deno",                         "run", "--allow-all", "interop/goblins_rooms_matrix/harness.ts",
            b.fmt("--phase={s}", .{phase}),
        });
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        if (previous_goblins_rooms_matrix_phase) |previous| {
            run.step.dependOn(previous);
        } else {
            run.step.dependOn(browser_preflight_step);
            run.step.dependOn(wasm_driver_install_step);
            run.step.dependOn(iroh_abi_step);
            run.step.dependOn(b.getInstallStep());
        }
        previous_goblins_rooms_matrix_phase = &run.step;
    }
    const goblins_rooms_matrix_iroh_step = b.step("goblins-rooms-matrix-iroh", "Heavy four-peer rooms matrix: pin Goblins' cross-receiver count defect, then exercise mixed and homogeneous rooms, every DM pair, close/reopen, and peer restart over iroh");
    goblins_rooms_matrix_iroh_step.dependOn(previous_goblins_rooms_matrix_phase.?);
}
