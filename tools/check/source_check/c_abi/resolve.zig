//! The C-ABI find/download contract (ADR-0077): the canonical
//! `c-abi-resolve.json`'s shape, the version pin against the generated
//! header, the byte-identical package copies, the packaging documentation,
//! the separation between tagged publication and consumer availability, and
//! the package-ship surfaces that make the contract reachable from every
//! published package.

const std = @import("std");
const util = @import("../util.zig");
const shared = @import("shared.zig");

const appendViolation = util.appendViolation;
const parseJsonFile = util.parseJsonFile;
const getField = util.getField;
const jsonStringEquals = util.jsonStringEquals;

pub fn checkCAbiResolve(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const contract_path = shared.contract_path;
    var parsed = try parseJsonFile(io, gpa, root, violations, contract_path) orelse return;
    defer parsed.deinit();

    const expected_tarball = shared.tarball_template;
    const expected_operator_script = shared.operator_script;

    const abi_version = blk: {
        const v = getField(parsed.value, "abi_version") orelse {
            try appendViolation(gpa, violations, "{s}: missing `abi_version`", .{contract_path});
            break :blk null;
        };
        break :blk switch (v) {
            .string => |s| s,
            else => {
                try appendViolation(gpa, violations, "{s}: `abi_version` must be a string", .{contract_path});
                break :blk null;
            },
        };
    };

    if (getField(parsed.value, "tarball_template")) |v| {
        if (!jsonStringEquals(v, expected_tarball)) {
            try appendViolation(gpa, violations, "{s}: `tarball_template` must be `{s}` (matches zig build release-pack)", .{ contract_path, expected_tarball });
        }
    } else {
        try appendViolation(gpa, violations, "{s}: missing `tarball_template`", .{contract_path});
    }
    if (getField(parsed.value, "operator_fetch_script") != null) {
        try appendViolation(gpa, violations, "{s}: unpaid `operator_fetch_script` — delete it; tools/c-abi/fetch-c-abi.sh is hard-coded for operators", .{contract_path});
    }
    if (getField(parsed.value, "contract_path") != null) {
        try appendViolation(gpa, violations, "{s}: unpaid `contract_path` — delete it; packages must not ship monorepo paths", .{contract_path});
    }
    if (getField(parsed.value, "require_https")) |v| {
        if (v != .bool or v.bool != true) {
            try appendViolation(gpa, violations, "{s}: `require_https` must be true", .{contract_path});
        }
    } else {
        try appendViolation(gpa, violations, "{s}: missing `require_https`", .{contract_path});
    }
    if (getField(parsed.value, "require_checksum")) |v| {
        if (v != .bool or v.bool != true) {
            try appendViolation(gpa, violations, "{s}: `require_checksum` must be true", .{contract_path});
        }
    } else {
        try appendViolation(gpa, violations, "{s}: missing `require_checksum`", .{contract_path});
    }
    // Prerelease valve for hosted C archives (may be true after first publish).
    if (getField(parsed.value, "releases_published")) |v| {
        if (v != .bool) {
            try appendViolation(gpa, violations, "{s}: `releases_published` must be a bool", .{contract_path});
        }
    } else {
        try appendViolation(gpa, violations, "{s}: missing `releases_published`", .{contract_path});
    }
    if (getField(parsed.value, "extract_prefix")) |v| {
        if (!jsonStringEquals(v, "lib")) {
            try appendViolation(gpa, violations, "{s}: `extract_prefix` must be `lib`", .{contract_path});
        }
    } else {
        try appendViolation(gpa, violations, "{s}: missing `extract_prefix`", .{contract_path});
    }
    const required_strings = [_][]const u8{
        "default_release_base_url",
        "release_tag_template",
        "cache_layout",
        "version_header",
        "user_agent",
        "fallback_cache_name",
        "marker_static",
        "marker_shared_stem",
    };
    for (required_strings) |key| {
        const v = getField(parsed.value, key) orelse {
            try appendViolation(gpa, violations, "{s}: missing `{s}`", .{ contract_path, key });
            continue;
        };
        if (v != .string) {
            try appendViolation(gpa, violations, "{s}: `{s}` must be a string", .{ contract_path, key });
        }
    }
    for ([_][]const u8{ "max_tarball_bytes", "max_sums_bytes" }) |key| {
        const v = getField(parsed.value, key) orelse {
            try appendViolation(gpa, violations, "{s}: missing `{s}`", .{ contract_path, key });
            continue;
        };
        if (v != .integer) {
            try appendViolation(gpa, violations, "{s}: `{s}` must be an integer", .{ contract_path, key });
        }
    }
    if (getField(parsed.value, "cache_layout")) |v| {
        if (!jsonStringEquals(v, "{cache_base}/{version}/{target}/lib")) {
            try appendViolation(gpa, violations, "{s}: `cache_layout` must be `{{cache_base}}/{{version}}/{{target}}/lib`", .{contract_path});
        }
    }
    // Each package ships its own copy of the contract (packages must not
    // reach for monorepo paths), so the copies must stay byte-identical to
    // the root — a divergent copy ships a different download cascade.
    const package_copies = [_][]const u8{
        "bindings/rust/c-abi-resolve.json",
        "bindings/python/glowcap/c-abi-resolve.json",
        "bindings/ts/runtime/internal/ffi/c-abi-resolve.json",
        "bindings/racket/private/c-abi-resolve.json",
    };
    {
        const canonical = root.readFileAlloc(io, contract_path, gpa, .limited(1 << 20)) catch null;
        defer if (canonical) |bytes| gpa.free(bytes);
        if (canonical) |canonical_bytes| {
            for (package_copies) |copy_path| {
                const copy = root.readFileAlloc(io, copy_path, gpa, .limited(1 << 20)) catch {
                    try appendViolation(gpa, violations, "{s}: missing package copy of `{s}`", .{ copy_path, contract_path });
                    continue;
                };
                defer gpa.free(copy);
                if (!std.mem.eql(u8, canonical_bytes, copy)) {
                    try appendViolation(gpa, violations, "{s}: differs from `{s}` — the shipped cascade must be byte-identical to the root contract", .{ copy_path, contract_path });
                }
            }
        }
    }

    // Frozen env truthy set lives in each loader helper, not the contract.
    if (getField(parsed.value, "truthy") != null) {
        try appendViolation(gpa, violations, "{s}: unpaid `truthy` field — delete it; loaders hardcode 1/true/yes", .{contract_path});
    }
    // Env name list is documentation in README; unpaid if shipped as JSON.
    if (getField(parsed.value, "env") != null) {
        try appendViolation(gpa, violations, "{s}: unpaid `env` field — delete it; document env names in bindings/PACKAGING.md", .{contract_path});
    }

    // Header macros must match the contract pin; user_agent embeds the same version.
    if (abi_version) |want| {
        const header = root.readFileAlloc(io, "include/glowcap_ocapn.h", gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "include/glowcap_ocapn.h: failed to read for c-abi-resolve check with {s}", .{@errorName(err)});
            return;
        };
        defer gpa.free(header);
        const major = headerMacroU32(header, "GLOWCAP_VERSION_MAJOR") orelse 0;
        const minor = headerMacroU32(header, "GLOWCAP_VERSION_MINOR") orelse 0;
        const patch = headerMacroU32(header, "GLOWCAP_VERSION_PATCH") orelse 0;
        var buf: [32]u8 = undefined;
        const got = std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{ major, minor, patch }) catch unreachable;
        if (!std.mem.eql(u8, got, want)) {
            try appendViolation(gpa, violations, "{s}: `abi_version` `{s}` must match include/glowcap_ocapn.h `{s}`", .{ contract_path, want, got });
        }
        if (getField(parsed.value, "user_agent")) |ua| {
            switch (ua) {
                .string => |s| {
                    if (std.mem.indexOf(u8, s, want) == null) {
                        try appendViolation(gpa, violations, "{s}: `user_agent` must embed `abi_version` `{s}`", .{ contract_path, want });
                    }
                },
                else => {},
            }
        }
    }

    // Package copies must be byte-identical to the canonical contract.
    if (getField(parsed.value, "package_copies")) |copies_val| {
        switch (copies_val) {
            .array => |arr| {
                const canonical = root.readFileAlloc(io, contract_path, gpa, .limited(1 << 20)) catch |err| {
                    try appendViolation(gpa, violations, "{s}: failed to re-read for copy check with {s}", .{ contract_path, @errorName(err) });
                    return;
                };
                defer gpa.free(canonical);
                for (arr.items) |item| {
                    const copy_path = switch (item) {
                        .string => |s| s,
                        else => {
                            try appendViolation(gpa, violations, "{s}: `package_copies` entries must be strings", .{contract_path});
                            continue;
                        },
                    };
                    const copy = root.readFileAlloc(io, copy_path, gpa, .limited(1 << 20)) catch |err| {
                        try appendViolation(gpa, violations, "{s}: package copy missing ({s})", .{ copy_path, @errorName(err) });
                        continue;
                    };
                    defer gpa.free(copy);
                    if (!std.mem.eql(u8, copy, canonical)) {
                        try appendViolation(gpa, violations, "{s}: drifts from {s}; copy the canonical contract into the package", .{ copy_path, contract_path });
                    }
                }
            },
            else => try appendViolation(gpa, violations, "{s}: `package_copies` must be an array", .{contract_path}),
        }
    } else {
        try appendViolation(gpa, violations, "{s}: missing `package_copies`", .{contract_path});
    }

    root.access(io, expected_operator_script, .{}) catch |err| {
        try appendViolation(gpa, violations, "{s}: missing operator fetch script ({s})", .{ expected_operator_script, @errorName(err) });
    };

    const readme = root.readFileAlloc(io, "bindings/PACKAGING.md", gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "bindings/PACKAGING.md: failed to read for c-abi-resolve check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(readme);
    if (std.mem.indexOf(u8, readme, "c-abi-resolve.json") == null) {
        try appendViolation(gpa, violations, "bindings/PACKAGING.md: Finding the archives must name `c-abi-resolve.json`", .{});
    }
    if (std.mem.indexOf(u8, readme, "ADR-0077") == null) {
        try appendViolation(gpa, violations, "bindings/PACKAGING.md: Finding the archives must cite ADR-0077", .{});
    }
    if (std.mem.indexOf(u8, readme, "GLOWCAP_STRICT") == null) {
        try appendViolation(gpa, violations, "bindings/PACKAGING.md: Finding the archives must document `GLOWCAP_STRICT`", .{});
    }
    if (std.mem.indexOf(u8, readme, "releases_published") == null) {
        try appendViolation(gpa, violations, "bindings/PACKAGING.md: Finding the archives must document `releases_published`", .{});
    }
    if (std.mem.indexOf(u8, readme, "PROVENANCE.md") == null) {
        try appendViolation(gpa, violations, "bindings/PACKAGING.md: release contents must document the packaged `PROVENANCE.md` disclosure", .{});
    }
    if (std.mem.indexOf(u8, readme, "GLOWCAP_DOWNLOAD") == null) {
        try appendViolation(gpa, violations, "bindings/PACKAGING.md: Finding the archives must document `GLOWCAP_DOWNLOAD`", .{});
    }

    if (std.mem.indexOf(u8, readme, "c-abi-host-aliases") == null and
        std.mem.indexOf(u8, readme, "CARGO_CFG_TARGET") == null)
    {
        try appendViolation(gpa, violations, "bindings/PACKAGING.md: must document release-pack target triples / cargo cfg posture", .{});
    }

    // A successful exact-SHA version tag authorizes archive publication.
    // `releases_published` is a later consumer-availability decision; using it
    // here would deadlock the first release because the flag cannot truthfully
    // turn on until the assets exist.
    const release_workflow = ".github/workflows/release.yml";
    const workflow = root.readFileAlloc(io, release_workflow, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ release_workflow, @errorName(err) });
        return;
    };
    defer gpa.free(workflow);
    if (std.mem.indexOf(u8, workflow, "releases_published") != null) {
        try appendViolation(gpa, violations, "{s}: `releases_published` governs consumer downloads, not tagged archive publication", .{release_workflow});
    }
    if (std.mem.indexOf(u8, workflow, "gh release create") == null) {
        try appendViolation(gpa, violations, "{s}: must still contain `gh release create` for the tag path", .{release_workflow});
    }
    if (std.mem.indexOf(u8, workflow, "expected_tag=\"v$(jq -r '.abi_version' bindings/c-abi-resolve.json)\"") == null or
        std.mem.indexOf(u8, workflow, "GITHUB_REF_NAME\" != \"$expected_tag") == null)
    {
        try appendViolation(gpa, violations, "{s}: tag publication must require `v<abi_version>` from bindings/c-abi-resolve.json", .{release_workflow});
    }
    if (std.mem.indexOf(u8, workflow, "macos-15-intel") == null or
        std.mem.indexOf(u8, workflow, "macos-13") != null)
    {
        try appendViolation(gpa, violations, "{s}: x86_64-macos archives require the supported `macos-15-intel` runner", .{release_workflow});
    }
    if (std.mem.indexOf(u8, workflow, "workflow_dispatch") == null) {
        try appendViolation(gpa, violations, "{s}: must offer workflow_dispatch for dry-run archive builds", .{release_workflow});
    }
    if (std.mem.indexOf(u8, workflow, "zig build -Doptimize=ReleaseSafe release-pack") == null) {
        try appendViolation(gpa, violations, "{s}: release archives must be built explicitly in ReleaseSafe mode", .{release_workflow});
    }
    if (std.mem.indexOf(u8, workflow, "actions: read") == null) {
        try appendViolation(gpa, violations, "{s}: tag publication must be able to read Actions check evidence", .{release_workflow});
    }
    if (std.mem.indexOf(u8, workflow, "actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6") == null or
        std.mem.indexOf(u8, workflow, "attestations: write") == null or
        std.mem.indexOf(u8, workflow, "id-token: write") == null or
        std.mem.indexOf(u8, workflow, "artifact-metadata: write") == null or
        std.mem.indexOf(u8, workflow, "release-assets/*.tar.gz") == null or
        std.mem.indexOf(u8, workflow, "release-assets/SHA256SUMS") == null)
    {
        try appendViolation(gpa, violations, "{s}: published archives and SHA256SUMS must receive GitHub artifact attestations", .{release_workflow});
    }
    if (std.mem.indexOf(u8, workflow, "PROVENANCE.md") == null or
        std.mem.indexOf(u8, workflow, "artifact attestation") == null or
        std.mem.indexOf(u8, workflow, "verify build provenance") != null)
    {
        try appendViolation(gpa, violations, "{s}: release notes must link the authorship disclosure separately from the artifact attestation", .{release_workflow});
    }

    const release_build_path = "tools/build/release.zig";
    const release_front = root.readFileAlloc(io, release_build_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ release_build_path, @errorName(err) });
        return;
    };
    defer gpa.free(release_front);
    const release_stage = try root.readFileAlloc(io, "tools/build/release/stage.zig", gpa, .limited(1 << 20));
    defer gpa.free(release_stage);
    const release_build = try std.mem.concat(gpa, u8, &.{ release_front, release_stage });
    defer gpa.free(release_build);
    if (std.mem.indexOf(u8, release_build, "cp -aL zig-out/lib") != null or
        std.mem.indexOf(u8, release_build, "zig-out/lib zig-out/include") != null)
    {
        try appendViolation(gpa, violations, "{s}: release staging must not copy the shared install directories; dirty and cross-target artifacts would enter the bundle", .{release_build_path});
    }
    for ([_][]const u8{
        "pub const Manifest = struct",
        "static_archives: []const []const u8",
        "dynamic_archives: []const []const u8",
        "missing static archive",
        "missing shared-library member",
        "stage must contain only regular files and directories",
        "cp PROVENANCE.md",
        "release packages refuse Debug",
        "tools/check/release-pack-smoke.sh",
    }) |marker| {
        if (std.mem.indexOf(u8, release_build, marker) == null) {
            try appendViolation(gpa, violations, "{s}: target-isolated release staging requires `{s}`", .{ release_build_path, marker });
        }
    }

    const release_smoke_path = "tools/check/release-pack-smoke.sh";
    const release_smoke = root.readFileAlloc(io, release_smoke_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ release_smoke_path, @errorName(err) });
        return;
    };
    defer gpa.free(release_smoke);
    for ([_][]const u8{
        "sha256sum -c SHA256SUMS",
        "glowcap_abi_version",
        "glowcap_ocapn_archive_fingerprint",
        "glowcap_host_archive_fingerprint",
        "glowcap_driver_archive_fingerprint",
        "glowcap_%s_archive_fingerprint",
        "static manifest omits libglowcap_ocapn",
        "shared manifest omits libglowcap_ocapn",
        "repo_root=",
        ". \"$repo_root/tools/c-abi/archive-hygiene.sh\"",
        "archive_hygiene_check",
        "TAR_OPTIONS=",
        "--no-same-owner",
        "cmp -s \"$repo_root/PROVENANCE.md\" \"$workdir/PROVENANCE.md\"",
        "write_consumer \"$workdir/static-$name-consumer.c\" \"$name\"",
        "shared-consumer",
    }) |marker| {
        if (std.mem.indexOf(u8, release_smoke, marker) == null) {
            try appendViolation(gpa, violations, "{s}: extracted release consumer proof requires `{s}`", .{ release_smoke_path, marker });
        }
    }

    const stability_path = "docs/stability.md";
    const stability = root.readFileAlloc(io, stability_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read extracted-consumer evidence with {s}", .{ stability_path, @errorName(err) });
        return;
    };
    defer gpa.free(stability);
    if (std.mem.indexOf(u8, stability, "`release-pack` also safely extracts its tarball off-tree") == null or
        std.mem.indexOf(u8, stability, "independent C consumer for each self-contained static archive") == null or
        std.mem.indexOf(u8, stability, "There is no independent C consumer") != null)
    {
        try appendViolation(gpa, violations, "{s}: C ABI evidence must state the extracted static/shared consumer proof rather than the retired no-consumer limitation", .{stability_path});
    }

    const root_build_path = "build.zig";
    const root_build = root.readFileAlloc(io, root_build_path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for release-manifest authority with {s}", .{ root_build_path, @errorName(err) });
        return;
    };
    defer gpa.free(root_build);
    for ([_][]const u8{
        "release_install: bool = true",
        ".static_archives = release_static_archives.items",
        ".dynamic_archives = release_dynamic_archives.items",
        ".headers = release_headers.items",
    }) |marker| {
        if (std.mem.indexOf(u8, root_build, marker) == null) {
            try appendViolation(gpa, violations, "{s}: archive_table must drive the release manifest through `{s}`", .{ root_build_path, marker });
        }
    }

    // Package-ship surfaces: contract must be reachable from published packages.
    const pyproject = root.readFileAlloc(io, "bindings/python/pyproject.toml", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "bindings/python/pyproject.toml: failed to read with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(pyproject);
    if (std.mem.indexOf(u8, pyproject, "c-abi-resolve.json") == null) {
        try appendViolation(gpa, violations, "bindings/python/pyproject.toml: package-data must ship c-abi-resolve.json", .{});
    }
    const deno_json = root.readFileAlloc(io, "bindings/ts/runtime/deno.json", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "bindings/ts/runtime/deno.json: failed to read with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(deno_json);
    if (std.mem.indexOf(u8, deno_json, "c-abi-resolve.json") == null or
        std.mem.indexOf(u8, deno_json, "\"publish\"") == null)
    {
        try appendViolation(gpa, violations, "bindings/ts/runtime/deno.json: publish.include must ship c-abi-resolve.json", .{});
    }
    const racket_info = root.readFileAlloc(io, "bindings/racket/info.rkt", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "bindings/racket/info.rkt: failed to read with {s} (package-ship surface)", .{@errorName(err)});
        return;
    };
    defer gpa.free(racket_info);
    if (std.mem.indexOf(u8, racket_info, "private/c-abi-resolve.json") == null) {
        try appendViolation(gpa, violations, "bindings/racket/info.rkt: must name private/c-abi-resolve.json as a must-ship package path", .{});
    }
    if (std.mem.indexOf(u8, racket_info, "compile-omit-paths") == null) {
        try appendViolation(gpa, violations, "bindings/racket/info.rkt: must declare compile-omit-paths (and not omit the resolve contract)", .{});
    }
}

fn headerMacroU32(text: []const u8, name: []const u8) ?u32 {
    var prefix_buf: [96]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "#define {s} ", .{name}) catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, prefix)) {
            const rest = std.mem.trim(u8, trimmed[prefix.len..], " \t\r");
            return std.fmt.parseInt(u32, rest, 10) catch null;
        }
    }
    return null;
}
