//! The C-ABI find/download contract (ADR-0023): the canonical
//! `c-abi-resolve.json`'s shape, the version pin against the generated
//! header, the byte-identical package copies, and the package manifests that
//! ship the contract.

const std = @import("std");
const json_files = @import("../json_files.zig");
const violation_log = @import("../violation_log.zig");
const resolve_contract = @import("resolve_contract.zig");

const appendViolation = violation_log.appendViolation;
const parseJsonFile = json_files.parseJsonFile;
const getField = json_files.getField;
const jsonStringEquals = json_files.jsonStringEquals;

pub fn checkCAbiResolve(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const contract_path = resolve_contract.contract_path;
    var parsed = try parseJsonFile(io, gpa, root, violations, contract_path) orelse return;
    defer parsed.deinit();

    const expected_tarball = resolve_contract.tarball_template;
    const expected_operator_script = resolve_contract.operator_script;

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
            try appendViolation(gpa, violations, "{s}: `tarball_template` must be `{s}` (matches zig build c-sdk-pack)", .{ contract_path, expected_tarball });
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
    copies: {
        const canonical = root.readFileAlloc(io, contract_path, gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try appendViolation(gpa, violations, "{s}: cannot be read to compare its package copies ({s})", .{ contract_path, @errorName(err) });
                break :copies;
            },
        };
        defer gpa.free(canonical);
        for (package_copies) |copy_path| {
            const copy = root.readFileAlloc(io, copy_path, gpa, .limited(1 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: cannot read the package copy of `{s}` ({s})", .{ copy_path, contract_path, @errorName(err) });
                continue;
            };
            defer gpa.free(copy);
            if (!std.mem.eql(u8, canonical, copy)) {
                try appendViolation(gpa, violations, "{s}: differs from `{s}` — the shipped cascade must be byte-identical to the root contract", .{ copy_path, contract_path });
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
        const got = std.mem.print(&buf, "{d}.{d}.{d}", .{ major, minor, patch }) catch unreachable;
        if (!std.mem.eql(u8, got, want)) {
            try appendViolation(gpa, violations, "{s}: `abi_version` `{s}` must match include/glowcap_ocapn.h `{s}`", .{ contract_path, want, got });
        }
        if (getField(parsed.value, "user_agent")) |ua| {
            switch (ua) {
                .string => |s| {
                    if (std.mem.find(u8, s, want) == null) {
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

    // Package-ship surfaces: contract must be reachable from published packages.
    const pyproject = root.readFileAlloc(io, "bindings/python/pyproject.toml", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "bindings/python/pyproject.toml: failed to read with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(pyproject);
    if (std.mem.find(u8, pyproject, "c-abi-resolve.json") == null) {
        try appendViolation(gpa, violations, "bindings/python/pyproject.toml: package-data must ship c-abi-resolve.json", .{});
    }
    const deno_json = root.readFileAlloc(io, "bindings/ts/runtime/deno.json", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "bindings/ts/runtime/deno.json: failed to read with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(deno_json);
    if (std.mem.find(u8, deno_json, "c-abi-resolve.json") == null or
        std.mem.find(u8, deno_json, "\"publish\"") == null)
    {
        try appendViolation(gpa, violations, "bindings/ts/runtime/deno.json: publish.include must ship c-abi-resolve.json", .{});
    }
    const racket_info = root.readFileAlloc(io, "bindings/racket/info.rkt", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "bindings/racket/info.rkt: failed to read with {s} (package-ship surface)", .{@errorName(err)});
        return;
    };
    defer gpa.free(racket_info);
    if (std.mem.find(u8, racket_info, "private/c-abi-resolve.json") == null) {
        try appendViolation(gpa, violations, "bindings/racket/info.rkt: must name private/c-abi-resolve.json as a must-ship package path", .{});
    }
    if (std.mem.find(u8, racket_info, "compile-omit-paths") == null) {
        try appendViolation(gpa, violations, "bindings/racket/info.rkt: must declare compile-omit-paths (and not omit the resolve contract)", .{});
    }
}

fn headerMacroU32(text: []const u8, name: []const u8) ?u32 {
    var prefix_buf: [96]u8 = undefined;
    const prefix = std.mem.print(&prefix_buf, "#define {s} ", .{name}) catch return null;
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
