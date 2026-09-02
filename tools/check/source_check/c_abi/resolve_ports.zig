//! Every port of the C-ABI resolve cascade (ADR-0077), held to one rule set.

const std = @import("std");
const util = @import("../util.zig");
const shared = @import("shared.zig");

const appendViolation = util.appendViolation;
const parseJsonFile = util.parseJsonFile;
const getField = util.getField;
const jsonStringEquals = util.jsonStringEquals;
const containsIgnoringWhitespace = util.containsIgnoringWhitespace;

/// Every port of the resolve cascade — the four binding loaders, the racket
/// per-archive loaders, and the operator script — held to the same download,
/// checksum, and extract-hygiene rules, with the hostile extract matrix and
/// the shared host-alias fixture keeping the greps honest against fixtures
/// that actually execute.
pub fn checkCAbiResolvePorts(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const expected_operator_script = shared.operator_script;
    const binding_loaders = shared.c_abi_binding_loaders;

    // Shadow literals that must live only in the contract JSON (not loaders/script).
    const forbidden_shadows = [_][]const u8{
        "536870912",
        "536_870_912",
        "1048576",
        "glowcap-c-abi-fetch/",
        "glowcap-c-abi-cache",
        "glowcap-c-v{version}-{target}.tar.gz",
        "https://github.com/jimisaacs/glowcap/releases/download",
    };
    for (binding_loaders) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for c-abi-resolve check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "c-abi-resolve.json") == null) {
            try appendViolation(gpa, violations, "{s}: must load the package-shipped `c-abi-resolve.json` contract", .{path});
        }
        // Bindings must not depend on the monorepo operator script.
        if (std.mem.indexOf(u8, contents, "tools/c-abi/fetch-c-abi.sh") != null or
            std.mem.indexOf(u8, contents, "fetch-c-abi.sh") != null)
        {
            try appendViolation(gpa, violations, "{s}: must not shell out to `fetch-c-abi.sh` (ADR-0077: language-native download)", .{path});
        }
        if (std.mem.indexOf(u8, contents, "abi_version") == null and
            std.mem.indexOf(u8, contents, "GLOWCAP_VERSION_MAJOR") == null)
        {
            try appendViolation(gpa, violations, "{s}: must read contract `abi_version` or header macros", .{path});
        }
        if (std.mem.indexOf(u8, contents, "SHA256") == null and std.mem.indexOf(u8, contents, "checksum") == null) {
            try appendViolation(gpa, violations, "{s}: must require checksum verification before extract", .{path});
        }
        if (std.mem.indexOf(u8, contents, "max_sums_bytes") == null) {
            try appendViolation(gpa, violations, "{s}: must read contract `max_sums_bytes`", .{path});
        }
        if (std.mem.indexOf(u8, contents, "fallback_cache_name") == null) {
            try appendViolation(gpa, violations, "{s}: must read contract `fallback_cache_name`", .{path});
        }
        if (std.mem.indexOf(u8, contents, "cache_layout") == null) {
            try appendViolation(gpa, violations, "{s}: must read contract `cache_layout`", .{path});
        }
        if (std.mem.indexOf(u8, contents, "require_https") == null) {
            try appendViolation(gpa, violations, "{s}: must read contract `require_https`", .{path});
        }
        if (std.mem.indexOf(u8, contents, "releases_published") == null) {
            try appendViolation(gpa, violations, "{s}: must read contract `releases_published`", .{path});
        }
        if (std.mem.indexOf(u8, contents, "GLOWCAP_ALLOW_INSECURE") == null) {
            try appendViolation(gpa, violations, "{s}: must gate downloads with GLOWCAP_ALLOW_INSECURE escape (ADR-0077 §5)", .{path});
        }
        // Fixed env truthy set (not a contract field).
        if (std.mem.indexOf(u8, contents, "\"1\"") == null or
            std.mem.indexOf(u8, contents, "\"true\"") == null or
            std.mem.indexOf(u8, contents, "\"yes\"") == null)
        {
            try appendViolation(gpa, violations, "{s}: env truthy helper must accept \"1\", \"true\", and \"yes\"", .{path});
        }
        // Marker roles: Rust static-links `.a`; dynamic loaders open shared libs.
        if (std.mem.eql(u8, path, "bindings/rust/build.rs")) {
            if (std.mem.indexOf(u8, contents, "marker_static") == null) {
                try appendViolation(gpa, violations, "{s}: must read contract `marker_static` for cache hits", .{path});
            }
            if (std.mem.indexOf(u8, contents, "marker_shared_stem") != null) {
                try appendViolation(gpa, violations, "{s}: must not use `marker_shared_stem` (static link uses marker_static)", .{path});
            }
            // Cargo cfg already emits release-pack arch/os names (no host alias map).
            if (std.mem.indexOf(u8, contents, "CARGO_CFG_TARGET_ARCH") == null or
                std.mem.indexOf(u8, contents, "CARGO_CFG_TARGET_OS") == null)
            {
                try appendViolation(gpa, violations, "{s}: host target must come from CARGO_CFG_TARGET_ARCH/OS (matches release-pack)", .{path});
            }
        } else {
            if (std.mem.indexOf(u8, contents, "marker_shared_stem") == null) {
                try appendViolation(gpa, violations, "{s}: must read contract `marker_shared_stem` for cache hits", .{path});
            }
            if (std.mem.indexOf(u8, contents, "marker_static") != null) {
                try appendViolation(gpa, violations, "{s}: must not use `marker_static` for cache hits (dynamic load uses marker_shared_stem)", .{path});
            }
            // Host alias → release-pack triple (see tools/c-abi/c-abi-host-aliases.json).
            if (std.mem.indexOf(u8, contents, "amd64") == null and
                std.mem.indexOf(u8, contents, "x64") == null)
            {
                try appendViolation(gpa, violations, "{s}: must normalize amd64/x64 → x86_64 for release-pack targets", .{path});
            }
            if (std.mem.indexOf(u8, contents, "aarch64") == null and std.mem.indexOf(u8, contents, "arm64") == null) {
                try appendViolation(gpa, violations, "{s}: must normalize arm64/aarch64 for release-pack targets", .{path});
            }
            if (std.mem.indexOf(u8, contents, "darwin") == null and
                std.mem.indexOf(u8, contents, "Darwin") == null and
                std.mem.indexOf(u8, contents, "macosx") == null)
            {
                try appendViolation(gpa, violations, "{s}: must normalize darwin/macosx → macos for release-pack targets", .{path});
            }
            // ADR-0077: refuse bare DLL names on Windows (search-order plant risk).
            if (std.mem.indexOf(u8, contents, "Windows refuses bare DLL") == null) {
                try appendViolation(gpa, violations, "{s}: must refuse bare DLL names on Windows (ADR-0077)", .{path});
            }
        }
        // Extract hygiene (ADR-0077 §5): reject links/traversal before extract.
        if (std.mem.eql(u8, path, "bindings/python/glowcap/_lib_resolve.py")) {
            if (std.mem.indexOf(u8, contents, "issym") == null) {
                try appendViolation(gpa, violations, "{s}: must reject symlink/hardlink tar members (ADR-0077 §5)", .{path});
            }
        } else if (std.mem.eql(u8, path, "bindings/ts/runtime/internal/ffi/load.ts")) {
            if (std.mem.indexOf(u8, contents, "--no-same-owner") == null) {
                try appendViolation(gpa, violations, "{s}: tar extract must pass --no-same-owner (ADR-0077 §5)", .{path});
            }
            if (std.mem.indexOf(u8, contents, "archive_hygiene.ts") == null or
                std.mem.indexOf(u8, contents, "archiveListingViolation") == null)
            {
                try appendViolation(gpa, violations, "{s}: must validate tar listings through archive_hygiene.ts before extract (ADR-0077 §5)", .{path});
            }
            // The validator only parses the two C-locale listing layouts, so
            // the call site that runs `tar` owns forcing that locale, and it
            // owns clearing `TAR_OPTIONS`: flags that hide a member from the
            // listing and admit it at extract defeat the validator entirely.
            if (std.mem.indexOf(u8, contents, "LC_ALL") == null) {
                try appendViolation(gpa, violations, "{s}: must run `tar -tv` under LC_ALL=C so the listing matches the gated parser", .{path});
            }
            // The mechanism, not a comment naming it: a fresh env object for
            // both tar calls. Spreading `process.env` back in would re-open the
            // hole while any mention of TAR_OPTIONS still satisfied a grep.
            // Both tar calls, not one: sanitizing the listing and leaving the
            // extract inheriting (or the reverse) means the two see different
            // archives, which is the whole hole. Count the uses.
            //
            // The variable must be neutralized by name. Omitting it from a
            // fresh object is not enough: Deno's `spawnSync` merges the given
            // env with the parent's rather than replacing it, so an omitted
            // `TAR_OPTIONS` still reached tar. The matrix runs this exact
            // path under a hostile value, which is how that was found.
            if (std.mem.indexOf(u8, contents, "const tarEnv = {") == null or
                std.mem.indexOf(u8, contents, "...process.env") != null or
                std.mem.indexOf(u8, contents, "TAR_OPTIONS: \"\"") == null or
                std.mem.count(u8, contents, "env: tarEnv") < 2)
            {
                try appendViolation(gpa, violations, "{s}: both tar calls must pass one fresh `env: tarEnv` and must not spread `process.env` (ADR-0077 §5)", .{path});
            }
            if (std.mem.indexOf(u8, contents, "isDirectory") == null) {
                try appendViolation(gpa, violations, "{s}: extract success must require extract_prefix is a directory", .{path});
            }
            if (std.mem.indexOf(u8, contents, "corrupt or incomplete contract") == null and
                std.mem.indexOf(u8, contents, "throw err") == null)
            {
                try appendViolation(gpa, violations, "{s}: must not silently swallow a corrupt contract load", .{path});
            }
        } else {
            if (std.mem.indexOf(u8, contents, "--no-same-owner") == null) {
                try appendViolation(gpa, violations, "{s}: tar extract must pass --no-same-owner (ADR-0077 §5)", .{path});
            }
            const owns_or_imports_hygiene =
                (std.mem.eql(u8, path, "bindings/rust/build.rs") and
                    std.mem.indexOf(u8, contents, "mod archive_hygiene") != null and
                    std.mem.indexOf(u8, contents, "listing_violation") != null) or
                (std.mem.eql(u8, path, "bindings/racket/private/lib-resolve.rkt") and
                    std.mem.indexOf(u8, contents, "tar-listing-violation") != null);
            if (!owns_or_imports_hygiene) {
                try appendViolation(gpa, violations, "{s}: must own or import the gated tar-listing validator before extract (ADR-0077 §5)", .{path});
            }
            // Same contract as the TypeScript loader above.
            if (std.mem.indexOf(u8, contents, "LC_ALL") == null) {
                try appendViolation(gpa, violations, "{s}: must run `tar -tv` under LC_ALL=C so the listing matches the gated parser", .{path});
            }
            // Again the mechanism: the call that clears the variable, in the
            // spelling this port uses.
            // Once is not enough: the listing and the extract each need the
            // sanitized environment, or they see different archives. Rust
            // clears per command; Racket parameterizes one env over both, so
            // the parameterize is what must appear twice.
            const clears_both =
                std.mem.count(u8, contents, ".env_remove(\"TAR_OPTIONS\")") >= 2 or
                std.mem.count(u8, contents, "parameterize ([current-environment-variables env])") >= 2;
            if (!clears_both) {
                try appendViolation(gpa, violations, "{s}: both the listing and the extract must run under the sanitized environment (ADR-0077 §5)", .{path});
            }
            if (std.mem.indexOf(u8, contents, "--absolute-names") != null or
                std.mem.indexOf(u8, contents, " -P\n") != null or
                std.mem.indexOf(u8, contents, " -P ") != null)
            {
                try appendViolation(gpa, violations, "{s}: tar extract must not use -P/--absolute-names", .{path});
            }
        }
        if (std.mem.eql(u8, path, "bindings/rust/build.rs")) {
            if (std.mem.indexOf(u8, contents, "require_https must be true") == null) {
                try appendViolation(gpa, violations, "{s}: must hard-fail at load if require_https is not true", .{path});
            }
            if (std.mem.indexOf(u8, contents, "include_str!(\"c-abi-resolve.json\")") == null) {
                try appendViolation(gpa, violations, "{s}: must embed package-shipped c-abi-resolve.json via include_str!", .{path});
            }
            // The serde_json requirement above carries the no-hand-rolled-
            // scanner invariant; the retired `fn json_string_field` name ban
            // added nothing over it.
            if (std.mem.indexOf(u8, contents, "serde_json") == null) {
                try appendViolation(gpa, violations, "{s}: must parse c-abi-resolve.json with serde_json (no hand-rolled scanner)", .{path});
            }
        }
        if (std.mem.eql(u8, path, "bindings/racket/private/lib-resolve.rkt")) {
            if (std.mem.indexOf(u8, contents, "curl not on PATH") == null) {
                try appendViolation(gpa, violations, "{s}: must soft-fail when curl is missing (not silent skip)", .{path});
            }
            if (std.mem.indexOf(u8, contents, "find-dev-root") == null or
                std.mem.indexOf(u8, contents, "zig-out-lib") == null)
            {
                try appendViolation(gpa, violations, "{s}: must discover zig-out via find-dev-root (no caller-hardcoded zig-out path)", .{path});
            }
            if (std.mem.indexOf(u8, contents, "hard-fail!") == null) {
                try appendViolation(gpa, violations, "{s}: must define hard-fail! for hygiene/checksum/HTTPS (ADR-0077)", .{path});
            }
        }
        if (std.mem.eql(u8, path, "bindings/python/glowcap/_lib_resolve.py")) {
            if (std.mem.indexOf(u8, contents, "def _hard_fail") == null) {
                try appendViolation(gpa, violations, "{s}: must define _hard_fail for hygiene/checksum/HTTPS", .{path});
            }
        } else if (std.mem.eql(u8, path, "bindings/ts/runtime/internal/ffi/load.ts")) {
            const security_path = "bindings/ts/runtime/internal/ffi/release_security.ts";
            const security = root.readFileAlloc(io, security_path, gpa, .limited(64 << 10)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read release-security policy with {s}", .{ security_path, @errorName(err) });
                continue;
            };
            defer gpa.free(security);
            const policy_calls = [_][]const u8{
                "failArchiveSecurity(",
                "requireSecureReleaseUrl(base, envTruthy(\"GLOWCAP_ALLOW_INSECURE\"));",
                "curlTransportArgs(url, envTruthy(\"GLOWCAP_ALLOW_INSECURE\"))",
            };
            var policy_complete = std.mem.indexOf(u8, contents, "release_security.ts") != null;
            for (policy_calls) |call_shape| {
                policy_complete = policy_complete and
                    containsIgnoringWhitespace(contents, call_shape);
            }
            const policy_definitions = [_][]const u8{
                "function failArchiveSecurity(",
                "function requireSecureReleaseUrl(",
                "function curlTransportArgs(",
            };
            for (policy_definitions) |definition| {
                policy_complete = policy_complete and
                    containsIgnoringWhitespace(security, definition);
            }
            if (!policy_complete) {
                try appendViolation(gpa, violations, "{s}: must call every shared fail-closed release-security policy function", .{path});
            }
        } else if (std.mem.eql(u8, path, "bindings/rust/build.rs")) {
            if (std.mem.indexOf(u8, contents, "fn hard_fail") == null) {
                try appendViolation(gpa, violations, "{s}: must define hard_fail for hygiene/checksum/HTTPS", .{path});
            }
        }
        for (forbidden_shadows) |lit| {
            if (std.mem.indexOf(u8, contents, lit) != null) {
                try appendViolation(gpa, violations, "{s}: hardcoded `{s}` — read from c-abi-resolve.json only", .{ path, lit });
            }
        }
    }

    // Racket per-archive loaders must not hardcode monorepo zig-out paths.
    // The four eager archives open inside their generated tables; the lazy
    // iroh loader opens in its hand module.
    const racket_ffi_loaders = [_][]const u8{
        "bindings/racket/private/ffi-ocapn-gen.rkt",
        "bindings/racket/private/ffi-host-gen.rkt",
        "bindings/racket/private/ffi-tcp-gen.rkt",
        "bindings/racket/private/ffi-inproc-gen.rkt",
        "bindings/racket/private/ffi-iroh.rkt",
    };
    for (racket_ffi_loaders) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for zig-out path check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "define-runtime-path") != null and
            std.mem.indexOf(u8, contents, "zig-out") != null)
        {
            try appendViolation(gpa, violations, "{s}: must not hardcode zig-out via define-runtime-path; open-glowcap-archive discovers it", .{path});
        }
        if (std.mem.indexOf(u8, contents, "open-glowcap-archive") == null) {
            try appendViolation(gpa, violations, "{s}: must open archives through open-glowcap-archive", .{path});
        }
        // Automatic FFI out cells (`(_ptr o …)`) lose values under concurrent
        // Racket green threads. Archive loaders must wrap outs with caller-owned
        // cells; the literal token is banned so the race cannot return.
        if (std.mem.indexOf(u8, contents, "(_ptr o") != null) {
            try appendViolation(gpa, violations, "{s}: automatic FFI out cells banned — wrap outs with call/out or wrap-out1 (caller-owned cells)", .{path});
        }
    }

    const script = root.readFileAlloc(io, expected_operator_script, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ expected_operator_script, @errorName(err) });
        return;
    };
    defer gpa.free(script);
    if (std.mem.indexOf(u8, script, "version_header") == null) {
        try appendViolation(gpa, violations, "{s}: must read abi version header path from contract `version_header`", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "jq -r") == null) {
        try appendViolation(gpa, violations, "{s}: must read fields from c-abi-resolve.json via jq", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, ".marker_static") == null or
        std.mem.indexOf(u8, script, ".marker_shared_stem") == null)
    {
        try appendViolation(gpa, violations, "{s}: cache-hit markers must come from c-abi-resolve.json", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "SHA256SUMS") == null) {
        try appendViolation(gpa, violations, "{s}: must attempt SHA256SUMS verification", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "checksum required") == null) {
        try appendViolation(gpa, violations, "{s}: must require checksum before extract", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "--no-same-owner") == null) {
        try appendViolation(gpa, violations, "{s}: must extract with --no-same-owner", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "archive-hygiene.sh") == null or
        std.mem.indexOf(u8, script, "archive_hygiene_check") == null)
    {
        try appendViolation(gpa, violations, "{s}: must source the gated archive-hygiene owner before extract (ADR-0077 §5)", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "TAR_OPTIONS=") == null) {
        try appendViolation(gpa, violations, "{s}: must clear TAR_OPTIONS on the extract, so it runs in the environment its listing was validated under (ADR-0077 §5)", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "hard_fail") == null) {
        try appendViolation(gpa, violations, "{s}: must define hard_fail for hygiene/checksum/HTTPS (ADR-0077)", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "operator") == null and std.mem.indexOf(u8, script, "Operator") == null) {
        try appendViolation(gpa, violations, "{s}: must document that it is an operator/CI tool, not a binding dependency", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "releases_published") == null) {
        try appendViolation(gpa, violations, "{s}: must honor contract `releases_published`", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, ".require_https") == null or
        std.mem.indexOf(u8, script, ".require_checksum") == null)
    {
        try appendViolation(gpa, violations, "{s}: must jq-enforce require_https and require_checksum", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "1 | true | yes") == null and
        (std.mem.indexOf(u8, script, "\"1\"") == null or
            std.mem.indexOf(u8, script, "true") == null or
            std.mem.indexOf(u8, script, "yes") == null))
    {
        try appendViolation(gpa, violations, "{s}: env truthy helper must accept 1/true/yes", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "amd64") == null) {
        try appendViolation(gpa, violations, "{s}: must normalize amd64 → x86_64 for release-pack targets", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "arm64") == null and std.mem.indexOf(u8, script, "aarch64") == null) {
        try appendViolation(gpa, violations, "{s}: must normalize arm64/aarch64 for release-pack targets", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "Darwin") == null and std.mem.indexOf(u8, script, "darwin") == null) {
        try appendViolation(gpa, violations, "{s}: must normalize Darwin → macos for release-pack targets", .{expected_operator_script});
    }
    for (forbidden_shadows) |lit| {
        if (std.mem.indexOf(u8, script, lit) != null) {
            try appendViolation(gpa, violations, "{s}: hardcoded `{s}` — read from c-abi-resolve.json only", .{ expected_operator_script, lit });
        }
    }

    // Shared host-target alias fixture: every listed alias must appear in
    // EACH non-cargo normalizer (per-port honesty — not a union corpus).
    // Rust uses CARGO_CFG_* and is skipped; operator script is included.
    const host_aliases_fixture = "tools/c-abi/c-abi-host-aliases.json";
    var aliases_parsed = try parseJsonFile(io, gpa, root, violations, host_aliases_fixture) orelse return;
    defer aliases_parsed.deinit();
    const alias_ports = shared.c_abi_binding_loaders[1..] ++ [_][]const u8{expected_operator_script};
    if (getField(aliases_parsed.value, "host_aliases")) |aliases_val| {
        switch (aliases_val) {
            .object => |obj| {
                for (alias_ports) |path| {
                    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                        try appendViolation(gpa, violations, "{s}: failed to read for host-alias check with {s}", .{ path, @errorName(err) });
                        continue;
                    };
                    defer gpa.free(contents);
                    var it = obj.iterator();
                    while (it.next()) |entry| {
                        switch (entry.value_ptr.*) {
                            .array => |arr| {
                                for (arr.items) |item| {
                                    const alias = switch (item) {
                                        .string => |s| s,
                                        else => continue,
                                    };
                                    if (std.mem.indexOf(u8, contents, alias) == null) {
                                        try appendViolation(gpa, violations, "{s}: host alias `{s}` missing from {s}", .{ host_aliases_fixture, alias, path });
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                }
            },
            else => try appendViolation(gpa, violations, "{s}: `host_aliases` must be an object", .{host_aliases_fixture}),
        }
    } else {
        try appendViolation(gpa, violations, "{s}: missing `host_aliases`", .{host_aliases_fixture});
    }
    if (getField(aliases_parsed.value, "release_pack_names")) |rpn| {
        switch (rpn) {
            .object => |obj| {
                if (obj.get("oses")) |oses| {
                    switch (oses) {
                        .array => |arr| {
                            for (arr.items) |item| {
                                const os_name = switch (item) {
                                    .string => |s| s,
                                    else => continue,
                                };
                                if (std.mem.eql(u8, os_name, "windows")) {
                                    try appendViolation(gpa, violations, "{s}: release_pack_names.oses must not list windows until release.yml has a Windows leg", .{host_aliases_fixture});
                                }
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    // Extract matrix apex: hostile fixtures must execute the same validators
    // the production ports import, not reassuring source-string greps.
    const extract_matrix = "tools/c-abi/c-abi-extract-matrix.sh";
    const matrix = root.readFileAlloc(io, extract_matrix, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ extract_matrix, @errorName(err) });
        return;
    };
    defer gpa.free(matrix);
    for ([_][]const u8{
        "archive-hygiene.sh",
        "archive_hygiene.ts",
        "rust-archive-hygiene-check.rs",
        "racket-archive-hygiene-check.rkt",
        "adversarial",
        "slip.tar.gz",
        "link.tar.gz",
        // The hostile fixtures each stand for a defect that reached this
        // tree: an owner field shaped like a date, a member name carrying
        // tar's own link separator, and a member that is neither file,
        // directory, nor link. Dropping one silently un-tests its fix.
        "arrow",
        "mkfifo",
        "dotslash",
        "TAR_OPTIONS",
        "python",
        "deno",
    }) |needle| {
        if (std.mem.indexOf(u8, matrix, needle) == null) {
            try appendViolation(gpa, violations, "{s}: must exercise `{s}` in the hermetic extract matrix", .{ extract_matrix, needle });
        }
    }
    // Every port that decides which archive members may be extracted. All of
    // them refuse a member that is not a regular file or a directory. One
    // property varies: four parse `tar -tv` text and so owe a fail-closed
    // verdict on a layout they cannot read, while the Python port reads tar
    // headers through `tarfile` and has no listing text to misread.
    //
    // The C locale is checked where tar is actually invoked, not here: for
    // the shell port that is this same file, and for the other three it is
    // the importer, covered by the binding-loader rows above.
    const HygieneOwner = struct {
        path: []const u8,
        parses_listing: bool = true,
    };
    const hygiene_owners = [_]HygieneOwner{
        .{ .path = "tools/c-abi/archive-hygiene.sh" },
        .{ .path = "bindings/racket/private/lib-resolve.rkt" },
        .{ .path = "bindings/ts/runtime/internal/ffi/archive_hygiene.ts" },
        .{ .path = "bindings/rust/archive_hygiene.rs" },
        .{ .path = "bindings/python/glowcap/_lib_resolve.py", .parses_listing = false },
    };
    for (hygiene_owners) |owner_spec| {
        const path = owner_spec.path;
        const owner = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read tar-listing hygiene owner with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(owner);
        if (owner_spec.parses_listing and
            std.mem.indexOf(u8, owner, "unrecognized tar listing format") == null)
        {
            try appendViolation(gpa, violations, "{s}: tar-listing owner must fail closed on a layout it cannot parse", .{path});
        }
        if (std.mem.indexOf(u8, owner, "refusing non-file tar member") == null) {
            try appendViolation(gpa, violations, "{s}: must refuse a member that is not a regular file or a directory", .{path});
        }
        // The shell port is the one owner that both parses the listing and
        // runs the tar producing it; the other three are parsers whose
        // importer owns the invocation.
        if (std.mem.eql(u8, path, "tools/c-abi/archive-hygiene.sh") and
            std.mem.indexOf(u8, owner, "LC_ALL") == null)
        {
            try appendViolation(gpa, violations, "{s}: must run `tar -tv` under LC_ALL=C so the listing matches its own parser", .{path});
        }
        // The shell port's listing and its extract live in different files, so
        // the sanitized environment has to be required in both. Only the
        // listing side is exercised by the matrix fixture.
        if (std.mem.eql(u8, path, "tools/c-abi/archive-hygiene.sh") and
            std.mem.indexOf(u8, owner, "TAR_OPTIONS=") == null)
        {
            try appendViolation(gpa, violations, "{s}: must clear TAR_OPTIONS on the listing (ADR-0077 §5)", .{path});
        }
    }
    const binding_docs = root.readFileAlloc(io, "bindings/PACKAGING.md", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "bindings/PACKAGING.md: failed to read for ADR-0077 archive resolution with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(binding_docs);
    if (std.mem.indexOf(u8, binding_docs, "ADR-0077") == null or
        std.mem.indexOf(u8, binding_docs, "c-abi-resolve.json") == null)
    {
        try appendViolation(gpa, violations, "bindings/PACKAGING.md: must name ADR-0077 and c-abi-resolve.json as the archive-resolution contract", .{});
    }
}
