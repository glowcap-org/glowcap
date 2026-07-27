//! Data-driven ban engine for `meta-check`: one table row per needle claim,
//! one runner that resolves scopes, caches file reads, and appends violations.
//! `tools/check/meta_check.zig` imports this file and runs `all` once per
//! gate invocation; bespoke checks that need more than substring presence
//! (require-groups, parsers, heuristics) stay in `meta_check.zig`.

const std = @import("std");

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

    pub const Kind = enum { forbid, require, file_absent, file_present };
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
        .file_absent => {
            root.access(io, path, .{}) catch return;
            try appendViolation(gpa, violations, "{s}: file must not exist — {s}", .{ path, row.why });
            return;
        },
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
        .file_absent, .file_present => unreachable,
    }
}

fn contains(haystack: []const u8, needle: []const u8, insensitive: bool) bool {
    if (insensitive) return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Twin of `meta_check.zig`'s `appendViolation`; the import direction
/// (`meta_check.zig` imports this file) forbids sharing the original.
fn appendViolation(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try violations.append(gpa, try std.fmt.allocPrint(gpa, fmt, args));
}

// ─── Migrated tables ────────────────────────────────────────────────────────

/// One CapTP I/O spine (the forbid half of `checkCaptpIoSpine`; its
/// require-groups and walks stay bespoke in `meta_check.zig`): no
/// reintroduced `BlockingHost`, `net.Loop` alias, dual `dialTcp`/`dialIroh`
/// Loop APIs, shared `ConnectTarget`, soft `@hasDecl(Backend` forks,
/// Bridge-owned dial grammar, socket-shaped Loop dial choreography, or OCapN
/// resolve on bare platform Backends.
const captp_io_spine_table: []const Ban = &.{
    .{
        .where = .{ .file = "src/driver/host.zig" },
        .kind = .file_absent,
        .check = "captp-io-spine",
        .why = "`BlockingHost` is deleted; Zig multi-session CapTP is Host + Bridge + completion.Loop",
    },
    .{
        .where = .{ .file = "src/driver/mod.zig" },
        .kind = .forbid,
        .needles = &.{"BlockingHost"},
        .check = "captp-io-spine",
        .why = "do not re-export `BlockingHost`; use `driver.Bridge` + `completion.Loop`",
    },
    .{
        .where = .{ .file = "src/net/mod.zig" },
        .kind = .forbid,
        .needles = &.{"pub const Loop ="},
        .check = "captp-io-spine",
        .why = "use `net.TcpLoop` or `completion.Loop(Backend)`, not a second concept named `Loop`",
    },
    .{
        .where = .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{ "pairedGoblins", "Offer.goblins(" },
        .check = "profile-names",
        .why = "protocol profiles do not wear an implementation's name; use `pairedV1_0Syrup` / `Offer.v1_0Syrup`",
    },
    .{
        .where = .{ .tree = .{ .dir = "test", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{ "pairedGoblins", "Offer.goblins(" },
        .check = "profile-names",
        .why = "protocol profiles do not wear an implementation's name; use `pairedV1_0Syrup` / `Offer.v1_0Syrup`",
    },
    .{
        .where = .{ .tree = .{ .dir = "examples", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{ "pairedGoblins", "Offer.goblins(" },
        .check = "profile-names",
        .why = "protocol profiles do not wear an implementation's name; use `pairedV1_0Syrup` / `Offer.v1_0Syrup`",
    },
    .{
        .where = .{ .file = "src/net/completion/loop.zig" },
        .kind = .forbid,
        .needles = &.{"pub fn dialTcp"},
        .check = "captp-io-spine",
        .why = "Bridge-facing dial is `dialLocator`; Backend owns `startDial`",
    },
    .{
        .where = .{ .file = "src/net/completion/loop.zig" },
        .kind = .forbid,
        .needles = &.{"pub fn dialIroh"},
        .check = "captp-io-spine",
        .why = "Bridge-facing dial is `dialLocator`; Backend owns `startDial`",
    },
    .{
        .where = .{ .file = "src/net/completion/loop.zig" },
        .kind = .forbid,
        .needles = &.{"pub const ConnectTarget = union"},
        .check = "captp-io-spine",
        .why = "no shared ConnectTarget union; each Backend declares its own associated type",
    },
    .{
        .where = .{ .file = "src/net/completion/loop.zig" },
        .kind = .forbid,
        .needles = &.{"@hasDecl(Backend, \""},
        .check = "captp-io-spine",
        .why = "total Backend contract via `validateBackend`; no soft dial/shutdown optionality at call sites",
    },
    .{
        .where = .{ .file = "src/net/completion/loop.zig" },
        .kind = .forbid,
        .needles = &.{"openDialFd"},
        .check = "captp-io-spine",
        .why = "socket-shaped Loop dial choreography is gone; Backend.startDial owns dial start",
    },
    .{
        .where = .{ .file = "src/net/completion/loop.zig" },
        .kind = .forbid,
        .needles = &.{"abandonDialFd"},
        .check = "captp-io-spine",
        .why = "Backend.startDial owns cleanup on failed start; no Loop abandonDialFd",
    },
    .{
        .where = .{ .file = "src/net/completion/loop.zig" },
        .kind = .forbid,
        .needles = &.{"submitIrohConnect"},
        .check = "captp-io-spine",
        .why = "optional `@hasDecl(submitIrohConnect)` is gone; Backends implement `startDial`",
    },
    .{
        .where = .{ .file = "src/net/completion/loop.zig" },
        .kind = .forbid,
        .needles = &.{"pub fn dial(self"},
        .check = "captp-io-spine",
        .why = "only public dial verb is `dialLocator`; `fn dial` stays private (no ConnectTarget at the Loop boundary)",
    },
    .{
        .where = .{ .file = "src/net/transport/tcp.zig" },
        .kind = .forbid,
        .needles = &.{"pub fn resolveDialAddress"},
        .check = "captp-io-spine",
        .why = "TCP address grammar lives only in `tcp.DialResolver.resolve`",
    },
    .{
        .where = .{ .file = "src/net/transport/iroh.zig" },
        .kind = .forbid,
        .needles = &.{"submitIrohConnect"},
        .check = "captp-io-spine",
        .why = "iroh dials through `Locator.resolve` + `startDial`, not a parallel connect verb",
    },
    .{
        .where = .{ .file = "src/net/completion/uring.zig" },
        .kind = .forbid,
        .needles = &.{"resolveConnectTarget"},
        .check = "captp-io-spine",
        .why = "platform Backend has no OCapN resolve; TCP resolve lives on `tcp.DialResolver`",
    },
    .{
        .where = .{ .file = "src/net/completion/kqueue.zig" },
        .kind = .forbid,
        .needles = &.{"resolveConnectTarget"},
        .check = "captp-io-spine",
        .why = "platform Backend has no OCapN resolve; TCP resolve lives on `tcp.DialResolver`",
    },
    .{
        .where = .{ .file = "src/net/mod.zig" },
        .kind = .forbid,
        .needles = &.{"tcp_backend"},
        .check = "captp-io-spine",
        .why = "`TcpLoop` is `Loop(platform, tcp.DialResolver)`; no forwarding `tcp_backend` wrapper",
    },
    .{
        .where = .{ .file = "src/net/transport/iroh.zig" },
        .kind = .forbid,
        .needles = &.{"@import(\"../stream_shim.zig\")"},
        .check = "captp-io-spine",
        .why = "iroh is its own module root under transport/; reach stream_shim via net.stream_shim (ADR-0040)",
    },
    .{
        .where = .{ .file = "src/net/mod.zig" },
        .kind = .forbid,
        .needles = &.{"@import(\"completion/tcp_keepalive.zig\")"},
        .check = "captp-io-spine",
        .why = "public Keepalive is net.socket / net.Keepalive — no second door into completion/",
    },
    .{
        .where = .{ .file = "src/net/transport/tcp.zig" },
        .kind = .forbid,
        .needles = &.{"@import(\"../completion/"},
        .check = "captp-io-spine",
        .why = "tcp netlayer reaches socket ops through net.socket, never completion/ internals",
    },
    .{
        .where = .{ .file = "src/net/transport/tcp_keyed.zig" },
        .kind = .forbid,
        .needles = &.{"@import(\"../completion/"},
        .check = "captp-io-spine",
        .why = "keyed-tcp netlayer reaches socket ops through net.socket, never completion/ internals",
    },
    .{
        .where = .{ .file = "src/net/transport/iroh.zig" },
        .kind = .forbid,
        .needles = &.{"@import(\"../completion/"},
        .check = "captp-io-spine",
        .why = "iroh netlayer reaches socket ops through net.socket, never completion/ internals",
    },
    .{
        .where = .{ .file = "src/net/completion/tcp_backend.zig" },
        .kind = .file_absent,
        .check = "captp-io-spine",
        .why = "tcp_backend forwarding wrapper is deleted; resolve is `tcp.DialResolver`, I/O is the platform Backend",
    },
    .{
        .where = .{ .file = "src/driver/core/mod.zig" },
        .kind = .forbid,
        .needles = &.{"pub const gc ="},
        .check = "captp-io-spine",
        .why = "export emitStatelessAfter only; gc.zig stays Served-private",
    },
    .{
        .where = .{ .file = "src/driver/core/host.zig" },
        .kind = .forbid,
        .needles = &.{"pub const HostAction"},
        .check = "captp-io-spine",
        .why = "HostAction lives on driver.core barrel, not Host type home",
    },
    .{
        .where = .{ .file = "src/driver/core/host.zig" },
        .kind = .forbid,
        .needles = &.{"pub const CrossedHellos"},
        .check = "captp-io-spine",
        .why = "CrossedHellos lives on driver.core barrel, not Host type home",
    },
    .{
        .where = .{ .file = "src/ocapn/codec/dispatch.zig" },
        .kind = .forbid,
        .needles = &.{"pub const registry"},
        .check = "captp-io-spine",
        .why = "codec.registry is the authority; dispatch keeps it private",
    },
    .{
        .where = .{ .file = "src/ocapn/codec/dispatch.zig" },
        .kind = .forbid,
        .needles = &.{"pub const framing"},
        .check = "captp-io-spine",
        .why = "export Prefix only; framing stays private to dispatch",
    },
    .{
        .where = .{ .file = "src/driver/mod.zig" },
        .kind = .forbid,
        .needles = &.{"LoopBridge"},
        .check = "captp-io-spine",
        .why = "call sites use `Bridge(net.TcpLoop)`; no `LoopBridge` alias",
    },
    .{
        .where = .{ .file = "src/driver/loop_bridge.zig" },
        .kind = .file_absent,
        .check = "captp-io-spine",
        .why = "`loop_bridge.zig` is renamed; the file is `src/driver/bridge.zig` matching `driver.Bridge`",
    },
    .{
        .where = .{ .file = "src/driver/bridge.zig" },
        .kind = .forbid,
        .needles = &.{"resolveDialAddress"},
        .check = "captp-io-spine",
        .why = "locator→connect belongs on `Locator.resolve` / `Loop.dialLocator`",
    },
    // retire-by: the next rewrite of src/driver/bridge.zig's dial comments —
    // retire this prose needle in that same diff.
    .{
        .where = .{ .file = "src/driver/bridge.zig" },
        .kind = .forbid,
        .needles = &.{"Backend resolves"},
        .check = "captp-io-spine",
        .why = "Locator resolves; Backend startDial connects — stale comment re-teaches the deleted design",
    },
    .{
        .where = .{ .file = "src/driver/bridge.zig" },
        .kind = .forbid,
        .needles = &.{"net.tcp"},
        .check = "captp-io-spine",
        .why = "Bridge speaks OCapN locator parts only; TCP grammar stays in the netlayer Locator",
    },
    .{
        .where = .{ .file = "src/driver/bridge.zig" },
        .kind = .forbid,
        .needles = &.{"ConnectTarget"},
        .check = "captp-io-spine",
        .why = "Bridge must not name Backend connect targets; use `Loop.dialLocator`",
    },
    .{
        .where = .{ .file = "src/driver/bridge.zig" },
        .kind = .forbid,
        .needles = &.{"IpAddress"},
        .check = "captp-io-spine",
        .why = "Bridge must not speak net addresses; use OCapN locator parts",
    },
    .{
        .where = .{ .file = "src/driver/bridge.zig" },
        .kind = .forbid,
        .needles = &.{"transport, \"iroh\""},
        .check = "captp-io-spine",
        .why = "no Bridge dial-dispatch on transport strings; Locator.resolve owns that",
    },
    .{
        .where = .{ .file = "src/net/transport/iroh.zig" },
        .kind = .forbid,
        .needles = &.{"Backend.Locator"},
        .check = "captp-io-spine",
        .why = "Locator is module-level `iroh.DialResolver`, not nested on Backend",
    },
};

/// Living-state surfaces the transport-vocabulary rows scan. Shared with the
/// bespoke keyed-tcp resident-count heuristic in `meta_check.zig`.
pub const transport_vocabulary_paths: []const []const u8 = &.{
    ".agents/rules/architecture.md",
    "AGENTS.md",
    "CONTRIBUTING.md",
    "README.md",
    "docs/architecture.md",
    "docs/boundaries.md",
    "docs/ladder.md",
    "docs/shipped.md",
    "docs/roadmap.md",
    "docs/capabilities.md",
    "docs/vision.md",
    "bindings/README.md",
    "bindings/python/README.md",
    "bindings/rust/README.md",
    "bindings/racket/README.md",
    "bindings/ts/README.md",
    "examples/README.md",
    "apps/accountability-on-pancake/README.md",
    "site/content/transports.smd",
    "site/content/modules.smd",
    "site/content/examples.smd",
};

/// CapTP is transport-agnostic; only netlayers name transports. Living-state
/// surfaces that equate pancake/OCapN with TCP fail here so the vocabulary
/// cannot rot back. (The keyed-tcp resident-count heuristic stays bespoke in
/// `meta_check.zig`'s `checkTransportVocabulary`.)
const transport_vocabulary: []const Ban = &.{
    .{
        .where = .{ .files = transport_vocabulary_paths },
        .kind = .forbid,
        .needles = &.{"binds the TCP socket"},
        .check = "transport-vocabulary",
        .why = "`net` realizes netlayer residents over byte streams; CapTP never names a transport",
    },
    .{
        .where = .{ .files = transport_vocabulary_paths },
        .kind = .forbid,
        .needles = &.{"pancake has two channels"},
        .check = "transport-vocabulary",
        .why = "name netlayer symbols and confidentiality postures; CapTP is identical across them",
    },
    .{
        .where = .{ .files = transport_vocabulary_paths },
        .kind = .forbid,
        .needles = &.{"OCapN/TCP"},
        .check = "transport-vocabulary",
        .why = "say an OCapN session on the `tcp` netlayer — CapTP is not TCP-based",
    },
    .{
        .where = .{ .files = transport_vocabulary_paths },
        .kind = .forbid,
        .needles = &.{"A byte-stream netlayer ships in `net`"},
        .check = "transport-vocabulary",
        .why = "`net` is the adapter + netlayer contract; CapTP stays above it",
    },
    .{
        .where = .{ .files = transport_vocabulary_paths },
        .kind = .forbid,
        .needles = &.{"Sessions above the socket"},
        .check = "transport-vocabulary",
        .why = "sessions live above I/O / the netlayer, not specifically TCP sockets",
    },
    .{
        .where = .{ .files = transport_vocabulary_paths },
        .kind = .forbid,
        .needles = &.{"pure asyncio over TCP"},
        .check = "transport-vocabulary",
        .why = "binding core is the byte-fed host; transport is chosen by locator",
    },
};

/// The high-precision transition phrases the prerelease-language rule bans
/// from first-read surfaces (README.md, AGENTS.md, CONTRIBUTING.md, and every
/// top-level docs/*.md), case-insensitively. Softer tells ("previously",
/// "originally") have honest uses, so they stay governed by the prose rule
/// alone.
const prerelease_language: []const Ban = prerelease_rows: {
    const phrases = [_][]const u8{ "formerly", "renamed from", "pre-1.0", "pre-publication" };
    const scopes = [_]Where{
        .{ .files = &.{ "README.md", "AGENTS.md", "CONTRIBUTING.md" } },
        .{ .tree = .{ .dir = "docs", .suffixes = &.{".md"}, .recursive = false } },
    };
    var rows: []const Ban = &.{};
    for (scopes) |scope| {
        for (phrases) |phrase| {
            rows = rows ++ &[_]Ban{.{
                .where = scope,
                .kind = .forbid,
                .needles = &.{phrase},
                .insensitive = true,
                .check = "prerelease-language",
                .why = "prerelease phrase; first-read surfaces describe the current shape (prerelease-language rule)",
            }};
        }
    }
    break :prerelease_rows rows;
};

/// A human-doc-voice scope: one `Where` plus how the arrow check and the
/// `.agents/` link ban treat it. The phrase rows below and the bespoke
/// `banConnectiveArrowOutsideFences` walk in `meta_check.zig` both drive off
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
            "bindings/rust/README.md",
            "bindings/ts/README.md",
            "bindings/python/README.md",
            "bindings/racket/README.md",
            "examples/README.md",
            "apps/README.md",
        } },
        .on_missing = .skip,
    },
    .{ .where = .{ .file = "CONTRIBUTING.md" }, .on_missing = .skip, .ban_agents_links = false },
    .{ .where = .{ .file = ".devcontainer/README.md" }, .on_missing = .skip, .ban_agents_links = false },
    .{ .where = .{ .tree = .{ .dir = "docs", .suffixes = &.{".md"}, .recursive = false } } },
    .{ .where = .{ .tree = .{ .dir = "docs/protocol-diagrams", .suffixes = &.{".md"} } } },
    .{ .where = .{ .tree = .{ .dir = "site/content", .suffixes = &.{".smd"} } } },
};

/// Human first-read docs must stay speech for people (doc-voice), not executor
/// scaffolding. CapTP vocabulary cheat-sheets ("sticky notes") belong in
/// `.agents/rules/architecture.md`. ADRs under `docs/decisions/` and
/// `.agents/**` are out of scope on purpose.
const human_doc_voice: []const Ban = voice_rows: {
    const phrases = [_]struct { needle: []const u8, why: []const u8 }{
        .{ .needle = "CapTP sticky note", .why = "CapTP vocabulary cheat-sheets live in the architecture agent rule, not human docs (doc-voice)" },
        .{ .needle = "Meta scaffolding", .why = "agent scaffolding vocabulary belongs under `.agents/`, not human inventory (doc-voice)" },
        .{ .needle = "deliberately boring", .why = "self-awarded praise; state the surface plainly (doc-voice)" },
        .{ .needle = "boring on purpose", .why = "self-awarded praise; state the surface plainly (doc-voice)" },
        .{ .needle = "next audit", .why = "executor framing; write for a human re-read (doc-voice)" },
        .{ .needle = "honest exception", .why = "self-awarded praise on the project's own carve-out; name the exception plainly (doc-voice)" },
        .{ .needle = "honest scope", .why = "self-awarded praise; state the scope plainly (doc-voice)" },
        .{ .needle = "worth stating", .why = "throat-clearing; just state it (doc-voice)" },
        .{ .needle = "deliberately not", .why = "intent-adverb hedge; state the reason or drop the adverb (doc-voice)" },
        // The doc-voice Insider Words table, for the terms that never have a
        // legitimate identifier spelling in these files. `gate`, `oracle`, and
        // `dogfood` are left out on purpose: each names a real build step or
        // directory that human pages quote verbatim.
        .{ .needle = "living-state", .why = "insider word; write \"docs kept in step with today's code\" (doc-voice)" },
        .{ .needle = "hermetic", .why = "insider word; write \"in-tree\" or \"no network or external services\" (doc-voice)" },
        .{ .needle = "pre-1.0", .why = "prerelease-language: state the present boundary, not the transition producing it" },
        .{ .needle = "pre-publication", .why = "prerelease-language: state the present boundary, not the transition producing it" },
    };
    var rows: []const Ban = &.{};
    for (human_doc_voice_scopes) |scope| {
        for (phrases) |phrase| {
            rows = rows ++ &[_]Ban{.{
                .where = scope.where,
                .kind = .forbid,
                .needles = &.{phrase.needle},
                .insensitive = true,
                .on_missing = scope.on_missing,
                .check = "human-doc-voice",
                .why = phrase.why,
            }};
        }
        if (scope.ban_agents_links) {
            rows = rows ++ &[_]Ban{.{
                .where = scope.where,
                .kind = .forbid,
                .needles = &.{".agents/"},
                .on_missing = scope.on_missing,
                .check = "human-doc-voice",
                .why = "agent scaffolding stays under `.agents/**`; human docs state the rule in speech (doc-voice)",
            }};
        }
    }
    break :voice_rows rows;
};

/// Diagram wire vocabulary: an op's target ("to ...") is a `desc:export` or
/// `desc:answer` — the spec's to-desc grammar. The import-side descriptors
/// introduce references; they are never a delivery target. The wrong spelling
/// reads plausibly and survived review once, so the gate holds it.
const diagram_wire_vocabulary: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "docs/protocol-diagrams", .suffixes = &.{".md"} } },
        .kind = .forbid,
        .needles = &.{"to desc:import-object"},
        .insensitive = true,
        .check = "diagram-wire-vocabulary",
        .why = "a deliver target is desc:export or desc:answer; desc:import-object only introduces (CapTP Specification, op:deliver to-desc)",
    },
    .{
        .where = .{ .tree = .{ .dir = "docs/protocol-diagrams", .suffixes = &.{".md"} } },
        .kind = .forbid,
        .needles = &.{"to desc:import-promise"},
        .insensitive = true,
        .check = "diagram-wire-vocabulary",
        .why = "a deliver target is desc:export or desc:answer; desc:import-promise only introduces (CapTP Specification, op:deliver to-desc)",
    },
};

/// The owning one-call C session verbs (`pancake_tcp_session_*`, ADR-0062)
/// are spelled on the tcp archive alone. A second transport must not copy
/// that family: before an owning inproc or iroh session surface lands, the
/// session choreography moves to one transport-neutral home and the
/// transports keep only their connect constructors (see docs/boundaries.md,
/// "One owning C session family").
const session_family_home: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src/c_abi", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{ "pancake_inproc_session_", "pancake_iroh_session_" },
        .check = "session-family-home",
        .why = "a second transport does not copy the tcp session-verb family; hoist the choreography to one transport-neutral home first (docs/boundaries.md)",
    },
};

/// The monotonic clock is consolidated onto one seam, `src/net/clock.zig`, so a
/// component that reads wall-clock or monotonic time goes through it rather than
/// calling the OS clock by hand. A stray `clock_gettime` anywhere else in the
/// core silently reopens the drift the consolidation closed.
const clock_seam: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"}, .exclude = &.{"src/net/clock.zig"} } },
        .kind = .forbid,
        .needles = &.{"clock_gettime"},
        .check = "clock-seam",
        .why = "read monotonic time through src/net/clock.zig's seam (nowMonotonicMs/nowMs), never a hand-rolled clock_gettime",
    },
};

/// The V1.0 resolver descriptor (`resolve_me_desc`) is CapTP wire knowledge:
/// mapping a resolver-only deliver to the virtual answer the engine installed
/// is the engine's job, reached through `Peer.answerForDeliver`. The actor
/// layer must never decode it, because `actors` adds no CapTP semantics the
/// engine lacks (architecture rule). This holds the boundary the
/// `answerForDeliver` seam established, so the vat's old inline descriptor
/// walk cannot creep back.
const actors_layer_purity: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src/actors", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{"resolve_me_desc"},
        .check = "actors-layer-purity",
        .why = "the V1.0 resolver descriptor is CapTP wire knowledge; route a resolver-only deliver's answer through `Peer.answerForDeliver`, never by decoding resolve_me_desc in the actor layer (architecture: actors adds no CapTP semantics the engine lacks)",
    },
};

/// The host-session and host-turn C verbs are `pancake_host_session_*` and
/// `pancake_host_turn_*`. ADR-0079 retired the binding `Connection` concept, so
/// no `conn_*` export exists. A backticked `conn_` shorthand in the bindings
/// README names a symbol a C consumer cannot grep, so the drift fails here.
const readme_c_verb_names: []const Ban = &.{
    .{
        .where = .{ .file = "bindings/README.md" },
        .kind = .forbid,
        .needles = &.{"`conn_"},
        .check = "readme-c-verb-names",
        .why = "no `conn_*` C export exists (ADR-0079 retired the binding Connection concept); name the real `pancake_host_session_*` or `pancake_iroh_conn_*` verb a consumer can grep",
    },
};

/// The unobserved-outcome FIFO cap is one policy number the three async
/// bindings share, mirrored in the bindings README. It is a hand-repeated
/// literal with no C ABI constant to reflect, so this holds the four in
/// lockstep: bumping the cap fails here until every copy and the README move
/// together.
const unobserved_outcome_cap_rows: []const Ban = &.{
    .{
        .where = .{ .file = "bindings/ts/stack/host.ts" },
        .kind = .require,
        .needles = &.{"MAX_UNOBSERVED_OUTCOMES = 1024"},
        .check = "unobserved-outcome-cap",
        .why = "the unobserved-outcome FIFO cap is 1024 across TS, Python, and Rust and the bindings README; move all four together",
    },
    .{
        .where = .{ .file = "bindings/rust/src/host.rs" },
        .kind = .require,
        .needles = &.{"MAX_UNOBSERVED_OUTCOMES: usize = 1024"},
        .check = "unobserved-outcome-cap",
        .why = "the unobserved-outcome FIFO cap is 1024 across TS, Python, and Rust and the bindings README; move all four together",
    },
    .{
        .where = .{ .file = "bindings/python/pancake/_host.py" },
        .kind = .require,
        .needles = &.{"_MAX_UNOBSERVED_OUTCOMES = 1024"},
        .check = "unobserved-outcome-cap",
        .why = "the unobserved-outcome FIFO cap is 1024 across TS, Python, and Rust and the bindings README; move all four together",
    },
    .{
        .where = .{ .file = "bindings/README.md" },
        .kind = .require,
        .needles = &.{"1024 in TypeScript, Python, and Rust"},
        .check = "unobserved-outcome-cap",
        .why = "the bindings README states the unobserved-outcome FIFO cap (1024); keep it in step with the three host constants",
    },
};

const goblins_runtime_portability: []const Ban = &.{
    .{
        .where = .{ .tree = .{
            .dir = "interop/goblins_interop",
            .suffixes = &.{ ".zig", ".py", ".rs", ".ts", ".rkt" },
        } },
        .kind = .forbid,
        // The class, not one spelling: /usr/bin, /usr/local/bin, and
        // /opt/homebrew/bin all end this way.
        .needles = &.{"/bin/racket"},
        .check = "Goblins runtime portability",
        .why = "live interop resolves `racket` through PATH; an absolute path pins one machine's layout",
    },
};

/// Every migrated table, run once per gate invocation.
pub const all: []const Ban =
    captp_io_spine_table ++
    transport_vocabulary ++
    prerelease_language ++
    human_doc_voice ++
    diagram_wire_vocabulary ++
    session_family_home ++
    clock_seam ++
    actors_layer_purity ++
    readme_c_verb_names ++
    unobserved_outcome_cap_rows ++
    goblins_runtime_portability;

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

test "bans: file_absent and file_present check existence without reading" {
    var t = try TestRun.init();
    defer t.deinit();
    try t.run(&.{
        .{ .where = .{ .file = "a.txt" }, .kind = .file_absent, .check = "t", .why = "must go" },
        .{ .where = .{ .file = "missing.txt" }, .kind = .file_absent, .check = "t", .why = "unused" },
        .{ .where = .{ .file = "a.txt" }, .kind = .file_present, .check = "t", .why = "unused" },
        .{ .where = .{ .file = "missing.txt" }, .kind = .file_present, .check = "t", .why = "must land" },
    });
    try t.expectMessages(&.{
        "a.txt: file must not exist — must go",
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
