//! Documented inventories held to the code: the community-review CI matrix
//! and the fuzz corpus seeds.

const std = @import("std");
const text_match = @import("../text_match.zig");
const violation_log = @import("../violation_log.zig");

const appendViolation = violation_log.appendViolation;

/// The community-review matrix makes direct claims about which live evidence
/// runs in CI. Derive those cells from the executable gate sequence so adding
/// or removing a gate cannot leave a stale "yes" or "no" for reviewers.
pub fn checkCommunityReviewCiMatrix(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const doc_path = "docs/community-review.md";
    const ci_path = ci_inventory_path;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = root.readFileAlloc(io, doc_path, arena, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for CI matrix check with {s}", .{ doc_path, @errorName(err) });
        return;
    };
    const ci = root.readFileAlloc(io, ci_path, arena, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for community-review CI matrix check with {s}", .{ ci_path, @errorName(err) });
        return;
    };

    // One parser of the inventory, shared with the stability area check: two
    // would be two definitions of "runs in CI".
    var running: std.ArrayList([]const u8) = .empty;
    try collectBuildSteps(arena, ci, ci_gate_prefix, &running);

    const header = "| Evidence | CI | Proves | Does not prove |";
    const hit = std.mem.indexOf(u8, doc, header) orelse {
        try appendViolation(gpa, violations, "{s}: the evidence matrix header is gone, so nothing derives the CI column", .{doc_path});
        return;
    };

    var rest = doc[hit + header.len ..];
    var rows: usize = 0;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        const row = rest[0..nl];
        rest = rest[nl + 1 ..];
        if (!std.mem.startsWith(u8, rest, "| ")) {
            if (row.len == 0 or std.mem.startsWith(u8, row, "| ")) continue;
            break;
        }
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = rest[0..line_end];
        if (std.mem.startsWith(u8, line, "| ---")) continue;

        const evidence_end = std.mem.indexOfPos(u8, line, 2, " | ") orelse continue;
        const evidence = line[2..evidence_end];
        const cell_start = evidence_end + 3;
        const cell_end = std.mem.indexOfPos(u8, line, cell_start, " |") orelse continue;
        const cell = std.mem.trim(u8, line[cell_start..cell_end], " \t\r");
        // A cell that is neither is a violation, not a row to skip. Skipping
        // let any row opt out of the derivation by writing `Yes`, `partial`, or
        // `yes*`, and because the skip also stepped over the row count, the
        // empty-table backstop did not notice either.
        if (!std.mem.eql(u8, cell, "yes") and !std.mem.eql(u8, cell, "no")) {
            try appendViolation(gpa, violations, "{s}: evidence row `{s}` has CI cell `{s}`; the column is derived, so it must read exactly `yes` or `no`", .{ doc_path, evidence, cell });
            continue;
        }
        rows += 1;

        // The gates this row stands for: the first `zig build X` its Evidence
        // mentions, or an inline annotation for a row that cannot say it in the
        // cell: one whose step rides inside `check`, one that names a family
        // with a glob.
        //
        // A row that names its own step may only annotate `check`, which is the
        // one aggregate the sequence runs: that is the honest case of "my step
        // is real but rides inside another." Left free, the annotation was a
        // standing opt-out: any row could point at some unrelated step that
        // does run and mint itself a `yes`.
        //
        // What this still cannot know is whether an annotated step is really
        // the one that produces that row's evidence. That is the author's word,
        // and it is taken only where the cell has no word of its own.
        var gates: std.ArrayList([]const u8) = .empty;
        const names_step = std.mem.indexOf(u8, evidence, "`zig build ") != null;
        if (std.mem.indexOf(u8, line, "<!-- ci-gate:")) |ann| blk: {
            const body = line[ann + "<!-- ci-gate:".len ..];
            const body_end = std.mem.indexOf(u8, body, "-->") orelse body.len;
            if (names_step and !std.mem.eql(u8, std.mem.trim(u8, body[0..body_end], " \t\r"), "check")) {
                try appendViolation(gpa, violations, "{s}: evidence row `{s}` names its own `zig build` step and annotates a different one. Only `check` may override, for a step that rides inside it.", .{ doc_path, evidence });
                break :blk;
            }
            const ann_start = ann + "<!-- ci-gate:".len;
            const ann_end = std.mem.indexOfPos(u8, line, ann_start, "-->") orelse line.len;
            var it = std.mem.splitScalar(u8, line[ann_start..ann_end], ',');
            while (it.next()) |name| {
                const trimmed = std.mem.trim(u8, name, " \t\r");
                if (trimmed.len != 0) try gates.append(arena, trimmed);
            }
        }
        if (gates.items.len == 0 and names_step) {
            // No usable annotation: derive from the step the cell names.
            const span = std.mem.indexOf(u8, evidence, "`zig build ").?;
            const name_start = span + "`zig build ".len;
            var stop = name_start;
            while (stop < evidence.len and evidence[stop] != '`') stop += 1;
            try gates.append(arena, std.mem.trim(u8, evidence[name_start..stop], " \t\r"));
        }
        if (gates.items.len == 0) {
            try appendViolation(gpa, violations, "{s}: evidence row `{s}` names no `zig build` step and carries no `<!-- ci-gate: … -->`, so its CI cell derives from nothing", .{ doc_path, evidence });
            continue;
        }

        var expected = true;
        for (gates.items) |gate| {
            if (!text_match.inSet(running.items, gate)) {
                expected = false;
                break;
            }
        }
        const expected_cell = if (expected) "yes" else "no";
        if (!std.mem.eql(u8, cell, expected_cell)) {
            try appendViolation(gpa, violations, "{s}: `{s}` says CI `{s}`, but {s} derives `{s}`", .{ doc_path, evidence, cell, ci_path, expected_cell });
        }
    }

    // A table that stopped having rows would otherwise pass in silence.
    if (rows == 0) {
        try appendViolation(gpa, violations, "{s}: the evidence matrix has no derivable rows", .{doc_path});
    }
}

/// Collect the build-step names that follow each occurrence of `prefix`, up to
/// the next backtick or end of line.
/// The gate inventory every "runs in CI" claim is derived from, and the text
/// that opens each `zig build` row in it: the opening quote of the command
/// string, so a step named in a comment is not a gate.
pub const ci_inventory_path = "ci/groups.py";
pub const ci_gate_prefix = "\"zig build ";

pub fn collectBuildSteps(
    arena: std.mem.Allocator,
    haystack: []const u8,
    prefix: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, prefix)) |hit| {
        const start = hit + prefix.len;
        var stop = start;
        // A space ends the name as surely as a backtick, a quote, or a newline
        // does: a build step never contains one, so anything past it is
        // arguments. A gate that passes an option (`zig build fuzz
        // -Dfuzz-runs=25K`) is still running that step, and a doc row saying
        // CI runs `fuzz` is still true: without this the option becomes part
        // of the name and every such row reads as stale.
        while (stop < haystack.len and
            haystack[stop] != '`' and
            haystack[stop] != '"' and
            haystack[stop] != '\n' and
            haystack[stop] != ' ') stop += 1;
        const name = std.mem.trim(u8, haystack[start..stop], " \t\r");
        if (name.len > 0) try out.append(arena, name);
        at = stop;
    }
}

/// Every checked-in fuzz corpus entry must be wired as a seed.
///
/// The seeds were hand-picked once and the corpus kept growing, so most entries
/// were shapes the fuzzer would never start from. A corpus file that is not a
/// seed is invisible: nothing fails, the harness just covers less than it looks
/// like it does. This is the kind of drift a rule cannot hold and a build check
/// can.
pub fn checkFuzzCorpusSeeds(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // Every fuzz target shares the seed list. Pointed at a file without the
    // seeds, the check would pass vacuously, which is the quiet way a parity
    // check stops being one.
    const harness_path = "test/support/corpus_seeds.zig";
    const corpus_dir = "test/oracle/corpus";

    const harness = root.readFileAlloc(io, harness_path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for fuzz seed check with {s}", .{ harness_path, @errorName(err) });
        return;
    };
    defer gpa.free(harness);

    var dir = root.openDir(io, corpus_dir, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for fuzz seed check with {s}", .{ corpus_dir, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".bin")) continue;

        const needle = try std.fmt.allocPrint(gpa, "corpus/{s}\")", .{entry.name});
        defer gpa.free(needle);
        if (std.mem.indexOf(u8, harness, needle) == null) {
            try appendViolation(gpa, violations, "{s}: corpus entry `{s}` is not wired as a seed in {s}", .{ corpus_dir, entry.name, harness_path });
        }
    }
}
