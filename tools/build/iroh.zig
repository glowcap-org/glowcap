//! The iroh companion archive's module and installed public C ABI.

const std = @import("std");
const common = @import("common.zig");
const execution = @import("execution.zig");
const profile_build = @import("profile.zig");
const addRootedSystemCommand = common.addRootedSystemCommand;
const addInstalledSystemRun = common.addInstalledSystemRun;
const irohDriverModule = common.irohDriverModule;
const linkIrohSidecar = common.linkIrohSidecar;
const AbiImport = common.AbiImport;
const root_build = @import("../../build.zig");
const gen_build = @import("gen.zig");
const irohAbiModule = gen_build.irohAbiModule;
const layerIndex = root_build.layerIndex;

pub fn abiModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    model_mod: *std.Build.Module,
    net_mod: *std.Build.Module,
    c_abi_shared_mod: *std.Build.Module,
    resident_mod: *std.Build.Module,
) *std.Build.Module {
    return common.transportAbiModule(b, target, optimize, "src/c_abi/net_transport/iroh/mod.zig", &.{
        .{ .name = "model", .module = model_mod },
        .{ .name = "net", .module = net_mod },
        .{ .name = "iroh", .module = resident_mod },
        .{ .name = "c_abi_shared", .module = c_abi_shared_mod },
    });
}

pub const AbiContext = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    version: std.SemanticVersion,
    model_mod: *std.Build.Module,
    net_mod: *std.Build.Module,
    c_abi_shared_mod: *std.Build.Module,
    resident_mod: *std.Build.Module,
    sidecar_archive: std.Build.LazyPath,
};

pub const AbiRegistration = struct {
    install: *std.Build.Step,
    step: *std.Build.Step,
};

/// Build the public frame-level companion around the private Rust byte-level
/// sidecar. The ELF map is a correctness boundary: leaking the sidecar's Rust
/// runtime can interpose on a Rust consumer's own panic runtime.
pub fn registerAbi(ctx: AbiContext) AbiRegistration {
    const b = ctx.b;
    const link_mod = abiModule(
        b,
        ctx.target,
        ctx.optimize,
        ctx.model_mod,
        ctx.net_mod,
        ctx.c_abi_shared_mod,
        ctx.resident_mod,
    );
    common.linkIrohSidecar(b, link_mod, ctx.target, ctx.sidecar_archive);
    const shared = b.addLibrary(.{
        .name = "glowcap_net_transport_iroh",
        .linkage = .dynamic,
        .root_module = link_mod,
        .version = ctx.version,
    });
    common.configureSharedArchive(shared);
    if (ctx.target.result.os.tag == .macos) {
        shared.install_name = b.fmt("@rpath/libglowcap_net_transport_iroh.{d}.dylib", .{ctx.version.major});
    }
    if (ctx.target.result.ofmt == .elf) {
        shared.version_script = b.path("tools/build/exports/iroh.map");
    }

    const install = common.installIfChanged(b, shared, common.install_lib_dir);
    common.checkArchiveTls(b, shared, install);
    common.checkArchiveResident(b, shared, install);
    const header = b.addInstallHeaderFile(
        b.path("include/glowcap_net_transport_iroh.h"),
        "glowcap_net_transport_iroh.h",
    );
    const step = b.step("iroh-abi", "Build libglowcap_net_transport_iroh, the iroh transport's public C ABI companion (needs cargo)");
    step.dependOn(install);
    step.dependOn(&header.step);

    if (ctx.target.result.ofmt == .elf) {
        const export_check = common.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{ "bash", "tools/check/sidecar-exports.sh" });
        export_check.addFileArg(shared.getEmittedBin());
        export_check.addArg("glowcap_iroh_");
        export_check.addArg("glowcap_iroh_sidecar_");
        step.dependOn(&export_check.step);
    }
    return .{ .install = install, .step = step };
}

/// The whole iroh family above the ABI companion: the sidecar's cargo
/// steps, the injected resident with its hermetic check object, the live
/// driver table, the ADR-0024 seam proof, the site snippet compiles and the
/// locator suite that ride the site's Zig example check, the companion
/// registration, and its deno-driven ABI test.
pub const StepsContext = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    abi_version: std.SemanticVersion,
    lib_mod: *std.Build.Module,
    host_mods: []*std.Build.Module,
    host_abi_mod: *std.Build.Module,
    driver_abi_mod: *std.Build.Module,
    interop_harness_mod: *std.Build.Module,
    check_step: *std.Build.Step,
    site_zig_examples_check: *std.Build.Step,
    profiles: profile_build.Profiles,
};

pub const StepsRegistration = struct {
    resident_mod: *std.Build.Module,
    /// The cargo-built sidecar staticlib as a build-graph path: link it and
    /// the cargo step runs first.
    sidecar_archive: std.Build.LazyPath,
    abi_step: *std.Build.Step,
    abi_test_step: *std.Build.Step,
};

/// The iroh resident (`src/net/transport/iroh.zig`) over one layer graph:
/// the host graph for every gate, the profiled graph for `profile-iroh`.
fn residentModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, mods: []*std.Build.Module) *std.Build.Module {
    const mod = b.createModule(.{ .root_source_file = b.path("src/net/transport/iroh.zig"), .target = target, .optimize = optimize });
    inline for (.{ "foundation", "model", "engine", "net" }) |layer| mod.addImport(layer, mods[layerIndex(layer)]);
    return mod;
}

/// Publish the resident with its Cargo-built sidecar. Repository checks use
/// a separate unlinked resident so compile-only gates do not invoke Cargo.
pub fn addModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, mods: []*std.Build.Module, archive: std.Build.LazyPath) void {
    const published_iroh_mod = b.addModule("glowcap_iroh", .{
        .root_source_file = b.path("src/net/transport/iroh.zig"),
        .target = target,
        .optimize = optimize,
    });
    published_iroh_mod.addImport("foundation", mods[layerIndex("foundation")]);
    published_iroh_mod.addImport("model", mods[layerIndex("model")]);
    published_iroh_mod.addImport("engine", mods[layerIndex("engine")]);
    published_iroh_mod.addImport("net", mods[layerIndex("net")]);
    linkIrohSidecar(b, published_iroh_mod, target, archive);
}

pub fn registerSteps(ctx: StepsContext) StepsRegistration {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const abi_version = ctx.abi_version;
    const lib_mod = ctx.lib_mod;
    const host_mods = ctx.host_mods;
    const host_abi_mod = ctx.host_abi_mod;
    const driver_abi_mod = ctx.driver_abi_mod;
    const interop_harness_mod = ctx.interop_harness_mod;
    const check_step = ctx.check_step;

    // ── iroh netlayer (external siblings, plus hermetic Zig checks) ─────────
    const sidecar = common.rustSidecar(b, "transports/iroh/Cargo.toml", "glowcap_iroh_sidecar");
    addModule(b, target, optimize, host_mods, sidecar.archive);
    const iroh_lib = sidecar.build;
    const sidecar_archive = sidecar.archive;
    const iroh_lib_step = b.step("iroh-lib", "Build the iroh netlayer sidecar staticlib (needs cargo)");
    iroh_lib_step.dependOn(&iroh_lib.step);

    // The sidecar's own Rust unit tests, chief among them the positive-fire proof
    // that a caller-set connect timeout trips fast against a bound-but-silent UDP
    // black hole. Needs cargo, so it is a sibling step like `iroh-lib`.
    const iroh_sidecar_test = addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{
        "cargo", "test", "--locked", "--release", "--manifest-path", "transports/iroh/Cargo.toml",
    });
    const iroh_sidecar_test_compile = addRootedSystemCommand(b, .build_tool, &.{
        "cargo", "test", "--locked", "--no-run", "--release", "--manifest-path", "transports/iroh/Cargo.toml",
    });
    iroh_sidecar_test.step.dependOn(&iroh_sidecar_test_compile.step);
    const iroh_sidecar_test_step = b.step("iroh-sidecar-test", "Run the iroh sidecar Rust unit tests, including the connect-timeout positive-fire proof (needs cargo)");
    iroh_sidecar_test_step.dependOn(&iroh_sidecar_test.step);

    // The resident compiles as its own module over the same layer-module
    // instances, *outside* the `glowcap` root namespace: its externs resolve
    // only when the staticlib links, and the api-surface test references every
    // exported `glowcap` declaration recursively, exporting it would drag the
    // Rust sidecar into every gate.
    const iroh_resident_mod = residentModule(b, target, optimize, host_mods);
    // CapTP serving is `driver.HostRuntime` over `iroh.MultiplexedAdapter`;
    // the resident only supplies the netlayer and the completion `Backend`.

    for ([_][]const u8{ "dial", "listen" }) |role| {
        common.addSiteZigExampleCompile(b, target, optimize, b.fmt("site-{s}-iroh", .{role}), b.fmt("site/examples/{s}/iroh.zig", .{role}), &.{ .{ .name = "glowcap", .module = lib_mod }, .{ .name = "iroh", .module = iroh_resident_mod } }, ctx.site_zig_examples_check);
    }

    // The iroh driver family, table-driven. Each row is both a runnable sibling
    // of `check` (linking the sidecar through `linkIrohSidecar`, so it needs
    // cargo) and a hermetic compile-only object that rides `check`: *compiling*
    // a driver's Zig is cargo-free because externs stay unresolved and nothing
    // links, so a core or model API change cannot silently rot a driver only the
    // cargo-gated steps run. Per-row posture:
    //   iroh-interop: live encrypted conversation, two glowcap peers over real
    //                   iroh endpoints, dialed by id with direct-address hints.
    //   iroh-reachability: dial by node id alone over n0's public
    //                   relays and DNS/pkarr discovery, no hints. Touches public
    //                   discovery infrastructure with propagation timing, so it
    //                   is opt-in and never a hermetic gate.
    //   iroh-loop: many concurrent connections
    //                   served from one thread through the event-driven sidecar
    //                   superset (ADR-0019). Deterministic.
    //   iroh-redeem: three glowcap Servers and Sessions over iroh: a recipient
    //                   redeems a handoff by dialing the exporter. Deterministic.
    //   goblins-iroh: a foreign protocol partner: a real Spritely
    //                   Goblins vat over the iroh netlayer this repository wrote
    //                   for it, both directions. Needs racket + goblins as well
    //                   as cargo, as does goblins-handoff-iroh below.
    //   bench-iroh: round-trip latency/throughput over real keyed QUIC vs a
    //                   same-machine cleartext TCP baseline; reports numbers,
    //                   gates none, and forwards `-- <args>`. `bench-site-report`
    //                   runs it to refresh the performance pages.
    const iroh_abi = registerAbi(.{
        .b = b,
        .target = target,
        .optimize = optimize,
        .version = abi_version,
        .model_mod = host_mods[layerIndex("model")],
        .net_mod = host_mods[layerIndex("net")],
        .c_abi_shared_mod = host_mods[layerIndex("c_abi_shared")],
        .resident_mod = iroh_resident_mod,
        .sidecar_archive = sidecar_archive,
    });

    var managed_step: ?*std.Build.Step = null;
    const iroh_drivers = [_]struct {
        step_name: []const u8,
        description: []const u8,
        exe_name: []const u8,
        root_source: []const u8,
        forwards_args: bool = false,
        posture: execution.Posture,
        goblins: bool = false,
    }{
        .{ .step_name = "iroh-managed", .description = "Zig Session and Server over real iroh: identity, fetch, call and accepted-session lifetime (needs cargo)", .exe_name = "glowcap-iroh-managed", .root_source = "test/driver/iroh_managed.zig", .posture = .{ .deterministic = 20 } },
        .{ .step_name = "iroh-interop", .description = "Live encrypted OCapN conversation: two glowcap peers over real iroh endpoints (needs cargo)", .exe_name = "glowcap-iroh-interop", .root_source = "interop/iroh_interop/driver.zig", .posture = .{ .deterministic = 20 } },
        .{ .step_name = "iroh-reachability", .description = "Live real-internet dial-by-id over n0 relays + DNS/pkarr discovery (opt-in; needs cargo + internet)", .exe_name = "glowcap-iroh-reachability", .root_source = "interop/iroh_reachability/driver.zig", .posture = .real_internet },
        .{ .step_name = "iroh-loop", .description = "Live iroh scale: many concurrent connections served from one Server thread (ADR-0019, needs cargo)", .exe_name = "glowcap-iroh-loop", .root_source = "interop/iroh_loop/driver.zig", .posture = .{ .deterministic = 20 } },
        .{ .step_name = "iroh-redeem", .description = "Live three-party redeem over iroh: a recipient Session dials the exporter by node id inside the introducing call (needs cargo)", .exe_name = "glowcap-iroh-redeem", .root_source = "interop/iroh_redeem/driver.zig", .posture = .{ .deterministic = 20 } },
        .{ .step_name = "goblins-iroh", .description = "Live Goblins over iroh: a real Goblins vat and a glowcap peer hold OCapN sessions over encrypted QUIC, both directions, through the iroh netlayer this repository wrote for Goblins (needs cargo + racket + goblins)", .exe_name = "glowcap-goblins-iroh", .root_source = "interop/goblins_interop/iroh_driver.zig", .posture = .{ .deterministic = 25 }, .goblins = true },
        .{ .step_name = "goblins-handoff-iroh", .description = "Live encrypted handoff: Goblins gifts and exports, a glowcap Session redeems directly over iroh (needs cargo + racket + goblins)", .exe_name = "glowcap-goblins-handoff-iroh", .root_source = "interop/goblins_interop/handoff_iroh_driver.zig", .posture = .{ .deterministic = 30 }, .goblins = true },
        .{ .step_name = "bench-iroh", .description = "Measure OCapN round-trip latency/throughput over iroh vs a TCP baseline (needs cargo)", .exe_name = "glowcap-iroh-bench", .root_source = "bench/iroh_bench.zig", .forwards_args = true, .posture = .benchmark },
    };
    for (iroh_drivers) |drv| {
        // Hermetic compile-only object (no sidecar), rides `check`.
        const compile_mod = irohDriverModule(b, target, optimize, lib_mod, iroh_resident_mod, drv.root_source);
        compile_mod.addImport("interop_harness", interop_harness_mod);
        const compile_obj = b.addObject(.{ .name = b.fmt("{s}-compile", .{drv.exe_name}), .root_module = compile_mod });
        check_step.dependOn(&compile_obj.step);

        // Runnable sibling of `check`: links the sidecar and runs from the root.
        const run_mod = irohDriverModule(b, target, optimize, lib_mod, iroh_resident_mod, drv.root_source);
        run_mod.addImport("interop_harness", interop_harness_mod);
        linkIrohSidecar(b, run_mod, target, sidecar_archive);
        const exe = b.addExecutable(.{ .name = drv.exe_name, .root_module = run_mod });
        const live_step = b.step(drv.step_name, drv.description);
        if (std.mem.eql(u8, drv.step_name, "iroh-managed")) managed_step = live_step;
        const run = execution.addArtifact(b, drv.posture, exe);
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        // The Racket netlayer loads the public companion and, through the
        // Racket binding, the installed host archives, as well as the Zig
        // driver's private sidecar; none may rely on a previous build.
        if (drv.goblins) {
            run.step.dependOn(iroh_abi.step);
            run.step.dependOn(b.getInstallStep());
        }
        if (drv.forwards_args) run.addPassthruArgs();
        live_step.dependOn(&run.step);
    }

    // bench-iroh under callgrind: the driver wire path over the profiled
    // graph, with the iroh resident built for the same baseline target so the
    // one executable links. Each timed loop is a phase named like its report
    // row, so `-- --transport=tcp --row=greet` attributes one row alone.
    const profiles = ctx.profiles;
    const profiled_resident = residentModule(b, profiles.target, profile_build.Profiles.optimize, profiles.mods);
    const profiled_mod = b.createModule(profiles.moduleOptions(b, "bench/iroh_bench.zig"));
    profiled_mod.addImport("glowcap", profiles.module("glowcap"));
    profiled_mod.addImport("iroh", profiled_resident);
    linkIrohSidecar(b, profiled_mod, profiles.target, sidecar_archive);
    const profiled = b.addExecutable(.{ .name = "glowcap-iroh-bench-profile", .root_module = profiled_mod });
    b.step("profile-iroh", "Profile bench-iroh under callgrind: self cost per file and function for each marked phase, taking bench-iroh's filters after -- (needs cargo + valgrind)").dependOn(profile_build.addRun(b, profiles, profiled));

    // ── ADR-0024 seam proof: the driver archive drives iroh through the C
    // multiplexed-transport table. Bespoke wiring rather than an `iroh_drivers` row,
    // because the driver composes the C archives (`c_abi_driver` carrying the
    // whole host family, plus the iroh C ABI) beside the Zig server half; the
    // module instances are shared with the archives so every export lands in
    // the executable exactly once.
    {
        const seam_source = "interop/iroh_driver_provider/driver.zig";
        const seam_imports = [_]AbiImport{
            .{ .name = "glowcap", .module = lib_mod },
            .{ .name = "iroh", .module = iroh_resident_mod },
            .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            .{ .name = "c_abi_host", .module = host_abi_mod },
            .{ .name = "c_abi_driver", .module = driver_abi_mod },
        };

        // Hermetic compile-only object (no sidecar), rides `check`.
        const seam_compile_mod = b.createModule(.{
            .root_source_file = b.path(seam_source),
            .target = target,
            .optimize = optimize,
        });
        for (seam_imports) |imp| seam_compile_mod.addImport(imp.name, imp.module);
        seam_compile_mod.addImport("interop_harness", interop_harness_mod);
        seam_compile_mod.addImport("c_abi_net_transport_iroh", irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod));
        const seam_compile = b.addObject(.{ .name = "glowcap-iroh-driver-provider-compile", .root_module = seam_compile_mod });
        check_step.dependOn(&seam_compile.step);

        // Runnable sibling of `check`: links the sidecar and runs from the root.
        const seam_run_mod = b.createModule(.{
            .root_source_file = b.path(seam_source),
            .target = target,
            .optimize = optimize,
        });
        for (seam_imports) |imp| seam_run_mod.addImport(imp.name, imp.module);
        seam_run_mod.addImport("interop_harness", interop_harness_mod);
        seam_run_mod.addImport("c_abi_net_transport_iroh", irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod));
        linkIrohSidecar(b, seam_run_mod, target, sidecar_archive);
        const seam_exe = b.addExecutable(.{ .name = "glowcap-iroh-driver-provider", .root_module = seam_run_mod });
        const seam_run = execution.addArtifact(b, .{ .deterministic = 30 }, seam_exe);
        seam_run.setCwd(b.path("."));
        seam_run.has_side_effects = true;
        const provider_step = b.step("iroh-driver-provider", "Live proof (ADR-0024) that the driver archive dials a real iroh endpoint through the C multiplexed-transport table (needs cargo)");
        provider_step.dependOn(&seam_run.step);
        provider_step.dependOn(managed_step.?);
    }

    // Hermetic type-check of the resident: compile it to an object, where its
    // externs need no definition, so plain `zig build check` catches resident
    // rot without cargo on PATH. Linking and running stay in `iroh-interop`.
    const iroh_resident_check = b.addObject(.{
        .name = "iroh-resident-check",
        .root_module = iroh_resident_mod,
    });
    check_step.dependOn(&iroh_resident_check.step);

    const iroh_locator_test_mod = b.createModule(.{
        .root_source_file = b.path("test/net/iroh_locator_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    iroh_locator_test_mod.addImport("iroh", iroh_resident_mod);
    iroh_locator_test_mod.addImport("model", host_mods[layerIndex("model")]);
    iroh_locator_test_mod.addImport("iroh_sidecar_stub", b.createModule(.{
        .root_source_file = b.path("tools/gen/stub/iroh_sidecar.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const iroh_locator_test = b.addTest(.{
        .name = "iroh-locator",
        .root_module = iroh_locator_test_mod,
    });
    const run_iroh_locator_test = execution.addZigTest(b, iroh_locator_test, .unit_test);
    ctx.site_zig_examples_check.dependOn(&run_iroh_locator_test.step);

    // Internal resident evidence links a scripted sidecar directly. It imports
    // only the supported facade, so no test-only leaf is re-exported through
    // the consumer namespace.
    const iroh_resident_internal_mod = b.createModule(.{
        .root_source_file = b.path("test/net/iroh_resident_internal_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    iroh_resident_internal_mod.addImport("foundation", host_mods[layerIndex("foundation")]);
    iroh_resident_internal_mod.addImport("model", host_mods[layerIndex("model")]);
    iroh_resident_internal_mod.addImport("engine", host_mods[layerIndex("engine")]);
    iroh_resident_internal_mod.addImport("net", host_mods[layerIndex("net")]);
    iroh_resident_internal_mod.addImport("iroh", iroh_resident_mod);
    iroh_resident_internal_mod.addImport("c_abi_shared", host_mods[layerIndex("c_abi_shared")]);
    iroh_resident_internal_mod.addImport("c_abi_net_transport_iroh", irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod));
    const iroh_resident_internal_test = b.addTest(.{
        .name = "iroh-resident-internal-test",
        .root_module = iroh_resident_internal_mod,
    });
    const run_iroh_resident_internal_test = execution.addZigTest(b, iroh_resident_internal_test, .unit_test);
    check_step.dependOn(&run_iroh_resident_internal_test.step);
    ctx.site_zig_examples_check.dependOn(&run_iroh_resident_internal_test.step);

    // The ABI-layout proof imports the internal owner directly in a separate
    // build-only test graph. It neither re-exports the leaf through the iroh
    // facade nor loads the same source file under two module identities.
    const iroh_sidecar_owner_mod = b.createModule(.{
        .root_source_file = b.path("src/net/transport/iroh/sidecar.zig"),
        .target = target,
        .optimize = optimize,
    });
    iroh_sidecar_owner_mod.addImport("foundation", host_mods[layerIndex("foundation")]);
    const iroh_sidecar_internal_test_mod = b.createModule(.{
        .root_source_file = b.path("test/net/iroh_sidecar_internal_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    iroh_sidecar_internal_test_mod.addImport("iroh_sidecar_internal", iroh_sidecar_owner_mod);
    const iroh_sidecar_internal_test = b.addTest(.{
        .name = "iroh-sidecar-internal-test",
        .root_module = iroh_sidecar_internal_test_mod,
    });
    const run_iroh_sidecar_internal_test = execution.addZigTest(b, iroh_sidecar_internal_test, .unit_test);
    check_step.dependOn(&run_iroh_sidecar_internal_test.step);
    ctx.site_zig_examples_check.dependOn(&run_iroh_sidecar_internal_test.step);

    const iroh_abi_install = iroh_abi.install;
    const iroh_abi_step = iroh_abi.step;

    const iroh_constructor_diagnostic = addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{
        "deno",                                                 "test", "--allow-ffi", "--allow-read", "--allow-env", "--unstable-ffi",
        "bindings/ts/iroh/test/constructor_diagnostic_test.ts",
    });
    iroh_constructor_diagnostic.step.dependOn(iroh_abi_install);
    iroh_constructor_diagnostic.step.dependOn(b.getInstallStep());
    iroh_constructor_diagnostic.setEnvironmentVariable(
        "GLOWCAP_LIB_DIR",
        common.rootPath(b, "zig-out/lib"),
    );

    const iroh_driver_listener = addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{
        "deno",                                          "test", "--allow-ffi", "--allow-read", "--allow-env", "--allow-net", "--unstable-ffi",
        "bindings/ts/iroh/test/driver_listener_test.ts",
    });
    iroh_driver_listener.step.dependOn(iroh_abi_install);
    iroh_driver_listener.step.dependOn(b.getInstallStep());
    iroh_driver_listener.setEnvironmentVariable(
        "GLOWCAP_LIB_DIR",
        common.rootPath(b, "zig-out/lib"),
    );

    const iroh_abi_test_step = b.step("iroh-abi-test", "Test the iroh C ABI and generic-driver listener adoption (needs cargo + deno)");
    iroh_abi_test_step.dependOn(&iroh_constructor_diagnostic.step);
    iroh_abi_test_step.dependOn(&iroh_driver_listener.step);

    return .{
        .resident_mod = iroh_resident_mod,
        .sidecar_archive = sidecar_archive,
        .abi_step = iroh_abi_step,
        .abi_test_step = iroh_abi_test_step,
    };
}
