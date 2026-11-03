//! The vendored Mbed TLS dependency: its pinned source fetch, include paths,
//! and compiled source inventory. `relay_tls.zig` builds the relay on it.

const std = @import("std");
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

    pub fn configureProbeModule(self: Dependency, b: *std.Build, module: *std.Build.Module) void {
        addIncludes(b, self.source, module);
        addSources(module, self.source, true);
        module.addCSourceFile(.{
            .file = b.path("test/support/mbedtls_allocation_probe.c"),
            .flags = &.{"-std=c11"},
        });
    }

    pub fn translatedHeaders(
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
