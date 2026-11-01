//! Every doc has a lifetime kind and an audience, and the two decide what it
//! may say and link.
//!
//! Lifetime:
//!
//! - Static docs state facts that stay true until the code changes. They use no
//!   status words and link only static or living docs.
//! - Living docs stay and say where the project stands: what ships, its limits
//!   and evidence, outside-peer standing, dated runs, decisions, and the work
//!   left. They change as the work moves, and anything may link them.
//! - Temporary docs are committed and deleted when their job is done. A living
//!   doc links each one, so it has an owner that will delete it, and nothing
//!   static links one, so deleting it edits nothing else.
//! - Temporary local docs live under `local_home`, which git ignores. A
//!   committed doc never links one, because no other checkout has it.
//!
//! Audience:
//!
//! - Human docs are read by people using glowcap or running Rooms. They take
//!   the reader voice: no insider words, no semicolons, no em dashes.
//! - Agent docs instruct an agent working in the repository. They are terse
//!   directives and may use the working words.
//! - Shared docs are read by people and agents building glowcap. They keep the
//!   human punctuation and may use the working words.
//!
//! Where a doc's place decides both, the place is the one home of the fact:
//! agent homes, site pages, the root docs, decision records, research notes,
//! results, changelogs, and the temporary homes. A README is the index of its
//! directory, like an OKF `index.md`, and may declare a header. Every other doc
//! opens with a header in the Open Knowledge Format (OKF v0.2), limited to these
//! keys:
//!
//!     ---
//!     type: static
//!     description: How Loam stores records and recovers them after a crash.
//!     audience: human
//!     sources:
//!       - resource: /src/loam/access/
//!       - resource: https://github.com/ocapn/ocapn
//!     ---
//!
//! - `type` (required): the lifetime, `static`, `living` or `temporary`.
//! - `description` (required): one sentence an index or an agent can show
//!   without opening the doc.
//! - `audience` (optional): `human` or `shared`, and `shared` when absent.
//! - `sources` (required): OKF provenance, the code and outside documents the
//!   doc explains. A `/` path is from the repository root and a directory ends
//!   in `/`. `sources: []` says the doc explains no code. A README without a
//!   header explains the files beside it.
//!
//! Values are plain YAML scalars, so they carry no `: ` and no ` #`.
//!
//! A doc whose place decides it carries its harness's or renderer's
//! frontmatter, or none. Its sources are what it already points at: the
//! repository paths it links or writes in code spans (`names`). Writing them
//! again in a header would be a second copy.

const std = @import("std");

pub const Kind = enum { static, living, temporary };
pub const Audience = enum { human, agent, shared };

/// Human docs by place: every `site/content` page, the front doors at the
/// root, and the README that opens each tree, app and published package
/// (`frontPage`). A new app or package is human from its first commit.
pub const human_roots = [_][]const u8{ "README.md", "SECURITY.md", "PROVENANCE.md", "CHANGELOG.md" };

/// Trees whose direct subdirectories are apps or packages, each opened by its
/// README.
const package_parents = [_][]const u8{ "apps/", "bindings/", "bindings/ts/" };

/// Subdirectories of those trees that hold no app or package.
const internal_dirs = [_][]const u8{"bindings/proofs/"};

/// The README directly under `examples/`, an app, or a published package.
fn frontPage(path: []const u8) bool {
    if (std.mem.eql(u8, path, "examples/README.md")) return true;
    if (!std.mem.endsWith(u8, path, "/README.md")) return false;
    const dir = path[0 .. path.len - "README.md".len];
    for (internal_dirs) |internal| if (std.mem.eql(u8, dir, internal)) return false;
    for (package_parents) |parent| {
        if (std.mem.eql(u8, dir, parent)) return true;
        if (!std.mem.startsWith(u8, dir, parent)) continue;
        const rest = dir[parent.len..];
        if (std.mem.indexOfScalar(u8, rest, '/') == rest.len - 1 and rest[0] != '_') return true;
    }
    return false;
}

/// Agent docs: these directories and root files.
const agent_homes = [_][]const u8{ ".agents/", ".cursor/", ".claude/", ".codex/", "AGENTS.md", "CLAUDE.md" };

/// Directories whose docs are temporary, with the pages in each that stay.
pub const Home = struct { dir: []const u8, keep: []const []const u8 };
pub const temporary_homes = [_]Home{
    .{ .dir = "docs/planning/", .keep = &.{ "README.md", "plan-to-plan.md" } },
};

/// Where docs live: these trees, plus the docs at the root.
pub const doc_trees = [_][]const u8{ "docs", "apps", "bindings", "bench", "examples", "interop", "conformance", "site/content", ".agents", "test", "tools" };
pub const root_docs = [_][]const u8{ "README.md", "CONTRIBUTING.md", "SECURITY.md", "PROVENANCE.md", "AGENTS.md", "CHANGELOG.md" };

/// A doc we write. Vendored upstream checkouts are someone else's.
pub fn isDoc(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "/upstream/") != null) return false;
    return std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".smd");
}

/// The ignored directory that holds temporary local docs.
pub const local_home = ".local/";

/// What decides a doc's kind and audience.
pub const Place = enum {
    /// The place alone. Agent docs and site pages carry their harness's or
    /// renderer's own frontmatter, and the rest carry none.
    decides,
    /// A README: the place, unless it declares a header.
    index,
    /// Its OKF header, which it must carry.
    declares,
};

pub fn placeOf(path: []const u8) Place {
    for (agent_homes) |home| if (std.mem.startsWith(u8, path, home)) return .decides;
    if (std.mem.startsWith(u8, path, "site/content/")) return .decides;
    for (root_docs) |doc| if (std.mem.eql(u8, path, doc)) return .decides;
    for (temporary_homes) |home| if (std.mem.startsWith(u8, path, home.dir)) return .decides;
    if (livingByPlace(path)) return .decides;
    if (std.mem.eql(u8, std.fs.path.basename(path), "README.md")) return .index;
    return .declares;
}

/// Decision records, research notes, dated results (`*results.md`) and
/// changelogs are living wherever they sit.
fn livingByPlace(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "docs/decisions/")) return true;
    if (std.mem.indexOf(u8, path, "/research/") != null) return true;
    const base = std.fs.path.basename(path);
    return std.mem.endsWith(u8, base, "results.md") or std.mem.eql(u8, base, "CHANGELOG.md");
}

fn kindByPlace(path: []const u8) Kind {
    for (temporary_homes) |home| {
        if (!std.mem.startsWith(u8, path, home.dir)) continue;
        const name = path[home.dir.len..];
        for (home.keep) |keep| if (std.mem.eql(u8, name, keep)) return .static;
        return .temporary;
    }
    return if (livingByPlace(path)) .living else .static;
}

fn audienceByPlace(path: []const u8) Audience {
    for (agent_homes) |home| if (std.mem.startsWith(u8, path, home)) return .agent;
    if (std.mem.startsWith(u8, path, "site/content/") and std.mem.endsWith(u8, path, ".smd")) return .human;
    for (human_roots) |page| if (std.mem.eql(u8, path, page)) return .human;
    if (frontPage(path)) return .human;
    return .shared;
}

pub const Doc = struct { kind: Kind, audience: Audience };

/// A doc's kind and audience. A malformed header falls back to the place,
/// and `problem` reports it.
pub fn classify(path: []const u8, text: []const u8) Doc {
    var doc = Doc{ .kind = kindByPlace(path), .audience = audienceByPlace(path) };
    if (placeOf(path) == .decides) return doc;
    const front = Frontmatter.of(text) orelse return doc;
    if (front.field("type")) |value| if (std.meta.stringToEnum(Kind, value)) |kind| {
        doc.kind = kind;
    };
    if (front.field("audience")) |value| {
        if (std.mem.eql(u8, value, "human")) doc.audience = .human;
        if (std.mem.eql(u8, value, "shared")) doc.audience = .shared;
    }
    return doc;
}

/// The first way a doc's header breaks the schema, if any. Source paths are
/// held separately because they need the tree.
pub fn problem(path: []const u8, text: []const u8) ?[]const u8 {
    const place = placeOf(path);
    if (place == .decides) return null;
    const front = Frontmatter.of(text) orelse
        return if (place == .declares) "opens with no OKF header; give it `type`, `description` and `sources` (kinds.zig)" else null;
    if (front.stray()) |_| return "carries a header line outside the schema; the keys are `type`, `description`, `audience` and `sources` (kinds.zig)";
    const kind = front.field("type") orelse return "header has no `type`";
    if (std.meta.stringToEnum(Kind, kind) == null) return "header `type` is not `static`, `living` or `temporary`";
    const description = front.field("description") orelse return "header has no `description`";
    if (description.len == 0 or description[description.len - 1] != '.') return "header `description` is not one sentence ending in a period";
    if (description.len > 200) return "header `description` runs past 200 characters";
    if (front.field("audience")) |audience| {
        if (!std.mem.eql(u8, audience, "human") and !std.mem.eql(u8, audience, "shared")) return "header `audience` is not `human` or `shared`";
    }
    if (front.sources() == null) return "header has no `sources`; list the code it explains, or `sources: []`";
    return null;
}

/// The block between a doc's opening `---` fences.
pub const Frontmatter = struct {
    body: []const u8,

    pub fn of(text: []const u8) ?Frontmatter {
        if (!std.mem.startsWith(u8, text, "---\n")) return null;
        const end = std.mem.indexOf(u8, text[3..], "\n---\n") orelse return null;
        return .{ .body = text[4 .. 3 + end + 1] };
    }

    /// A top-level scalar's value.
    pub fn field(self: Frontmatter, key: []const u8) ?[]const u8 {
        var lines = std.mem.splitScalar(u8, self.body, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, key) or !std.mem.startsWith(u8, line[key.len..], ": ")) continue;
            return line[key.len + 2 ..];
        }
        return null;
    }

    /// The `sources` resources, or null when the doc declares none.
    pub fn sources(self: Frontmatter) ?Sources {
        var lines = std.mem.splitScalar(u8, self.body, '\n');
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "sources: []")) return .{ .lines = std.mem.splitScalar(u8, "", '\n') };
            if (std.mem.eql(u8, line, "sources:")) return .{ .lines = std.mem.splitScalar(u8, lines.rest(), '\n') };
        }
        return null;
    }

    /// The first line outside the schema: an unknown key, a value YAML would
    /// read differently, or a list item that is not a `resource`.
    pub fn stray(self: Frontmatter) ?[]const u8 {
        const keys = [_][]const u8{ "type: ", "description: ", "audience: " };
        var in_list = false;
        var lines = std.mem.splitScalar(u8, self.body, '\n');
        next: while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.eql(u8, line, "sources: []") or std.mem.eql(u8, line, "sources:")) {
                in_list = line.len == "sources:".len;
                continue;
            }
            if (in_list and std.mem.startsWith(u8, line, "  - resource: ")) {
                if (plain(line["  - resource: ".len..])) continue;
                return line;
            }
            in_list = false;
            for (keys) |key| if (std.mem.startsWith(u8, line, key)) {
                if (plain(line[key.len..])) continue :next;
                return line;
            };
            return line;
        }
        return null;
    }

    /// A value YAML reads as the same plain string.
    fn plain(value: []const u8) bool {
        if (value.len == 0) return false;
        if (std.mem.indexOfScalar(u8, "'\"[{&*!|>%@`-?", value[0]) != null) return false;
        return std.mem.indexOf(u8, value, ": ") == null and std.mem.indexOf(u8, value, " #") == null;
    }
};

pub const Sources = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    pub fn next(self: *Sources) ?[]const u8 {
        const line = self.lines.next() orelse return null;
        if (!std.mem.startsWith(u8, line, "  - resource: ")) return null;
        return line["  - resource: ".len..];
    }
};

/// The repository path a `sources` resource names, or null for an outside URL.
pub fn sourcePath(resource: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, resource, "/")) return null;
    return resource[1..];
}

/// Whether a doc without an OKF header points at `path`: a link to it or to a
/// directory holding it, resolved from the doc, or a code span naming it from
/// the repository root. Links into this repository on GitHub count too.
pub fn names(gpa: std.mem.Allocator, doc: []const u8, text: []const u8, path: []const u8) !bool {
    const dir = std.fs.path.dirname(doc) orelse ".";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, "](")) |open| {
        at = open + 2;
        const close = std.mem.indexOfAnyPos(u8, text, at, ") \n") orelse break;
        var target = text[at..close];
        if (std.mem.indexOfScalar(u8, target, '#')) |hash| target = target[0..hash];
        if (target.len == 0) continue;
        if (repoUrl(target)) |rest| {
            if (pointsAt(rest, path)) return true;
            continue;
        }
        if (std.mem.indexOf(u8, target, "://") != null or std.mem.startsWith(u8, target, "mailto:")) continue;
        const resolved = try std.fs.path.resolvePosix(gpa, &.{ dir, target });
        defer gpa.free(resolved);
        if (pointsAt(resolved, path)) return true;
    }
    var spans = std.mem.splitScalar(u8, text, '`');
    _ = spans.next();
    while (spans.next()) |span| {
        defer _ = spans.next();
        if (std.mem.indexOfScalar(u8, span, '/') == null or std.mem.indexOfAny(u8, span, " \n") != null) continue;
        const named = std.mem.trimStart(u8, std.mem.trimStart(u8, span, "."), "/");
        if (pointsAt(named, path)) return true;
    }
    return false;
}

fn repoUrl(target: []const u8) ?[]const u8 {
    const repo = "https://github.com/glowcap-org/glowcap/";
    if (!std.mem.startsWith(u8, target, repo)) return null;
    const rest = target[repo.len..];
    for ([_][]const u8{ "blob/main/", "tree/main/" }) |prefix| {
        if (std.mem.startsWith(u8, rest, prefix)) return rest[prefix.len..];
    }
    return null;
}

fn pointsAt(target: []const u8, path: []const u8) bool {
    const bare = std.mem.trimEnd(u8, target, "/");
    if (bare.len == 0 or std.mem.eql(u8, bare, ".")) return false;
    if (std.mem.eql(u8, bare, path)) return true;
    return std.mem.startsWith(u8, path, bare) and path.len > bare.len and path[bare.len] == '/';
}

/// The directory a README explains when it declares no header: the files
/// directly in it. The root README explains no one directory.
pub fn readmeDir(path: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, path, "/README.md")) return null;
    return path[0 .. path.len - "README.md".len];
}

/// Whether `changed` is code that `source` names: the file itself, or any
/// file under a named directory.
pub fn covers(source: []const u8, changed: []const u8) bool {
    if (std.mem.endsWith(u8, source, "/")) return std.mem.startsWith(u8, changed, source);
    return std.mem.eql(u8, source, changed);
}

test "the place decides kind and audience where it can" {
    try std.testing.expectEqual(Kind.temporary, classify("docs/planning/rooms.md", "").kind);
    try std.testing.expectEqual(Kind.static, classify("docs/planning/plan-to-plan.md", "").kind);
    try std.testing.expectEqual(Kind.living, classify("bench/loam/results.md", "").kind);
    try std.testing.expectEqual(Kind.living, classify("docs/decisions/adr/ADR-0001-x.md", "").kind);
    try std.testing.expectEqual(Audience.human, classify("site/content/why.smd", "").audience);
    try std.testing.expectEqual(Audience.human, classify("README.md", "").audience);
    try std.testing.expectEqual(Audience.agent, classify(".agents/rules/cli.md", "").audience);
    try std.testing.expectEqual(Audience.shared, classify("CONTRIBUTING.md", "").audience);
    try std.testing.expectEqual(Audience.human, classify("apps/README.md", "").audience);
    try std.testing.expectEqual(Audience.human, classify("apps/newapp/README.md", "").audience);
    try std.testing.expectEqual(Audience.human, classify("bindings/ts/newpkg/README.md", "").audience);
    try std.testing.expectEqual(Audience.shared, classify("bindings/proofs/README.md", "").audience);
    try std.testing.expectEqual(Audience.shared, classify("apps/rooms/web/ui/README.md", "").audience);
    try std.testing.expectEqual(Audience.shared, classify("apps/_demo/README.md", "").audience);
}

test "an OKF header declares the rest" {
    const doc = "---\ntype: living\ndescription: What ships.\naudience: human\nsources:\n  - resource: /src/loam/\n  - resource: https://ocapn.org\n---\n\n# Shipped\n";
    try std.testing.expectEqual(Doc{ .kind = .living, .audience = .human }, classify("docs/shipped.md", doc));
    try std.testing.expectEqual(@as(?[]const u8, null), problem("docs/shipped.md", doc));
    var sources = Frontmatter.of(doc).?.sources().?;
    try std.testing.expectEqualStrings("src/loam/", sourcePath(sources.next().?).?);
    try std.testing.expectEqual(@as(?[]const u8, null), sourcePath(sources.next().?));
    try std.testing.expectEqual(@as(?[]const u8, null), sources.next());

    try std.testing.expect(problem("docs/loam.md", "# Loam\n") != null);
    try std.testing.expect(problem("apps/x/README.md", "# X\n") == null);
    try std.testing.expect(problem("docs/a.md", "---\ntype: static\ndescription: A.\nsources: []\ntitle: A\n---\n") != null);
    try std.testing.expect(problem("docs/a.md", "---\ntype: static\ndescription: A: b.\nsources: []\n---\n") != null);
    try std.testing.expect(problem("docs/a.md", "---\ntype: static\ndescription: A.\n---\n") != null);
    try std.testing.expect(problem("docs/a.md", "---\ntype: draft\ndescription: A.\nsources: []\n---\n") != null);
    try std.testing.expect(covers("src/loam/", "src/loam/core/mod.zig"));
    try std.testing.expect(!covers("src/loam/mod.zig", "src/loam/core/mod.zig"));
}

test "a doc without a header names what it links and spans" {
    const gpa = std.testing.allocator;
    const text = "See [the gate](../../tools/check/source_check.zig#L3), `src/loam/` and [deploy](https://github.com/glowcap-org/glowcap/blob/main/apps/rooms/web/deploy/README.md).";
    try std.testing.expect(try names(gpa, ".agents/rules/x.md", text, "tools/check/source_check.zig"));
    try std.testing.expect(try names(gpa, ".agents/rules/x.md", text, "src/loam/core/mod.zig"));
    try std.testing.expect(try names(gpa, ".agents/rules/x.md", text, "apps/rooms/web/deploy/README.md"));
    try std.testing.expect(!try names(gpa, ".agents/rules/x.md", text, "src/loamy/mod.zig"));
    try std.testing.expect(!try names(gpa, ".agents/rules/x.md", text, "tools/check/source_check/util.zig"));
}
