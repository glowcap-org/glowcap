//! WebRTC DataChannel build steps (ADR-0089).
//!
//! The Rust crate builds the probe binary and sidecar staticlib. Live steps stay
//! outside `check` because they need cargo, deno, and a browser. Compile-only
//! objects do ride `check`, so Zig API drift is caught without requiring those
//! tools.

const std = @import("std");
const common = @import("common.zig");
const execution = @import("execution.zig");

/// What the WebRTC family draws from the root build graph: the builder trio,
/// the shared layer-module instances the resident and archives import, the
/// C archive modules the driver-provider seam composes, and the steps the
/// browser proofs hang off. Everything here is minted by the root before the
/// family registers. The family adds no layer of its own.
pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    abi_version: std.SemanticVersion,
    /// The public `glowcap` module.
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
    /// The site's Zig example tabs compile under this step.
    site_zig_examples_check: *std.Build.Step,
    browser_preflight: *std.Build.Step,
    wasm_driver_install: *std.Build.Step,
};

/// The one handle the rest of the graph consumes after registration: the
/// header generator and the binding-layout generators mint their own C ABI
/// modules over the same resident instance.
pub const Registered = struct {
    resident_mod: *std.Build.Module,
    /// `webrtc-abi`: the shared C library every binding's live dial links.
    abi_step: *std.Build.Step,
    /// `webrtc-answerer`: the Zig peer those dials reach over stdio signaling.
    answerer_install_step: *std.Build.Step,
    /// `webrtc-offerer`: the Zig peer the binding listeners accept the same way.
    offerer_install_step: *std.Build.Step,
};

/// The webrtc C ABI module: `common.transportAbiModule` over
/// `src/c_abi/net_transport/webrtc/mod.zig` with the injected `webrtc`
/// resident alongside the shared vocabulary leaf, keeping
/// `libglowcap_net_transport_webrtc` symbol-disjoint from `libglowcap_ocapn`
/// (ADR-0089).
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

/// The WebRTC sidecar (ADR-0089). The hermetic compile-only objects
/// leave this off, so their externs stay unresolved and they need no cargo.
/// The archive is the cargo step's output, so linking it orders the build.
fn linkSidecar(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    archive: std.Build.LazyPath,
) void {
    common.linkRustSidecar(b, mod, target, archive);
}

const DriverImports = struct {
    webrtc_common: bool = false,
    interop_harness: bool = false,
};

const LiveDriver = struct {
    step_name: []const u8,
    description: []const u8,
    exe_name: []const u8,
    root_source: []const u8,
    imports: DriverImports = .{},
    posture: execution.Posture = .{ .deterministic = 30 },
};

/// A standalone Zig WebRTC peer that speaks stdio signaling with a harness
/// (`interop/webrtc_common/stdio.zig`).
const StdioPeer = struct {
    step_name: []const u8,
    description: []const u8,
    exe_name: []const u8,
    root_source: []const u8,
};

const BrowserProof = struct {
    step_name: []const u8,
    description: []const u8,
    script: []const u8,
    needs_answerer: bool = false,
};

fn driverModule(
    ctx: Context,
    resident_mod: *std.Build.Module,
    webrtc_common_mod: *std.Build.Module,
    drv: LiveDriver,
) *std.Build.Module {
    const mod = ctx.b.createModule(.{
        .root_source_file = ctx.b.path(drv.root_source),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    mod.addImport("glowcap", ctx.lib_mod);
    mod.addImport("webrtc", resident_mod);
    if (drv.imports.webrtc_common) mod.addImport("webrtc_common", webrtc_common_mod);
    if (drv.imports.interop_harness) mod.addImport("interop_harness", ctx.interop_harness_mod);
    return mod;
}

fn addLiveDriver(
    ctx: Context,
    resident_mod: *std.Build.Module,
    webrtc_common_mod: *std.Build.Module,
    sidecar_archive: std.Build.LazyPath,
    drv: LiveDriver,
) void {
    const b = ctx.b;
    const compile_mod = driverModule(ctx, resident_mod, webrtc_common_mod, drv);
    const compile_obj = b.addObject(.{ .name = b.fmt("{s}-compile", .{drv.exe_name}), .root_module = compile_mod });
    ctx.check_step.dependOn(&compile_obj.step);

    const run_mod = driverModule(ctx, resident_mod, webrtc_common_mod, drv);
    linkSidecar(b, run_mod, ctx.target, sidecar_archive);
    const exe = b.addExecutable(.{ .name = drv.exe_name, .root_module = run_mod });
    const run = execution.addArtifact(b, drv.posture, exe);
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    b.step(drv.step_name, drv.description).dependOn(&run.step);
}

fn addBrowserProof(
    ctx: Context,
    proof: BrowserProof,
    answerer_install: *std.Build.Step,
) void {
    const run = execution.addSystemCommand(ctx.b, .{ .browser_proof = 120 }, &.{ "deno", "run", "--allow-all", proof.script });
    const cache = execution.addSystemCommand(ctx.b, .build_tool, &.{ "deno", "cache", proof.script });
    run.step.dependOn(&cache.step);
    run.setCwd(ctx.b.path("."));
    run.has_side_effects = true;
    run.step.dependOn(ctx.browser_preflight);
    run.step.dependOn(ctx.wasm_driver_install);
    if (proof.needs_answerer) run.step.dependOn(answerer_install);
    ctx.b.step(proof.step_name, proof.description).dependOn(&run.step);
}

pub fn register(ctx: Context) Registered {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const lib_mod = ctx.lib_mod;
    const check_step = ctx.check_step;

    // The sidecar's own Rust unit tests, covering the inbound buffer's
    // bound: a far peer that sends faster than the resident reads has to wait
    // for room rather than grow the buffer without limit. Needs cargo, so it
    // is a sibling step like the iroh sidecar's.
    const webrtc_sidecar_test = common.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{
        "cargo", "test", "--release", "--manifest-path", "transports/webrtc/Cargo.toml",
    });
    const webrtc_sidecar_test_compile = common.addRootedSystemCommand(b, .build_tool, &.{
        "cargo", "test", "--no-run", "--release", "--manifest-path", "transports/webrtc/Cargo.toml",
    });
    webrtc_sidecar_test.step.dependOn(&webrtc_sidecar_test_compile.step);
    const webrtc_sidecar_test_step = b.step("webrtc-sidecar-test", "Run the WebRTC sidecar Rust unit tests, including the inbound backpressure proof (needs cargo)");
    webrtc_sidecar_test_step.dependOn(&webrtc_sidecar_test.step);

    // The target directory is a build output, as for the iroh sidecar: every
    // linker and the browser proof depend on the archive and probe by path, in
    // this tree and in a downstream package that imports `glowcap_webrtc`.
    const webrtc_probe_build = common.addRootedSystemCommand(b, .build_tool, &.{
        "cargo", "build", "--locked", "--release", "--manifest-path", "transports/webrtc/Cargo.toml",
    });
    const sidecar_target_dir = webrtc_probe_build.addPrefixedOutputDirectoryArg("--target-dir=", "target");
    webrtc_probe_build.has_side_effects = true;
    const sidecar_archive = sidecar_target_dir.path(b, "release/libglowcap_webrtc_sidecar.a");
    const webrtc_lib_step = b.step("webrtc-lib", "Build the WebRTC DataChannel netlayer sidecar staticlib and probe binary (ADR-0089, needs cargo)");
    webrtc_lib_step.dependOn(&webrtc_probe_build.step);

    const webrtc_datachannel_test = execution.addSystemCommand(b, .{ .browser_proof = 90 }, &.{
        "deno", "run", "--allow-all", "transports/webrtc/test/datachannel_roundtrip_test.ts",
    });
    webrtc_datachannel_test.addFileArg(sidecar_target_dir.path(b, "release/glowcap-webrtc-datachannel-probe"));
    const webrtc_datachannel_cache = execution.addSystemCommand(b, .build_tool, &.{
        "deno", "cache", "transports/webrtc/test/datachannel_roundtrip_test.ts",
    });
    webrtc_datachannel_test.step.dependOn(&webrtc_datachannel_cache.step);
    webrtc_datachannel_test.setCwd(b.path("."));
    webrtc_datachannel_test.has_side_effects = true;
    webrtc_datachannel_test.step.dependOn(ctx.browser_preflight);
    const webrtc_datachannel_test_step = b.step("webrtc-datachannel-test", "Prove a headless Chromium RTCDataChannel carries bytes both directions to a Rust webrtc-crate peer on loopback (ADR-0089, needs cargo + deno + a Playwright Chromium)");
    webrtc_datachannel_test_step.dependOn(&webrtc_datachannel_test.step);

    // The phase-2 resident compiles as its own module over the same layer
    // instances, outside the `glowcap` root namespace: its externs resolve only
    // when the sidecar staticlib links, so exporting it would drag the Rust
    // sidecar into every gate. A hermetic object build type-checks it under plain
    // `zig build check` with no cargo, catching resident rot the same way the
    // iroh resident check does (ADR-0089).
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
    b.step("webrtc-resident-check", "Type-check the WebRTC DataChannel netlayer resident (ADR-0089), compile-only, no cargo").dependOn(&webrtc_resident_check.step);

    // The same resident published for a downstream package, with the sidecar
    // attached, so `glowcap.module("glowcap_webrtc")` is the `webrtc` import
    // the site's Zig tab names. A second module over the same source keeps the
    // in-tree resident unlinked for the hermetic compile objects in `check`.
    const published_webrtc_mod = b.addModule("glowcap_webrtc", .{
        .root_source_file = b.path("src/net/transport/webrtc.zig"),
        .target = target,
        .optimize = optimize,
    });
    published_webrtc_mod.addImport("foundation", ctx.foundation_mod);
    published_webrtc_mod.addImport("model", ctx.model_mod);
    published_webrtc_mod.addImport("engine", ctx.engine_mod);
    published_webrtc_mod.addImport("net", ctx.net_mod);
    linkSidecar(b, published_webrtc_mod, target, sidecar_archive);

    // The site's Zig dial tab: `driver.connect` over the completion resident,
    // with the application's signaling authority, as `webrtc_redeem` runs it.
    common.addSiteZigExampleCompile(b, target, optimize, "site-dial-webrtc", "site/examples/dial/webrtc.zig", &.{ .{ .name = "glowcap", .module = lib_mod }, .{ .name = "webrtc", .module = webrtc_resident_mod } }, ctx.site_zig_examples_check);

    // Internal owner evidence imports the leaves directly: cross-file `pub`
    // is not a reason to widen the supported `webrtc` facade. All three files
    // link the scripted sidecar in `test/net/webrtc_sidecar_stub.zig`, so
    // they run without cargo.
    const webrtc_internal_test_step = b.step("webrtc-internal-test", "Run WebRTC resident ownership, bounded-signaling, managed-dial, and managed-accept tests against a scripted sidecar");
    const webrtc_abi_mod = abiModule(b, target, optimize, ctx.foundation_mod, ctx.c_abi_shared_mod, webrtc_resident_mod);
    for ([_][]const u8{ "test/net/webrtc_internal_test.zig", "test/net/webrtc_provider_dial_test.zig", "test/net/webrtc_provider_accept_test.zig" }, [_][]const u8{ "webrtc-internal-test", "webrtc-provider-dial-test", "webrtc-provider-accept-test" }) |source, name| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
        });
        test_mod.addImport("net", ctx.net_mod);
        test_mod.addImport("foundation", ctx.foundation_mod);
        test_mod.addImport("webrtc", webrtc_resident_mod);
        test_mod.addImport("c_abi_shared", ctx.c_abi_shared_mod);
        test_mod.addImport("c_abi_net_transport_webrtc", webrtc_abi_mod);
        const tests = b.addTest(.{ .name = name, .root_module = test_mod });
        const run = execution.addZigTest(b, tests, .unit_test);
        webrtc_internal_test_step.dependOn(&run.step);
    }
    check_step.dependOn(webrtc_internal_test_step);

    // The shared WebRTC interop core (interop/webrtc_common.zig): signaling
    // inbox helpers plus the Host packet pump every Zig WebRTC proof uses.
    const webrtc_common_mod = b.createModule(.{
        .root_source_file = b.path("interop/webrtc_common.zig"),
        .target = target,
        .optimize = optimize,
    });
    webrtc_common_mod.addImport("glowcap", lib_mod);
    webrtc_common_mod.addImport("webrtc", webrtc_resident_mod);

    // Each live Zig proof has the same build shape: a cargo-free compile
    // object rides `check`; a sidecar-linked executable remains an opt-in
    // sibling. Rows name only their imports and evidence.
    const live_drivers = [_]LiveDriver{
        .{
            .step_name = "webrtc-interop",
            .description = "Live WebRTC: two Zig glowcap peers hold a keyed OCapN session over a real DataChannel (ADR-0089, needs cargo)",
            .exe_name = "glowcap-webrtc-interop",
            .root_source = "interop/webrtc_interop/driver.zig",
            .imports = .{ .webrtc_common = true },
        },
        .{
            .step_name = "webrtc-mesh",
            .description = "Live WebRTC signaling mesh: two Zig peers bring up a DataChannel through an OCapN signaling hub, then hold a keyed session (ADR-0089, needs cargo)",
            .exe_name = "glowcap-webrtc-mesh",
            .root_source = "interop/webrtc_mesh/driver.zig",
            .imports = .{ .webrtc_common = true },
        },
        .{
            .step_name = "webrtc-loop",
            .description = "Live WebRTC scale: many concurrent DataChannels, each answered by the completion backend and served from one HostRuntime thread with the client's identity proved (ADR-0089, ADR-0202 and ADR-0232, needs cargo)",
            .exe_name = "glowcap-webrtc-loop",
            .root_source = "interop/webrtc_loop/driver.zig",
            .imports = .{ .webrtc_common = true },
        },
        .{
            .step_name = "webrtc-redeem",
            .description = "Live three-party handoff over WebRTC: a recipient Session redeems a bare webrtc give through its signaling authority, and every exporter's backend answers the offer itself (ADR-0089 and ADR-0232, needs cargo)",
            .exe_name = "glowcap-webrtc-redeem",
            .root_source = "interop/webrtc_redeem/driver.zig",
            .imports = .{ .interop_harness = true },
        },
        .{
            .step_name = "webrtc-signaling-captp",
            .description = "Live WebRTC signaling capability over CapTP: signaling opens the DataChannel, then the keyed session runs over it (ADR-0089, needs cargo)",
            .exe_name = "glowcap-webrtc-signaling-captp",
            .root_source = "interop/webrtc_signaling_captp/driver.zig",
            .imports = .{ .webrtc_common = true },
        },
    };
    for (live_drivers) |drv| addLiveDriver(ctx, webrtc_resident_mod, webrtc_common_mod, sidecar_archive, drv);

    // The standalone peers the browser proof and the binding proofs drive over
    // stdio signaling. Each rides `check` as a hermetic compile object, and
    // its sidecar-linked binary is installed by its own step.
    const webrtc_answerer_install = addStdioPeer(ctx, webrtc_resident_mod, webrtc_common_mod, sidecar_archive, .{
        .step_name = "webrtc-answerer",
        .description = "Build the Zig answerer the webrtc-browser-peer proof and the binding dial proofs reach (ADR-0089, needs cargo)",
        .exe_name = "glowcap-webrtc-answerer",
        .root_source = "interop/webrtc_browser_peer/answerer.zig",
    });
    const webrtc_offerer_install = addStdioPeer(ctx, webrtc_resident_mod, webrtc_common_mod, sidecar_archive, .{
        .step_name = "webrtc-offerer",
        .description = "Build the Zig offerer the binding listen proofs accept (ADR-0232, needs cargo)",
        .exe_name = "glowcap-webrtc-offerer",
        .root_source = "interop/webrtc_driver_provider/offerer.zig",
    });

    const browser_proofs = [_]BrowserProof{
        .{
            .step_name = "webrtc-browser-peer",
            .description = "Prove a real headless Chromium runs @glowcap/web + @glowcap/webrtc: a DataChannel to the Zig answerer carries a keyed OCapN session (ADR-0089, needs cargo + deno + a Playwright Chromium)",
            .script = "interop/webrtc_browser_peer/browser_peer_test.ts",
            .needs_answerer = true,
        },
        .{
            .step_name = "webrtc-browser-to-browser",
            .description = "Prove two real headless Chromium peers hold a keyed OCapN session over a direct WebRTC DataChannel, one dialing through the WebRTC connector and the other accepting through the WebRTC listener, the signaling host out of the byte path (ADR-0089, needs deno + a Playwright Chromium)",
            .script = "interop/webrtc_browser_to_browser/browser_to_browser_test.ts",
        },
    };
    for (browser_proofs) |proof| addBrowserProof(ctx, proof, webrtc_answerer_install);

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
        const seam_compile = b.addObject(.{ .name = "glowcap-webrtc-driver-provider-compile", .root_module = seam_compile_mod });
        check_step.dependOn(&seam_compile.step);

        const seam_run_mod = b.createModule(.{
            .root_source_file = b.path(seam_source),
            .target = target,
            .optimize = optimize,
        });
        for (seam_imports) |imp| seam_run_mod.addImport(imp.name, imp.module);
        seam_run_mod.addImport("c_abi_net_transport_webrtc", abiModule(b, target, optimize, ctx.foundation_mod, ctx.c_abi_shared_mod, webrtc_resident_mod));
        linkSidecar(b, seam_run_mod, target, sidecar_archive);
        const seam_exe = b.addExecutable(.{ .name = "glowcap-webrtc-driver-provider", .root_module = seam_run_mod });
        const seam_run = execution.addArtifact(b, .{ .deterministic = 30 }, seam_exe);
        seam_run.setCwd(b.path("."));
        seam_run.has_side_effects = true;
        b.step("webrtc-driver-provider", "Live WebRTC C-provider proof: the generic C driver dials and listens through the WebRTC provider's signaling callbacks, the offer is handed in with provide_offer, and releasing the loop cancels a dial still in flight (needs cargo)").dependOn(&seam_run.step);
    }

    // libglowcap_net_transport_webrtc: the WebRTC transport's public C ABI
    // companion (ADR-0089). Like the iroh companion it links the Rust
    // sidecar and exports only its own `glowcap_webrtc_*` family, sharing the
    // base ABI by layout, so it is a sibling of `check` (needs cargo). The
    // header generator and its staleness check are the root's
    // `gen-header-net-transport-webrtc` pair; this step builds and installs
    // the library.
    const webrtc_abi_link_mod = abiModule(b, target, optimize, ctx.foundation_mod, ctx.c_abi_shared_mod, webrtc_resident_mod);
    linkSidecar(b, webrtc_abi_link_mod, target, sidecar_archive);
    const webrtc_abi_shared = b.addLibrary(.{
        .name = "glowcap_net_transport_webrtc",
        .linkage = .dynamic,
        .root_module = webrtc_abi_link_mod,
        .version = ctx.abi_version,
    });
    if (target.result.ofmt == .elf) {
        // Keep the Rust sidecar and its runtime private to this artifact. The
        // public companion surface is the generated glowcap_webrtc_* family.
        webrtc_abi_shared.version_script = ctx.b.path("tools/build/exports/webrtc.map");
        // The self-hosted backend accepts --version-script but does not honor
        // it; see the sibling note in tools/build/iroh.zig. The boundary holds
        // in every mode, so this archive always compiles and links through
        // LLVM/lld.
        webrtc_abi_shared.use_llvm = true;
        webrtc_abi_shared.use_lld = true;
    }
    const webrtc_abi_install = b.addInstallArtifact(webrtc_abi_shared, .{});
    common.checkArchiveTls(ctx.b, webrtc_abi_shared, &webrtc_abi_install.step);
    common.checkArchiveResident(ctx.b, webrtc_abi_shared, &webrtc_abi_install.step);
    const webrtc_abi_header_install = b.addInstallHeaderFile(b.path("include/glowcap_net_transport_webrtc.h"), "glowcap_net_transport_webrtc.h");
    const webrtc_abi_step = b.step("webrtc-abi", "Build libglowcap_net_transport_webrtc, the WebRTC transport's public C ABI companion (ADR-0089, needs cargo)");
    webrtc_abi_step.dependOn(&webrtc_abi_install.step);
    webrtc_abi_step.dependOn(&webrtc_abi_header_install.step);
    if (target.result.ofmt == .elf) {
        const export_check = common.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{ "bash", "tools/check/sidecar-exports.sh" });
        export_check.addFileArg(webrtc_abi_shared.getEmittedBin());
        export_check.addArg("glowcap_webrtc_");
        export_check.addArg("glowcap_webrtc_sidecar_");
        webrtc_abi_step.dependOn(&export_check.step);
    }

    return .{
        .resident_mod = webrtc_resident_mod,
        .abi_step = webrtc_abi_step,
        .answerer_install_step = webrtc_answerer_install,
        .offerer_install_step = webrtc_offerer_install,
    };
}

/// Register one stdio peer: a cargo-free compile object under `check`, and
/// the sidecar-linked executable its step installs. Returns the install step.
fn addStdioPeer(
    ctx: Context,
    webrtc_resident_mod: *std.Build.Module,
    webrtc_common_mod: *std.Build.Module,
    sidecar_archive: std.Build.LazyPath,
    peer: StdioPeer,
) *std.Build.Step {
    const b = ctx.b;
    const compile_mod = b.createModule(.{
        .root_source_file = b.path(peer.root_source),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    compile_mod.addImport("glowcap", ctx.lib_mod);
    compile_mod.addImport("webrtc", webrtc_resident_mod);
    compile_mod.addImport("webrtc_common", webrtc_common_mod);
    const compile = b.addObject(.{ .name = b.fmt("{s}-compile", .{peer.exe_name}), .root_module = compile_mod });
    ctx.check_step.dependOn(&compile.step);

    const run_mod = b.createModule(.{
        .root_source_file = b.path(peer.root_source),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    run_mod.addImport("glowcap", ctx.lib_mod);
    run_mod.addImport("webrtc", webrtc_resident_mod);
    run_mod.addImport("webrtc_common", webrtc_common_mod);
    linkSidecar(b, run_mod, ctx.target, sidecar_archive);
    const exe = b.addExecutable(.{ .name = peer.exe_name, .root_module = run_mod });
    const install = b.addInstallArtifact(exe, .{});
    b.step(peer.step_name, peer.description).dependOn(&install.step);
    return &install.step;
}
