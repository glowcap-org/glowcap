//! The hand-kept ABI mirrors: return-shape conventions, per-binding struct
//! pins, and the trace vocabulary, each held to the generated headers so a
//! mirror cannot drift where only a live conversation would notice.

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

/// Three body invariants on every C-ABI entry point, all about failure paths
/// the compiler cannot see.
///
/// First: every status-returning entry point clears its archive-local error
/// slot before validation or effects. Otherwise a cheap refusal that has no
/// richer detail (a null pointer, WOULD_BLOCK, or CLOSED) can make a binding
/// attach an older call's cause to the new result. Clearing at the public seam
/// also means private helpers never own diagnostic freshness.
///
/// Second: an entry point that can set the error slot must be able to report
/// that it did. The rule is the body, not the name. Thirty `void` exports are
/// genuinely infallible releases and must stay `void`; two others refused from
/// inside a callback, freed nothing, wrote the per-thread diagnostic, and
/// returned `void` anyway — so an embedder that dropped the handle leaked a
/// whole host and the only signal was a slot nobody was told to read. The
/// generated header even documented a code they could not return. "Writes the
/// error slot" is exactly the line between the two groups, and it is greppable.
///
/// Third: an `export fn` returns codes, not errors, so an `errdefer` in its
/// body never fires — the cleanup it promises silently leaks on every failure
/// path, and the code compiles green. The driver archive shipped five such
/// bodies in one sitting before a cold read caught them. The fallible half
/// belongs in an error-returning helper with real `errdefer`s; the export maps
/// the error to a code at the boundary.
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
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot be read for the layout-mirror check ({s})", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        const opener = "pub export fn ";
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, contents, at, opener)) |hit| {
            at = hit + opener.len;
            var name_end = at;
            while (name_end < contents.len and shared.isIdentChar(contents[name_end])) name_end += 1;
            const name = contents[at..name_end];
            const body_start = std.mem.indexOfScalarPos(u8, contents, name_end, '{') orelse break;
            const signature = contents[name_end..body_start];

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
            if (std.mem.indexOf(u8, signature, ") i32") != null) {
                const first_statement = std.mem.trimStart(u8, body[1..], " \t\r\n");
                const clears_error = std.mem.startsWith(u8, first_statement, "shared.lastErrorClear();") or
                    std.mem.startsWith(u8, first_statement, "abi.lastErrorClear();") or
                    std.mem.startsWith(u8, first_statement, "c.lastErrorClear();");
                if (!clears_error) {
                    try appendViolation(gpa, violations, "{s}: `{s}` returns a status without clearing its archive-local diagnostic first; an undetailed refusal could inherit an older call's cause", .{ path, name });
                }
            }
            if (std.mem.indexOf(u8, body, "errdefer") != null) {
                try appendViolation(gpa, violations, "{s}: `{s}` is an `export fn`, so its `errdefer` never fires (the function returns codes, not errors) and the cleanup it promises leaks on every failure path. Move the fallible half into an error-returning helper and map the error to a code at the boundary.", .{ path, name });
            }
            // Only the `void` returns are in question below; a code already
            // reports.
            if (std.mem.indexOf(u8, signature, ") void") == null) continue;
            if (std.mem.indexOf(u8, body, "setLastError") == null) continue;
            try appendViolation(gpa, violations, "{s}: `{s}` returns `void` and writes the error slot, so an embedder cannot see the failure it just recorded. Give it an `i32` code, or stop recording one.", .{ path, name });
        }
    }
}

/// The layout-pin family: `tools/gen/binding/ffi_layouts.zig` reflects every C
/// ABI struct's size, offsets, and widths off the real Zig type, and each
/// binding checks its own hand-written mirror against those numbers at load
/// time — Rust in a `const` assert block, Python in `glowcap._pin.pin_struct`,
/// Racket in `pin-layout!`. A mirror that never calls its language's pin is
/// simply not checked, and no load-time pin can report its own absence.
///
/// That is how the trace record drifted: `GlowcapTraceEvent` gained a
/// transport and a session id and turned a byte of provenance into a word,
/// while the Python mirror kept declaring the field set the library had
/// stopped sending. It sat below its module's pin call and no gate could see
/// it. This check reads the canonical per-archive `contract_layouts`
/// manifests directly. Their `archive_contract.layout` rows are projected
/// into bindings; `cOnlyLayout` rows remain fingerprinted without reopening a
/// retired binding surface. For every projected struct a binding declares a
/// mirror of, this requires the pin in the same file.
pub fn checkBindingStructPins(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var abi_types: std.ArrayList([]const u8) = .empty;
    defer {
        for (abi_types.items) |name| gpa.free(name);
        abi_types.deinit(gpa);
    }

    var c_abi_dir = root.openDir(io, "src/c_abi", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "src/c_abi: failed to open canonical layout manifests with {s}", .{@errorName(err)});
        return;
    };
    defer c_abi_dir.close(io);
    var walker = try c_abi_dir.walk(gpa);
    defer walker.deinit();
    const layout_needle = "archive_contract.layout(\"";
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "src/c_abi/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read canonical layout manifest with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, contents, cursor, layout_needle)) |row| {
            const line_end = std.mem.indexOfScalarPos(u8, contents, row, '\n') orelse contents.len;
            const line = contents[row..line_end];
            cursor = line_end;
            const comma = std.mem.indexOf(u8, line, ", ") orelse continue;
            var type_name: []const u8 = line[comma + 2 ..];
            if (std.mem.indexOfScalar(u8, type_name, ')')) |close| type_name = type_name[0..close];
            type_name = std.mem.trim(u8, type_name, " \t\r");
            if (std.mem.lastIndexOfScalar(u8, type_name, '.')) |dot| type_name = type_name[dot + 1 ..];
            if (type_name.len == 0) continue;
            var duplicate = false;
            for (abi_types.items) |known| {
                if (std.mem.eql(u8, known, type_name)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) try abi_types.append(gpa, try gpa.dupe(u8, type_name));
        }
    }
    if (abi_types.items.len == 0) {
        try appendViolation(gpa, violations, "src/c_abi: no binding-projected `archive_contract.layout` rows found; struct mirrors have no canonical inventory", .{});
        return;
    }

    const Language = struct {
        dir: []const u8,
        /// A hand-written mirror module; the `*_gen` siblings are generated.
        prefix: []const u8,
        suffix: []const u8,
        generated_marker: []const u8,
        /// Python declares `_TraceEvent`, dropping the ABI's `Glowcap` prefix;
        /// Racket and Rust keep the full name.
        drops_glowcap_prefix: bool,
        declaration_before: []const u8,
        declaration_after: []const u8,
        pin_before: []const u8,
        pin_after: []const u8,
        pin_verb: []const u8,
    };
    const languages = [_]Language{
        .{
            .dir = "bindings/python/glowcap",
            .prefix = "_ffi_",
            .suffix = ".py",
            .generated_marker = "_gen.py",
            .drops_glowcap_prefix = true,
            .declaration_before = "class _",
            .declaration_after = "(ctypes.Structure)",
            .pin_before = "pin_struct(_",
            .pin_after = ",",
            .pin_verb = "pin_struct call",
        },
        .{
            .dir = "bindings/racket/private",
            .prefix = "ffi-",
            .suffix = ".rkt",
            .generated_marker = "-gen.rkt",
            .drops_glowcap_prefix = false,
            .declaration_before = "(define-cstruct _",
            .declaration_after = "",
            .pin_before = "pin-layout! '_",
            .pin_after = "",
            .pin_verb = "pin-layout! call",
        },
        .{
            .dir = "bindings/rust/src/sys",
            .prefix = "",
            .suffix = ".rs",
            .generated_marker = "_gen.rs",
            .drops_glowcap_prefix = false,
            .declaration_before = "pub struct ",
            .declaration_after = " {",
            .pin_before = "size_of::<",
            .pin_after = ">()",
            .pin_verb = "const assert block",
        },
    };

    for (languages) |lang| {
        var dir = root.openDir(io, lang.dir, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for binding struct-pin check with {s}", .{ lang.dir, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, lang.prefix)) continue;
            if (!std.mem.endsWith(u8, entry.name, lang.suffix)) continue;
            if (std.mem.endsWith(u8, entry.name, lang.generated_marker)) continue;
            const contents = dir.readFileAlloc(io, entry.name, gpa, .limited(4 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}/{s}: failed to read for binding struct-pin check with {s}", .{ lang.dir, entry.name, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            for (abi_types.items) |abi_type| {
                const name = if (lang.drops_glowcap_prefix and std.mem.startsWith(u8, abi_type, "Glowcap"))
                    abi_type["Glowcap".len..]
                else
                    abi_type;
                if (!try mirrorTokenPresent(gpa, contents, lang.declaration_before, name, lang.declaration_after)) continue;
                if (try mirrorTokenPresent(gpa, contents, lang.pin_before, name, lang.pin_after)) continue;
                try appendViolation(
                    gpa,
                    violations,
                    "{s}/{s}: mirrors {s} but never pins it — add the {s} for it, or nothing checks this mirror against the C ABI",
                    .{ lang.dir, entry.name, abi_type, lang.pin_verb },
                );
            }
        }
    }
}

/// Whether `contents` names `name` in the `before`/`after` spelling one
/// binding uses. An empty `after` still requires a word boundary, so
/// `_GlowcapFrame` does not match a longer sibling's declaration.
fn mirrorTokenPresent(
    gpa: std.mem.Allocator,
    contents: []const u8,
    before: []const u8,
    name: []const u8,
    after: []const u8,
) !bool {
    const needle = try std.mem.concat(gpa, u8, &.{ before, name, after });
    defer gpa.free(needle);
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, contents, from, needle)) |at| {
        from = at + 1;
        if (after.len != 0) return true;
        const next = at + needle.len;
        if (next >= contents.len or !shared.isIdentChar(contents[next])) return true;
    }
    return false;
}

/// The trace's CapTP-version vocabulary, held against the protocol's own word.
///
/// A trace is a report about the wire, so it should say what the wire says.
/// The wire word lives in one place, `model.CaptpVersion.wireString`, and
/// the C ABI hands the version to a binding as a `GLOWCAP_CAPTP_*` integer,
/// which carries no spelling at all. So each of the four bindings that shapes
/// the trace JSON has to name the version itself, and four hands naming one
/// fact is exactly how the fact stops being one.
///
/// It already had. Every binding wrote out the Zig enum tags instead of the
/// wire words, and the two that documented the field documented opposite
/// contracts for it: the Rust doc promised the wire spelling beside code that
/// emitted the tag, while the TypeScript doc argued for the tag on the grounds
/// that nothing downstream would have to translate — while the viewer
/// downstream translated. Nothing could see the disagreement, because no gate
/// read more than one of the four at a time.
///
/// This reads the arms of `wireString` and requires every trace module to
/// carry each one, and to carry none of the enum tags in quotes. It is parity
/// against the authority rather than a pinned pair, so adding a version stays
/// a one-line edit in the model — it just cannot be only that.
///
/// The codec word rides the same authority and the same file, with one half of
/// the rule dropped: the enum tags `capnp` and `syrup` *are* the words a trace
/// says, because a handshake spells a codec as a decimal id and there is no
/// other spelling to prefer. So each built-in `model.CodecId` field is required
/// present, and nothing is banned. That asymmetry is the reason both halves
/// live here rather than in one loop: a version has a wire word its tag differs
/// from, and a codec has no wire word at all.
///
/// The rest of the trace record is deliberately not held here. Its remaining
/// shared facts have no single authority to derive from — the four `ocapn.*`
/// kind strings are not a mechanical reading of the three `GLOWCAP_TRACE_*`
/// constants and include one no constant names, and the payload cap is a
/// per-embedder argument to `glowcap_host_set_trace_queue` rather than one
/// number. A check over either could only pin a table, which makes changing
/// them one edit harder rather than one edit safer.
pub fn checkTraceVocabulary(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const authority = "src/ocapn/model/negotiated.zig";
    const source = root.readFileAlloc(io, authority, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read the trace wire-word authority with {s}", .{ authority, @errorName(err) });
        return;
    };
    defer gpa.free(source);

    // `pub fn wireString(self: CaptpVersion) []const u8 {` … `.v1_0 => "1.0",`.
    // The parse lives in `util` because the viewer-side check reads the same
    // switch, and one switch deserves one reader.
    var arms: std.ArrayList(util.CaptpWireArm) = .empty;
    defer arms.deinit(gpa);
    try util.collectCaptpWireArms(gpa, source, &arms);
    if (arms.items.len == 0) {
        try appendViolation(gpa, violations, "{s}: `wireString` gave up no version arms, so the trace-vocabulary check held nothing", .{authority});
        return;
    }

    // `pub const CodecId = enum(u16) {` … `capnp = 0,`. The `_` non-exhaustive
    // member is not a built-in and names no word.
    var codecs: std.ArrayList([]const u8) = .empty;
    defer codecs.deinit(gpa);
    if (std.mem.indexOf(u8, source, "pub const CodecId = enum(u16) {")) |enum_at| {
        const enum_end = std.mem.indexOfPos(u8, source, enum_at, "\n};") orelse source.len;
        var lines = std.mem.splitScalar(u8, source[enum_at..enum_end], '\n');
        _ = lines.next();
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const name = std.mem.trim(u8, line[0..eq], " ");
            if (name.len == 0 or name[0] == '_' or !std.ascii.isLower(name[0])) continue;
            try codecs.append(gpa, name);
        }
    }
    if (codecs.items.len == 0) {
        try appendViolation(gpa, violations, "{s}: `CodecId` gave up no built-in members, so the trace-vocabulary check held nothing for the codec word", .{authority});
        return;
    }

    // Every binding that turns a `GlowcapTraceEvent` into a JSON record.
    const trace_modules = [_][]const u8{
        "bindings/python/glowcap/_trace.py",
        "bindings/racket/private/trace.rkt",
        "bindings/rust/src/trace/projection.rs",
        "bindings/ts/runtime/trace.ts",
    };

    for (trace_modules) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for the trace vocabulary check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        for (codecs.items) |codec| {
            const quoted = try std.mem.concat(gpa, u8, &.{ "\"", codec, "\"" });
            defer gpa.free(quoted);
            if (std.mem.indexOf(u8, contents, quoted) != null) continue;
            try appendViolation(gpa, violations, "{s}: the trace never says {s}, the word `{s}` gives the built-in codec `.{s}`. A session reports the codec it negotiated, so every trace has a word for every one this model ships.", .{ path, quoted, authority, codec });
        }

        for (arms.items) |arm| {
            const wire_quoted = try std.mem.concat(gpa, u8, &.{ "\"", arm.wire, "\"" });
            defer gpa.free(wire_quoted);
            if (std.mem.indexOf(u8, contents, wire_quoted) == null) {
                try appendViolation(gpa, violations, "{s}: the trace never says {s}, the word `{s}` puts on the wire for `.{s}`. A trace reports on the wire, so it reports the wire's spelling.", .{ path, wire_quoted, authority, arm.tag });
            }
            const tag_quoted = try std.mem.concat(gpa, u8, &.{ "\"", arm.tag, "\"" });
            defer gpa.free(tag_quoted);
            if (std.mem.indexOf(u8, contents, tag_quoted) != null) {
                try appendViolation(gpa, violations, "{s}: the trace says {s}, which is the Zig enum tag for this version and not a word any peer ever sends. Say {s} instead, the spelling `{s}` puts on the wire.", .{ path, tag_quoted, arm.wire, authority });
            }
        }
    }
}
