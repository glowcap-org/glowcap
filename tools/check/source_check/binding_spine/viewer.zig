//! The trace-viewer vocabulary: the session-trace words the producers emit,
//! and the viewer's provenance mirror held to them.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const fileContains = util.fileContains;
const containsAsSymbol = util.containsAsSymbol;
const extractBraceBlock = util.extractBraceBlock;

/// The far end of the trace vocabulary: the viewer that reads the schema, and
/// the profile word no Zig declaration owns (ADR-0104).
///
/// `c_abi.checkTraceVocabulary` holds the four producers to the protocol's own
/// words. It stops at the bindings, which leaves two parties to one schema
/// unheld, and this is them.
///
/// **The viewer.** `apps/ocapnviz` declares its own `CAPTP_VERSION_WIRE`, and
/// that is the right shape rather than a copy to collapse: the viewer is a
/// consumer of a wire schema the producers do not own between them, it is a
/// separate Deno scope that links no glowcap package, and its table doubles as
/// the display text a person reads. What it may not do is fall out of step with
/// the words a producer sends, so the same `wireString` arms are required here
/// too. The producers' rule that a quoted enum tag is forbidden deliberately
/// does *not* extend to it: `v1_0` and `next` are the viewer's own document-model
/// identifiers, and its table is keyed by them.
///
/// **The profile.** `a_profile` says which implementation a producer runs. It
/// has no Zig origin to derive from, because "a host behind a glowcap binding
/// is a glowcap host" is a claim about the binding tier rather than a fact the
/// core states, and the C ABI carries nothing like it. So the word is written
/// out at each of the four producers and again at the viewer that reads them,
/// and this check is where that vocabulary is written down once. `"goblins"` is
/// pinned beside `"glowcap"` because the schema is not glowcap's alone: the
/// conformance publisher is a different producer stating a different fact, and
/// requiring each site's own declaration rather than the bare word is what
/// stops the two being collapsed into one.
pub fn checkTraceViewerVocabulary(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const authority = "src/ocapn/model/negotiated.zig";
    const viewer = "apps/ocapnviz/src/schema/topology.ts";
    const provenance_mirror = "apps/ocapnviz/src/schema/session-end.ts";

    if (root.readFileAlloc(io, authority, gpa, .limited(1 << 20))) |source| {
        defer gpa.free(source);
        var arms: std.ArrayList(util.CaptpWireArm) = .empty;
        defer arms.deinit(gpa);
        try util.collectCaptpWireArms(gpa, source, &arms);
        if (arms.items.len == 0) {
            try appendViolation(gpa, violations, "{s}: `wireString` gave up no version arms, so the viewer's vocabulary was held against nothing", .{authority});
        } else if (root.readFileAlloc(io, viewer, gpa, .limited(4 << 20))) |contents| {
            defer gpa.free(contents);
            for (arms.items) |arm| {
                const quoted = try std.mem.concat(gpa, u8, &.{ "\"", arm.wire, "\"" });
                defer gpa.free(quoted);
                if (std.mem.indexOf(u8, contents, quoted) == null) {
                    try appendViolation(gpa, violations, "{s}: the viewer has no word for `.{s}`, which every producer sends as {s} (`{s}`). A version the feed can carry and the viewer cannot read draws as nothing.", .{ viewer, arm.tag, quoted, authority });
                }
            }
        } else |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for the viewer's CapTP vocabulary with {s}", .{ viewer, @errorName(err) });
        }
    } else |err| {
        try appendViolation(gpa, violations, "{s}: failed to read the trace wire-word authority with {s}", .{ authority, @errorName(err) });
    }

    // The whole declaration, not the bare word, so a changed value fails as
    // loudly as a deleted constant.
    const profile_declarations = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/python/glowcap/_trace.py", .needle = "_SELF_PROFILE = \"glowcap\"" },
        .{ .path = "bindings/racket/private/trace.rkt", .needle = "(define self-profile \"glowcap\")" },
        .{ .path = "bindings/rust/src/trace.rs", .needle = "const SELF_PROFILE: &str = \"glowcap\";" },
        .{ .path = "bindings/ts/runtime/trace.ts", .needle = "const SELF_PROFILE = \"glowcap\";" },
        // The viewer reads what producers state, so it carries both words.
        .{ .path = viewer, .needle = "export const GLOWCAP_PROFILE = \"glowcap\";" },
        .{ .path = viewer, .needle = "export const GOBLINS_PROFILE = \"goblins\";" },
        // A different producer stating a different fact. It stays different.
        .{ .path = "conformance/goblins-peer/racket/trace-publish.rkt", .needle = "(define self-profile \"goblins\")" },
    };
    for (profile_declarations) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for the trace profile vocabulary with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, row.needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}`. The schema's `a_profile` vocabulary is pinned in checkTraceViewerVocabulary, because no Zig declaration owns it and a producer and its viewer have to say the same word.", .{ row.path, row.needle });
        }
    }

    // **The provenance verdict.** The viewer mirrors `engine.DurableProvenance`
    // by hand, and until this check it said so itself: a verdict added in Zig
    // was added there by whoever remembered. The failure that costs is not a
    // missing word but a silent one. `attributionForProvenance` maps anything it
    // does not recognize to no attribution, so a third verdict would reach the
    // viewer and draw as "nothing proved this" — a wrong picture rather than an
    // absent feature, and the one outcome nobody reviewing either side would
    // see.
    //
    // Tag-by-tag off the Zig enum rather than by counting, so a rename fails
    // naming both words.
    try checkViewerProvenanceMirror(io, gpa, root, violations, provenance_mirror);
}

/// Hold the viewer's `DurableProvenance` list to the Zig enum it mirrors.
///
/// The Zig side is the authority: `engine.DurableProvenance` derives one
/// session's verdict, and `driver_core.vocab` aliases it so the byte-fed tier,
/// the trace, and the C ABI all read the same one. The viewer is the far end of
/// that chain and links no glowcap package, so a copy is the only shape
/// available; what this refuses is the copy going quiet.
fn checkViewerProvenanceMirror(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    viewer: []const u8,
) !void {
    const authority = "src/ocapn/engine/peer/identity.zig";
    const source = root.readFileAlloc(io, authority, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read the durable-provenance authority with {s}", .{ authority, @errorName(err) });
        return;
    };
    defer gpa.free(source);

    const decl = "pub const DurableProvenance = enum {";
    const decl_at = std.mem.indexOf(u8, source, decl) orelse {
        try appendViolation(gpa, violations, "{s}: no `{s}` to hold the viewer against. Either the enum moved, in which case checkViewerProvenanceMirror follows it, or it is gone and the viewer's mirror should go with it.", .{ authority, decl });
        return;
    };
    const body_start = decl_at + decl.len;
    const body_end = std.mem.indexOfPos(u8, source, body_start, "\n};") orelse {
        try appendViolation(gpa, violations, "{s}: `DurableProvenance` has no closing brace, so its arms were read against nothing", .{authority});
        return;
    };

    const contents = root.readFileAlloc(io, viewer, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for the durable-provenance mirror with {s}", .{ viewer, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    // The viewer's own declaration, not the whole file. Every one of these words
    // is also read somewhere in the module that maps it, so a file-wide search
    // for the bare word is answered by that mention and the check can never
    // fail. This is the profile rows' rule above ("the whole declaration, not
    // the bare word") applied to a list.
    const viewer_decl = "export const DurableProvenance = z.enum([";
    const list_at = std.mem.indexOf(u8, contents, viewer_decl) orelse {
        try appendViolation(gpa, violations, "{s}: no `{s}` to hold against {s}. The mirror is what this check exists for, so a renamed or deleted declaration is the failure rather than a reason to skip.", .{ viewer, viewer_decl, authority });
        return;
    };
    const list_start = list_at + viewer_decl.len;
    const list_end = std.mem.indexOfPos(u8, contents, list_start, "]);") orelse {
        try appendViolation(gpa, violations, "{s}: `DurableProvenance` has no closing `]);`, so its words were read against nothing", .{viewer});
        return;
    };
    const viewer_list = contents[list_start..list_end];

    var arms: usize = 0;
    var lines = std.mem.splitScalar(u8, source[body_start..body_end], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        // Arms only: the enum's prose is doc comments, and a bare `tag,` is
        // what an arm looks like.
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;
        if (!std.mem.endsWith(u8, line, ",")) continue;
        const tag = std.mem.trim(u8, line[0 .. line.len - 1], " \t");
        if (tag.len == 0 or std.mem.indexOfAny(u8, tag, " \t:(){}") != null) continue;
        arms += 1;

        // The viewer writes the wire word, which is the tag with underscores
        // turned into dashes, the same shape the trace carries.
        const wire = try gpa.dupe(u8, tag);
        defer gpa.free(wire);
        for (wire) |*c| {
            if (c.* == '_') c.* = '-';
        }
        const quoted = try std.mem.concat(gpa, u8, &.{ "\"", wire, "\"" });
        defer gpa.free(quoted);
        if (std.mem.indexOf(u8, viewer_list, quoted) == null) {
            try appendViolation(gpa, violations, "{s}: the viewer's `DurableProvenance` has no word for `.{s}`, which {s} declares and the trace can carry as {s}. `attributionForProvenance` answers an unrecognized verdict with no attribution, so this draws as \"nothing proved this\" rather than failing.", .{ viewer, tag, authority, quoted });
        }
    }
    if (arms == 0) {
        try appendViolation(gpa, violations, "{s}: `DurableProvenance` gave up no arms, so the viewer's mirror was held against nothing", .{authority});
    }
}
