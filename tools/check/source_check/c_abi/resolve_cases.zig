//! The resolve-cases oracle over the canonical contract (ADR-0023).

const std = @import("std");
const util = @import("../util.zig");
const shared = @import("shared.zig");

const appendViolation = util.appendViolation;
const parseJsonFile = util.parseJsonFile;
const getField = util.getField;
const jsonStringEquals = util.jsonStringEquals;

/// The shared resolve-cases oracle: derive URL, cache path, and want_fetch
/// from the canonical contract's own templates and pin the case table, so the
/// apex and the five per-port spines cannot drift apart.
pub fn checkCAbiResolveCases(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var contract_doc = try parseJsonFile(io, gpa, root, violations, shared.contract_path) orelse return;
    defer contract_doc.deinit();
    const contract = contract_doc.value;

    const cases_path = "tools/c-abi/c-abi-resolve-cases.json";
    var cases_doc = try parseJsonFile(io, gpa, root, violations, cases_path) orelse return;
    defer cases_doc.deinit();

    const default_base = blk: {
        const v = getField(contract, "default_release_base_url") orelse {
            try appendViolation(gpa, violations, "{s}: contract missing default_release_base_url for resolve-cases", .{cases_path});
            return;
        };
        break :blk switch (v) {
            .string => |s| s,
            else => {
                try appendViolation(gpa, violations, "{s}: default_release_base_url must be a string", .{cases_path});
                return;
            },
        };
    };
    const tag_tmpl = blk: {
        const v = getField(contract, "release_tag_template") orelse return;
        break :blk switch (v) {
            .string => |s| s,
            else => return,
        };
    };
    const tarball_tmpl = blk: {
        const v = getField(contract, "tarball_template") orelse return;
        break :blk switch (v) {
            .string => |s| s,
            else => return,
        };
    };
    const cache_tmpl = blk: {
        const v = getField(contract, "cache_layout") orelse return;
        break :blk switch (v) {
            .string => |s| s,
            else => return,
        };
    };

    const cases_val = getField(cases_doc.value, "cases") orelse {
        try appendViolation(gpa, violations, "{s}: missing `cases`", .{cases_path});
        return;
    };
    const cases = switch (cases_val) {
        .array => |arr| arr,
        else => {
            try appendViolation(gpa, violations, "{s}: `cases` must be an array", .{cases_path});
            return;
        },
    };

    for (cases.items) |case_val| {
        const case_obj = switch (case_val) {
            .object => |o| o,
            else => continue,
        };
        const id = switch (case_obj.get("id") orelse continue) {
            .string => |s| s,
            else => "?",
        };
        const version = switch (case_obj.get("version") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const target = switch (case_obj.get("target") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const cache_base = switch (case_obj.get("cache_base") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const checkout = switch (case_obj.get("checkout") orelse continue) {
            .bool => |b| b,
            else => continue,
        };
        const want_fetch = switch (case_obj.get("want_fetch") orelse continue) {
            .bool => |b| b,
            else => continue,
        };
        const want_url = switch (case_obj.get("url") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const want_cache = switch (case_obj.get("cache_lib") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const want_sums = switch (case_obj.get("sums_url") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const env_obj: ?std.json.ObjectMap = blk: {
            const v = case_obj.get("env") orelse break :blk null;
            break :blk switch (v) {
                .object => |o| o,
                else => null,
            };
        };

        const skip = envTruthyFromObject(env_obj, "GLOWCAP_SKIP_DOWNLOAD");
        const download = envTruthyFromObject(env_obj, "GLOWCAP_DOWNLOAD");
        const got_fetch = if (checkout) download else !skip;
        if (got_fetch != want_fetch) {
            try appendViolation(gpa, violations, "{s}: case `{s}` want_fetch mismatch", .{ cases_path, id });
        }

        const base = blk: {
            if (env_obj) |o| {
                if (o.get("GLOWCAP_RELEASE_BASE_URL")) |v| {
                    switch (v) {
                        .string => |s| break :blk s,
                        else => {},
                    }
                }
            }
            break :blk default_base;
        };
        const tag = try applyContractTemplate(gpa, tag_tmpl, version, target, cache_base);
        defer gpa.free(tag);
        const tarball = try applyContractTemplate(gpa, tarball_tmpl, version, target, cache_base);
        defer gpa.free(tarball);
        const cache_lib = try applyContractTemplate(gpa, cache_tmpl, version, target, cache_base);
        defer gpa.free(cache_lib);

        const got_url = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ base, tag, tarball });
        defer gpa.free(got_url);
        if (!std.mem.eql(u8, got_url, want_url)) {
            try appendViolation(gpa, violations, "{s}: case `{s}` url want `{s}` got `{s}`", .{ cases_path, id, want_url, got_url });
        }
        const got_sums = try std.fmt.allocPrint(gpa, "{s}/{s}/SHA256SUMS", .{ base, tag });
        defer gpa.free(got_sums);
        if (!std.mem.eql(u8, got_sums, want_sums)) {
            try appendViolation(gpa, violations, "{s}: case `{s}` sums_url want `{s}` got `{s}`", .{ cases_path, id, want_sums, got_sums });
        }
        if (!std.mem.eql(u8, cache_lib, want_cache)) {
            try appendViolation(gpa, violations, "{s}: case `{s}` cache_lib want `{s}` got `{s}`", .{ cases_path, id, want_cache, cache_lib });
        }
    }

    // Loaders must still implement the same want_fetch / template verbs.
    const resolve_ports = shared.c_abi_binding_loaders ++ [_][]const u8{shared.operator_script};
    for (resolve_ports) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot be read for the resolve-verb check ({s})", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "GLOWCAP_SKIP_DOWNLOAD") == null) {
            try appendViolation(gpa, violations, "{s}: resolve port must honor GLOWCAP_SKIP_DOWNLOAD", .{path});
        }
    }
}

fn applyContractTemplate(allocator: std.mem.Allocator, tmpl: []const u8, version: []const u8, target: []const u8, cache_base: []const u8) ![]u8 {
    var out = try allocator.dupe(u8, tmpl);
    errdefer allocator.free(out);
    // Replace longest placeholders first so nested names cannot collide.
    inline for (.{ "{cache_base}", "{version}", "{target}" }) |needle| {
        const replacement = switch (needle[1]) {
            'c' => cache_base,
            'v' => version,
            't' => target,
            else => unreachable,
        };
        if (std.mem.indexOf(u8, out, needle) != null) {
            const next = try std.mem.replaceOwned(u8, allocator, out, needle, replacement);
            allocator.free(out);
            out = next;
        }
    }
    return out;
}

fn envTruthyFromObject(env_obj: ?std.json.ObjectMap, name: []const u8) bool {
    const obj = env_obj orelse return false;
    const v = obj.get(name) orelse return false;
    const s = switch (v) {
        .string => |str| str,
        else => return false,
    };
    var buf: [16]u8 = undefined;
    if (s.len > buf.len) return false;
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const lower = buf[0..s.len];
    return std.mem.eql(u8, lower, "1") or std.mem.eql(u8, lower, "true") or std.mem.eql(u8, lower, "yes");
}
