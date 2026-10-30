const std = @import("std");
const common = @import("common.zig");
const execution = @import("execution.zig");

const tls_sources = [_][]const u8{
    "library/debug.c",
    "library/error.c",
    "library/mbedtls_config.c",
    "library/mps_reader.c",
    "library/mps_trace.c",
    "library/ssl_ciphersuites.c",
    "library/ssl_client.c",
    "library/ssl_debug_helpers_generated.c",
    "library/ssl_msg.c",
    "library/ssl_tls.c",
    "library/ssl_tls12_client.c",
    "library/ssl_tls13_client.c",
    "library/ssl_tls13_generic.c",
    "library/ssl_tls13_keys.c",
    "library/version.c",
    "library/version_features.c",
    "library/x509.c",
    "library/x509_crl.c",
    "library/x509_crt.c",
    "library/x509_oid.c",
};

const crypto_core_sources = [_][]const u8{
    "tf-psa-crypto/core/psa_crypto.c",
    "tf-psa-crypto/core/psa_crypto_client.c",
    "tf-psa-crypto/core/psa_crypto_driver_wrappers_no_static.c",
    "tf-psa-crypto/core/psa_crypto_random.c",
    "tf-psa-crypto/core/psa_crypto_slot_management.c",
    "tf-psa-crypto/core/psa_crypto_storage.c",
    "tf-psa-crypto/core/psa_its_file.c",
    "tf-psa-crypto/core/psa_util.c",
    "tf-psa-crypto/core/tf_psa_crypto_config.c",
    "tf-psa-crypto/core/tf_psa_crypto_version.c",
};

const crypto_support_sources = [_][]const u8{
    "tf-psa-crypto/extras/lmots.c",
    "tf-psa-crypto/extras/lms.c",
    "tf-psa-crypto/extras/md.c",
    "tf-psa-crypto/extras/nist_kw.c",
    "tf-psa-crypto/extras/pk.c",
    "tf-psa-crypto/extras/pk_ecc.c",
    "tf-psa-crypto/extras/pk_rsa.c",
    "tf-psa-crypto/extras/pk_wrap.c",
    "tf-psa-crypto/extras/pkparse.c",
    "tf-psa-crypto/extras/pkwrite.c",
    "tf-psa-crypto/platform/memory_buffer_alloc.c",
    "tf-psa-crypto/platform/platform.c",
    "tf-psa-crypto/platform/platform_util.c",
    "tf-psa-crypto/platform/threading.c",
    "tf-psa-crypto/utilities/asn1parse.c",
    "tf-psa-crypto/utilities/asn1write.c",
    "tf-psa-crypto/utilities/base64.c",
    "tf-psa-crypto/utilities/constant_time.c",
    "tf-psa-crypto/utilities/oid.c",
    "tf-psa-crypto/utilities/pem.c",
    "tf-psa-crypto/utilities/pkcs5.c",
};

const crypto_builtin_sources = [_][]const u8{
    "tf-psa-crypto/drivers/builtin/src/aes.c",
    "tf-psa-crypto/drivers/builtin/src/aesce.c",
    "tf-psa-crypto/drivers/builtin/src/aesni.c",
    "tf-psa-crypto/drivers/builtin/src/aria.c",
    "tf-psa-crypto/drivers/builtin/src/bignum.c",
    "tf-psa-crypto/drivers/builtin/src/bignum_core.c",
    "tf-psa-crypto/drivers/builtin/src/bignum_mod.c",
    "tf-psa-crypto/drivers/builtin/src/bignum_mod_raw.c",
    "tf-psa-crypto/drivers/builtin/src/block_cipher.c",
    "tf-psa-crypto/drivers/builtin/src/camellia.c",
    "tf-psa-crypto/drivers/builtin/src/ccm.c",
    "tf-psa-crypto/drivers/builtin/src/chacha20.c",
    "tf-psa-crypto/drivers/builtin/src/chacha20_neon.c",
    "tf-psa-crypto/drivers/builtin/src/chachapoly.c",
    "tf-psa-crypto/drivers/builtin/src/cipher.c",
    "tf-psa-crypto/drivers/builtin/src/cipher_wrap.c",
    "tf-psa-crypto/drivers/builtin/src/cmac.c",
    "tf-psa-crypto/drivers/builtin/src/ctr_drbg.c",
    "tf-psa-crypto/drivers/builtin/src/ecdsa.c",
    "tf-psa-crypto/drivers/builtin/src/ecjpake.c",
    "tf-psa-crypto/drivers/builtin/src/ecp.c",
    "tf-psa-crypto/drivers/builtin/src/ecp_curves.c",
    "tf-psa-crypto/drivers/builtin/src/entropy.c",
    "tf-psa-crypto/drivers/builtin/src/entropy_poll.c",
    "tf-psa-crypto/drivers/builtin/src/gcm.c",
    "tf-psa-crypto/drivers/builtin/src/hmac_drbg.c",
    "tf-psa-crypto/drivers/builtin/src/md5.c",
    "tf-psa-crypto/drivers/builtin/src/poly1305.c",
    "tf-psa-crypto/drivers/builtin/src/psa_crypto_aead.c",
    "tf-psa-crypto/drivers/builtin/src/psa_crypto_cipher.c",
    "tf-psa-crypto/drivers/builtin/src/psa_crypto_ecp.c",
    "tf-psa-crypto/drivers/builtin/src/psa_crypto_ffdh.c",
    "tf-psa-crypto/drivers/builtin/src/psa_crypto_hash.c",
    "tf-psa-crypto/drivers/builtin/src/psa_crypto_mac.c",
    "tf-psa-crypto/drivers/builtin/src/psa_crypto_pake.c",
    "tf-psa-crypto/drivers/builtin/src/psa_crypto_rsa.c",
    "tf-psa-crypto/drivers/builtin/src/psa_crypto_xof.c",
    "tf-psa-crypto/drivers/builtin/src/psa_util_internal.c",
    "tf-psa-crypto/drivers/builtin/src/ripemd160.c",
    "tf-psa-crypto/drivers/builtin/src/rsa.c",
    "tf-psa-crypto/drivers/builtin/src/rsa_alt_helpers.c",
    "tf-psa-crypto/drivers/builtin/src/sha1.c",
    "tf-psa-crypto/drivers/builtin/src/sha256.c",
    "tf-psa-crypto/drivers/builtin/src/sha3.c",
    "tf-psa-crypto/drivers/builtin/src/sha512.c",
};

const crypto_accelerator_sources = [_][]const u8{
    "tf-psa-crypto/drivers/everest/library/x25519.c",
    "tf-psa-crypto/drivers/everest/library/Hacl_Curve25519_joined.c",
    "tf-psa-crypto/drivers/p256-m/p256-m_driver_entrypoints.c",
    "tf-psa-crypto/drivers/p256-m/p256-m/p256-m.c",
};

/// Build Glowcap's private, pinned Mbed TLS engine dependency. This function is
/// called unconditionally so the named step exists, but its source acquisition
/// remains lazy until a consumer depends on the returned compile step.
pub const Dependency = struct {
    source: std.Build.LazyPath,

    pub fn configureModule(self: Dependency, b: *std.Build, module: *std.Build.Module) void {
        addIncludes(b, self.source, module);
        addSources(module, self.source, false);
    }

    fn configureProbeModule(self: Dependency, b: *std.Build, module: *std.Build.Module) void {
        addIncludes(b, self.source, module);
        addSources(module, self.source, true);
        module.addCSourceFile(.{
            .file = b.path("test/support/mbedtls_allocation_probe.c"),
            .flags = &.{"-std=c11"},
        });
    }

    fn translatedHeaders(
        self: Dependency,
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    ) *std.Build.Module {
        const translate = b.addTranslateC(.{
            .root_source_file = b.path("src/net/tls/mbedtls_import.c"),
            .target = target,
            .optimize = optimize,
        });
        addIncludes(b, self.source, translate);
        translate.defineCMacro("MBEDTLS_CONFIG_FILE", "\"glowcap_mbedtls_config.h\"");
        translate.defineCMacro("TF_PSA_CRYPTO_CONFIG_FILE", "\"glowcap_psa_crypto_config.h\"");
        return translate.createModule();
    }
};

pub fn engineModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dependency: Dependency,
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
    dependency: Dependency,
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
) common.InstalledArchive {
    const archive = common.installArchive(b, "glowcap_net_transport_relay", module, version);
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
    return common.transportAbiModule(b, target, optimize, "src/c_abi/net_transport/relay/mod.zig", &.{
        .{ .name = "foundation", .module = foundation },
        .{ .name = "model", .module = model },
        .{ .name = "net", .module = net },
        .{ .name = "c_abi_shared", .module = c_abi_shared },
        .{ .name = "relay_tls", .module = relay_tls },
    });
}

pub const Modules = struct {
    dependency: Dependency,
    engine: *std.Build.Module,
    tls: *std.Build.Module,
    relay: *std.Build.Module,
};

/// The public relay and its TLS engine, with no test or live-probe setup.
pub fn addModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, foundation: *std.Build.Module, net: *std.Build.Module) Modules {
    const dependency = add(b);
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
    const modules = addModule(b, target, optimize, foundation, net);
    const dependency = modules.dependency;
    const engine = modules.engine;
    const tls_mbedtls = modules.tls;
    const relay_tls = modules.relay;
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
    const secure_check = b.step("relay-tls-build", "Fetch by checksum, compile, and test Glowcap's private Mbed TLS engine (needs network)");
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
        common.addSiteZigExampleCompile(b, target, optimize, example.name, example.path, &.{
            .{ .name = "glowcap", .module = lib_mod },
            .{ .name = "relay_tls", .module = relay_tls },
        }, site_zig_examples_check);
    }
}

fn addIncludes(b: *std.Build, source: std.Build.LazyPath, module: anytype) void {
    inline for (.{
        "include",
        "library",
        "tf-psa-crypto/include",
        "tf-psa-crypto/core",
        "tf-psa-crypto/dispatch",
        "tf-psa-crypto/extras",
        "tf-psa-crypto/platform",
        "tf-psa-crypto/utilities",
        "tf-psa-crypto/drivers/builtin/include",
        "tf-psa-crypto/drivers/builtin/src",
        "tf-psa-crypto/drivers/everest/include",
        "tf-psa-crypto/drivers/everest/include/tf-psa-crypto/private/everest",
        "tf-psa-crypto/drivers/everest/include/tf-psa-crypto/private/everest/kremlib",
        "tf-psa-crypto/drivers/p256-m",
        "tf-psa-crypto/drivers/p256-m/p256-m",
    }) |path| module.addIncludePath(source.path(b, path));
    module.addIncludePath(b.path("src/net/tls"));
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

pub fn add(b: *std.Build) Dependency {
    const fetch = execution.addSystemCommand(b, .build_tool, &.{"bash"});
    fetch.addFileArg(b.path("tools/deps/fetch-mbedtls.sh"));
    // The fetch script is the single version-and-checksum authority. Keeping
    // the build-cache label version-neutral prevents an update from requiring
    // a second, mechanically coupled pin edit here.
    const source = fetch.addOutputDirectoryArg("mbedtls-source");
    return .{ .source = source };
}

fn addSources(
    module: *std.Build.Module,
    source: std.Build.LazyPath,
    allocation_probe: bool,
) void {
    const production_flags: []const []const u8 = &.{
        "-std=c11",
        "-fvisibility=hidden",
        "-DMBEDTLS_CONFIG_FILE=\"glowcap_mbedtls_config.h\"",
        "-DTF_PSA_CRYPTO_CONFIG_FILE=\"glowcap_psa_crypto_config.h\"",
    };
    const probe_flags: []const []const u8 = &.{
        "-std=c11",
        "-fvisibility=hidden",
        "-DMBEDTLS_CONFIG_FILE=\"glowcap_mbedtls_config.h\"",
        "-DTF_PSA_CRYPTO_CONFIG_FILE=\"glowcap_psa_crypto_config.h\"",
        "-DGLOWCAP_MBEDTLS_ALLOCATION_PROBE=1",
    };
    const flags = if (allocation_probe) probe_flags else production_flags;
    module.addCSourceFiles(.{ .root = source, .files = &tls_sources, .flags = flags });
    module.addCSourceFiles(.{ .root = source, .files = &crypto_core_sources, .flags = flags });
    module.addCSourceFiles(.{ .root = source, .files = &crypto_support_sources, .flags = flags });
    module.addCSourceFiles(.{ .root = source, .files = &crypto_builtin_sources, .flags = flags });
    module.addCSourceFiles(.{ .root = source, .files = &crypto_accelerator_sources, .flags = flags });
}
