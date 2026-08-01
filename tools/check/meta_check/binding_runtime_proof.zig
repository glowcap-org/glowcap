//! Every host-tier verb a dynamically typed binding claims must be reachable
//! from a runtime proof.
//!
//! Rust and TypeScript refuse a wrapper that names something undefined or calls
//! it with the wrong arity; `cargo` and `deno check` are that proof. Python and
//! Racket refuse nothing until the line runs, so a `pancake_host_*` wrapper no
//! gate ever executes can ship with an undefined name or a mismatched argument
//! list in it and nothing in the tree will say so. Twice it did. This check is
//! the missing compiler for those two bindings: every verb's wrapper must be
//! reachable, per binding, from code a `zig build` step runs.
//!
//! Reachability, not execution, is what a static check can claim. The call graph
//! is built over the binding's own library, where a definition refers to another
//! when its body names it, and it is rooted at the identifiers a proof script
//! mentions plus the module-init code that runs on import. A verb passes when at
//! least one of its call sites sits in a definition that closure contains. That
//! is a necessary condition for the verb to run, and the whole defect class here
//! fails it: a wrapper nothing calls is reachable from nothing.
//!
//! Wired by the meta-check driver (`tools/check/meta_check.zig`).

const std = @import("std");
const util = @import("util.zig");
const binding_spine = @import("binding_spine.zig");

const appendViolation = util.appendViolation;
const containsAsSymbol = binding_spine.containsAsSymbol;

const Lang = enum { python, racket };

const Binding = struct {
    lang: Lang,
    /// Names the `<name>_omit` field in `src/c_abi/host/symbols.zig` that opts a
    /// row out of this binding, and appears in every failure message.
    name: []const u8,
    ext: []const u8,
    /// The binding's library: wrapper definitions, never proof.
    lib: []const []const u8,
    /// Basenames of the generated FFI declaration tier. A row there declares the
    /// symbol rather than calling it, so reading it as a call site would make
    /// every verb its own proof.
    ffi_tier: []const []const u8,
    /// Run entrypoints belonging to this binding alone; `proof_roots` below
    /// applies to every binding.
    proof: []const []const u8,
};

/// Trees a `zig build` step executes. The hermetic per-binding proof families
/// (`bindings/proofs/`) and the cross-implementation interop clients are the
/// ones `ci/gates.sh` runs on every push and they carry every proven verb today;
/// the demo apps and benchmark clients are run on demand and count the same,
/// because what makes a call site proof is that a build step runs it.
const proof_roots = [_][]const u8{ "bindings/proofs", "interop", "apps", "bench" };

const bindings = [_]Binding{
    .{
        .lang = .python,
        .name = "python",
        .ext = ".py",
        .lib = &.{"bindings/python/pancake"},
        .ffi_tier = &.{ "_ffi_host.py", "_sigs_gen.py" },
        .proof = &.{ "bindings/python/zig_smoke.py", "bindings/python/relay.py" },
    },
    .{
        .lang = .racket,
        .name = "racket",
        .ext = ".rkt",
        .lib = &.{
            "bindings/racket/private",
            "bindings/racket/pancake.rkt",
            "bindings/racket/pancake-tcp.rkt",
            "bindings/racket/pancake-iroh.rkt",
            "bindings/racket/pancake-inproc.rkt",
        },
        .ffi_tier = &.{ "ffi-host-gen.rkt", "ffi-host.rkt", "ffi-shared.rkt" },
        .proof = &.{ "bindings/racket/zig-smoke.rkt", "bindings/racket/relay.rkt" },
    },
};

const Allowed = struct {
    binding: []const u8,
    symbol: []const u8,
    why: []const u8,
};

/// Rows with no runtime proof today, each carrying why. A row whose verb becomes
/// provable fails the gate, so the list only shrinks. It is empty: every verb
/// either has a proof or an `<name>_omit` reason on its inventory row.
const allowlist = [_]Allowed{};

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var verbs: std.ArrayList(Verb) = .empty;
    try collectVerbs(io, gpa, arena, root, violations, &verbs);
    if (verbs.items.len == 0) return;

    // Allowlist rows this run reached, so a row that stops applying is caught.
    var used = std.StringHashMap(void).init(arena);

    for (bindings) |binding| {
        var graph = Graph.init(arena, verbs.items);
        for (binding.lib) |path| try graph.absorbTree(io, gpa, root, violations, binding, path, .library);
        for (proof_roots) |path| try graph.absorbTree(io, gpa, root, violations, binding, path, .proof);
        for (binding.proof) |path| try graph.absorbTree(io, gpa, root, violations, binding, path, .proof);
        if (graph.defs.count() == 0) {
            try appendViolation(gpa, violations, "{s}: no wrapper definitions found under {s} — the runtime-proof scanner no longer matches this binding", .{ binding.name, binding.lib[0] });
            continue;
        }
        try graph.close();

        for (verbs.items) |verb| {
            if (verb.omits(binding.name)) continue;
            const sites = graph.sites.get(verb.name);
            const allowed = isAllowed(binding.name, verb.name);
            const proven = if (sites) |set| graph.anyReached(set) else false;
            // A row the run matched at all is not stale, however it matched, so
            // the sweep below reports only rows naming nothing.
            if (allowed) try used.put(try std.fmt.allocPrint(arena, "{s}/{s}", .{ binding.name, verb.name }), {});
            if (proven) {
                if (allowed) {
                    try appendViolation(gpa, violations, "{s}: `{s}` now has a runtime proof — delete its `allowlist` row in tools/check/meta_check/binding_runtime_proof.zig; that list only shrinks", .{ binding.name, verb.name });
                }
                continue;
            }
            if (allowed) continue;
            if (sites) |set| {
                try appendViolation(gpa, violations, "{s}: `{s}` is called only from `{s}`, which no gate reaches — call that wrapper from a script under interop/, apps/, bench/, or the binding's own proof entrypoints, or add an `allowlist` row with its reason in tools/check/meta_check/binding_runtime_proof.zig", .{ binding.name, verb.name, graph.firstName(set) });
            } else {
                try appendViolation(gpa, violations, "{s}: `{s}` has no call site outside the generated FFI table — give it a wrapper a proof reaches, or record a `{s}_omit` reason on its row in src/c_abi/host/symbols.zig", .{ binding.name, verb.name, binding.name });
            }
        }
    }

    for (allowlist) |row| {
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}/{s}", .{ row.binding, row.symbol }) catch continue;
        if (used.contains(key)) continue;
        try appendViolation(gpa, violations, "{s}: `allowlist` row `{s}` matched nothing this run — its binding name or symbol is stale; fix or delete it in tools/check/meta_check/binding_runtime_proof.zig", .{ row.binding, row.symbol });
    }
}

fn isAllowed(binding: []const u8, symbol: []const u8) bool {
    for (allowlist) |row| {
        if (std.mem.eql(u8, row.binding, binding) and std.mem.eql(u8, row.symbol, symbol)) return true;
    }
    return false;
}

// -- the symbol inventory ----------------------------------------------------

const Verb = struct {
    name: []const u8,
    /// Binding names whose row carries an `<name>_omit` reason.
    omitted: []const []const u8,

    fn omits(self: Verb, binding: []const u8) bool {
        for (self.omitted) |name| {
            if (std.mem.eql(u8, name, binding)) return true;
        }
        return false;
    }
};

/// Read `src/c_abi/host/symbols.zig`, the annotated inventory the binding
/// generators already treat as the export set, and keep each row's per-binding
/// omission so a verb a binding reaches by another spelling is not demanded of
/// it here as well.
fn collectVerbs(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    out: *std.ArrayList(Verb),
) !void {
    const path = "src/c_abi/host/symbols.zig";
    const contents = root.readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for runtime-proof check with {s}", .{ path, @errorName(err) });
        return;
    };
    const table_start = std.mem.indexOf(u8, contents, "pub const symbols = [_]Symbol{") orelse {
        try appendViolation(gpa, violations, "{s}: missing `pub const symbols` table — the runtime-proof scanner no longer matches this inventory", .{path});
        return;
    };
    const table = contents[table_start..];

    const needle = ".name = \"pancake_host_";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, table, from, needle)) |at| {
        const name_start = at + ".name = \"".len;
        const close = std.mem.indexOfScalarPos(u8, table, name_start, '"') orelse break;
        const name = table[name_start..close];
        // The row runs to the next row's `.name =`, or to the end of the table.
        const next = std.mem.indexOfPos(u8, table, close, needle) orelse table.len;
        const row = table[close..next];
        from = close;

        var omitted: std.ArrayList([]const u8) = .empty;
        for (bindings) |binding| {
            const field = try std.fmt.allocPrint(arena, ".{s}_omit", .{binding.name});
            if (std.mem.indexOf(u8, row, field) != null) try omitted.append(arena, binding.name);
        }
        try out.append(arena, .{ .name = name, .omitted = omitted.items });
    }
    if (out.items.len == 0) {
        try appendViolation(gpa, violations, "{s}: no `pancake_host_*` rows found — the runtime-proof scanner no longer matches this inventory", .{path});
    }
}

// -- the call graph ----------------------------------------------------------

const Role = enum { library, proof };

const NameSet = std.StringHashMap(void);

/// The name standing for a file's module-init code, which runs on import and so
/// is always reached. It cannot collide with a definition: no identifier lexes
/// with angle brackets in either language.
const module_owner = "<module>";

const Graph = struct {
    arena: std.mem.Allocator,
    verbs: []const Verb,
    /// Wrapper definitions found in the binding's library.
    defs: NameSet,
    /// Definition name to the identifiers its body names.
    edges: std.StringHashMap(NameSet),
    /// Verb to the definition names whose bodies call it.
    sites: std.StringHashMap(NameSet),
    /// Identifiers a proof script names, plus module-init code and the dunders
    /// the interpreter calls for you: the roots of the closure.
    roots: NameSet,
    reached: NameSet,

    fn init(arena: std.mem.Allocator, verbs: []const Verb) Graph {
        return .{
            .arena = arena,
            .verbs = verbs,
            .defs = NameSet.init(arena),
            .edges = std.StringHashMap(NameSet).init(arena),
            .sites = std.StringHashMap(NameSet).init(arena),
            .roots = NameSet.init(arena),
            .reached = NameSet.init(arena),
        };
    }

    fn absorbTree(
        self: *Graph,
        io: std.Io,
        gpa: std.mem.Allocator,
        root: std.Io.Dir,
        violations: *std.ArrayList([]const u8),
        binding: Binding,
        path: []const u8,
        role: Role,
    ) !void {
        if (std.mem.endsWith(u8, path, binding.ext)) {
            const contents = root.readFileAlloc(io, path, self.arena, .limited(4 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for runtime-proof check with {s}", .{ path, @errorName(err) });
                return;
            };
            try self.absorbFile(binding, contents, role);
            return;
        }
        var dir = root.openDir(io, path, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for runtime-proof check with {s}", .{ path, @errorName(err) });
            return;
        };
        defer dir.close(io);
        var walker = try dir.walkSelectively(self.arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) {
                if (!isSkippedDir(entry.basename)) try walker.enter(io, entry);
                continue;
            }
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, binding.ext)) continue;
            if (role == .library and isFfiTier(binding, entry.basename)) continue;
            const contents = dir.readFileAlloc(io, entry.path, self.arena, .limited(4 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}/{s}: failed to read for runtime-proof check with {s}", .{ path, entry.path, @errorName(err) });
                continue;
            };
            try self.absorbFile(binding, contents, role);
        }
    }

    fn absorbFile(self: *Graph, binding: Binding, raw: []const u8, role: Role) !void {
        const stripped = try stripProse(self.arena, binding.lang, raw);
        var owners = Owners.init(binding.lang);
        var lines = std.mem.splitScalar(u8, stripped, '\n');
        while (lines.next()) |line| {
            const owner = owners.advance(line);
            if (owner == .inert) continue;
            if (role == .proof) {
                try self.collect(&self.roots, binding.lang, line);
                continue;
            }
            switch (owner) {
                .inert => unreachable,
                .module => {
                    // Module-init code runs on import, so what it names is a root.
                    try self.collect(&self.roots, binding.lang, line);
                    try self.noteSites(line, module_owner);
                },
                .definition => |names| {
                    for (names) |name| {
                        try self.defs.put(name, {});
                        // A dunder is called by the interpreter, never by name.
                        if (isDunder(name)) try self.roots.put(name, {});
                        const slot = try self.edges.getOrPut(name);
                        if (!slot.found_existing) slot.value_ptr.* = NameSet.init(self.arena);
                        try self.collect(slot.value_ptr, binding.lang, line);
                        try self.noteSites(line, name);
                    }
                },
            }
        }
    }

    fn noteSites(self: *Graph, line: []const u8, owner: []const u8) !void {
        if (std.mem.indexOf(u8, line, "pancake_host_") == null) return;
        for (self.verbs) |verb| {
            // Boundary-matched, so `…_publish` is not read out of
            // `…_published_ref`.
            if (!containsAsSymbol(line, verb.name)) continue;
            const slot = try self.sites.getOrPut(verb.name);
            if (!slot.found_existing) slot.value_ptr.* = NameSet.init(self.arena);
            try slot.value_ptr.put(owner, {});
        }
    }

    fn collect(self: *Graph, set: *NameSet, lang: Lang, line: []const u8) !void {
        _ = self;
        var it = IdentIter{ .lang = lang, .rest = line };
        while (it.next()) |ident| try set.put(ident, {});
    }

    fn close(self: *Graph) !void {
        var frontier: std.ArrayList([]const u8) = .empty;
        try self.reached.put(module_owner, {});
        var it = self.roots.keyIterator();
        while (it.next()) |key| {
            if (!self.defs.contains(key.*)) continue;
            if ((try self.reached.getOrPut(key.*)).found_existing) continue;
            try frontier.append(self.arena, key.*);
        }
        var cursor: usize = 0;
        while (cursor < frontier.items.len) : (cursor += 1) {
            const refs = self.edges.get(frontier.items[cursor]) orelse continue;
            var refs_it = refs.keyIterator();
            while (refs_it.next()) |ref| {
                if (!self.defs.contains(ref.*)) continue;
                if ((try self.reached.getOrPut(ref.*)).found_existing) continue;
                try frontier.append(self.arena, ref.*);
            }
        }
    }

    fn anyReached(self: *Graph, set: NameSet) bool {
        var it = set.keyIterator();
        while (it.next()) |name| {
            if (self.reached.contains(name.*)) return true;
        }
        return false;
    }

    fn firstName(self: *Graph, set: NameSet) []const u8 {
        _ = self;
        var it = set.keyIterator();
        return if (it.next()) |name| name.* else "?";
    }
};

fn isSkippedDir(basename: []const u8) bool {
    for ([_][]const u8{ "node_modules", "target", "compiled", "__pycache__", ".zig-cache", "zig-out", "dist" }) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }
    return false;
}

fn isFfiTier(binding: Binding, basename: []const u8) bool {
    for (binding.ffi_tier) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }
    return false;
}

fn isDunder(name: []const u8) bool {
    return name.len > 4 and std.mem.startsWith(u8, name, "__") and std.mem.endsWith(u8, name, "__");
}

// -- lexing ------------------------------------------------------------------

/// Blank out comments and string bodies. Prose is where a verb's name is most
/// often written without being called: the Python `enroll` this check was built
/// for was named in three neighbouring docstrings and called from nowhere, and a
/// scan that reads prose as code believes them.
fn stripProse(arena: std.mem.Allocator, lang: Lang, text: []const u8) ![]u8 {
    const out = try arena.alloc(u8, text.len);
    @memset(out, ' ');
    const line_comment: u8 = switch (lang) {
        .python => '#',
        .racket => ';',
    };
    // A Python docstring is the one construct here that spans lines.
    var block: ?[]const u8 = null;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '\n') {
            out[i] = '\n';
            i += 1;
            continue;
        }
        if (block) |close| {
            if (std.mem.startsWith(u8, text[i..], close)) {
                block = null;
                i += close.len;
            } else i += 1;
            continue;
        }
        if (lang == .python and (std.mem.startsWith(u8, text[i..], "\"\"\"") or std.mem.startsWith(u8, text[i..], "'''"))) {
            block = text[i .. i + 3];
            i += 3;
            continue;
        }
        if (ch == line_comment) {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        // Racket's `'` quotes a datum; only Python spells a string with it.
        if (ch == '"' or (ch == '\'' and lang == .python)) {
            i += 1;
            while (i < text.len and text[i] != '\n') {
                if (text[i] == '\\') {
                    i += 2;
                    continue;
                }
                if (text[i] == ch) {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }
        out[i] = ch;
        i += 1;
    }
    return out;
}

const IdentIter = struct {
    lang: Lang,
    rest: []const u8,

    fn isStart(ch: u8) bool {
        return std.ascii.isAlphabetic(ch) or ch == '_';
    }

    fn isPart(lang: Lang, ch: u8) bool {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') return true;
        // A Racket name runs through its dashes and its `!?*<>=/+`, so
        // `session-release!` must not lex as `session` plus `release`.
        return lang == .racket and switch (ch) {
            '-', '!', '?', '*', '<', '>', '=', '/', '+' => true,
            else => false,
        };
    }

    fn next(self: *IdentIter) ?[]const u8 {
        var i: usize = 0;
        while (i < self.rest.len and !isStart(self.rest[i])) i += 1;
        if (i == self.rest.len) return null;
        var end = i + 1;
        while (end < self.rest.len and isPart(self.lang, self.rest[end])) end += 1;
        const ident = self.rest[i..end];
        self.rest = self.rest[end..];
        return ident;
    }
};

/// What owns a line: a chain of enclosing definitions, module-init code, or a
/// form that names wrappers without running them.
const Owner = union(enum) {
    inert,
    module,
    /// Outermost-first chain of enclosing definition names.
    definition: []const []const u8,
};

/// One forward pass giving each line its owner. Python nests by indentation, so
/// a stack of indent-and-name pairs tracks the chain and a multi-line `def`
/// header is held open until its parentheses balance. Racket indents every body,
/// so a column-zero `(` opens the next top-level form and only a `define` form
/// owns the lines beneath it.
const Owners = struct {
    lang: Lang,
    stack_indent: [max_depth]usize = undefined,
    stack_name: [max_depth][]const u8 = undefined,
    depth: usize = 0,
    /// Parentheses left open by a `def` header or an `import` clause.
    pending: isize = 0,
    /// Racket: the open top-level form, when it is a `define`.
    current: ?[]const u8 = null,
    /// Racket: the open top-level form is a `provide` or `require` clause.
    inert: bool = false,
    /// Python: an `import` clause spanning lines.
    importing: bool = false,

    /// Deeper nesting than this stops tracking rather than growing; a
    /// twelve-deep wrapper is not a shape either binding writes.
    const max_depth = 12;

    fn init(lang: Lang) Owners {
        return .{ .lang = lang };
    }

    fn advance(self: *Owners, line: []const u8) Owner {
        return switch (self.lang) {
            .python => self.advancePython(line),
            .racket => self.advanceRacket(line),
        };
    }

    fn advancePython(self: *Owners, line: []const u8) Owner {
        if (self.importing) {
            self.pending += parenDelta(line);
            if (self.pending <= 0) {
                self.importing = false;
                self.pending = 0;
            }
            return .inert;
        }
        if (self.pending > 0) {
            self.pending += parenDelta(line);
            if (self.pending < 0) self.pending = 0;
            return self.chain();
        }
        const body = std.mem.trimStart(u8, line, " \t");
        if (body.len == 0) return self.chain();
        const indent = line.len - body.len;
        while (self.depth > 0 and self.stack_indent[self.depth - 1] >= indent) self.depth -= 1;

        if (self.depth == 0 and (std.mem.startsWith(u8, body, "import ") or std.mem.startsWith(u8, body, "from "))) {
            self.pending = parenDelta(line);
            self.importing = self.pending > 0;
            return .inert;
        }
        if (pythonDefName(body)) |name| {
            if (self.depth < max_depth) {
                self.stack_indent[self.depth] = indent;
                self.stack_name[self.depth] = name;
                self.depth += 1;
            }
            self.pending = parenDelta(line);
            if (self.pending < 0) self.pending = 0;
        }
        return self.chain();
    }

    fn advanceRacket(self: *Owners, line: []const u8) Owner {
        if (line.len != 0 and line[0] == '(') {
            const head = line[1..];
            self.inert = std.mem.startsWith(u8, head, "provide") or std.mem.startsWith(u8, head, "require");
            self.current = racketDefineName(head);
        }
        if (self.inert) return .inert;
        if (self.current) |name| {
            self.stack_name[0] = name;
            return .{ .definition = self.stack_name[0..1] };
        }
        return .module;
    }

    fn chain(self: *Owners) Owner {
        if (self.depth == 0) return .module;
        return .{ .definition = self.stack_name[0..self.depth] };
    }
};

fn parenDelta(line: []const u8) isize {
    var delta: isize = 0;
    for (line) |ch| {
        if (ch == '(') delta += 1;
        if (ch == ')') delta -= 1;
    }
    return delta;
}

fn pythonDefName(body: []const u8) ?[]const u8 {
    var rest = body;
    if (std.mem.startsWith(u8, rest, "async ")) rest = std.mem.trimStart(u8, rest["async ".len..], " ");
    if (!std.mem.startsWith(u8, rest, "def ")) return null;
    const after = std.mem.trimStart(u8, rest["def ".len..], " ");
    var end: usize = 0;
    while (end < after.len and (std.ascii.isAlphanumeric(after[end]) or after[end] == '_')) end += 1;
    return if (end == 0) null else after[0..end];
}

/// The name bound by a column-zero `(define…)` form: `(define (f x) …)`,
/// `(define f …)`, and the `define-values` / `define-syntax-rule` siblings.
fn racketDefineName(head: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, head, "define")) return null;
    var i: usize = "define".len;
    while (i < head.len and head[i] != ' ' and head[i] != '\t') i += 1;
    while (i < head.len and (head[i] == ' ' or head[i] == '\t' or head[i] == '(')) i += 1;
    if (i >= head.len or !IdentIter.isStart(head[i])) return null;
    var end = i;
    while (end < head.len and IdentIter.isPart(.racket, head[end])) end += 1;
    return head[i..end];
}

test "a python def line belongs to itself, not to the sibling above it" {
    var owners = Owners.init(.python);
    const lines = [_][]const u8{
        "class Session:",
        "    def with_gc(self):",
        "        return self",
        "    def enroll(self, ref):",
        "        return call(ref)",
    };
    var last: Owner = .module;
    for (lines) |line| last = owners.advance(line);
    try std.testing.expectEqualStrings("enroll", last.definition[last.definition.len - 1]);
}

test "a multi-line python def header stays open" {
    var owners = Owners.init(.python);
    const lines = [_][]const u8{
        "    def establish_accepted(",
        "        self,",
        "    ) -> Session:",
        "        return plan(self)",
    };
    var last: Owner = .module;
    for (lines) |line| last = owners.advance(line);
    try std.testing.expectEqualStrings("establish_accepted", last.definition[last.definition.len - 1]);
}

test "a racket provide clause owns nothing" {
    var owners = Owners.init(.racket);
    try std.testing.expect(owners.advance("(provide session-release!") == .inert);
    try std.testing.expect(owners.advance("         session-close!)") == .inert);
    const owned = owners.advance("(define (session-release! c ref)");
    try std.testing.expectEqualStrings("session-release!", owned.definition[0]);
    const body = owners.advance("  (pancake_host_ref_release c ref))");
    try std.testing.expectEqualStrings("session-release!", body.definition[0]);
}

test "a racket identifier lexes through its dashes and its bang" {
    var it = IdentIter{ .lang = .racket, .rest = "(session-release! to-exporter offered)" };
    try std.testing.expectEqualStrings("session-release!", it.next().?);
    try std.testing.expectEqualStrings("to-exporter", it.next().?);
    try std.testing.expectEqualStrings("offered", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "prose cannot forge a call" {
    const gpa = std.testing.allocator;
    const python = try stripProse(gpa, .python, "x = 1  # calls enroll\n\"\"\"names enroll\"\"\"\ny = enroll\n");
    defer gpa.free(python);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, python, "enroll"));
    const racket = try stripProse(gpa, .racket, ";; names session-get\n(session-get c)\n");
    defer gpa.free(racket);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, racket, "session-get"));
}

test "every allowlist row names a real binding" {
    for (allowlist) |row| {
        var known = false;
        for (bindings) |binding| {
            if (std.mem.eql(u8, binding.name, row.binding)) known = true;
        }
        try std.testing.expect(known);
        try std.testing.expect(row.why.len != 0);
        try std.testing.expect(std.mem.startsWith(u8, row.symbol, "pancake_host_"));
    }
}
