//! The documentation site pipeline, registered as one subject the root
//! `build.zig` composes: the autodoc API reference, the transport example
//! snippets and their per-language checks, the Zine-rendered site with its
//! output validation, and the local preview server. Zine is a heavyweight
//! static site generator, so it lives behind its own build in
//! `site/build.zig` and is compiled only when the site steps run, the same
//! way the cargo, deno, and racket sibling steps reach for their tool at run
//! time. The hermetic `check` graph never imports it. What does ride `check`
//! is the snippet-staleness check, the Zig and TypeScript snippet checks,
//! and the site output checker's own tests.

const std = @import("std");
const common = @import("common.zig");
const execution = @import("execution.zig");

/// What the pipeline draws from the root build graph.
pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// The public `glowcap` module: the autodoc source and every Zig
    /// snippet's import.
    lib_mod: *std.Build.Module,
    /// The shared `model` layer instance the snippet assembler imports.
    model_mod: *std.Build.Module,
    check_step: *std.Build.Step,
    pin_port: ?u16,
    /// The shared headless-Chromium preflight every browser proof depends on.
    browser_preflight: *std.Build.Step,
};

/// The step handles the root's `bindings` aggregate wires: the site example
/// checks whose language runtime the binding dogfoods already require.
pub const Registered = struct {
    /// The Zig snippet check, returned because the root's iroh section
    /// attaches its two iroh snippet compiles to it (the one named exception
    /// to in-module discovery).
    zig_examples_check: *std.Build.Step,
    python_examples_check: *std.Build.Step,
    rust_examples_check: *std.Build.Step,
    racket_examples_check: *std.Build.Step,
};

pub fn register(ctx: Context) Registered {
    const b = ctx.b;
    const check_step = ctx.check_step;

    // ── API reference (autodoc) ──────────────────────────────────────────────
    // Renders the public `glowcap` module's generated documentation under
    // zig-out/docs/. The site step ships this same artifact as the API
    // reference section, so the reference can never be hand-written prose. Built
    // from the `glowcap` root module but never installed, so the autodoc emit
    // costs nothing on a default `zig build` and no umbrella artifact ships.
    const docs_lib = b.addLibrary(.{
        .name = "glowcap",
        .linkage = .static,
        .root_module = ctx.lib_mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    // Site transport example tabs: snippets under `site/examples/` assemble into
    // SuperMD `code-tabs` between page markers (`tools/gen/site_examples.zig`).
    const site_examples_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen/site_examples.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    site_examples_mod.addImport("model", ctx.model_mod);
    const site_examples_exe = b.addExecutable(.{
        .name = "gen-site-examples",
        .root_module = site_examples_mod,
    });
    const site_examples_write = execution.addArtifact(b, .build_tool, site_examples_exe);
    site_examples_write.setCwd(b.path("."));
    site_examples_write.addArg("write");
    site_examples_write.has_side_effects = true;
    const site_examples_write_step = b.step("gen-site-examples", "Assemble site/examples snippets into SuperMD code-tabs on binding, Start, and transport pages");
    site_examples_write_step.dependOn(&site_examples_write.step);

    const site_examples_check_run = execution.addArtifact(b, .{ .deterministic = 30 }, site_examples_exe);
    site_examples_check_run.setCwd(b.path("."));
    site_examples_check_run.addArg("check");
    const site_examples_check_step = b.step("gen-site-examples-check", "Verify site transport example tabs match site/examples snippets (fails if stale)");
    site_examples_check_step.dependOn(&site_examples_check_run.step);
    check_step.dependOn(site_examples_check_step);

    // The Zig and TypeScript transport tabs are authoritative source, not
    // prose fragments: compile or type-check the exact files so a public
    // example cannot drift from the API it presents. The checked set is
    // discovered from `site/examples/` itself rather than kept as a second
    // list beside the generator's matrix, so a snippet the matrix gains
    // cannot ship unchecked. A `PLANNED:` marker excludes a snippet exactly
    // as `tools/check/site_binding_examples.py` excludes it, and that checker
    // holds planned snippets to comment-only bodies. The iroh Zig tabs are
    // compiled beside the iroh resident module, and the relay Zig tabs beside
    // the native relay module, because those modules stay outside the default
    // glowcap graph.
    // Walk the snippet dirs from the build root, not process cwd. `zig build`
    // from a subdirectory still loads this `build.zig`, and `Dir.cwd()` would
    // miss `site/examples/` and panic before any step ran. Later compile
    // steps already take `b.path(snippet_path)`, which is build-root-relative.
    const snippets_io = b.graph.io;
    const snippets_root = b.root.root_dir.handle;
    var site_zig_snippets: std.ArrayList([]const u8) = .empty;
    var site_ts_snippets: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{
        "site/examples/browser",
        "site/examples/dial",
        "site/examples/listen",
        "site/examples/onion",
    }) |dir_path| {
        var dir = snippets_root.openDir(snippets_io, dir_path, .{ .iterate = true }) catch |err|
            std.debug.panic("site snippets {s}: {s}", .{ dir_path, @errorName(err) });
        defer dir.close(snippets_io);
        var entries = dir.iterate();
        while (entries.next(snippets_io) catch |err|
            std.debug.panic("site snippets {s}: {s}", .{ dir_path, @errorName(err) })) |entry|
        {
            if (entry.kind != .file) continue;
            const is_zig = std.mem.endsWith(u8, entry.name, ".zig");
            if (!is_zig and !std.mem.endsWith(u8, entry.name, ".ts")) continue;
            if (is_zig and (std.mem.eql(u8, entry.name, "iroh.zig") or
                std.mem.endsWith(u8, entry.name, "-relay.zig"))) continue;
            const path = b.fmt("{s}/{s}", .{ dir_path, entry.name });
            const body = snippets_root.readFileAlloc(snippets_io, path, b.allocator, .limited(1 << 20)) catch |err|
                std.debug.panic("site snippet {s}: {s}", .{ path, @errorName(err) });
            if (std.mem.indexOf(u8, body, "PLANNED:") != null) continue;
            const list = if (is_zig) &site_zig_snippets else &site_ts_snippets;
            list.append(b.allocator, path) catch @panic("OOM");
        }
    }
    // Directory iteration order is platform noise; sort so the graph and the
    // deno invocation stay byte-stable across runs.
    for ([_]*std.ArrayList([]const u8){ &site_zig_snippets, &site_ts_snippets }) |list| {
        std.mem.sort([]const u8, list.items, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.lessThan(u8, lhs, rhs);
            }
        }.lessThan);
    }

    const site_zig_examples_check = b.step("site-zig-examples-check", "Compile the authoritative Zig transport site examples");
    check_step.dependOn(site_zig_examples_check);
    for (site_zig_snippets.items) |snippet_path| {
        const name = b.fmt("site-example-{s}", .{snippet_path["site/examples/".len .. snippet_path.len - ".zig".len]});
        std.mem.replaceScalar(u8, name, '/', '-');
        common.addSiteZigExampleCompile(b, ctx.target, ctx.optimize, name, snippet_path, &.{
            .{ .name = "glowcap", .module = ctx.lib_mod },
        }, site_zig_examples_check);
    }

    const site_ts_examples_check = b.step("site-ts-examples-check", "Type-check the authoritative TypeScript transport site examples");
    const site_ts_check = execution.addSystemCommand(b, .build_tool, &.{ "deno", "check", "--config", "deno.json" });
    for (site_ts_snippets.items) |snippet_path| site_ts_check.addArg(snippet_path);
    site_ts_examples_check.dependOn(&site_ts_check.step);
    check_step.dependOn(site_ts_examples_check);

    const site_python_examples_check = b.step("site-python-examples-check", "Type-check the authoritative Python transport site examples");
    const site_python_check = common.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/site_binding_examples.py", "python" });
    site_python_examples_check.dependOn(&site_python_check.step);

    const site_rust_examples_check = b.step("site-rust-examples-check", "Type-check the authoritative Rust transport site examples");
    const site_rust_check = common.addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/site_binding_examples.py", "rust" });
    site_rust_examples_check.dependOn(&site_rust_check.step);

    const site_racket_examples_check = b.step("site-racket-examples-check", "Compile the authoritative Racket transport site examples");
    const site_racket_check = common.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/site_binding_examples.py", "racket" });
    site_racket_examples_check.dependOn(&site_racket_check.step);

    // ── Documentation site (sibling of `check`) ──────────────────────────────
    // The public face under zig-out/site/: the Zine-rendered pages plus the
    // autodoc API reference under reference/api/. The autodoc-only step emits
    // the public `glowcap` module's reference under zig-out/docs/ from the
    // artifact built in the autodoc section above.
    const docs_step = b.step("docs", "Generate the Zig API reference (autodoc) under zig-out/docs/");
    docs_step.dependOn(&install_docs.step);

    // The brand mark on every page is the rooms shader mark, bundled from
    // `site/brand_mark.ts` into a site asset the template links as a module.
    // Bundled here rather than committed: the shader's source is the rooms
    // app's, and a checked-in bundle would be a second copy of it that drifts.
    // The bundle lands in the cache, and `tools/gen/site_brand_mark.zig` writes
    // it into `site/assets` behind the generated-file header, so the tree's
    // checks read it as generated rather than as source. Zine ships the file
    // because the template names it.
    const brand_mark_bundle = common.addRootedSystemCommand(b, .build_tool, &.{
        "deno", "bundle", "--quiet", "--platform", "browser", "--config", "deno.json", "site/brand_mark.ts", "--output",
    });
    const brand_mark_bundled = brand_mark_bundle.addOutputFileArg("mark.js");
    brand_mark_bundle.has_side_effects = true;
    const brand_mark_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen/site_brand_mark.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const brand_mark_exe = b.addExecutable(.{
        .name = "site-brand-mark",
        .root_module = brand_mark_mod,
    });
    const brand_mark_write = execution.addArtifact(b, .build_tool, brand_mark_exe);
    brand_mark_write.setCwd(b.path("."));
    brand_mark_write.addFileArg(brand_mark_bundled);
    brand_mark_write.addArg("site/assets/mark.js");
    brand_mark_write.has_side_effects = true;

    const render_site = execution.addSystemCommand(b, .build_tool, &.{
        b.graph.zig_exe, "build",
    });
    render_site.step.dependOn(&brand_mark_write.step);
    // Forward the cache root Zig selected for the outer build. This preserves a
    // native build's normal local cache and lets a container select a filesystem
    // with the atomic-file semantics Zig requires; a hardcoded checkout path
    // bypasses both decisions.
    render_site.addArg("--cache-dir");
    render_site.addDirectoryArg2(std.Build.LazyPath.cache_root, .{ .make_absolute = true });
    render_site.addArgs(&.{
        "--prefix", common.rootPath(b, "zig-out"),
        "site",
    });
    render_site.setCwd(b.path("site"));
    render_site.has_side_effects = true;

    // The reference section is the generated autodoc for the public `glowcap`
    // module, installed into the rendered site after Zine has written the pages.
    // The inner build clears generated site output before Zine renders; this
    // install then restores the generated reference at reference/api/.
    // Rewrite the rendered pages into the DOM the browser would repair them
    // to (paragraph-wrapped figures, missing figure-image alt, bare table
    // rows), so the served bytes are the document every consumer sees.
    const site_normalize = common.addRootedSystemCommand(b, .build_tool, &.{
        "python3", "tools/gen/site_normalize.py", common.rootPath(b, "zig-out/site"),
    });
    site_normalize.has_side_effects = true;
    site_normalize.step.dependOn(&render_site.step);

    const site_docs_install = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .{ .custom = "site" },
        .install_subdir = "reference/api",
    });
    site_docs_install.step.dependOn(&site_normalize.step);

    // The upstream viewer lacks a document language and an accessible name on
    // its logo link; the fix-up owns those two attributes at the install seam
    // and fails loudly if the viewer's shape changes underneath it.
    const autodoc_access = common.addRootedSystemCommand(b, .build_tool, &.{
        "python3", "tools/gen/autodoc_access.py", common.rootPath(b, "zig-out/site/reference/api/index.html"),
    });
    autodoc_access.has_side_effects = true;
    autodoc_access.step.dependOn(&site_docs_install.step);

    // Validate the artifact after autodoc replaces the reference placeholder.
    // Source checks cannot see Zine's resolved URLs, and checking before this
    // install would miss the generated API's relative assets.
    const site_output_check_mod = b.createModule(.{
        .root_source_file = b.path("tools/check/site_output.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const site_output_check_exe = b.addExecutable(.{
        .name = "site-output-check",
        .root_module = site_output_check_mod,
    });
    const run_site_output_check = execution.addArtifact(b, .{ .deterministic = 30 }, site_output_check_exe);
    run_site_output_check.addArg(common.rootPath(b, "zig-out/site"));
    run_site_output_check.step.dependOn(&autodoc_access.step);
    const site_output_check_tests = b.addTest(.{
        .name = "site-output-check-tests",
        .root_module = site_output_check_mod,
    });
    const run_site_output_check_tests = execution.addZigTest(b, site_output_check_tests, .unit_test);
    check_step.dependOn(&run_site_output_check_tests.step);

    const site_step = b.step("site", "Build and validate the documentation site (Zine + autodoc) under zig-out/site/");
    site_step.dependOn(&run_site_output_check.step);

    // Render the built pages in the pinned headless Chromium at phone width.
    // The source checks and the output checker cannot see layout, and the
    // site's real regressions have been layout: a page a wide code listing
    // stretched past the viewport, a tab strip that widened the whole page,
    // and module doc prose that could not wrap inside the autodoc reference.
    // On-demand like every browser proof.
    const site_render_check = execution.addSystemCommand(b, .{ .browser_proof = 240 }, &.{
        "deno", "run", "--allow-all", "tools/check/site_render.ts", common.rootPath(b, "zig-out/site"),
    });
    site_render_check.setCwd(b.path("."));
    site_render_check.has_side_effects = true;
    site_render_check.step.dependOn(&autodoc_access.step);
    site_render_check.step.dependOn(ctx.browser_preflight);
    const site_render_check_step = b.step("site-render-check", "Render every built site page at phone width in the pinned Chromium (fails on console errors or horizontal overflow)");
    site_render_check_step.dependOn(&site_render_check.step);

    // Press the code-tabs on every built page and prove the example switches.
    // `site-render-check` above proves the pages load and do not overflow but
    // never clicks, so a broken tab `select()` would pass it. On-demand like
    // every browser proof, and a sibling rather than a member of
    // `site-render-check` because its authority is interaction, not layout.
    const site_tabs_check = execution.addSystemCommand(b, .{ .browser_proof = 240 }, &.{
        "deno", "run", "--allow-all", "tools/check/site_tabs.ts", common.rootPath(b, "zig-out/site"),
    });
    site_tabs_check.setCwd(b.path("."));
    site_tabs_check.has_side_effects = true;
    site_tabs_check.step.dependOn(&autodoc_access.step);
    site_tabs_check.step.dependOn(ctx.browser_preflight);
    const site_tabs_check_step = b.step("site-tabs-check", "Press the code-tabs on every built site page in the pinned Chromium and prove each tab opens its own panel");
    site_tabs_check_step.dependOn(&site_tabs_check.step);

    // `docs-serve` is the normal local preview: Zine's development server
    // rebuilds and reloads as the content and templates change. It serves the
    // Zine pages only, the generated autodoc reference is a release-time
    // install, so preview the API reference with `zig build site`.
    //
    // Transport example tabs are assembled from `site/examples/` into the
    // pages; regenerate them before the server starts so a fresh preview is
    // never one gen step behind. `site/docs-serve.sh` then watches the
    // snippets and re-runs the gen while the server is up.
    //
    // The inner `zig build … docs-serve` launches Zine's dev server as a
    // grandchild, and `zig build` does not reap that subtree when an ancestor is
    // stopped, so the server can be left orphaned and bound to its port.
    // `site/docs-serve.sh` is a minimal launcher that runs the inner build in
    // its own process group and tears the whole group down on any stop signal or
    // exit. It is the lifecycle detail of this step, not a new user command; the
    // public `zig build docs-serve` is unchanged.
    const serve_site = execution.addSystemCommand(b, .service, &.{
        "bash",          common.rootPath(b, "site/docs-serve.sh"),
        b.graph.zig_exe, "--cache-dir",
    });
    serve_site.addDirectoryArg2(std.Build.LazyPath.cache_root, .{ .make_absolute = true });
    serve_site.addArgs(&.{
        "--prefix",
        common.rootPath(b, "zig-out"),
        "docs-serve",
    });
    if (ctx.pin_port) |p| serve_site.addArg(b.fmt("-Dport={d}", .{p}));
    serve_site.has_side_effects = true;
    serve_site.step.dependOn(site_examples_write_step);
    serve_site.step.dependOn(&brand_mark_write.step);
    const docs_serve_step = b.step("docs-serve", "Serve the documentation site locally with Zine's development server (regenerates site example tabs; watches site/examples while running)");
    docs_serve_step.dependOn(&serve_site.step);

    return .{
        .zig_examples_check = site_zig_examples_check,
        .python_examples_check = site_python_examples_check,
        .rust_examples_check = site_rust_examples_check,
        .racket_examples_check = site_racket_examples_check,
    };
}
