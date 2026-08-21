//! Data-driven ban engine for `source-check`: one table row per needle claim,
//! one runner that resolves scopes, caches file reads, and appends violations.
//! `tools/check/source_check.zig` imports this file and runs `all` once per
//! gate invocation; checks that need more than substring presence stay in the
//! module that owns their concern.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

/// The files a `Ban` row scans.
pub const Where = union(enum) {
    /// One repo-relative file.
    file: []const u8,
    /// A fixed list of repo-relative files.
    files: []const []const u8,
    /// Every matching file under a directory.
    tree: Tree,

    pub const Tree = struct {
        dir: []const u8,
        /// File-name suffixes to include; empty means every file.
        suffixes: []const []const u8 = &.{},
        recursive: bool = true,
        /// Exact repo-relative paths to skip.
        exclude: []const []const u8 = &.{},
        /// Path substrings that prune subtrees.
        skip_dirs: []const []const u8 = &.{},
    };
};

/// One needle claim over a scope.
pub const Ban = struct {
    where: Where,
    kind: Kind,
    /// OR-set: `forbid` fires per present needle; `require` passes when any
    /// needle is present and names `needles[0]` when none is.
    needles: []const []const u8 = &.{},
    insensitive: bool = false,
    /// Forbid only when this substring is absent from the whole file.
    unless_contains: ?[]const u8 = null,
    on_missing: OnMissing = .violate,
    /// Tag for read-failure messages ("failed to read for {check} check").
    check: []const u8,
    why: []const u8,

    pub const Kind = enum { forbid, require, file_present };
    pub const OnMissing = enum { violate, skip };
};

const read_limit: std.Io.Limit = .limited(4 << 20);

/// A cached read outcome: contents on success, the error otherwise. A failed
/// read is reported at most once per `runBans` call, by the first row whose
/// `on_missing` is `.violate`.
const CacheEntry = struct {
    contents: ?[]const u8,
    err: anyerror = error.Unexpected,
    reported: bool = false,
};

/// Run every row, reading each scanned file at most once.
pub fn runBans(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    rows: []const Ban,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cache: std.StringHashMapUnmanaged(CacheEntry) = .empty;
    var tree_failures: std.StringHashMapUnmanaged(CacheEntry) = .empty;

    for (rows) |row| {
        switch (row.where) {
            .file => |path| try applyRowToFile(io, gpa, arena, root, &cache, violations, row, path),
            .files => |paths| for (paths) |path| {
                try applyRowToFile(io, gpa, arena, root, &cache, violations, row, path);
            },
            .tree => |tree| {
                var paths: std.ArrayList([]const u8) = .empty;
                defer paths.deinit(arena);
                collectFiles(io, arena, root, row.where, &paths) catch |err| {
                    const gop = try tree_failures.getOrPut(arena, tree.dir);
                    if (!gop.found_existing) gop.value_ptr.* = .{ .contents = null, .err = err };
                    if (row.on_missing == .violate and !gop.value_ptr.reported) {
                        gop.value_ptr.reported = true;
                        try appendViolation(gpa, violations, "{s}: failed to open for {s} check with {s}", .{
                            tree.dir, row.check, @errorName(gop.value_ptr.err),
                        });
                    }
                    continue;
                };
                for (paths.items) |path| {
                    try applyRowToFile(io, gpa, arena, root, &cache, violations, row, path);
                }
            },
        }
    }
}

/// Append every repo-relative file path a `Where` names. Tree-scope paths are
/// allocated with `arena`; file scopes append the row's static paths. A tree
/// whose directory cannot be opened returns the open error to the caller.
pub fn collectFiles(
    io: std.Io,
    arena: std.mem.Allocator,
    root: std.Io.Dir,
    where: Where,
    out: *std.ArrayList([]const u8),
) !void {
    switch (where) {
        .file => |path| try out.append(arena, path),
        .files => |paths| try out.appendSlice(arena, paths),
        .tree => |tree| {
            var dir = try root.openDir(io, tree.dir, .{ .iterate = true });
            defer dir.close(io);
            if (tree.recursive) {
                var walker = try dir.walk(arena);
                defer walker.deinit();
                while (try walker.next(io)) |entry| {
                    if (entry.kind != .file) continue;
                    if (!treeAdmits(tree, entry.path)) continue;
                    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ tree.dir, entry.path });
                    if (treeExcludes(tree, path)) continue;
                    try out.append(arena, path);
                }
            } else {
                var it = dir.iterate();
                while (try it.next(io)) |entry| {
                    if (entry.kind != .file) continue;
                    if (!treeAdmits(tree, entry.name)) continue;
                    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ tree.dir, entry.name });
                    if (treeExcludes(tree, path)) continue;
                    try out.append(arena, path);
                }
            }
        },
    }
}

fn treeAdmits(tree: Where.Tree, sub_path: []const u8) bool {
    for (tree.skip_dirs) |skip| {
        if (std.mem.indexOf(u8, sub_path, skip) != null) return false;
    }
    if (tree.suffixes.len == 0) return true;
    for (tree.suffixes) |suffix| {
        if (std.mem.endsWith(u8, sub_path, suffix)) return true;
    }
    return false;
}

fn treeExcludes(tree: Where.Tree, repo_path: []const u8) bool {
    for (tree.exclude) |excluded| {
        if (std.mem.eql(u8, repo_path, excluded)) return true;
    }
    return false;
}

fn applyRowToFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    root: std.Io.Dir,
    cache: *std.StringHashMapUnmanaged(CacheEntry),
    violations: *std.ArrayList([]const u8),
    row: Ban,
    path: []const u8,
) !void {
    switch (row.kind) {
        .file_present => {
            root.access(io, path, .{}) catch {
                try appendViolation(gpa, violations, "{s}: file must exist — {s}", .{ path, row.why });
            };
            return;
        },
        .forbid, .require => {},
    }

    const gop = try cache.getOrPut(arena, path);
    if (!gop.found_existing) {
        if (root.readFileAlloc(io, path, arena, read_limit)) |contents| {
            gop.value_ptr.* = .{ .contents = contents };
        } else |err| {
            gop.value_ptr.* = .{ .contents = null, .err = err };
        }
    }
    const contents = gop.value_ptr.contents orelse {
        if (row.on_missing == .violate and !gop.value_ptr.reported) {
            gop.value_ptr.reported = true;
            try appendViolation(gpa, violations, "{s}: failed to read for {s} check with {s}", .{
                path, row.check, @errorName(gop.value_ptr.err),
            });
        }
        return;
    };

    switch (row.kind) {
        .forbid => {
            if (row.unless_contains) |guard| {
                if (std.mem.indexOf(u8, contents, guard) != null) return;
            }
            for (row.needles) |needle| {
                if (contains(contents, needle, row.insensitive)) {
                    try appendViolation(gpa, violations, "{s}: contains `{s}` — {s}", .{ path, needle, row.why });
                }
            }
        },
        .require => {
            for (row.needles) |needle| {
                if (contains(contents, needle, row.insensitive)) return;
            }
            try appendViolation(gpa, violations, "{s}: missing `{s}` — {s}", .{ path, row.needles[0], row.why });
        },
        .file_present => unreachable,
    }
}

fn contains(haystack: []const u8, needle: []const u8, insensitive: bool) bool {
    if (insensitive) return std.ascii.findIgnoreCasePos(haystack, 0, needle) != null;
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── Migrated tables ────────────────────────────────────────────────────────

/// A human-doc-voice scope: one `Where` plus how the arrow check and the
/// `.agents/` link ban treat it. The phrase rows below and the bespoke
/// `banConnectiveArrowOutsideFences` walk in `source_check.zig` both drive off
/// this one list, so the scopes exist once.
pub const HumanDocScope = struct {
    where: Where,
    on_missing: Ban.OnMissing = .violate,
    /// `CONTRIBUTING.md` and `.devcontainer/README.md` are contributor /
    /// operator routers: phrase bans apply, `.agents/` links are allowed.
    ban_agents_links: bool = true,
};

pub const human_doc_voice_scopes = [_]HumanDocScope{
    .{
        .where = .{ .files = &.{
            "README.md",
            "SECURITY.md",
            "bindings/README.md",
            "bindings/DEVELOPING.md",
            "bindings/PACKAGING.md",
            "bindings/rust/README.md",
            "bindings/ts/README.md",
            "bindings/python/README.md",
            "bindings/racket/README.md",
            "examples/README.md",
            "apps/README.md",
            "apps/rooms/README.md",
            "ui/README.md",
        } },
        .on_missing = .skip,
    },
    .{ .where = .{ .file = "CONTRIBUTING.md" }, .on_missing = .skip, .ban_agents_links = false },
    .{ .where = .{ .file = ".devcontainer/README.md" }, .on_missing = .skip, .ban_agents_links = false },
    .{ .where = .{ .tree = .{ .dir = "docs", .suffixes = &.{".md"}, .recursive = false } } },
    .{ .where = .{ .tree = .{ .dir = "docs/protocol-diagrams", .suffixes = &.{".md"} } } },
    .{ .where = .{ .tree = .{ .dir = "site/content", .suffixes = &.{".smd"} } } },
};

const captp_io = @import("bans/captp_io.zig");
const transport = @import("bans/transport.zig");
const prose = @import("bans/prose.zig");
const layers = @import("bans/layers.zig");
const engine_peer_handle = @import("bans/engine_peer_handle.zig");
const binding_policy = @import("bans/binding_policy.zig");
const binding_relay_policy = @import("bans/binding_relay_policy.zig");
const onion = @import("bans/onion.zig");
const local_forward = @import("bans/local_forward.zig");
const authority = @import("bans/authority.zig");
const surfaces = @import("bans/surfaces.zig");
const failure = @import("bans/failure.zig");

pub const all: []const Ban =
    captp_io.captp_io_spine_table ++
    transport.transport_vocabulary ++
    prose.prerelease_prose ++
    prose.human_doc_voice ++
    prose.diagram_wire_vocabulary ++
    layers.clock_seam ++
    layers.actors_layer_purity ++
    layers.core_fifo_spine ++
    engine_peer_handle.rows ++
    layers.outbound_answer_cursor_rows ++
    layers.codec_decode_nesting_rows ++
    layers.readme_c_verb_names ++
    layers.discovery_dial_budget_rows ++
    layers.local_turn_budget_rows ++
    local_forward.hop_cap_rows ++
    binding_policy.unobserved_outcome_cap_rows ++
    failure.runtime_failure_journal_rows ++
    binding_policy.readiness_drain_cap_rows ++
    binding_policy.pending_dial_hint_probe_rows ++
    binding_policy.racket_relay_binary_rows ++
    binding_policy.stream_read_chunk_rows ++
    binding_policy.iroh_read_chunk_rows ++
    binding_policy.trace_payload_cap_rows ++
    binding_relay_policy.rows ++
    binding_policy.default_profile_rows ++
    binding_policy.secondary_failure_cap_rows ++
    layers.iroh_node_id_bytes_rows ++
    layers.iroh_direct_address_rows ++
    onion.service_key_cap_rows ++
    layers.uri_format_sizing_rows ++
    layers.relay_route_hint_cap_rows ++
    layers.goblins_runtime_portability ++
    layers.rooms_lib_layer ++
    layers.signature_arm_reads ++
    transport.transport_provider_architecture ++
    authority.sturdyref_authority ++
    authority.host_action_session_vocabulary ++
    surfaces.binding_public_api_retirements ++
    surfaces.deferral_markers ++
    surfaces.test_only_surface ++
    surfaces.rooms_env_namespace ++
    failure.binding_failure_surface ++
    authority.sturdyref_profile_authority ++
    failure.nonfatal_release_paths;

// ─── Tests ──────────────────────────────────────────────────────────────────

const TestRun = struct {
    tmp: std.testing.TmpDir,
    violations: std.ArrayList([]const u8),

    fn init() !TestRun {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const io = std.testing.io;
        try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello WORLD\nfoo\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "b.md", .data = "clean prose\n" });
        try tmp.dir.createDirPath(io, "sub");
        try tmp.dir.writeFile(io, .{ .sub_path = "sub/c.md", .data = "a needle here\n" });
        return .{ .tmp = tmp, .violations = .empty };
    }

    fn deinit(self: *TestRun) void {
        for (self.violations.items) |msg| std.testing.allocator.free(msg);
        self.violations.deinit(std.testing.allocator);
        self.tmp.cleanup();
    }

    fn run(self: *TestRun, rows: []const Ban) !void {
        try runBans(std.testing.io, std.testing.allocator, self.tmp.dir, &self.violations, rows);
    }

    fn expectMessages(self: *TestRun, expected: []const []const u8) !void {
        try std.testing.expectEqual(expected.len, self.violations.items.len);
        for (expected, self.violations.items) |want, got| {
            try std.testing.expectEqualStrings(want, got);
        }
    }
};

test "bans: forbid fires on a present needle and stays quiet on an absent one" {
    var t = try TestRun.init();
    defer t.deinit();
    try t.run(&.{
        .{ .where = .{ .file = "a.txt" }, .kind = .forbid, .needles = &.{"hello"}, .check = "t", .why = "no greetings" },
        .{ .where = .{ .file = "a.txt" }, .kind = .forbid, .needles = &.{"absent"}, .check = "t", .why = "unused" },
    });
    try t.expectMessages(&.{"a.txt: contains `hello` — no greetings"});
}

test "bans: require passes on a present needle and names needle0 on a miss" {
    var t = try TestRun.init();
    defer t.deinit();
    try t.run(&.{
        .{ .where = .{ .file = "a.txt" }, .kind = .require, .needles = &.{"foo"}, .check = "t", .why = "keep foo" },
        .{ .where = .{ .file = "a.txt" }, .kind = .require, .needles = &.{ "bar", "baz" }, .check = "t", .why = "needs bar" },
    });
    try t.expectMessages(&.{"a.txt: missing `bar` — needs bar"});
}

test "bans: OR-needles — forbid names each present needle; require passes on any" {
    var t = try TestRun.init();
    defer t.deinit();
    try t.run(&.{
        .{ .where = .{ .file = "a.txt" }, .kind = .forbid, .needles = &.{ "nope", "WORLD", "foo" }, .check = "t", .why = "w" },
        .{ .where = .{ .file = "a.txt" }, .kind = .require, .needles = &.{ "nope", "foo" }, .check = "t", .why = "unused" },
    });
    try t.expectMessages(&.{
        "a.txt: contains `WORLD` — w",
        "a.txt: contains `foo` — w",
    });
}

test "bans: unless_contains suppresses the forbid when the guard is present" {
    var t = try TestRun.init();
    defer t.deinit();
    try t.run(&.{
        .{ .where = .{ .file = "a.txt" }, .kind = .forbid, .needles = &.{"hello"}, .unless_contains = "foo", .check = "t", .why = "unused" },
        .{ .where = .{ .file = "a.txt" }, .kind = .forbid, .needles = &.{"hello"}, .unless_contains = "zzz", .check = "t", .why = "guard absent" },
    });
    try t.expectMessages(&.{"a.txt: contains `hello` — guard absent"});
}

test "bans: insensitive matches across case; sensitive does not" {
    var t = try TestRun.init();
    defer t.deinit();
    try t.run(&.{
        .{ .where = .{ .file = "a.txt" }, .kind = .forbid, .needles = &.{"world"}, .insensitive = true, .check = "t", .why = "ci" },
        .{ .where = .{ .file = "a.txt" }, .kind = .forbid, .needles = &.{"world"}, .check = "t", .why = "unused" },
    });
    try t.expectMessages(&.{"a.txt: contains `world` — ci"});
}

test "bans: on_missing violates once per file or skips silently" {
    var t = try TestRun.init();
    defer t.deinit();
    try t.run(&.{
        .{ .where = .{ .file = "missing.txt" }, .kind = .forbid, .needles = &.{"x"}, .on_missing = .skip, .check = "t", .why = "unused" },
        .{ .where = .{ .file = "missing.txt" }, .kind = .forbid, .needles = &.{"x"}, .check = "tag", .why = "unused" },
        .{ .where = .{ .file = "missing.txt" }, .kind = .require, .needles = &.{"x"}, .check = "tag2", .why = "unused" },
    });
    try t.expectMessages(&.{"missing.txt: failed to read for tag check with FileNotFound"});
}

test "bans: file_present checks existence without reading" {
    var t = try TestRun.init();
    defer t.deinit();
    try t.run(&.{
        .{ .where = .{ .file = "a.txt" }, .kind = .file_present, .check = "t", .why = "unused" },
        .{ .where = .{ .file = "missing.txt" }, .kind = .file_present, .check = "t", .why = "must land" },
    });
    try t.expectMessages(&.{
        "missing.txt: file must exist — must land",
    });
}

test "bans: files scope scans every listed file" {
    var t = try TestRun.init();
    defer t.deinit();
    try t.run(&.{
        .{ .where = .{ .files = &.{ "a.txt", "b.md" } }, .kind = .forbid, .needles = &.{"clean"}, .check = "t", .why = "w" },
    });
    try t.expectMessages(&.{"b.md: contains `clean` — w"});
}

test "bans: tree scope honors suffixes, recursion, and exclude" {
    var t = try TestRun.init();
    defer t.deinit();
    // Recursive .md tree reaches sub/c.md; a.txt is filtered by suffix.
    try t.run(&.{
        .{
            .where = .{ .tree = .{ .dir = ".", .suffixes = &.{".md"} } },
            .kind = .forbid,
            .needles = &.{"needle"},
            .check = "t",
            .why = "deep",
        },
    });
    try t.expectMessages(&.{"./sub/c.md: contains `needle` — deep"});

    // Shallow tree never reaches sub/; exclude drops an exact path.
    var shallow = try TestRun.init();
    defer shallow.deinit();
    try shallow.run(&.{
        .{
            .where = .{ .tree = .{ .dir = ".", .suffixes = &.{".md"}, .recursive = false } },
            .kind = .forbid,
            .needles = &.{"needle"},
            .check = "t",
            .why = "unused",
        },
        .{
            .where = .{ .tree = .{ .dir = ".", .suffixes = &.{".md"}, .exclude = &.{"./sub/c.md"} } },
            .kind = .forbid,
            .needles = &.{"needle"},
            .check = "t",
            .why = "unused",
        },
    });
    try shallow.expectMessages(&.{});
}
