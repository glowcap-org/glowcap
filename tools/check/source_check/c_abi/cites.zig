//! Documentation surfaces over the C ABI: the served-surface list, the
//! deleted-projection guard, and every `glowcap_*` citation in the docs held
//! to a symbol the headers actually export.

const std = @import("std");
const util = @import("../util.zig");
const shared = @import("shared.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const fileContains = util.fileContains;
const firstIntIn = util.firstIntIn;
const parseJsonFile = util.parseJsonFile;
const getField = util.getField;
const jsonStringEquals = util.jsonStringEquals;

const doc_c_abi_header_paths = [_][]const u8{
    "include/glowcap_ocapn.h",
    "include/glowcap_host.h",
    "include/glowcap_loam.h",
    "include/glowcap_loam_lmdb.h",
    "include/glowcap_driver.h",
    "include/glowcap_transport_provider.h",
    "include/glowcap_net_transport_tcp.h",
    "include/glowcap_net_transport_relay.h",
    "include/glowcap_net_transport_inproc.h",
    "include/glowcap_net_transport_onion.h",
    "include/glowcap_net_transport_iroh.h",
    "include/glowcap_net_transport_webrtc.h",
    "transports/iroh/include/glowcap_iroh_sidecar.h",
};

/// The C ABI consumes `Served` through its surface verbs (`spawnHosted`,
/// `bindExport`, `refForExport`, …), never by reaching through the embedded
/// vat: `.served.vat` under `src/c_abi/` is a boundary violation.
pub fn checkCAbiServedSurface(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "src/c_abi", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "src/c_abi: failed to open for Served-surface check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const contents = dir.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "src/c_abi/{s}: failed to read for Served-surface check with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, ".served.vat") != null) {
            try appendViolation(gpa, violations, "src/c_abi/{s}: reaches `.served.vat` — the C ABI talks to Served through its surface verbs only", .{entry.path});
        }
    }
}

/// CapTP C product is `glowcap_host_*` only: the demoted `glowcap_node_*`
/// projection must not return in generated headers or binding FFI maps.
pub fn checkDeletedNodeCProjection(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const banned = "glowcap_node_";
    const paths = [_][]const u8{
        "include/glowcap_ocapn.h",
        "include/glowcap_host.h",
        "include/glowcap_loam.h",
        "include/glowcap_loam_lmdb.h",
        "bindings/ts/runtime/internal/ffi/ocapn.ts",
        "bindings/python/glowcap/_ffi_ocapn.py",
        "bindings/racket/private/ffi-ocapn.rkt",
        "bindings/rust/src/sys/ocapn.rs",
    };
    for (paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for deleted-node C projection check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, banned) != null) {
            try appendViolation(gpa, violations, "{s}: contains `{s}` — CapTP C product is glowcap_host_* only; the demoted node waist must not return", .{ path, banned });
        }
    }
    // The companion header itself must stay deleted.
    if (root.access(io, "include/glowcap_ocapn_node.h", .{})) |_| {
        try appendViolation(gpa, violations, "include/glowcap_ocapn_node.h: file must stay deleted (demoted node waist)", .{});
    } else |_| {}
}

/// Every `glowcap_[a-z0-9_]+` token inside backticks in docs and site content
/// must exist in the generated headers (or name a wildcard family that does).
pub fn checkDocCAbiCites(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var symbols = std.StringHashMap(void).init(arena);
    for (doc_c_abi_header_paths) |header_path| {
        const contents = root.readFileAlloc(io, header_path, arena, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for doc C-ABI cite check with {s}", .{ header_path, @errorName(err) });
            continue;
        };
        try collectGlowcapSymbols(contents, &symbols);
    }

    var docs = root.openDir(io, "docs", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "docs: failed to open for doc C-ABI cite check with {s}", .{@errorName(err)});
        return;
    };
    defer docs.close(io);
    var docs_walker = try docs.walk(gpa);
    defer docs_walker.deinit();
    while (try docs_walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
        const path = try std.fmt.allocPrint(arena, "docs/{s}", .{entry.path});
        const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for doc C-ABI cite check with {s}", .{ path, @errorName(err) });
            continue;
        };
        try scanDocCAbiCitesInContents(gpa, path, contents, &symbols, violations);
    }

    var site = root.openDir(io, "site/content", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "site/content: failed to open for doc C-ABI cite check with {s}", .{@errorName(err)});
        return;
    };
    defer site.close(io);
    var site_walker = try site.walk(gpa);
    defer site_walker.deinit();
    while (try site_walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".smd")) continue;
        const path = try std.fmt.allocPrint(arena, "site/content/{s}", .{entry.path});
        const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for doc C-ABI cite check with {s}", .{ path, @errorName(err) });
            continue;
        };
        try scanDocCAbiCitesInContents(gpa, path, contents, &symbols, violations);
    }
}

fn collectGlowcapSymbols(
    contents: []const u8,
    out: *std.StringHashMap(void),
) !void {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, contents, search, "glowcap_")) |start| {
        var end = start + "glowcap_".len;
        while (end < contents.len and isGlowcapIdentChar(contents[end])) end += 1;
        search = end;
        if (start > 0 and shared.isIdentChar(contents[start - 1])) continue;
        const name = contents[start..end];
        if (!out.contains(name)) try out.put(name, {});
    }
}

fn glowcapSymbolFamilyExists(prefix: []const u8, symbols: *const std.StringHashMap(void)) bool {
    var it = symbols.keyIterator();
    while (it.next()) |key| {
        if (std.mem.startsWith(u8, key.*, prefix)) return true;
    }
    return false;
}

fn docCAbiTokenValid(token: []const u8, symbols: *const std.StringHashMap(void)) bool {
    if (token.len < "glowcap_".len) return false;

    if (std.mem.eql(u8, token, "glowcap_*_release")) {
        var it = symbols.keyIterator();
        while (it.next()) |key| {
            if (!std.mem.startsWith(u8, key.*, "glowcap_")) continue;
            if (!std.mem.endsWith(u8, key.*, "_release")) continue;
            return true;
        }
        return false;
    }

    if (std.mem.endsWith(u8, token, "*")) {
        const prefix = token[0 .. token.len - 1];
        if (std.mem.endsWith(u8, prefix, "_")) {
            return glowcapSymbolFamilyExists(prefix, symbols);
        }
        var it = symbols.keyIterator();
        while (it.next()) |key| {
            if (std.mem.startsWith(u8, key.*, prefix)) return true;
        }
        return false;
    }

    if (std.mem.endsWith(u8, token, "_")) {
        return glowcapSymbolFamilyExists(token, symbols);
    }

    if (symbols.contains(token)) return true;

    return false;
}

fn extractGlowcapCiteToken(span: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, span, "glowcap_")) return null;
    if (std.mem.indexOfAny(u8, span, "<>") != null) return null;
    if (std.mem.endsWith(u8, span, ".h") or std.mem.endsWith(u8, span, ".wasm")) return null;
    var end: usize = "glowcap_".len;
    while (end < span.len and isGlowcapIdentChar(span[end])) end += 1;
    if (end < span.len and span[end] == '*') end += 1;
    if (end == "glowcap_".len) return null;
    return span[0..end];
}

/// ADRs preserve the exact spelling of surfaces they decided, including a
/// surface a later ADR explicitly retired. Current guides and site content get
/// no exception; this is a closed historical vocabulary, not a general stale-
/// cite allowlist.
fn isRetiredAdrCAbiToken(path: []const u8, token: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "docs/decisions/adr/")) return false;
    if (std.mem.startsWith(u8, token, "glowcap_peer_")) return true;
    if (std.mem.startsWith(u8, token, "glowcap_tcp_session_")) return true;
    return std.mem.eql(u8, token, "glowcap_event_release") or
        std.mem.eql(u8, token, "glowcap_any_event_release") or
        std.mem.eql(u8, token, "glowcap_tcp_settled_release") or
        std.mem.eql(u8, token, "glowcap_host_session_enroll_capability") or
        std.mem.eql(u8, token, "glowcap_host_session_release_import") or
        std.mem.eql(u8, token, "glowcap_host_gc_release");
}

fn scanDocCAbiCitesInContents(
    gpa: std.mem.Allocator,
    path: []const u8,
    contents: []const u8,
    symbols: *const std.StringHashMap(void),
    violations: *std.ArrayList([]const u8),
) !void {
    var rest = contents;
    while (std.mem.indexOf(u8, rest, "`glowcap_")) |start| {
        const after_tick = rest[start + 1 ..];
        const close = std.mem.indexOfScalar(u8, after_tick, '`') orelse break;
        const span = after_tick[0..close];
        rest = after_tick[close + 1 ..];
        const token = extractGlowcapCiteToken(span) orelse continue;
        if (!docCAbiTokenValid(token, symbols) and !isRetiredAdrCAbiToken(path, token)) {
            try appendViolation(gpa, violations, "{s}: backtick cite `{s}` has no matching symbol in include/*.h (doc C-ABI cite check)", .{ path, token });
        }
    }
}

fn isGlowcapIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
}
