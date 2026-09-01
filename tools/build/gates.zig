//! The in-tree correctness gate: unit and oracle suites, structure checks,
//! cross-compiles, perf tripwires, and the browser Host wasm artifact.
//! The root build composes this module and receives the `check` step, the test
//! filter, and the wasm install step used by browser-facing siblings.

const std = @import("std");
const root = @import("../../build.zig");
const arch_check = @import("../check/arch_check.zig");
const source_check = @import("../check/source_check.zig");
const toolchain_check = @import("../check/toolchain_check.zig");
const common = @import("common.zig");
const execution = @import("execution.zig");

const transportAbiModule = common.transportAbiModule;
const layer_table = root.layer_table;
const layerIndex = root.layerIndex;
const graphFromTable = root.graphFromTable;
/// What `zig build check` requires on PATH besides Zig. A row raises the floor
/// for every contributor, so the graph checker below holds this inventory to
/// the gate's actual process dependencies.
const check_runtimes = [_]toolchain_check.Runtime{
    .{
        .program = "python3",
        .scripts = &.{"tools/run-with-timeout.py"},
        .modules = &.{"py_compile"},
        .why = "deterministic subprocesses use the shared deadline wrapper and the Python benchmark client is compile-checked",
    },
    .{
        .program = "bash",
        .scripts = &.{
            ".devcontainer/test/env-sync.sh",
            ".devcontainer/test/host-invariants.sh",
            "tools/check/ocapnviz-build-check.sh",
            "tools/check/ocapnviz-test.sh",
            "tools/c-abi/c-abi-extract-matrix.sh",
            "tools/check/worktree-integration-test.sh",
        },
        .why = "devcontainer, worktree, C-ABI extract, and visualizer harnesses are shell-owned",
    },
    .{
        .program = "deno",
        .why = "checked TypeScript examples and site surfaces catch binding API drift",
    },
    .{
        .program = "cargo",
        .why = "the Rust benchmark client is compile-checked against the current binding",
    },
    .{
        .program = "raco",
        .why = "the Racket benchmark clients are compiled against the current binding",
    },
};

pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// The public `pancake` module and the shared layer instances the test
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
    test_filter: ?[]const u8,
    /// The wasm module's install step; every serve path and browser proof
    /// reads the on-disk artifact it writes.
    wasm_install: *std.Build.Step,
};

/// The full `src/root.zig` module graph for an arbitrary target, used by the
/// cross-compile gate to type-check the platform backends (notably the
/// Darwin `kqueue` path, which the host io_uring build never compiles)
/// without running, so a regression there fails `zig build check` instead of
/// waiting for a Mac.
fn crossLibModule(b: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode) *std.Build.Module {
    const mods = graphFromTable(b, t, o, &layer_table, false);
    return mods[layerIndex("pancake")];
}

/// The *sans-io core* module graph (no `net` / I/O) for an arbitrary
/// target, returning the `actors` module at its top, used to type-check the
/// core for `wasm32-freestanding`, gating the 32-bit overflow guards the codec
/// carries without pulling in the I/O layers that wasm lacks.
fn crossCoreModule(b: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode) *std.Build.Module {
    const mods = graphFromTable(b, t, o, layer_table[0 .. layerIndex("actors") + 1], false);
    return mods[layerIndex("actors")];
}

/// The browser binding's freestanding `wasm32` artifact (ADR-0070): the byte-fed
/// CapTP Host (`libpancake_host`) and the shared `libpancake_ocapn` vocabulary
/// compiled to one loadable wasm module. It roots on `src/c_abi/wasm/mod.zig`,
/// which forces both export families in and adds the JS<->wasm linear-memory
/// primitives. The module graph is the sans-io core (the `core = true` prefix)
/// plus the two ocapn C ABI vocabulary rows; the I/O layers (`net`, `driver`,
/// `oracle`) wasm lacks are excluded. ReleaseSmall keeps the download small and
/// drops the runtime-safety-only `std.Thread.getCurrentId` owner assert.
/// The `layer_table` rows the wasm driver's base module graph transitively
/// needs, as a keep-mask over `layer_table`.
///
/// It is the import-closure of the `c_abi_wasm` root's forced families — its own
/// declared imports, `{c_abi_shared, c_abi, c_abi_host}` — followed over
/// `layer_table` edges, then restricted to the `graph = true` rows
/// `graphFromTable` actually builds. The two `graph = false` reached rows
/// (`c_abi_host` and the wasm root itself) are minted at the use site below,
/// so they stay out of the base graph. Deriving the set from the edges is what
/// lets a new dependency of the wasm surface pull itself in, instead of a
/// hand-kept name list that silently over- or under-includes as edges change.
fn wasmGraphMask() [layer_table.len]bool {
    @setEvalBranchQuota(20000);
    var reached: [layer_table.len]bool = @splat(false);
    for (layer_table[layerIndex("c_abi_wasm")].imports) |name| reached[layerIndex(name)] = true;
    // Fixpoint: pull in every import of an already-reached row. Edges only point
    // at earlier rows, so `layer_table.len` forward passes reach the fixpoint.
    var pass: usize = 0;
    while (pass < layer_table.len) : (pass += 1) {
        for (layer_table, 0..) |spec, i| {
            if (!reached[i]) continue;
            for (spec.imports) |name| reached[layerIndex(name)] = true;
        }
    }
    var mask: [layer_table.len]bool = @splat(false);
    for (layer_table, 0..) |spec, i| mask[i] = reached[i] and spec.graph;
    return mask;
}

fn wasmDriverExe(b: *std.Build, o: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const t = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const mask = comptime wasmGraphMask();
    var buf: [layer_table.len]arch_check.LayerSpec = undefined;
    var n: usize = 0;
    inline for (layer_table, 0..) |spec, i| {
        if (mask[i]) {
            buf[n] = spec;
            n += 1;
        }
    }
    const sub = buf[0..n];
    const mods = graphFromTable(b, t, o, sub, false);
    const pick = struct {
        fn get(table: []const arch_check.LayerSpec, ms: []*std.Build.Module, name: []const u8) *std.Build.Module {
            for (table, 0..) |spec, i| {
                if (std.mem.eql(u8, spec.name, name)) return ms[i];
            }
            @panic("wasm layer subset missing a required row");
        }
    }.get;
    // `c_abi_host` and the `c_abi_wasm` root are graph=false; mint them at this
    // use site the way the transport archives are, wiring the wasm modules above.
    const driver_mod = transportAbiModule(b, t, o, "src/c_abi/host/mod.zig", &.{
        .{ .name = "foundation", .module = pick(sub, mods, "foundation") },
        .{ .name = "model", .module = pick(sub, mods, "model") },
        .{ .name = "engine", .module = pick(sub, mods, "engine") },
        .{ .name = "actors", .module = pick(sub, mods, "actors") },
        .{ .name = "driver_core", .module = pick(sub, mods, "driver_core") },
        .{ .name = "c_abi_shared", .module = pick(sub, mods, "c_abi_shared") },
    });
    const wasm_root = transportAbiModule(b, t, o, "src/c_abi/wasm/mod.zig", &.{
        .{ .name = "c_abi_shared", .module = pick(sub, mods, "c_abi_shared") },
        .{ .name = "c_abi", .module = pick(sub, mods, "c_abi") },
        .{ .name = "c_abi_host", .module = driver_mod },
    });
    const exe = b.addExecutable(.{ .name = "pancake_host", .root_module = wasm_root });
    // A loadable module, not a command: no `_start`, exports discovered from the
    // `export fn`s (`entry = .disabled`, `rdynamic`). The linker exports linear
    // memory so JS can read/write `ptr + len` across the boundary.
    exe.entry = .disabled;
    exe.rdynamic = true;
    return exe;
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
    // Steps below are declared in newcomer priority order — `zig build -l`
    // lists them in declaration order. `check` leads; its focused components
    // follow; the non-hermetic sibling steps come last, grouped by concern.
    //
    // The core correctness gate is hermetic from outside authority: arch gate,
    // source gate, tests, oracle checks, the header staleness check, the Zig + C
    // examples, the cross-compile gate, the accountability application
    // (loopback TCP) with its three-party attribution test, and the benchmark
    // checks (peer-scaling in smoke mode). The cross-language C ABI dogfood
    // (`zig build rust-dogfood`, and the wider `zig build bindings`) needs
    // cargo/deno/python/racket on PATH, so it is a sibling step run alongside
    // `check`, not a dependency of it. `check` itself requires the small host
    // tool set declared by `check_runtimes` above; the devcontainer supplies it.
    // CI: the checks workflow (.github/workflows/)
    // runs `check` and the sibling gates inside the committed devcontainer
    // image via ci/gates.sh.
    // Each section below wires its gated runs into `check` where the artifacts
    // are built.
    const check_step = b.step("check", "Run the complete in-tree correctness gate");

    // ── Tests ────────────────────────────────────────────────────────────────
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("test/all_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addImport("pancake", lib_mod);
    // Completion deadline arithmetic is implementation authority, not a
    // supported `net` namespace. Focused tests import that leaf directly so
    // evidence never forces a consumer-root re-export.
    // The C ABI layers and `oracle` are not on the public `pancake` namespace
    // (a Zig consumer has no use for them), so their test suites import the
    // layer modules directly.
    // Renderer invariant tests use the Syrup implementation barrel directly;
    // importing a child file as a second module violates Zig's file-identity rule.
    tests_mod.addImport("syrup", host_mods[layerIndex("syrup")]);
    tests_mod.addImport("c_abi_shared", host_mods[layerIndex("c_abi_shared")]);
    tests_mod.addImport("c_abi", host_mods[layerIndex("c_abi")]);
    // The transport C ABI archives are separate modules (ADR-0059); their
    // loopback suites drive them directly, reusing the artifact module instances.
    tests_mod.addImport("c_abi_net_transport_tcp", tcp_abi_mod);
    tests_mod.addImport("c_abi_net_transport_relay", relay_check_abi_mod);
    tests_mod.addImport("c_abi_net_transport_inproc", inproc_abi_mod);
    tests_mod.addImport("c_abi_net_transport_onion", onion_abi_mod);
    tests_mod.addImport("c_abi_host", host_abi_mod);
    tests_mod.addImport("c_abi_driver", driver_abi_mod);
    tests_mod.addImport("oracle", host_mods[layerIndex("oracle")]);
    // The persistent-collections leaf module (ADR-0061) is not on the public
    // `pancake` namespace, so its direct test imports the layer module.
    tests_mod.addImport("persistent", host_mods[layerIndex("persistent")]);
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
    // `zig build test -Dtest-filter=<substring>` narrows the run to matching
    // test names while iterating; the bare step still runs everything.
    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose names contain this substring");
    const tests = b.addTest(.{
        .root_module = tests_mod,
        .filters = if (test_filter) |f| b.dupeStrings(&.{f}) else &.{},
    });

    const run_tests = execution.addZigTest(b, tests, .{ .deterministic = 30 });
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
    const run_completion_deadlines_tests = execution.addZigTest(b, completion_deadlines_tests, .{ .deterministic = 3 });
    // ── Mutation fuzzing ─────────────────────────────────────────────────────
    // Deliberately outside `check`: a search with no natural end does not
    // belong in a gate that has to finish. What `check` does carry is the
    // replay of everything the fuzzer has already found, which is the part
    // that must never regress.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("test/fuzz_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_mod.addImport("pancake", lib_mod);
    // Same reason the ordinary suite takes it directly: the persistent
    // collections leaf (ADR-0061) is not on the public `pancake` namespace, and
    // its fuzz target drives it against a plain map to see where they disagree.
    fuzz_mod.addImport("persistent", host_mods[layerIndex("persistent")]);
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

    const fuzz_budget = b.option([]const u8, "fuzz-runs", "How long `zig build fuzz` searches each target (default 500K; accepts K, M, G suffixes)") orelse "500K";
    const fuzz_driver_exe = b.addExecutable(.{
        .name = "pancake-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fuzz/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const fuzz_driver = execution.addArtifact(b, .search, fuzz_driver_exe);
    fuzz_driver.addArgs(&.{ b.graph.zig_exe, b.fmt("--fuzz={s}", .{fuzz_budget}) });
    fuzz_driver.has_side_effects = true;
    b.step("fuzz", "Mutation-fuzz every hostile-input target (-Dfuzz-runs to change how long each one searches)")
        .dependOn(&fuzz_driver.step);

    const test_step = b.step("test", "Run the unit and scenario test suite (test/all_test.zig)");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_completion_deadlines_tests.step);
    check_step.dependOn(&run_tests.step);
    check_step.dependOn(&run_completion_deadlines_tests.step);

    // ADR-0108's focused completion-tier proof. The ordinary test aggregate
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
    onion_loop_tests_mod.addImport("pancake", lib_mod);
    const onion_loop_tests = b.addTest(.{ .root_module = onion_loop_tests_mod });
    const onion_loop_step = b.step("onion-loop", "Run the focused native OnionLoop completion tests");
    onion_loop_step.dependOn(&execution.addZigTest(b, onion_loop_tests, .{ .deterministic = 3 }).step);

    const oracle_tests_mod = b.createModule(.{
        .root_source_file = b.path("test/oracle_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    oracle_tests_mod.addImport("pancake", lib_mod);
    // The scenario traces drive the `oracle` layer directly (it is not on the
    // public `pancake` namespace), so the focused gate imports it too.
    oracle_tests_mod.addImport("oracle", host_mods[layerIndex("oracle")]);
    const oracle_tests = b.addTest(.{
        .root_module = oracle_tests_mod,
    });
    const run_oracle_tests = execution.addZigTest(b, oracle_tests, .{ .deterministic = 3 });
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
    });
    const source_check_tests = b.addTest(.{ .root_module = source_check_tests_mod });
    const run_source_check_tests = execution.addZigTest(b, source_check_tests, .{ .deterministic = 3 });

    const source_check_step = b.step("source-check", "Enforce cross-file source, generated, documentation, and scaffolding contracts");
    source_check_step.dependOn(source_check_step_inner);
    source_check_step.dependOn(&run_source_check_tests.step);
    const devcontainer_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "bash", ".devcontainer/test/env-sync.sh" });
    devcontainer_contracts.has_side_effects = true;
    source_check_step.dependOn(&devcontainer_contracts.step);
    // The devcontainer's own behaviour tests: name grammars, checkout lookup,
    // launcher refusals, and the tmux pane runtime. They build their fixtures
    // in a temporary directory and need no container, so the directory that
    // every contributor builds in answers to the gate like any other surface.
    const devcontainer_behaviour = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "bash", ".devcontainer/test/host-invariants.sh" });
    devcontainer_behaviour.has_side_effects = true;
    source_check_step.dependOn(&devcontainer_behaviour.step);
    const worktree_integration_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "bash", "tools/check/worktree-integration-test.sh" });
    worktree_integration_contracts.has_side_effects = true;
    source_check_step.dependOn(&worktree_integration_contracts.step);
    check_step.dependOn(source_check_step);

    // The deadline wrapper every CI gate runs under, held by its behaviour
    // rather than by its source text: a check that greps the file for
    // `return 124` proves the string is present, not that a timed-out child
    // reports 124. Not a member of `check`. It needs `python3`, which `check`
    // does not, and it spends seconds on real deadline waits — and `ci/gates.sh`
    // already runs it first, which is the right place: the wrapper has to be
    // proven before the sequence that runs under it.
    const timeout_runner_test = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "bash", "tools/run-with-timeout-test.sh" });
    timeout_runner_test.has_side_effects = true;
    const timeout_runner_step = b.step("timeout-runner-test", "Black-box the CI deadline wrapper: exit codes, relayed signal, no survivors");
    timeout_runner_step.dependOn(&timeout_runner_test.step);

    // Cross-compile gate: type-check the whole library for macOS (and a 64-bit
    // Darwin) so the kqueue completion backend — which the host io_uring build never
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
    // The README's first instruction, as a check: a throwaway downstream
    // package under `tools/consumer/` depends on pancake by path the way a
    // consumer depends on it by URL, imports the `pancake` module, and builds
    // a program against the public surface. It is the one claim in the tree
    // that every reader executes, so it gets a step rather than an assertion.
    const consumer_check_step = b.step("consumer-check", "Build a downstream package against the pancake module (the README's fetch/import path)");
    const consumer_build = execution.addSystemCommand(b, .build_tool, &.{
        b.graph.zig_exe,
        "build",
        "--cache-dir",
        common.rootPath(b, ".zig-cache/consumer"),
        "--prefix",
        common.rootPath(b, "zig-out/consumer"),
    });
    consumer_build.setCwd(b.path("tools/consumer"));
    consumer_build.setName("consumer-check");
    consumer_check_step.dependOn(&consumer_build.step);
    check_step.dependOn(consumer_check_step);

    const cross_check_step = b.step("cross-check", "Type-check non-host targets — macOS/kqueue (full) and wasm32 (sans-io core), compile-only");
    cross_check_step.dependOn(&cross_macos.step);
    cross_check_step.dependOn(&cross_wasm.step);
    check_step.dependOn(cross_check_step);

    // The browser binding's freestanding wasm32 Host module (ADR-0070): the
    // byte-fed driver tier plus the shared ocapn vocabulary, one loadable
    // `pancake_host.wasm` under zig-out/wasm/ that a browser instantiates and
    // drives with bytes. Building it also folds the whole browser-binding graph
    // (`c_abi_host`, `c_abi_wasm`) into `cross-check`, so a wasm regression
    // fails the gate.
    const wasm_driver = wasmDriverExe(b, .ReleaseSmall);
    const wasm_driver_install = b.addInstallArtifact(wasm_driver, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });
    // The wasm module is a shipped artifact like the archives, so fold its
    // install into the default `zig build` install. Every serve path reads the
    // on-disk `zig-out/wasm/pancake_host.wasm`. Each rooms serve path depends on
    // this exact install step, and the compose deploy runs plain `zig build`.
    // Without this edge a renamed C-ABI symbol leaves the served module stale,
    // and the browser can only report the missing export at dlopen time.
    b.getInstallStep().dependOn(&wasm_driver_install.step);
    const wasm_driver_step = b.step("wasm-driver", "Build the browser binding's freestanding wasm32 Host module (ADR-0070) into zig-out/wasm/");
    wasm_driver_step.dependOn(&wasm_driver_install.step);
    cross_check_step.dependOn(&wasm_driver.step);

    // Behavioral proof that the wasm32 Host runs real CapTP from JavaScript: two
    // Hosts with distinct identities complete a keyed handshake over an in-memory
    // byte pipe, then the dialer refuses a wrong-peer sturdyref before output.
    // A sibling step (needs deno on PATH), not folded into the Zig-hermetic `check`.
    const wasm_driver_test = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "deno", "run", "--allow-read", "bindings/ts/web/test/wasm_handshake_smoke.ts" });
    wasm_driver_test.setCwd(b.path("."));
    wasm_driver_test.has_side_effects = true;
    wasm_driver_test.step.dependOn(&wasm_driver_install.step);
    const wasm_driver_test_step = b.step("wasm-driver-test", "Prove the wasm32 Host handshakes and checks sturdyref peer authority from JS (needs deno; ADR-0070/0098)");
    wasm_driver_test_step.dependOn(&wasm_driver_test.step);

    // The wasm32 layout descriptor (`pancake_wasm_abi_layout`) decodes cleanly:
    // instantiate the module, read the blob, prove it is well formed, and
    // cross-check each struct's field count against the `abi.ts` host mirror. A
    // sibling step (needs deno), not folded into the Zig-hermetic `check`.
    const wasm_abi_layout_check = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "deno", "run", "--allow-read", "tools/wasm/abi_layout_check.ts" });
    wasm_abi_layout_check.setCwd(b.path("."));
    wasm_abi_layout_check.has_side_effects = true;
    wasm_abi_layout_check.step.dependOn(&wasm_driver_install.step);
    const wasm_abi_layout_check_step = b.step("wasm-abi-layout-check", "Prove the wasm32 Host's layout descriptor (pancake_wasm_abi_layout) decodes cleanly and agrees with the abi.ts field counts (needs deno; ADR-0070)");
    wasm_abi_layout_check_step.dependOn(&wasm_abi_layout_check.step);

    // Product proof for the @pancake/web Wasm peer: keyed WebSocket call and
    // callback against a native host, then a native CLI cold-dial into that
    // browser-shaped Host over sealed noise-relay rendezvous. Needs the wasm
    const web_peer_test = execution.addSystemCommand(b, .{ .browser_proof = 120 }, &.{
        "deno",                                  "run", "--config", "deno.json", "--allow-all",
        "bindings/ts/web/test/web_peer_test.ts",
    });
    web_peer_test.setCwd(b.path("."));
    web_peer_test.has_side_effects = true;
    web_peer_test.step.dependOn(&wasm_driver_install.step);
    web_peer_test.step.dependOn(b.getInstallStep());
    const web_peer_test_step = b.step("web-peer-test", "Prove @pancake/web holds keyed WebSocket and sealed Noise-relay sessions with native peers (needs deno + Playwright; ADR-0070/0107)");
    web_peer_test_step.dependOn(&web_peer_test.step);

    // The cross-runtime relay matrix (`bindings-relay`, `bindings-relay-iroh`) is
    // wired below, after the iroh ABI companion it depends on is defined.

    // The wasm32 Host imports exactly the behavior-dispatch and hosted-
    // retirement seams (ADR-0070). Parse the module statically and assert that
    // fixed set, so an accidental extra import or rename fails the build. A
    // sibling step (needs deno), not folded into the Zig-hermetic `check`.
    const wasm_import_check = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "deno", "run", "--allow-read", "tools/wasm/import_check.ts" });
    wasm_import_check.setCwd(b.path("."));
    wasm_import_check.has_side_effects = true;
    wasm_import_check.step.dependOn(&wasm_driver_install.step);
    const wasm_import_check_step = b.step("wasm-import-check", "Prove the wasm32 Host imports exactly its behavior and hosted-retirement callbacks (needs deno; ADR-0070)");
    wasm_import_check_step.dependOn(&wasm_import_check.step);

    return .{
        .check_step = check_step,
        .test_filter = test_filter,
        .wasm_install = &wasm_driver_install.step,
    };
}

pub fn registerToolchainCheck(b: *std.Build, check_step: *std.Build.Step) void {
    const toolchain_check_step_inner = toolchain_check.create(b, check_step, &check_runtimes);
    const toolchain_check_step = b.step("toolchain-check", "Hold `zig build check` to its declared external runtimes");
    toolchain_check_step.dependOn(toolchain_check_step_inner);
    check_step.dependOn(toolchain_check_step);
}
