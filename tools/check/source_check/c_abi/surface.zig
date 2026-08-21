//! The boring-surface shape of the generated headers: one `_release` per
//! handle and no other freeing verb, fixed-width parameter vocabulary, the
//! locator-authority split, and every export consumed by a binding.

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
    const allowed_error_families = [_][]const u8{ "", "host", "driver", "tcp", "relay", "inproc", "iroh", "webrtc", "onion" };
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
            try appendViolation(gpa, violations, "C ABI surface (ADR-0059): {s} introduces an error channel for unexpected family `{s}`; the error channels are the ocapn root, host, driver, tcp, relay, inproc, iroh, webrtc, onion", .{ name, family });
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

/// Public C headers are binding-author surfaces. A generator path that glues a
/// declaration terminator to the next doc comment (`;/*`) is still valid C, but
/// it hides a new callable surface from the visual scan that reviews generated
/// ABI diffs. Keep this here, not in a one-off header, so every generated
/// archive header inherits the same readability floor.
pub fn checkCAbiHeaderCommentSeparation(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (abi_vocabulary_headers) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(
                gpa,
                violations,
                "{s}: failed to read for ABI header-comment separation check with {s}",
                .{ path, @errorName(err) },
            );
            continue;
        };
        defer gpa.free(contents);

        var at: usize = 0;
        while (std.mem.indexOfPos(u8, contents, at, ";/*")) |hit| {
            try appendViolation(
                gpa,
                violations,
                "{s}:{d}: public C ABI header joins a declaration and doc comment as `;/*`; emit a newline before the comment",
                .{ path, lineIndexOfOffset(contents, hit) + 1 },
            );
            at = hit + 3;
        }
    }
}

/// A peer locator is location vocabulary; a sturdyref adds authority-bearing
/// swiss bytes and therefore has a distinct handle and release path.
pub fn checkLocatorAuthoritySplit(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try expectFileContains(io, gpa, root, violations, "src/c_abi/ocapn/uri.zig", &.{
        "const PancakeLocator = c.PancakeLocator;",
        "const PancakeSturdyRef = c.PancakeSturdyRef;",
        "pancake_sturdyref_borrow_locator",
        "pancake_sturdyref_swissnum",
        "pancake_sturdyref_release",
    });
    try expectFileContains(io, gpa, root, violations, "src/c_abi/ocapn/uri/ownership.zig", &.{
        "pub const SturdyRefPayload = struct",
        "locator: *LocatorPayload",
        "swissnum: []u8",
    });
    try expectFileContains(io, gpa, root, violations, "include/pancake_ocapn.h", &.{
        "typedef struct PancakeLocator PancakeLocator;",
        "typedef struct PancakeSturdyRef PancakeSturdyRef;",
        "pancake_sturdyref_borrow_locator",
        "pancake_sturdyref_swissnum",
        "pancake_sturdyref_release",
    });
    if (try fileContains(io, gpa, root, "src/c_abi/shared/locator.zig", "swiss")) {
        try appendViolation(gpa, violations, "src/c_abi/shared/locator.zig: PancakeLocatorView must remain peer-location vocabulary and cannot carry sturdyref authority", .{});
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
                while (end < contents.len and shared.isIdentChar(contents[end])) end += 1;
                search = end;
                if (start > 0 and shared.isIdentChar(contents[start - 1])) continue;
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
        while (end < text.len and shared.isIdentChar(text[end])) end += 1;
        search = end;
        if (start > 0 and shared.isIdentChar(text[start - 1])) continue;
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

/// One exported function declaration found in a generated header: its name and
/// the byte offset of that name in the header text (so a caller can locate the
/// declaration's line for its doc comment).
const HeaderDecl = struct { name: []const u8, offset: usize };

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
    "include/pancake_host.h",
    "include/pancake_driver.h",
    "include/pancake_net_transport_tcp.h",
    "include/pancake_net_transport_relay.h",
    "include/pancake_net_transport_inproc.h",
    "include/pancake_net_transport_onion.h",
    "include/pancake_net_transport_iroh.h",
    "include/pancake_net_transport_webrtc.h",
};
