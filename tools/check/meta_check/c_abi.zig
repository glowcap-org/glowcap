//! The C ABI contract checks.
//!
//! Cross-file derived invariants over the public C surface: the ABI version
//! lockstep, the one-release-per-handle freeing verb, the boring-surface
//! shape, export consumption, peer-event/send parity, the archive resolve
//! cascade (ADR-0077) and its case table, the served-surface and
//! deleted-projection guards, doc C-ABI citation validity, host-action arm
//! lockstep, the host plugin API wiring, the host-pump import allowlist, and
//! the no-ADR-in-runtime-strings rule. Wired by the meta-check driver
//! (`tools/check/meta_check.zig`).

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const fileContains = util.fileContains;
const firstIntIn = util.firstIntIn;
const parseJsonFile = util.parseJsonFile;
const getField = util.getField;
const jsonStringEquals = util.jsonStringEquals;

/// The ABI version triple is stated four times: `abi_version` in `build.zig`,
/// `.version` in `build.zig.zon`, `PANCAKE_VERSION_*` in `src/c_abi/ocapn/mod.zig`,
/// and the generated `#define PANCAKE_VERSION_*` macros in `include/pancake_ocapn.h`.
/// This parses all four and holds them in lockstep, so bumping one surface
/// without the others fails the gate instead of shipping a package whose zon
/// version disagrees with the soname it installs.
pub fn checkAbiVersionLockstep(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const Triple = struct { major: i64, minor: i64, patch: i64 };
    const sources = [_]struct {
        path: []const u8,
        keys: [3][]const u8,
        // The triple's declaration site, when the keys alone are ambiguous in
        // the file (build.zig has many `.major =` struct literals).
        anchor: ?[]const u8 = null,
    }{
        .{ .path = "build.zig", .keys = .{ ".major =", ".minor =", ".patch =" }, .anchor = "const abi_version" },
        .{ .path = "src/c_abi/ocapn/mod.zig", .keys = .{
            "PANCAKE_VERSION_MAJOR: u32 =",
            "PANCAKE_VERSION_MINOR: u32 =",
            "PANCAKE_VERSION_PATCH: u32 =",
        } },
        .{ .path = "include/pancake_ocapn.h", .keys = .{
            "#define PANCAKE_VERSION_MAJOR",
            "#define PANCAKE_VERSION_MINOR",
            "#define PANCAKE_VERSION_PATCH",
        } },
    };

    var triples: [sources.len]?Triple = @splat(null);
    for (sources, 0..) |source, i| {
        const contents = root.readFileAlloc(io, source.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for ABI version lockstep check with {s}", .{ source.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        const search_from = if (source.anchor) |anchor|
            (if (std.mem.indexOf(u8, contents, anchor)) |at| contents[at..] else contents)
        else
            contents;
        var parts: [3]i64 = undefined;
        var ok = true;
        for (source.keys, 0..) |key, k| {
            const at = std.mem.indexOf(u8, search_from, key) orelse {
                try appendViolation(gpa, violations, "{s}: ABI version component '{s}' not found", .{ source.path, key });
                ok = false;
                continue;
            };
            parts[k] = firstIntIn(search_from[at + key.len ..]) orelse {
                try appendViolation(gpa, violations, "{s}: ABI version component '{s}' has no integer value", .{ source.path, key });
                ok = false;
                continue;
            };
        }
        if (ok) triples[i] = .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
    }

    var zon_triple: ?Triple = null;
    const zon = root.readFileAlloc(io, "build.zig.zon", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "build.zig.zon: failed to read for ABI version lockstep check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(zon);
    if (std.mem.indexOf(u8, zon, ".version = \"")) |at| {
        const rest = zon[at + ".version = \"".len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse rest.len;
        var it = std.mem.splitScalar(u8, rest[0..end], '.');
        const major = firstIntIn(it.next() orelse "");
        const minor = firstIntIn(it.next() orelse "");
        const patch = firstIntIn(it.next() orelse "");
        if (major != null and minor != null and patch != null) {
            zon_triple = .{ .major = major.?, .minor = minor.?, .patch = patch.? };
        } else {
            try appendViolation(gpa, violations, "build.zig.zon: .version \"{s}\" is not a semantic version triple", .{rest[0..end]});
        }
    } else {
        try appendViolation(gpa, violations, "build.zig.zon: no .version field found for ABI version lockstep check", .{});
    }

    const anchor = triples[0] orelse return;
    for (sources[1..], triples[1..]) |source, maybe_triple| {
        const triple = maybe_triple orelse continue;
        if (!std.meta.eql(triple, anchor)) {
            try appendViolation(gpa, violations, "{s}: ABI version {d}.{d}.{d} drifts from build.zig abi_version {d}.{d}.{d}", .{
                source.path, triple.major, triple.minor, triple.patch, anchor.major, anchor.minor, anchor.patch,
            });
        }
    }
    if (zon_triple) |triple| {
        if (!std.meta.eql(triple, anchor)) {
            try appendViolation(gpa, violations, "build.zig.zon: .version {d}.{d}.{d} drifts from build.zig abi_version {d}.{d}.{d}", .{
                triple.major, triple.minor, triple.patch, anchor.major, anchor.minor, anchor.patch,
            });
        }
    }
}

pub fn checkAbiFreeingVerb(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (abi_vocabulary_headers) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for ABI freeing-verb check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(gpa);
        var line_it = std.mem.splitScalar(u8, contents, '\n');
        while (line_it.next()) |line| try lines.append(gpa, line);

        var decls: std.ArrayList(HeaderDecl) = .empty;
        defer decls.deinit(gpa);
        try collectHeaderDeclarations(gpa, contents, &decls);
        if (decls.items.len == 0) {
            try appendViolation(gpa, violations, "{s}: found no pancake_ declarations; the ABI freeing-verb scanner no longer matches this header", .{path});
            continue;
        }

        for (decls.items) |decl| {
            const name = decl.name;
            // `*_free` is not an allowed freeing spelling: a handle that frees
            // is `*_release`, so a `pancake_*_free` export is the inconsistency
            // this rule exists to prevent, not merely a `*_close` to document.
            if (std.mem.endsWith(u8, name, "_free")) {
                try appendViolation(gpa, violations, "{s}: {s} frees a handle but is not spelled *_release; the one freeing verb is *_release", .{ path, name });
                continue;
            }
            if (!std.mem.endsWith(u8, name, "_close")) continue;
            const i = lineIndexOfOffset(contents, decl.offset);

            if (i == 0 or !std.mem.endsWith(u8, std.mem.trimEnd(u8, lines.items[i - 1], " \t"), "*/")) {
                try appendViolation(gpa, violations, "{s}: {s} has no doc comment; a *_close must state it closes \"without releasing\" the handle", .{ path, name });
                continue;
            }
            var states_no_release = false;
            var claims_free = false;
            var j: usize = i - 1;
            while (true) {
                const doc_line = lines.items[j];
                if (std.mem.indexOf(u8, doc_line, "without releasing") != null) states_no_release = true;
                if (std.mem.indexOf(u8, doc_line, "free") != null) claims_free = true;
                if (std.mem.startsWith(u8, std.mem.trimStart(u8, doc_line, " \t"), "/*")) break;
                if (j == 0) break;
                j -= 1;
            }
            if (!states_no_release) {
                try appendViolation(gpa, violations, "{s}: {s} must state it closes \"without releasing\" the handle; release is the only freeing verb", .{ path, name });
            }
            if (claims_free) {
                try appendViolation(gpa, violations, "{s}: {s} claims to free in its doc; a freeing handle verb is spelled *_release", .{ path, name });
            }
        }
    }
}

/// The minimality bar from ADR-0059: a clean C ABI is not only correctly
/// represented (ADR-0059) but minimally shaped — one spelling per concept, no
/// accidental variation. This holds the two structural invariants a careless
/// addition would break (the close/release verb is held separately by
/// `checkAbiFreeingVerb`):
///   - constructor-twin completeness: every `*_new` that uses the library
///     allocator has exactly one allocator-aware twin (`*_new_in`, or
///     `*_new_with_allocator` for the context root), and every twin has its base;
///   - one error channel per archive: exactly one `last_error`/`clear_last_error`
///     pair per family — the ocapn root, `tcp`, `inproc`, `iroh` — and no other
///     error-reporting spelling.
pub fn checkCAbiSurfaceShape(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // Collect every exported function name. The name slices reference the header
    // contents, so keep the buffers alive for the whole check.
    var contents_buffers: std.ArrayList([]u8) = .empty;
    defer {
        for (contents_buffers.items) |buf| gpa.free(buf);
        contents_buffers.deinit(gpa);
    }
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var name_set = std.StringHashMap(void).init(gpa);
    defer name_set.deinit();

    for (abi_vocabulary_headers) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for ABI surface-shape check with {s}", .{ path, @errorName(err) });
            continue;
        };
        try contents_buffers.append(gpa, contents);

        var decls: std.ArrayList(HeaderDecl) = .empty;
        defer decls.deinit(gpa);
        try collectHeaderDeclarations(gpa, contents, &decls);
        if (decls.items.len == 0) {
            try appendViolation(gpa, violations, "{s}: found no pancake_ declarations; the ABI surface-shape scanner no longer matches this header", .{path});
            continue;
        }
        for (decls.items) |decl| {
            if (name_set.contains(decl.name)) continue;
            try name_set.put(decl.name, {});
            try names.append(gpa, decl.name);
        }
    }

    // Invariant 1, constructor-twin completeness.
    for (names.items) |name| {
        if (std.mem.endsWith(u8, name, "_in")) {
            const base = name[0 .. name.len - "_in".len];
            if (!name_set.contains(base)) {
                try appendViolation(gpa, violations, "C ABI surface (ADR-0059): {s} has no base constructor {s}; an `_in` twin must pair a library-allocator base", .{ name, base });
            }
        } else if (std.mem.endsWith(u8, name, "_new_with_allocator")) {
            const base = name[0 .. name.len - "_with_allocator".len];
            if (!name_set.contains(base)) {
                try appendViolation(gpa, violations, "C ABI surface (ADR-0059): {s} has no base constructor {s}", .{ name, base });
            }
        } else if (std.mem.indexOf(u8, name, "_new") != null) {
            const twin_in = try std.fmt.allocPrint(gpa, "{s}_in", .{name});
            defer gpa.free(twin_in);
            const twin_alloc = try std.fmt.allocPrint(gpa, "{s}_with_allocator", .{name});
            defer gpa.free(twin_alloc);
            if (!name_set.contains(twin_in) and !name_set.contains(twin_alloc)) {
                try appendViolation(gpa, violations, "C ABI surface (ADR-0059): {s} has no allocator-aware twin ({s}_in or {s}_with_allocator); allocation policy is one axis spelled one way", .{ name, name, name });
            }
        }
    }

    // Invariant 2, one error channel per archive, no extra spelling.
    const allowed_error_families = [_][]const u8{ "", "host", "tcp", "inproc", "iroh", "webrtc" };
    for (names.items) |name| {
        if (!std.mem.endsWith(u8, name, "_last_error")) continue;
        if (std.mem.endsWith(u8, name, "_clear_last_error")) continue;
        const head = name[0 .. name.len - "_last_error".len];
        var family: []const u8 = undefined;
        if (std.mem.eql(u8, head, "pancake")) {
            family = "";
        } else if (std.mem.startsWith(u8, head, "pancake_")) {
            family = head["pancake_".len..];
        } else continue;

        var family_ok = false;
        for (allowed_error_families) |f| {
            if (std.mem.eql(u8, f, family)) family_ok = true;
        }
        if (!family_ok) {
            try appendViolation(gpa, violations, "C ABI surface (ADR-0059): {s} introduces an error channel for unexpected family `{s}`; the error channels are the ocapn root, host, tcp, inproc, iroh", .{ name, family });
            continue;
        }
        const clear = if (family.len == 0)
            try std.fmt.allocPrint(gpa, "pancake_clear_last_error", .{})
        else
            try std.fmt.allocPrint(gpa, "pancake_{s}_clear_last_error", .{family});
        defer gpa.free(clear);
        if (!name_set.contains(clear)) {
            try appendViolation(gpa, violations, "C ABI surface (ADR-0059): {s} has no matching {s}; an error channel is a last_error/clear_last_error pair", .{ name, clear });
        }
    }
}

/// Every function the C headers export must have a consumer: a reference
/// somewhere under `bindings/`, `examples/`, `interop/`, or `test/`. An export
/// nobody consumes or exercises is dead surface — the drift mode is a verb the
/// waist has superseded that keeps shipping because nothing points at it. The
/// scan collects every `pancake_*` identifier the consumer trees mention (one
/// pass, identifier boundaries), so `pancake_host_session_feed` cannot satisfy
/// `pancake_host_session_feed_bytes`.
pub fn checkAbiExportsConsumed(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The exported names, parsed from function declarations only.
    var exports: std.ArrayList(struct { name: []const u8, header: []const u8 }) = .empty;
    defer exports.deinit(gpa);
    for (abi_vocabulary_headers) |path| {
        const contents = root.readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for ABI consumer check with {s}", .{ path, @errorName(err) });
            continue;
        };
        var decls: std.ArrayList(HeaderDecl) = .empty;
        defer decls.deinit(gpa);
        try collectHeaderDeclarations(gpa, contents, &decls);
        if (decls.items.len == 0) {
            try appendViolation(gpa, violations, "{s}: found no pancake_ declarations; the ABI consumer scanner no longer matches this header", .{path});
            continue;
        }
        for (decls.items) |decl| try exports.append(gpa, .{ .name = decl.name, .header = path });
    }

    // Every pancake_* identifier the consumer trees mention, one walk.
    var consumed = std.StringHashMap(void).init(gpa);
    defer consumed.deinit();
    const consumer_roots = [_][]const u8{ "bindings", "examples", "interop", "test" };
    const consumer_exts = [_][]const u8{ ".rs", ".ts", ".py", ".rkt", ".c", ".h", ".zig", ".scm" };
    const skip_dirs = [_][]const u8{ "target", "node_modules", "__pycache__", "compiled", ".zig-cache", "zig-out" };
    for (consumer_roots) |dir_path| {
        var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for ABI consumer check with {s}", .{ dir_path, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walkSelectively(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) {
                var skip = false;
                for (skip_dirs) |sd| {
                    if (std.mem.eql(u8, entry.basename, sd)) skip = true;
                }
                if (!skip) try walker.enter(io, entry);
                continue;
            }
            if (entry.kind != .file) continue;
            var ext_ok = false;
            for (consumer_exts) |ext| {
                if (std.mem.endsWith(u8, entry.basename, ext)) ext_ok = true;
            }
            if (!ext_ok) continue;
            const contents = dir.readFileAlloc(io, entry.path, gpa, .limited(1 << 24)) catch |err| {
                try appendViolation(gpa, violations, "{s}/{s}: failed to read for ABI consumer check with {s}", .{ dir_path, entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            var search: usize = 0;
            while (std.mem.indexOfPos(u8, contents, search, "pancake_")) |start| {
                var end = start;
                while (end < contents.len and isIdentChar(contents[end])) end += 1;
                search = end;
                if (start > 0 and isIdentChar(contents[start - 1])) continue;
                const ident = contents[start..end];
                if (consumed.contains(ident)) continue;
                try consumed.put(try arena.dupe(u8, ident), {});
            }
        }
    }

    var export_names = std.StringHashMap(void).init(gpa);
    defer export_names.deinit();
    for (exports.items) |exported| try export_names.put(exported.name, {});

    for (exports.items) |exported| {
        if (consumed.contains(exported.name)) continue;
        // An allocator twin of an exported base constructor is structurally
        // required by ADR-0059 (checkCAbiSurfaceShape holds the pairing), so
        // its existence does not need a consumer of its own; everything else
        // must earn its slot.
        if (std.mem.endsWith(u8, exported.name, "_in")) {
            const base = exported.name[0 .. exported.name.len - "_in".len];
            if (export_names.contains(base)) continue;
        }
        if (std.mem.endsWith(u8, exported.name, "_with_allocator")) {
            const base = exported.name[0 .. exported.name.len - "_with_allocator".len];
            if (export_names.contains(base)) continue;
        }
        try appendViolation(gpa, violations, "{s}: exported `{s}` has no consumer under bindings/, examples/, interop/, or test/ — dead surface; retire it or give it the consumer that justifies it", .{ exported.header, exported.name });
    }
}

/// CapTP `PANCAKE_EVENT_*` kinds (except `NONE`) must have a peer send constructor
/// in `pancake_ocapn.h`, or an explicit allowlist reason. Renamed constructors
/// (start_session, handoff deposit/withdraw/resolve-give) count; LISTEN is
/// allowlisted as engine-synthesized / inbound-only. Adding an event without a
/// send or allowlist row fails this check.
pub fn checkPeerEventSendParity(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const header_path = "include/pancake_ocapn.h";
    const header = root.readFileAlloc(io, header_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for event/send parity with {s}", .{ header_path, @errorName(err) });
        return;
    };
    defer gpa.free(header);

    const Row = struct {
        event: []const u8,
        send: ?[]const u8 = null,
        also: []const []const u8 = &.{},
        allowlist: ?[]const u8 = null,
    };
    const rows = [_]Row{
        .{ .event = "DELIVER", .send = "pancake_peer_send_deliver" },
        .{ .event = "RESOLVE", .send = "pancake_peer_send_resolve" },
        .{ .event = "GC_EXPORT", .send = "pancake_peer_send_gc_export" },
        .{ .event = "GC_ANSWER", .send = "pancake_peer_send_gc_answer" },
        .{ .event = "HANDOFF", .also = &.{
            "pancake_peer_send_deposit_gift",
            "pancake_peer_send_withdraw_gift",
            "pancake_peer_send_resolve_handoff_give",
        } },
        .{ .event = "START_SESSION", .send = "pancake_peer_start_session" },
        .{ .event = "ABORT", .send = "pancake_peer_send_abort" },
        .{ .event = "LISTEN", .allowlist = "engine-synthesized / inbound install; not an app send at the peer ABI" },
        .{ .event = "GET", .send = "pancake_peer_send_get" },
        .{ .event = "INDEX", .send = "pancake_peer_send_index" },
        .{ .event = "UNTAG", .send = "pancake_peer_send_untag" },
    };

    var seen_events = std.StringHashMap(void).init(gpa);
    defer seen_events.deinit();

    var rest = header;
    const event_needle = "#define PANCAKE_EVENT_";
    while (std.mem.indexOf(u8, rest, event_needle)) |start| {
        const after = rest[start + event_needle.len ..];
        const line_end = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
        const line = after[0..line_end];
        rest = after[line_end..];
        const name_end = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const suffix = line[0..name_end];
        if (std.mem.eql(u8, suffix, "NONE")) continue;
        try seen_events.put(suffix, {});

        var matched_row: ?Row = null;
        for (rows) |row| {
            if (std.mem.eql(u8, row.event, suffix)) {
                matched_row = row;
                break;
            }
        }
        const row = matched_row orelse {
            try appendViolation(gpa, violations, "{s}: PANCAKE_EVENT_{s} has no peer send/allowlist row in checkPeerEventSendParity — add pancake_peer_send_* or an allowlist reason", .{ header_path, suffix });
            continue;
        };
        if (row.allowlist != null) continue;

        var ok = false;
        if (row.send) |send_name| {
            if (std.mem.indexOf(u8, header, send_name) != null) ok = true;
        }
        for (row.also) |alt| {
            if (std.mem.indexOf(u8, header, alt) != null) ok = true;
        }
        if (!ok) {
            if (row.send) |send_name| {
                try appendViolation(gpa, violations, "{s}: PANCAKE_EVENT_{s} needs `{s}` (or a listed alternate) in the header, or an allowlist reason in checkPeerEventSendParity", .{ header_path, suffix, send_name });
            } else {
                try appendViolation(gpa, violations, "{s}: PANCAKE_EVENT_{s} needs one of its alternate send constructors in the header, or an allowlist reason in checkPeerEventSendParity", .{ header_path, suffix });
            }
        }
    }

    for (rows) |row| {
        if (!seen_events.contains(row.event)) {
            try appendViolation(gpa, violations, "{s}: checkPeerEventSendParity lists EVENT_{s} but the header has no PANCAKE_EVENT_{s} — drop the stale row", .{ header_path, row.event, row.event });
        }
    }
}

pub fn checkCAbiResolve(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const contract_path = "bindings/c-abi-resolve.json";
    var parsed = try parseJsonFile(io, gpa, root, violations, contract_path) orelse return;
    defer parsed.deinit();

    const expected_tarball = "pancake-c-v{version}-{target}.tar.gz";
    const expected_operator_script = "tools/c-abi/fetch-c-abi.sh";

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
        "bindings/python/pancake/c-abi-resolve.json",
        "bindings/ts/stack/internal/ffi/c-abi-resolve.json",
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
        try appendViolation(gpa, violations, "{s}: unpaid `env` field — delete it; document env names in bindings/README.md", .{contract_path});
    }

    // Header macros must match the contract pin; user_agent embeds the same version.
    if (abi_version) |want| {
        const header = root.readFileAlloc(io, "include/pancake_ocapn.h", gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "include/pancake_ocapn.h: failed to read for c-abi-resolve check with {s}", .{@errorName(err)});
            return;
        };
        defer gpa.free(header);
        const major = headerMacroU32(header, "PANCAKE_VERSION_MAJOR") orelse 0;
        const minor = headerMacroU32(header, "PANCAKE_VERSION_MINOR") orelse 0;
        const patch = headerMacroU32(header, "PANCAKE_VERSION_PATCH") orelse 0;
        var buf: [32]u8 = undefined;
        const got = std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{ major, minor, patch }) catch unreachable;
        if (!std.mem.eql(u8, got, want)) {
            try appendViolation(gpa, violations, "{s}: `abi_version` `{s}` must match include/pancake_ocapn.h `{s}`", .{ contract_path, want, got });
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

    const readme = root.readFileAlloc(io, "bindings/README.md", gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "bindings/README.md: failed to read for c-abi-resolve check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(readme);
    if (std.mem.indexOf(u8, readme, "c-abi-resolve.json") == null) {
        try appendViolation(gpa, violations, "bindings/README.md: Finding the archives must name `c-abi-resolve.json`", .{});
    }
    if (std.mem.indexOf(u8, readme, "ADR-0077") == null) {
        try appendViolation(gpa, violations, "bindings/README.md: Finding the archives must cite ADR-0077", .{});
    }
    if (std.mem.indexOf(u8, readme, "PANCAKE_STRICT") == null) {
        try appendViolation(gpa, violations, "bindings/README.md: Finding the archives must document `PANCAKE_STRICT`", .{});
    }
    if (std.mem.indexOf(u8, readme, "releases_published") == null) {
        try appendViolation(gpa, violations, "bindings/README.md: Finding the archives must document `releases_published`", .{});
    }
    if (std.mem.indexOf(u8, readme, "PANCAKE_DOWNLOAD") == null) {
        try appendViolation(gpa, violations, "bindings/README.md: Finding the archives must document `PANCAKE_DOWNLOAD`", .{});
    }

    const binding_loaders = c_abi_binding_loaders;
    // Shadow literals that must live only in the contract JSON (not loaders/script).
    const forbidden_shadows = [_][]const u8{
        "536870912",
        "536_870_912",
        "1048576",
        "pancake-c-abi-fetch/",
        "pancake-c-abi-cache",
        "pancake-c-v{version}-{target}.tar.gz",
        "https://github.com/jimisaacs/pancake/releases/download",
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
            std.mem.indexOf(u8, contents, "PANCAKE_VERSION_MAJOR") == null)
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
        if (std.mem.indexOf(u8, contents, "PANCAKE_ALLOW_INSECURE") == null) {
            try appendViolation(gpa, violations, "{s}: must gate downloads with PANCAKE_ALLOW_INSECURE escape (ADR-0077 §5)", .{path});
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
        if (std.mem.eql(u8, path, "bindings/python/pancake/_lib_resolve.py")) {
            if (std.mem.indexOf(u8, contents, "issym") == null) {
                try appendViolation(gpa, violations, "{s}: must reject symlink/hardlink tar members (ADR-0077 §5)", .{path});
            }
        } else if (std.mem.eql(u8, path, "bindings/ts/stack/internal/ffi/load.ts")) {
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
        if (std.mem.eql(u8, path, "bindings/python/pancake/_lib_resolve.py")) {
            if (std.mem.indexOf(u8, contents, "def _hard_fail") == null) {
                try appendViolation(gpa, violations, "{s}: must define _hard_fail for hygiene/checksum/HTTPS", .{path});
            }
        } else if (std.mem.eql(u8, path, "bindings/ts/stack/internal/ffi/load.ts")) {
            if (std.mem.indexOf(u8, contents, "function hardFail") == null) {
                try appendViolation(gpa, violations, "{s}: must define hardFail for hygiene/checksum/HTTPS", .{path});
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
        "bindings/racket/private/ffi-driver-gen.rkt",
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
            try appendViolation(gpa, violations, "{s}: must not hardcode zig-out via define-runtime-path; open-pancake-archive discovers it", .{path});
        }
        if (std.mem.indexOf(u8, contents, "open-pancake-archive") == null) {
            try appendViolation(gpa, violations, "{s}: must open archives through open-pancake-archive", .{path});
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

    // Package-ship surfaces: contract must be reachable from published packages.
    const pyproject = root.readFileAlloc(io, "bindings/python/pyproject.toml", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "bindings/python/pyproject.toml: failed to read with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(pyproject);
    if (std.mem.indexOf(u8, pyproject, "c-abi-resolve.json") == null) {
        try appendViolation(gpa, violations, "bindings/python/pyproject.toml: package-data must ship c-abi-resolve.json", .{});
    }
    const deno_json = root.readFileAlloc(io, "bindings/ts/stack/deno.json", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "bindings/ts/stack/deno.json: failed to read with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(deno_json);
    if (std.mem.indexOf(u8, deno_json, "c-abi-resolve.json") == null or
        std.mem.indexOf(u8, deno_json, "\"publish\"") == null)
    {
        try appendViolation(gpa, violations, "bindings/ts/stack/deno.json: publish.include must ship c-abi-resolve.json", .{});
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

    // Shared resolve-cases oracle: derive URL/cache/want_fetch from the
    // canonical contract templates and pin cases (apex vs five-spine drift).
    try checkCAbiResolveCases(io, gpa, root, violations, parsed.value);

    // Shared host-target alias fixture: every listed alias must appear in
    // EACH non-cargo normalizer (per-port honesty — not a union corpus).
    // Rust uses CARGO_CFG_* and is skipped; operator script is included.
    const host_aliases_fixture = "tools/c-abi/c-abi-host-aliases.json";
    var aliases_parsed = try parseJsonFile(io, gpa, root, violations, host_aliases_fixture) orelse return;
    defer aliases_parsed.deinit();
    const alias_ports = c_abi_binding_loaders[1..] ++ [_][]const u8{expected_operator_script};
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
    if (std.mem.indexOf(u8, readme, "c-abi-host-aliases") == null and
        std.mem.indexOf(u8, readme, "CARGO_CFG_TARGET") == null)
    {
        try appendViolation(gpa, violations, "bindings/README.md: must document release-pack target triples / cargo cfg posture", .{});
    }

    // release.yml must gate `gh release create` on the contract valve.
    const release_workflow = ".github/workflows/release.yml";
    const workflow = root.readFileAlloc(io, release_workflow, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ release_workflow, @errorName(err) });
        return;
    };
    defer gpa.free(workflow);
    if (std.mem.indexOf(u8, workflow, "releases_published") == null) {
        try appendViolation(gpa, violations, "{s}: must gate publish on contract `releases_published`", .{release_workflow});
    }
    if (std.mem.indexOf(u8, workflow, "gh release create") == null) {
        try appendViolation(gpa, violations, "{s}: must still contain `gh release create` for the tag path", .{release_workflow});
    }
    if (std.mem.indexOf(u8, workflow, "jq") == null or
        std.mem.indexOf(u8, workflow, ".releases_published == true") == null)
    {
        try appendViolation(gpa, violations, "{s}: must jq-check `.releases_published == true` before publish", .{release_workflow});
    }
    if (std.mem.indexOf(u8, workflow, "workflow_dispatch") == null) {
        try appendViolation(gpa, violations, "{s}: must offer workflow_dispatch for dry-run archive builds", .{release_workflow});
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
        .{ .path = "bindings/ts/stack/internal/ffi/archive_hygiene.ts" },
        .{ .path = "bindings/rust/archive_hygiene.rs" },
        .{ .path = "bindings/python/pancake/_lib_resolve.py", .parses_listing = false },
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
    const boundaries = root.readFileAlloc(io, "docs/boundaries.md", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "docs/boundaries.md: failed to read for ADR-0077 packaging edge with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(boundaries);
    if (std.mem.indexOf(u8, boundaries, "ADR-0077") == null or
        std.mem.indexOf(u8, boundaries, "c-abi-resolve.json") == null)
    {
        try appendViolation(gpa, violations, "docs/boundaries.md: must name ADR-0077 publishable C-ABI resolve / c-abi-resolve.json", .{});
    }
}

pub fn checkCAbiResolveCases(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    contract: std.json.Value,
) !void {
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
        const releases_published = switch (case_obj.get("releases_published") orelse continue) {
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

        const skip = envTruthyFromObject(env_obj, "PANCAKE_SKIP_DOWNLOAD");
        const download = envTruthyFromObject(env_obj, "PANCAKE_DOWNLOAD");
        const got_fetch = if (releases_published) !skip else download;
        if (got_fetch != want_fetch) {
            try appendViolation(gpa, violations, "{s}: case `{s}` want_fetch mismatch", .{ cases_path, id });
        }

        const base = blk: {
            if (env_obj) |o| {
                if (o.get("PANCAKE_RELEASE_BASE_URL")) |v| {
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
    const resolve_ports = c_abi_binding_loaders ++ [_][]const u8{"tools/c-abi/fetch-c-abi.sh"};
    for (resolve_ports) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch continue;
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "releases_published") == null) {
            try appendViolation(gpa, violations, "{s}: resolve port must honor releases_published", .{path});
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

/// Collect every C ABI function declaration in a generated header: a `pancake_`
/// identifier at an identifier boundary directly followed by `(`, found after
/// blanking `/* */` comments so a prose mention of a name is never mistaken for
/// a prototype. Matching on that call shape rather than on a set of allowed
/// return-type spellings keeps a new export visible whatever its return type is,
/// whether `uint64_t`, a `double`, or a pointer. Each appended `name` slice
/// references `contents`, so the caller must keep it alive; callers also read
/// the declaration count, and a zero there means the scanner has stopped
/// matching the header.
fn collectHeaderDeclarations(
    gpa: std.mem.Allocator,
    contents: []const u8,
    out: *std.ArrayList(HeaderDecl),
) !void {
    const text = try gpa.dupe(u8, contents);
    defer gpa.free(text);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "/*")) |open| {
        const close = std.mem.indexOfPos(u8, text, open + 2, "*/") orelse break;
        @memset(text[open .. close + 2], ' ');
        i = close + 2;
    }
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, "pancake_")) |start| {
        var end = start;
        while (end < text.len and isIdentChar(text[end])) end += 1;
        search = end;
        if (start > 0 and isIdentChar(text[start - 1])) continue;
        if (end >= text.len or text[end] != '(') continue;
        // Blanking preserves byte length, so offsets index the original.
        try out.append(gpa, .{ .name = contents[start..end], .offset = start });
    }
}

/// The 0-based line index of `offset` within `contents` (the newline count
/// before it), so a declaration found by offset can be tied to its doc comment.
fn lineIndexOfOffset(contents: []const u8, offset: usize) usize {
    return std.mem.count(u8, contents[0..offset], "\n");
}

fn isIdentChar(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => false,
    };
}

/// One exported function declaration found in a generated header: its name and
/// the byte offset of that name in the header text (so a caller can locate the
/// declaration's line for its doc comment).
const HeaderDecl = struct { name: []const u8, offset: usize };

/// The C-ABI find/download cascade is one contract (`bindings/c-abi-resolve.json`)
/// shipped inside every binding package (ADR-0077). Bindings download with
/// language-native code; `tools/c-abi/fetch-c-abi.sh` is an operator CLI only.
const c_abi_binding_loaders = [_][]const u8{
    "bindings/rust/build.rs",
    "bindings/python/pancake/_lib_resolve.py",
    "bindings/ts/stack/internal/ffi/load.ts",
    "bindings/racket/private/lib-resolve.rkt",
};

/// `_release` is the only C ABI verb that frees a handle: a `*_free` export
/// is rejected outright, and a `*_close` must document that it does not free.
/// The endpoint
/// surfaces converged on that law — every handle frees through exactly one
/// `pancake_*_release`, and a `pancake_*_close` is a shutdown lever that
/// leaves the handle alive — so this holds it in the generated headers:
/// every `*_close` declaration must carry a doc comment that says
/// "without releasing" and never claims to free. A future netlayer that
/// reintroduces a freeing close fails the gate instead of shipping the
/// ambiguity to a C consumer.
/// The generated headers the C-ABI vocabulary checks below hold — every
/// exporting archive, one list, so a new archive cannot join some checks and
/// silently miss others.
const abi_vocabulary_headers = [_][]const u8{
    "include/pancake_ocapn.h",
    "include/pancake_driver.h",
    "include/pancake_net_transport_tcp.h",
    "include/pancake_net_transport_inproc.h",
    "include/pancake_net_transport_iroh.h",
    "include/pancake_net_transport_webrtc.h",
};

const doc_c_abi_header_paths = [_][]const u8{
    "include/pancake_ocapn.h",
    "include/pancake_driver.h",
    "include/pancake_net_transport_tcp.h",
    "include/pancake_net_transport_inproc.h",
    "include/pancake_net_transport_iroh.h",
    "include/pancake_net_transport_webrtc.h",
    "transports/iroh/include/pancake_iroh_sidecar.h",
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

/// CapTP C product is `pancake_host_*` only: the demoted `pancake_node_*`
/// projection must not return in generated headers or binding FFI maps.
pub fn checkDeletedNodeCProjection(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const banned = "pancake_node_";
    const paths = [_][]const u8{
        "include/pancake_ocapn.h",
        "include/pancake_driver.h",
        "bindings/ts/stack/internal/ffi/ocapn.ts",
        "bindings/python/pancake/_ffi_ocapn.py",
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
            try appendViolation(gpa, violations, "{s}: contains `{s}` — CapTP C product is pancake_host_* only; the demoted node waist must not return", .{ path, banned });
        }
    }
    // The companion header itself must stay deleted.
    if (root.access(io, "include/pancake_ocapn_node.h", .{})) |_| {
        try appendViolation(gpa, violations, "include/pancake_ocapn_node.h: file must stay deleted (demoted node waist)", .{});
    } else |_| {}
}

/// Every `pancake_[a-z0-9_]+` token inside backticks in docs and site content
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
        try collectPancakeSymbols(contents, &symbols);
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

fn collectPancakeSymbols(
    contents: []const u8,
    out: *std.StringHashMap(void),
) !void {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, contents, search, "pancake_")) |start| {
        var end = start + "pancake_".len;
        while (end < contents.len and isPancakeIdentChar(contents[end])) end += 1;
        search = end;
        if (start > 0 and isIdentChar(contents[start - 1])) continue;
        const name = contents[start..end];
        if (!out.contains(name)) try out.put(name, {});
    }
}

fn pancakeSymbolFamilyExists(prefix: []const u8, symbols: *const std.StringHashMap(void)) bool {
    var it = symbols.keyIterator();
    while (it.next()) |key| {
        if (std.mem.startsWith(u8, key.*, prefix)) return true;
    }
    return false;
}

fn docCAbiTokenValid(token: []const u8, symbols: *const std.StringHashMap(void)) bool {
    if (token.len < "pancake_".len) return false;

    if (std.mem.eql(u8, token, "pancake_*_release")) {
        var it = symbols.keyIterator();
        while (it.next()) |key| {
            if (!std.mem.startsWith(u8, key.*, "pancake_")) continue;
            if (!std.mem.endsWith(u8, key.*, "_release")) continue;
            return true;
        }
        return false;
    }

    if (std.mem.endsWith(u8, token, "*")) {
        const prefix = token[0 .. token.len - 1];
        if (std.mem.endsWith(u8, prefix, "_")) {
            return pancakeSymbolFamilyExists(prefix, symbols);
        }
        var it = symbols.keyIterator();
        while (it.next()) |key| {
            if (std.mem.startsWith(u8, key.*, prefix)) return true;
        }
        return false;
    }

    if (std.mem.endsWith(u8, token, "_")) {
        return pancakeSymbolFamilyExists(token, symbols);
    }

    if (symbols.contains(token)) return true;

    return false;
}

fn extractPancakeCiteToken(span: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, span, "pancake_")) return null;
    if (std.mem.indexOfAny(u8, span, "<>") != null) return null;
    if (std.mem.endsWith(u8, span, ".h") or std.mem.endsWith(u8, span, ".wasm")) return null;
    var end: usize = "pancake_".len;
    while (end < span.len and isPancakeIdentChar(span[end])) end += 1;
    if (end < span.len and span[end] == '*') end += 1;
    if (end == "pancake_".len) return null;
    return span[0..end];
}

fn scanDocCAbiCitesInContents(
    gpa: std.mem.Allocator,
    path: []const u8,
    contents: []const u8,
    symbols: *const std.StringHashMap(void),
    violations: *std.ArrayList([]const u8),
) !void {
    var rest = contents;
    while (std.mem.indexOf(u8, rest, "`pancake_")) |start| {
        const after_tick = rest[start + 1 ..];
        const close = std.mem.indexOfScalar(u8, after_tick, '`') orelse break;
        const span = after_tick[0..close];
        rest = after_tick[close + 1 ..];
        const token = extractPancakeCiteToken(span) orelse continue;
        if (!docCAbiTokenValid(token, symbols)) {
            try appendViolation(gpa, violations, "{s}: backtick cite `{s}` has no matching symbol in include/*.h (doc C-ABI cite check)", .{ path, token });
        }
    }
}

fn isPancakeIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
}

/// HostAction / Node.Action / C embedder_pump arm parity: a seventh action kind
/// must fail the build rather than silently drop in one of three switch spines.
pub fn checkHostActionArmLockstep(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const header_path = "include/pancake_driver.h";
    const header = root.readFileAlloc(io, header_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for HostAction arm lockstep with {s}", .{ header_path, @errorName(err) });
        return;
    };
    defer gpa.free(header);

    var action_names: std.ArrayList([]const u8) = .empty;
    defer action_names.deinit(gpa);
    const needle = "#define PANCAKE_HOST_ACTION_";
    var rest = header;
    while (std.mem.indexOf(u8, rest, needle)) |start| {
        const after = rest[start + needle.len ..];
        const name_end = std.mem.indexOfAny(u8, after, " \t\r\n") orelse after.len;
        const name = after[0..name_end];
        if (name.len != 0) try action_names.append(gpa, name);
        rest = after[name_end..];
    }
    if (action_names.items.len == 0) {
        try appendViolation(gpa, violations, "{s}: no PANCAKE_HOST_ACTION_* for HostAction arm lockstep", .{header_path});
        return;
    }

    const zig_action = root.readFileAlloc(io, "src/driver/core/host_action.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/driver/core/host_action.zig: failed to read for HostAction arm lockstep with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(zig_action);
    // Zig HostAction tags (snake) must match header constants (SCREAMING).
    const zig_tags = [_][]const u8{ "dial", "flush", "close", "need_gift_id", "settled", "failed" };
    if (action_names.items.len != zig_tags.len) {
        try appendViolation(gpa, violations, "HostAction arm lockstep: header has {d} PANCAKE_HOST_ACTION_* but Zig HostAction expects {d} tags", .{ action_names.items.len, zig_tags.len });
    }
    for (zig_tags) |tag| {
        if (std.mem.indexOf(u8, zig_action, tag) == null) {
            try appendViolation(gpa, violations, "src/driver/core/host_action.zig: missing HostAction tag `{s}`", .{tag});
        }
    }

    const embedder = root.readFileAlloc(io, "src/c_abi/driver/embedder_pump.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/c_abi/driver/embedder_pump.zig: failed to read for HostAction arm lockstep with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(embedder);
    for (action_names.items) |name| {
        var token_buf: [96]u8 = undefined;
        const token = std.fmt.bufPrint(&token_buf, "PANCAKE_HOST_ACTION_{s}", .{name}) catch {
            try appendViolation(gpa, violations, "HostAction arm lockstep: action name `{s}` too long", .{name});
            continue;
        };
        if (std.mem.indexOf(u8, embedder, token) == null) {
            // SETTLE and FAIL share the complete arm in embedder_pump.
            if (std.mem.eql(u8, name, "SETTLE") or std.mem.eql(u8, name, "FAIL")) {
                if (std.mem.indexOf(u8, embedder, "PANCAKE_HOST_ACTION_SETTLE") != null and
                    std.mem.indexOf(u8, embedder, "PANCAKE_HOST_ACTION_FAIL") != null) continue;
            }
            try appendViolation(gpa, violations, "src/c_abi/driver/embedder_pump.zig: missing drain arm for `{s}`", .{token});
        }
    }

    // Node.Action tags must each have an execNodeAction arm (settle/fail stay
    // in-process on the vat; they are not HostAction variants).
    const node_src = root.readFileAlloc(io, "src/ocapn/engine/node.zig", gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: failed to read for Node.Action parity with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(node_src);
    const pump_src = root.readFileAlloc(io, "src/driver/core/host_pump.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/driver/core/host_pump.zig: failed to read for Node.Action parity with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(pump_src);
    const node_tags = [_][]const u8{ "dial", "flush", "settle", "fail", "need_gift_id" };
    const action_union = "pub const Action = union(enum)";
    const action_at = std.mem.indexOf(u8, node_src, action_union) orelse {
        try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: Node.Action union missing", .{});
        return;
    };
    const action_body = node_src[action_at..];
    const exec_at = std.mem.indexOf(u8, pump_src, "fn execNodeAction") orelse {
        try appendViolation(gpa, violations, "src/driver/core/host_pump.zig: execNodeAction missing", .{});
        return;
    };
    const exec_body = pump_src[exec_at..];
    const exec_end = std.mem.indexOf(u8, exec_body, "\n}") orelse exec_body.len;
    const exec = exec_body[0..exec_end];
    for (node_tags) |tag| {
        var arm_buf: [64]u8 = undefined;
        const arm = std.fmt.bufPrint(&arm_buf, ".{s} =>", .{tag}) catch unreachable;
        if (std.mem.indexOf(u8, action_body, tag) == null) {
            try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: Node.Action missing tag `{s}`", .{tag});
        }
        if (std.mem.indexOf(u8, exec, arm) == null) {
            try appendViolation(gpa, violations, "src/driver/core/host_pump.zig: execNodeAction missing arm for Node.Action.{s}", .{tag});
        }
    }
}

/// ADR-0009 introducing-session promise proxy: production callers must stay
/// wired on Node/Host, and the retired unfinished Host needle must not return.
/// One settlement spine: `applyRelayedResolution`. The deleted Peer queue
/// (`relayResolution` / `drainRelayedResolutions`) must not return under src/.
pub fn checkUnwiredHostPluginApis(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const retired_needle = "Host does not yet call `Peer.relayResolution`";
    const boundaries = root.readFileAlloc(io, "docs/boundaries.md", gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "docs/boundaries.md: failed to read for host-plugin check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(boundaries);
    if (std.mem.indexOf(u8, boundaries, retired_needle) != null) {
        try appendViolation(gpa, violations, "docs/boundaries.md: unfinished needle `{s}` must stay retired — introducing-session promise proxy is live on Node/Host", .{retired_needle});
    }

    const rows = [_]struct { call_needle: []const u8, def_path: []const u8 }{
        .{ .call_needle = ".applyRelayedResolution(", .def_path = "src/ocapn/engine/mod.zig" },
        .{ .call_needle = ".installThirdPartyImport(", .def_path = "src/ocapn/session/imported_promise.zig" },
    };
    for (rows) |row| {
        if (!try srcHasCallOutsideDef(io, gpa, root, row.call_needle, row.def_path)) {
            try appendViolation(gpa, violations, "host-plugin API `{s}` lost its production caller under src/ — Node promise proxy must keep calling it", .{row.call_needle});
        }
    }

    // Deleted queue spine must not reappear under production src/.
    if (try srcHasCallOutsideDef(io, gpa, root, ".relayResolution(", "src/ocapn/engine/mod.zig")) {
        try appendViolation(gpa, violations, "deleted Peer.relayResolution reappeared under src/ — settle via applyRelayedResolution only", .{});
    }
    if (try srcHasCallOutsideDef(io, gpa, root, "drainRelayedResolutions(", "src/ocapn/engine/cross_peer.zig")) {
        try appendViolation(gpa, violations, "deleted drainRelayedResolutions reappeared under src/ — settle via applyRelayedResolution only", .{});
    }
    // Relayed path moves; a public/production resolution deep-clone must not return.
    const clone_ban_paths = [_]struct { path: []const u8, why: []const u8 }{
        .{ .path = "src/ocapn/model/owned.zig", .why = "cloneResolution must stay deleted — relayed settlement moves (memory.md)" },
        .{ .path = "src/ocapn/model/mod.zig", .why = "cloneResolution export must stay deleted — relayed settlement moves (memory.md)" },
        .{ .path = "src/ocapn/engine/node.zig", .why = "public cloneResolution must stay deleted — proxy uses materializeResolutionForStore (memory.md)" },
    };
    for (clone_ban_paths) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for cloneResolution ban with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "cloneResolution") != null) {
            try appendViolation(gpa, violations, "{s}: `{s}`", .{ row.path, row.why });
        }
    }
    try expectFileContains(io, gpa, root, violations, "src/ocapn/model/owned.zig", &.{
        "materializeResolutionForStore",
    });
    try expectFileContains(io, gpa, root, violations, "src/ocapn/engine/node.zig", &.{
        "proxyForeignPromiseFulfill",
        "consumeProxyListenerFire",
        "claimProxyListenerFire",
        "isProxyHomeListener",
        "materializeResolutionForStore",
        "proxy_by_listener",
        "PendingDialView",
        "pub fn pendingDial",
        "pending_dial_by_identity",
        "stagePendingDial",
        "freePendingDialShell",
        "freeDialParts",
        "freeDialPart",
        "unparseable exporter locator",
        "dial: struct { pending: PendingId }",
        "applyRelayedResolution",
        "installThirdPartyImport",
        "session_not_open",
    });
    // Ticket-only dial action: dial parts live on the pending row alone.
    if (try fileContains(io, gpa, root, "src/ocapn/engine/node.zig", "action_locator")) {
        try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: action_locator must stay deleted — pending row owns dial parts", .{});
    }
    if (try fileContains(io, gpa, root, "src/ocapn/engine/node.zig", "allocator.dupe(u8, exporter_locator)")) {
        try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: acceptGive must not dupe the verbatim exporter URI — pending row owns parts only", .{});
    }
    if (try fileContains(io, gpa, root, "src/ocapn/engine/node.zig", "dial: struct { pending: PendingId, locator:")) {
        try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: Action.dial must not carry locator — use pendingDial", .{});
    }
    // Zig dual borrow API must stay deleted — one pendingDial view.
    for ([_][]const u8{ "pub fn pendingDialLocator", "pub fn pendingDialParts", "PendingDialParts" }) |needle| {
        if (try fileContains(io, gpa, root, "src/ocapn/engine/node.zig", needle)) {
            try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: `{s}` must stay deleted — use pendingDial / PendingDialView", .{needle});
        }
    }
    // Named materialize is for the proxy fire owner only — not a free fan-out API.
    if (try srcHasCallOutsideAllowlist(io, gpa, root, "materializeResolutionForStore(", &.{
        "src/ocapn/engine/node.zig",
        "src/ocapn/model/owned.zig",
    })) {
        try appendViolation(gpa, violations, "materializeResolutionForStore called outside node.zig — proxy fire path only (memory.md)", .{});
    }
    // Withdraw moves; pre-row clone must not return on the settle path.
    if (try fileContains(io, gpa, root, "src/ocapn/engine/bootstrap.zig", "cloneReference")) {
        try appendViolation(gpa, violations, "src/ocapn/engine/bootstrap.zig: cloneReference must stay deleted — applyWithdraw moves verbatim caps", .{});
    }
    // Enliven: session owns swissnum; Host bridge keys on answer only.
    for ([_][]const u8{
        "mintEnlivenVow(session, swissnum,",
        "mintEnlivenVow(self, session, swissnum,",
        ".swissnum = owned",
        "swissnum: []const u8,\n    vow_id",
        "swissnum: []u8,\n    vow_id",
    }) |needle| {
        if (try fileContains(io, gpa, root, "src/driver/core/host.zig", needle)) {
            try appendViolation(gpa, violations, "src/driver/core/host.zig: EnlivenListener/mintEnlivenVow must not own swissnum — session pending row owns it", .{});
            break;
        }
    }
    // Cap'n Proto set encode-once: deleted 2N helpers must not return.
    for ([_][]const u8{ "canonicalSetOrder", "encodeArgumentKey" }) |needle| {
        if (try fileContains(io, gpa, root, "src/ocapn/codec/capnp/encode.zig", needle)) {
            try appendViolation(gpa, violations, "src/ocapn/codec/capnp/encode.zig: `{s}` must stay deleted — use encodeArgumentSetList", .{needle});
        }
    }
    try expectFileContains(io, gpa, root, violations, "src/ocapn/codec/capnp/encode.zig", &.{
        "encodeArgumentSetList",
    });
    try expectFileContains(io, gpa, root, violations, "src/driver/core/host.zig", &.{
        "isProxyHomeListener",
        "claimProxyListenerFire",
        "pendingEnlivenSwissnum",
    });
    try expectFileContains(io, gpa, root, violations, "test/engine/relay_resolution_test.zig", &.{
        "applyRelayedResolution",
        "installThirdPartyImport",
        "desc:export",
    });
    try expectFileContains(io, gpa, root, violations, "test/all_test.zig", &.{
        "relay_resolution_test.zig",
        "equality_test.zig",
    });
    try expectFileContains(io, gpa, root, violations, "test/model/equality_test.zig", &.{
        "view equality and hash agree with the owned spine",
    });
    try expectFileContains(io, gpa, root, violations, "test/engine/node_test.zig", &.{
        "proxyForeignPromiseFulfill",
        "consumeProxyListenerFire",
        "session_not_open",
        "multi-introduce",
    });
    // Ticket-only HostAction.dial: dialActionFields / action-carried locator
    // must stay deleted (pending row owns dial parts; memory.md).
    if (try fileContains(io, gpa, root, "src/driver/core/host_pump.zig", "fn dialActionFields")) {
        try appendViolation(gpa, violations, "src/driver/core/host_pump.zig: dialActionFields must stay deleted — ticket-only HostAction.dial", .{});
    }
    if (try fileContains(io, gpa, root, "src/driver/core/host_action.zig", "locator: []const u8")) {
        try appendViolation(gpa, violations, "src/driver/core/host_action.zig: HostAction.dial must not carry locator — use pendingDial", .{});
    }
    if (try fileContains(io, gpa, root, "src/driver/core/host_action.zig", "pancake_host_pending_dial_*")) {
        try appendViolation(gpa, violations, "src/driver/core/host_action.zig: stale pending_dial_* plural — use pancake_host_pending_dial", .{});
    }
    try expectFileContains(io, gpa, root, violations, "src/driver/core/host.zig", &.{
        "pub fn pendingDial",
        "PendingDialView",
    });
    try expectFileContains(io, gpa, root, violations, "src/c_abi/driver/host.zig", &.{
        "pancake_host_pending_dial",
        "PancakePendingDial",
        "inst.core.pendingDial",
    });
    try expectFileContains(io, gpa, root, violations, "src/c_abi/driver/mod.zig", &.{
        "pub const PancakePendingDial",
    });
    // Dual C pending-dial exports must stay deleted — one struct view.
    for ([_][]const u8{ "pancake_host_pending_dial_locator", "pancake_host_pending_dial_parts" }) |needle| {
        if (try fileContains(io, gpa, root, "src/c_abi/driver/host.zig", needle)) {
            try appendViolation(gpa, violations, "src/c_abi/driver/host.zig: `{s}` must stay deleted — use pancake_host_pending_dial", .{needle});
        }
        if (try fileContains(io, gpa, root, "include/pancake_driver.h", needle)) {
            try appendViolation(gpa, violations, "include/pancake_driver.h: `{s}` must stay deleted — use pancake_host_pending_dial", .{needle});
        }
    }
    // Redeem dial must not re-parse the pending URI on Host/Bridge.
    if (try fileContains(io, gpa, root, "src/driver/core/host_pump.zig", "dialDesignatorForReuse")) {
        try appendViolation(gpa, violations, "src/driver/core/host_pump.zig: dialDesignatorForReuse must stay deleted — pendingDial owns the designator", .{});
    }
    if (try fileContains(io, gpa, root, "src/driver/bridge.zig", "parsePeer(bridge.allocator")) {
        try appendViolation(gpa, violations, "src/driver/bridge.zig: Exec.dial must not parsePeer — use pendingDial", .{});
    }
    try expectFileContains(io, gpa, root, violations, "src/driver/bridge.zig", &.{
        "OutboundConnect",
        "pending_connects",
        "connectOutbound",
        ".{ .redeem = d.ticket }",
        // Ticket-only redeem arm — app_dial alone owns connect-window string copies.
        "redeem: engine.Node.PendingId",
        "app_dial: struct { transport: []u8, designator: []u8 }",
    });
    if (try fileContains(io, gpa, root, "src/driver/bridge.zig", "const PendingDial = struct")) {
        try appendViolation(gpa, violations, "src/driver/bridge.zig: PendingDial must stay deleted — use OutboundConnect", .{});
    }
    for ([_][]const u8{ "DialKind", "submitPendingDial", "submitRedeemDial", "pending_dials:", "pending dial parts missing" }) |needle| {
        if (try fileContains(io, gpa, root, "src/driver/bridge.zig", needle)) {
            try appendViolation(gpa, violations, "src/driver/bridge.zig: `{s}` must stay deleted — OutboundConnect + acceptGive own the invariant", .{needle});
        }
    }
    // (The zig-fmt-pinned `const pieces: struct { … } = switch (pending)`
    // needle is retired: it could never re-match after a rewrap, and the
    // OutboundConnect require-set plus the DialKind/submitPendingDial bans
    // above carry the one-adopt-switch invariant.)
    if (try fileContains(io, gpa, root, "tools/gen/header/driver.zig", "Empty transport/designator means")) {
        try appendViolation(gpa, violations, "tools/gen/header/driver.zig: empty-parts-as-unparseable prose must stay deleted — acceptGive fails unparseable closed", .{});
    }
    try expectFileContains(io, gpa, root, violations, "src/ocapn/engine/node.zig", &.{
        "UnparseableExporterLocator",
    });
    // exporterDialed must free dial parts through freeDialPart (empty hint sentinel).
    for ([_][]const u8{
        "allocator.free(entry.transport)",
        "allocator.free(entry.designator)",
        "allocator.free(entry.direct_addresses_hint)",
    }) |raw_free| {
        if (try fileContains(io, gpa, root, "src/ocapn/engine/node.zig", raw_free)) {
            try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: exporterDialed must not raw-free dial parts ({s}) — use freePendingDialShell", .{raw_free});
        }
    }
    // Host dial harness must borrow the dial view, not re-parse the locator.
    if (try fileContains(io, gpa, root, "test/driver/core_host_test.zig", "parsePeer(allocator, pending)")) {
        try appendViolation(gpa, violations, "test/driver/core_host_test.zig: dial arm must use pendingDial, not parsePeer", .{});
    }
    // Session inspect walks live in inspect.zig; Session method forwards stay deleted.
    try expectFileContains(io, gpa, root, violations, "src/ocapn/session/inspect.zig", &.{
        "forEachExport",
        "ExportView",
    });
    if (try fileContains(io, gpa, root, "src/ocapn/session/mod.zig", "pub fn forEachExport")) {
        try appendViolation(gpa, violations, "src/ocapn/session/mod.zig: Session.forEachExport must stay deleted — use inspect.forEachExport", .{});
    }
    try expectFileContains(io, gpa, root, violations, "test/all_test.zig", &.{
        "inspect_test.zig",
    });
    try expectFileContains(io, gpa, root, violations, "test/session/inspect_test.zig", &.{
        "session inspect walks export and import rows",
        "inspect.forEachExport",
    });
    // Redeem path must open from pendingDial parts, not re-parse parked.locator.
    if (try fileContains(io, gpa, root, "test/driver/core_host_test.zig", "parsePeer(allocator, parked.locator)")) {
        try appendViolation(gpa, violations, "test/driver/core_host_test.zig: redeem must use pendingDial parts, not parsePeer(parked.locator)", .{});
    }
    // O(1) crossed-hellos tiebreak: must use dialed_by_designator, not a full
    // sessions scan (smell-annihilation / ADR-0012 scale).
    const host_src = root.readFileAlloc(io, "src/driver/core/host.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/driver/core/host.zig: failed to read for tiebreak index check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(host_src);
    if (std.mem.indexOf(u8, host_src, "fn tiebreakInbound")) |fn_start| {
        const body = host_src[fn_start..];
        const body_end = std.mem.indexOf(u8, body, "\n};") orelse body.len;
        const tiebreak = body[0..body_end];
        if (std.mem.indexOf(u8, tiebreak, "valueIterator") != null) {
            try appendViolation(gpa, violations, "src/driver/core/host.zig: tiebreakInbound must not scan sessions.valueIterator — use dialed_by_designator", .{});
        }
        if (std.mem.indexOf(u8, tiebreak, "dialed_by_designator") == null) {
            try appendViolation(gpa, violations, "src/driver/core/host.zig: tiebreakInbound must consult dialed_by_designator", .{});
        }
    } else {
        try appendViolation(gpa, violations, "src/driver/core/host.zig: tiebreakInbound missing", .{});
    }
}

/// `host_pump.zig` is Host-private pump mechanics: only `src/driver/core/host.zig`
/// may import it. Cross-file `pub fn` stays for Zig module visibility; this gate
/// is what keeps the boundary from rotting into a second public API.
pub fn checkHostPumpImportGate(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const allowed = "src/driver/core/host.zig";
    const needle = "@import(\"host_pump.zig\")";
    var dir = root.openDir(io, "src", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "src: failed to open for host_pump import gate with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(path);
        if (std.mem.eql(u8, path, allowed)) continue;
        if (std.mem.eql(u8, path, "src/driver/core/host_pump.zig")) continue;
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for host_pump import gate with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, needle) != null) {
            try appendViolation(gpa, violations, "{s}: imports host_pump.zig — only {s} may (Host private pump)", .{ path, allowed });
        }
    }
}

/// ADR names belong in docs and comments, never in strings that can reach a
/// panic message, CapTP abort text, log line, or other runtime surface.
pub fn checkNoAdrInRuntimeStrings(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const roots = [_][]const u8{ "src", "interop" };
    for (roots) |rel| {
        var dir = root.openDir(io, rel, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for ADR-runtime-string check with {s}", .{ rel, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, entry.path });
            defer gpa.free(path);
            const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for ADR-runtime-string check with {s}", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            var line_no: usize = 1;
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |line| : (line_no += 1) {
                if (zigLineHasAdrInStringLiteral(line)) {
                    try appendViolation(gpa, violations, "{s}:{d}: ADR citation in a string literal — keep ADR names in comments/docs, not panic/abort/log text", .{ path, line_no });
                }
            }
        }
    }
}

/// Like `srcHasCallOutsideDef`, but allows a small set of definition/call sites.
fn srcHasCallOutsideAllowlist(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    call_needle: []const u8,
    allow: []const []const u8,
) !bool {
    var dir = root.openDir(io, "src", .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(path);
        var allowed = false;
        for (allow) |a| {
            if (std.mem.eql(u8, path, a)) {
                allowed = true;
                break;
            }
        }
        if (allowed) continue;
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch continue;
        defer gpa.free(contents);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "//")) continue;
            if (std.mem.indexOf(u8, line, call_needle) != null) return true;
        }
    }
    return false;
}

fn srcHasCallOutsideDef(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    call_needle: []const u8,
    def_path: []const u8,
) !bool {
    var dir = root.openDir(io, "src", .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(path);
        if (std.mem.eql(u8, path, def_path)) continue;
        if (std.mem.eql(u8, path, "src/ocapn/session/mod.zig") and
            std.mem.eql(u8, call_needle, ".installThirdPartyImport("))
            continue;
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch continue;
        defer gpa.free(contents);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "//")) continue;
            if (std.mem.indexOf(u8, line, call_needle) != null) return true;
        }
    }
    return false;
}

/// True when a double-quoted Zig string literal on `line` contains `ADR-`.
/// Line comments (`//`) outside strings are ignored. Multiline strings and
/// character literals are out of scope (ADR citations do not live there).
fn zigLineHasAdrInStringLiteral(line: []const u8) bool {
    var i: usize = 0;
    var in_string = false;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (!in_string) {
            if (c == '/' and i + 1 < line.len and line[i + 1] == '/') return false;
            if (c == '"') {
                in_string = true;
            }
            continue;
        }
        if (c == '\\') {
            i += 1; // skip escaped byte
            continue;
        }
        if (c == '"') {
            in_string = false;
            continue;
        }
        if (c == 'A' and i + 4 <= line.len and std.mem.eql(u8, line[i..][0..4], "ADR-")) {
            return true;
        }
    }
    return false;
}

test "zigLineHasAdrInStringLiteral ignores comments and flags string literals" {
    try std.testing.expect(!zigLineHasAdrInStringLiteral("// (ADR-0082) comment only"));
    try std.testing.expect(!zigLineHasAdrInStringLiteral("const x = 1; // (ADR-0001)"));
    try std.testing.expect(zigLineHasAdrInStringLiteral("@panic(\"needs store (ADR-0082)\");"));
    try std.testing.expect(zigLineHasAdrInStringLiteral(".message = \"cap (ADR-0025)\","));
    try std.testing.expect(!zigLineHasAdrInStringLiteral(".message = \"cap exceeded\","));
}

/// A C-ABI entry point that can set the error slot must be able to report that
/// it did.
///
/// The rule is the body, not the name. Thirty `void` exports are genuinely
/// infallible releases and must stay `void`; two others refused from inside a
/// callback, freed nothing, wrote the per-thread diagnostic, and returned
/// `void` anyway — so an embedder that dropped the handle leaked a whole host
/// and the only signal was a slot nobody was told to read. The generated
/// header even documented a code they could not return. "Writes the error slot"
/// is exactly the line between the two groups, and it is greppable.
pub fn checkAbiReturnShape(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "src/c_abi", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "src/c_abi: cannot open it to check return shapes ({s})", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "src/c_abi/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch continue;
        defer gpa.free(contents);

        const opener = "pub export fn ";
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, contents, at, opener)) |hit| {
            at = hit + opener.len;
            var name_end = at;
            while (name_end < contents.len and isIdentChar(contents[name_end])) name_end += 1;
            const name = contents[at..name_end];
            const body_start = std.mem.indexOfScalarPos(u8, contents, name_end, '{') orelse break;
            const signature = contents[name_end..body_start];
            // Only the `void` returns are in question; a code already reports.
            if (std.mem.indexOf(u8, signature, ") void") == null) continue;

            var depth: usize = 0;
            var i = body_start;
            while (i < contents.len) : (i += 1) {
                if (contents[i] == '{') depth += 1;
                if (contents[i] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            const body = contents[body_start..@min(i + 1, contents.len)];
            if (std.mem.indexOf(u8, body, "setLastError") == null) continue;
            try appendViolation(gpa, violations, "{s}: `{s}` returns `void` and writes the error slot, so an embedder cannot see the failure it just recorded. Give it an `i32` code, or stop recording one.", .{ path, name });
        }
    }
}
