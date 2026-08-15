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
    if (insensitive) return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── Migrated tables ────────────────────────────────────────────────────────

/// One CapTP I/O spine (the forbid half of `checkCaptpIoSpine`; its
/// require-groups and walks stay bespoke in `source_check.zig`): no
/// reintroduced `BlockingHost`, `net.Loop` alias, dual `dialTcp`/`dialIroh`
/// Loop APIs, shared `ConnectTarget`, soft `@hasDecl(Backend` forks,
/// Bridge-owned dial grammar, socket-shaped Loop dial choreography, or OCapN
/// resolve on bare platform Backends.
const captp_io_spine_table: []const Ban = &.{
    .{
        // The owning host face (ADR-0090) lives here and *embeds* the one
        // `driver_core.Host`; what stays banned is the deleted `BlockingHost`
        // shape, a parallel multi-session type that duplicated the core.
        .where = .{ .file = "src/driver/host_runtime.zig" },
        .kind = .forbid,
        .needles = &.{"BlockingHost"},
        .check = "captp-io-spine",
        .why = "`BlockingHost` is deleted; the owning face embeds driver_core.Host (ADR-0090), never a parallel core",
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
        .why = "iroh dials through `DialResolver.resolve` + `startDial`, not a parallel connect verb",
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
        .where = .{ .file = "src/net/transport/tcp_key_addressed.zig" },
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
        .where = .{ .file = "src/driver/bridge.zig" },
        .kind = .forbid,
        .needles = &.{"resolveDialAddress"},
        .check = "captp-io-spine",
        .why = "locator→connect belongs on `DialResolver.resolve` / `Loop.dialLocator`",
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
        .why = "no Bridge dial-dispatch on transport strings; DialResolver.resolve owns that",
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
/// bespoke keyed-tcp resident-count heuristic in `source_check.zig`.
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
    "bindings/DEVELOPING.md",
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
/// `source_check.zig`'s `checkTransportVocabulary`.)
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

/// High-precision transition phrases forbidden by the prerelease rule
/// from first-read surfaces (README.md, AGENTS.md, CONTRIBUTING.md, and every
/// top-level docs/*.md), case-insensitively. Softer tells ("previously",
/// "originally") have honest uses, so they stay governed by the prose rule
/// alone.
const prerelease_prose: []const Ban = prerelease_rows: {
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
                .check = "prerelease-prose",
                .why = "first-read surfaces describe the current shape, not its migration history (prerelease rule)",
            }};
        }
    }
    break :prerelease_rows rows;
};

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
        .{ .needle = "pre-1.0", .why = "prerelease: state the present boundary, not the transition producing it" },
        .{ .needle = "pre-publication", .why = "prerelease: state the present boundary, not the transition producing it" },
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
        .where = .{ .file = "bindings/DEVELOPING.md" },
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
        .where = .{ .file = "bindings/ts/runtime/host.ts" },
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
/// A borrowed `Signature` is two arms because two codecs spell one value two
/// ways: Syrup carries the halves, Cap'n Proto the concatenation. Reading
/// either arm by name outside the type's own file is therefore a claim about
/// which codec decoded the frame, which no consumer of a codec-neutral view is
/// entitled to make, and the arm that is not active panics. `Signature.eql`
/// answers across arms without allocating; every comparison goes through it.
const signature_arm_reads: []const Ban = &.{
    .{
        .where = .{ .tree = .{
            .dir = "src",
            .suffixes = &.{".zig"},
            .exclude = &.{"src/ocapn/model/view_records.zig"},
        } },
        .kind = .forbid,
        .needles = &.{ "signature.raw", "signature.halves" },
        .check = "signature-arm-reads",
        .why = "compare borrowed signatures through `Signature.eql`, which is total across arms; naming an arm assumes a codec and panics on the other",
    },
};

const transport_provider_architecture: []const Ban = &.{
    .{
        .where = .{ .file = "include/pancake_transport_provider.h" },
        .kind = .require,
        .needles = &.{"PancakeMultiplexedClaimExternalFn claim_external;"},
        .check = "transport-provider-architecture",
        .why = "the generated multiplexed table must preserve claim_external's semantic callback type even though Zig aliases it structurally",
    },
    .{
        .where = .{ .file = "src/c_abi/shared/locator.zig" },
        .kind = .forbid,
        .needles = &.{ "@import(\"model\")", "clonePeerLocator", "fromView", "project(", "pub fn " },
        .check = "transport-provider-architecture",
        .why = "shared/locator.zig is archive-neutral POD vocabulary only; OCapN semantics and model projection live in their owning modules",
    },
    .{
        .where = .{ .tree = .{
            .dir = "src",
            .suffixes = &.{".zig"},
            .exclude = &.{"src/c_abi/shared/locator.zig"},
        } },
        .kind = .forbid,
        .needles = &.{"PANCAKE_LOCATOR_VIEW_ABI_VERSION: u32 ="},
        .check = "transport-provider-architecture",
        .why = "the locator ABI version and layout have one physical authority in c_abi/shared/locator.zig; other modules may only re-export it",
    },
    .{
        .where = .{ .tree = .{ .dir = "src/c_abi/driver", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{ "net.tcp", "pancake_tcp_", "c_abi_net_transport_tcp", "transport/tcp" },
        .check = "transport-provider-architecture",
        .why = "the generic driver consumes PancakeTransportProvider and must not depend on a concrete TCP implementation",
    },
    .{
        .where = .{ .file = "src/c_abi/driver/provider_registry.zig" },
        .kind = .file_present,
        .check = "transport-provider-architecture",
        .why = "provider package validation, execution-model adapters, copied tables, and leases have one driver-side owner",
    },
    .{
        .where = .{ .file = "src/c_abi/driver/loop.zig" },
        .kind = .forbid,
        .needles = &.{ "StreamAdapter", "MultiplexedAdapter", "decodeTransportProfile", "PancakeStreamTransport", "PancakeMultiplexedTransport" },
        .check = "transport-provider-architecture",
        .why = "loop.zig owns loop lifecycle and event choreography; provider ABI adaptation belongs to ProviderRegistry",
    },
    .{
        .where = .{ .tree = .{
            .dir = "src/c_abi",
            .suffixes = &.{".zig"},
        } },
        .kind = .forbid,
        .needles = &.{
            "PancakeStreamListenerLocatorFn",
            "PancakeStreamListenerAdvertiseFn",
            "PancakeMultiplexedListenerLocatorFn",
            "PancakeMultiplexedListenerAdvertiseFn",
        },
        .check = "transport-provider-architecture",
        .why = "stream and multiplexed listeners share one locator projection and canonicalization ABI; only their I/O execution models differ",
    },
    .{
        .where = .{ .files = &.{ "include/pancake_transport_provider.h", "tools/gen/header/transport_provider.zig" } },
        .kind = .forbid,
        .needles = &.{
            "PancakeStreamListenerLocatorFn",
            "PancakeStreamListenerAdvertiseFn",
            "PancakeMultiplexedListenerLocatorFn",
            "PancakeMultiplexedListenerAdvertiseFn",
        },
        .check = "transport-provider-architecture",
        .why = "the generated C authority must preserve the execution-model-neutral listener locator callback ABI",
    },
    .{
        .where = .{ .file = "include/pancake_transport_provider.h" },
        .kind = .require,
        .needles = &.{
            "PancakeTransportListenerLocatorFn listener_locator;",
            "PancakeTransportListenerAdvertiseFn listener_advertise;",
        },
        .check = "transport-provider-architecture",
        .why = "both provider execution tables consume the common listener locator callback contract",
    },
    .{
        .where = .{ .file = "src/c_abi/net_transport/tcp/mod.zig" },
        .kind = .forbid,
        .needles = &.{ "parseKnown(", "IpAddress.connect(", ".server.accept(", "stream.reader(", "stream.writer(" },
        .check = "transport-provider-architecture",
        .why = "the TCP C ABI projects net.tcp's admitted profile/runtime; it must not reconstruct semantics or realize sockets independently",
    },
    .{
        .where = .{ .files = &.{ "include/pancake_driver.h", "tools/gen/header/driver.zig" } },
        .kind = .forbid,
        .needles = &.{ "typedef struct PancakeTransportProfile", "typedef struct PancakeTransportProvider", "struct PancakeTransportProvider {" },
        .check = "transport-provider-architecture",
        .why = "provider layouts belong only to the standalone pancake_transport_provider.h authority",
    },
    .{
        .where = .{ .file = "include/pancake_transport_provider.h" },
        .kind = .file_present,
        .check = "transport-provider-architecture",
        .why = "transport archives and the driver share one standalone provider ABI header",
    },
    .{
        .where = .{ .file = "include/pancake_transport_provider.h" },
        .kind = .require,
        .needles = &.{"PancakeStreamReadFn read;"},
        .check = "transport-provider-architecture",
        .why = "ABI-identical read and metadata callbacks still need role-specific C typedefs; field-aware generation preserves the provider contract's meaning",
    },
    .{
        .where = .{ .file = "include/pancake_transport_provider.h" },
        .kind = .require,
        .needles = &.{"PancakeStreamWriteAllFn write_all;"},
        .check = "transport-provider-architecture",
        .why = "the stream execution model exposes an explicit write-all status callback; byte-count writes belong only to multiplexed try_write",
    },
    .{
        .where = .{ .file = "include/pancake_transport_provider.h" },
        .kind = .require,
        .needles = &.{"PancakeStreamConnCloseFn conn_close;"},
        .check = "transport-provider-architecture",
        .why = "ABI-identical close callbacks still need role-specific C typedefs; field-aware generation preserves the provider contract's meaning",
    },
    .{
        .where = .{ .file = "include/pancake_transport_provider.h" },
        .kind = .require,
        .needles = &.{"PancakeTransportRetainFn retain;"},
        .check = "transport-provider-architecture",
        .why = "the provider lease acquire callback must keep its semantic C typedef despite sharing a signature with readiness callbacks",
    },
    .{
        .where = .{ .file = "include/pancake_transport_provider.h" },
        .kind = .require,
        .needles = &.{"PancakeTransportReleaseFn release;"},
        .check = "transport-provider-architecture",
        .why = "the provider lease release callback must keep its semantic C typedef despite sharing a signature with listener callbacks",
    },
    .{
        .where = .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{ "pancake_driver_new", "pancake_driver_host", "pancake_driver_add_resident", "pancake_iroh_loop_resident" },
        .check = "transport-provider-architecture",
        .why = "the provider migration is complete: drivers adopt Hosts and install archive-owned packages through the generic registration ABI",
    },
    .{
        .where = .{ .file = "src/c_abi/host/archive.zig" },
        .kind = .file_present,
        .check = "transport-provider-architecture",
        .why = "Host exports must be rooted by the Host archive rather than an importing consumer",
    },
    .{
        .where = .{ .file = "src/c_abi/driver/symbols.zig" },
        .kind = .forbid,
        .needles = &.{".name = \"pancake_host_"},
        .check = "transport-provider-architecture",
        .why = "the driver symbol inventory owns only pancake_driver_*; Host keeps its own archive and inventory",
    },
    .{
        .where = .{ .file = "bindings/python/pancake/_ffi_host.py" },
        .kind = .require,
        .needles = &.{"_lib_path(\"pancake_host\")"},
        .check = "transport-provider-architecture",
        .why = "the Python Host table must load libpancake_host",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/internal/ffi/host.ts" },
        .kind = .require,
        .needles = &.{"libPath(\"pancake_host\")"},
        .check = "transport-provider-architecture",
        .why = "the TypeScript Host table must load libpancake_host",
    },
    .{
        .where = .{ .file = "bindings/racket/private/ffi-host-gen.rkt" },
        .kind = .require,
        .needles = &.{"open-pancake-archive \"pancake_host\""},
        .check = "transport-provider-architecture",
        .why = "the Racket Host table must load libpancake_host",
    },
    .{
        .where = .{ .file = "bindings/rust/build.rs" },
        .kind = .require,
        .needles = &.{"rustc-link-lib=static=pancake_host"},
        .check = "transport-provider-architecture",
        .why = "the Rust binding must link the symbol-disjoint Host archive",
    },
    .{
        .where = .{ .tree = .{
            .dir = "bindings",
            .suffixes = &.{ ".py", ".rs", ".rkt", ".ts" },
            .skip_dirs = &.{ "target/", "node_modules/" },
        } },
        .kind = .forbid,
        .needles = &.{
            "_LoopIrohResident", "_loop_iroh_residents", "_provider_owners",
            "provider_owners",   "providerOwners",       "_netlayer: IrohNetlayer",
        },
        .check = "transport-provider-architecture",
        .why = "the driver-held provider lease is the native callback-context owner; bindings retain only immutable provider state",
    },
    .{
        .where = .{ .file = "bindings/python/pancake/_loop.py" },
        .kind = .forbid,
        .needles = &.{ "_ffi_tcp", "pancake_tcp_", "ensure_tcp_provider" },
        .check = "transport-provider-architecture",
        .why = "the generic Python loop registers packages and drives events; transport modules own concrete provider composition",
    },
    .{
        .where = .{ .file = "bindings/rust/src/driver_loop.rs" },
        .kind = .forbid,
        .needles = &.{ "ensure_tcp_provider", "crate::dial::DialPlan", "crate::iroh::ensure_loop_provider" },
        .check = "transport-provider-architecture",
        .why = "the generic Rust loop registers packages and drives events; dial and transport modules own concrete provider composition",
    },
    .{
        .where = .{ .file = "bindings/racket/private/loop.rkt" },
        .kind = .forbid,
        .needles = &.{ "\"ffi-tcp.rkt\"", "driver-loop-add-tcp!" },
        .check = "transport-provider-architecture",
        .why = "the generic Racket loop registers packages and drives events; transport modules own concrete provider composition",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/driver_loop.ts" },
        .kind = .forbid,
        .needles = &.{ "internal/ffi/tcp", "pancake_tcp_", "ensureTcpProvider" },
        .check = "transport-provider-architecture",
        .why = "the generic TypeScript loop registers packages and drives events; transport modules own concrete provider composition",
    },
    .{
        .where = .{ .file = "src/c_abi/net_transport/tcp/mod.zig" },
        .kind = .require,
        .needles = &.{".tcp =>"},
        .check = "transport-provider-architecture",
        .why = "the TCP archive owns the plain TCP profile in its complete provider package",
    },
    .{
        .where = .{ .file = "src/c_abi/net_transport/tcp/mod.zig" },
        .kind = .require,
        .needles = &.{".keyed_tcp =>"},
        .check = "transport-provider-architecture",
        .why = "the TCP archive owns the keyed TCP profile in its complete provider package",
    },
    .{
        .where = .{ .file = "src/c_abi/net_transport/tcp/mod.zig" },
        .kind = .require,
        .needles = &.{".noise_tcp =>"},
        .check = "transport-provider-architecture",
        .why = "the TCP archive owns the Noise-sealed TCP profile while reusable Noise machinery stays below packaging",
    },
};

const sturdyref_authority: []const Ban = blk: {
    const dirs = [_][]const u8{ "src", "include", "bindings", "test", "tools", "interop", "examples", "apps", "cli" };
    var rows: [dirs.len]Ban = undefined;
    for (rows[0..], dirs) |*row, dir| {
        row.* = .{
            .where = .{ .tree = .{
                .dir = dir,
                .suffixes = &.{ ".zig", ".h", ".rs", ".py", ".rkt", ".ts" },
                .skip_dirs = &.{ "zig-pkg/", "target/", "node_modules/", ".zig-cache/", "zig-out/" },
                .exclude = &.{ "tools/check/source_check/bans.zig", "tools/check/source_check/c_abi.zig" },
            } },
            .kind = .forbid,
            .needles = &.{ "pancake_locator_swissnum", "is_sturdyref" },
            .check = "sturdyref-authority",
            .why = "peer locators and authority-bearing sturdyrefs are distinct values and handles; do not restore a discriminator-shaped union",
        };
    }
    const frozen = rows;
    break :blk &frozen;
};

/// Host actions carry CapTP sessions, not transport connections. Keep the
/// generated mirrors and their hand-written consumers on that one contract
/// without banning legitimate connection vocabulary in transport adapters.
const host_action_session_vocabulary: []const Ban = &.{
    .{
        .where = .{ .files = &.{
            "bindings/python/pancake/_action.py",
            "bindings/python/pancake/_ffi_host.py",
            "bindings/racket/private/host-action-gen.rkt",
            "bindings/racket/private/loop.rkt",
            "bindings/rust/src/session.rs",
            "bindings/rust/src/session_shared.rs",
            "tools/gen/binding/host_action.zig",
        } },
        .kind = .forbid,
        .needles = &.{
            "a.conn_ptr",
            "aliases={\"session\": \"conn\"}",
            "PancakeHostAction-conn",
            "session-vow-conn",
            "fn raw_conn(&self) -> *mut ffi::PancakeHostSession",
            "self.shared.raw_conn()",
        },
        .check = "host-action-session-vocabulary",
        .why = "Host actions and PancakeHostSession mirrors use session vocabulary directly; prerelease keeps no connection-named aliases",
    },
};

/// The native bindings hand complete locators to the generic driver and its
/// registered transport packages. The byte-fed C embedder may still use
/// PancakeDialPlan, but projecting that plan into a binding restores concrete
/// transport dispatch to generic runtime code. The rest of this table holds
/// current lifecycle and style invariants; exact-spelling bans of retired
/// names are pruned once the tree and its generated mirrors agree.
const binding_public_api_retirements: []const Ban = &.{
    .{
        .where = .{ .tree = .{
            .dir = "bindings",
            .suffixes = &.{ ".rs", ".py", ".rkt", ".ts" },
            .skip_dirs = &.{ "target/", "node_modules/" },
        } },
        .kind = .forbid,
        .needles = &.{
            "PancakeDialPlan",
            "PANCAKE_DIAL_PLAN",
            "DIAL_SHAPE_",
            "DIAL_REACH_",
            "DIAL_POSTURE_",
        },
        .check = "binding-public-api-retirements",
        .why = "native bindings pass typed locators through the generic driver; only direct byte-fed C embedders project PancakeDialPlan",
    },
    .{
        .where = .{ .files = &.{
            "tools/gen/binding/constants.zig",
            "tools/gen/binding/ffi_layouts.zig",
            "tools/gen/binding/rust_ffi.zig",
            "tools/gen/binding/ts_abi.zig",
        } },
        .kind = .forbid,
        .needles = &.{
            "PancakeDialPlan",
            "PANCAKE_DIAL_PLAN",
            "DIAL_SHAPE_",
            "DIAL_REACH_",
            "DIAL_POSTURE_",
        },
        .check = "binding-public-api-retirements",
        .why = "binding generators must not restore the byte-fed DialPlan projection omitted by every native binding",
    },
    .{
        .where = .{ .tree = .{
            .dir = "site/examples",
            .suffixes = &.{".ts"},
        } },
        .kind = .forbid,
        .needles = &.{"import * as"},
        .check = "binding-public-api-retirements",
        .why = "website TypeScript examples import the names they use so package consumption stays explicit and consistent",
    },
    .{
        .where = .{ .tree = .{
            .dir = "site/examples",
            .suffixes = &.{".zig"},
        } },
        .kind = .forbid,
        .needles = &.{"defer server.close();"},
        .check = "binding-public-api-retirements",
        .why = "Server.close is admission-only; deferred ownership cleanup in a public example must call Server.deinit",
    },
    .{
        .where = .{ .tree = .{
            .dir = "bindings/python",
            .suffixes = &.{".py"},
        } },
        .kind = .forbid,
        .needles = &.{"owns_host"},
        .check = "binding-public-api-retirements",
        .why = "Session closes one connection; Runtime owns Host and provider teardown",
    },
    .{
        .where = .{ .tree = .{
            .dir = "bindings/ts",
            .suffixes = &.{".ts"},
            .skip_dirs = &.{ "node_modules/", "dist/" },
        } },
        .kind = .forbid,
        .needles = &.{"ownsHost"},
        .check = "binding-public-api-retirements",
        .why = "Session closes one connection; Runtime owns Host and provider teardown",
    },
    .{
        .where = .{ .tree = .{
            .dir = "bindings/rust/src",
            .suffixes = &.{".rs"},
        } },
        .kind = .forbid,
        .needles = &.{"owns_host"},
        .check = "binding-public-api-retirements",
        .why = "Session closes one connection; Runtime owns Host and provider teardown",
    },
    .{
        .where = .{ .tree = .{
            .dir = "bindings/racket",
            .suffixes = &.{".rkt"},
        } },
        .kind = .forbid,
        .needles = &.{"owns-host"},
        .check = "binding-public-api-retirements",
        .why = "Session closes one connection; Runtime owns Host and provider teardown",
    },
    .{
        .where = .{ .tree = .{
            .dir = "bindings/racket",
            .suffixes = &.{".rkt"},
        } },
        .kind = .forbid,
        .needles = &.{"(host-release!"},
        .check = "binding-public-api-retirements",
        .why = "Racket host-close! is the one Host policy barrier; the retired host-release! verb must not return",
    },
    .{
        .where = .{ .file = "bindings/python/pancake/_host.py" },
        .kind = .forbid,
        .needles = &.{
            "async def release_async",
            "def release(self)",
        },
        .check = "binding-public-api-retirements",
        .why = "Python Host.close is the sole shutdown barrier; the retired release/release_async verbs must not return",
    },
    .{
        .where = .{ .tree = .{
            .dir = "bindings/python",
            .suffixes = &.{".py"},
        } },
        .kind = .forbid,
        .needles = &.{"_loop_mode"},
        .check = "binding-public-api-retirements",
        .why = "loop ownership is Host.driver_loop; a parallel _loop_mode flag is a second representation of the same fact",
    },
};

/// An unowned deferral marker in first-party source is a decision hidden in a
/// comment. The boundary it defers belongs where the release bar can see it:
/// `docs/boundaries.md`, `docs/roadmap.md`, or an ADR — or the fix lands now,
/// which prerelease already names as the default verdict. Third-party and
/// generated trees (extracted Zig packages, cargo `target/`) are skipped, and
/// this file is excluded because the table must name the markers it bans.
const deferral_markers: []const Ban = blk: {
    const needles: []const []const u8 = &.{ "TODO", "FIXME", "XXX:", "HACK:" };
    const why = "an unowned deferral marker hides a decision; fix it now (prerelease) or record the boundary in docs/boundaries.md, docs/roadmap.md, or an ADR";
    const dirs = [_][]const u8{
        "src",        "cli",      "test", "tools",
        "examples",   "bench",    "apps", "interop",
        "transports", "bindings", "ui",   "ci",
    };
    var rows: [dirs.len + 1]Ban = undefined;
    for (rows[0..dirs.len], dirs) |*row, dir| {
        row.* = .{
            .where = .{
                .tree = .{
                    .dir = dir,
                    .suffixes = &.{
                        ".zig", ".rs", ".py", ".rkt", ".ts",   ".js",
                        ".c",   ".h",  ".sh", ".css", ".html",
                    },
                    // Fragments match the walked tree's RELATIVE paths, so a
                    // repo-rooted spelling here is dead config. Generated
                    // output dirs only; first-party source is always held.
                    .skip_dirs = &.{ "zig-pkg/", "target/", "node_modules/", ".vite/", ".deno/", "dist/", ".zig-cache", "zig-out" },
                    .exclude = &.{"tools/check/source_check/bans.zig"},
                },
            },
            .kind = .forbid,
            .needles = needles,
            .check = "deferral-markers",
            .why = why,
        };
    }
    // The build scripts live at their roots, outside every tree above.
    rows[dirs.len] = .{
        .where = .{ .files = &.{ "build.zig", "site/build.zig" } },
        .kind = .forbid,
        .needles = needles,
        .check = "deferral-markers",
        .why = why,
    };
    const frozen = rows;
    break :blk &frozen;
};

/// White-box helpers stay behind the conditional `driver.core.testing`
/// namespace instead of becoming methods or direct exports on production
/// types and barrels.
const test_only_surface: []const Ban = &.{
    .{
        .where = .{ .file = "src/driver/core/host.zig" },
        .kind = .forbid,
        .needles = &.{ "pub fn testing", "pub const testing" },
        .check = "test-only-surface",
        .why = "Host white-box helpers belong under the test-build-only driver.core.testing namespace",
    },
    .{
        .where = .{ .file = "src/driver/core/mod.zig" },
        .kind = .forbid,
        .needles = &.{"pub const emitStatelessAfter"},
        .check = "test-only-surface",
        .why = "direct stateless-GC emission is white-box support, not a production driver.core export",
    },
    .{
        .where = .{ .files = &.{
            "src/driver/core/host_action.zig",
            "src/driver/core/host_pump.zig",
        } },
        .kind = .forbid,
        .needles = &.{ "pub fn testingMarkDirty", "pub fn testingQueueUniqueSessionAction" },
        .check = "test-only-surface",
        .why = "white-box pump helpers live under a compile-time-empty testing namespace, never as ordinary public functions",
    },
    .{
        .where = .{ .file = "src/ocapn/engine/mod.zig" },
        .kind = .forbid,
        .needles = &.{ "initRawOpenFixture", "fifo_steady_bytes" },
        .check = "test-only-surface",
        .why = "engine fixtures and budget probes belong under the test-build-only engine.testing namespace",
    },
    .{
        .where = .{ .file = "src/driver/core/host.zig" },
        .kind = .forbid,
        .needles = &.{ "pub const markSessionTerminating", "pub const advanceCloseLifecycle" },
        .check = "host-internal-surface",
        .why = "close transaction steps belong to the private host_close sibling, not the public Host method set",
    },
    .{
        .where = .{ .files = &.{
            "src/c_abi/host/host.zig",
            "src/driver/host_runtime.zig",
        } },
        .kind = .forbid,
        .needles = &.{
            "inst.core.closeDeadline()",
            "inst.core.nextSessionCloseDeadline()",
            "self.core.closeDeadline()",
            "self.core.nextSessionCloseDeadline()",
        },
        .check = "c-abi-policy-surface",
        .why = "adapters project Host.closeWaitMs; Host/session deadline selection stays in the sans-I/O core",
    },
};

/// A binding async surface reports admission failure through the same result
/// its caller already observes; synchronous task admission is not discarded.
const binding_failure_surface: []const Ban = &.{
    .{
        .where = .{ .file = "bindings/rust/src/session_shared.rs" },
        .kind = .forbid,
        .needles = &.{ "let _ = try_spawn_local", "tell is lost", "tolerated loss" },
        .check = "binding-failure-surface",
        .why = "a Result-returning binding verb must report synchronous task-admission failure instead of accepting and losing work",
    },
    .{
        .where = .{ .file = "bindings/rust/src/dial.rs" },
        .kind = .forbid,
        .needles = &.{"let _ = try_spawn_local"},
        .check = "binding-failure-surface",
        .why = "the byte-fed dial owner task is admitted before the core commits the dial outcome",
    },
    .{
        .where = .{ .file = "bindings/rust/src/session.rs" },
        .kind = .require,
        .needles = &.{"pub fn serve(&self) -> impl std::future::Future<Output = Result<()>>"},
        .check = "binding-failure-surface",
        .why = "Rust serve admission belongs on the returned future, never a panic",
    },
    .{
        .where = .{ .file = "bindings/rust/src/pump.rs" },
        .kind = .forbid,
        .needles = &.{"let _ = result;"},
        .check = "binding-failure-surface",
        .why = "the Rust serve future reports its primary feed or transport failure after teardown",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/pump.ts" },
        .kind = .require,
        .needles = &.{
            "if (!failed && !wasClosing)",
            "if (failed) throw failure;",
        },
        .check = "binding-failure-surface",
        .why = "a TypeScript clean EOF reports a refused transport-loss notification while an earlier serve failure remains primary",
    },
    .{
        .where = .{ .file = "bindings/python/pancake/_pump.py" },
        .kind = .require,
        .needles = &.{
            "if failure is None and not was_closing:",
            "raise failure",
        },
        .check = "binding-failure-surface",
        .why = "a Python clean EOF reports a refused transport-loss notification while an earlier serve failure remains primary",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/promise.ts" },
        .kind = .require,
        .needles = &.{"attend(): void;"},
        .check = "binding-failure-surface",
        .why = "TypeScript vow waits admit inbound synchronously so an async caller observes refusal without retaining its result behind the session-lifetime promise",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/promise.ts" },
        .kind = .forbid,
        .needles = &.{ "Promise.race([", "h.serve()", "void h.kickActions()" },
        .check = "binding-failure-surface",
        .why = "vow waits observe action-drain failure without retaining their result behind the session lifetime",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/dial.ts" },
        .kind = .forbid,
        .needles = &.{"session.serve().catch(() => {});"},
        .check = "binding-failure-surface",
        .why = "an internally owned dial session closes when its serve task fails",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/driver_loop.ts" },
        .kind = .require,
        .needles = &.{
            "#terminalFailure: PancakeError | null",
            "#failBackground(error: unknown): void",
            "row.failed(error);",
            "this.#wrapper.failPendingVows(failure);",
        },
        .check = "binding-failure-surface",
        .why = "every TypeScript background drive failure is one terminal outcome completed into all binding waiters",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/trampoline.ts" },
        .kind = .require,
        .needles = &.{"pancake_host_turn_session"},
        .check = "binding-failure-surface",
        .why = "TypeScript obtains callback session authority from the core turn",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/driver_loop.ts" },
        .kind = .forbid,
        .needles = &.{
            "void runParker().finally",
            "this.stepNow();\n\t\t\tthis.#armDialTicker();",
            "this.stepNow();\n\t\t});",
            "#stepCarrier",
        },
        .check = "binding-failure-surface",
        .why = "background failures reach the loop's terminal authority and callback session identity comes from the core turn, never a guessed carrier",
    },
    .{
        .where = .{ .file = "src/driver/core/host_pump.zig" },
        .kind = .require,
        .needles = &.{"pub fn scheduleFeedResume(self:"},
        .check = "binding-failure-surface",
        .why = "the core owns the wake that resumes complete stream frames retained behind local pressure",
    },
    .{
        .where = .{ .file = "src/driver/core/host.zig" },
        .kind = .require,
        .needles = &.{"try resumeFeedTail(self.host, self)"},
        .check = "binding-failure-surface",
        .why = "outbound drain resumes core-owned stream input without a binding-only empty-feed invariant",
    },
    .{
        .where = .{ .file = "src/driver/core/gc.zig" },
        .kind = .forbid,
        .needles = &.{
            "}) catch {};",
            "it.next() catch null",
        },
        .check = "binding-failure-surface",
        .why = "stateless GC emission and fallback decoding propagate failure instead of stranding capability counts until teardown",
    },
    .{
        .where = .{ .file = "src/c_abi/ocapn/uri.zig" },
        .kind = .forbid,
        .needles = &.{
            "error.OutOfMemory => PANCAKE_ERR_INTERNAL",
            "catch return PANCAKE_ERR_INTERNAL",
        },
        .check = "binding-failure-surface",
        .why = "an opaque C internal error must also publish an operation-specific last-error diagnostic",
    },
    .{
        .where = .{ .tree = .{ .dir = "src/c_abi/net_transport", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{
            "catch return PANCAKE_ERR_INTERNAL",
            "orelse return PANCAKE_ERR_INTERNAL",
        },
        .check = "binding-failure-surface",
        .why = "a transport C crossing must retain its operation and concrete cause before returning the generic internal code",
    },
    .{
        .where = .{ .files = &.{
            "src/driver/core/host.zig",
            "src/driver/core/host_pump.zig",
        } },
        .kind = .forbid,
        .needles = &.{
            "catch {};",
            "PeerKey.fromSlice(ss.session_pubkey) catch return",
            "event.view() catch return false",
            "event.wireView() catch return false",
        },
        .check = "binding-failure-surface",
        .why = "core protocol and cleanup failures must propagate or enter the session's retained terminal diagnosis",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/host.ts" },
        .kind = .require,
        .needles = &.{"failPendingVows(error: PancakeError): void"},
        .check = "binding-failure-surface",
        .why = "loop failure completes Host vows before wrapper teardown clears their table",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/host.ts" },
        .kind = .require,
        .needles = &.{"if (firstFailure !== null) throw firstFailure.error;"},
        .check = "binding-failure-surface",
        .why = "the TypeScript byte-fed action drain reports its first failed effect after finishing the already-popped batch",
    },
    .{
        .where = .{ .file = "bindings/python/pancake/_loop.py" },
        .kind = .require,
        .needles = &.{
            "self._terminal_failure:",
            "def _fail_background(self, error: BaseException) -> None:",
            "self._wrapper._driver_failed(failure)",
            "self._aio.call_soon(self._step_background)",
        },
        .check = "binding-failure-surface",
        .why = "Python readiness callbacks and scheduled steps complete all waiters through one terminal loop failure",
    },
    .{
        .where = .{ .file = "bindings/python/pancake/_host.py" },
        .kind = .require,
        .needles = &.{"raise first_failure"},
        .check = "binding-failure-surface",
        .why = "the Python byte-fed action drain reports its first failed effect after finishing the already-popped batch",
    },
    .{
        .where = .{ .file = "bindings/python/pancake/_loop.py" },
        .kind = .forbid,
        .needles = &.{
            "self._aio.call_soon(self.step_now)",
        },
        .check = "binding-failure-surface",
        .why = "Python loop background work must retain or classify its failure instead of relying on the event-loop exception handler",
    },
    .{
        .where = .{ .file = "bindings/racket/private/loop.rkt" },
        .kind = .require,
        .needles = &.{
            "(define (loop-background-failed! lp error)",
            "(loop-owner-failed! c error)",
            "[exn:fail:loop-drive?",
        },
        .check = "binding-failure-surface",
        .why = "a Racket park-thread drain failure completes loop waiters and session shells before release",
    },
    .{
        .where = .{ .file = "bindings/rust/src/host.rs" },
        .kind = .forbid,
        .needles = &.{
            "pub(crate) fn close_wait(&self) -> Option<Duration>",
            "pub(crate) fn schedule_kick(self: &Rc<HostShared>) {",
            "let _ = try_spawn_local",
            "let _ = crate::action::run(self, action).await",
        },
        .check = "binding-failure-surface",
        .why = "host scheduling and close-deadline failures must remain observable",
    },
    .{
        .where = .{ .file = "bindings/rust/src/host.rs" },
        .kind = .require,
        .needles = &.{"pub(crate) async fn kick_actions(self: &Rc<HostShared>) -> Result<()>"},
        .check = "binding-failure-surface",
        .why = "the Rust byte-fed action drain reports its first failed effect after finishing the already-popped batch",
    },
    .{
        .where = .{ .file = "bindings/rust/src/driver_loop.rs" },
        .kind = .forbid,
        .needles = &.{
            "fn step_wait(&self) -> Option<std::time::Duration>",
            "Ok(None) | Err(_) => break",
            "let _ = try_spawn_local",
        },
        .check = "binding-failure-surface",
        .why = "driver scheduling, stepping, and deadline failures are terminal outcomes, never idle progress",
    },
    .{
        .where = .{ .file = "bindings/rust/src/driver_loop.rs" },
        .kind = .require,
        .needles = &.{"background failure releases the driver loop"},
        .check = "binding-layer-vocabulary",
        .why = "the failure test names the concrete driver-loop owner",
    },
    .{
        .where = .{ .file = "bindings/rust/src/host.rs" },
        .kind = .require,
        .needles = &.{"project C ABI FAIL events"},
        .check = "binding-layer-vocabulary",
        .why = "failure projection names the concrete C ABI seam",
    },
    .{
        .where = .{ .file = "bindings/rust/src/session_shared.rs" },
        .kind = .require,
        .needles = &.{"Resume loop-owned inbound"},
        .check = "binding-layer-vocabulary",
        .why = "session serving names the loop owner directly",
    },
};

/// Sturdyref swissnum path spelling is a CapTP profile fact. A generic C or
/// binding helper must receive that profile explicitly instead of falling back
/// to the model's 1.0 convenience verbs.
const sturdyref_profile_authority: []const Ban = &.{
    .{
        .where = .{ .file = "src/c_abi/ocapn/uri.zig" },
        .kind = .forbid,
        .needles = &.{
            "model.uri.parseSturdyref(allocator",
            "model.uri.writeSturdyref(alloc",
        },
        .check = "sturdyref-profile-authority",
        .why = "the C URI surface must select swissnum spelling through the caller's CapTP profile",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/locator.ts" },
        .kind = .require,
        .needles = &.{"parseSturdyRef(uri: string, captpVersion: CaptpVersion)"},
        .check = "sturdyref-profile-authority",
        .why = "TypeScript sturdyref parsing requires the profile that owns its swissnum spelling",
    },
    .{
        .where = .{ .file = "bindings/rust/src/uri.rs" },
        .kind = .require,
        .needles = &.{"pub fn parse_sturdyref(uri: &str, captp_version: CaptpVersion)"},
        .check = "sturdyref-profile-authority",
        .why = "Rust sturdyref parsing requires the profile that owns its swissnum spelling",
    },
    .{
        .where = .{ .file = "bindings/python/pancake/_locator.py" },
        .kind = .require,
        .needles = &.{"def parse_sturdyref(uri: str, captp_version: str)"},
        .check = "sturdyref-profile-authority",
        .why = "Python sturdyref parsing requires the profile that owns its swissnum spelling",
    },
    .{
        .where = .{ .file = "bindings/racket/private/locator.rkt" },
        .kind = .require,
        .needles = &.{"(define (parse-sturdyref uri #:captp-version captp-version)"},
        .check = "sturdyref-profile-authority",
        .why = "Racket sturdyref parsing requires the profile that owns its swissnum spelling",
    },
};

pub const all: []const Ban =
    captp_io_spine_table ++
    transport_vocabulary ++
    prerelease_prose ++
    human_doc_voice ++
    diagram_wire_vocabulary ++
    clock_seam ++
    actors_layer_purity ++
    readme_c_verb_names ++
    unobserved_outcome_cap_rows ++
    goblins_runtime_portability ++
    signature_arm_reads ++
    transport_provider_architecture ++
    sturdyref_authority ++
    host_action_session_vocabulary ++
    binding_public_api_retirements ++
    deferral_markers ++
    test_only_surface ++
    binding_failure_surface ++
    sturdyref_profile_authority;

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
