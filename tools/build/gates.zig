//! The in-tree correctness gate: unit and oracle suites, structure checks,
//! cross-compiles, and perf tripwires.
//! The root build composes this module and receives the `check` step, the test
//! filter, and the wasm install step (registered by `wasm.zig`) used by
//! browser-facing siblings.

const std = @import("std");
const root = @import("../../build.zig");
const arch_check = @import("../check/arch_check.zig");
const source_check = @import("../check/source_check.zig");
const archives = @import("archives.zig");
const commands = @import("commands.zig");
const modules = @import("modules.zig");
const execution = @import("execution.zig");
const agent_index_build = @import("agent_index.zig");
const dependencies_build = @import("dependencies.zig");
const doc_values_build = @import("doc_values.zig");
const doc_impact_build = @import("doc_impact.zig");
const frame_identity = @import("frame_identity.zig");
const infrastructure_build = @import("infrastructure.zig");
const wasm_build = @import("wasm.zig");

const layer_table = root.layer_table;
const layerIndex = root.layerIndex;
const graphFromTable = root.graphFromTable;
pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// The public `glowcap` module and the shared layer instances the test
    /// suites import directly.
    lib_mod: *std.Build.Module,
    host_mods: []*std.Build.Module,
    tcp_abi_mod: *std.Build.Module,
    relay_check_abi_mod: *std.Build.Module,
    inproc_abi_mod: *std.Build.Module,
    onion_abi_mod: *std.Build.Module,
    host_abi_mod: *std.Build.Module,
    driver_abi_mod: *std.Build.Module,
};

pub const Registered = struct {
    check_step: *std.Build.Step,
    source_check_step: *std.Build.Step,
    runtime_gate: *execution.RuntimeGate,
    test_filter: ?[]const u8,
    /// The wasm module's install step. Every serve path and browser proof
    /// reads the on-disk artifact it writes.
    wasm_install: *std.Build.Step,
    wasm_archives: *std.Build.Step,
    /// The scenario and agreement layer, for a test root outside the main
    /// suite whose pair harness holds pairs to the agreement.
    scenarios: *std.Build.Module,
};

/// The full `src/root.zig` module graph for an arbitrary target, used by the
/// cross-compile gate to type-check the platform backends (notably the
/// Darwin `kqueue` path, which a Linux host build never compiles)
/// without running, so a regression there fails `zig build check` instead of
/// waiting for a Mac.
fn crossLibModule(b: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode) *std.Build.Module {
    const mods = graphFromTable(b, t, o, &layer_table, false);
    return mods[layerIndex("glowcap")];
}

/// The *sans-io core* module graph (no `net` / I/O) for an arbitrary
/// target, returning the `actors` module at its top, which type-checks the
/// core for `wasm32-freestanding`, gating the 32-bit overflow guards the codec
/// carries without pulling in the I/O layers that wasm lacks.
fn crossCoreModule(b: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode) *std.Build.Module {
    const mods = graphFromTable(b, t, o, layer_table[0 .. layerIndex("actors") + 1], false);
    return mods[layerIndex("actors")];
}

/// The CapTP scenario drivers under `test/oracle/scenarios/`: test code that
/// drives a `Peer` through fixed protocol scenarios and returns the wire bytes
/// the oracle, fuzz, and memcheck suites compare. Built once per module graph
/// because each graph has its own target and mode.
fn scenariosModule(b: *std.Build, mods: []*std.Build.Module, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("test/oracle/scenarios/mod.zig"),
        .target = t,
        .optimize = o,
    });
    inline for (.{ "foundation", "model", "session", "engine" }) |layer| mod.addImport(layer, mods[layerIndex(layer)]);
    return mod;
}

/// One named import edge for a transport C ABI module.
pub fn register(ctx: Context) Registered {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const lib_mod = ctx.lib_mod;
    const host_mods = ctx.host_mods;
    const tcp_abi_mod = ctx.tcp_abi_mod;
    const relay_check_abi_mod = ctx.relay_check_abi_mod;
    const inproc_abi_mod = ctx.inproc_abi_mod;
    const onion_abi_mod = ctx.onion_abi_mod;
    const host_abi_mod = ctx.host_abi_mod;
    const driver_abi_mod = ctx.driver_abi_mod;

    // ── The gate ─────────────────────────────────────────────────────────────
    // Steps below are declared in newcomer priority order, `zig build -l`
    // lists them in declaration order. `check` leads; its focused components
    // follow; the non-hermetic sibling steps come last, grouped by concern.
    //
    // The core correctness gate is hermetic from outside authority: arch gate,
    // source gate, tests, oracle checks, the header staleness check, the Zig + C
    // examples, the cross-compile gate, and the benchmark checks (peer-scaling
    // in its in-process smoke mode). The binding test suites
    // (`zig build rust-test`, and the wider `zig build bindings`) need
    // cargo/deno/python/racket on PATH, so it is a sibling step run alongside
    // `check`, not a dependency of it. `check` itself requires the small host
    // tool set `in_tree_runtimes` declares in toolchain.zig. The container has it.
    // CI: the checks workflow (.github/workflows/)
    // runs `check` and the sibling gates inside the committed devcontainer
    // image, as ci/groups.py lists them.
    // Each section below wires its gated runs into `check` where the artifacts
    // are built.
    const check_step = b.step("check", "Run in-process Zig, static, generated, performance, and compile-time checks");
    const runtime_gate = b.allocator.create(execution.RuntimeGate) catch @panic("OOM");
    runtime_gate.* = .{
        .step = b.step("runtime-check", "Run deterministic process, application, and language-workspace checks without cross-step contention"),
        .build = b.step("runtime-check-build", "Compile everything runtime-check runs, so its deadline measures only the runs"),
    };

    // ── Tests ────────────────────────────────────────────────────────────────
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("test/all_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addImport("glowcap", lib_mod);
    frame_identity.addFixtures(b, tests_mod, target, optimize);
    // Completion deadline arithmetic is implementation authority, not a
    // supported `net` namespace. Focused tests import that leaf directly so
    // evidence never forces a consumer-root re-export.
    // The C ABI layers are not on the public `glowcap` namespace (a Zig
    // consumer has no use for them), so their test suites import the layer
    // modules directly.
    // Renderer invariant tests use the Syrup implementation barrel directly;
    // importing a child file as a second module violates Zig's file-identity rule.
    tests_mod.addImport("syrup", host_mods[layerIndex("syrup")]);
    tests_mod.addImport("c_abi_shared", host_mods[layerIndex("c_abi_shared")]);
    tests_mod.addImport("c_abi", host_mods[layerIndex("c_abi")]);
    // The transport C ABI archives are separate modules (ADR-0022); their
    // loopback suites drive them directly, reusing the artifact module instances.
    tests_mod.addImport("c_abi_net_transport_tcp", tcp_abi_mod);
    tests_mod.addImport("c_abi_net_transport_relay", relay_check_abi_mod);
    tests_mod.addImport("c_abi_net_transport_inproc", inproc_abi_mod);
    tests_mod.addImport("c_abi_net_transport_onion", onion_abi_mod);
    tests_mod.addImport("c_abi_host", host_abi_mod);
    tests_mod.addImport("c_abi_driver", driver_abi_mod);
    const scenarios_mod = scenariosModule(b, host_mods, target, optimize);
    tests_mod.addImport("scenarios", scenarios_mod);
    // Collection tests import the dependency-free Loam leaf directly, matching
    // the snapshot benchmark without involving storage or LMDB backends.
    tests_mod.addImport("loam_collections", host_mods[layerIndex("loam_collections")]);
    // The header-parity test imports translated generated headers to prove they
    // agree with the Zig C ABI sources (sizes, offsets, constants), so the two
    // can never silently drift.
    const c_headers = b.addTranslateC(.{
        .root_source_file = b.path("test/c_abi/header_parity.c"),
        .target = target,
        .optimize = optimize,
    });
    c_headers.addIncludePath(b.path("include"));
    tests_mod.addImport("c_headers", c_headers.createModule());
    tests_mod.addIncludePath(b.path("include"));
    tests_mod.link_libc = true;
    // Callback cancellation must work across independently compiled Zig
    // archives, which an ordinary single-image Zig test cannot establish.
    const foreign_host_mod = b.createModule(.{
        .root_source_file = b.path("test/support/foreign_host_archive.zig"),
        .target = target,
        .optimize = optimize,
    });
    foreign_host_mod.addImport("driver_core", host_mods[layerIndex("driver_core")]);
    foreign_host_mod.addImport("actors", host_mods[layerIndex("actors")]);
    const foreign_host = b.addLibrary(.{
        .name = "glowcap-test-foreign-host",
        .linkage = .static,
        .root_module = foreign_host_mod,
    });
    tests_mod.linkLibrary(foreign_host);
    // `-Dtest-layer=engine,driver` compiles only those layers' test files while
    // iterating. Every gate leaves it unset and compiles the whole suite.
    const test_layer = b.option([]const u8, "test-layer", "Compile only these comma-separated test layers (engine, driver, net, ...)");
    const test_layers = b.addOptions();
    var selected_layers: std.ArrayList([]const u8) = .empty;
    if (test_layer) |list| {
        var it = std.mem.tokenizeScalar(u8, list, ',');
        while (it.next()) |layer| selected_layers.append(b.allocator, layer) catch @panic("OOM");
    }
    test_layers.addOption([]const []const u8, "layers", selected_layers.items);
    tests_mod.addOptions("test_layers", test_layers);
    // `zig build test -Dtest-filter=<substring>` narrows the run to matching
    // test names while iterating; the bare step still runs everything.
    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose names contain this substring");
    const tests = b.addTest(.{
        .root_module = tests_mod,
        .filters = if (test_filter) |f| b.dupeStrings(&.{f}) else &.{},
    });

    const run_tests = execution.addZigTest(b, tests, .unit_test);
    const completion_deadlines_tests_mod = b.createModule(.{
        .root_source_file = b.path("test/net/completion_loop_deadlines_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const completion_deadlines_mod = b.createModule(.{
        .root_source_file = b.path("src/net/completion/loop/connections/deadlines.zig"),
        .target = target,
        .optimize = optimize,
    });
    completion_deadlines_tests_mod.addImport("completion_deadlines", completion_deadlines_mod);
    const completion_deadlines_tests = b.addTest(.{ .root_module = completion_deadlines_tests_mod });
    const run_completion_deadlines_tests = execution.addZigTest(b, completion_deadlines_tests, .unit_test);
    // ── Memcheck ──────────────────────────────────────────────────────────
    // The protocol core and actors tests run once more under valgrind. The graph is
    // built for the baseline CPU because the checker cannot execute the
    // SHA-256 instructions the machine's own target enables, and Debug keeps
    // Zig's valgrind client requests on, so every `undefined` byte is one the
    // checker tracks. The I/O layers stay out because the checker does not
    // follow io_uring, and Loam stays out until its tests need no LMDB
    // process. `-Dtest-filter` narrows this suite as it does `test`.
    const memcheck_target = b.resolveTargetQuery(.{ .cpu_model = .baseline });
    const memcheck_mods = graphFromTable(b, memcheck_target, .Debug, &layer_table, false);
    const memcheck_mod = b.createModule(.{
        .root_source_file = b.path("test/all_test.zig"),
        .target = memcheck_target,
        .optimize = .Debug,
    });
    memcheck_mod.addImport("glowcap", memcheck_mods[layerIndex("glowcap")]);
    memcheck_mod.addImport("scenarios", scenariosModule(b, memcheck_mods, memcheck_target, .Debug));
    frame_identity.addFixtures(b, memcheck_mod, memcheck_target, .Debug);
    memcheck_mod.addImport("syrup", memcheck_mods[layerIndex("syrup")]);
    const memcheck_layers = b.addOptions();
    memcheck_layers.addOption([]const []const u8, "layers", &.{ "foundation", "model", "codec", "session", "engine", "actors" });
    memcheck_mod.addOptions("test_layers", memcheck_layers);
    // LLVM on every host: Zig's own x86_64 backend probes a large frame's
    // stack pages before it moves the stack pointer, and the checker reports
    // each probe as a read below the stack.
    const memcheck_tests = b.addTest(.{
        .root_module = memcheck_mod,
        .filters = if (test_filter) |f| b.dupeStrings(&.{f}) else &.{},
        .use_llvm = true,
    });
    // The hosted baseline-CPU Debug suite measured 672s under valgrind.
    // Instrumentation needs at least 2x that time, independently of compilation.
    const run_memcheck = execution.addZigTest(b, memcheck_tests, .{ .memcheck = 1800 });
    b.step("test-memcheck", "Run the protocol core and actors tests under valgrind, built for the baseline CPU (-Dtest-filter narrows it)").dependOn(&run_memcheck.step);
    b.step("test-memcheck-build", "Compile the test-memcheck suite without running it").dependOn(&memcheck_tests.step);
    // ── Mutation fuzzing ─────────────────────────────────────────────────────
    // Search stays outside `check`. The finite gate compiles this separate
    // root as well as replaying the corpus through the ordinary suite: that
    // suite cannot prove the standalone fuzz module has all its imports.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("test/fuzz_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_mod.addImport("glowcap", lib_mod);
    fuzz_mod.addImport("scenarios", scenarios_mod);
    // The immutable collections use the same direct leaf import as the suite;
    // their fuzz target needs neither graph storage nor an LMDB backend, and
    // its fuzz target drives it against a plain map to see where they disagree.
    fuzz_mod.addImport("loam_collections", host_mods[layerIndex("loam_collections")]);
    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_mod,
        .name = "fuzz-tests",
        // `zig build fuzz` needs this: one `--fuzz` run searches a single
        // target, whichever the runner picks, so the driver narrows the build
        // to one target at a time and runs the fuzzer once per target. Without
        // the filter here it silently fuzzed the same target every time and
        // reported "no findings" for all the others.
        .filters = if (test_filter) |f| b.dupeStrings(&.{f}) else &.{},
    });
    const fuzz_run_step = b.step("fuzz-run", "Fuzz worker: `zig build fuzz` drives this, or add --fuzz yourself for Zig's coverage UI");
    fuzz_run_step.dependOn(&execution.addZigTest(b, fuzz_tests, .search).step);
    check_step.dependOn(&fuzz_tests.step);

    const fuzz_budget = b.option([]const u8, "fuzz-runs", "How long `zig build fuzz` searches each target (default 500K; accepts K, M, G suffixes)") orelse "500K";
    const fuzz_driver_exe = b.addExecutable(.{
        .name = "glowcap-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fuzz/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const shard_mod = b.createModule(.{ .root_source_file = b.path("tools/build/shard.zig"), .target = b.graph.host });
    fuzz_driver_exe.root_module.addImport("shard", shard_mod);
    const fuzz_shard = execution.shardOption(b, "fuzz-shard", "Search only the k-th of n interleaved slices of the targets, as k/n (default 1/1)");
    const fuzz_driver = execution.addArtifact(b, .search, fuzz_driver_exe);
    fuzz_driver.addArgs(&.{ b.graph.zig_exe, b.fmt("--fuzz={s}", .{fuzz_budget}), b.fmt("--shard={d}/{d}", .{ fuzz_shard.index, fuzz_shard.count }) });
    fuzz_driver.has_side_effects = true;
    // The driver only runs under `zig build fuzz`, so the check gate compiles it.
    check_step.dependOn(&fuzz_driver_exe.step);
    b.step("fuzz", "Mutation-fuzz every untrusted-input target (-Dfuzz-runs to change how long each one searches)")
        .dependOn(&fuzz_driver.step);

    const test_step = b.step("test", "Run the unit and scenario test suite (test/all_test.zig)");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_completion_deadlines_tests.step);
    check_step.dependOn(&run_tests.step);
    check_step.dependOn(&run_completion_deadlines_tests.step);

    // ADR-0042's focused completion-tier proof. The ordinary test aggregate
    // carries this file too; the named step keeps the transport package's loop
    // evidence directly runnable while iterating or reviewing the ADR.
    const onion_loop_tests_mod = b.createModule(.{
        // The wrapper roots the module at `test/`, so the scenario can share
        // the ordinary aggregate's support imports without giving one file
        // two Zig module identities.
        .root_source_file = b.path("test/onion_loop_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    onion_loop_tests_mod.addImport("glowcap", lib_mod);
    const onion_loop_tests = b.addTest(.{ .root_module = onion_loop_tests_mod });
    const onion_loop_step = b.step("onion-loop-test", "Run the focused Zig OnionLoop completion tests");
    onion_loop_step.dependOn(&execution.addZigTest(b, onion_loop_tests, .unit_test).step);

    // ADR-0018's pending resident listen for `onion`. The publish conversation
    // runs on the loop's own turns and never blocks it; the runtime gate
    // exercises that through the completion residents over the fake daemon.
    const onion_pending_tests_mod = b.createModule(.{
        .root_source_file = b.path("test/onion_pending_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    onion_pending_tests_mod.addImport("glowcap", lib_mod);
    const onion_pending_tests = b.addTest(.{ .root_module = onion_pending_tests_mod });
    const onion_pending_step = b.step("onion-pending-listen-test", "Run the onion pending-listen resident tests over the fake daemon");
    onion_pending_step.dependOn(&execution.addZigTest(b, onion_pending_tests, .unit_test).step);
    runtime_gate.add(onion_pending_step);

    const oracle_tests_mod = b.createModule(.{
        .root_source_file = b.path("test/oracle_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    oracle_tests_mod.addImport("glowcap", lib_mod);
    oracle_tests_mod.addImport("scenarios", scenarios_mod);
    const oracle_tests = b.addTest(.{
        .root_module = oracle_tests_mod,
    });
    const run_oracle_tests = execution.addZigTest(b, oracle_tests, .unit_test);
    const oracle_check_step = b.step("oracle-check", "Run the protocol oracle: message-arm coverage, Syrup corpus parity, and whole-conversation scenario traces (test/oracle_check.zig)");
    oracle_check_step.dependOn(&run_oracle_tests.step);
    check_step.dependOn(&run_oracle_tests.step);

    // ── Structure gates ──────────────────────────────────────────────────────
    const arch_check_step_inner = arch_check.create(b, &layer_table);
    const arch_check_step = b.step("arch-check", "Enforce the layer dependency DAG over src/");
    arch_check_step.dependOn(arch_check_step_inner);
    check_step.dependOn(arch_check_step);

    const source_check_step_inner = source_check.create(b);

    // Unit tests for the source gate's own parsers (link/command/Mermaid logic)
    // live in `tools/check/source_check.zig`. The file is a build-time import, so its
    // `test` blocks only run when compiled as a dedicated test artifact.
    const source_check_tests_mod = b.createModule(.{
        .root_source_file = b.path("tools/check/source_check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = source_check.checkImports(b, target, optimize),
    });
    const source_check_tests = b.addTest(.{ .root_module = source_check_tests_mod });
    const run_source_check_tests = execution.addZigTest(b, source_check_tests, .unit_test);

    const source_check_step = b.step("source-check", "Enforce formatting and cross-file source, generated, documentation, and scaffolding contracts");
    source_check_step.dependOn(source_check_step_inner);
    source_check_step.dependOn(&run_source_check_tests.step);
    agent_index_build.register(b, source_check_step);
    dependencies_build.register(b, source_check_step);
    doc_values_build.register(b, source_check_step);
    doc_impact_build.register(b, source_check_step);
    const devcontainer_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "bash", ".devcontainer/test/env-sync.sh" });
    devcontainer_contracts.has_side_effects = true;
    source_check_step.dependOn(&devcontainer_contracts.step);
    // The pinned ruff formats and lints every first-party Python file, from
    // the CI programs to the binding, under the root ruff.toml.
    const python_format = commands.addRootedSystemCommand(b, .build_tool, &.{ "ruff", "format", "--check", "." });
    const python_lint = commands.addRootedSystemCommand(b, .build_tool, &.{ "ruff", "check", "." });
    // The pinned mypy types the CI programs and the build tools. Each `ci`
    // file imports its siblings by bare name, so that directory is its own
    // base; `tools` files are named from the root.
    const ci_types = commands.addRootedSystemCommand(b, .build_tool, &(commands.mypy ++ .{"ci"}));
    const tool_types = commands.addRootedSystemCommand(b, .build_tool, &(commands.mypy ++ .{ "--explicit-package-bases", "tools" }));
    const python_check_step = b.step("python-check", "Check the formatting and lint of every first-party Python file with the pinned ruff, and type the CI programs and build tools with the pinned mypy");
    python_check_step.dependOn(&python_format.step);
    python_check_step.dependOn(&python_lint.step);
    python_check_step.dependOn(&ci_types.step);
    python_check_step.dependOn(&tool_types.step);
    source_check_step.dependOn(python_check_step);
    const python_format_write = commands.addRootedSystemCommand(b, .build_tool, &.{ "ruff", "format", "." });
    python_format_write.has_side_effects = true;
    b.step("python-fmt", "Format every first-party Python file in place with the pinned ruff").dependOn(&python_format_write.step);
    const shard_tests = b.addTest(.{ .name = "shard-tests", .root_module = shard_mod });
    source_check_step.dependOn(&execution.addZigTest(b, shard_tests, .unit_test).step);
    check_step.dependOn(source_check_step);
    infrastructure_build.register(b);

    // Cross-compile gate: type-check the whole library for macOS (and a 64-bit
    // Darwin) so the kqueue completion backend, which a Linux host build never
    // compiles, cannot regress unnoticed. Compile-only: depending on the object's
    // step builds it without running a foreign binary. `aarch64-macos` exercises
    // kqueue; `x86_64-linux` is the host and would be redundant, so the second
    // target is a different ABI to widen coverage cheaply.
    const cross_macos = b.addObject(.{
        .name = "glowcap-cross-macos",
        .root_module = crossLibModule(b, b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos }), .Debug),
    });
    // wasm32-freestanding type-checks the sans-io core (no I/O layers wasm
    // lacks), gating the 32-bit overflow guards the codec carries.
    const cross_wasm = b.addObject(.{
        .name = "glowcap-cross-wasm-core",
        .root_module = crossCoreModule(b, b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }), .Debug),
    });
    // A real fetched archive applies .paths, unlike a checkout dependency.
    // Exercise core-only use and all optional modules outside the checkout.
    const consumer_check_step = b.step("consumer-check", "Build a downstream package against the glowcap module (the README's fetch/import path)");
    const consumer_build = commands.addRootedSystemCommand(b, .build_tool, &.{
        "python3", "tools/check/zig_package.py", "--zig", b.graph.zig_exe,
    });
    consumer_build.setName("consumer-check");
    consumer_check_step.dependOn(&consumer_build.step);
    check_step.dependOn(consumer_check_step);

    // The Zig tree in ReleaseFast. std's runtime-safety
    // instrumentation: the `pointer_stability` lock every list and map header
    // carries in Debug and ReleaseSafe, is zero-sized there, so every footprint
    // budget measures smaller. The ceilings absorb
    // that; the one comptime equality, the loop slot in
    // `src/net/completion/loop/state.zig`, states its fast-mode expectation and
    // only this leg proves it, because nothing else in `check` instantiates the
    // loop outside Debug while a product build may. `test/api_surface_test.zig`
    // is the root because it references every exported declaration, which is
    // what reaches the loop instantiations and every other comptime gate; its
    // one test is comptime, so running it costs nothing beyond the compile.
    const cross_fast_mod = b.createModule(.{
        .root_source_file = b.path("test/api_surface_test.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    cross_fast_mod.addImport("glowcap", crossLibModule(b, target, .ReleaseFast));
    cross_fast_mod.link_libc = true;
    const cross_fast = b.addTest(.{ .name = "glowcap-cross-fast", .root_module = cross_fast_mod });
    const run_cross_fast = execution.addZigTest(b, cross_fast, .unit_test);

    const cross_check_step = b.step("cross-check", "Type-check non-host targets, macOS/kqueue (full) and wasm32 (sans-io core), compile-only, and analyze the Zig tree in ReleaseFast");
    cross_check_step.dependOn(&cross_macos.step);
    cross_check_step.dependOn(&cross_wasm.step);
    cross_check_step.dependOn(&run_cross_fast.step);
    check_step.dependOn(cross_check_step);

    const wasm = wasm_build.register(b, cross_check_step);

    return .{
        .check_step = check_step,
        .source_check_step = source_check_step,
        .runtime_gate = runtime_gate,
        .test_filter = test_filter,
        .wasm_install = wasm.install,
        .wasm_archives = wasm.archives,
        .scenarios = scenarios_mod,
    };
}
