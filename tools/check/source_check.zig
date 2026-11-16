//! Static source-contract gate for cross-file facts the compiler cannot hold:
//! scaffolding, docs, generated mirrors, ABI spines, and product structure.
//! Wired as `zig build source-check` and into `zig build check`.

const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const bans = @import("source_check/bans.zig");
const entry_wiring = @import("source_check/entry_wiring.zig");
const scaffolding = @import("source_check/scaffolding.zig");
const ffi_omissions = @import("source_check/ffi_omissions.zig");

/// The check modules. `check()` runs every public function of a listed module
/// whose name starts with `check`, in list order then declaration order. Each
/// has the entry signature `fn (std.Io, std.mem.Allocator, std.Io.Dir,
/// *std.ArrayList([]const u8)) !void`, and one with another signature does not
/// compile. A listed module's helper that should not run is not public or has
/// a name that does not start with `check`. A nested module that is not listed
/// is reached through a listed one.
const checks = .{
    bans,
    @import("source_check/bans/native_identifier.zig"),
    @import("source_check/binding_runtime_proof.zig"),
    @import("source_check/binding_spine/iroh.zig"),
    @import("source_check/binding_spine/constants.zig"),
    @import("source_check/binding_spine/host_actions.zig"),
    @import("source_check/binding_spine/embedder.zig"),
    @import("source_check/binding_spine/ffi_surface.zig"),
    @import("source_check/binding_spine/viewer.zig"),
    @import("source_check/binding_spine/python_sigs.zig"),
    @import("source_check/docs/adr.zig"),
    @import("source_check/docs/links.zig"),
    @import("source_check/docs/site.zig"),
    @import("source_check/docs/maps.zig"),
    @import("source_check/docs/inventories.zig"),
    @import("source_check/docs/threat_model.zig"),
    @import("source_check/docs/claim_parity.zig"),
    @import("source_check/docs/snippets.zig"),
    @import("source_check/docs/ocapn_conformance.zig"),
    @import("source_check/docs/temporary.zig"),
    @import("source_check/docs/public_paths.zig"),
    @import("source_check/docs/section_refs.zig"),
    @import("source_check/docs/bench_figures.zig"),
    @import("source_check/docs/source_comments.zig"),
    @import("source_check/docs/static_docs.zig"),
    @import("source_check/docs/headers.zig"),
    @import("source_check/docs/code_names.zig"),
    @import("source_check/docs/voice.zig"),
    @import("source_check/project_shape/hygiene.zig"),
    @import("source_check/project_shape/discarded_errors.zig"),
    @import("source_check/project_shape/layers.zig"),
    @import("source_check/project_shape/packages.zig"),
    @import("source_check/project_shape/license_manifests.zig"),
    @import("source_check/project_shape/registries.zig"),
    @import("source_check/project_shape/examples.zig"),
    @import("source_check/project_shape/steps.zig"),
    @import("source_check/project_shape/execution_deadlines.zig"),
    @import("source_check/project_shape/zig_module_surface.zig"),
    @import("source_check/project_shape/budgets.zig"),
    @import("source_check/project_shape/playwright.zig"),
    @import("source_check/project_shape/npm_pins.zig"),
    @import("source_check/project_shape/formatting.zig"),
    @import("source_check/project_shape/zig_version.zig"),
    @import("source_check/project_shape/dependency_doc.zig"),
    @import("source_check/doc_orphans.zig"),
    @import("source_check/prerelease_versions.zig"),
    @import("source_check/rust_manifest_inventory.zig"),
    @import("source_check/rust_unsafe_floor.zig"),
    @import("source_check/rooms_scenes.zig"),
    @import("source_check/runtime_paths.zig"),
    @import("source_check/test_wiring.zig"),
    entry_wiring,
    @import("source_check/ui.zig"),
    @import("source_check/css_wellformed.zig"),
    @import("source_check/css_lightdark.zig"),
    @import("source_check/rooms_ui.zig"),
    @import("source_check/rooms_avatar.zig"),
    @import("source_check/literal_pins.zig"),
    @import("source_check/mark_assets.zig"),
    @import("source_check/prose_file_claims.zig"),
    @import("source_check/rooms_session_access.zig"),
    @import("source_check/rooms_rust_tasks.zig"),
    @import("source_check/rooms_rust_ownership.zig"),
    @import("source_check/rooms_proofs.zig"),
    @import("source_check/rooms_protocol.zig"),
    scaffolding,
    @import("source_check/agents_catalog.zig"),
    @import("source_check/c_abi/versions.zig"),
    @import("source_check/c_abi/surface.zig"),
    @import("source_check/c_abi/resolve.zig"),
    @import("source_check/c_abi/resolve_ports.zig"),
    @import("source_check/c_abi/resolve_cases.zig"),
    @import("source_check/c_abi/cites.zig"),
    @import("source_check/c_abi/errdefer.zig"),
    @import("source_check/c_abi/wiring.zig"),
    @import("source_check/c_abi/mirrors.zig"),
    @import("source_check/binding_literals.zig"),
    @import("source_check/captp_product/node_actions.zig"),
    @import("source_check/captp_product/pins.zig"),
    @import("source_check/captp_product/codes.zig"),
    @import("source_check/captp_product/relay.zig"),
    @import("source_check/captp_product/racket.zig"),
    @import("source_check/captp_product/skills.zig"),
    @import("source_check/captp_product/deadlines.zig"),
    @import("source_check/captp_product/cli_ux.zig"),
    @import("source_check/zig_docs.zig"),
    @import("source_check/zig_doc_names.zig"),
    @import("source_check/zig_dead_fns.zig"),
    @import("source_check/fuzz.zig"),
    @import("source_check/file_length.zig"),
    @import("source_check/zig_duplicate_bodies.zig"),
    @import("source_check/namespaces.zig"),
    @import("source_check/signing_domain.zig"),
};

/// Create the `source-check` build step.
pub fn create(b: *Build) *Step {
    const exe = b.addExecutable(.{
        .name = "source-check-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check/source_check_main.zig"),
            .target = b.graph.host,
            // This analyzer scans the whole source tree on every gate. Keep
            // safety checks while optimizing its parsing and traversal loops.
            .optimize = .safe,
            .imports = checkImports(b, b.graph.host, .safe),
        }),
    });
    const run = b.addRunArtifact(exe);
    run.addArg(b.root.toString(b.allocator) catch @panic("OOM"));
    return &run.step;
}

/// The modules some checks read by reflection rather than by parsing their
/// text: the codec-neutral model, the `libglowcap_host` symbol inventory, and
/// the shared, Python, and Racket FFI omission tables that the binding
/// runtime-proof check joins.
pub fn checkImports(b: *Build, target: Build.ResolvedTarget, optimize: std.lang.Optimize) []const Build.Module.Import {
    const policies = [_][]const u8{ "shared", "python", "racket" };
    const imports = b.allocator.alloc(Build.Module.Import, 3 + policies.len) catch @panic("OOM");
    imports[0] = .{ .name = "model", .module = leafModule(b, target, optimize, "src/ocapn/model/mod.zig", &.{}) };
    imports[1] = .{ .name = "host_inventory", .module = hostInventoryModule(b, target, optimize) };
    // The inventory writer owns how a row names a step, so the documented-step
    // check reads rows through it.
    imports[2] = .{ .name = "build_steps_doc", .module = leafModule(b, target, optimize, "tools/build/build_steps_doc.zig", &.{}) };
    inline for (policies, 3..) |binding, i| {
        imports[i] = .{ .name = "ffi_omissions_" ++ binding, .module = leafModule(b, target, optimize, ffi_omissions.path(binding), &.{}) };
    }
    return imports;
}

/// `src/c_abi/host/symbols.zig` alone. It imports only `c_abi_shared` for the
/// `Symbol` row type, so a shim exposes the shared vocabulary leaf under that
/// name instead of the whole shared layer.
fn hostInventoryModule(b: *Build, target: Build.ResolvedTarget, optimize: std.lang.Optimize) *Build.Module {
    const vocabulary = leafModule(b, target, optimize, "src/c_abi/shared/symbols.zig", &.{});
    const shim = b.addWriteFiles().add("c_abi_shared.zig", "pub const symbols = @import(\"symbols\");\n");
    const shared = b.createModule(.{
        .root_source_file = shim,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "symbols", .module = vocabulary }},
    });
    return leafModule(b, target, optimize, "src/c_abi/host/symbols.zig", &.{.{ .name = "c_abi_shared", .module = shared }});
}

fn leafModule(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    comptime path: []const u8,
    imports: []const Build.Module.Import,
) *Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
}

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
) !usize {
    var violations: std.ArrayList([]const u8) = .empty;
    defer violations.deinit(gpa);

    try scaffolding.expectSymlink(io, gpa, root, &violations, "CLAUDE.md", "AGENTS.md");
    try scaffolding.expectSymlink(io, gpa, root, &violations, ".claude/rules", "../.agents/rules");
    try scaffolding.expectSymlink(io, gpa, root, &violations, ".claude/skills", "../.agents/skills");
    try scaffolding.expectSymlink(io, gpa, root, &violations, ".cursor/skills", "../.agents/skills");
    try scaffolding.expectAbsent(io, gpa, root, &violations, ".codex/skills", "Codex loads .agents/skills directly");
    // The shared UI core. A tool that writes through one of these turns it
    // into a regular file and the brand forks silently; see checkUiCore for
    // the rest of that contract. tokens.css is the palette. mark.css is the
    // stacked lockup both surfaces draw.
    try scaffolding.expectSymlink(io, gpa, root, &violations, "site/assets/tokens.css", "../../ui/tokens.css");
    try scaffolding.expectSymlink(io, gpa, root, &violations, "apps/rooms/web/ui/tokens.css", "../../../../ui/tokens.css");
    try scaffolding.expectSymlink(io, gpa, root, &violations, "site/assets/mark.css", "../../ui/mark.css");
    try scaffolding.expectSymlink(io, gpa, root, &violations, "apps/rooms/web/ui/mark.css", "../../../../ui/mark.css");

    try bans.runBans(io, gpa, root, &violations, bans.all);

    try entry_wiring.runListed(checks, io, gpa, root, &violations);

    if (violations.items.len != 0) {
        for (violations.items) |msg| std.debug.print("source-check: {s}\n", .{msg});
    }
    return violations.items.len;
}

test {
    _ = @import("toolchain_check.zig");
    // Every listed check module runs its tests. A nested module the list does
    // not name declares its tests here, and `test_wiring.zig` holds this block
    // to the tree.
    inline for (checks) |module| _ = module;
    _ = @import("source_check/docs/anchors.zig");
    _ = @import("source_check/docs/kinds.zig");
    _ = @import("source_check/docs/ocapn_conformance_transaction_test.zig");
    _ = @import("source_check/docs/paragraphs.zig");
    _ = @import("source_check/docs/paths.zig");
    _ = @import("source_check/docs/reader_voice.zig");
    _ = @import("source_check/markdown.zig");
    _ = @import("source_check/project_shape/execution_deadlines/zig_tests.zig");
    _ = @import("source_check/rooms_ui/text_catalog.zig");
    _ = @import("source_check/rooms_ui/text_voice.zig");
    _ = @import("source_check/runtime_proof_lex.zig");
    _ = @import("source_check/source_tree.zig");
    _ = @import("source_check/text_match.zig");
}
