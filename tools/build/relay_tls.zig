//! The relay transport family built on the vendored Mbed TLS dependency
//! (`mbedtls.zig`): the TLS engine layers, the installed relay C ABI archive,
//! and the site relay examples.

const std = @import("std");
const archives = @import("archives.zig");
const mbedtls = @import("mbedtls.zig");
const site_build = @import("site.zig");
const modules = @import("modules.zig");
const execution = @import("execution.zig");

pub fn engineModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dependency: mbedtls.Dependency,
    foundation: *std.Build.Module,
    net: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/net/tls/mbedtls.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
        // The relay archive is a C ABI deliverable linked by foreign toolchains.
        // Trap-mode keeps checked C arithmetic self-contained; full UBSan would
        // leave compiler-runtime symbols that only Zig consumers happen to add.
        .sanitize_c = .trap,
    });
    module.addImport("foundation", foundation);
    module.addImport("net", net);
    module.addImport("mbedtls_c", dependency.translatedHeaders(b, target, optimize));
    dependency.configureModule(b, module);
    return module;
}

fn probeEngineModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dependency: mbedtls.Dependency,
    foundation: *std.Build.Module,
    net: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/net/tls/mbedtls.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("foundation", foundation);
    module.addImport("net", net);
    module.addImport("mbedtls_c", dependency.translatedHeaders(b, target, optimize));
    dependency.configureProbeModule(b, module);
    return module;
}

pub fn tlsMbedtlsModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    net: *std.Build.Module,
    engine: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/net/tls/mbedtls_composition.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("net", net);
    module.addImport("mbedtls", engine);
    return module;
}

pub const Family = struct {
    tls: *std.Build.Module,
    relay: *std.Build.Module,
    check_relay: *std.Build.Module,
    secure_check: *std.Build.Step,
};

pub const RelayAbiModules = struct {
    production: *std.Build.Module,
    check: *std.Build.Module,
};

pub fn relayAbiModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    family: Family,
    foundation: *std.Build.Module,
    model: *std.Build.Module,
    net: *std.Build.Module,
    c_abi_shared: *std.Build.Module,
) RelayAbiModules {
    const production = relayAbiModule(
        b,
        target,
        optimize,
        foundation,
        model,
        net,
        c_abi_shared,
        family.relay,
    );
    const check = relayAbiModule(
        b,
        target,
        optimize,
        foundation,
        model,
        net,
        c_abi_shared,
        family.check_relay,
    );
    production.linkSystemLibrary("c", .{});
    check.linkSystemLibrary("c", .{});
    family.secure_check.dependOn(&b.addObject(.{
        .name = "secure-relay-c-abi-check",
        .root_module = production,
    }).step);
    return .{ .production = production, .check = check };
}

/// Install the relay archive with its compiler and TLS runtimes private on ELF.
pub fn installArchive(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    module: *std.Build.Module,
    version: std.SemanticVersion,
) archives.InstalledArchive {
    const archive = archives.installArchive(b, "glowcap_net_transport_relay", module, version);
    if (target.result.ofmt == .elf) {
        archive.dynamic.version_script = b.path("tools/build/exports/relay.map");
    }
    return archive;
}

/// Prove the installed archive shape that module-level tests cannot see: the
/// static archive links without a separately installed vendor library, while
/// the shared archive exports only Glowcap's relay family.
pub fn addArchiveChecks(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    secure_check: *std.Build.Step,
    static: *std.Build.Step.Compile,
    dynamic: *std.Build.Step.Compile,
) void {
    const consumer_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    consumer_module.addIncludePath(b.path("include"));
    consumer_module.addCSourceFile(.{
        .file = b.path("test/c_abi/relay_static_link_test.c"),
        .flags = &.{"-std=c11"},
    });
    const consumer = b.addExecutable(.{
        .name = "relay-static-link-test",
        .root_module = consumer_module,
    });
    consumer.root_module.linkLibrary(static);
    secure_check.dependOn(&execution.addArtifact(b, .{ .deterministic = 30 }, consumer).step);

    const symbols = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{"bash"});
    symbols.addFileArg(b.path("tools/check/relay-archive-symbols.sh"));
    symbols.addArtifactArg(dynamic);
    secure_check.dependOn(&symbols.step);
}

fn relayAbiModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    foundation: *std.Build.Module,
    model: *std.Build.Module,
    net: *std.Build.Module,
    c_abi_shared: *std.Build.Module,
    relay_tls: *std.Build.Module,
) *std.Build.Module {
    return modules.transportAbiModule(b, target, optimize, "src/c_abi/net_transport/relay/mod.zig", &.{
        .{ .name = "foundation", .module = foundation },
        .{ .name = "model", .module = model },
        .{ .name = "net", .module = net },
        .{ .name = "c_abi_shared", .module = c_abi_shared },
        .{ .name = "relay_tls", .module = relay_tls },
    });
}

pub const Modules = struct {
    dependency: mbedtls.Dependency,
    engine: *std.Build.Module,
    tls: *std.Build.Module,
    relay: *std.Build.Module,
};

/// The public relay and its TLS engine, with no test or live-probe setup.
pub fn addModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, foundation: *std.Build.Module, net: *std.Build.Module) Modules {
    const dependency = mbedtls.add(b);
    const engine = engineModule(b, target, optimize, dependency, foundation, net);
    const tls_mbedtls = tlsMbedtlsModule(b, target, optimize, net, engine);
    const relay_tls = b.addModule("glowcap_relay_tls", .{
        .root_source_file = b.path("src/net/transport/keyed_relay/wss_mbedtls.zig"),
        .target = target,
        .optimize = optimize,
    });
    relay_tls.addImport("foundation", foundation);
    relay_tls.addImport("net", net);
    relay_tls.addImport("tls_mbedtls", tls_mbedtls);
    return .{ .dependency = dependency, .engine = engine, .tls = tls_mbedtls, .relay = relay_tls };
}

pub fn addFamily(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    foundation: *std.Build.Module,
    net: *std.Build.Module,
) Family {
    const layers = addModule(b, target, optimize, foundation, net);
    const dependency = layers.dependency;
    const engine = layers.engine;
    const tls_mbedtls = layers.tls;
    const relay_tls = layers.relay;
    const check_tls = b.createModule(.{
        .root_source_file = b.path("test/support/tls_stub.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_tls.addImport("foundation", foundation);
    check_tls.addImport("net", net);
    const check_relay = b.createModule(.{
        .root_source_file = b.path("src/net/transport/keyed_relay/wss_mbedtls.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_relay.addImport("foundation", foundation);
    check_relay.addImport("net", net);
    check_relay.addImport("tls_mbedtls", check_tls);
    const test_module = b.createModule(.{
        .root_source_file = b.path("test/net/mbedtls_engine_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("mbedtls", engine);
    test_module.addImport("relay_tls", relay_tls);
    const tests = b.addTest(.{ .name = "relay-tls-test", .root_module = test_module });
    const probe_engine = probeEngineModule(b, target, optimize, dependency, foundation, net);
    const probe_tls = tlsMbedtlsModule(b, target, optimize, net, probe_engine);
    const probe_relay = b.createModule(.{
        .root_source_file = b.path("src/net/transport/keyed_relay/wss_mbedtls.zig"),
        .target = target,
        .optimize = optimize,
    });
    probe_relay.addImport("foundation", foundation);
    probe_relay.addImport("net", net);
    probe_relay.addImport("tls_mbedtls", probe_tls);
    const allocation_probe = b.createModule(.{
        .root_source_file = b.path("test/support/mbedtls_allocation_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    allocation_probe.addImport("allocation_probe_c", allocationProbeHeaders(b, target, optimize));
    allocation_probe.addIncludePath(b.path("test/support"));
    const live_module = b.createModule(.{
        .root_source_file = b.path("tools/check/relay_tls_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    live_module.addImport("foundation", foundation);
    live_module.addImport("net", net);
    live_module.addImport("relay_tls", probe_relay);
    live_module.addImport("tls_mbedtls", probe_tls);
    live_module.addImport("allocation_probe", allocation_probe);
    const live_client = b.addExecutable(.{
        .name = "relay-tls-client",
        .root_module = live_module,
    });
    const live = execution.addSystemCommand(b, .real_internet, &.{"bash"});
    live.addFileArg(b.path("tools/check/relay-tls-live.sh"));
    live.addArtifactArg(live_client);
    const secure_check = b.step("mbedtls-build", "Fetch by checksum, compile, and test Glowcap's private Mbed TLS engine (needs network)");
    secure_check.dependOn(&execution.addZigTest(b, tests, .unit_test).step);
    secure_check.dependOn(&live.step);
    return .{
        .tls = tls_mbedtls,
        .relay = relay_tls,
        .check_relay = check_relay,
        .secure_check = secure_check,
    };
}

/// Compile the relay Zig first-calls against the relay TLS module. They
/// stay out of the default glowcap snippet walk for the same reason iroh does:
/// Mbed TLS is an optional composition, not part of `lib_mod`.
pub fn addSiteRelayExamples(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
    relay_tls: *std.Build.Module,
    site_zig_examples_check: *std.Build.Step,
) void {
    const examples = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "site-example-dial-noise-relay", .path = "site/examples/dial/noise-relay.zig" },
        .{ .name = "site-example-dial-keyed-relay", .path = "site/examples/dial/keyed-relay.zig" },
        .{ .name = "site-example-listen-noise-relay", .path = "site/examples/listen/noise-relay.zig" },
    };
    for (examples) |example| {
        site_build.addSiteZigExampleCompile(b, target, optimize, example.name, example.path, &.{
            .{ .name = "glowcap", .module = lib_mod },
            .{ .name = "relay_tls", .module = relay_tls },
        }, site_zig_examples_check);
    }
}

fn allocationProbeHeaders(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("test/support/mbedtls_allocation_probe_import.c"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(b.path("test/support"));
    return translate.createModule();
}
