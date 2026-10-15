//! Documented inventories held to the code: the resident roster, the
//! stability page's workflow claims and evidence parity, the community-review CI
//! matrix, first-read provenance (once, on the landing), and the fuzz corpus seeds.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;

/// The netlayer resident roster is recited in prose across several inventory
/// docs, and the count and list have drifted before: a page hardcoded "four"
/// after a fifth resident landed, and one dropped a resident entirely. The
/// transport symbols are declared once in `src/ocapn/model/transport.zig`. The
/// residents are the subset that carry a `src/net/transport/<name>.zig` netlayer
/// (all but `keyed_relay`, a resident-less browser rendezvous symbol, and
/// `noise_relay`, realized as a sealing completion-backend adapter over the
/// keyed-relay pipe rather than a blocking resident). This pins
/// every roster doc to name every resident, so adding one forces each inventory
/// to mention it rather than silently falling behind. It replaces a fragile
/// negative phrase-ban with a positive set check.
pub fn checkResidentRoster(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const Resident = struct { name: []const u8, alts: []const []const u8 };
    // The spellings a doc may use for each resident, lowercased. Update this set
    // in the same change as a new `src/net/transport/*.zig` resident; the gate
    // then makes every roster doc name it.
    const residents = [_]Resident{
        .{ .name = "tcp", .alts = &.{"tcp"} },
        .{ .name = "keyed-tcp", .alts = &.{ "keyed-tcp", "keyed tcp", "tcp_keyed" } },
        .{ .name = "noise-tcp", .alts = &.{ "noise-tcp", "noise tcp" } },
        .{ .name = "inproc", .alts = &.{ "inproc", "in-process", "in process" } },
        .{ .name = "iroh", .alts = &.{"iroh"} },
        .{ .name = "webrtc", .alts = &.{"webrtc"} },
    };
    const roster_docs = [_][]const u8{
        "docs/shipped.md",
        // The page whose stated job is "the edges of what ships today". A
        // transport that ships without its edge written down fails here.
        "docs/boundaries.md",
        // The site inventory of every netlayer: choosing owns the roster
        // because the parent Transports page is the concept overview.
        "site/content/transports/choosing.smd",
        "site/content/modules.smd",
        "site/content/relay.smd",
    };
    for (roster_docs) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for resident-roster check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        const lower = try gpa.alloc(u8, contents.len);
        defer gpa.free(lower);
        _ = std.ascii.lowerString(lower, contents);
        for (residents) |r| {
            var found = false;
            for (r.alts) |alt| {
                if (std.mem.indexOf(u8, lower, alt) != null) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try appendViolation(gpa, violations, "{s}: the netlayer resident roster omits `{s}`; every roster doc must name all residents (src/ocapn/model/transport.zig is the source), so a resident cannot silently fall behind", .{ path, r.name });
            }
        }
    }
}

/// The stability page points at `ci/gates.sh` for which checks recur, and
/// names the macOS job's command. Hold the workflow to the cancel policy and
/// the macOS job the page describes.
pub fn checkStabilityWorkflow(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const doc_path = "docs/stability.md";
    const workflow_path = ".github/workflows/check.yml";

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = root.readFileAlloc(io, doc_path, arena, .limited(1 << 20)) catch {
        try appendViolation(gpa, violations, "{s}: missing, but recurring evidence is documented there", .{doc_path});
        return;
    };
    const workflow = root.readFileAlloc(io, workflow_path, arena, .limited(1 << 20)) catch {
        try appendViolation(gpa, violations, "{s}: missing, so recurring platform evidence cannot be checked", .{workflow_path});
        return;
    };
    if (std.mem.indexOf(u8, workflow, "concurrency:") == null or
        std.mem.indexOf(u8, workflow, "cancel-in-progress: true") == null)
    {
        try appendViolation(gpa, violations, "{s}: recurring full gates must cancel superseded runs", .{workflow_path});
    }

    const macos_command = "zig build test loam-lmdb-test loam-sqlite-test";
    const macos_markers = [_][]const u8{
        "\n  macos-runtime:",
        "runs-on: macos-",
        "ZIG_INSTALL_DIR=\"$RUNNER_TEMP/zig\" bash .devcontainer/image/zig.sh",
        "run: " ++ macos_command,
    };
    for (macos_markers) |marker| {
        if (std.mem.indexOf(u8, workflow, marker) == null) {
            try appendViolation(gpa, violations, "{s}: macOS runtime evidence requires `{s}`", .{ workflow_path, marker });
        }
    }
    const macos_row_start = std.mem.indexOf(u8, doc, "| macOS |") orelse doc.len;
    const macos_row_end = std.mem.indexOfScalarPos(u8, doc, macos_row_start, '\n') orelse doc.len;
    if (std.mem.indexOf(u8, doc[macos_row_start..macos_row_end], "`" ++ macos_command ++ "`") == null) {
        try appendViolation(gpa, violations, "{s}: the macOS evidence row must name `{s}` as configured by {s}", .{ doc_path, macos_command, workflow_path });
    }
}

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
    const ci_path = "ci/gates.sh";

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

    // One parser of `ci/gates.sh`, shared with the stability area check: two
    // would be two definitions of "runs in CI".
    var running: std.ArrayList([]const u8) = .empty;
    try collectBuildSteps(arena, ci, "\ngate zig build ", &running);

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
            if (!containsStep(running.items, gate)) {
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
        // A space ends the name as surely as a backtick or a newline does: a
        // build step never contains one, so anything past it is arguments. A
        // gate that passes an option (`zig build fuzz -Dfuzz-runs=25K`) is
        // still running that step, and a doc row saying CI runs `fuzz` is
        // still true: without this the option becomes part of the name and
        // every such row reads as stale.
        while (stop < haystack.len and
            haystack[stop] != '`' and
            haystack[stop] != '\n' and
            haystack[stop] != ' ') stop += 1;
        const name = std.mem.trim(u8, haystack[start..stop], " \t\r");
        if (name.len > 0) try out.append(arena, name);
        at = stop;
    }
}

fn containsStep(steps: []const []const u8, needle: []const u8) bool {
    for (steps) |step| {
        if (std.mem.eql(u8, step, needle)) return true;
    }
    return false;
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
    // The seed list moved out of the codec target when every fuzz target began
    // sharing it. The check follows it: pointed at the old path it would read a
    // file with no seeds in it and pass, which is the quiet way a parity check
    // stops being one.
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

/// `docs/stability.md` owns the evidence table. The site page points at it
/// and must not paste a second copy: identical tables drift, and a stranger
/// evaluating on the website does not need a CI changelog.
pub fn checkStabilityEvidenceParity(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const doc_path = "docs/stability.md";
    const site_path = "site/content/stability.smd";
    const table_header = "| Area | Evidence | What remains |";
    const doc = root.readFileAlloc(io, doc_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ doc_path, @errorName(err) });
        return;
    };
    defer gpa.free(doc);
    const site = root.readFileAlloc(io, site_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ site_path, @errorName(err) });
        return;
    };
    defer gpa.free(site);

    if (std.mem.indexOf(u8, doc, table_header) == null) {
        try appendViolation(gpa, violations, "{s}: missing the stability evidence table this check treats as canonical", .{doc_path});
    }
    if (std.mem.indexOf(u8, site, table_header) != null) {
        try appendViolation(gpa, violations, "{s}: pasted the evidence table; point at {s} instead (doc-voice: one owner per status claim)", .{ site_path, doc_path });
    }
    if (std.mem.indexOf(u8, site, "docs/stability.md") == null) {
        try appendViolation(gpa, violations, "{s}: must link {s}, the page that owns the evidence matrix", .{ site_path, doc_path });
    }

    const rust_path = "bindings/rust/README.md";
    const rust = root.readFileAlloc(io, rust_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read binding evidence scope with {s}", .{ rust_path, @errorName(err) });
        return;
    };
    defer gpa.free(rust);
    if (std.mem.indexOf(u8, rust, "fake daemon") == null or
        std.mem.indexOf(u8, rust, "rust-dogfood") == null or
        std.mem.indexOf(u8, rust, "Repository-level on-demand checks cross Tor") == null or
        std.mem.indexOf(u8, rust, "nothing has yet crossed the Tor network") != null)
    {
        try appendViolation(gpa, violations, "{s}: distinguish its fake-daemon binding check from the repository's live Tor evidence in {s}", .{ rust_path, doc_path });
    }
}

/// First-read landings disclose agent provenance once, before native or scale
/// marketing. Inventory pages link the landing instead of restamping
/// `PROVENANCE.md`. `zig build source-check` holds both.
pub fn checkFirstReadProvenance(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const landings = [_][]const u8{
        "README.md",
        "site/content/index.smd",
    };
    for (landings) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for first-read provenance check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        const lower = try gpa.alloc(u8, contents.len);
        defer gpa.free(lower);
        _ = std.ascii.lowerString(lower, contents);

        const provenance_at = std.mem.indexOf(u8, lower, "provenance.md") orelse {
            try appendViolation(gpa, violations, "{s}: missing `PROVENANCE.md`; the landing must disclose agent provenance before a reviewer infers it from trailers", .{path});
            continue;
        };

        if (std.mem.indexOf(u8, lower, "iroh")) |iroh_at| {
            if (iroh_at < provenance_at) {
                try appendViolation(gpa, violations, "{s}: `iroh` appears before `PROVENANCE.md`; disclose agent provenance before native-path marketing", .{path});
            }
        }
        if (std.mem.indexOf(u8, lower, "500,000")) |scale_at| {
            if (scale_at < provenance_at) {
                try appendViolation(gpa, violations, "{s}: `500,000` appears before `PROVENANCE.md`; disclose agent provenance before scale marketing", .{path});
            }
        }
    }

    const no_stamp = [_][]const u8{
        "docs/ladder.md",
        "docs/shipped.md",
        "site/content/project.smd",
    };
    for (no_stamp) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for provenance-stamp check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        const lower = try gpa.alloc(u8, contents.len);
        defer gpa.free(lower);
        _ = std.ascii.lowerString(lower, contents);
        if (std.mem.indexOf(u8, lower, "provenance.md") != null) {
            try appendViolation(gpa, violations, "{s}: restamps `PROVENANCE.md`; the landing owns that disclosure, this page does not", .{path});
        }
    }

    const readme = root.readFileAlloc(io, "README.md", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "README.md: failed to read for outside-claim check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(readme);
    const readme_lower = try gpa.alloc(u8, readme.len);
    defer gpa.free(readme_lower);
    _ = std.ascii.lowerString(readme_lower, readme);

    if (std.mem.indexOf(u8, readme_lower, "captp 1.0") == null) {
        try appendViolation(gpa, violations, "README.md: missing `CapTP 1.0`; the outside claim is signed CapTP 1.0 over Syrup", .{});
    }
    if (std.mem.indexOf(u8, readme_lower, "testing adapter") == null and
        std.mem.indexOf(u8, readme_lower, "testing transport") == null)
    {
        try appendViolation(gpa, violations, "README.md: missing testing-transport wording; recurring Goblins evidence is cleartext `tcp`", .{});
    }

    const interop_at = std.mem.indexOf(u8, readme_lower, "goblins-interop");
    const iroh_step_at = std.mem.indexOf(u8, readme_lower, "goblins-iroh");
    if (interop_at != null and iroh_step_at != null and iroh_step_at.? < interop_at.?) {
        try appendViolation(gpa, violations, "README.md: `goblins-iroh` appears before `goblins-interop`; recurring Goblins evidence is the testing-TCP step", .{});
    }

    const onion_at = std.mem.indexOf(u8, readme_lower, "goblins-onion");
    if (onion_at != null and interop_at != null and interop_at.? < onion_at.?) {
        try appendViolation(gpa, violations, "README.md: `goblins-onion` must appear before `goblins-interop`; the standardized Goblins meeting is Tor", .{});
    }
}
