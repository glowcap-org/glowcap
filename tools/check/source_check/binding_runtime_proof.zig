//! Every host-tier verb a dynamically typed binding claims must be reachable
//! from a runtime proof.
//!
//! Rust and TypeScript refuse a wrapper that names something undefined or calls
//! it with the wrong arity, `cargo` and `deno check` are that proof. Python and
//! Racket refuse nothing until the line runs, so a `glowcap_host_*` wrapper no
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
//! Wired by the source-check driver (`tools/check/source_check.zig`).

const std = @import("std");
const source_tree = @import("source_tree.zig");
const text_match = @import("text_match.zig");
const violation_log = @import("violation_log.zig");
const lex = @import("runtime_proof_lex.zig");
const host_inventory = @import("host_inventory");
const ffi_omissions = @import("ffi_omissions.zig");

const appendViolation = violation_log.appendViolation;
const containsAsSymbol = text_match.containsAsSymbol;

const Binding = struct {
    lang: lex.Lang,
    /// Names the binding in failure messages.
    name: []const u8,
    /// The exports the binding's omission policy leaves out of its FFI table,
    /// read from the same compiled policy its generator checks.
    omitted: []const []const u8,
    /// The policy file, named where a verb lacks both a proof and an entry.
    policy_path: []const u8,
    ext: []const u8,
    /// The binding's library: wrapper definitions, never proof.
    lib: []const []const u8,
    /// Basenames of the generated FFI declaration tier. A row there declares the
    /// symbol rather than calling it, so reading it as a call site would make
    /// every verb its own proof.
    ffi_tier: []const []const u8,
    /// Run entrypoints belonging to this binding alone, `proof_roots` below
    /// applies to every binding.
    proof: []const []const u8,

    fn omits(self: Binding, verb: []const u8) bool {
        for (self.omitted) |name| {
            if (std.mem.eql(u8, name, verb)) return true;
        }
        return false;
    }
};

/// Trees a `zig build` step executes. The hermetic per-binding proof families
/// (`bindings/proofs/`) and the cross-implementation interop clients are the
/// ones CI runs on every push (`ci/groups.py`) and they carry every proven verb,
/// the demo apps and benchmark clients are run on demand and count the same,
/// because what makes a call site proof is that a build step runs it.
const proof_roots = [_][]const u8{ "bindings/proofs", "interop", "test/driver/transports", "test/support/transport", "apps", "bench" };

const bindings = [_]Binding{
    .{
        .lang = .python,
        .name = "python",
        .omitted = &policyNames(@import("ffi_omissions_python")),
        .policy_path = ffi_omissions.path("python"),
        .ext = ".py",
        .lib = &.{"bindings/python/glowcap"},
        .ffi_tier = &.{"_sigs_gen.py"},
        .proof = &.{ "bindings/python/test", "bindings/python/relay.py" },
    },
    .{
        .lang = .racket,
        .name = "racket",
        .omitted = &policyNames(@import("ffi_omissions_racket")),
        .policy_path = ffi_omissions.path("racket"),
        .ext = ".rkt",
        .lib = &.{
            "bindings/racket/private",
            "bindings/racket/glowcap.rkt",
            "bindings/racket/glowcap-tcp.rkt",
            "bindings/racket/glowcap-iroh.rkt",
            "bindings/racket/glowcap-inproc.rkt",
        },
        .ffi_tier = &.{ "ffi-host-gen.rkt", "ffi-shared.rkt" },
        .proof = &.{ "bindings/racket/test", "bindings/racket/relay.rkt" },
    },
};

fn policyNames(comptime policy: type) [policy.omissions.len][]const u8 {
    var names: [policy.omissions.len][]const u8 = undefined;
    inline for (policy.omissions, 0..) |entry, i| names[i] = entry.name;
    return names;
}

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (bindings) |binding| {
        var graph = Graph.init(arena, &host_verbs);
        for (binding.lib) |path| try graph.absorbTree(io, gpa, root, violations, binding, path, .library);
        for (proof_roots) |path| try graph.absorbTree(io, gpa, root, violations, binding, path, .proof);
        for (binding.proof) |path| try graph.absorbTree(io, gpa, root, violations, binding, path, .proof);
        if (graph.defs.count() == 0) {
            try appendViolation(gpa, violations, "{s}: no wrapper definitions found under {s} — the runtime-proof scanner no longer matches this binding", .{ binding.name, binding.lib[0] });
            continue;
        }
        try graph.close();

        for (host_verbs) |verb| {
            if (binding.omits(verb)) continue;
            const sites = graph.sites.get(verb);
            if (sites) |set| if (graph.anyReached(set)) continue;
            if (sites) |set| {
                try appendViolation(gpa, violations, "{s}: `{s}` is called only from `{s}`, which no gate reaches — call that wrapper from a script under interop/, apps/, bench/, or the binding's own proof entrypoints, or record its omission and reason in {s}", .{ binding.name, verb, graph.firstName(set), binding.policy_path });
            } else {
                try appendViolation(gpa, violations, "{s}: `{s}` has no call site outside the generated FFI table — give it a wrapper a proof reaches, or record its omission and reason in {s}", .{ binding.name, verb, binding.policy_path });
            }
        }
    }
}

// -- the symbol inventory ----------------------------------------------------

/// Every `glowcap_host_*` export, read from the compiled `libglowcap_host`
/// inventory the binding generators render. A verb a binding's omission policy
/// leaves out is not demanded of that binding here.
const host_verbs = names: {
    var names: [host_inventory.symbols.len][]const u8 = undefined;
    for (host_inventory.symbols, &names) |row, *name| name.* = row.name;
    const final = names;
    break :names final;
};

// -- the call graph ----------------------------------------------------------

const Role = enum { library, proof };

const NameSet = std.StringHashMap(void);

/// The name standing for a file's module-init code, which runs on import and so
/// is always reached. It cannot collide with a definition: no identifier lexes
/// with angle brackets in either language.
const module_owner = "<module>";

const Graph = struct {
    arena: std.mem.Allocator,
    verbs: []const []const u8,
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

    fn init(arena: std.mem.Allocator, verbs: []const []const u8) Graph {
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
                if (!std.mem.eql(u8, entry.basename, "dist")) {
                    try source_tree.enterSourceDirectory(io, self.arena, &walker, path, entry);
                }
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
        const stripped = try lex.stripProse(self.arena, binding.lang, raw);
        var owners = lex.Owners.init(binding.lang);
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
        if (std.mem.indexOf(u8, line, "glowcap_host_") == null) return;
        for (self.verbs) |verb| {
            // Boundary-matched, so `…_publish` is not read out of
            // `…_published_ref`.
            if (!containsAsSymbol(line, verb)) continue;
            const slot = try self.sites.getOrPut(verb);
            if (!slot.found_existing) slot.value_ptr.* = NameSet.init(self.arena);
            try slot.value_ptr.put(owner, {});
        }
    }

    fn collect(self: *Graph, set: *NameSet, lang: lex.Lang, line: []const u8) !void {
        _ = self;
        var it = lex.IdentIter{ .lang = lang, .rest = line };
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

test "the Python binding omits a verb its compiled policy lists and demands one it does not" {
    const python = bindings[0];
    try std.testing.expectEqualStrings("python", python.name);
    try std.testing.expect(python.omits("glowcap_host_plan_dial"));
    try std.testing.expect(!python.omits("glowcap_host_session_send"));
}
