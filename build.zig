const std = @import("std");
const arch_check = @import("tools/arch_check.zig");
const meta_check = @import("tools/meta_check.zig");

/// C ABI version (keep in lockstep with `PANCAKE_VERSION_*` in `include/pancake.h`
/// and `src/c_abi/mod.zig`, and with `.version` in `build.zig.zon` — the meta
/// gate holds the zon triple to this one). The dynamic library's soname tracks
/// `major`.
const abi_version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

/// The layer DAG — the one authoritative statement of the architecture
/// (ADR-0040; ADR-0048 for the sibling-codec modules below the codec layer).
/// Every build graph is generated from this table, and `tools/arch_check.zig`
/// verifies it against the source tree: a granted edge no file imports fails
/// the gate, so the table carries the edges the code uses, never a wider
/// silent allowance. Rows are in dependency order; the sans-io core graph is
/// the table prefix ending at `actors`, and the final `pancake` row is
/// `src/root.zig`, the curated public namespace over the layers.
const layer_table = [_]arch_check.LayerSpec{
    .{ .name = "foundation", .prefix = "foundation/", .imports = &.{}, .core = true },
    .{ .name = "model", .prefix = "ocapn/model/", .imports = &.{}, .core = true },
    .{ .name = "framing", .prefix = "ocapn/codec/framing.zig", .imports = &.{"model"}, .core = true },
    .{ .name = "syrup", .prefix = "ocapn/codec/syrup/", .imports = &.{ "foundation", "model", "framing" }, .core = true },
    .{ .name = "capnp", .prefix = "ocapn/codec/capnp/", .imports = &.{ "foundation", "model", "framing" }, .core = true },
    .{ .name = "codec", .prefix = "ocapn/codec/", .imports = &.{ "foundation", "model", "framing", "syrup", "capnp" }, .core = true },
    .{ .name = "session", .prefix = "ocapn/session/", .imports = &.{"model"}, .core = true },
    .{ .name = "engine", .prefix = "ocapn/engine/", .imports = &.{ "foundation", "model", "codec", "session" }, .core = true },
    .{ .name = "actors", .prefix = "actors/", .imports = &.{ "model", "engine" }, .core = true },
    .{ .name = "net_adapter", .prefix = "net_adapter/", .imports = &.{ "foundation", "model", "codec", "engine" }, .core = false },
    .{ .name = "conformance", .prefix = "conformance/", .imports = &.{ "foundation", "model", "engine" }, .core = false },
    .{ .name = "driver", .prefix = "driver/", .imports = &.{ "foundation", "model", "engine", "actors", "net_adapter" }, .core = false },
    .{ .name = "c_abi", .prefix = "c_abi/", .imports = &.{ "foundation", "model", "engine", "net_adapter" }, .core = false },
    .{ .name = "pancake", .prefix = "root.zig", .imports = &.{ "foundation", "model", "codec", "session", "engine", "actors", "net_adapter", "driver", "c_abi" }, .core = false },
};

/// Index of `name` in `layer_table`; edges may only point at earlier rows.
fn layerIndex(comptime name: []const u8) usize {
    inline for (layer_table, 0..) |spec, i| {
        if (comptime std.mem.eql(u8, spec.name, name)) return i;
    }
    @compileError("layer_table has no row named '" ++ name ++ "'");
}

/// Materialize one module per table row, in order, resolving each row's edges
/// against the earlier rows. Every module is position-independent so the
/// static `libpancake.a` links cleanly into a PIE consumer (the Rust C ABI
/// dogfood links `static=pancake` into a position-independent test binary;
/// without this, the archive's R_X86_64_32S relocations are rejected at link
/// time). The shared library requires PIC regardless, so both artifacts share
/// one PIC graph.
///
/// When `expose_root` is set, the `pancake` row is registered through
/// `b.addModule`, so a downstream package's
/// `b.dependency("pancake", ...).module("pancake")` resolves to the same graph
/// the artifacts are built from. The cross-target graphs pass false: they are
/// compile-only gates, not the public module.
fn graphFromTable(
    b: *std.Build,
    t: std.Build.ResolvedTarget,
    o: std.builtin.OptimizeMode,
    table: []const arch_check.LayerSpec,
    expose_root: bool,
) []*std.Build.Module {
    const mods = b.allocator.alloc(*std.Build.Module, table.len) catch @panic("OOM");
    for (table, 0..) |spec, i| {
        const root_source = if (std.mem.endsWith(u8, spec.prefix, ".zig"))
            b.fmt("src/{s}", .{spec.prefix})
        else
            b.fmt("src/{s}mod.zig", .{spec.prefix});
        const create_options: std.Build.Module.CreateOptions = .{
            .root_source_file = b.path(root_source),
            .target = t,
            .optimize = o,
            .pic = true,
        };
        mods[i] = if (expose_root and std.mem.eql(u8, spec.name, "pancake"))
            b.addModule("pancake", create_options)
        else
            b.createModule(create_options);
        for (spec.imports) |edge| {
            const j = for (table[0..i], 0..) |prior, k| {
                if (std.mem.eql(u8, prior.name, edge)) break k;
            } else @panic("layer_table edge does not name an earlier row");
            mods[i].addImport(edge, mods[j]);
        }
    }
    return mods;
}

/// One executable over the public `pancake` module — the shape every example,
/// bench, interop driver, and demo client shares: a module rooted at
/// `root_source`, the `pancake` import, and the named executable.
fn pancakeExecutable(
    b: *std.Build,
    lib_mod: *std.Build.Module,
    t: std.Build.ResolvedTarget,
    o: std.builtin.OptimizeMode,
    name: []const u8,
    root_source: []const u8,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path(root_source),
        .target = t,
        .optimize = o,
    });
    mod.addImport("pancake", lib_mod);
    return b.addExecutable(.{ .name = name, .root_module = mod });
}

/// A `pancakeExecutable` run from the repository root with side effects — the
/// shape the live interop drivers and worked applications share.
fn addPancakeRun(
    b: *std.Build,
    lib_mod: *std.Build.Module,
    t: std.Build.ResolvedTarget,
    o: std.builtin.OptimizeMode,
    name: []const u8,
    root_source: []const u8,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(pancakeExecutable(b, lib_mod, t, o, name, root_source));
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    return run;
}

/// A sibling-step system command that needs the installed artifacts
/// (`libpancake` + `pancake.h`) and runs from the repository root with side
/// effects — the shape every cross-language interop and demo orchestrator
/// shares.
fn addInstalledSystemRun(b: *std.Build, argv: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(argv);
    run.step.dependOn(b.getInstallStep());
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    return run;
}

/// The full `src/root.zig` module graph for an arbitrary target — used by the
/// cross-compile gate to type-check the platform backends (notably the
/// macOS/BSD `kqueue` path, which the host io_uring build never compiles)
/// without running, so a regression there fails `zig build check` instead of
/// waiting for a Mac.
fn crossLibModule(b: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode) *std.Build.Module {
    const mods = graphFromTable(b, t, o, &layer_table, false);
    return mods[layerIndex("pancake")];
}

/// The *sans-io core* module graph (no `net_adapter` / I/O) for an arbitrary
/// target, returning the `actors` module at its top — used to type-check the
/// core for `wasm32-freestanding`, gating the 32-bit overflow guards the codec
/// carries without pulling in the I/O layers that wasm lacks.
fn crossCoreModule(b: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode) *std.Build.Module {
    const mods = graphFromTable(b, t, o, layer_table[0 .. layerIndex("actors") + 1], false);
    return mods[layerIndex("actors")];
}

/// A module over the iroh public C ABI (`src/c_abi/iroh.zig`). Minted fresh per
/// call so the sidecar-linked artifact, the hermetic check object, and the
/// header generator can each have their own (no source file lands in two
/// modules of one compilation). `resident` is the iroh netlayer resident
/// module; `host_mods` supplies the shared `model` / `net_adapter` / `c_abi`
/// layer instances.
fn irohAbiModule(
    b: *std.Build,
    t: std.Build.ResolvedTarget,
    o: std.builtin.OptimizeMode,
    host_mods: []*std.Build.Module,
    resident: *std.Build.Module,
) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("src/c_abi/iroh.zig"),
        .target = t,
        .optimize = o,
        .pic = true,
    });
    m.addImport("model", host_mods[layerIndex("model")]);
    m.addImport("net_adapter", host_mods[layerIndex("net_adapter")]);
    m.addImport("iroh", resident);
    m.addImport("c_abi", host_mods[layerIndex("c_abi")]);
    return m;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Port pinning for demo and interop steps ──────────────────────────────
    // Every demo orchestrator binds an ephemeral port by default, and every
    // live interop step pins its own fixed port so concurrent steps cannot
    // collide. `-Dport` overrides either choice for one run — to put a demo
    // server on a forwarded port, or to move an interop step off a port that
    // is taken on this machine. `-Dattach` (demo steps only, requires
    // `-Dport`) joins an already-running server on that port instead of
    // spawning one; each orchestrator validates the combination and fails
    // loud, so an unsupported pairing is an error, never a silent ignore.
    const pin_port = b.option(u16, "port", "Pin the listening TCP port for demo and interop steps (default: ephemeral for demos, each step's documented fixed port for interop)");
    const attach = b.option(bool, "attach", "With -Dport: demo orchestrators join an already-running server on that port instead of spawning one") orelse false;
    if (attach and pin_port == null) {
        std.debug.panic("-Dattach requires -Dport: there is no server to join without a port", .{});
    }

    // ── Internal layer modules (ADR-0040, ADR-0048) ─────────────────────────
    // The DAG lives in `layer_table` above; materializing it makes every edge a
    // compiler-checked law — a layer cannot even name a file outside its module
    // root, and a new edge is a visible one-line table diff, not a review note.
    // arch-check consumes the same table, so a granted edge no file imports
    // fails the gate, and only the content bans a module graph cannot express
    // (no `std.Io` / `std.Thread` in core, no platform syscall namespaces in
    // portable code) live as prose checks.
    const host_mods = graphFromTable(b, target, optimize, &layer_table, true);
    const lib_mod = host_mods[layerIndex("pancake")];
    const static_lib = b.addLibrary(.{
        .name = "pancake",
        .linkage = .static,
        .root_module = lib_mod,
    });
    b.installArtifact(static_lib);

    const shared_lib = b.addLibrary(.{
        .name = "pancake",
        .linkage = .dynamic,
        .root_module = lib_mod,
        // Stamps the soname (`libpancake.so.0`) so a distro can express the ABI
        // contract; `pancake_abi_version` reports the same triple at runtime.
        .version = abi_version,
    });
    b.installArtifact(shared_lib);

    const install_header = b.addInstallHeaderFile(b.path("include/pancake.h"), "pancake.h");
    b.getInstallStep().dependOn(&install_header.step);

    // ── API reference (autodoc) ──────────────────────────────────────────────
    // Renders the public `pancake` module's generated documentation under
    // zig-out/docs/. The site step ships this same artifact as the API
    // reference section, so the reference can never be hand-written prose.
    const install_docs = b.addInstallDirectory(.{
        .source_dir = static_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate the Zig API reference (autodoc) under zig-out/docs/");
    docs_step.dependOn(&install_docs.step);

    // ── The gate ─────────────────────────────────────────────────────────────
    // Steps below are declared in newcomer priority order — `zig build -l`
    // lists them in declaration order. `check` leads; its focused components
    // follow; the non-hermetic sibling steps come last, grouped by concern.
    //
    // The core correctness gate is hermetic to the Zig toolchain: arch gate,
    // meta gate, tests, oracle checks, the header staleness check, the Zig + C
    // examples, the cross-compile gate, the accountability application
    // (loopback TCP) with its three-party attribution test, and the benchmark
    // checks (peer-scaling in smoke mode). The cross-language C ABI dogfood
    // (`zig build rust-dogfood`, and the wider `zig build bindings`) needs
    // cargo/deno/python/racket on PATH, so it is a sibling step run alongside
    // `check`, not a dependency of it — a contributor with only a Zig
    // toolchain can run the gate. CI runs `check` and the sibling gates inside
    // the committed devcontainer image via ci/gates.sh; .forgejo/workflows/
    // (Codeberg, the origin) and .github/workflows/ (the mirror) are thin
    // wrappers around that script. Each section below wires its gated runs
    // into `check` where the artifacts are built.
    const check_step = b.step("check", "Run the Zig-hermetic correctness and meta-scaffolding gate");

    // ── Tests ────────────────────────────────────────────────────────────────
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("test/all_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addImport("pancake", lib_mod);
    // `c_abi` and `conformance` are not on the public `pancake` namespace (a
    // Zig consumer has no use for either), so their test suites import the
    // layer modules directly.
    tests_mod.addImport("c_abi", host_mods[layerIndex("c_abi")]);
    tests_mod.addImport("conformance", host_mods[layerIndex("conformance")]);
    // The header-parity test `@cImport`s `pancake.h` to prove the hand-written C
    // header agrees with the Zig `c_abi` source (sizes, offsets, constants), so
    // the two can never silently drift.
    tests_mod.addIncludePath(b.path("include"));
    tests_mod.link_libc = true;
    // `zig build test -Dtest-filter=<substring>` narrows the run to matching
    // test names while iterating; the bare step still runs everything.
    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose names contain this substring");
    const tests = b.addTest(.{
        .root_module = tests_mod,
        .filters = if (test_filter) |f| b.dupeStrings(&.{f}) else &.{},
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the unit and scenario test suite (test/all_test.zig)");
    test_step.dependOn(&run_tests.step);
    check_step.dependOn(&run_tests.step);

    const oracle_tests_mod = b.createModule(.{
        .root_source_file = b.path("test/oracle_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    oracle_tests_mod.addImport("pancake", lib_mod);
    const oracle_tests = b.addTest(.{
        .root_module = oracle_tests_mod,
    });
    const run_oracle_tests = b.addRunArtifact(oracle_tests);
    const oracle_check_step = b.step("oracle-check", "Run protocol and Goblins fixture oracle checks");
    oracle_check_step.dependOn(&run_oracle_tests.step);
    check_step.dependOn(&run_oracle_tests.step);

    // ── Structure gates ──────────────────────────────────────────────────────
    const arch_check_step_inner = arch_check.create(b, &layer_table);
    const arch_check_step = b.step("arch-check", "Enforce the layer dependency DAG over src/");
    arch_check_step.dependOn(arch_check_step_inner);
    check_step.dependOn(arch_check_step);

    const meta_check_step_inner = meta_check.create(b);

    // Unit tests for the meta gate's own parsers (link/command/Mermaid logic)
    // live in `tools/meta_check.zig`. The file is a build-time import, so its
    // `test` blocks only run when compiled as a dedicated test artifact.
    const meta_check_tests_mod = b.createModule(.{
        .root_source_file = b.path("tools/meta_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    const meta_check_tests = b.addTest(.{ .root_module = meta_check_tests_mod });
    const run_meta_check_tests = b.addRunArtifact(meta_check_tests);

    const meta_check_step = b.step("meta-check", "Enforce agent scaffolding and documented build-step parity");
    meta_check_step.dependOn(meta_check_step_inner);
    meta_check_step.dependOn(&run_meta_check_tests.step);
    check_step.dependOn(meta_check_step);

    // Cross-compile gate: type-check the whole library for macOS (and a 64-bit
    // BSD) so the kqueue completion backend — which the host io_uring build never
    // compiles — cannot regress unnoticed. Compile-only: depending on the object's
    // step builds it without running a foreign binary. `aarch64-macos` exercises
    // kqueue; `x86_64-linux` is the host and would be redundant, so the second
    // target is a different ABI to widen coverage cheaply.
    const cross_macos = b.addObject(.{
        .name = "pancake-cross-macos",
        .root_module = crossLibModule(b, b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos }), .Debug),
    });
    // wasm32-freestanding type-checks the sans-io core (no I/O layers wasm
    // lacks), gating the 32-bit overflow guards the codec carries.
    const cross_wasm = b.addObject(.{
        .name = "pancake-cross-wasm-core",
        .root_module = crossCoreModule(b, b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }), .Debug),
    });
    const cross_check_step = b.step("cross-check", "Type-check non-host targets — macOS/kqueue (full) and wasm32 (sans-io core), compile-only");
    cross_check_step.dependOn(&cross_macos.step);
    cross_check_step.dependOn(&cross_wasm.step);
    check_step.dependOn(cross_check_step);

    // ── Generated header ─────────────────────────────────────────────────────
    // `include/pancake.h` is generated from `src/c_abi/mod.zig` (reflected
    // layouts, constant values, and function signatures): the Zig source is the
    // single source of truth. `zig build gen-header-check` is the gate — it
    // fails when the committed header is stale and rides `check`. `zig build
    // gen-header` is the fixer that rewrites the header in place.
    const gen_check_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_header_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_check_mod.addImport("c_abi", host_mods[layerIndex("c_abi")]);
    const gen_check_exe = b.addExecutable(.{ .name = "gen-header-check", .root_module = gen_check_mod });
    const header_check = b.addRunArtifact(gen_check_exe);
    header_check.setCwd(b.path("."));
    const gen_header_check_step = b.step("gen-header-check", "Verify include/pancake.h matches src/c_abi (fails if stale)");
    gen_header_check_step.dependOn(&header_check.step);
    check_step.dependOn(gen_header_check_step);

    const gen_write_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_header_write.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_write_mod.addImport("c_abi", host_mods[layerIndex("c_abi")]);
    const gen_write_exe = b.addExecutable(.{ .name = "gen-header-write", .root_module = gen_write_mod });
    const gen_header_write = b.addRunArtifact(gen_write_exe);
    gen_header_write.setCwd(b.path("."));
    gen_header_write.has_side_effects = true;
    const gen_header_step = b.step("gen-header", "Regenerate include/pancake.h from src/c_abi");
    gen_header_step.dependOn(&gen_header_write.step);

    // ── Examples ─────────────────────────────────────────────────────────────
    const examples_step = b.step("examples", "Build and run examples");
    check_step.dependOn(examples_step);

    // Zig example programs, run in array order. The numbered chapters are
    // runnable CapTP walkthroughs whose narrative lives in their `//!` headers,
    // so the prose and the API calls can't drift (each is built and run under
    // `check`); they read top-down, from the application surface to the raw
    // engine. `readme_quick_start` keeps the README's Quick Start snippet
    // compiling, and `frame_view` / `connect_explicit_buffers` are the
    // lower-level library-mechanics walkthroughs.
    const zig_examples = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "pancake-ex-01-connect-and-serve", .path = "examples/zig/01_connect_and_serve.zig" },
        .{ .name = "pancake-ex-02-actor-far-send", .path = "examples/zig/02_actor_far_send.zig" },
        .{ .name = "pancake-ex-03-look-up-by-name", .path = "examples/zig/03_look_up_by_name.zig" },
        .{ .name = "pancake-ex-04-call-a-remote-method", .path = "examples/zig/04_call_a_remote_method.zig" },
        .{ .name = "pancake-readme-quick-start", .path = "examples/zig/readme_quick_start.zig" },
        .{ .name = "pancake-zig-frame-view", .path = "examples/zig/frame_view.zig" },
        .{ .name = "pancake-zig-connect-explicit-buffers", .path = "examples/zig/connect_explicit_buffers.zig" },
    };
    for (zig_examples) |ex| {
        const run = b.addRunArtifact(pancakeExecutable(b, lib_mod, target, optimize, ex.name, ex.path));
        examples_step.dependOn(&run.step);
    }

    // C example programs over `pancake.h` + the static library, same table
    // shape as the Zig examples.
    const c_examples = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "pancake-c-frame-view", .path = "examples/c/frame_view.c" },
        .{ .name = "pancake-c-context-alloc", .path = "examples/c/context_alloc.c" },
        .{ .name = "pancake-c-echo-peer", .path = "examples/c/echo_peer.c" },
    };
    for (c_examples) |ex| {
        const c_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
        });
        c_mod.addCSourceFile(.{ .file = b.path(ex.path) });
        c_mod.addIncludePath(b.path("include"));
        c_mod.linkLibrary(static_lib);
        c_mod.link_libc = true;
        const c_exe = b.addExecutable(.{ .name = ex.name, .root_module = c_mod });
        examples_step.dependOn(&b.addRunArtifact(c_exe).step);
    }

    // ── Benchmarks ───────────────────────────────────────────────────────────
    // The benchmark trio, table-driven like the examples: one executable over
    // `pancake`, one run that forwards `zig build <step> -- <args>`, one step.
    const benches = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "frame-view-bench", .path = "bench/frame_view_bench.zig" },
        .{ .name = "codec-bench", .path = "bench/codec_bench.zig" },
        .{ .name = "peer-scaling-bench", .path = "bench/peer_scaling_bench.zig" },
    };
    var bench_exes: [benches.len]*std.Build.Step.Compile = undefined;
    var bench_runs: [benches.len]*std.Build.Step.Run = undefined;
    for (benches, 0..) |bench, i| {
        bench_exes[i] = pancakeExecutable(b, lib_mod, target, optimize, bench.name, bench.path);
        bench_runs[i] = b.addRunArtifact(bench_exes[i]);
        if (b.args) |args| {
            bench_runs[i].addArgs(args);
        }
    }
    b.step("bench-frame-view", "Run frame/view benchmark").dependOn(&bench_runs[0].step);
    b.step("bench-codec", "Run codec/dispatch throughput benchmark").dependOn(&bench_runs[1].step);
    b.step("bench-peer-scaling", "Measure per-connection memory footprint and extrapolate to 500k").dependOn(&bench_runs[2].step);

    // The gate runs are dedicated Run artifacts that never see `b.args`, so
    // `zig build check -- <args>` cannot leak user arguments into the gate.
    // The footprint budget itself is gated by
    // test/engine/footprint_budget_test.zig; `check` runs the peer-scaling
    // bench only in `--smoke` mode: prove it still runs, cheaply, without
    // writing report artifacts into zig-out as a side effect of the gate.
    const gate_frame_view_bench = b.addRunArtifact(bench_exes[0]);
    const gate_codec_bench = b.addRunArtifact(bench_exes[1]);
    const smoke_peer_scaling_bench = b.addRunArtifact(bench_exes[2]);
    smoke_peer_scaling_bench.addArg("--smoke");
    check_step.dependOn(&gate_frame_view_bench.step);
    check_step.dependOn(&gate_codec_bench.step);
    check_step.dependOn(&smoke_peer_scaling_bench.step);

    // ── C ABI dogfoods (siblings of `check`) ─────────────────────────────────
    // Per-language dogfood of the Zig libpancake C ABI. Each consumer loads the
    // installed library and drives an OCapN round-trip through its idiomatic
    // API over the whole C ABI — allocation context, owned-frame feed, and
    // typed events included (see bindings/README.md). The Rust consumer also
    // exercises the opt-in tokio async layer alongside the sync surface. Each
    // needs its runtime on PATH (cargo / deno / python3 / racket), provided by
    // this repo's devcontainer.
    const dogfoods = [_]struct {
        step_name: []const u8,
        description: []const u8,
        argv: []const []const u8,
    }{
        .{
            .step_name = "rust-dogfood",
            .description = "Run Rust C ABI dogfood tests against libpancake (needs cargo)",
            .argv = &.{ "cargo", "test", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async" },
        },
        .{
            .step_name = "deno-dogfood",
            .description = "Run the Deno C ABI dogfood against libpancake (needs deno)",
            .argv = &.{ "deno", "run", "--allow-ffi", "--allow-read", "--allow-net", "bindings/deno/zig_smoke.ts" },
        },
        .{
            .step_name = "python-dogfood",
            .description = "Run the Python C ABI dogfood against libpancake (needs python3)",
            .argv = &.{ "python3", "bindings/python/zig_smoke.py" },
        },
        .{
            .step_name = "racket-dogfood",
            .description = "Run the Racket C ABI dogfood against libpancake (needs racket)",
            .argv = &.{ "racket", "bindings/racket/zig-smoke.rkt" },
        },
    };
    var dogfood_runs: [dogfoods.len]*std.Build.Step.Run = undefined;
    for (dogfoods, 0..) |dogfood, i| {
        dogfood_runs[i] = b.addSystemCommand(dogfood.argv);
        dogfood_runs[i].step.dependOn(b.getInstallStep());
        b.step(dogfood.step_name, dogfood.description).dependOn(&dogfood_runs[i].step);
    }
    const bindings_step = b.step("bindings", "Run per-language dogfood of the C ABI (rust, deno, python, racket)");
    for (dogfood_runs) |run| bindings_step.dependOn(&run.step);

    // ── Live Goblins interop (siblings of `check`) ───────────────────────────
    // Live interop proof against a real Spritely Goblins vat: a pancake peer
    // dials the conformance Goblins host, completes the keyed op:start-session
    // handshake, and bootstrap-fetches its echo cap. Needs `racket` + the
    // `goblins` collection on PATH (like the binding dogfoods), so it is a
    // sibling of `check`, not part of the hermetic gate. The driver spawns and
    // tears down the Goblins vat itself.
    const run_goblins_interop = addPancakeRun(b, lib_mod, target, optimize, "pancake-goblins-interop", "conformance/goblins_interop/driver.zig");
    if (pin_port) |p| run_goblins_interop.addArg(b.fmt("--port={d}", .{p}));
    const goblins_interop_step = b.step("goblins-interop", "Live OCapN conversation vs a real Goblins vat, both directions (needs racket + goblins)");
    goblins_interop_step.dependOn(&run_goblins_interop.step);

    // Live three-party handoff, pancake as recipient (needs racket + goblins).
    // It runs two Goblins listeners (alice, bob), so `-Dport=N` pins N and N+1.
    const run_goblins_handoff = addPancakeRun(b, lib_mod, target, optimize, "pancake-goblins-handoff", "conformance/goblins_interop/handoff_driver.zig");
    if (pin_port) |p| run_goblins_handoff.addArg(b.fmt("--port={d}", .{p}));
    const goblins_handoff_step = b.step("goblins-handoff", "Live three-party handoff vs Goblins, pancake as recipient (needs racket + goblins)");
    goblins_handoff_step.dependOn(&run_goblins_handoff.step);

    // Each binding drives the same keyed conversation against a real Goblins
    // vat through the installed `libpancake` — the binding↔live-Goblins keyed
    // conversation, not just the in-Zig one. Every entry needs `racket` + the
    // `goblins` collection on PATH plus its own runtime; each script spawns and
    // tears down the Goblins vat itself. The Rust entry runs a feature-gated
    // tokio example, so it needs the async feature.
    const goblins_clients = [_]struct {
        step_name: []const u8,
        description: []const u8,
        argv: []const []const u8,
        /// True when the runner needs a `--` separator before program args
        /// (cargo run forwards trailing args to the example only after one).
        dashdash_before_args: bool = false,
    }{
        .{
            .step_name = "deno-goblins-interop",
            .description = "Live keyed OCapN conversation: Deno binding vs a real Goblins vat (needs deno + racket + goblins)",
            .argv = &.{ "deno", "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "conformance/goblins_interop/deno_client.ts" },
        },
        .{
            .step_name = "python-goblins-interop",
            .description = "Live keyed OCapN conversation: Python binding vs a real Goblins vat (needs python3 + racket + goblins)",
            .argv = &.{ "python3", "conformance/goblins_interop/python_client.py" },
        },
        .{
            .step_name = "racket-goblins-interop",
            .description = "Live keyed OCapN conversation: Racket binding vs a real Goblins vat (needs racket + goblins)",
            .argv = &.{ "racket", "conformance/goblins_interop/racket_client.rkt" },
        },
        .{
            .step_name = "rust-goblins-interop",
            .description = "Live keyed OCapN conversation: Rust binding vs a real Goblins vat (needs cargo + racket + goblins)",
            .argv = &.{ "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async", "--example", "goblins_interop" },
            .dashdash_before_args = true,
        },
    };
    for (goblins_clients) |client| {
        const run = addInstalledSystemRun(b, client.argv);
        if (pin_port) |p| {
            if (client.dashdash_before_args) run.addArg("--");
            run.addArg(b.fmt("--port={d}", .{p}));
        }
        b.step(client.step_name, client.description).dependOn(&run.step);
    }

    // Cross-implementation benchmark: one shared Racket application run on
    // pancake's Racket binding and on Spritely Goblins, comparing latency,
    // throughput, connection setup, and server memory. It needs `racket` + the
    // `goblins` collection on PATH, so it is a sibling of `check`, not part of
    // the hermetic gate. The orchestrator spawns and tears down both servers
    // itself. Forward `-- <args>` (e.g. `--smoke`, `--suite=echo`) to the
    // orchestrator; `-Dport=N` pins the base port.
    const run_bench_goblins = addInstalledSystemRun(b, &.{ "racket", "bench/goblins/bench.rkt" });
    if (pin_port) |p| run_bench_goblins.addArg(b.fmt("--port={d}", .{p}));
    if (b.args) |args| run_bench_goblins.addArgs(args);
    b.step("bench-goblins", "Cross-implementation benchmark: pancake's Racket binding vs Spritely Goblins (needs racket + goblins)")
        .dependOn(&run_bench_goblins.step);

    // ── iroh netlayer (siblings of `check`, plus one hermetic object) ────────
    // The iroh netlayer sidecar (ADR-0055): cargo builds the
    // `libpancake_iroh_sidecar.a` staticlib, and the live gate runs two pancake
    // peers — each with its own
    // real iroh endpoint — through the keyed handshake, a bootstrap fetch, and
    // a deliver/resolve over an encrypted QUIC stream, dialed by endpoint id
    // with direct-address hints. Needs cargo on PATH, so both are sibling
    // steps of `check`, the same posture as `rust-dogfood`.
    const iroh_lib = b.addSystemCommand(&.{
        "cargo", "build", "--release", "--manifest-path", "transports/iroh/Cargo.toml",
    });
    const iroh_lib_step = b.step("iroh-lib", "Build the iroh netlayer sidecar staticlib (needs cargo)");
    iroh_lib_step.dependOn(&iroh_lib.step);

    // The resident compiles as its own module over the same layer-module
    // instances, *outside* the `pancake` root namespace: its externs resolve
    // only when the staticlib links, and the api-surface test references every
    // exported `pancake` declaration recursively — exporting it would drag the
    // Rust sidecar into every gate.
    const iroh_resident_mod = b.createModule(.{
        .root_source_file = b.path("src/net_adapter/iroh.zig"),
        .target = target,
        .optimize = optimize,
    });
    iroh_resident_mod.addImport("model", host_mods[layerIndex("model")]);
    iroh_resident_mod.addImport("engine", host_mods[layerIndex("engine")]);
    iroh_resident_mod.addImport("net_adapter", host_mods[layerIndex("net_adapter")]);

    const iroh_interop_mod = b.createModule(.{
        .root_source_file = b.path("conformance/iroh_interop/driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    iroh_interop_mod.addImport("pancake", lib_mod);
    iroh_interop_mod.addImport("iroh", iroh_resident_mod);
    iroh_interop_mod.addObjectFile(b.path("transports/iroh/target/release/libpancake_iroh_sidecar.a"));
    iroh_interop_mod.link_libc = true;
    iroh_interop_mod.linkSystemLibrary("unwind", .{});
    const iroh_interop_exe = b.addExecutable(.{
        .name = "pancake-iroh-interop",
        .root_module = iroh_interop_mod,
    });
    iroh_interop_exe.step.dependOn(&iroh_lib.step);
    const run_iroh_interop = b.addRunArtifact(iroh_interop_exe);
    run_iroh_interop.setCwd(b.path("."));
    run_iroh_interop.has_side_effects = true;
    const iroh_interop_step = b.step("iroh-interop", "Live encrypted OCapN conversation: two pancake peers over real iroh endpoints (needs cargo)");
    iroh_interop_step.dependOn(&run_iroh_interop.step);

    // Hermetic type-check of the resident: compile it to an object, where its
    // externs need no definition, so plain `zig build check` catches resident
    // rot without cargo on PATH. Linking and running stay in `iroh-interop`.
    const iroh_resident_check = b.addObject(.{
        .name = "iroh-resident-check",
        .root_module = iroh_resident_mod,
    });
    check_step.dependOn(&iroh_resident_check.step);

    // ── iroh public C ABI (separate artifact; ADR-0055) ──────────────────────
    // `src/c_abi/iroh.zig` is the iroh transport's public C ABI. It ships as its
    // own library, `libpancake_iroh`, because it links the Rust sidecar and so
    // cannot fold into pure-Zig `libpancake`. The artifact is a superset — it
    // force-references the base `c_abi` root — so a binding loads one library
    // for the whole peer-driving surface plus this transport. Building and
    // running it needs cargo, so it is a sibling of `check`, the same posture as
    // `iroh-interop`.
    const iroh_abi_link_mod = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod);
    iroh_abi_link_mod.addObjectFile(b.path("transports/iroh/target/release/libpancake_iroh_sidecar.a"));
    iroh_abi_link_mod.link_libc = true;
    iroh_abi_link_mod.linkSystemLibrary("unwind", .{});
    const iroh_abi_shared = b.addLibrary(.{
        .name = "pancake_iroh",
        .linkage = .dynamic,
        .root_module = iroh_abi_link_mod,
        .version = abi_version,
    });
    iroh_abi_shared.step.dependOn(&iroh_lib.step);
    const iroh_abi_install = b.addInstallArtifact(iroh_abi_shared, .{});
    const iroh_abi_header_install = b.addInstallHeaderFile(b.path("include/pancake_iroh.h"), "pancake_iroh.h");
    const iroh_abi_step = b.step("iroh-abi", "Build libpancake_iroh — the iroh transport's public C ABI superset (needs cargo)");
    iroh_abi_step.dependOn(&iroh_abi_install.step);
    iroh_abi_step.dependOn(&iroh_abi_header_install.step);

    // Hermetic type-check of the public iroh C ABI: an object, so its externs
    // need no definition — `zig build check` catches rot in this module (and the
    // resident surface it drives) without cargo. Linking stays in `iroh-abi`.
    const iroh_abi_check_mod = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod);
    const iroh_abi_check = b.addObject(.{
        .name = "iroh-abi-check",
        .root_module = iroh_abi_check_mod,
    });
    check_step.dependOn(&iroh_abi_check.step);

    // `include/pancake_iroh.h` is generated from `src/c_abi/iroh.zig`
    // (reflected signatures): the Zig source is the single source of truth, as
    // for pancake.h. Both gen steps reflect types only and link the sidecar
    // stubs, so they run cargo-free; `gen-header-iroh-check` rides `check`.
    const iroh_abi_for_gen = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod);
    const iroh_gen_check_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_header_iroh_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    iroh_gen_check_mod.addImport("c_abi_iroh", iroh_abi_for_gen);
    const iroh_gen_check_exe = b.addExecutable(.{ .name = "gen-header-iroh-check", .root_module = iroh_gen_check_mod });
    const iroh_header_check = b.addRunArtifact(iroh_gen_check_exe);
    iroh_header_check.setCwd(b.path("."));
    const gen_header_iroh_check_step = b.step("gen-header-iroh-check", "Verify include/pancake_iroh.h matches src/c_abi/iroh.zig (fails if stale)");
    gen_header_iroh_check_step.dependOn(&iroh_header_check.step);
    check_step.dependOn(gen_header_iroh_check_step);

    const iroh_abi_for_gen_write = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod);
    const iroh_gen_write_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_header_iroh_write.zig"),
        .target = target,
        .optimize = optimize,
    });
    iroh_gen_write_mod.addImport("c_abi_iroh", iroh_abi_for_gen_write);
    const iroh_gen_write_exe = b.addExecutable(.{ .name = "gen-header-iroh-write", .root_module = iroh_gen_write_mod });
    const iroh_gen_write_run = b.addRunArtifact(iroh_gen_write_exe);
    iroh_gen_write_run.setCwd(b.path("."));
    iroh_gen_write_run.has_side_effects = true;
    const gen_header_iroh_step = b.step("gen-header-iroh", "Regenerate include/pancake_iroh.h from src/c_abi/iroh.zig");
    gen_header_iroh_step.dependOn(&iroh_gen_write_run.step);

    // ── External conformance pressure (siblings of `check`) ──────────────────
    // A pancake peer the upstream OCapN test suite can dial: it serves the
    // canonical conformance swiss-nums over `tcp-testing-only`. The orchestrator
    // `run-against-pancake.sh` starts it and runs the suite against it — pointing
    // the external authority back at pancake. Not part of `check`; needs uv +
    // the suite submodule. The peer installs only for this step, not on every
    // default build.
    const ocapn_peer_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-ocapn-peer", "conformance/ocapn-conformance/pancake_peer.zig");
    const ocapn_peer_install = b.addInstallArtifact(ocapn_peer_exe, .{});
    const ocapn_conformance = addInstalledSystemRun(b, &.{ "bash", "conformance/ocapn-conformance/run-against-pancake.sh" });
    if (pin_port) |p| ocapn_conformance.addArg(b.fmt("--port={d}", .{p}));
    ocapn_conformance.step.dependOn(&ocapn_peer_install.step);
    const ocapn_conformance_step = b.step("ocapn-conformance", "Run the upstream OCapN test suite against a pancake peer (needs uv + the ocapn-conformance submodule)");
    ocapn_conformance_step.dependOn(&ocapn_conformance.step);

    // Regenerate the Syrup fixture corpus through the upstream Racket Syrup
    // encoder and byte-compare it against the committed corpus, so
    // generator/corpus drift fails loud instead of rotting silently. A sibling
    // step (needs racket + the syrup collection), not part of the hermetic
    // check; a deliberate corpus change regenerates with
    // `racket test/oracles/goblins/generate.rkt test/oracles/goblins/expected`.
    const fixture_gen = b.addSystemCommand(&.{"racket"});
    fixture_gen.addFileArg(b.path("test/oracles/goblins/generate.rkt"));
    const fixture_gen_out = fixture_gen.addOutputDirectoryArg("generated-fixtures");
    const fixture_diff = b.addSystemCommand(&.{ "diff", "-r" });
    fixture_diff.addDirectoryArg(b.path("test/oracles/goblins/expected"));
    fixture_diff.addDirectoryArg(fixture_gen_out);
    const fixture_gen_check_step = b.step("fixture-gen-check", "Regenerate Syrup fixtures via the upstream Racket Syrup encoder and diff against the committed corpus (needs racket + syrup)");
    fixture_gen_check_step.dependOn(&fixture_diff.step);

    // ── Cross-language application demos (siblings of `check`) ───────────────
    // The rooms cross-language application demo: one Zig-built native client plus
    // the Deno server and the Deno/Python/Racket/Rust clients, all joining one
    // capability-secure chat room over TCP. It needs `deno` (which hosts the room
    // and runs the orchestrator) and the Zig client, always built here. Python,
    // Racket, and Rust each join only when their runtime is on PATH; the demo
    // builds the Rust client itself when `cargo` is present and reports any
    // language it skipped rather than failing. So it is a sibling step, not part of
    // the hermetic gate. The Deno server regression test covers attached-room
    // cleanup, then the orchestrator (`examples/apps/rooms/demo.ts`) starts the
    // server, runs whichever clients are available, and asserts the all-to-all
    // broadcast among them.
    const rooms_client_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-rooms-client", "examples/apps/rooms/zig/client.zig");
    // The default rooms client is TCP-only: a build option flips the iroh dial
    // path off so the `@import("iroh")` inside it is comptime-elided and the
    // hermetic build never pulls the Rust sidecar into its graph.
    const rooms_tcp_opts = b.addOptions();
    rooms_tcp_opts.addOption(bool, "iroh_enabled", false);
    rooms_client_exe.root_module.addOptions("rooms_client_build_options", rooms_tcp_opts);

    // --unstable-ffi lets the iroh server tests in server_test.ts dial the
    // sidecar's nonblocking FFI; they skip when the iroh ABI lib is absent, so
    // the flag is harmless for the TCP suite and a cargo-free run stays green.
    const rooms_server_test = addInstalledSystemRun(b, &.{
        "deno",                                    "test",                                      "--allow-ffi",                          "--unstable-ffi", "--allow-read", "--allow-net", "--allow-run",
        "examples/apps/rooms/deno/server_test.ts", "examples/apps/rooms/deno/presence_test.ts", "examples/apps/rooms/deno/web_test.ts",
    });

    const rooms_demo = addInstalledSystemRun(b, &.{
        "deno",                        "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run",
        "examples/apps/rooms/demo.ts",
    });
    rooms_demo.addArtifactArg(rooms_client_exe); // the Zig client's built path
    if (pin_port) |p| rooms_demo.addArg(b.fmt("--port={d}", .{p}));
    if (attach) rooms_demo.addArg("--attach");
    rooms_demo.step.dependOn(&rooms_server_test.step);
    const rooms_demo_step = b.step("demo-rooms", "Run the cross-language rooms chat demo (needs deno; joins python3/racket/cargo clients when present)");
    rooms_demo_step.dependOn(&rooms_demo.step);

    // The same rooms demo over iroh's encrypted QUIC. The Zig client is built as
    // a second, iroh-enabled artifact that links the Rust sidecar (so it can dial
    // an ocapn:// URI), and the cross-language clients reach the room through the
    // iroh C ABI superset library. Needs cargo (sidecar + iroh ABI) and deno, so
    // it is a sibling of `check`, like `iroh-interop`.
    const rooms_client_iroh_mod = b.createModule(.{
        .root_source_file = b.path("examples/apps/rooms/zig/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    rooms_client_iroh_mod.addImport("pancake", lib_mod);
    rooms_client_iroh_mod.addImport("iroh", iroh_resident_mod);
    const rooms_iroh_opts = b.addOptions();
    rooms_iroh_opts.addOption(bool, "iroh_enabled", true);
    rooms_client_iroh_mod.addOptions("rooms_client_build_options", rooms_iroh_opts);
    rooms_client_iroh_mod.addObjectFile(b.path("transports/iroh/target/release/libpancake_iroh_sidecar.a"));
    rooms_client_iroh_mod.link_libc = true;
    rooms_client_iroh_mod.linkSystemLibrary("unwind", .{});
    const rooms_client_iroh_exe = b.addExecutable(.{ .name = "pancake-rooms-client-iroh", .root_module = rooms_client_iroh_mod });
    rooms_client_iroh_exe.step.dependOn(&iroh_lib.step);

    const rooms_demo_iroh = addInstalledSystemRun(b, &.{
        "deno",                        "run", "-A", "--unstable-ffi",
        "examples/apps/rooms/demo.ts",
    });
    rooms_demo_iroh.addArtifactArg(rooms_client_iroh_exe); // the iroh-enabled Zig client
    rooms_demo_iroh.addArg("--transport=iroh");
    if (pin_port) |p| rooms_demo_iroh.addArg(b.fmt("--port={d}", .{p}));
    // The cross-language clients and the Deno server dial iroh through the iroh
    // C ABI superset library, so it must be built and installed first.
    rooms_demo_iroh.step.dependOn(iroh_abi_step);
    const rooms_demo_iroh_step = b.step("demo-rooms-iroh", "Run the cross-language rooms demo over iroh's encrypted QUIC (needs cargo + deno; joins python3/racket/cargo clients when present)");
    rooms_demo_iroh_step.dependOn(&rooms_demo_iroh.step);

    // The tasks cross-language application demo: a capability-secure shared task
    // board with CRUD operations and live change notifications through capability
    // callbacks. One Zig-built native client plus the Deno server and
    // Deno/Python/Racket/Rust clients, all managing tasks on one board over TCP. Like
    // rooms, it needs `deno` (which hosts the board and runs the orchestrator)
    // and the Zig client, always built here. Python, Racket, and Rust join when their
    // runtimes are on PATH. It is a sibling step, not part of the hermetic gate.
    const tasks_client_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-tasks-client", "examples/apps/tasks/zig/client.zig");

    const tasks_demo = addInstalledSystemRun(b, &.{
        "deno",                        "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run",
        "examples/apps/tasks/demo.ts",
    });
    tasks_demo.addArtifactArg(tasks_client_exe);
    if (pin_port) |p| tasks_demo.addArg(b.fmt("--port={d}", .{p}));
    if (attach) tasks_demo.addArg("--attach");
    const tasks_demo_step = b.step("demo-tasks", "Run the cross-language tasks board demo (needs deno; joins python3/racket/cargo clients when present)");
    tasks_demo_step.dependOn(&tasks_demo.step);

    // The tools capability showcase: an AI-tool-harness shaped demo. A Deno
    // coordinator hands an agent capabilities to tools — attenuated to read-only,
    // and revocable — and each agent proves delegation, attenuation, and
    // revocation over OCapN/TCP. The coordinator and agent are different languages
    // on the wire, so the capability trio is real, not in-process. It needs `deno`
    // (which hosts the coordinator and runs the orchestrator); Python, Racket,
    // and Rust agents join when their runtimes are on PATH. A sibling step, not
    // part of the hermetic gate.
    const tools_agent_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-tools-agent", "examples/apps/tools/zig/agent.zig");

    const tools_demo = addInstalledSystemRun(b, &.{
        "deno",                        "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run",
        "examples/apps/tools/demo.ts",
    });
    tools_demo.addArtifactArg(tools_agent_exe); // the Zig agent's built path
    if (pin_port) |p| tools_demo.addArg(b.fmt("--port={d}", .{p}));
    if (attach) tools_demo.addArg("--attach");
    const tools_demo_step = b.step("demo-tools", "Run the cross-language tools demo: delegation, attenuation, and revocation (needs deno; joins python3/racket/cargo agents when present)");
    tools_demo_step.dependOn(&tools_demo.step);

    // ── Accountability application ───────────────────────────────────────────
    // accountability-on-pancake: a real worked application that runs ON pancake's
    // own runtime. Two native pancake peers complete an OCapN handshake over a
    // real loopback TCP socket; the host publishes an Affordance capability and
    // the caller invokes it, and every invocation produces a signed,
    // transparency-logged Episode attributing the attested caller. Identity
    // (KERI), Episodes, and the transparency log all live above pancake — the app
    // imports the `pancake` module and never reaches into the core. It is a
    // sibling of `check` (it needs no extra runtime, but it is a worked example
    // homed in `conformance/`, not part of the hermetic protocol gate). The app
    // source lives in `conformance/accountability-on-pancake/`.
    const run_accountability = addPancakeRun(b, lib_mod, target, optimize, "accountability-on-pancake", "conformance/accountability-on-pancake/zig/main.zig");
    const accountability_step = b.step("accountability", "Run the accountability application on pancake's own runtime over real TCP");
    accountability_step.dependOn(&run_accountability.step);
    // The accountability application and its three-party attribution test are
    // Zig-hermetic (loopback TCP and in-memory respectively), so they ride the
    // gate: a runnable application is a contract the same way an example is.
    check_step.dependOn(&run_accountability.step);

    // The cross-language accountability demo: the standalone Zig host (listens
    // on an ephemeral port and serves one connection per caller) driven by the
    // Deno orchestrator, which connects the Deno and Python callers over the
    // installed C ABI. The orchestrator receives the host binary's built path
    // as its argument; the host installs only for this step, not on every
    // default build.
    const host_exe = pancakeExecutable(b, lib_mod, target, optimize, "accountability-host", "conformance/accountability-on-pancake/zig/host.zig");
    const host_install = b.addInstallArtifact(host_exe, .{});
    const accountability_demo = addInstalledSystemRun(b, &.{
        "deno",                                               "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run",
        "conformance/accountability-on-pancake/deno/demo.ts",
    });
    accountability_demo.addArtifactArg(host_exe); // the Zig host's built path
    if (pin_port) |p| accountability_demo.addArg(b.fmt("--port={d}", .{p}));
    if (attach) accountability_demo.addArg("--attach"); // the orchestrator rejects it: each caller needs a fresh host
    const accountability_demo_step = b.step("demo-accountability", "Run the cross-language accountability demo: Zig host + Deno/Python callers (needs deno)");
    accountability_demo_step.dependOn(&host_install.step);
    accountability_demo_step.dependOn(&accountability_demo.step);

    // Three-party accountability test: proves that a handoff-introduced caller's
    // Episode attributes the true caller, not the introducer. In-memory, protocol-
    // level — the same test the Zig-native and cross-seam demos make over TCP.
    const three_party_mod = b.createModule(.{
        .root_source_file = b.path("conformance/accountability-on-pancake/zig/three_party_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    three_party_mod.addImport("pancake", lib_mod);
    const three_party_test = b.addTest(.{
        .name = "accountability-three-party",
        .root_module = three_party_mod,
    });
    const run_three_party = b.addRunArtifact(three_party_test);
    const three_party_step = b.step("accountability-three-party", "Run the three-party accountability attribution test");
    three_party_step.dependOn(&run_three_party.step);
    check_step.dependOn(&run_three_party.step);

    // ── Documentation site (sibling of `check`) ──────────────────────────────
    // The public face under zig-out/site/: the Zine-rendered pages plus the
    // autodoc API reference under reference/api/. Zine is a heavyweight static
    // site generator, so it lives behind its own build in `site/build.zig` and
    // is compiled only when these steps run — the same way the cargo, deno, and
    // racket sibling steps reach for their tool at run time. The hermetic
    // `check` graph never imports it, so the root build stays dependency-free.
    const site_cache_dir = b.pathJoin(&.{ b.build_root.path.?, ".zig-cache" });
    const render_site = b.addSystemCommand(&.{
        b.graph.zig_exe, "build",
        "--build-file",  "site/build.zig",
        "--cache-dir",   site_cache_dir,
        "--prefix",      b.install_prefix,
        "site",
    });
    render_site.has_side_effects = true;

    // The reference section is the generated autodoc for the public `pancake`
    // module, installed into the rendered site after Zine has written the pages.
    // Zine renders with `force`, so it leaves the rest of the tree in place and
    // this install drops the generated reference at reference/api/.
    const site_docs_install = b.addInstallDirectory(.{
        .source_dir = static_lib.getEmittedDocs(),
        .install_dir = .{ .custom = "site" },
        .install_subdir = "reference/api",
    });
    site_docs_install.step.dependOn(&render_site.step);
    const site_step = b.step("site", "Build the documentation site (Zine + autodoc) under zig-out/site/");
    site_step.dependOn(&site_docs_install.step);

    // `docs-serve` is the normal local preview: Zine's development server
    // rebuilds and reloads as the content and templates change. It serves the
    // Zine pages only — the generated autodoc reference is a release-time
    // install, so preview the API reference with `zig build site`.
    const serve_site = b.addSystemCommand(&.{
        b.graph.zig_exe, "build",
        "--build-file",  "site/build.zig",
        "--cache-dir",   site_cache_dir,
        "docs-serve",
    });
    if (pin_port) |p| serve_site.addArg(b.fmt("-Dport={d}", .{p}));
    serve_site.has_side_effects = true;
    const docs_serve_step = b.step("docs-serve", "Serve the documentation site locally with Zine's development server");
    docs_serve_step.dependOn(&serve_site.step);

    // Serena's SolidLSP ZLS adapter currently hard-codes build-on-save args to
    // `zig build build`; keep that editor-only alias pointed at the normal
    // install step. The project correctness gate remains `zig build check`.
    const build_step = b.step("build", "Build and install libpancake artifacts");
    build_step.dependOn(b.getInstallStep());
}
