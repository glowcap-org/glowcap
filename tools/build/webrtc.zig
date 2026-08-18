//! The WebRTC DataChannel netlayer's build steps (ADR-0089), registered as
//! one subject the root `build.zig` composes. One cargo build of
//! `transports/webrtc/` produces both the phase-1 probe binary and the
//! phase-2 sidecar staticlib `libpancake_webrtc_sidecar.a`. Phase 1 de-risks
//! the transport: the probe binary plus a Deno/Playwright harness drive a
//! real headless Chromium RTCDataChannel on loopback and assert a byte
//! round-trip, proving the crate, the browser RTCDataChannel API, ICE on
//! loopback in a headless container, and the DTLS channel. Phase 2 adds the
//! sidecar's blocking C ABI (`pancake_webrtc_sidecar_*`), the private
//! byte-level seam the Zig resident drives, mirroring the iroh sidecar. The
//! focused phase-1 probe keeps signaling out of band over stdio;
//! `webrtc-signaling-captp` drives the shipped capability-routed signaling
//! path. The live steps are siblings of `check`, not members: they need
//! cargo, deno, and a browser binary. What does ride `check` is every
//! hermetic compile-only object, so a core or resident API change cannot
//! silently rot a driver only the cargo-gated steps run.

const std = @import("std");
const common = @import("common.zig");

/// What the WebRTC family draws from the root build graph: the builder trio,
/// the shared layer-module instances the resident and archives import, the
/// C archive modules the driver-provider seam composes, and the steps the
/// browser proofs hang off. Everything here is minted by the root before the
/// family registers; the family adds no layer of its own.
pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    abi_version: std.SemanticVersion,
    /// The public `pancake` module.
    lib_mod: *std.Build.Module,
    foundation_mod: *std.Build.Module,
    model_mod: *std.Build.Module,
    engine_mod: *std.Build.Module,
    net_mod: *std.Build.Module,
    c_abi_shared_mod: *std.Build.Module,
    host_abi_mod: *std.Build.Module,
    driver_abi_mod: *std.Build.Module,
    interop_harness_mod: *std.Build.Module,
    check_step: *std.Build.Step,
    browser_preflight: *std.Build.Step,
    wasm_driver_install: *std.Build.Step,
};

/// The one handle the rest of the graph consumes after registration: the
/// header generator and the binding-layout generators mint their own C ABI
/// modules over the same resident instance.
pub const Registered = struct {
    resident_mod: *std.Build.Module,
};

/// The webrtc C ABI module: `common.transportAbiModule` over
/// `src/c_abi/net_transport/webrtc/mod.zig` with the injected `webrtc`
/// resident alongside the shared vocabulary leaf, keeping
/// `libpancake_net_transport_webrtc` symbol-disjoint from `libpancake_ocapn`
/// (ADR-0089 phase 3, mirroring the iroh companion).
pub fn abiModule(
    b: *std.Build,
    t: std.Build.ResolvedTarget,
    o: std.builtin.OptimizeMode,
    foundation_mod: *std.Build.Module,
    c_abi_shared_mod: *std.Build.Module,
    resident: *std.Build.Module,
) *std.Build.Module {
    return common.transportAbiModule(b, t, o, "src/c_abi/net_transport/webrtc/mod.zig", &.{
        .{ .name = "webrtc", .module = resident },
        .{ .name = "foundation", .module = foundation_mod },
        .{ .name = "c_abi_shared", .module = c_abi_shared_mod },
    });
}

/// The WebRTC sidecar (ADR-0089 phase 2). The hermetic compile-only objects
/// leave this off, so their externs stay unresolved and they need no cargo.
fn linkSidecar(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    common.linkRustSidecar(b, mod, target, "transports/webrtc/target/release/libpancake_webrtc_sidecar.a");
}

pub fn register(ctx: Context) Registered {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const lib_mod = ctx.lib_mod;
    const interop_harness_mod = ctx.interop_harness_mod;
    const check_step = ctx.check_step;

    // The sidecar's own Rust unit tests, covering the inbound buffer's
    // bound: a far peer that sends faster than the resident reads has to wait
    // for room rather than grow the buffer without limit. Needs cargo, so it
    // is a sibling step like the iroh sidecar's.
    const webrtc_sidecar_test = common.addRootedSystemCommand(b, &.{
        "cargo", "test", "--release", "--manifest-path", "transports/webrtc/Cargo.toml",
    });
    const webrtc_sidecar_test_step = b.step("webrtc-sidecar-test", "Run the WebRTC sidecar Rust unit tests, including the inbound backpressure proof (needs cargo)");
    webrtc_sidecar_test_step.dependOn(&webrtc_sidecar_test.step);

    const webrtc_probe_build = common.addRootedSystemCommand(b, &.{
        "cargo", "build", "--release", "--manifest-path", "transports/webrtc/Cargo.toml",
    });
    const webrtc_lib_step = b.step("webrtc-lib", "Build the WebRTC DataChannel netlayer sidecar staticlib and phase-1 probe binary (ADR-0089; needs cargo)");
    webrtc_lib_step.dependOn(&webrtc_probe_build.step);

    const webrtc_datachannel_test = b.addSystemCommand(&.{
        "deno", "run", "--allow-all", "transports/webrtc/test/datachannel_roundtrip_test.ts",
    });
    webrtc_datachannel_test.setCwd(b.path("."));
    webrtc_datachannel_test.has_side_effects = true;
    webrtc_datachannel_test.step.dependOn(ctx.browser_preflight);
    webrtc_datachannel_test.step.dependOn(&webrtc_probe_build.step);
    const webrtc_datachannel_test_step = b.step("webrtc-datachannel-test", "Prove a headless Chromium RTCDataChannel carries bytes both directions to a native webrtc-crate peer on loopback (ADR-0089 phase 1; needs cargo + deno + a Playwright Chromium)");
    webrtc_datachannel_test_step.dependOn(&webrtc_datachannel_test.step);

    // The phase-2 resident compiles as its own module over the same layer
    // instances, outside the `pancake` root namespace: its externs resolve only
    // when the sidecar staticlib links, so exporting it would drag the Rust
    // sidecar into every gate. A hermetic object build type-checks it under plain
    // `zig build check` with no cargo, catching resident rot the same way the
    // iroh resident check does (ADR-0089 phase 2).
    const webrtc_resident_mod = b.createModule(.{
        .root_source_file = b.path("src/net/transport/webrtc.zig"),
        .target = target,
        .optimize = optimize,
    });
    webrtc_resident_mod.addImport("foundation", ctx.foundation_mod);
    webrtc_resident_mod.addImport("model", ctx.model_mod);
    webrtc_resident_mod.addImport("engine", ctx.engine_mod);
    webrtc_resident_mod.addImport("net", ctx.net_mod);
    const webrtc_resident_check = b.addObject(.{
        .name = "webrtc-resident-check",
        .root_module = webrtc_resident_mod,
    });
    check_step.dependOn(&webrtc_resident_check.step);
    b.step("webrtc-resident-check", "Type-check the WebRTC DataChannel netlayer resident (ADR-0089 phase 2), compile-only, no cargo").dependOn(&webrtc_resident_check.step);

    // The webrtc-interop driver: two native pancake peers hold a keyed OCapN
    // session over a real DataChannel, with signaling ferried in-process (phase
    // 2). It rides `check` as a hermetic compile-only object (no sidecar, externs
    // unresolved) so a core or resident API change cannot silently rot it, and
    // runs as the sibling step `webrtc-interop`, which links the sidecar (cargo).
    const webrtc_interop_compile_mod = b.createModule(.{
        .root_source_file = b.path("interop/webrtc_interop/driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    webrtc_interop_compile_mod.addImport("pancake", lib_mod);
    webrtc_interop_compile_mod.addImport("webrtc", webrtc_resident_mod);
    const webrtc_interop_compile = b.addObject(.{ .name = "pancake-webrtc-interop-compile", .root_module = webrtc_interop_compile_mod });
    check_step.dependOn(&webrtc_interop_compile.step);

    const webrtc_interop_run_mod = b.createModule(.{
        .root_source_file = b.path("interop/webrtc_interop/driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    webrtc_interop_run_mod.addImport("pancake", lib_mod);
    webrtc_interop_run_mod.addImport("webrtc", webrtc_resident_mod);
    linkSidecar(b, webrtc_interop_run_mod, target);
    const webrtc_interop_exe = b.addExecutable(.{ .name = "pancake-webrtc-interop", .root_module = webrtc_interop_run_mod });
    webrtc_interop_exe.step.dependOn(&webrtc_probe_build.step);
    const webrtc_interop_run = b.addRunArtifact(webrtc_interop_exe);
    webrtc_interop_run.setCwd(b.path("."));
    webrtc_interop_run.has_side_effects = true;
    b.step("webrtc-interop", "Live WebRTC: two native pancake peers hold a keyed OCapN session over a real DataChannel (ADR-0089 phase 2; needs cargo)").dependOn(&webrtc_interop_run.step);

    // The signaling mesh (ADR-0089 phase 5): the same two-peer keyed session,
    // but the channel comes up through an OCapN-shaped signaling hub routing
    // offer/answer/candidate by designator, not a direct ferry. webrtc's
    // iroh mesh path. Rides `check` as a hermetic compile-only object and runs as a
    // sidecar-linked sibling.
    const webrtc_mesh_compile_mod = b.createModule(.{
        .root_source_file = b.path("interop/webrtc_mesh/driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    webrtc_mesh_compile_mod.addImport("pancake", lib_mod);
    webrtc_mesh_compile_mod.addImport("webrtc", webrtc_resident_mod);
    const webrtc_mesh_compile = b.addObject(.{ .name = "pancake-webrtc-mesh-compile", .root_module = webrtc_mesh_compile_mod });
    check_step.dependOn(&webrtc_mesh_compile.step);

    const webrtc_mesh_run_mod = b.createModule(.{
        .root_source_file = b.path("interop/webrtc_mesh/driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    webrtc_mesh_run_mod.addImport("pancake", lib_mod);
    webrtc_mesh_run_mod.addImport("webrtc", webrtc_resident_mod);
    linkSidecar(b, webrtc_mesh_run_mod, target);
    const webrtc_mesh_exe = b.addExecutable(.{ .name = "pancake-webrtc-mesh", .root_module = webrtc_mesh_run_mod });
    webrtc_mesh_exe.step.dependOn(&webrtc_probe_build.step);
    const webrtc_mesh_run = b.addRunArtifact(webrtc_mesh_exe);
    webrtc_mesh_run.setCwd(b.path("."));
    webrtc_mesh_run.has_side_effects = true;
    b.step("webrtc-mesh", "Live WebRTC signaling mesh: two native peers bring up a DataChannel through an OCapN signaling hub, then hold a keyed session (ADR-0089 phase 5; needs cargo)").dependOn(&webrtc_mesh_run.step);

    // The shared WebRTC signaling core (interop/webrtc_common.zig): the one
    // signaling inbox and channel-bring-up client that both CapTP-signaling
    // drivers below call, instead of a byte-identical copy in each.
    const webrtc_common_mod = b.createModule(.{
        .root_source_file = b.path("interop/webrtc_common.zig"),
        .target = target,
        .optimize = optimize,
    });
    webrtc_common_mod.addImport("pancake", lib_mod);
    webrtc_common_mod.addImport("webrtc", webrtc_resident_mod);

    // Live WebRTC scale (ADR-0089's generic Host adoption): many DataChannels
    // served from one loop thread through completion.Loop(webrtc.Backend) +
    // driver.Bridge + driver_core.Host, signaling ferried by an in-process hub
    // into the backend's thread-safe adoption entries. Rides `check` as a
    // hermetic compile-only object and runs as a sidecar-linked sibling.
    const webrtc_loop_compile_mod = b.createModule(.{
        .root_source_file = b.path("interop/webrtc_loop/driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    webrtc_loop_compile_mod.addImport("pancake", lib_mod);
    webrtc_loop_compile_mod.addImport("webrtc", webrtc_resident_mod);
    webrtc_loop_compile_mod.addImport("webrtc_common", webrtc_common_mod);
    webrtc_loop_compile_mod.addImport("interop_harness", interop_harness_mod);
    const webrtc_loop_compile = b.addObject(.{ .name = "pancake-webrtc-loop-compile", .root_module = webrtc_loop_compile_mod });
    check_step.dependOn(&webrtc_loop_compile.step);

    const webrtc_loop_run_mod = b.createModule(.{
        .root_source_file = b.path("interop/webrtc_loop/driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    webrtc_loop_run_mod.addImport("pancake", lib_mod);
    webrtc_loop_run_mod.addImport("webrtc", webrtc_resident_mod);
    webrtc_loop_run_mod.addImport("webrtc_common", webrtc_common_mod);
    webrtc_loop_run_mod.addImport("interop_harness", interop_harness_mod);
    linkSidecar(b, webrtc_loop_run_mod, target);
    const webrtc_loop_exe = b.addExecutable(.{ .name = "pancake-webrtc-loop", .root_module = webrtc_loop_run_mod });
    webrtc_loop_exe.step.dependOn(&webrtc_probe_build.step);
    const webrtc_loop_run = b.addRunArtifact(webrtc_loop_exe);
    webrtc_loop_run.setCwd(b.path("."));
    webrtc_loop_run.has_side_effects = true;
    b.step("webrtc-loop", "Live WebRTC scale: many concurrent DataChannels served from one loop thread through the generic Host completion adapter (webrtc.Backend + Bridge + Host, ADR-0089; needs cargo)").dependOn(&webrtc_loop_run.step);

    // The native three-party redeem over a bare webrtc give (ADR-0089's last
    // evidence item): G/E/R each on Bridge + Loop over webrtc.Backend, all
    // signaling through one in-process hub, R redeeming by Loop.dialLocator.
    // Rides `check` as a hermetic compile-only object and runs as a
    // sidecar-linked sibling.
    const webrtc_bridge_redeem_compile_mod = b.createModule(.{
        .root_source_file = b.path("interop/webrtc_bridge_redeem/driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    webrtc_bridge_redeem_compile_mod.addImport("pancake", lib_mod);
    webrtc_bridge_redeem_compile_mod.addImport("webrtc", webrtc_resident_mod);
    webrtc_bridge_redeem_compile_mod.addImport("interop_harness", interop_harness_mod);
    const webrtc_bridge_redeem_compile = b.addObject(.{ .name = "pancake-webrtc-bridge-redeem-compile", .root_module = webrtc_bridge_redeem_compile_mod });
    check_step.dependOn(&webrtc_bridge_redeem_compile.step);

    const webrtc_bridge_redeem_run_mod = b.createModule(.{
        .root_source_file = b.path("interop/webrtc_bridge_redeem/driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    webrtc_bridge_redeem_run_mod.addImport("pancake", lib_mod);
    webrtc_bridge_redeem_run_mod.addImport("webrtc", webrtc_resident_mod);
    webrtc_bridge_redeem_run_mod.addImport("interop_harness", interop_harness_mod);
    linkSidecar(b, webrtc_bridge_redeem_run_mod, target);
    const webrtc_bridge_redeem_exe = b.addExecutable(.{ .name = "pancake-webrtc-bridge-redeem", .root_module = webrtc_bridge_redeem_run_mod });
    webrtc_bridge_redeem_exe.step.dependOn(&webrtc_probe_build.step);
    const webrtc_bridge_redeem_run = b.addRunArtifact(webrtc_bridge_redeem_exe);
    webrtc_bridge_redeem_run.setCwd(b.path("."));
    webrtc_bridge_redeem_run.has_side_effects = true;
    b.step("webrtc-bridge-redeem", "Live native three-party handoff over WebRTC: the recipient's loop redeems a give naming a bare webrtc designator, dialing through its configured signaling authority (ADR-0089; needs cargo)").dependOn(&webrtc_bridge_redeem_run.step);

    // The signaling object as a real OCapN capability over CapTP (ADR-0089 phase
    // 6, native half): the exporter hosts a signaling inbox behind a keyed
    // session, and the recipient drives offer/answer/candidate over that session
    // to bring the DataChannel up, then holds the direct keyed session over it.
    // The wire-capability shape the browser arm and a room-introduction redeem
    // build on. Rides `check` as a hermetic compile-only object and runs as a
    // sidecar-linked sibling.
    const webrtc_signaling_captp_compile_mod = b.createModule(.{
        .root_source_file = b.path("interop/webrtc_signaling_captp/driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    webrtc_signaling_captp_compile_mod.addImport("pancake", lib_mod);
    webrtc_signaling_captp_compile_mod.addImport("webrtc", webrtc_resident_mod);
    webrtc_signaling_captp_compile_mod.addImport("webrtc_common", webrtc_common_mod);
    const webrtc_signaling_captp_compile = b.addObject(.{ .name = "pancake-webrtc-signaling-captp-compile", .root_module = webrtc_signaling_captp_compile_mod });
    check_step.dependOn(&webrtc_signaling_captp_compile.step);

    const webrtc_signaling_captp_run_mod = b.createModule(.{
        .root_source_file = b.path("interop/webrtc_signaling_captp/driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    webrtc_signaling_captp_run_mod.addImport("pancake", lib_mod);
    webrtc_signaling_captp_run_mod.addImport("webrtc", webrtc_resident_mod);
    webrtc_signaling_captp_run_mod.addImport("webrtc_common", webrtc_common_mod);
    linkSidecar(b, webrtc_signaling_captp_run_mod, target);
    const webrtc_signaling_captp_exe = b.addExecutable(.{ .name = "pancake-webrtc-signaling-captp", .root_module = webrtc_signaling_captp_run_mod });
    webrtc_signaling_captp_exe.step.dependOn(&webrtc_probe_build.step);
    const webrtc_signaling_captp_run = b.addRunArtifact(webrtc_signaling_captp_exe);
    webrtc_signaling_captp_run.setCwd(b.path("."));
    webrtc_signaling_captp_run.has_side_effects = true;
    b.step("webrtc-signaling-captp", "Live WebRTC signaling capability over CapTP: the exporter hosts a signaling inbox behind a keyed session, the recipient drives offer/answer/candidate over it to open a DataChannel, then holds a keyed session over it (ADR-0089 phase 5; needs cargo)").dependOn(&webrtc_signaling_captp_run.step);

    // The native answerer for the webrtc-browser-peer proof (ADR-0089 phase 6):
    // it serves a keyed session over the sidecar with signaling ferried over
    // stdio, so a real browser (@pancake/webrtc + the wasm Host) is the offerer.
    // Rides `check` as a hermetic compile object; the sidecar-linked binary is
    // installed for the Playwright harness (added with the webrtc-browser-peer
    // step) to drive.
    const webrtc_answerer_compile_mod = b.createModule(.{
        .root_source_file = b.path("interop/webrtc_browser_peer/answerer.zig"),
        .target = target,
        .optimize = optimize,
    });
    webrtc_answerer_compile_mod.addImport("pancake", lib_mod);
    webrtc_answerer_compile_mod.addImport("webrtc", webrtc_resident_mod);
    const webrtc_answerer_compile = b.addObject(.{ .name = "pancake-webrtc-answerer-compile", .root_module = webrtc_answerer_compile_mod });
    check_step.dependOn(&webrtc_answerer_compile.step);

    const webrtc_answerer_run_mod = b.createModule(.{
        .root_source_file = b.path("interop/webrtc_browser_peer/answerer.zig"),
        .target = target,
        .optimize = optimize,
    });
    webrtc_answerer_run_mod.addImport("pancake", lib_mod);
    webrtc_answerer_run_mod.addImport("webrtc", webrtc_resident_mod);
    linkSidecar(b, webrtc_answerer_run_mod, target);
    const webrtc_answerer_exe = b.addExecutable(.{ .name = "pancake-webrtc-answerer", .root_module = webrtc_answerer_run_mod });
    webrtc_answerer_exe.step.dependOn(&webrtc_probe_build.step);
    const webrtc_answerer_install = b.addInstallArtifact(webrtc_answerer_exe, .{});
    b.step("webrtc-answerer", "Build the native answerer for the webrtc-browser-peer proof (ADR-0089 phase 6; needs cargo)").dependOn(&webrtc_answerer_install.step);

    // The full browser-peer proof: a real headless Chromium bundles @pancake/web
    // and @pancake/webrtc, brings up a DataChannel to the native answerer through
    // the harness's stdio signaling ferry, and runs a keyed OCapN session over it
    // — fetch, call, check the reply. The browser twin of `webrtc-interop`. Needs
    // deno, the wasm module, the sidecar-linked answerer, and a Playwright
    // Chromium. A sibling step, not folded into `check` (it needs cargo + a
    // browser binary).
    const webrtc_browser_peer = b.addSystemCommand(&.{
        "deno", "run", "--allow-all", "interop/webrtc_browser_peer/browser_peer_test.ts",
    });
    webrtc_browser_peer.setCwd(b.path("."));
    webrtc_browser_peer.has_side_effects = true;
    webrtc_browser_peer.step.dependOn(ctx.browser_preflight);
    webrtc_browser_peer.step.dependOn(ctx.wasm_driver_install);
    webrtc_browser_peer.step.dependOn(&webrtc_answerer_install.step);
    b.step("webrtc-browser-peer", "Prove a real headless Chromium runs @pancake/web + @pancake/webrtc: a DataChannel to the native answerer carries a keyed OCapN session (ADR-0089 phase 6; needs cargo + deno + a Playwright Chromium)").dependOn(&webrtc_browser_peer.step);

    // The two-browser end state: two headless Chromium contexts each run
    // @pancake/web + @pancake/webrtc, exchange signaling through a byte relay, and
    // bring up a direct DataChannel between them that carries a keyed OCapN
    // session — the answerer publishes a greeter and accepts, the offerer dials
    // its key and greets. No sidecar (both peers are browsers), so it is
    // deno-only: needs the wasm module and a Playwright Chromium. A sibling step,
    // not folded into `check`.
    const webrtc_browser_to_browser = b.addSystemCommand(&.{
        "deno", "run", "--allow-all", "interop/webrtc_browser_to_browser/browser_to_browser_test.ts",
    });
    webrtc_browser_to_browser.setCwd(b.path("."));
    webrtc_browser_to_browser.has_side_effects = true;
    webrtc_browser_to_browser.step.dependOn(ctx.browser_preflight);
    webrtc_browser_to_browser.step.dependOn(ctx.wasm_driver_install);
    b.step("webrtc-browser-to-browser", "Prove two real headless Chromium peers bring up a direct WebRTC DataChannel and hold a keyed OCapN session over it, the offerer dialing a bare webrtc locator through the signaling authority of its composed webrtc connector, the signaling host out of the byte path (ADR-0089; needs deno + a Playwright Chromium)").dependOn(&webrtc_browser_to_browser.step);

    // The WebRTC established-connection seam: signaling stays in the raw
    // WebRTC C archive, then both peers are adopted by independent generic
    // driver loops. The compile object rides `check`; only the sibling live
    // step links the Rust sidecar.
    {
        const seam_source = "interop/webrtc_driver_provider/driver.zig";
        const seam_imports = [_]common.AbiImport{
            .{ .name = "c_abi_shared", .module = ctx.c_abi_shared_mod },
            .{ .name = "c_abi_host", .module = ctx.host_abi_mod },
            .{ .name = "c_abi_driver", .module = ctx.driver_abi_mod },
        };

        const seam_compile_mod = b.createModule(.{
            .root_source_file = b.path(seam_source),
            .target = target,
            .optimize = optimize,
        });
        for (seam_imports) |imp| seam_compile_mod.addImport(imp.name, imp.module);
        seam_compile_mod.addImport("c_abi_net_transport_webrtc", abiModule(b, target, optimize, ctx.foundation_mod, ctx.c_abi_shared_mod, webrtc_resident_mod));
        const seam_compile = b.addObject(.{ .name = "pancake-webrtc-driver-provider-compile", .root_module = seam_compile_mod });
        check_step.dependOn(&seam_compile.step);

        const seam_run_mod = b.createModule(.{
            .root_source_file = b.path(seam_source),
            .target = target,
            .optimize = optimize,
        });
        for (seam_imports) |imp| seam_run_mod.addImport(imp.name, imp.module);
        seam_run_mod.addImport("c_abi_net_transport_webrtc", abiModule(b, target, optimize, ctx.foundation_mod, ctx.c_abi_shared_mod, webrtc_resident_mod));
        linkSidecar(b, seam_run_mod, target);
        const seam_exe = b.addExecutable(.{ .name = "pancake-webrtc-driver-provider", .root_module = seam_run_mod });
        seam_exe.step.dependOn(&webrtc_probe_build.step);
        const seam_run = b.addRunArtifact(seam_exe);
        seam_run.setCwd(b.path("."));
        seam_run.has_side_effects = true;
        b.step("webrtc-driver-provider", "Live WebRTC C-provider proof: raw C signaling transfers two open peers into generic driver loops (needs cargo)").dependOn(&seam_run.step);
    }

    // libpancake_net_transport_webrtc: the WebRTC transport's public C ABI
    // companion (ADR-0089 phase 3). Like the iroh companion it links the Rust
    // sidecar and exports only its own `pancake_webrtc_*` family, sharing the
    // base ABI by layout, so it is a sibling of `check` (needs cargo). The
    // header generator and its staleness check are the root's
    // `gen-header-net-transport-webrtc` pair; this step builds and installs
    // the library.
    const webrtc_abi_link_mod = abiModule(b, target, optimize, ctx.foundation_mod, ctx.c_abi_shared_mod, webrtc_resident_mod);
    linkSidecar(b, webrtc_abi_link_mod, target);
    const webrtc_abi_shared = b.addLibrary(.{
        .name = "pancake_net_transport_webrtc",
        .linkage = .dynamic,
        .root_module = webrtc_abi_link_mod,
        .version = ctx.abi_version,
    });
    if (target.result.ofmt == .elf) {
        // Keep the Rust sidecar and its runtime private to this artifact. The
        // public companion surface is the generated pancake_webrtc_* family.
        webrtc_abi_shared.version_script = ctx.b.path("tools/build/exports/webrtc.map");
    }
    webrtc_abi_shared.step.dependOn(&webrtc_probe_build.step);
    const webrtc_abi_install = b.addInstallArtifact(webrtc_abi_shared, .{});
    const webrtc_abi_header_install = b.addInstallHeaderFile(b.path("include/pancake_net_transport_webrtc.h"), "pancake_net_transport_webrtc.h");
    const webrtc_abi_step = b.step("webrtc-abi", "Build libpancake_net_transport_webrtc, the WebRTC transport's public C ABI companion (ADR-0089 phase 3; needs cargo)");
    webrtc_abi_step.dependOn(&webrtc_abi_install.step);
    webrtc_abi_step.dependOn(&webrtc_abi_header_install.step);
    if (target.result.ofmt == .elf) {
        const export_check = common.addRootedSystemCommand(b, &.{ "bash", "tools/check/sidecar-exports.sh" });
        export_check.addFileArg(webrtc_abi_shared.getEmittedBin());
        export_check.addArg("pancake_webrtc_");
        export_check.addArg("pancake_webrtc_sidecar_");
        webrtc_abi_step.dependOn(&export_check.step);
    }

    return .{ .resident_mod = webrtc_resident_mod };
}
