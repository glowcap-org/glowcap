//! The CapTP product-surface checks.
//!
//! The live-product vocabulary held honest: transport symbols and designator
//! schemes in lockstep with `model.transport` and the residents, the
//! application-surface verb inventory across every binding and the skills,
//! the CapTP CLI/MCP skill authorities and agent dogfood routing, the CapTP
//! vocabulary map (ADR-0079), the CLI deadline and listen-stop contracts, the
//! lab UX honesty rows, and the Racket conformance-script paren balance.
//! Wired by the meta-check driver (`tools/check/meta_check.zig`).

const std = @import("std");
const bans = @import("bans.zig");
const util = @import("util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;

/// The transport-agnosticism phrase bans live in `meta_check/bans.zig`
/// (`transport_vocabulary`); this keeps only the resident-count heuristic,
/// whose violation message names the fix (`keyed-tcp` in the enumeration)
/// rather than the matched needle. It shares the scanned path list with
/// those rows.
pub fn checkTransportVocabulary(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (bans.transport_vocabulary_paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for transport-vocabulary check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        // Resident enumerations that still say "three" without keyed-tcp.
        if (std.mem.indexOf(u8, contents, "three residents") != null or
            std.mem.indexOf(u8, contents, "Three residents") != null or
            std.mem.indexOf(u8, contents, "All three residents") != null or
            std.mem.indexOf(u8, contents, "three real residents") != null or
            std.mem.indexOf(u8, contents, "Three ship today") != null or
            std.mem.indexOf(u8, contents, "walks all three") != null)
        {
            if (std.mem.indexOf(u8, contents, "keyed-tcp") == null) {
                try appendViolation(
                    gpa,
                    violations,
                    "{s}: netlayer resident count omits `keyed-tcp` — list `tcp`, `keyed-tcp`, `inproc`, and iroh",
                    .{path},
                );
            }
        }
    }
}

/// `driver_core.designatorSchemeForTransport` must agree with each netlayer
/// resident's `designator_scheme` for the four shipped transports. The sans-io
/// host never sees a vtable, so this string table is the byte-fed mirror of
/// the I/O path's authoritative declaration — a transport added to one must
/// land in the other.
pub fn checkDesignatorSchemeSync(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const Transport = struct {
        name: []const u8,
        path: []const u8,
    };
    const transports = [_]Transport{
        .{ .name = "tcp", .path = "src/net/transport/tcp.zig" },
        .{ .name = "keyed-tcp", .path = "src/net/transport/tcp_keyed.zig" },
        .{ .name = "inproc", .path = "src/net/transport/inproc.zig" },
        .{ .name = "iroh", .path = "src/net/transport/iroh.zig" },
    };

    const vocab_path = "src/driver/core/vocab.zig";
    const vocab = root.readFileAlloc(io, vocab_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for designator-scheme sync with {s}", .{ vocab_path, @errorName(err) });
        return;
    };
    defer gpa.free(vocab);

    const fn_start = std.mem.indexOf(u8, vocab, "pub fn designatorSchemeForTransport") orelse {
        try appendViolation(gpa, violations, "{s}: missing `pub fn designatorSchemeForTransport`", .{vocab_path});
        return;
    };
    const after_fn = vocab[fn_start..];
    const body_open = std.mem.indexOfScalar(u8, after_fn, '{') orelse {
        try appendViolation(gpa, violations, "{s}: designatorSchemeForTransport has no body", .{vocab_path});
        return;
    };
    const body = after_fn[body_open..];
    const body_close = std.mem.indexOfScalar(u8, body, '}') orelse {
        try appendViolation(gpa, violations, "{s}: designatorSchemeForTransport body is unclosed", .{vocab_path});
        return;
    };
    const fn_body = body[0 .. body_close + 1];

    for (transports) |t| {
        const vocab_scheme = designatorSchemeFromVocabBody(fn_body, t.name);
        const resident = root.readFileAlloc(io, t.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for designator-scheme sync with {s}", .{ t.path, @errorName(err) });
            continue;
        };
        defer gpa.free(resident);

        const resident_scheme = designatorSchemeFromResident(resident);
        if (!std.mem.eql(u8, vocab_scheme, resident_scheme)) {
            try appendViolation(
                gpa,
                violations,
                "designator-scheme mismatch for `{s}`: vocab.designatorSchemeForTransport → .{s}, but {s} Netlayer.VTable → .{s}",
                .{ t.name, vocab_scheme, t.path, resident_scheme },
            );
        }
    }

    // Every explicit key arm in the vocab table must name a shipped transport
    // (no orphan model.transport.* or string that never matches a resident).
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, fn_body, search, "model.transport.")) |at| {
        const after = fn_body[at + "model.transport.".len ..];
        const end = std.mem.indexOfAny(u8, after, ")., \n\r\t") orelse break;
        const field = after[0..end];
        if (std.mem.eql(u8, field, "hint_direct_addresses")) {
            search = at + 1;
            continue;
        }
        const name = transportNameFromField(field) orelse {
            try appendViolation(gpa, violations, "{s}: designatorSchemeForTransport names unknown model.transport.`{s}`", .{ vocab_path, field });
            search = at + 1;
            continue;
        };
        var known = false;
        for (transports) |t| {
            if (std.mem.eql(u8, t.name, name)) {
                known = true;
                break;
            }
        }
        if (!known) {
            try appendViolation(
                gpa,
                violations,
                "{s}: designatorSchemeForTransport names unknown transport `{s}` — add a netlayer resident or drop the arm",
                .{ vocab_path, name },
            );
        }
        search = at + 1;
    }

    // Residents must alias `transport_name` to `model.transport.*` (one symbol table).
    for (transports) |t| {
        const resident = root.readFileAlloc(io, t.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for transport_name alias check with {s}", .{ t.path, @errorName(err) });
            continue;
        };
        defer gpa.free(resident);
        const field = transportSymbolField(t.name);
        var alias_buf: [96]u8 = undefined;
        const alias = std.fmt.bufPrint(&alias_buf, "model.transport.{s}", .{field}) catch continue;
        if (std.mem.indexOf(u8, resident, alias) == null) {
            try appendViolation(gpa, violations, "{s}: `transport_name` must alias `{s}` — one model.transport symbol table", .{ t.path, alias });
        }
    }
}

fn transportNameFromField(field: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, field, "tcp")) return "tcp";
    if (std.mem.eql(u8, field, "keyed_tcp")) return "keyed-tcp";
    if (std.mem.eql(u8, field, "inproc")) return "inproc";
    if (std.mem.eql(u8, field, "iroh")) return "iroh";
    return null;
}

fn designatorSchemeFromVocabBody(fn_body: []const u8, transport: []const u8) []const u8 {
    // Match `transport, model.transport.NAME)` arms (preferred) or legacy
    // `transport, "NAME")` arms; unmarked names fall through to `.address`.
    var buf: [128]u8 = undefined;
    const model_needle = std.fmt.bufPrint(&buf, "transport, model.transport.{s})", .{transportSymbolField(transport)}) catch return "address";
    if (schemeReturnAfterNeedle(fn_body, model_needle)) |scheme| return scheme;
    const lit_needle = std.fmt.bufPrint(&buf, "transport, \"{s}\")", .{transport}) catch return "address";
    if (schemeReturnAfterNeedle(fn_body, lit_needle)) |scheme| return scheme;
    return "address";
}

fn transportSymbolField(transport: []const u8) []const u8 {
    if (std.mem.eql(u8, transport, "tcp")) return "tcp";
    if (std.mem.eql(u8, transport, "keyed-tcp")) return "keyed_tcp";
    if (std.mem.eql(u8, transport, "inproc")) return "inproc";
    if (std.mem.eql(u8, transport, "iroh")) return "iroh";
    return transport;
}

fn schemeReturnAfterNeedle(fn_body: []const u8, needle: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, fn_body, needle) orelse return null;
    const after = fn_body[at + needle.len ..];
    if (std.mem.indexOf(u8, after, "return .key")) |k| {
        if (std.mem.indexOf(u8, after, "return .address")) |a| {
            if (a < k) return "address";
        }
        if (std.mem.indexOf(u8, after, "\nif ")) |next_if| {
            if (k < next_if) return "key";
        } else return "key";
    }
    if (std.mem.indexOf(u8, after, "return .address")) |_| return "address";
    return null;
}

/// Read the Netlayer resident vtable's `designator_scheme` from source.
/// Absence means the VTable default (`.address`).
fn designatorSchemeFromResident(source: []const u8) []const u8 {
    // Prefer the first Netlayer.VTable literal; keyed-tcp/iroh set `.key`
    // there. Listener vtables may repeat the same field and must not confuse
    // an address-scheme resident.
    const markers = [_][]const u8{
        "const resident_vtable: Netlayer.VTable",
        "const resident_vtable: net.netlayer.Netlayer.VTable",
        "const netlayer_vtable = Netlayer.VTable",
        "const netlayer_vtable: Netlayer.VTable",
    };
    var vtable_region: ?[]const u8 = null;
    for (markers) |marker| {
        if (std.mem.indexOf(u8, source, marker)) |at| {
            const rest = source[at..];
            const open = std.mem.indexOfScalar(u8, rest, '{') orelse continue;
            const close = std.mem.indexOfScalar(u8, rest[open..], '}') orelse continue;
            vtable_region = rest[open .. open + close + 1];
            break;
        }
    }
    const region = vtable_region orelse source;
    if (std.mem.indexOf(u8, region, ".designator_scheme = .key") != null) return "key";
    if (std.mem.indexOf(u8, region, ".designator_scheme = .address") != null) return "address";
    return "address";
}

/// Every Racket script under `conformance/goblins-peer/racket/` must read as
/// balanced s-expressions. The hermetic gate cannot run Goblins, so a script
/// with an unclosed paren ships silently, and every live step that spawns it
/// watches a dialer die at parse. Reader-level only: strings, `;` line
/// comments, and `#\` char literals are skipped; this is not an expander.
pub fn checkRacketScriptBalance(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const dir_path = "conformance/goblins-peer/racket";
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for paren-balance check with {s}", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".rkt")) continue;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for paren-balance check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (racketParenImbalance(contents)) |imbalance| {
            try appendViolation(gpa, violations, "{s}: unbalanced s-expressions (net depth {d} at end of file) — a script that cannot read parks every live step that spawns it", .{ path, imbalance });
        }
    }
}

/// Net open-parens at end of file (positive: unclosed openers; negative: an
/// extra closer, reported at first dip), or null when balanced. Treats (),
/// [], {} uniformly and skips strings, `;` comments, and `#\` char literals.
fn racketParenImbalance(contents: []const u8) ?isize {
    var depth: isize = 0;
    var i: usize = 0;
    while (i < contents.len) : (i += 1) {
        switch (contents[i]) {
            ';' => while (i < contents.len and contents[i] != '\n') {
                i += 1;
            },
            '"' => {
                i += 1;
                while (i < contents.len) : (i += 1) {
                    if (contents[i] == '\\') {
                        i += 1;
                        continue;
                    }
                    if (contents[i] == '"') break;
                }
            },
            '#' => if (i + 1 < contents.len and contents[i + 1] == '\\') {
                i += 2;
            },
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                depth -= 1;
                if (depth < 0) return depth;
            },
            else => {},
        }
    }
    return if (depth == 0) null else depth;
}

/// The application-surface verbs the vision promises in every binding and on the
/// native driver. Each surface that introduces the vocabulary must list all of
/// them; a dropped verb is a silently second-class surface.
const application_surface_verbs = [_][]const u8{
    "connect", "listen", "fetch", "publish", "spawn", "send", "tell", "serve", "close",
};

/// The living-state surfaces that enumerate the application-surface vocabulary.
/// `bindings/README.md` is the authoritative enumeration; `examples/README.md`
/// repeats it as the tutorial index. Every other surface (README, vision)
/// cites "nine verbs" with a link instead of enumerating, so a partial copy
/// cannot exist there.
const application_surface_files = [_][]const u8{
    "bindings/README.md", "examples/README.md",
};

/// Whether `verb` appears as an inline-code token in `contents`, tolerating the
/// three ways the surfaces write it: bare (`connect`), as a call
/// (`connect(locator)`), or as a method on a receiver (`conn.tell(ref, …)`).
/// A trailing `(…)` and a leading `recv.` are stripped before comparison.
fn mentionsVerbInCode(contents: []const u8, verb: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, contents, i, '`')) |open| {
        const after = open + 1;
        const close = std.mem.indexOfScalarPos(u8, contents, after, '`') orelse return false;
        var span = contents[after..close];
        if (std.mem.indexOfScalar(u8, span, '(')) |paren| span = span[0..paren];
        if (std.mem.lastIndexOfScalar(u8, span, '.')) |dot| span = span[dot + 1 ..];
        if (std.mem.eql(u8, span, verb)) return true;
        i = close + 1;
    }
    return false;
}

/// Gate that every living-state surface listing the application vocabulary names
/// all nine verbs. This is the check the prose restatements collapse toward: when
/// a verb is added or renamed, this fails until every surface is updated, so the
/// list cannot silently drift on one surface (as it did when `listen` and `tell`
/// went missing from the examples index).
pub fn checkApplicationSurfaceVerbs(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (application_surface_files) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for application-surface verb check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (application_surface_verbs) |verb| {
            if (!mentionsVerbInCode(contents, verb)) {
                try appendViolation(gpa, violations, "{s}: application-surface verb `{s}` is missing, the nine-verb vocabulary (connect, listen, fetch, publish, spawn, send, tell, serve, close) must be complete on every surface that lists it", .{ path, verb });
            }
        }
    }
}

/// CapTP leaf names from `cli/registry.zig`'s `commands` table.
/// Command rows put `.name` / `.help` on consecutive lines; positional structs
/// keep both on one line — that difference is how we avoid collecting `locator`.
fn collectCaptpRegistryNames(
    gpa: std.mem.Allocator,
    registry_src: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const start = std.mem.indexOf(u8, registry_src, "pub const commands") orelse return;
    const end_marker = std.mem.indexOfPos(u8, registry_src, start, "\n};") orelse registry_src.len;
    const block = registry_src[start..end_marker];
    var line_start: usize = 0;
    while (line_start < block.len) {
        const nl = std.mem.indexOfScalarPos(u8, block, line_start, '\n') orelse block.len;
        const line = std.mem.trim(u8, block[line_start..nl], " \t");
        if (std.mem.startsWith(u8, line, ".name = \"")) {
            const after = ".name = \"".len;
            if (std.mem.indexOfScalarPos(u8, line, after, '"')) |q| {
                const name = line[after..q];
                var next = if (nl < block.len) nl + 1 else block.len;
                while (next < block.len) {
                    const nnl = std.mem.indexOfScalarPos(u8, block, next, '\n') orelse block.len;
                    const next_line = std.mem.trim(u8, block[next..nnl], " \t");
                    if (next_line.len == 0) {
                        next = if (nnl < block.len) nnl + 1 else block.len;
                        continue;
                    }
                    if (std.mem.startsWith(u8, next_line, ".help =")) {
                        try out.append(gpa, name);
                    }
                    break;
                }
            }
        }
        line_start = if (nl < block.len) nl + 1 else block.len;
    }
}

/// True when a markdown table is a CapTP verb inventory (header names Verb or
/// Command) and lists some registry leaves (≥3) but not all. Session-model
/// tables that mention `` `call` `` inline are not inventories.
fn captpVerbTableIsPartial(skill: []const u8, names: []const []const u8) bool {
    var line_start: usize = 0;
    var in_inventory = false;
    var hit: usize = 0;
    var seen: [64]bool = .{false} ** 64;
    while (line_start < skill.len) {
        const nl = std.mem.indexOfScalarPos(u8, skill, line_start, '\n') orelse skill.len;
        const line = skill[line_start..nl];
        const is_row = line.len > 0 and line[0] == '|';
        if (is_row) {
            const lower_buf_len = @min(line.len, 256);
            var lower_buf: [256]u8 = undefined;
            for (line[0..lower_buf_len], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
            const lower = lower_buf[0..lower_buf_len];
            if (!in_inventory) {
                if (std.mem.indexOf(u8, lower, "verb") != null or std.mem.indexOf(u8, lower, "command") != null) {
                    in_inventory = true;
                }
            } else {
                var cell_start: usize = 0;
                while (cell_start < line.len) {
                    if (line[cell_start] != '|') {
                        cell_start += 1;
                        continue;
                    }
                    const after_bar = cell_start + 1;
                    const next_bar = std.mem.indexOfScalarPos(u8, line, after_bar, '|') orelse line.len;
                    const cell = std.mem.trim(u8, line[after_bar..next_bar], " \t");
                    if (cell.len >= 3 and cell[0] == '`' and cell[cell.len - 1] == '`') {
                        const span = cell[1 .. cell.len - 1];
                        for (names, 0..) |name, ni| {
                            if (ni >= seen.len) break;
                            if (std.mem.eql(u8, span, name) and !seen[ni]) {
                                seen[ni] = true;
                                hit += 1;
                            }
                        }
                    }
                    cell_start = next_bar;
                }
            }
        } else if (in_inventory) {
            if (hit >= 3 and hit < names.len) return true;
            in_inventory = false;
            hit = 0;
            seen = .{false} ** 64;
        }
        line_start = if (nl < skill.len) nl + 1 else skill.len;
    }
    if (in_inventory and hit >= 3 and hit < names.len) return true;
    return false;
}

/// The pancake-mcp skill defers the tool catalog to MCP `tools/list` / registry.
/// Refuse a partial default-catalog inventory and unimplemented env overrides.
pub fn checkPancakeMcpSkillAuthority(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const skill_path = ".agents/skills/pancake-mcp/SKILL.md";
    const skill = root.readFileAlloc(io, skill_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ skill_path, @errorName(err) });
        return;
    };
    defer gpa.free(skill);

    if (std.mem.indexOf(u8, skill, "tools/list") == null) {
        try appendViolation(gpa, violations, "{s}: CapTP MCP catalog authority must point at `tools/list`", .{skill_path});
    }
    if (std.mem.indexOf(u8, skill, "Use pancake to write pancake") == null) {
        try appendViolation(gpa, violations, "{s}: must state dogfood destination `Use pancake to write pancake`", .{skill_path});
    }
    if (std.mem.indexOf(u8, skill, "PANCAKE_MCP_TOOLS") != null) {
        try appendViolation(gpa, violations, "{s}: forbids unimplemented `PANCAKE_MCP_TOOLS` — catalog is `--tools` only", .{skill_path});
    }
    // Hand-maintained default inventory (second catalog) — body or description.
    if (std.mem.indexOf(u8, skill, "everyday CapTP (dial, probe") != null or
        std.mem.indexOf(u8, skill, "dial, probe, call, tell, fetch, publish, info") != null or
        std.mem.indexOf(u8, skill, "dial/probe/call/tell/fetch/publish/info/close") != null)
    {
        try appendViolation(gpa, violations, "{s}: do not enumerate default MCP tools — discover via `tools/list` / registry", .{skill_path});
    }
}

/// Work / smell-annihilation / skill indexes must not funnel MCP through pancake-cli.
pub fn checkCaptpAgentDogfoodRouting(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const must_name_mcp = [_][]const u8{
        ".agents/skills/work/SKILL.md",
        ".agents/skills/smell-annihilation/SKILL.md",
        ".agents/skills/rooms-peer/SKILL.md",
        ".agents/skills/rooms-team/SKILL.md",
        ".agents/skills/community-review/SKILL.md",
    };
    for (must_name_mcp) |path| {
        const text = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP dogfood routing with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(text);
        if (std.mem.indexOf(u8, text, "pancake-mcp") == null) {
            try appendViolation(gpa, violations, "{s}: CapTP dogfood routing must name `pancake-mcp` (MCP is not under pancake-cli)", .{path});
        }
    }

    const indexes = [_][]const u8{
        ".agents/README.md",
        ".agents/skills/README.md",
    };
    for (indexes) |path| {
        const text = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP dogfood routing with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(text);
        // retire-by: the next rewrite of the skill indexes it guards —
        // retire the `argv, REPL, MCP` prose needle in that same diff.
        if (std.mem.indexOf(u8, text, "argv, REPL, MCP") != null) {
            try appendViolation(gpa, violations, "{s}: pancake-cli blurb must not claim MCP — MCP lives on pancake-mcp", .{path});
        }
    }

    const rooms_team_script = ".agents/skills/rooms-team/scripts/team.sh";
    root.access(io, rooms_team_script, .{}) catch |err| {
        try appendViolation(gpa, violations, "{s}: rooms-team skill requires companion script ({s})", .{ rooms_team_script, @errorName(err) });
    };
    const rooms_team_skill = root.readFileAlloc(io, ".agents/skills/rooms-team/SKILL.md", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, ".agents/skills/rooms-team/SKILL.md: failed to read for companion refs with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(rooms_team_skill);
    if (std.mem.indexOf(u8, rooms_team_skill, "ops.md") == null or
        std.mem.indexOf(u8, rooms_team_skill, "gotchas.md") == null or
        std.mem.indexOf(u8, rooms_team_skill, "strategies.md") == null)
    {
        try appendViolation(gpa, violations, ".agents/skills/rooms-team/SKILL.md: must link ops.md, gotchas.md, and strategies.md", .{});
    }
}

/// The pancake-cli skill defers the CapTP catalog to `pancake help`. Gate the
/// authority pointer and refuse a partial verb-inventory table (second catalog).
pub fn checkPancakeCliSkillAuthority(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const skill_path = ".agents/skills/pancake-cli/SKILL.md";
    const skill = root.readFileAlloc(io, skill_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ skill_path, @errorName(err) });
        return;
    };
    defer gpa.free(skill);

    const has_help = std.mem.indexOf(u8, skill, "pancake help") != null or
        std.mem.indexOf(u8, skill, "help ocapn") != null;
    if (!has_help) {
        try appendViolation(gpa, violations, "{s}: CapTP catalog authority must point at `pancake help` / `help ocapn` (not a second verb table)", .{skill_path});
    }

    const registry_src = root.readFileAlloc(io, "cli/registry.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "cli/registry.zig: failed to read for pancake-cli skill check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(registry_src);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    try collectCaptpRegistryNames(gpa, registry_src, &names);
    if (names.items.len < 5) {
        try appendViolation(gpa, violations, "cli/registry.zig: expected CapTP leaf `.name = \"…\"` rows for pancake-cli skill check", .{});
        return;
    }
    if (captpVerbTableIsPartial(skill, names.items)) {
        try appendViolation(gpa, violations, "{s}: CapTP verb table is incomplete — enumerate every registry leaf or defer to `pancake help` (no second catalog)", .{skill_path});
    }
}

/// CapTP vocabulary (ADR-0079): structural resurrection guards only.
/// Deleted file paths, deleted `pub` symbols, and binding export maps that a
/// compiler would not catch. Prose tombstones for the rename ("multi-connection
/// node", "native-Zig Connection", …) were pruned once the rename shipped —
/// see the gate-accretion rule in `.agents/rules/agent-scaffolding.md`.
pub fn checkCaptpVocabulary(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // Deleted file names must stay deleted (renamed in ADR-0079).
    const deleted_paths = [_]struct { path: []const u8, reason: []const u8 }{
        .{ .path = "src/driver/connected_vat.zig", .reason = "BlockingSession lives in blocking_session.zig (ADR-0079)" },
        .{ .path = "test/driver/connected_vat_test.zig", .reason = "blocking_session_test.zig (ADR-0079)" },
        .{ .path = "bindings/ts/stack/connection.ts", .reason = "Session lives in session.ts (ADR-0079)" },
        .{ .path = "bindings/python/pancake/_connection.py", .reason = "Session lives in _session.py (ADR-0079)" },
        .{ .path = "bindings/rust/src/connection.rs", .reason = "Session lives in session.rs (ADR-0079)" },
        .{ .path = "bindings/racket/private/connection.rkt", .reason = "Session lives in session.rkt (ADR-0079)" },
    };
    for (deleted_paths) |entry| {
        if (root.access(io, entry.path, .{})) |_| {
            try appendViolation(gpa, violations, "{s}: file must stay deleted — {s}", .{ entry.path, entry.reason });
        } else |_| {}
    }

    // Resurrected symbols / exports — not prose.
    const SymbolBan = struct { path: []const u8, needle: []const u8, reason: []const u8 };
    const symbol_bans = [_]SymbolBan{
        .{ .path = "src/driver/core/host.zig", .needle = "pub fn hasSelfDesignator", .reason = "unused; callers use setSelfDesignator + selfDesignator" },
        .{ .path = "src/driver/core/host.zig", .needle = "pub fn vowConn", .reason = "unused; C ABI / bindings use vowConnClosing path, not ConnId lookup" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "pub fn execNodeAction", .reason = "host_pump-private; only called inside host_pump" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "pub fn dialActionFields", .reason = "host_pump-private; only called inside host_pump" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "fn queueFlushAction", .reason = "collapsed into queueUniqueConnAction" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "fn queueCloseAction", .reason = "collapsed into queueUniqueConnAction" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "pub fn queueUniqueConnAction", .reason = "host_pump-private; only called inside host_pump" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "pub fn drainWork", .reason = "host_pump-private; only called from finishVerb" },
        .{ .path = "src/net/mod.zig", .needle = "pub const FrameError = frame_stream.FrameError", .reason = "frame_stream-internal; not a net barrel export" },
        .{ .path = "src/net/mod.zig", .needle = "pub const drainWholeFrames = frame_stream.drainWholeFrames", .reason = "frame_stream-internal; not a net barrel export" },
        .{ .path = "src/driver/core/mod.zig", .needle = "pub const requiresDirectAddressesHint = vocab.requiresDirectAddressesHint", .reason = "use vocab.requiresDirectAddressesHint; not a driver_core barrel export" },
        .{ .path = "src/driver/core/mod.zig", .needle = "pub const DialPlanError = dial_plan.Error", .reason = "unused barrel export; dial_plan.Error stays module-local" },
        .{ .path = "src/driver/core/mod.zig", .needle = "pub const DialReach = dial_plan.Reach", .reason = "unused barrel export; dial_plan.Reach stays module-local" },
        .{ .path = "test/support/wait.zig", .needle = "pub const Signal = struct", .reason = "unused; use untilFlag" },
        .{ .path = "test/support/wait.zig", .needle = "pub const PublishedAddr = struct", .reason = "unused; no adopters" },
        .{ .path = "src/driver/mod.zig", .needle = "pub const Node = engine.Node", .reason = "driver.Node re-export deleted (ADR-0079)" },
        .{ .path = "src/driver/core/served.zig", .needle = "fn bindForeign", .reason = "use bindExport; bindForeign deleted (ADR-0079)" },
        .{ .path = "src/driver/core/served.zig", .needle = "fn spawnForeign", .reason = "spawnHosted (ADR-0079)" },
        .{ .path = "src/net/transport/tcp.zig", .needle = "pub const Locator = struct", .reason = "tcp.DialResolver (ADR-0079)" },
        .{ .path = "src/net/transport/iroh.zig", .needle = "pub const Locator = struct", .reason = "iroh.DialResolver (ADR-0079)" },
        .{ .path = "src/c_abi/shared/mod.zig", .needle = "pub const HostAllocator", .reason = "ContextAllocator (ADR-0079)" },
        .{ .path = "src/driver/blocking_session.zig", .needle = "pub const ConnectedVat", .reason = "BlockingSession (ADR-0079)" },
        .{ .path = "src/actors/vat/mod.zig", .needle = "pub const ForeignActor", .reason = "HostedActor (ADR-0079)" },
        .{ .path = "src/actors/vat/mod.zig", .needle = "fn spawnForeign", .reason = "spawnHosted (ADR-0079)" },
        .{ .path = "src/actors/vat/boxed.zig", .needle = "const ForeignBlock", .reason = "HostedBlock (ADR-0079)" },
        .{ .path = "src/ocapn/engine/pairing.zig", .needle = "pub fn pairedWithOffers", .reason = "use pairedNegotiated + negotiate" },
        .{ .path = "src/ocapn/engine/negotiation.zig", .needle = "pub fn offerForTarget", .reason = "test-local interop offer helper" },
        .{ .path = "src/ocapn/engine/negotiation.zig", .needle = "pub const InteropTarget", .reason = "test-local interop offer helper" },
        .{ .path = "src/ocapn/engine/negotiation.zig", .needle = "pub const CodecId = model.CodecId", .reason = "use model.CodecId" },
        .{ .path = "src/ocapn/engine/negotiation.zig", .needle = "pub fn sharesProfile", .reason = "removed; tests map negotiate null locally" },
        .{ .path = "bindings/ts/stack/mod.ts", .needle = "export { Node }", .reason = "export Host (ADR-0079)" },
        .{ .path = "bindings/ts/stack/mod.ts", .needle = "export { Connection }", .reason = "export Session (ADR-0079)" },
        .{ .path = "bindings/rust/src/lib.rs", .needle = "pub use host::Node", .reason = "pub use host::Host (ADR-0079)" },
        .{ .path = "bindings/rust/src/lib.rs", .needle = "pub use session::Connection", .reason = "pub use session::Session (ADR-0079)" },
        .{ .path = "bindings/python/pancake/__init__.py", .needle = "\"Node\"", .reason = "__all__ exports Host (ADR-0079)" },
        .{ .path = "bindings/python/pancake/__init__.py", .needle = "\"Connection\"", .reason = "__all__ exports Session (ADR-0079)" },
        .{ .path = "bindings/racket/pancake.rkt", .needle = "make-fresh-node", .reason = "make-fresh-host (ADR-0079)" },
        .{ .path = "bindings/racket/private/host.rkt", .needle = "(define (make-fresh-node", .reason = "make-fresh-host (ADR-0079)" },
        // Internal-vocabulary rule: a CapTP session is a `Session`, never a
        // `Conn`. conn/connection names only a byte stream, so the byte-fed
        // host tier must not respell its per-partner session as the byte-stream
        // `Conn` it once collided with in the same C ABI (ADR-0079 amendment).
        .{ .path = "include/pancake_driver.h", .needle = "PancakeHostConn", .reason = "PancakeHostSession — a CapTP session is not a byte-stream Conn (ADR-0079)" },
        .{ .path = "include/pancake_driver.h", .needle = "pancake_host_conn_", .reason = "pancake_host_session_* — a CapTP session is not a byte-stream conn (ADR-0079)" },
        .{ .path = "src/c_abi/driver/mod.zig", .needle = "PancakeHostConn", .reason = "PancakeHostSession (ADR-0079)" },
        .{ .path = "src/c_abi/driver/mod.zig", .needle = "pancake_host_conn_", .reason = "pancake_host_session_* (ADR-0079)" },
        .{ .path = "src/driver/core/host.zig", .needle = "pub const Conn ", .reason = "driver_core.Session — the byte-fed CapTP session is a Session (ADR-0079)" },
        // A public host-verb / PancakeHostAction field must not name a session
        // pointer `conn` — the exact conn-means-session residue review caught.
        .{ .path = "include/pancake_driver.h", .needle = "PancakeHostSession *conn", .reason = "name the session-pointer param/field `session`, not `conn` (ADR-0079)" },
        .{ .path = "include/pancake_driver.h", .needle = "out_conn", .reason = "name the out-session param `out_session`, not `out_conn` (ADR-0079)" },
        // Item-2 part 3: the byte-fed session type is `HostSession`, its id is
        // `PeerId` (the engine routes to Peers), and the Host releases sessions.
        .{ .path = "src/driver/core/host.zig", .needle = "pub const Session = struct", .reason = "the byte-fed CapTP session type is HostSession, never Session/Conn (ADR-0079)" },
        .{ .path = "src/driver/core/host.zig", .needle = "pub fn releaseConn", .reason = "releaseSession — the Host releases a HostSession, not a conn (ADR-0079)" },
        .{ .path = "src/ocapn/engine/node.zig", .needle = "pub const ConnId", .reason = "PeerId — the engine's routing id keys Peers, not byte-stream conns (ADR-0079)" },
        // Item-2 part 4: the Node registers/routes Peers, not conns — it returns
        // a PeerId and installs an engine.Peer.
        .{ .path = "src/ocapn/engine/node.zig", .needle = "pub fn registerConn", .reason = "registerPeer — the Node registers a Peer, not a byte-stream conn (ADR-0079)" },
        .{ .path = "src/ocapn/engine/node.zig", .needle = "conns:", .reason = "the Node's Peer table is `peers`, not `conns` (ADR-0079)" },
    };
    for (symbol_bans) |ban| {
        const contents = root.readFileAlloc(io, ban.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP vocabulary check with {s}", .{ ban.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, ban.needle) != null) {
            try appendViolation(gpa, violations, "{s}: contains `{s}` — {s}", .{ ban.path, ban.needle, ban.reason });
        }
    }

    // The driver family must carry the renamed session type / symbol — the
    // positive half of the internal-vocabulary rule (ADR-0079 amendment).
    const driver_header = root.readFileAlloc(io, "include/pancake_driver.h", gpa, .limited(4 << 20)) catch return;
    defer gpa.free(driver_header);
    for ([_][]const u8{ "PancakeHostSession", "pancake_host_session_" }) |needle| {
        if (std.mem.indexOf(u8, driver_header, needle) == null) {
            try appendViolation(gpa, violations, "include/pancake_driver.h: missing `{s}` — the byte-fed CapTP session family (ADR-0079)", .{needle});
        }
    }

    // Item-2 part 3 positive half: the Zig type / id renames landed.
    const positive = [_]struct { path: []const u8, needle: []const u8, what: []const u8 }{
        .{ .path = "src/driver/core/host.zig", .needle = "pub const HostSession", .what = "the byte-fed CapTP session Zig type (aligns with PancakeHostSession)" },
        .{ .path = "src/ocapn/engine/node.zig", .needle = "pub const PeerId", .what = "the engine's Peer routing id (was ConnId)" },
        .{ .path = "src/ocapn/engine/node.zig", .needle = "pub fn registerPeer", .what = "the Node registers Peers (was registerConn)" },
    };
    for (positive) |p| {
        const contents = root.readFileAlloc(io, p.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP vocabulary positive check with {s}", .{ p.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, p.needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — {s} (ADR-0079)", .{ p.path, p.needle, p.what });
        }
    }
}

/// Product CLI CapTP waits must be finite (ADR-0081). Empty `SessionOptions`
/// (`handshake_timeout_ms` / `settle_timeout_ms` default 0) parks forever on a
/// silent peer — the hang that wedged `cli-test` and left zombie test binaries.
pub fn checkCliCaptpDeadlines(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try expectFileContains(io, gpa, root, violations, "cli/ocapn/mod.zig", &.{
        "pub fn sessionOpts()",
        "default_handshake_timeout_ms",
        "default_settle_timeout_ms",
        "HandshakeTimedOut",
        "sessionOpts()",
    });
    try expectFileContains(io, gpa, root, violations, "test/cli/session_cases.zig", &.{
        "sessionOpts()",
        "HandshakeTimedOut",
        "handshake_timeout_ms = 200",
    });
    try expectFileContains(io, gpa, root, violations, "test/cli/captp_cases.zig", &.{
        "cmdListen",
        "cmdCall",
        "publish",
        "greeter",
        "requestStop while accepting",
        "requestStop while serving",
    });
    try expectFileContains(io, gpa, root, violations, "test/cli/all.zig", &.{
        "captp_cases.zig",
    });

    var dir = root.openDir(io, "cli", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "cli/: failed to open for CapTP-deadline check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "cli/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP-deadline check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        var line_no: usize = 1;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| : (line_no += 1) {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "//")) continue;
            if (std.mem.indexOf(u8, line, "handshake_timeout_ms: 0") != null or
                std.mem.indexOf(u8, line, "handshake_timeout_ms = 0") != null or
                std.mem.indexOf(u8, line, "settle_timeout_ms: 0") != null or
                std.mem.indexOf(u8, line, "settle_timeout_ms = 0") != null)
            {
                try appendViolation(gpa, violations, "{s}:{d}: CapTP wait budget must be finite in cli/ (0 parks forever on a silent peer; use sessionOpts() or a positive ms)", .{ path, line_no });
            }
            // Empty SessionOptions on connect/listen — the default opts are unbounded.
            if (std.mem.indexOf(u8, line, "connectUriOwned(") != null and std.mem.indexOf(u8, line, ", .{})") != null) {
                try appendViolation(gpa, violations, "{s}:{d}: connectUriOwned with empty SessionOptions `.{{}}` is unbounded; pass sessionOpts() or an explicit positive handshake budget", .{ path, line_no });
            }
            if (std.mem.indexOf(u8, line, "driver.listen(") != null and std.mem.indexOf(u8, line, ", .{})") != null) {
                try appendViolation(gpa, violations, "{s}:{d}: driver.listen with empty SessionOptions `.{{}}` is unbounded; pass sessionOpts()", .{ path, line_no });
            }
        }
    }
}

/// Ctrl+C on `ocapn listen` must poll `waitAcceptable` rather than close the
/// listen FD from another thread (Zig Threaded Io panics on that BADF).
pub fn checkCliListenStopWake(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try expectFileContains(io, gpa, root, violations, "cli/operability/signals.zig", &.{
        "accept-after-close",
        "must not close a listen FD",
        "pub const poll_ms",
    });
    try expectFileContains(io, gpa, root, violations, "cli/ocapn/mod.zig", &.{
        "waitAcceptable",
        "serveUntilStop",
        "signals.poll_ms",
    });
    try expectFileContains(io, gpa, root, violations, "src/net/netlayer.zig", &.{
        "waitAcceptable",
    });
    try expectFileContains(io, gpa, root, violations, "test/cli/captp_cases.zig", &.{
        "requestStop while accepting",
        "requestStop while serving",
    });
    try expectFileContains(io, gpa, root, violations, "docs/boundaries.md", &.{
        "waitAcceptable",
        "Zig threaded Io panics on that BADF",
    });

    // Tombstones: close-from-watcher and CapTP self-dial wake both regress BADF
    // or invent stop-path CapTP cost the poll seat already forbids.
    const tombstones = [_]struct { path: []const u8, needle: []const u8, why: []const u8 }{
        .{ .path = "cli/ocapn/mod.zig", .needle = "Closable", .why = "Closable closed the listen FD from the stop watcher (BADF panic); use waitAcceptable" },
        .{ .path = "cli/ocapn/mod.zig", .needle = "parked_in_accept", .why = "CapTP self-dial wake retired; poll Listener.waitAcceptable against the stop latch" },
        .{ .path = "cli/operability/signals.zig", .needle = "Closable", .why = "Closable name retired; StopWatch is MCP's stdin closer, not listen wake" },
        // retire-by: the next rewrite of docs/boundaries.md — retire these
        // two prose needles in that same diff.
        .{ .path = "docs/boundaries.md", .needle = "shared Io closer", .why = "listen and mcp share only the stop latch, not an Io closer" },
        .{ .path = "docs/boundaries.md", .needle = "dialing its own URI", .why = "listen stop polls waitAcceptable; CapTP self-dial wake is retired" },
    };
    for (tombstones) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for listen-stop check with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, row.needle) != null) {
            try appendViolation(gpa, violations, "{s}: forbidden needle `{s}` — {s}", .{ row.path, row.needle, row.why });
        }
    }
}

/// CapTP lab chrome/docs must match live keys: listen is argv-only; F1 (not
/// prompt `?`) opens the help modal; no stub search theater; no product-taste
/// names in `cli/repl` module headers.
pub fn checkCaptpLabUxHonesty(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const tombstones = [_]struct { path: []const u8, needle: []const u8, why: []const u8 }{
        .{ .path = "cli/repl/panes.zig", .needle = "dial or listen", .why = "empty-session chrome must invite dial only (listen is argv-only)" },
        .{ .path = "cli/repl/panes.zig", .needle = "F1 / ?", .why = "help modal must not claim prompt ? opens it (F1 does; ? is tip at prompt)" },
        .{ .path = "docs/cli.md", .needle = "dial` / `listen` inside", .why = "lab starts with dial inside; listen stays argv-only" },
        .{ .path = ".agents/skills/pancake-cli/SKILL.md", .needle = "dial/listen inside", .why = "skill session table: dial inside; listen argv-only" },
        .{ .path = "cli/repl/tui.zig", .needle = "Claude Code", .why = "taste as structure, not product names in committed headers" },
        .{ .path = "cli/repl/tui.zig", .needle = "stub — use Ctrl-O", .why = "search stub theater deleted; do not reintroduce" },
        .{ .path = "cli/repl/ecs/intent.zig", .needle = "search_start", .why = "search stub intents deleted until a real search mode exists" },
        .{ .path = "cli/repl/ecs/intent.zig", .needle = "hover_at", .why = "dead hover intent deleted; mouse handles hits inline" },
        .{ .path = "cli/argv.zig", .needle = "ocapn_flags", .why = "pre-tree CapTP argv helpers deleted; tree/registry own parse" },
        .{ .path = "cli/argv.zig", .needle = "peelGlobals", .why = "pre-tree CapTP argv helpers deleted; cmd/mod owns globals" },
        .{ .path = "cli/mcp/mod.zig", .needle = "\"version\":\"0.1.0\"", .why = "MCP serverInfo.version must come from build_options, not a hard-coded literal" },
        .{ .path = "cli/mcp/mod.zig", .needle = "Content-Length", .why = "MCP stdio is NDJSON per the MCP transport spec; LSP Content-Length framing breaks Cursor/Claude" },
        .{ .path = "cli/mcp/mod.zig", .needle = "\"]}}}\"", .why = "tools/list closes with ]}} (array+result+root); an extra brace makes Cursor drop the catalog" },
        .{ .path = "cli/registry.zig", .needle = "if (std.mem.eql(u8, cmd.name, \"listen\")) continue", .why = "use leafVisible; no ad-hoc listen skip lists" },
        .{ .path = "cli/cmd/tree.zig", .needle = "held; not yet on the wire", .why = "rooms-peer --dm ships via directory introduce; help must not claim held" },
        // retire-by: the rooms-peer rename holding stable for a month —
        // retire the bot/rooms-bot rename rows below in that diff.
        .{ .path = "cli/cmd/tree.zig", .needle = ".name = \"bot\"", .why = "rooms presence leaf is rooms-peer, not bot" },
        .{ .path = "cli/cmd/tree.zig", .needle = "Application fronts (bot)", .why = "app short_help names rooms-peer, not bot" },
        .{ .path = "build.zig", .needle = "rooms-bot", .why = "install/run step is rooms-peer" },
        .{ .path = "cli/app/rooms_peer/peer.zig", .needle = "remaining milestone", .why = "DM introduce/tell shipped; do not reintroduce a silent skip" },
        .{ .path = "cli/app/rooms_peer/verbs.zig", .needle = "not-implemented", .why = "reply --dm writes outbox; not a not-implemented stub" },
        .{ .path = "cli/app/rooms_peer/verbs.zig", .needle = "BotFailed", .why = "rooms-peer soft fail is PeerFailed/UsageFailed" },
        .{ .path = "cli/app/rooms_peer/supervise.zig", .needle = "botCliPrefix", .why = "prefix helper is peerCliPrefix" },
        .{ .path = "cli/app/rooms_peer/peer.zig", .needle = "BotState", .why = "daemon state type is PeerState" },
        .{ .path = ".agents/skills/rooms-peer/SKILL.md", .needle = "rooms-bot", .why = "skill vocabulary is rooms-peer" },
        .{ .path = ".agents/skills/rooms-peer/SKILL.md", .needle = "One bot per nick", .why = "skill rules say one peer per nick" },
    };
    for (tombstones) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP lab UX check with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, row.needle) != null) {
            try appendViolation(gpa, violations, "{s}: forbidden needle `{s}` — {s}", .{ row.path, row.needle, row.why });
        }
    }
    try expectFileContains(io, gpa, root, violations, "cli/repl/panes.zig", &.{
        "F1       this help",
        "dial an ocapn:// locator",
    });
    try expectFileContains(io, gpa, root, violations, "cli/registry.zig", &.{
        "leafVisible",
        "flagVisibleMcp",
        "argv_only",
        "mcp_hide",
    });
    try expectFileContains(io, gpa, root, violations, "cli/app/rooms_peer/peer.zig", &.{
        "registerWithDirectory",
        "startIntroduce",
        "publishDm",
    });
}

test "collectCaptpRegistryNames takes Command rows only" {
    const gpa = std.testing.allocator;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    const src =
        \\pub const commands = [_]Command{
        \\    .{
        \\        .name = "listen",
        \\        .help = "Bind",
        \\        .positionals = &[_]Positional{.{ .name = "locator", .help = "uri" }},
        \\    },
        \\    .{
        \\        .name = "dial",
        \\        .help = "Dial",
        \\    },
        \\};
    ;
    try collectCaptpRegistryNames(gpa, src, &names);
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("listen", names.items[0]);
    try std.testing.expectEqualStrings("dial", names.items[1]);
}

test "captpVerbTableIsPartial catches incomplete inventory tables" {
    const names = [_][]const u8{ "listen", "dial", "probe", "call" };
    try std.testing.expect(captpVerbTableIsPartial(
        "| Verb | Role |\n| --- | --- |\n| `listen` | host |\n| `dial` | dial |\n| `probe` | poke |\n",
        &names,
    ));
    try std.testing.expect(!captpVerbTableIsPartial(
        "| Verb | Role |\n| --- | --- |\n| `listen` | host |\n| `dial` | dial |\n| `probe` | poke |\n| `call` | act |\n",
        &names,
    ));
    try std.testing.expect(!captpVerbTableIsPartial(
        "| Front | Shape |\n| --- | --- |\n| argv | `call` / `tell` / `fetch` / `probe` |\n",
        &names,
    ));
    try std.testing.expect(!captpVerbTableIsPartial("defer to `pancake help`", &names));
}

test "mentionsVerbInCode matches bare, call, and receiver-method phrasings" {
    // Bare token, as the README and vision write it.
    try std.testing.expect(mentionsVerbInCode("the `connect` verb dials", "connect"));
    // As a call with arguments, as bindings/README's table writes it.
    try std.testing.expect(mentionsVerbInCode("| `listen(host, port)` | accept |", "listen"));
    // As a method on a receiver, the other bindings/README phrasing.
    try std.testing.expect(mentionsVerbInCode("call `conn.tell(ref, verb, args)`", "tell"));
    try std.testing.expect(mentionsVerbInCode("`conn.serve()` runs the loop", "serve"));
    // Absent: prose mention outside code is not enough, and a different verb
    // inside code does not satisfy the missing one.
    try std.testing.expect(!mentionsVerbInCode("you can tell it to stop", "tell"));
    try std.testing.expect(!mentionsVerbInCode("only `conn.close()` here", "serve"));
}
