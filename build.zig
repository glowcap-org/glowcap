const std = @import("std");
const arch_check = @import("tools/check/arch_check.zig");
const meta_check = @import("tools/check/meta_check.zig");

/// C ABI version (keep in lockstep with `PANCAKE_VERSION_*` in
/// `include/pancake_ocapn.h` and `src/c_abi/ocapn/mod.zig`, and with `.version`
/// in `build.zig.zon` — the meta gate holds the zon triple to this one). Each
/// archive's dynamic library soname tracks `major`.
const abi_version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

/// The layer DAG, the one authoritative statement of the architecture
/// (ADR-0040; ADR-0048 for the sibling-codec modules below the codec layer).
/// Every build graph is generated from this table, and `tools/check/arch_check.zig`
/// verifies it against the source tree: a granted edge no file imports fails
/// the gate, so the table carries the edges the code uses, never a wider
/// silent allowance. Rows are in dependency order; the sans-io core graph is
/// the table prefix ending at `actors`, and the final `pancake` row is
/// `src/root.zig`, the curated public namespace over the layers.
const layer_table = [_]arch_check.LayerSpec{
    .{ .name = "foundation", .prefix = "foundation/", .imports = &.{}, .core = true },
    .{ .name = "model", .prefix = "ocapn/model/", .imports = &.{}, .core = true },
    .{ .name = "framing", .prefix = "ocapn/codec/framing.zig", .imports = &.{"model"}, .core = true },
    .{ .name = "codec_order", .prefix = "ocapn/codec/order.zig", .imports = &.{}, .core = true },
    .{ .name = "syrup", .prefix = "ocapn/codec/syrup/", .imports = &.{ "foundation", "model", "framing", "codec_order" }, .core = true },
    .{ .name = "capnp", .prefix = "ocapn/codec/capnp/", .imports = &.{ "foundation", "model", "framing", "codec_order" }, .core = true },
    .{ .name = "codec", .prefix = "ocapn/codec/", .imports = &.{ "foundation", "model", "framing", "codec_order", "syrup", "capnp" }, .core = true },
    .{ .name = "session", .prefix = "ocapn/session/", .imports = &.{"model"}, .core = true },
    .{ .name = "engine", .prefix = "ocapn/engine/", .imports = &.{ "foundation", "model", "codec", "session" }, .core = true },
    .{ .name = "persistent", .prefix = "persistent/", .imports = &.{}, .core = true },
    .{ .name = "actors", .prefix = "actors/", .imports = &.{ "model", "engine" }, .core = true },
    .{ .name = "net", .prefix = "net/", .imports = &.{ "foundation", "model", "codec", "engine" }, .core = false },
    .{ .name = "oracle", .prefix = "oracle/", .imports = &.{ "foundation", "model", "engine" }, .core = false },
    .{ .name = "driver_core", .prefix = "driver/core/", .imports = &.{ "foundation", "model", "engine", "actors" }, .core = true },
    .{ .name = "driver", .prefix = "driver/", .imports = &.{ "foundation", "model", "engine", "actors", "net", "driver_core" }, .core = false },
    .{ .name = "c_abi_shared", .prefix = "c_abi/shared/", .imports = &.{ "foundation", "model", "engine" }, .core = false },
    .{ .name = "c_abi", .prefix = "c_abi/ocapn/", .imports = &.{ "foundation", "model", "engine", "c_abi_shared" }, .core = false },
    .{ .name = "c_abi_net_transport_iroh", .prefix = "c_abi/net_transport/iroh/", .imports = &.{ "net", "c_abi_shared" }, .core = false, .graph = false },
    .{ .name = "c_abi_net_transport_tcp", .prefix = "c_abi/net_transport/tcp/", .imports = &.{ "net", "driver", "c_abi_shared" }, .core = false, .graph = false },
    .{ .name = "c_abi_net_transport_inproc", .prefix = "c_abi/net_transport/inproc/", .imports = &.{ "net", "c_abi_shared" }, .core = false, .graph = false },
    .{ .name = "c_abi_driver", .prefix = "c_abi/driver/", .imports = &.{ "foundation", "model", "engine", "actors", "driver_core", "c_abi_shared" }, .core = false, .graph = false },
    .{ .name = "c_abi_wasm", .prefix = "c_abi/wasm/", .imports = &.{ "c_abi_shared", "c_abi", "c_abi_driver" }, .core = false, .graph = false },
    .{ .name = "pancake", .prefix = "root.zig", .imports = &.{ "foundation", "model", "codec", "session", "engine", "actors", "net", "driver", "c_abi" }, .core = false },
};

/// The composable C ABI archive set (ADR-0059), declared once beside
/// `layer_table`. Each row names an installed archive, the `layer_table` row
/// whose module supplies its C ABI root (the source of its export family), and
/// the public header it ships (none for the inert net-core base). This table
/// drives the per-archive header install loop below and a comptime check that
/// each row's `layer` names a real `layer_table` row. The archives themselves
/// are built at their use sites, where each needs its own root module and link
/// handling; a consumer's link-alongside set is the real link line each C
/// example spells. Under Model A every transport embeds its lower layers as
/// local symbols, so `pancake_net` exports nothing yet; it is first-class in
/// the contract so the Model-A→B migration never adds an archive to a link line.
const ArchiveSpec = struct {
    /// Installed library name: `lib<artifact>.a` / `.so`.
    artifact: []const u8,
    /// The `layer_table` row supplying this archive's C ABI root module.
    layer: []const u8,
    /// The public header this archive installs, or null for an export-less base.
    header: ?[]const u8 = null,
    /// False for an archive that links a non-Zig sidecar and so installs only
    /// behind its own sibling step (iroh), never on the default build.
    default_install: bool = true,
};
const archive_table = [_]ArchiveSpec{
    .{ .artifact = "pancake_ocapn", .layer = "c_abi", .header = "pancake_ocapn.h" },
    .{ .artifact = "pancake_net", .layer = "net" },
    .{ .artifact = "pancake_net_transport_tcp", .layer = "c_abi_net_transport_tcp", .header = "pancake_net_transport_tcp.h" },
    .{ .artifact = "pancake_net_transport_inproc", .layer = "c_abi_net_transport_inproc", .header = "pancake_net_transport_inproc.h" },
    .{ .artifact = "pancake_driver", .layer = "c_abi_driver" },
    .{ .artifact = "pancake_net_transport_iroh", .layer = "c_abi_net_transport_iroh", .header = "pancake_net_transport_iroh.h", .default_install = false },
};

comptime {
    // Hold `archive_table` honest against `layer_table`: every archive's root
    // layer must name a real row, so a typo or a removed layer fails the build.
    for (archive_table) |arch| _ = layerIndex(arch.layer);
}

/// Index of `name` in `layer_table`; edges may only point at earlier rows.
fn layerIndex(comptime name: []const u8) usize {
    inline for (layer_table, 0..) |spec, i| {
        if (comptime std.mem.eql(u8, spec.name, name)) return i;
    }
    @compileError("layer_table has no row named '" ++ name ++ "'");
}

/// Materialize one module per table row, in order, resolving each row's edges
/// against the earlier rows. Every module is position-independent so each
/// static archive (`libpancake_ocapn.a`, the transport archives) links cleanly
/// into a PIE consumer (the Rust C ABI dogfood links a static archive into a
/// position-independent test binary;
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
        // Out-of-graph rows (e.g. `c_abi_net_transport_iroh`) are claimed by arch-check for file
        // coverage and edge liveness but are not DAG participants, they link a
        // non-Zig sidecar and import an injected resident, so `irohAbiModule`
        // mints them. No graph row imports such a row, so the slot stays unread.
        if (!spec.graph) continue;
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

/// One executable over the public `pancake` module, the shape every example,
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

/// A `pancakeExecutable` run from the repository root with side effects, the
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

/// A sibling-step system command that needs the installed archive set and its
/// headers and runs from the repository root with side effects, the shape
/// every cross-language interop and demo orchestrator shares.
fn addInstalledSystemRun(b: *std.Build, argv: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(argv);
    run.step.dependOn(b.getInstallStep());
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    return run;
}

/// One per-binding client row under a `bindings-*` family aggregate.
const BindingClientRow = struct {
    step_name: []const u8,
    description: []const u8,
    argv: []const []const u8,
    /// True when the runner needs a `--` separator before program args
    /// (cargo run forwards trailing args to the example only after one).
    dashdash_before_args: bool = false,
};

/// One per-binding client family: an aggregate step plus its language rows.
const BindingFamily = struct {
    aggregate_name: []const u8,
    aggregate_desc: []const u8,
    needs_iroh_abi: bool,
    rows: []const BindingClientRow,
};

/// Register a `bindings-*` aggregate and every per-binding step under it.
fn addBindingFamily(
    b: *std.Build,
    family: BindingFamily,
    pin_port: ?u16,
    iroh_abi_step: *std.Build.Step,
) void {
    const aggregate = b.step(family.aggregate_name, family.aggregate_desc);
    for (family.rows) |client| {
        const run = addInstalledSystemRun(b, client.argv);
        if (family.needs_iroh_abi) run.step.dependOn(iroh_abi_step);
        if (pin_port) |p| {
            if (client.dashdash_before_args) run.addArg("--");
            run.addArg(b.fmt("--port={d}", .{p}));
        }
        b.step(client.step_name, client.description).dependOn(&run.step);
        aggregate.dependOn(&run.step);
    }
}

/// One relay harness kind: which parameterized proof drives the relay under test.
const RelayHarness = enum { tcp, backpressure, idle, iroh };

/// The harness script, its Deno permissions, and the archives it needs, derived
/// from the harness kind so a row states only its runtime, not its plumbing.
const RelayHarnessSpec = struct {
    script: []const u8,
    perms: []const []const u8,
    needs_wasm: bool,
    needs_iroh_abi: bool,
};

fn relayHarnessSpec(kind: RelayHarness) RelayHarnessSpec {
    return switch (kind) {
        // The browser peer runs the wasm module in-process and dials through the
        // relay over `?to=`.
        .tcp => .{
            .script = "bindings/ts/web/test/relay_tcp_harness.ts",
            .perms = &.{ "--allow-read", "--allow-net", "--allow-run", "--allow-ffi", "--allow-env" },
            .needs_wasm = true,
            .needs_iroh_abi = false,
        },
        // Raw byte flood and a stalled WebSocket client; no wasm peer.
        .backpressure => .{
            .script = "bindings/ts/web/test/relay_backpressure_harness.ts",
            .perms = &.{ "--allow-read", "--allow-net", "--allow-run", "--allow-env" },
            .needs_wasm = false,
            .needs_iroh_abi = false,
        },
        // A silent pair whose idle timer must fire; no wasm peer.
        .idle => .{
            .script = "bindings/ts/web/test/relay_idle_harness.ts",
            .perms = &.{ "--allow-read", "--allow-net", "--allow-run", "--allow-env" },
            .needs_wasm = false,
            .needs_iroh_abi = false,
        },
        // The probe is bundled to a temp file (`--allow-write`) and run against a
        // native iroh host, so the relay's iroh leg needs the iroh ABI companion.
        .iroh => .{
            .script = "bindings/ts/web/test/relay_iroh_harness.ts",
            .perms = &.{ "--allow-read", "--allow-write", "--allow-net", "--allow-run", "--allow-env" },
            .needs_wasm = true,
            .needs_iroh_abi = true,
        },
    };
}

/// One row of the cross-runtime relay matrix: a single (runtime, harness) proof.
/// `step_name` is a literal so `meta-check`'s build-step census sees it.
const RelayRow = struct {
    step_name: []const u8,
    description: []const u8,
    harness: RelayHarness,
    /// Names the greet argument and the scenario messages.
    label: []const u8,
    /// The line the relay prints when listening (`<MARKER> <port>`).
    marker: []const u8,
    /// The relay program and its args, spawned by the harness from the repository
    /// root; the trailing "0" asks for an ephemeral port.
    relay_argv: []const []const u8,
    /// Environment `{key, value}` pairs the harness merges into the relay
    /// subprocess (the idle proof sets a low `PANCAKE_RELAY_IDLE_MS`).
    relay_env: []const [2][]const u8 = &.{},
    /// A build step that must produce the relay program first (Rust's cargo build;
    /// Deno and Python relays are scripts and need none).
    build_dep: ?*std.Build.Step = null,
    /// Point the relay's dynamic loader at `zig-out/lib`, where the iroh transport
    /// archive lives (Rust's iroh relay links it at load time).
    needs_iroh_lib_path: bool = false,
};

/// One relay matrix family: an aggregate step over its (runtime, harness) rows.
const RelayFamily = struct {
    aggregate_name: []const u8,
    aggregate_desc: []const u8,
    rows: []const RelayRow,
};

/// Register a relay matrix family: one aggregate plus every per-row proof. The
/// harness, its permissions, and its build dependencies come from the row's
/// harness kind, so proving a new runtime's relay is a row, never a forked test.
fn addRelayFamily(
    b: *std.Build,
    family: RelayFamily,
    wasm_install: *std.Build.Step,
    iroh_abi_step: *std.Build.Step,
) void {
    const aggregate = b.step(family.aggregate_name, family.aggregate_desc);
    for (family.rows) |row| {
        const spec = relayHarnessSpec(row.harness);
        const run = addInstalledSystemRun(b, &.{ "deno", "run" });
        run.addArgs(spec.perms);
        run.addArg(spec.script);
        run.addArgs(&.{ "--marker", row.marker, "--label", row.label });
        for (row.relay_env) |pair| {
            run.addArgs(&.{ "--env", b.fmt("{s}={s}", .{ pair[0], pair[1] }) });
        }
        if (row.needs_iroh_lib_path) {
            run.addArgs(&.{ "--env", b.fmt("LD_LIBRARY_PATH={s}", .{b.pathFromRoot("zig-out/lib")}) });
        }
        run.addArg("--");
        run.addArgs(row.relay_argv);

        if (spec.needs_wasm) run.step.dependOn(wasm_install);
        if (spec.needs_iroh_abi) run.step.dependOn(iroh_abi_step);
        if (row.build_dep) |dep| run.step.dependOn(dep);

        b.step(row.step_name, row.description).dependOn(&run.step);
        aggregate.dependOn(&run.step);
    }
}

/// The full `src/root.zig` module graph for an arbitrary target, used by the
/// cross-compile gate to type-check the platform backends (notably the
/// macOS/BSD `kqueue` path, which the host io_uring build never compiles)
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
/// CapTP Host (`libpancake_driver`) and the shared `libpancake_ocapn` vocabulary
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
/// declared imports, `{c_abi_shared, c_abi, c_abi_driver}` — followed over
/// `layer_table` edges, then restricted to the `graph = true` rows
/// `graphFromTable` actually builds. The two `graph = false` reached rows
/// (`c_abi_driver` and the wasm root itself) are minted at the use site below,
/// so they stay out of the base graph. Deriving the set from the edges is what
/// lets a new dependency of the wasm surface pull itself in, instead of a
/// hand-kept name list that silently over- or under-includes as edges change.
fn wasmGraphMask() [layer_table.len]bool {
    @setEvalBranchQuota(20000);
    var reached = [_]bool{false} ** layer_table.len;
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
    var mask = [_]bool{false} ** layer_table.len;
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
    // `c_abi_driver` and the `c_abi_wasm` root are graph=false; mint them at this
    // use site the way the transport archives are, wiring the wasm modules above.
    const driver_mod = transportAbiModule(b, t, o, "src/c_abi/driver/mod.zig", &.{
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
        .{ .name = "c_abi_driver", .module = driver_mod },
    });
    const exe = b.addExecutable(.{ .name = "pancake_driver", .root_module = wasm_root });
    // A loadable module, not a command: no `_start`, exports discovered from the
    // `export fn`s (`entry = .disabled`, `rdynamic`). The linker exports linear
    // memory so JS can read/write `ptr + len` across the boundary.
    exe.entry = .disabled;
    exe.rdynamic = true;
    return exe;
}

/// One named import edge for a transport C ABI module.
const AbiImport = struct { name: []const u8, module: *std.Build.Module };

/// A module over a transport's public C ABI root (`src/c_abi/net_transport/<transport>/mod.zig`),
/// the generalization of the iroh companion (ADR-0055) to every transport
/// archive (ADR-0059). Minted fresh per call so the artifact, the hermetic check
/// object, and the header generator can each have their own (no source file
/// lands in two modules of one compilation). `imports` supplies the layer
/// instances the transport draws on, always the shared vocabulary leaf
/// (`c_abi_shared`), never the `c_abi` ocapn root, so the artifact stays
/// symbol-disjoint from `libpancake_ocapn`. These are the `.graph = false`
/// `c_abi_*` rows' only materialization: they sit outside the layer DAG because
/// a transport's injected sidecar resident is not a DAG edge.
fn transportAbiModule(
    b: *std.Build,
    t: std.Build.ResolvedTarget,
    o: std.builtin.OptimizeMode,
    root_source: []const u8,
    imports: []const AbiImport,
) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path(root_source),
        .target = t,
        .optimize = o,
        .pic = true,
    });
    for (imports) |imp| m.addImport(imp.name, imp.module);
    return m;
}

/// Build and install one archive in both static (`.a`) and shared (`.so`) form
/// from `root_module`, stamping the shared library's soname with `version` so a
/// distro can express the ABI contract. Returns the static `Compile` so a C
/// example or test can link the composed set the consumer would.
fn installArchive(
    b: *std.Build,
    name: []const u8,
    root_module: *std.Build.Module,
    version: std.SemanticVersion,
) *std.Build.Step.Compile {
    const static_lib = b.addLibrary(.{ .name = name, .linkage = .static, .root_module = root_module });
    b.installArtifact(static_lib);
    const shared_lib = b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .root_module = root_module,
        .version = version,
    });
    b.installArtifact(shared_lib);
    return static_lib;
}

/// The iroh C ABI module: `transportAbiModule` over
/// `src/c_abi/net_transport/iroh/mod.zig` with the injected `iroh` resident
/// alongside the shared layer instances. The shared vocabulary leaf (not the
/// `c_abi` ocapn root) keeps `libpancake_net_transport_iroh` symbol-disjoint
/// from `libpancake_ocapn`.
fn irohAbiModule(
    b: *std.Build,
    t: std.Build.ResolvedTarget,
    o: std.builtin.OptimizeMode,
    host_mods: []*std.Build.Module,
    resident: *std.Build.Module,
) *std.Build.Module {
    return transportAbiModule(b, t, o, "src/c_abi/net_transport/iroh/mod.zig", &.{
        .{ .name = "model", .module = host_mods[layerIndex("model")] },
        .{ .name = "net", .module = host_mods[layerIndex("net")] },
        .{ .name = "iroh", .module = resident },
        .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
    });
}

/// Link the iroh Rust sidecar staticlib into `mod`, plus the libc and unwind
/// runtime its panic machinery needs (ADR-0055). Every runnable iroh artifact
/// shares this recipe: the drivers and bench, the public C ABI companion, and
/// the iroh-enabled rooms client. The artifact that consumes `mod` must still
/// depend on the `iroh-lib` cargo step so the staticlib exists before the link.
fn linkIrohSidecar(b: *std.Build, mod: *std.Build.Module) void {
    mod.addObjectFile(b.path("transports/iroh/target/release/libpancake_iroh_sidecar.a"));
    mod.link_libc = true;
    mod.linkSystemLibrary("unwind", .{});
}

/// A fresh module over an iroh driver root with the `pancake` and injected
/// `iroh` resident imports, the shape the iroh drivers, the iroh bench, and the
/// iroh-enabled rooms client share. Minted per call so the hermetic
/// compile-only object and the sidecar-linked executable can each root their
/// own (no source file lands in two modules of one compilation). The caller
/// adds `linkIrohSidecar` for a runnable artifact and leaves it off for the
/// hermetic object, whose externs stay unresolved.
fn irohDriverModule(
    b: *std.Build,
    t: std.Build.ResolvedTarget,
    o: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
    resident: *std.Build.Module,
    root_source: []const u8,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root_source),
        .target = t,
        .optimize = o,
    });
    mod.addImport("pancake", lib_mod);
    mod.addImport("iroh", resident);
    return mod;
}

/// The shared Zig interop-driver harness (`interop/_common/zig/harness.zig`),
/// imported as `interop_harness` by every Zig interop executable. Scaffolding
/// like `test/support`, so it sits outside the `src/` layer DAG. The wait
/// vocabulary is `test/support/wait.zig` itself, handed in as `support_wait`
/// so the two scaffolding trees share one owner instead of hand-synced copies.
fn interopHarnessModule(
    b: *std.Build,
    t: std.Build.ResolvedTarget,
    o: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
) *std.Build.Module {
    const wait_mod = b.createModule(.{
        .root_source_file = b.path("test/support/wait.zig"),
        .target = t,
        .optimize = o,
    });
    const mod = b.createModule(.{
        .root_source_file = b.path("interop/_common/zig/harness.zig"),
        .target = t,
        .optimize = o,
    });
    mod.addImport("pancake", lib_mod);
    mod.addImport("support_wait", wait_mod);
    return mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Port pinning for demo and interop steps ──────────────────────────────
    // Every demo orchestrator binds an ephemeral port by default, and every
    // live interop step pins its own fixed port so concurrent steps cannot
    // collide. `-Dport` overrides either choice for one run, to put a demo
    // server on a forwarded port, or to move an interop step off a port that
    // is taken on this machine. `-Dattach` (demo steps only, requires
    // `-Dport`) joins an already-running server on that port instead of
    // spawning one; each orchestrator validates the combination and fails
    // loud, so an unsupported pairing is an error, never a silent ignore.
    const pin_port = b.option(u16, "port", "Pin the listening TCP port for demo and interop steps (default: ephemeral for demos, each step's documented fixed port for interop)");
    const attach = b.option(bool, "attach", "With -Dport: demo orchestrators join an already-running server on that port instead of spawning one") orelse false;
    if (attach and pin_port == null) {
        std.process.fatal("-Dattach requires -Dport: there is no server to join without a port", .{});
    }

    // ── Internal layer modules (ADR-0040, ADR-0048) ─────────────────────────
    // The DAG lives in `layer_table` above; materializing it makes every edge a
    // compiler-checked law, a layer cannot even name a file outside its module
    // root, and a new edge is a visible one-line table diff, not a review note.
    // arch-check consumes the same table, so a granted edge no file imports
    // fails the gate, and only the content bans a module graph cannot express
    // (no `std.Io` / `std.Thread` in core, no platform syscall namespaces in
    // portable code) live as prose checks.
    const host_mods = graphFromTable(b, target, optimize, &layer_table, true);
    const lib_mod = host_mods[layerIndex("pancake")];

    // ── Composable C ABI archives (ADR-0059) ─────────────────────────────────
    // The single umbrella artifact is dropped: each family
    // ships as its own archive linked à la carte, exporting only its
    // `pancake_<family>_*` symbols and sharing core types by header layout.
    // `libpancake_ocapn` (sans-io peer + the shared vocabulary) is the universal
    // base; `libpancake_net` is the inert net-core base (exports nothing under
    // Model A); each transport is a self-contained companion that embeds its
    // lower layers as local symbols (the proven iroh mechanism, generalized).
    // The transport roots are minted by `transportAbiModule` because they sit
    // outside the layer DAG; ocapn and net root on their graph modules.
    const tcp_abi_mod = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/tcp/mod.zig", &.{
        .{ .name = "model", .module = host_mods[layerIndex("model")] },
        .{ .name = "net", .module = host_mods[layerIndex("net")] },
        // The owning `pancake_tcp_session_*` surface drives turns and I/O over a
        // `driver.Session`; an owning session is intrinsically a driver-level
        // concept, so this archive embeds the actor runtime (ADR-0062).
        .{ .name = "driver", .module = host_mods[layerIndex("driver")] },
        .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
    });
    const inproc_abi_mod = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/inproc/mod.zig", &.{
        .{ .name = "net", .module = host_mods[layerIndex("net")] },
        .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
    });
    // `libpancake_driver`: the byte-fed driver tier over the C ABI (ADR-0072).
    // Roots on its own layer module, importing `driver_core` (the sans-io serve
    // core it wraps) and the shared vocabulary leaf, so it exports only
    // `pancake_host_*`.
    const driver_abi_mod = transportAbiModule(b, target, optimize, "src/c_abi/driver/mod.zig", &.{
        .{ .name = "foundation", .module = host_mods[layerIndex("foundation")] },
        .{ .name = "model", .module = host_mods[layerIndex("model")] },
        .{ .name = "engine", .module = host_mods[layerIndex("engine")] },
        .{ .name = "actors", .module = host_mods[layerIndex("actors")] },
        .{ .name = "driver_core", .module = host_mods[layerIndex("driver_core")] },
        .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
    });

    // The static lib of each archive, kept so the C examples can link the
    // composed set the consumer would. `libpancake_ocapn` roots on the `c_abi`
    // (ocapn) layer module directly — the same module the ocapn header generator
    // reflects over — so it exports exactly the sans-io ocapn family and nothing
    // the `pancake` root module would otherwise drag in.
    const ocapn_static = installArchive(b, "pancake_ocapn", host_mods[layerIndex("c_abi")], abi_version);
    // `libpancake_net` roots on the `net` layer module directly: under Model A it
    // is inert (no `export fn`), so the archive exports nothing — that is
    // expected, and it is first-class so the Model-A→B migration never adds an
    // archive to a consumer's link line.
    _ = installArchive(b, "pancake_net", host_mods[layerIndex("net")], abi_version);
    const tcp_static = installArchive(b, "pancake_net_transport_tcp", tcp_abi_mod, abi_version);
    const inproc_static = installArchive(b, "pancake_net_transport_inproc", inproc_abi_mod, abi_version);
    const driver_static = installArchive(b, "pancake_driver", driver_abi_mod, abi_version);

    // Install each archive's public header (the inert net base ships none).
    inline for (archive_table) |arch| {
        if (arch.header) |hdr| {
            if (arch.default_install) {
                const install_hdr = b.addInstallHeaderFile(b.path(b.fmt("include/{s}", .{hdr})), hdr);
                b.getInstallStep().dependOn(&install_hdr.step);
            }
        }
    }

    // ── API reference (autodoc) ──────────────────────────────────────────────
    // Renders the public `pancake` module's generated documentation under
    // zig-out/docs/. The site step ships this same artifact as the API
    // reference section, so the reference can never be hand-written prose. Built
    // from the `pancake` root module but never installed, so the autodoc emit
    // costs nothing on a default `zig build` and no umbrella artifact ships.
    const docs_lib = b.addLibrary(.{
        .name = "pancake",
        .linkage = .static,
        .root_module = lib_mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    // The `docs` step itself is registered with the site steps below, so
    // `check` leads the `zig build -l` listing and the doc-generation steps
    // group together.

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
    // toolchain can run the gate. CI: the GitHub mirror (.github/workflows/)
    // runs `check` and the sibling gates inside the committed devcontainer
    // image via ci/gates.sh; the Codeberg origin's hosted runners cannot
    // build that image, so .forgejo/workflows/ runs the Zig-only checks
    // directly. Each section below wires its gated runs into `check` where
    // the artifacts are built.
    const check_step = b.step("check", "Run the Zig-hermetic correctness and meta-scaffolding gate");

    // ── Tests ────────────────────────────────────────────────────────────────
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("test/all_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addImport("pancake", lib_mod);
    // `c_abi` and `oracle` are not on the public `pancake` namespace (a
    // Zig consumer has no use for either), so their test suites import the
    // layer modules directly.
    tests_mod.addImport("c_abi", host_mods[layerIndex("c_abi")]);
    // The transport C ABI archives are separate modules (ADR-0059); their
    // loopback suites drive them directly, reusing the artifact module instances.
    tests_mod.addImport("c_abi_net_transport_tcp", tcp_abi_mod);
    tests_mod.addImport("c_abi_net_transport_inproc", inproc_abi_mod);
    tests_mod.addImport("c_abi_driver", driver_abi_mod);
    tests_mod.addImport("oracle", host_mods[layerIndex("oracle")]);
    // The persistent-collections leaf module (ADR-0061) is not on the public
    // `pancake` namespace, so its direct test imports the layer module.
    tests_mod.addImport("persistent", host_mods[layerIndex("persistent")]);
    // The header-parity test `@cImport`s the generated headers to prove they
    // agree with the Zig C ABI sources (sizes, offsets, constants), so the two
    // can never silently drift.
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
    // The scenario traces drive the `oracle` layer directly (it is not on the
    // public `pancake` namespace), so the focused gate imports it too.
    oracle_tests_mod.addImport("oracle", host_mods[layerIndex("oracle")]);
    const oracle_tests = b.addTest(.{
        .root_module = oracle_tests_mod,
    });
    const run_oracle_tests = b.addRunArtifact(oracle_tests);
    const oracle_check_step = b.step("oracle-check", "Run the protocol oracle: message-arm coverage, Syrup corpus parity, and whole-conversation scenario traces (test/oracle_check.zig)");
    oracle_check_step.dependOn(&run_oracle_tests.step);
    check_step.dependOn(&run_oracle_tests.step);

    // ── Structure gates ──────────────────────────────────────────────────────
    const arch_check_step_inner = arch_check.create(b, &layer_table);
    const arch_check_step = b.step("arch-check", "Enforce the layer dependency DAG over src/");
    arch_check_step.dependOn(arch_check_step_inner);
    check_step.dependOn(arch_check_step);

    const meta_check_step_inner = meta_check.create(b);

    // Unit tests for the meta gate's own parsers (link/command/Mermaid logic)
    // live in `tools/check/meta_check.zig`. The file is a build-time import, so its
    // `test` blocks only run when compiled as a dedicated test artifact.
    const meta_check_tests_mod = b.createModule(.{
        .root_source_file = b.path("tools/check/meta_check.zig"),
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

    // The browser binding's freestanding wasm32 Host module (ADR-0070): the
    // byte-fed driver tier plus the shared ocapn vocabulary, one loadable
    // `pancake_driver.wasm` under zig-out/wasm/ that a browser instantiates and
    // drives with bytes. Building it also folds the whole browser-binding graph
    // (`c_abi_driver`, `c_abi_wasm`) into `cross-check`, so a wasm regression
    // fails the gate.
    const wasm_driver = wasmDriverExe(b, .ReleaseSmall);
    const wasm_driver_install = b.addInstallArtifact(wasm_driver, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });
    const wasm_driver_step = b.step("wasm-driver", "Build the browser binding's freestanding wasm32 Host module (ADR-0070) into zig-out/wasm/");
    wasm_driver_step.dependOn(&wasm_driver_install.step);
    cross_check_step.dependOn(&wasm_driver.step);

    // Behavioral proof that the wasm32 Host runs real CapTP from JavaScript: two
    // Hosts with distinct identities complete a keyed handshake over an in-memory
    // byte pipe, driven through the wasm exports. A sibling step (needs deno on
    // PATH), not folded into the Zig-hermetic `check`.
    const wasm_driver_test = b.addSystemCommand(&.{ "deno", "run", "--allow-read", "bindings/ts/web/wasm_handshake_smoke.ts" });
    wasm_driver_test.setCwd(b.path("."));
    wasm_driver_test.has_side_effects = true;
    wasm_driver_test.step.dependOn(&wasm_driver_install.step);
    const wasm_driver_test_step = b.step("wasm-driver-test", "Prove the wasm32 Host holds a real keyed CapTP handshake from JS over an in-memory pipe (needs deno; ADR-0070)");
    wasm_driver_test_step.dependOn(&wasm_driver_test.step);

    // The wasm32 layout descriptor (`pancake_wasm_abi_layout`) decodes cleanly:
    // instantiate the module, read the blob, prove it is well formed, and
    // cross-check each struct's field count against the `abi.ts` host mirror. A
    // sibling step (needs deno), not folded into the Zig-hermetic `check`.
    const wasm_abi_layout_check = b.addSystemCommand(&.{ "deno", "run", "--allow-read", "tools/wasm/abi_layout_check.ts" });
    wasm_abi_layout_check.setCwd(b.path("."));
    wasm_abi_layout_check.has_side_effects = true;
    wasm_abi_layout_check.step.dependOn(&wasm_driver_install.step);
    const wasm_abi_layout_check_step = b.step("wasm-abi-layout-check", "Prove the wasm32 Host's layout descriptor (pancake_wasm_abi_layout) decodes cleanly and agrees with the abi.ts field counts (needs deno; ADR-0070)");
    wasm_abi_layout_check_step.dependOn(&wasm_abi_layout_check.step);

    // The ADR-0070 Milestone 1 proof: a browser-shaped peer (the @pancake/web
    // binding: wasm module, linear-memory FFI adapter, WebSocket channel, no
    // dlopen) holds a real keyed OCapN session against a native host that
    // accepts WebSocket, including a host call back into a wasm-hosted object.
    // Needs the wasm module and the native archives (the accepting child is a
    // dlopen host), so it depends on both installs. A sibling step (needs
    // deno), not folded into the Zig-hermetic `check`.
    const web_peer_test = b.addSystemCommand(&.{
        "deno",                                  "run", "--allow-read", "--allow-net", "--allow-run", "--allow-ffi", "--allow-env",
        "bindings/ts/web/test/web_peer_test.ts",
    });
    web_peer_test.setCwd(b.path("."));
    web_peer_test.has_side_effects = true;
    web_peer_test.step.dependOn(&wasm_driver_install.step);
    web_peer_test.step.dependOn(b.getInstallStep());
    const web_peer_test_step = b.step("web-peer-test", "Prove the @pancake/web browser peer holds a keyed OCapN session over WebSocket against a native host (needs deno; ADR-0070 Milestone 1)");
    web_peer_test_step.dependOn(&web_peer_test.step);

    // The cross-runtime relay matrix (`bindings-relay`, `bindings-relay-iroh`) is
    // wired below, after the iroh ABI companion it depends on is defined.

    // The wasm32 Host declares exactly one import — the behavior-dispatch seam
    // `env.pancake_behavior_trampoline` (ADR-0070). Parse the module statically
    // and assert the import set is exactly that one, so an accidental extra
    // import or a rename fails the build. A sibling step (needs deno), not folded
    // into the Zig-hermetic `check`.
    const wasm_import_check = b.addSystemCommand(&.{ "deno", "run", "--allow-read", "tools/wasm/import_check.ts" });
    wasm_import_check.setCwd(b.path("."));
    wasm_import_check.has_side_effects = true;
    wasm_import_check.step.dependOn(&wasm_driver_install.step);
    const wasm_import_check_step = b.step("wasm-import-check", "Prove the wasm32 Host's import set is exactly {env.pancake_behavior_trampoline}, the sole behavior-dispatch seam (needs deno; ADR-0070)");
    wasm_import_check_step.dependOn(&wasm_import_check.step);

    // ── Generated headers / binding mirrors (per archive; ADR-0059) ──────────
    // Each archive's header is generated from its C ABI module (reflected
    // layouts, constant values, and function signatures): the Zig source is the
    // single source of truth. `include/pancake_ocapn.h` carries the shared
    // vocabulary and the peer/uri families. Multi-session CapTP product
    // work uses `pancake_host_*` in `pancake_driver.h`.
    // `include/pancake_net_transport_tcp.h` and `include/pancake_net_transport_inproc.h`
    // `#include` the ocapn header and add their transport family. The `*-check`
    // steps ride `check` and fail when a committed header is stale; the bare
    // steps are the fixers that rewrite in place. Every row drives the shared
    // `tools/gen/verify.zig` / `tools/gen/emit.zig` harness with the concrete
    // generator as `@import("generator")`.
    const HeaderGen = struct {
        check_step_name: []const u8,
        check_desc: []const u8,
        write_step_name: []const u8,
        write_desc: []const u8,
        generator: []const u8,
        import_name: []const u8,
        import_module: *std.Build.Module,
        /// A second reflected module, for a generator that mirrors more than
        /// one archive (the TS mirror covers ocapn and driver).
        extra_import_name: ?[]const u8 = null,
        extra_import_module: ?*std.Build.Module = null,
        /// A third reflected module (FFI layouts also mirror the iroh archive).
        extra2_import_name: ?[]const u8 = null,
        extra2_import_module: ?*std.Build.Module = null,
        /// Fourth and fifth reflected modules (the TS mirror also covers the
        /// tcp and inproc transport archives).
        extra3_import_name: ?[]const u8 = null,
        extra3_import_module: ?*std.Build.Module = null,
        extra4_import_name: ?[]const u8 = null,
        extra4_import_module: ?*std.Build.Module = null,
    };
    const header_gens = [_]HeaderGen{
        .{
            .check_step_name = "gen-header-ocapn-check",
            .check_desc = "Verify include/pancake_ocapn.h matches src/c_abi/ocapn (fails if stale)",
            .write_step_name = "gen-header-ocapn",
            .write_desc = "Regenerate include/pancake_ocapn.h from src/c_abi/ocapn",
            .generator = "tools/gen/header/ocapn.zig",
            .import_name = "c_abi",
            .import_module = host_mods[layerIndex("c_abi")],
        },
        .{
            .check_step_name = "gen-header-driver-check",
            .check_desc = "Verify include/pancake_driver.h matches src/c_abi/driver (fails if stale)",
            .write_step_name = "gen-header-driver",
            .write_desc = "Regenerate include/pancake_driver.h from src/c_abi/driver",
            .generator = "tools/gen/header/driver.zig",
            .import_name = "c_abi_driver",
            .import_module = driver_abi_mod,
        },
        .{
            .check_step_name = "gen-header-net-transport-tcp-check",
            .check_desc = "Verify include/pancake_net_transport_tcp.h matches src/c_abi/net_transport/tcp (fails if stale)",
            .write_step_name = "gen-header-net-transport-tcp",
            .write_desc = "Regenerate include/pancake_net_transport_tcp.h from src/c_abi/net_transport/tcp",
            .generator = "tools/gen/header/net_tcp.zig",
            .import_name = "c_abi_net_transport_tcp",
            .import_module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/tcp/mod.zig", &.{
                .{ .name = "model", .module = host_mods[layerIndex("model")] },
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "driver", .module = host_mods[layerIndex("driver")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }),
        },
        .{
            .check_step_name = "gen-header-net-transport-inproc-check",
            .check_desc = "Verify include/pancake_net_transport_inproc.h matches src/c_abi/net_transport/inproc (fails if stale)",
            .write_step_name = "gen-header-net-transport-inproc",
            .write_desc = "Regenerate include/pancake_net_transport_inproc.h from src/c_abi/net_transport/inproc",
            .generator = "tools/gen/header/net_inproc.zig",
            .import_name = "c_abi_net_transport_inproc",
            .import_module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/inproc/mod.zig", &.{
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }),
        },
        .{
            .check_step_name = "gen-binding-host-action-check",
            .check_desc = "Verify binding HostAction decode/types match src/c_abi/driver (fails if stale)",
            .write_step_name = "gen-binding-host-action",
            .write_desc = "Regenerate binding HostAction decode/types from src/c_abi/driver",
            .generator = "tools/gen/binding/host_action.zig",
            .import_name = "c_abi_driver",
            .import_module = driver_abi_mod,
        },
    };

    const addHeaderGen = struct {
        fn add(bb: *std.Build, check_agg: *std.Build.Step, tgt: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, hg: HeaderGen) void {
            const gen_mod = bb.createModule(.{
                .root_source_file = bb.path(hg.generator),
                .target = tgt,
                .optimize = opt,
            });
            gen_mod.addImport(hg.import_name, hg.import_module);
            if (hg.extra_import_name) |extra| gen_mod.addImport(extra, hg.extra_import_module.?);
            if (hg.extra2_import_name) |extra2| gen_mod.addImport(extra2, hg.extra2_import_module.?);
            if (hg.extra3_import_name) |extra3| gen_mod.addImport(extra3, hg.extra3_import_module.?);
            if (hg.extra4_import_name) |extra4| gen_mod.addImport(extra4, hg.extra4_import_module.?);
            // Available to every generator; iroh header + FFI layouts force-link it
            // so reflection stays cargo-free.
            gen_mod.addImport("iroh_sidecar_stub", bb.createModule(.{
                .root_source_file = bb.path("tools/gen/stub/iroh_sidecar.zig"),
                .target = tgt,
                .optimize = opt,
            }));

            const check_mod = bb.createModule(.{
                .root_source_file = bb.path("tools/gen/verify.zig"),
                .target = tgt,
                .optimize = opt,
            });
            check_mod.addImport("generator", gen_mod);
            const check_exe = bb.addExecutable(.{ .name = hg.check_step_name, .root_module = check_mod });
            const check_run = bb.addRunArtifact(check_exe);
            check_run.setCwd(bb.path("."));
            const check_step_h = bb.step(hg.check_step_name, hg.check_desc);
            check_step_h.dependOn(&check_run.step);
            check_agg.dependOn(check_step_h);

            const write_mod = bb.createModule(.{
                .root_source_file = bb.path("tools/gen/emit.zig"),
                .target = tgt,
                .optimize = opt,
            });
            write_mod.addImport("generator", gen_mod);
            const write_exe = bb.addExecutable(.{ .name = hg.write_step_name, .root_module = write_mod });
            const write_run = bb.addRunArtifact(write_exe);
            write_run.setCwd(bb.path("."));
            write_run.has_side_effects = true;
            const write_step_h = bb.step(hg.write_step_name, hg.write_desc);
            write_step_h.dependOn(&write_run.step);
        }
    }.add;

    for (header_gens) |hg| {
        addHeaderGen(b, check_step, target, optimize, hg);
    }

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
        .{ .name = "pancake-ex-02-introduce-and-redeem", .path = "examples/zig/02_introduce_and_redeem.zig" },
        .{ .name = "pancake-ex-03-actor-far-send", .path = "examples/zig/03_actor_far_send.zig" },
        .{ .name = "pancake-ex-04-look-up-by-name", .path = "examples/zig/04_look_up_by_name.zig" },
        .{ .name = "pancake-ex-05-call-a-remote-method", .path = "examples/zig/05_call_a_remote_method.zig" },
        .{ .name = "pancake-ex-06-pipeline-and-attenuate", .path = "examples/zig/06_pipeline_and_attenuate.zig" },
        .{ .name = "pancake-readme-quick-start", .path = "examples/zig/readme_quick_start.zig" },
        .{ .name = "pancake-dev-frame-view", .path = "examples/zig/frame_view.zig" },
        .{ .name = "pancake-dev-connect-explicit-buffers", .path = "examples/zig/connect_explicit_buffers.zig" },
    };
    for (zig_examples) |ex| {
        const run = b.addRunArtifact(pancakeExecutable(b, lib_mod, target, optimize, ex.name, ex.path));
        examples_step.dependOn(&run.step);
    }

    // C example programs over the per-archive headers, each linking exactly the
    // composed archive set it includes, the same à-la-carte link the documented
    // recipe gives a C consumer (ADR-0059). `compose_transports` links all three
    // and is the standing Model-A symbol-disjoint composition proof.
    const c_examples = [_]struct { name: []const u8, path: []const u8, libs: []const *std.Build.Step.Compile }{
        .{ .name = "pancake-c-frame-view", .path = "examples/c/frame_view.c", .libs = &.{ocapn_static} },
        .{ .name = "pancake-c-context-alloc", .path = "examples/c/context_alloc.c", .libs = &.{ocapn_static} },
        .{ .name = "pancake-c-echo-peer", .path = "examples/c/echo_peer.c", .libs = &.{ ocapn_static, tcp_static } },
        .{ .name = "pancake-c-compose-transports", .path = "examples/c/compose_transports.c", .libs = &.{ ocapn_static, tcp_static, inproc_static } },
        .{ .name = "pancake-c-host-embedder-pump", .path = "examples/c/host_embedder_pump.c", .libs = &.{ ocapn_static, driver_static } },
    };
    for (c_examples) |ex| {
        const c_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
        });
        c_mod.addCSourceFile(.{ .file = b.path(ex.path) });
        c_mod.addIncludePath(b.path("include"));
        for (ex.libs) |lib| c_mod.linkLibrary(lib);
        c_mod.link_libc = true;
        const c_exe = b.addExecutable(.{ .name = ex.name, .root_module = c_mod });
        examples_step.dependOn(&b.addRunArtifact(c_exe).step);
    }

    // ── Benchmarks ───────────────────────────────────────────────────────────
    // Table-driven like the examples: each row builds one executable over
    // `pancake` and registers its public step, whose run forwards
    // `zig build <step> -- <args>`. Each row also gets a dedicated gate run that
    // never sees `b.args`, so `zig build check -- <args>` cannot leak user
    // arguments into the gate; `smoke_on_check` passes `--smoke` on that gate
    // run so the heavier benches prove they still run cheaply, without writing
    // report artifacts into zig-out as a side effect of the gate (the footprint
    // budget itself is gated by test/engine/footprint_budget_test.zig).
    //
    // Optimize mode is per-module: an executable whose root module is
    // ReleaseFast still runs Debug *library* code when it imports the
    // `-Doptimize` graph. Every consumer that claims optimized pancake figures
    // — the `--gate` tripwire runs below and the bench-langs Zig rows — must
    // therefore import this dedicated ReleaseFast graph, never `lib_mod`.
    const fast_lib_mod = graphFromTable(b, target, .ReleaseFast, &layer_table, false)[layerIndex("pancake")];

    // The ReleaseFast wall-clock tripwire (docs/ladder.md rung 2 owns the
    // ceilings). `gate_on_check` replaces a bench's Debug `--smoke` gate run
    // with a ReleaseFast `--gate` run: it proves "still runs" strictly
    // stronger and holds the wall-clock ceiling while it is at it. The
    // ceilings sit roughly an order of magnitude over the measured figures,
    // so only a structural regression — never machine noise — crosses one.
    const perf_check_step = b.step("perf-check", "Gate ReleaseFast wall-clock cost: warm inbound dispatch and the outbound answered-send path against docs/ladder.md rung 2 ceilings, plus the gc-storm linearity ratio (runs under check)");
    const benches = [_]struct {
        step_name: []const u8,
        description: []const u8,
        name: []const u8,
        path: []const u8,
        smoke_on_check: bool = false,
        gate_on_check: bool = false,
        /// The snapshot bench measures the persistent-actor divergence path, so
        /// it imports the persistent-collections leaf module directly, the same
        /// way the test module does; it is not on the public `pancake`
        /// namespace (ADR-0061).
        needs_persistent: bool = false,
    }{
        .{ .step_name = "bench-frame-view", .description = "Run frame/view benchmark", .name = "frame-view-bench", .path = "bench/frame_view_bench.zig" },
        .{ .step_name = "bench-codec", .description = "Run codec/dispatch throughput benchmark", .name = "codec-bench", .path = "bench/codec_bench.zig" },
        .{ .step_name = "bench-dispatch-scaling", .description = "Measure inbound dispatch ns/turn across N peers (cold-cache regime) with p50/p99", .name = "dispatch-scaling-bench", .path = "bench/dispatch_scaling_bench.zig", .gate_on_check = true },
        .{ .step_name = "bench-outbound", .description = "Measure the outbound engine path (send/step/takeOutbound) and the op:gc-answers release storm", .name = "outbound-bench", .path = "bench/outbound_bench.zig", .gate_on_check = true },
        .{ .step_name = "bench-peer-scaling", .description = "Measure per-connection memory footprint and extrapolate to 500k", .name = "peer-scaling-bench", .path = "bench/peer_scaling_bench.zig", .smoke_on_check = true },
        .{ .step_name = "bench-snapshot", .description = "Measure vat snapshot/restore: O(objects), flat in object size, off by default", .name = "snapshot-bench", .path = "bench/snapshot_bench.zig", .smoke_on_check = true, .needs_persistent = true },
    };
    for (benches) |bench| {
        const exe = pancakeExecutable(b, lib_mod, target, optimize, bench.name, bench.path);
        if (bench.needs_persistent) {
            exe.root_module.addImport("persistent", host_mods[layerIndex("persistent")]);
        }
        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        b.step(bench.step_name, bench.description).dependOn(&run.step);

        if (bench.gate_on_check) {
            const gate_exe = pancakeExecutable(b, fast_lib_mod, target, .ReleaseFast, b.fmt("{s}-gate", .{bench.name}), bench.path);
            const gate = b.addRunArtifact(gate_exe);
            gate.addArg("--gate");
            check_step.dependOn(&gate.step);
            perf_check_step.dependOn(&gate.step);
        } else {
            const gate = b.addRunArtifact(exe);
            if (bench.smoke_on_check) gate.addArg("--smoke");
            check_step.dependOn(&gate.step);
        }
    }

    {
        const gen_mod = b.createModule(.{
            .root_source_file = b.path("tools/gen/fixture/capnp.zig"),
            .target = target,
            .optimize = optimize,
        });
        gen_mod.addImport("pancake", lib_mod);
        const handoff_fixtures_mod = b.createModule(.{
            .root_source_file = b.path("test/support/handoff_fixtures.zig"),
            .target = target,
            .optimize = optimize,
        });
        handoff_fixtures_mod.addImport("pancake", lib_mod);
        gen_mod.addImport("handoff_fixtures", handoff_fixtures_mod);
        const gen_exe = b.addExecutable(.{ .name = "capnp-fixture-gen", .root_module = gen_mod });
        const gen_run = b.addRunArtifact(gen_exe);
        gen_run.setCwd(b.path("."));
        gen_run.has_side_effects = true;
        b.step("gen-capnp-fixtures", "Regenerate Cap'n Proto golden fixtures under test/codec/capnp_fixtures/").dependOn(&gen_run.step);
    }

    // ── C ABI dogfoods (siblings of `check`) ─────────────────────────────────
    // Per-language dogfood of the Zig C ABI archives. Each consumer loads the
    // installed archives and drives an OCapN round-trip through its idiomatic
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
            .description = "Run Rust C ABI dogfood tests against the pancake C ABI archives (needs cargo)",
            .argv = &.{ "cargo", "test", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async" },
        },
        .{
            .step_name = "deno-dogfood",
            .description = "Run the Deno C ABI dogfood against the pancake C ABI archives (needs deno)",
            // `--v8-flags=--expose-gc` gives the dogfood a deterministic `gc()` so
            // the ADR-0063 finalizer-GC scenario can force collection and prove a
            // dropped import releases its export.
            .argv = &.{ "deno", "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-env", "--v8-flags=--expose-gc", "bindings/ts/dogfood/zig_smoke.ts" },
        },
        .{
            .step_name = "bun-dogfood",
            .description = "Run the Bun C ABI dogfood against the pancake C ABI archives — same multi-runtime binding as Deno (needs bun)",
            .argv = &.{ "bun", "run", "bindings/ts/dogfood/zig_smoke.ts" },
        },
        .{
            .step_name = "python-dogfood",
            .description = "Run the Python C ABI dogfood against the pancake C ABI archives (needs python3)",
            .argv = &.{ "python3", "bindings/python/zig_smoke.py" },
        },
        .{
            .step_name = "racket-dogfood",
            .description = "Run the Racket C ABI dogfood against the pancake C ABI archives (needs racket)",
            .argv = &.{ "racket", "-y", "bindings/racket/zig-smoke.rkt" },
        },
    };
    var dogfood_runs: [dogfoods.len]*std.Build.Step.Run = undefined;
    for (dogfoods, 0..) |dogfood, i| {
        dogfood_runs[i] = b.addSystemCommand(dogfood.argv);
        dogfood_runs[i].step.dependOn(b.getInstallStep());
        b.step(dogfood.step_name, dogfood.description).dependOn(&dogfood_runs[i].step);
    }
    // The Rust crate's README claims the core stands alone with no feature on;
    // this compile-only leg keeps that claim a gate instead of a sentence (the
    // cfg-gated surface plus the dead-code deny make it the likeliest shape to
    // rot silently).
    const rust_core_only = b.addSystemCommand(&.{
        "cargo", "check", "--manifest-path", "bindings/rust/Cargo.toml", "--no-default-features",
    });
    rust_core_only.step.dependOn(b.getInstallStep());
    dogfood_runs[0].step.dependOn(&rust_core_only.step);
    const bindings_step = b.step("bindings", "Run per-language dogfood of the C ABI (rust, deno, bun, python, racket)");
    for (dogfood_runs) |run| bindings_step.dependOn(&run.step);

    // Pancake-only three-party handoff: pancake is exporter, gifter, and
    // recipient over loopback TCP. A broker introduces a recipient to an
    // exporter's node-giftable object; the recipient transparently redeems the
    // give and messages the exporter *directly*, the broker never relays. Proves
    // the gifter half (ADR-0009) and the engine's swiss re-resolution end to end
    // through the binding, with no Goblins or manual export bookkeeping.
    const run_gifter_handoff = b.addSystemCommand(&.{
        "deno",                                  "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-env",
        "bindings/ts/dogfood/gifter_handoff.ts",
    });
    run_gifter_handoff.step.dependOn(b.getInstallStep());
    b.step("deno-gifter-handoff", "Pancake-only 3-node three-party handoff: a broker introduces a recipient to an exporter, who is then messaged directly (needs deno)")
        .dependOn(&run_gifter_handoff.step);

    // Shared Zig interop-driver harness, one instance for every interop
    // executable below (the goblins/tcp-loop exes here and the iroh drivers).
    const interop_harness_mod = interopHarnessModule(b, target, optimize, lib_mod);

    // ── Live Goblins interop (siblings of `check`) ───────────────────────────
    // Live interop proof against a real Spritely Goblins vat: a pancake peer
    // dials the conformance Goblins host, completes the keyed op:start-session
    // handshake, and bootstrap-fetches its echo cap. Needs `racket` + the
    // `goblins` collection on PATH (like the binding dogfoods), so it is a
    // sibling of `check`, not part of the hermetic gate. The driver spawns and
    // tears down the Goblins vat itself.
    const goblins_interop_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-goblins-interop", "interop/goblins_interop/driver.zig");
    goblins_interop_exe.root_module.addImport("interop_harness", interop_harness_mod);
    const run_goblins_interop = b.addRunArtifact(goblins_interop_exe);
    run_goblins_interop.setCwd(b.path("."));
    run_goblins_interop.has_side_effects = true;
    if (pin_port) |p| run_goblins_interop.addArg(b.fmt("--port={d}", .{p}));
    const goblins_interop_step = b.step("goblins-interop", "Live OCapN conversation vs a real Goblins vat, both directions (needs racket + goblins)");
    goblins_interop_step.dependOn(&run_goblins_interop.step);
    // Running the live conversations needs racket + goblins, but *compiling*
    // their drivers is hermetic: the check gate compiles them so an engine or
    // model API change cannot silently rot a driver nothing ran.
    check_step.dependOn(&goblins_interop_exe.step);

    // Deno binding Host/listen: publish an actor and let a real Goblins vat dial.
    const deno_goblins_listen = addInstalledSystemRun(b, &.{
        "deno",                                          "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run",
        "interop/goblins_interop/deno_listen_client.ts",
    });
    const deno_goblins_listen_step = b.step("deno-goblins-listen", "Live keyed OCapN listen: Deno binding Host/listen publishes and a real Goblins vat dials it (needs deno + racket + goblins)");
    deno_goblins_listen_step.dependOn(&deno_goblins_listen.step);

    // Live TCP scale over the loop-fed host bridge (ADR-0076): one completion
    // loop thread serves a full byte-fed node through `driver.Bridge`,
    // many concurrent BlockingSession clients across two waves. Binds real
    // loopback sockets at scale, so it is a sibling of `check`, port-exclusive
    // like every live step; `check` still compiles it so an API change cannot
    // silently rot it.
    const tcp_loop_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-tcp-loop", "interop/tcp_loop/driver.zig");
    tcp_loop_exe.root_module.addImport("interop_harness", interop_harness_mod);
    const run_tcp_loop = b.addRunArtifact(tcp_loop_exe);
    run_tcp_loop.setCwd(b.path("."));
    run_tcp_loop.has_side_effects = true;
    const tcp_loop_step = b.step("tcp-loop", "Live TCP scale: many concurrent connections served from one loop thread through the Host bridge (ADR-0076)");
    tcp_loop_step.dependOn(&run_tcp_loop.step);
    check_step.dependOn(&tcp_loop_exe.step);

    // Live three-party handoff, pancake as recipient (needs racket + goblins).
    // It runs two Goblins listeners (alice, bob), so `-Dport=N` pins N and N+1.
    const goblins_handoff_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-goblins-handoff", "interop/goblins_interop/handoff_driver.zig");
    goblins_handoff_exe.root_module.addImport("interop_harness", interop_harness_mod);
    const run_goblins_handoff = b.addRunArtifact(goblins_handoff_exe);
    run_goblins_handoff.setCwd(b.path("."));
    run_goblins_handoff.has_side_effects = true;
    check_step.dependOn(&goblins_handoff_exe.step);
    if (pin_port) |p| run_goblins_handoff.addArg(b.fmt("--port={d}", .{p}));
    const goblins_handoff_step = b.step("goblins-handoff", "Live three-party handoff vs Goblins, pancake as recipient (needs racket + goblins)");
    goblins_handoff_step.dependOn(&run_goblins_handoff.step);

    // Live three-party handoff, pancake as gifter (needs racket + goblins).
    // Bob listens on N; Carol binds N+1. `-Dport=N` pins the pair.
    const goblins_gift_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-goblins-gift", "interop/goblins_interop/gift_driver.zig");
    goblins_gift_exe.root_module.addImport("interop_harness", interop_harness_mod);
    const run_goblins_gift = b.addRunArtifact(goblins_gift_exe);
    run_goblins_gift.setCwd(b.path("."));
    run_goblins_gift.has_side_effects = true;
    check_step.dependOn(&goblins_gift_exe.step);
    if (pin_port) |p| run_goblins_gift.addArg(b.fmt("--port={d}", .{p}));
    const goblins_gift_step = b.step("goblins-gift", "Live three-party handoff vs Goblins, pancake as gifter (needs racket + goblins)");
    goblins_gift_step.dependOn(&run_goblins_gift.step);

    // Live distributed-GC evidence vs Goblins: introduce a near export into the
    // suite echo and observe inbound op:gc-exports (needs racket + goblins).
    const goblins_gc_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-goblins-gc", "interop/goblins_interop/gc_driver.zig");
    goblins_gc_exe.root_module.addImport("interop_harness", interop_harness_mod);
    const run_goblins_gc = b.addRunArtifact(goblins_gc_exe);
    run_goblins_gc.setCwd(b.path("."));
    run_goblins_gc.has_side_effects = true;
    check_step.dependOn(&goblins_gc_exe.step);
    if (pin_port) |p| run_goblins_gc.addArg(b.fmt("--port={d}", .{p}));
    const goblins_gc_step = b.step("goblins-gc", "Live Goblins GC evidence: inbound op:gc-exports after echo consumes a near export (needs racket + goblins)");
    goblins_gc_step.dependOn(&run_goblins_gc.step);

    // Per-binding Goblins clients (interop / handoff / gift) register with the
    // shared `binding_families` table after `iroh-abi` below — same emitter as
    // the iroh and keyed-tcp families.

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

    // Per-language consumer-cost benchmark: one fixed native Zig taskboard host,
    // the client language swapped per row (Zig, Rust, Deno, Python, the Racket
    // binding, and Goblins as the reference CapTP peer). It answers "what does a
    // consumer in language X pay to run this app over the same pancake host and
    // wire" — NOT a language leaderboard, and distinct from the substrate
    // comparison above. A sibling of `check`, never gated; the orchestrator
    // spawns and tears down a fresh host per client row. The host and Zig client
    // are always built (and run in whatever `-Doptimize` mode is passed, like the
    // other benches); other rows join when their runtimes are on PATH. Forward
    // `-- <args>` (e.g. `--smoke`, `--client=zig`); `-Dport=N` pins the host port.
    // The orchestrator is itself a native pancake executable — no Racket on the
    // driving path — so the Zig-only smoke runs with nothing else installed.
    // Racket joins only as two client rows (the binding and the Goblins
    // reference), each skipped with a note when its runtime is absent.
    //
    // The host and Zig client are pinned to ReleaseFast regardless of
    // `-Doptimize`, because the Rust row always builds `--release` and the
    // interpreters always run optimized: a fair cross-language comparison needs
    // the Zig rows optimized too, so a plain `zig build bench-langs` is honest
    // without remembering `-Doptimize=ReleaseFast`. The pin only holds through
    // `fast_lib_mod`: optimize mode is per-module, so importing `lib_mod` here
    // would run Debug pancake under a ReleaseFast main. The orchestrator is
    // glue — its own speed never enters a measured number — so it tracks
    // `-Doptimize`.
    const langs_host_exe = pancakeExecutable(b, fast_lib_mod, target, .ReleaseFast, "pancake-langs-host", "bench/langs/host.zig");
    const langs_zig_client_exe = pancakeExecutable(b, fast_lib_mod, target, .ReleaseFast, "pancake-langs-client-zig", "bench/langs/clients/zig_bench.zig");
    const run_bench_langs = addPancakeRun(b, lib_mod, target, optimize, "pancake-langs-orchestrator", "bench/langs/orchestrator.zig");
    // The Deno, Python, and Rust rows link the installed C ABI archives, so the
    // run needs the install step the way the binding dogfoods do.
    run_bench_langs.step.dependOn(b.getInstallStep());
    run_bench_langs.addArtifactArg(langs_host_exe);
    run_bench_langs.addArtifactArg(langs_zig_client_exe);
    if (pin_port) |p| run_bench_langs.addArg(b.fmt("--port={d}", .{p}));
    if (b.args) |args| run_bench_langs.addArgs(args);
    b.step("bench-langs", "Per-language consumer-cost benchmark: fixed Zig host, swap client (Zig always; joins deno/python3/cargo/racket+goblins when present)")
        .dependOn(&run_bench_langs.step);

    // The langs host and Zig client consume the same driver API as any consumer,
    // but they only compile inside the ReleaseFast `bench-langs` sibling of
    // `check`, so an API change can rot them unnoticed (a missing `.give` arm, a
    // Connection `close` that became `deinit`). Compile them under `check`,
    // compile-only with no run and no cross-language runtime, so the gate catches
    // that rot the same way it catches an example that stops compiling.
    check_step.dependOn(&langs_host_exe.step);
    check_step.dependOn(&langs_zig_client_exe.step);

    // Regenerate the performance page's charts and tables from live ReleaseFast
    // runs of every bench (codec, peer-scaling, frame-view) plus the Goblins
    // comparison, splicing the results into site/content/performance.smd between
    // `<!-- bench:<name> -->` markers, the gen-header pattern, applied to docs.
    // Needs `racket` + `goblins`, so it is a sibling of `check`, never gated:
    // bench numbers are a dated snapshot of one machine, not an invariant.
    const run_site_report = addInstalledSystemRun(b, &.{ "racket", "bench/site_report.rkt" });
    b.step("bench-site-report", "Regenerate the performance page's benchmark reports from live runs (needs racket + goblins)")
        .dependOn(&run_site_report.step);

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

    // The sidecar's own Rust unit tests, chief among them the positive-fire proof
    // that a caller-set connect timeout trips fast against a bound-but-silent UDP
    // black hole. Needs cargo, so it is a sibling step like `iroh-lib`.
    const iroh_sidecar_test = b.addSystemCommand(&.{
        "cargo", "test", "--release", "--manifest-path", "transports/iroh/Cargo.toml",
    });
    const iroh_sidecar_test_step = b.step("iroh-sidecar-test", "Run the iroh sidecar Rust unit tests, including the connect-timeout positive-fire proof (needs cargo)");
    iroh_sidecar_test_step.dependOn(&iroh_sidecar_test.step);

    // The resident compiles as its own module over the same layer-module
    // instances, *outside* the `pancake` root namespace: its externs resolve
    // only when the staticlib links, and the api-surface test references every
    // exported `pancake` declaration recursively, exporting it would drag the
    // Rust sidecar into every gate.
    const iroh_resident_mod = b.createModule(.{
        .root_source_file = b.path("src/net/transport/iroh.zig"),
        .target = target,
        .optimize = optimize,
    });
    iroh_resident_mod.addImport("foundation", host_mods[layerIndex("foundation")]);
    iroh_resident_mod.addImport("model", host_mods[layerIndex("model")]);
    iroh_resident_mod.addImport("engine", host_mods[layerIndex("engine")]);
    iroh_resident_mod.addImport("net", host_mods[layerIndex("net")]);
    // CapTP serving for the scale path is `driver.Bridge` + `driver_core.Host`
    // in the interop drivers; the resident only supplies the netlayer and the
    // completion `Backend` (ADR-0076).

    // The iroh driver family, table-driven. Each row is both a runnable sibling
    // of `check` (linking the sidecar through `linkIrohSidecar`, so it needs
    // cargo) and a hermetic compile-only object that rides `check`: *compiling*
    // a driver's Zig is cargo-free because externs stay unresolved and nothing
    // links, so a core or model API change cannot silently rot a driver only the
    // cargo-gated steps run. Per-row posture:
    //   iroh-interop  — live encrypted conversation, two pancake peers over real
    //                   iroh endpoints, dialed by id with direct-address hints.
    //   iroh-reachability — Milestone 1: dial by node id alone over n0's public
    //                   relays and DNS/pkarr discovery, no hints. Touches public
    //                   discovery infrastructure with propagation timing, so it
    //                   is opt-in and never a hermetic gate.
    //   iroh-mesh     — Milestone 2: a three-party handoff, A introduces B to C
    //                   and B reaches C by the gifted node id. Deterministic
    //                   (in-process discovery book).
    //   iroh-loop     — Milestone 3 (ADR-0057): many concurrent connections
    //                   served from one thread through the event-driven sidecar
    //                   superset. Deterministic.
    //   iroh-bridge-redeem — ADR-0076: recipient on Loop(iroh.Backend, iroh.DialResolver) redeems
    //                   a handoff via Loop.dialLocator. Deterministic.
    //   bench-iroh    — round-trip latency/throughput over real keyed QUIC vs a
    //                   same-machine cleartext TCP baseline; reports numbers,
    //                   gates none, and forwards `-- <args>`. `bench-site-report`
    //                   runs it to refresh the performance page.
    const iroh_drivers = [_]struct {
        step_name: []const u8,
        description: []const u8,
        exe_name: []const u8,
        root_source: []const u8,
        forwards_args: bool = false,
    }{
        .{ .step_name = "iroh-interop", .description = "Live encrypted OCapN conversation: two pancake peers over real iroh endpoints (needs cargo)", .exe_name = "pancake-iroh-interop", .root_source = "interop/iroh_interop/driver.zig" },
        .{ .step_name = "iroh-reachability", .description = "Live real-internet dial-by-id over n0 relays + DNS/pkarr discovery (opt-in; needs cargo + internet)", .exe_name = "pancake-iroh-reachability", .root_source = "interop/iroh_reachability/driver.zig" },
        .{ .step_name = "iroh-mesh", .description = "Live three-party handoff over iroh: recipient reaches the introduced exporter by node id (needs cargo)", .exe_name = "pancake-iroh-mesh", .root_source = "interop/iroh_mesh/driver.zig" },
        .{ .step_name = "iroh-loop", .description = "Live iroh scale: many concurrent connections served from one loop thread (ADR-0057; needs cargo)", .exe_name = "pancake-iroh-loop", .root_source = "interop/iroh_loop/driver.zig" },
        .{ .step_name = "iroh-bridge-redeem", .description = "Live iroh redeem dial on driver.Bridge: recipient on one loop thread redeems a handoff via Loop.dialLocator (ADR-0076; needs cargo)", .exe_name = "pancake-iroh-bridge-redeem", .root_source = "interop/iroh_bridge_redeem/driver.zig" },
        .{ .step_name = "bench-iroh", .description = "Measure OCapN round-trip latency/throughput over iroh vs a TCP baseline (needs cargo)", .exe_name = "pancake-iroh-bench", .root_source = "bench/iroh_bench.zig", .forwards_args = true },
    };
    for (iroh_drivers) |drv| {
        // Hermetic compile-only object (no sidecar), rides `check`.
        const compile_mod = irohDriverModule(b, target, optimize, lib_mod, iroh_resident_mod, drv.root_source);
        compile_mod.addImport("interop_harness", interop_harness_mod);
        const compile_obj = b.addObject(.{ .name = b.fmt("{s}-compile", .{drv.exe_name}), .root_module = compile_mod });
        check_step.dependOn(&compile_obj.step);

        // Runnable sibling of `check`: links the sidecar and runs from the root.
        const run_mod = irohDriverModule(b, target, optimize, lib_mod, iroh_resident_mod, drv.root_source);
        run_mod.addImport("interop_harness", interop_harness_mod);
        linkIrohSidecar(b, run_mod);
        const exe = b.addExecutable(.{ .name = drv.exe_name, .root_module = run_mod });
        exe.step.dependOn(&iroh_lib.step);
        const run = b.addRunArtifact(exe);
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        if (drv.forwards_args) {
            if (b.args) |args| run.addArgs(args);
        }
        b.step(drv.step_name, drv.description).dependOn(&run.step);
    }

    // Hermetic type-check of the resident: compile it to an object, where its
    // externs need no definition, so plain `zig build check` catches resident
    // rot without cargo on PATH. Linking and running stay in `iroh-interop`.
    const iroh_resident_check = b.addObject(.{
        .name = "iroh-resident-check",
        .root_module = iroh_resident_mod,
    });
    check_step.dependOn(&iroh_resident_check.step);

    // ── iroh public C ABI (separate artifact; ADR-0055) ──────────────────────
    // `src/c_abi/net_transport/iroh/mod.zig` is the iroh transport's public C ABI. It ships as
    // its own library, `libpancake_net_transport_iroh`, because it links the Rust
    // sidecar and so cannot fold into the pure-Zig archives. The artifact is a
    // companion, not a superset: it exports only `pancake_iroh_*` and shares the
    // base ABI by layout, so a binding loads `libpancake_ocapn` for the
    // peer-driving surface and this library for the transport. Building and
    // running it needs cargo, so it is a sibling of `check`, the same posture as
    // `iroh-interop`.
    const iroh_abi_link_mod = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod);
    linkIrohSidecar(b, iroh_abi_link_mod);
    const iroh_abi_shared = b.addLibrary(.{
        .name = "pancake_net_transport_iroh",
        .linkage = .dynamic,
        .root_module = iroh_abi_link_mod,
        .version = abi_version,
    });
    iroh_abi_shared.step.dependOn(&iroh_lib.step);
    const iroh_abi_install = b.addInstallArtifact(iroh_abi_shared, .{});
    const iroh_abi_header_install = b.addInstallHeaderFile(b.path("include/pancake_net_transport_iroh.h"), "pancake_net_transport_iroh.h");
    const iroh_abi_step = b.step("iroh-abi", "Build libpancake_net_transport_iroh, the iroh transport's public C ABI companion (needs cargo)");
    iroh_abi_step.dependOn(&iroh_abi_install.step);
    iroh_abi_step.dependOn(&iroh_abi_header_install.step);

    // The cross-runtime relay matrix (ADR-0086). One shared harness per proof —
    // TCP forwarding, the non-optional backpressure clause, and the iroh leg —
    // runs against every runtime's relay: the Deno reference relay
    // (`bindings/ts/relay/serve.ts`), the Python relay (`bindings/python/relay.py`,
    // WebSocket server via `uv run --with websockets`), and the Rust relay
    // (`bindings/rust/relay`, tokio-tungstenite). A runtime is a row, never a fork,
    // so no binding can silently lack a proof.
    //
    // The Rust relay builds twice: archive-free for the TCP and backpressure legs,
    // and with `--features iroh` (linking the iroh binding) for the iroh leg. Deno
    // and Python relays are single scripts that serve every leg.
    const rust_relay_build = b.addSystemCommand(&.{
        "cargo", "build", "--release", "--manifest-path", "bindings/rust/relay/Cargo.toml",
    });
    const rust_relay_iroh_build = b.addSystemCommand(&.{
        "cargo", "build", "--release", "--features", "iroh", "--manifest-path", "bindings/rust/relay/Cargo.toml",
    });
    rust_relay_iroh_build.step.dependOn(iroh_abi_step);
    rust_relay_iroh_build.step.dependOn(b.getInstallStep());

    const deno_relay_tcp = [_][]const u8{ "deno", "run", "--allow-net", "--allow-read", "--allow-env", "bindings/ts/relay/serve.ts", "0" };
    const deno_relay_iroh = [_][]const u8{ "deno", "run", "--allow-net", "--allow-read", "--allow-ffi", "--unstable-ffi", "--allow-env", "bindings/ts/relay/serve.ts", "0" };
    const python_relay = [_][]const u8{ "uv", "run", "--with", "websockets", "python3", "bindings/python/relay.py", "0" };
    const rust_relay = [_][]const u8{ "bindings/rust/relay/target/release/pancake-relay", "0" };

    // The core contract: byte-transparent TCP forwarding and the backpressure
    // clause, across every runtime's relay.
    addRelayFamily(b, .{
        .aggregate_name = "bindings-relay",
        .aggregate_desc = "Prove the byte-transparent relay contract (TCP forwarding + backpressure + the idle-timeout bounded-resources clause) across every runtime's relay: Deno, Python, Rust (needs deno + uv + cargo)",
        .rows = &.{
            .{ .step_name = "deno-relay-test", .description = "Prove a browser peer holds a keyed session through the Deno reference relay (needs deno)", .harness = .tcp, .label = "Deno", .marker = "DENO-RELAY-READY", .relay_argv = &deno_relay_tcp },
            .{ .step_name = "python-relay-test", .description = "Prove a browser peer holds a keyed session through the Python relay (needs deno + uv)", .harness = .tcp, .label = "Python", .marker = "PYTHON-RELAY-READY", .relay_argv = &python_relay },
            .{ .step_name = "rust-relay-test", .description = "Prove a browser peer holds a keyed session through the Rust relay (needs deno + cargo)", .harness = .tcp, .label = "Rust", .marker = "RUST-RELAY-READY", .relay_argv = &rust_relay, .build_dep = &rust_relay_build.step },
            .{ .step_name = "deno-relay-backpressure-test", .description = "Prove a stalled reader backpressures the far sender through the Deno relay (needs deno)", .harness = .backpressure, .label = "Deno", .marker = "DENO-RELAY-READY", .relay_argv = &deno_relay_tcp },
            .{ .step_name = "python-relay-backpressure-test", .description = "Prove a stalled reader backpressures the far sender through the Python relay (needs deno + uv)", .harness = .backpressure, .label = "Python", .marker = "PYTHON-RELAY-READY", .relay_argv = &python_relay },
            .{ .step_name = "rust-relay-backpressure-test", .description = "Prove a stalled reader backpressures the far sender through the Rust relay (needs deno + cargo)", .harness = .backpressure, .label = "Rust", .marker = "RUST-RELAY-READY", .relay_argv = &rust_relay, .build_dep = &rust_relay_build.step },
            .{ .step_name = "deno-relay-idle-test", .description = "Prove the Deno relay reclaims an idle session (the bounded-resources clause) (needs deno)", .harness = .idle, .label = "Deno", .marker = "DENO-RELAY-READY", .relay_argv = &deno_relay_tcp, .relay_env = &.{.{ "PANCAKE_RELAY_IDLE_MS", "500" }} },
            .{ .step_name = "python-relay-idle-test", .description = "Prove the Python relay reclaims an idle session (the bounded-resources clause) (needs deno + uv)", .harness = .idle, .label = "Python", .marker = "PYTHON-RELAY-READY", .relay_argv = &python_relay, .relay_env = &.{.{ "PANCAKE_RELAY_IDLE_MS", "500" }} },
            .{ .step_name = "rust-relay-idle-test", .description = "Prove the Rust relay reclaims an idle session (the bounded-resources clause) (needs deno + cargo)", .harness = .idle, .label = "Rust", .marker = "RUST-RELAY-READY", .relay_argv = &rust_relay, .build_dep = &rust_relay_build.step, .relay_env = &.{.{ "PANCAKE_RELAY_IDLE_MS", "500" }} },
        },
    }, &wasm_driver_install.step, iroh_abi_step);

    // The iroh leg: each runtime's relay dials a real iroh endpoint over QUIC and
    // carries the browser peer's live session through it. The browser probe is
    // bundled with the browser mapping so @pancake/iroh resolves to its browser arm.
    addRelayFamily(b, .{
        .aggregate_name = "bindings-relay-iroh",
        .aggregate_desc = "Prove the relay's iroh leg across every runtime's relay: a browser peer holds a live iroh session through Deno, Python, Rust relays (needs deno + uv + cargo)",
        .rows = &.{
            .{ .step_name = "deno-relay-iroh-test", .description = "Prove a browser peer holds a live iroh session through the Deno reference relay (needs deno + cargo)", .harness = .iroh, .label = "Deno", .marker = "DENO-RELAY-READY", .relay_argv = &deno_relay_iroh },
            .{ .step_name = "python-relay-iroh-test", .description = "Prove a browser peer holds a live iroh session through the Python relay (needs deno + uv + cargo)", .harness = .iroh, .label = "Python", .marker = "PYTHON-RELAY-READY", .relay_argv = &python_relay },
            .{ .step_name = "rust-relay-iroh-test", .description = "Prove a browser peer holds a live iroh session through the Rust relay (needs deno + cargo)", .harness = .iroh, .label = "Rust", .marker = "RUST-RELAY-READY", .relay_argv = &rust_relay, .build_dep = &rust_relay_iroh_build.step, .needs_iroh_lib_path = true },
        },
    }, &wasm_driver_install.step, iroh_abi_step);

    // ── release packaging ────────────────────────────────────────────────────
    // Stage the complete installed archive set — the pure-Zig archives plus the
    // iroh companion — with the headers and licenses into one versioned,
    // checksummed tarball under `zig-out/release/`, named by `abi_version` and
    // the host target triple. `.github/workflows/release.yml` runs this per
    // platform on a version tag and attaches the tarballs to the release, the
    // hosted upstream the bindings' find leg resolves against.
    const release_tarball = b.fmt(
        "pancake-c-v{d}.{d}.{d}-{s}-{s}.tar.gz",
        .{
            abi_version.major,                abi_version.minor,              abi_version.patch,
            @tagName(target.result.cpu.arch), @tagName(target.result.os.tag),
        },
    );
    const release_pack_run = addInstalledSystemRun(b, &.{
        "sh", "-ec",
        b.fmt(
            \\rm -rf zig-out/release
            \\mkdir -p zig-out/release/stage
            \\# Dereference soname symlinks so the tarball has only regular files
            \\# (ADR-0077 extract hygiene refuses symlink members).
            \\cp -aL zig-out/lib zig-out/include zig-out/release/stage/
            \\if [ -d zig-out/bin ]; then cp -aL zig-out/bin zig-out/release/stage/; fi
            \\if find zig-out/release/stage/lib \( -type l -o -type b -o -type c \) 2>/dev/null | grep -q .; then
            \\  echo 'release-pack: lib/ must contain only regular files and directories (no symlinks/special files)' >&2
            \\  exit 1
            \\fi
            \\cp LICENSE-APACHE zig-out/release/stage/
            \\tar -czf 'zig-out/release/{s}' -C zig-out/release/stage lib include bin LICENSE-APACHE 2>/dev/null || tar -czf 'zig-out/release/{s}' -C zig-out/release/stage lib include LICENSE-APACHE
            \\rm -rf zig-out/release/stage
            \\cd zig-out/release
            \\(sha256sum '{s}' || shasum -a 256 '{s}') > SHA256SUMS
            \\echo 'release-pack: zig-out/release/{s}'
        , .{ release_tarball, release_tarball, release_tarball, release_tarball, release_tarball }),
    });
    release_pack_run.step.dependOn(b.getInstallStep());
    release_pack_run.step.dependOn(iroh_abi_step);
    const release_pack_step = b.step("release-pack", "Stage the installed archives + headers (+ bin/pancake and rooms-peer shim) into a versioned, checksummed per-target tarball under zig-out/release/ (needs cargo for the iroh companion)");
    release_pack_step.dependOn(&release_pack_run.step);

    // ── Per-binding client families ──────────────────────────────────────────
    // One emitter over every `bindings-*` aggregate: Goblins interop/handoff/gift,
    // iroh loop/handoff/redeem/reachability, and keyed-tcp restart. Row order is
    // deno → python → rust → racket wherever a language is present. Native
    // one-offs (`goblins-interop`, `goblins-handoff`, `tcp-loop`) stay above —
    // they are Zig drivers, not binding clients.

    // Each binding drives the same keyed conversation against a real Goblins
    // vat through the installed C ABI archives. Every entry needs `racket` + the
    // `goblins` collection on PATH plus its own runtime; each script spawns and
    // tears down the Goblins vat itself. The Rust entry runs a feature-gated
    // tokio example, so it needs the async feature.
    const goblins_interop_clients = [_]BindingClientRow{
        .{
            .step_name = "deno-goblins-interop",
            .description = "Live keyed OCapN conversation: Deno binding vs a real Goblins vat (needs deno + racket + goblins)",
            .argv = &.{ "deno", "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "interop/goblins_interop/deno_client.ts" },
        },
        .{
            .step_name = "python-goblins-interop",
            .description = "Live keyed OCapN conversation: Python binding vs a real Goblins vat (needs python3 + racket + goblins)",
            .argv = &.{ "python3", "interop/goblins_interop/python_client.py" },
        },
        .{
            .step_name = "rust-goblins-interop",
            .description = "Live keyed OCapN conversation: Rust binding vs a real Goblins vat (needs cargo + racket + goblins)",
            .argv = &.{ "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async", "--example", "rust_client" },
            .dashdash_before_args = true,
        },
        .{
            .step_name = "racket-goblins-interop",
            .description = "Live keyed OCapN conversation: Racket binding vs a real Goblins vat (needs racket + goblins)",
            .argv = &.{ "racket", "-y", "interop/goblins_interop/racket_client.rkt" },
        },
    };

    // Binding as recipient: redeems a `desc:handoff-give` from a real Goblins
    // introducer, then calls the exporter directly. Counterpart of the Zig
    // `goblins-handoff` driver. `-Dport=N` pins the introducer (exporter on N+1).
    const goblins_handoff_clients = [_]BindingClientRow{
        .{
            .step_name = "deno-goblins-handoff",
            .description = "Live three-party handoff: the Deno binding redeems a give from a real Goblins introducer and calls the exporter (needs deno + racket + goblins)",
            .argv = &.{ "deno", "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "interop/goblins_interop/deno_handoff_client.ts" },
        },
        .{
            .step_name = "python-goblins-handoff",
            .description = "Live three-party handoff: the Python binding redeems a give from a real Goblins introducer and calls the exporter (needs python3 + racket + goblins)",
            .argv = &.{ "python3", "interop/goblins_interop/python_handoff_client.py" },
        },
        .{
            .step_name = "rust-goblins-handoff",
            .description = "Live three-party handoff: the Rust binding redeems a give from a real Goblins introducer and calls the exporter (needs cargo + racket + goblins)",
            .argv = &.{ "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async", "--example", "rust_handoff_client" },
            .dashdash_before_args = true,
        },
        .{
            .step_name = "racket-goblins-handoff",
            .description = "Live three-party handoff: the Racket binding redeems a give from a real Goblins introducer and calls the exporter (needs racket + goblins)",
            .argv = &.{ "racket", "-y", "interop/goblins_interop/racket_handoff_client.rkt" },
        },
    };

    // Binding as gifter: mints a give a real Goblins recipient redeems. Proves
    // the exporter half of ADR-0009. `-Dport=N` pins the exporter (recipient on
    // N+1; gifter takes an ephemeral port). Deno needs `--allow-env`.
    const goblins_gift_clients = [_]BindingClientRow{
        .{
            .step_name = "deno-goblins-gift",
            .description = "Live three-party handoff: the Deno binding mints a give a real Goblins recipient redeems, reaching the exporter (needs deno + racket + goblins)",
            .argv = &.{ "deno", "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "--allow-env", "interop/goblins_interop/deno_gift_client.ts" },
        },
        .{
            .step_name = "python-goblins-gift",
            .description = "Live three-party handoff: the Python binding mints a give a real Goblins recipient redeems, reaching the exporter (needs python3 + racket + goblins)",
            .argv = &.{ "python3", "interop/goblins_interop/python_gift_client.py" },
        },
        .{
            .step_name = "rust-goblins-gift",
            .description = "Live three-party handoff: the Rust binding mints a give a real Goblins recipient redeems, reaching the exporter (needs cargo + racket + goblins)",
            .argv = &.{ "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async", "--example", "rust_gift_client" },
            .dashdash_before_args = true,
        },
        .{
            .step_name = "racket-goblins-gift",
            .description = "Live three-party handoff: the Racket binding mints a give a real Goblins recipient redeems, reaching the exporter (needs racket + goblins)",
            .argv = &.{ "racket", "-y", "interop/goblins_interop/racket_gift_client.rkt" },
        },
    };

    // Binding sibling of `iroh-loop`: many concurrent connections from one
    // readiness loop through the iroh C ABI (ADR-0057).
    const iroh_loop_clients = [_]BindingClientRow{
        .{
            .step_name = "deno-iroh-loop",
            .description = "Live iroh scale: the Deno binding serves many connections from one readiness loop (ADR-0057; needs cargo + deno)",
            .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "interop/iroh_loop/deno_client.ts" },
        },
        .{
            .step_name = "python-iroh-loop",
            .description = "Live iroh scale: the Python binding serves many connections from one readiness loop (ADR-0057; needs cargo + python3)",
            .argv = &.{ "python3", "interop/iroh_loop/python_client.py" },
        },
        .{
            .step_name = "rust-iroh-loop",
            .description = "Live iroh scale: the Rust binding serves many connections from one readiness loop (ADR-0057; needs cargo)",
            .argv = &.{ "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "iroh", "--example", "iroh_loop" },
            .dashdash_before_args = true,
        },
        .{
            .step_name = "racket-iroh-loop",
            .description = "Live iroh scale: the Racket binding serves many connections from one readiness loop (ADR-0057; needs cargo + racket)",
            .argv = &.{ "racket", "-y", "interop/iroh_loop/racket_client.rkt" },
        },
    };

    // Binding sibling of demo-rooms-dm-iroh: mint + redeem an iroh handoff give
    // in one process (relay-less Direct posture). Deterministic, flake-free.
    const iroh_handoff_clients = [_]BindingClientRow{
        .{
            .step_name = "deno-iroh-handoff",
            .description = "Three-party handoff over iroh: the Deno binding mints and redeems an iroh handoff give in one process (needs cargo + deno)",
            .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "interop/iroh_handoff/deno_client.ts" },
        },
        .{
            .step_name = "python-iroh-handoff",
            .description = "Three-party handoff over iroh: the Python binding mints and redeems an iroh handoff give in one process (needs cargo + python3)",
            .argv = &.{ "python3", "interop/iroh_handoff/python_client.py" },
        },
        .{
            .step_name = "rust-iroh-handoff",
            .description = "Three-party handoff over iroh: the Rust binding mints and redeems an iroh handoff give in one process (needs cargo)",
            .argv = &.{ "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "iroh", "--example", "iroh_handoff" },
            .dashdash_before_args = true,
        },
        .{
            .step_name = "racket-iroh-handoff",
            .description = "Three-party handoff over iroh: the Racket binding mints and redeems an iroh handoff give in one process (needs cargo + racket)",
            .argv = &.{ "racket", "-y", "interop/iroh_handoff/racket_client.rkt" },
        },
    };

    // Hermetic proof that configured redeem posture governs a hint-less iroh
    // give (node id alone, in-process address book). Flake-free like handoff.
    const iroh_redeem_clients = [_]BindingClientRow{
        .{
            .step_name = "deno-iroh-redeem-posture",
            .description = "Hermetic configured-redeem-posture proof for a hint-less iroh give: the Deno binding (needs cargo + deno)",
            .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "interop/iroh_redeem_posture/deno_client.ts" },
        },
        .{
            .step_name = "python-iroh-redeem-posture",
            .description = "Hermetic configured-redeem-posture proof for a hint-less iroh give: the Python binding (needs cargo + python3)",
            .argv = &.{ "python3", "interop/iroh_redeem_posture/python_client.py" },
        },
        .{
            .step_name = "rust-iroh-redeem-posture",
            .description = "Hermetic configured-redeem-posture proof for a hint-less iroh give: the Rust binding (needs cargo)",
            .argv = &.{ "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "iroh", "--example", "iroh_redeem_posture" },
            .dashdash_before_args = true,
        },
        .{
            .step_name = "racket-iroh-redeem-posture",
            .description = "Hermetic configured-redeem-posture proof for a hint-less iroh give: the Racket binding (needs cargo + racket)",
            .argv = &.{ "racket", "-y", "interop/iroh_redeem_posture/racket_client.rkt" },
        },
    };

    // Keyed-tcp restart proof (ADR-0075): happy path, squatter refusal, same-
    // seed fresh-port restart. No iroh companion needed.
    const keyed_tcp_restart_clients = [_]BindingClientRow{
        .{
            .step_name = "deno-keyed-tcp-restart",
            .description = "Keyed-tcp restart proof: the Deno binding (happy, squatter, restart)",
            .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "interop/keyed_tcp_restart/deno_client.ts" },
        },
        .{
            .step_name = "python-keyed-tcp-restart",
            .description = "Keyed-tcp restart proof: the Python binding (happy, squatter, restart)",
            .argv = &.{ "python3", "interop/keyed_tcp_restart/python_client.py" },
        },
        .{
            .step_name = "rust-keyed-tcp-restart",
            .description = "Keyed-tcp restart proof: the Rust binding (happy, squatter, restart; needs cargo)",
            .argv = &.{ "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async", "--example", "keyed_tcp_restart" },
            .dashdash_before_args = true,
        },
        .{
            .step_name = "racket-keyed-tcp-restart",
            .description = "Keyed-tcp restart proof: the Racket binding (happy, squatter, restart; needs racket)",
            .argv = &.{ "racket", "-y", "interop/keyed_tcp_restart/racket_client.rkt" },
        },
    };

    // Opt-in live dial-by-id over n0 relays + DNS/pkarr. Touches public infra;
    // never part of `check`. Offline dial-by-id is `local_discovery` in *-iroh-loop.
    const iroh_reach_clients = [_]BindingClientRow{
        .{
            .step_name = "deno-iroh-reachability",
            .description = "Live dial-by-id over n0 relays + DNS/pkarr discovery: the Deno binding (opt-in; needs cargo + deno + internet)",
            .argv = &.{ "deno", "run", "-A", "--unstable-ffi", "interop/iroh_reachability/deno_client.ts" },
        },
        .{
            .step_name = "python-iroh-reachability",
            .description = "Live dial-by-id over n0 relays + DNS/pkarr discovery: the Python binding (opt-in; needs cargo + python3 + internet)",
            .argv = &.{ "python3", "interop/iroh_reachability/python_client.py" },
        },
        .{
            .step_name = "rust-iroh-reachability",
            .description = "Live dial-by-id over n0 relays + DNS/pkarr discovery: the Rust binding (opt-in; needs cargo + internet)",
            .argv = &.{ "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "iroh", "--example", "iroh_reachability" },
            .dashdash_before_args = true,
        },
        .{
            .step_name = "racket-iroh-reachability",
            .description = "Live dial-by-id over n0 relays + DNS/pkarr discovery: the Racket binding (opt-in; needs cargo + racket + internet)",
            .argv = &.{ "racket", "-y", "interop/iroh_reachability/racket_client.rkt" },
        },
    };

    const binding_families = [_]BindingFamily{
        .{
            .aggregate_name = "bindings-goblins-interop",
            .aggregate_desc = "Per-binding live keyed conversation vs a real Goblins vat, every binding (needs racket + goblins + the runtimes)",
            .needs_iroh_abi = false,
            .rows = &goblins_interop_clients,
        },
        .{
            .aggregate_name = "bindings-goblins-handoff",
            .aggregate_desc = "Per-binding three-party handoff: binding as recipient (redeems a Goblins give), every binding (needs racket + goblins + the runtimes)",
            .needs_iroh_abi = false,
            .rows = &goblins_handoff_clients,
        },
        .{
            .aggregate_name = "bindings-goblins-gift",
            .aggregate_desc = "Per-binding three-party handoff: binding as gifter (Goblins recipient redeems), every binding (needs racket + goblins + the runtimes)",
            .needs_iroh_abi = false,
            .rows = &goblins_gift_clients,
        },
        .{
            .aggregate_name = "bindings-iroh-loop",
            .aggregate_desc = "Per-binding iroh scale proof: many connections served from one loop, every binding (needs cargo + the runtimes)",
            .needs_iroh_abi = true,
            .rows = &iroh_loop_clients,
        },
        .{
            .aggregate_name = "bindings-iroh-handoff",
            .aggregate_desc = "Per-binding three-party handoff over iroh: every binding mints and redeems an iroh handoff give in one process (needs cargo + the runtimes)",
            .needs_iroh_abi = true,
            .rows = &iroh_handoff_clients,
        },
        .{
            .aggregate_name = "bindings-iroh-redeem-posture",
            .aggregate_desc = "Per-binding hermetic proof that a configured redeem posture governs a hint-less iroh give, every binding (needs cargo + the runtimes)",
            .needs_iroh_abi = true,
            .rows = &iroh_redeem_clients,
        },
        .{
            .aggregate_name = "bindings-keyed-tcp-restart",
            .aggregate_desc = "Per-binding keyed-tcp restart proof: happy path, squatter refusal, same-seed fresh-port restart, every binding",
            .needs_iroh_abi = false,
            .rows = &keyed_tcp_restart_clients,
        },
        .{
            .aggregate_name = "bindings-iroh-reachability",
            .aggregate_desc = "Per-binding live dial-by-id over n0 relays + DNS/pkarr discovery, every binding (opt-in; needs cargo + the runtimes + internet)",
            .needs_iroh_abi = true,
            .rows = &iroh_reach_clients,
        },
    };
    for (binding_families) |family| {
        addBindingFamily(b, family, pin_port, iroh_abi_step);
    }

    // Hermetic type-check of the public iroh C ABI: an object, so its externs
    // need no definition, `zig build check` catches rot in this module (and the
    // resident surface it drives) without cargo. Linking stays in `iroh-abi`.
    const iroh_abi_check_mod = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod);
    const iroh_abi_check = b.addObject(.{
        .name = "iroh-abi-check",
        .root_module = iroh_abi_check_mod,
    });
    check_step.dependOn(&iroh_abi_check.step);

    // `include/pancake_net_transport_iroh.h` and the binding FFI layout facts
    // need the iroh resident module (defined above), so they join the shared
    // gen harness here rather than in the early header_gens table.
    addHeaderGen(b, check_step, target, optimize, .{
        .check_step_name = "gen-header-net-transport-iroh-check",
        .check_desc = "Verify include/pancake_net_transport_iroh.h matches src/c_abi/net_transport/iroh/mod.zig (fails if stale)",
        .write_step_name = "gen-header-net-transport-iroh",
        .write_desc = "Regenerate include/pancake_net_transport_iroh.h from src/c_abi/net_transport/iroh/mod.zig",
        .generator = "tools/gen/header/iroh.zig",
        .import_name = "c_abi_net_transport_iroh",
        .import_module = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod),
    });
    addHeaderGen(b, check_step, target, optimize, .{
        .check_step_name = "gen-binding-rust-ffi-check",
        .check_desc = "Verify the generated Rust extern blocks match src/c_abi (fails if stale)",
        .write_step_name = "gen-binding-rust-ffi",
        .write_desc = "Regenerate the Rust binding's extern blocks from src/c_abi (types reflected, names from the generated headers)",
        .generator = "tools/gen/binding/rust_ffi.zig",
        .import_name = "c_abi_net_transport_iroh",
        .import_module = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod),
        .extra_import_name = "c_abi",
        .extra_import_module = host_mods[layerIndex("c_abi")],
        .extra2_import_name = "c_abi_driver",
        .extra2_import_module = driver_abi_mod,
        .extra3_import_name = "c_abi_net_transport_tcp",
        .extra3_import_module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/tcp/mod.zig", &.{
            .{ .name = "model", .module = host_mods[layerIndex("model")] },
            .{ .name = "net", .module = host_mods[layerIndex("net")] },
            .{ .name = "driver", .module = host_mods[layerIndex("driver")] },
            .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
        }),
        .extra4_import_name = "c_abi_net_transport_inproc",
        .extra4_import_module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/inproc/mod.zig", &.{
            .{ .name = "net", .module = host_mods[layerIndex("net")] },
            .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
        }),
    });
    addHeaderGen(b, check_step, target, optimize, .{
        .check_step_name = "gen-binding-racket-ffi-check",
        .check_desc = "Verify the generated Racket FFI tables match src/c_abi (fails if stale)",
        .write_step_name = "gen-binding-racket-ffi",
        .write_desc = "Regenerate the Racket binding's FFI tables from src/c_abi (types reflected, wrapper argument names from the generated headers)",
        .generator = "tools/gen/binding/racket_ffi.zig",
        .import_name = "c_abi_net_transport_iroh",
        .import_module = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod),
        .extra_import_name = "c_abi",
        .extra_import_module = host_mods[layerIndex("c_abi")],
        .extra2_import_name = "c_abi_driver",
        .extra2_import_module = driver_abi_mod,
        .extra3_import_name = "c_abi_net_transport_tcp",
        .extra3_import_module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/tcp/mod.zig", &.{
            .{ .name = "model", .module = host_mods[layerIndex("model")] },
            .{ .name = "net", .module = host_mods[layerIndex("net")] },
            .{ .name = "driver", .module = host_mods[layerIndex("driver")] },
            .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
        }),
        .extra4_import_name = "c_abi_net_transport_inproc",
        .extra4_import_module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/inproc/mod.zig", &.{
            .{ .name = "net", .module = host_mods[layerIndex("net")] },
            .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
        }),
    });
    addHeaderGen(b, check_step, target, optimize, .{
        .check_step_name = "gen-binding-python-ffi-check",
        .check_desc = "Verify the generated Python ctypes signature tables match src/c_abi (fails if stale)",
        .write_step_name = "gen-binding-python-ffi",
        .write_desc = "Regenerate the Python binding's ctypes signature tables from src/c_abi (types reflected; the sigs dicts are positional)",
        .generator = "tools/gen/binding/python_ffi.zig",
        .import_name = "c_abi_net_transport_iroh",
        .import_module = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod),
        .extra_import_name = "c_abi",
        .extra_import_module = host_mods[layerIndex("c_abi")],
        .extra2_import_name = "c_abi_driver",
        .extra2_import_module = driver_abi_mod,
        .extra3_import_name = "c_abi_net_transport_tcp",
        .extra3_import_module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/tcp/mod.zig", &.{
            .{ .name = "model", .module = host_mods[layerIndex("model")] },
            .{ .name = "net", .module = host_mods[layerIndex("net")] },
            .{ .name = "driver", .module = host_mods[layerIndex("driver")] },
            .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
        }),
        .extra4_import_name = "c_abi_net_transport_inproc",
        .extra4_import_module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/inproc/mod.zig", &.{
            .{ .name = "net", .module = host_mods[layerIndex("net")] },
            .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
        }),
    });
    addHeaderGen(b, check_step, target, optimize, .{
        .check_step_name = "gen-binding-ffi-layouts-check",
        .check_desc = "Verify binding FFI layout facts match src/c_abi (fails if stale)",
        .write_step_name = "gen-binding-ffi-layouts",
        .write_desc = "Regenerate binding FFI layout facts from src/c_abi (the ocapn, driver, and iroh transport archives)",
        .generator = "tools/gen/binding/ffi_layouts.zig",
        .import_name = "c_abi",
        .import_module = host_mods[layerIndex("c_abi")],
        .extra_import_name = "c_abi_driver",
        .extra_import_module = driver_abi_mod,
        .extra2_import_name = "c_abi_net_transport_iroh",
        .extra2_import_module = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod),
    });
    addHeaderGen(b, check_step, target, optimize, .{
        .check_step_name = "gen-ts-abi-check",
        .check_desc = "Verify the generated TypeScript ABI mirror files match src/c_abi (fails if stale)",
        .write_step_name = "gen-ts-abi",
        .write_desc = "Regenerate the TypeScript ABI mirror from src/c_abi (the ocapn, driver, and iroh transport archives)",
        .generator = "tools/gen/binding/ts_abi.zig",
        .import_name = "c_abi",
        .import_module = host_mods[layerIndex("c_abi")],
        .extra_import_name = "c_abi_driver",
        .extra_import_module = driver_abi_mod,
        .extra2_import_name = "c_abi_net_transport_iroh",
        .extra2_import_module = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod),
        .extra3_import_name = "c_abi_net_transport_tcp",
        .extra3_import_module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/tcp/mod.zig", &.{
            .{ .name = "model", .module = host_mods[layerIndex("model")] },
            .{ .name = "net", .module = host_mods[layerIndex("net")] },
            .{ .name = "driver", .module = host_mods[layerIndex("driver")] },
            .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
        }),
        .extra4_import_name = "c_abi_net_transport_inproc",
        .extra4_import_module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/inproc/mod.zig", &.{
            .{ .name = "net", .module = host_mods[layerIndex("net")] },
            .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
        }),
    });
    addHeaderGen(b, check_step, target, optimize, .{
        .check_step_name = "gen-binding-constants-check",
        .check_desc = "Verify binding ABI constants match src/c_abi (fails if stale)",
        .write_step_name = "gen-binding-constants",
        .write_desc = "Regenerate binding ABI constants from src/c_abi (the ocapn, driver, and iroh transport archives)",
        .generator = "tools/gen/binding/constants.zig",
        .import_name = "c_abi",
        .import_module = host_mods[layerIndex("c_abi")],
        .extra_import_name = "c_abi_driver",
        .extra_import_module = driver_abi_mod,
        .extra2_import_name = "c_abi_net_transport_iroh",
        .extra2_import_module = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod),
    });

    // ── External conformance pressure (siblings of `check`) ──────────────────
    // A pancake peer the upstream OCapN test suite can dial: it serves the
    // canonical conformance swiss-nums over `tcp-testing-only`. The orchestrator
    // `run-against-pancake.sh` starts it and runs the suite against it, pointing
    // the external authority back at pancake. Not part of `check`; needs uv +
    // the suite submodule. The peer installs only for this step, not on every
    // default build.
    const ocapn_peer_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-ocapn-peer", "conformance/ocapn-conformance/pancake_peer.zig");
    // The peer is pure Zig over the pancake API; running the suite needs uv, but
    // compiling the peer does not, so it rides `check`. A core-API change that
    // breaks this consumer then fails fast on `zig build check` rather than only
    // under the uv-driven ocapn-conformance sibling.
    check_step.dependOn(&ocapn_peer_exe.step);
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
    // `racket test/oracle/generate.rkt test/oracle/corpus`.
    const fixture_gen = b.addSystemCommand(&.{"racket"});
    fixture_gen.addFileArg(b.path("test/oracle/generate.rkt"));
    const fixture_gen_out = fixture_gen.addOutputDirectoryArg("generated-fixtures");
    const fixture_diff = b.addSystemCommand(&.{ "diff", "-r" });
    fixture_diff.addDirectoryArg(b.path("test/oracle/corpus"));
    fixture_diff.addDirectoryArg(fixture_gen_out);
    const fixture_gen_check_step = b.step("fixture-gen-check", "Regenerate Syrup fixtures via the upstream Racket Syrup encoder and diff against the committed corpus (needs racket + syrup)");
    fixture_gen_check_step.dependOn(&fixture_diff.step);

    // Hermetic C-ABI extract refuse matrix (ADR-0077): zip-slip / symlink
    // fixtures against each resolve port's hard-fail hygiene. Sibling of the
    // Zig-hermetic gate only in that it needs host tools (python3/deno/tar);
    // it is still part of `check` because soft-green extract is a footgun.
    const c_abi_extract = b.addSystemCommand(&.{ "bash", "tools/c-abi/c-abi-extract-matrix.sh" });
    c_abi_extract.setCwd(b.path("."));
    const c_abi_extract_check_step = b.step("c-abi-extract-check", "Hermetic C-ABI extract hygiene matrix: refuse zip-slip/symlink, accept clean lib/ (ADR-0077)");
    c_abi_extract_check_step.dependOn(&c_abi_extract.step);
    check_step.dependOn(c_abi_extract_check_step);

    // ── Cross-language application demos (siblings of `check`) ───────────────
    // The rooms cross-language application demo: one Zig-built native client plus
    // the Deno server and the Deno/Python/Racket/Rust clients, all joining one
    // capability-secure chat room over TCP. It needs `deno` (which hosts the room
    // and runs the orchestrator) and the Zig client, always built here. Python,
    // Racket, and Rust each join only when their runtime is on PATH; the demo
    // builds the Rust client itself when `cargo` is present and reports any
    // language it skipped rather than failing. So it is a sibling step, not part of
    // the hermetic gate. The Deno server regression test covers attached-room
    // cleanup, then the orchestrator (`apps/rooms/demo.ts`) starts the
    // server, runs whichever clients are available, and asserts the all-to-all
    // broadcast among them.
    // The Zig demo clients' shared helper modules under
    // `apps/_demo/zig/`: the typed room-error vocabulary, the
    // one-shot usage printer, and the tools capability checklist. Each std-only
    // leaf is minted once and imported by the clients that name it.
    const demo_rooms_cli_mod = b.createModule(.{ .root_source_file = b.path("apps/_demo/zig/rooms_cli.zig"), .target = target, .optimize = optimize });
    const demo_usage_mod = b.createModule(.{ .root_source_file = b.path("apps/_demo/zig/usage.zig"), .target = target, .optimize = optimize });
    const demo_tools_check_mod = b.createModule(.{ .root_source_file = b.path("apps/_demo/zig/tools_check.zig"), .target = target, .optimize = optimize });

    const rooms_client_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-rooms-client", "apps/rooms/zig/client.zig");
    rooms_client_exe.root_module.addImport("demo_rooms_cli", demo_rooms_cli_mod);
    rooms_client_exe.root_module.addImport("demo_usage", demo_usage_mod);
    // The default rooms client is TCP-only: a build option flips the iroh dial
    // path off so the `@import("iroh")` inside it is comptime-elided and the
    // hermetic build never pulls the Rust sidecar into its graph.
    const rooms_tcp_opts = b.addOptions();
    rooms_tcp_opts.addOption(bool, "iroh_enabled", false);
    rooms_client_exe.root_module.addOptions("rooms_client_build_options", rooms_tcp_opts);

    // Run that same TCP client by hand against a room you started yourself, so
    // the README's Zig one-liner is a real command: `zig build rooms-client --
    // <locator> <room> <nick> <line> [roster]` forwards everything after `--` to the
    // client. It is a convenience runner for the artifact the demo already
    // builds, not part of any gate.
    const rooms_client_run = b.addRunArtifact(rooms_client_exe);
    if (b.args) |args| rooms_client_run.addArgs(args);
    const rooms_client_step = b.step("rooms-client", "Run the native Zig rooms chat client (one-shot); pass `-- <locator> <room> <nick> <line> [roster]`");
    rooms_client_step.dependOn(&rooms_client_run.step);

    // The demo Zig clients only run under demo steps that need deno (and
    // cargo for the iroh variant), so an API or module-wiring change can rot
    // them unnoticed by every hermetic gate. Compile them under `check`,
    // compile-only, the same rot guard the bench-langs executables carry.
    check_step.dependOn(&rooms_client_exe.step);

    // --unstable-ffi lets the iroh server tests in server_test.ts dial the
    // sidecar's nonblocking FFI; they skip when the iroh ABI lib is absent, so
    // the flag is harmless for the TCP suite and a cargo-free run stays green.
    const rooms_server_test = addInstalledSystemRun(b, &.{
        "deno",                           "test",                        "--allow-ffi", "--unstable-ffi", "--allow-read", "--allow-net", "--allow-run", "--allow-env",
        "apps/rooms/deno/server_test.ts", "apps/rooms/deno/web_test.ts",
    });

    const rooms_demo = addInstalledSystemRun(b, &.{
        "deno",               "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "--allow-env",
        "apps/rooms/demo.ts",
    });
    rooms_demo.addArtifactArg(rooms_client_exe); // the Zig client's built path
    if (pin_port) |p| rooms_demo.addArg(b.fmt("--port={d}", .{p}));
    if (attach) rooms_demo.addArg("--attach");
    rooms_demo.step.dependOn(&rooms_server_test.step);
    const rooms_demo_step = b.step("demo-rooms", "Run the cross-language rooms chat demo (needs deno; joins python3/racket/cargo clients when present)");
    rooms_demo_step.dependOn(&rooms_demo.step);

    // The rooms-app face of the gifter handoff (`deno-gifter-handoff`): a
    // rendezvous room introduces two members who then DM directly, room out of
    // the path. Exercises the real rooms directory's `register`/`introduce` and
    // a member's exported `dm` object, the three proofs (live cap, brand-new
    // inbound, no relay) asserted. Its iroh sibling is `demo-rooms-dm-iroh`.
    const run_rooms_dm = b.addSystemCommand(&.{
        "deno",                  "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-env",
        "apps/rooms/dm_demo.ts",
    });
    run_rooms_dm.step.dependOn(b.getInstallStep());
    b.step("demo-rooms-dm", "Rooms direct-message-by-introduction over TCP: a room introduces two members who then DM directly, room out of the path (needs deno)")
        .dependOn(&run_rooms_dm.step);

    // The same rooms demo over iroh's encrypted QUIC. The Zig client is built as
    // a second, iroh-enabled artifact that links the Rust sidecar (so it can dial
    // an ocapn:// URI), and the cross-language clients reach the room through the
    // iroh C ABI companion library. Needs cargo (sidecar + iroh ABI) and deno, so
    // it is a sibling of `check`, like `iroh-interop`.
    const rooms_client_iroh_mod = irohDriverModule(b, target, optimize, lib_mod, iroh_resident_mod, "apps/rooms/zig/client.zig");
    const rooms_iroh_opts = b.addOptions();
    rooms_iroh_opts.addOption(bool, "iroh_enabled", true);
    rooms_client_iroh_mod.addOptions("rooms_client_build_options", rooms_iroh_opts);
    rooms_client_iroh_mod.addImport("demo_rooms_cli", demo_rooms_cli_mod);
    rooms_client_iroh_mod.addImport("demo_usage", demo_usage_mod);
    linkIrohSidecar(b, rooms_client_iroh_mod);
    const rooms_client_iroh_exe = b.addExecutable(.{ .name = "pancake-rooms-client-iroh", .root_module = rooms_client_iroh_mod });
    rooms_client_iroh_exe.step.dependOn(&iroh_lib.step);
    // The client's `dialIroh` path lives behind `iroh_enabled`, so the TCP client
    // that rides `check` (above) compiles it out. Ride a second, cargo-free
    // compile guard on `check` with the flag on — externs stay unresolved — so a
    // core-API change through the iroh resident cannot break this consumer unseen,
    // the same split as `rooms-peer-shim-check`.
    const rooms_client_iroh_check_mod = irohDriverModule(b, target, optimize, lib_mod, iroh_resident_mod, "apps/rooms/zig/client.zig");
    rooms_client_iroh_check_mod.addOptions("rooms_client_build_options", rooms_iroh_opts);
    rooms_client_iroh_check_mod.addImport("demo_rooms_cli", demo_rooms_cli_mod);
    rooms_client_iroh_check_mod.addImport("demo_usage", demo_usage_mod);
    check_step.dependOn(&b.addObject(.{ .name = "rooms-client-iroh-check", .root_module = rooms_client_iroh_check_mod }).step);

    // Product CLI (ADR-0084): one CapTP registry behind ocapn / repl / mcp / app rooms-peer.
    // Links the iroh sidecar (rooms presence). Cargo-free object on check.
    const pancake_cli_opts = b.addOptions();
    pancake_cli_opts.addOption(u32, "version_major", @as(u32, @intCast(abi_version.major)));
    pancake_cli_opts.addOption(u32, "version_minor", @as(u32, @intCast(abi_version.minor)));
    pancake_cli_opts.addOption(u32, "version_patch", @as(u32, @intCast(abi_version.patch)));
    pancake_cli_opts.addOption([]const u8, "captp_profile", "ocapn-captp");
    // CapTP lab REPL (libvaxis): TUI only on the product CLI, never libpancake_*.
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_mod = vaxis_dep.module("vaxis");

    const pancake_cli_mod = irohDriverModule(b, target, optimize, lib_mod, iroh_resident_mod, "cli/main.zig");
    pancake_cli_mod.addOptions("build_options", pancake_cli_opts);
    pancake_cli_mod.addImport("vaxis", vaxis_mod);
    linkIrohSidecar(b, pancake_cli_mod);
    const pancake_cli_exe = b.addExecutable(.{ .name = "pancake", .root_module = pancake_cli_mod });
    pancake_cli_exe.step.dependOn(&iroh_lib.step);
    b.installArtifact(pancake_cli_exe);
    const pancake_cli_run = b.addRunArtifact(pancake_cli_exe);
    pancake_cli_run.setCwd(b.path("."));
    pancake_cli_run.has_side_effects = true;
    if (b.args) |args| pancake_cli_run.addArgs(args);
    b.step("pancake", "Run the pancake CapTP CLI; pass `-- <command> …` (ocapn|repl|mcp|app rooms-peer|…)")
        .dependOn(&pancake_cli_run.step);
    const pancake_cli_check_mod = irohDriverModule(b, target, optimize, lib_mod, iroh_resident_mod, "cli/main.zig");
    pancake_cli_check_mod.addOptions("build_options", pancake_cli_opts);
    pancake_cli_check_mod.addImport("vaxis", vaxis_mod);
    check_step.dependOn(&b.addObject(.{ .name = "pancake-cli-check", .root_module = pancake_cli_check_mod }).step);

    // Install alias: thin shim → `pancake app rooms-peer` (no CapTP/iroh link).
    // `zig build rooms-peer` runs the product binary directly so the cache path
    // need not sit beside an installed `pancake`.
    const rooms_peer_shim_mod = b.createModule(.{
        .root_source_file = b.path("cli/rooms_peer_shim.zig"),
        .target = target,
        .optimize = optimize,
    });
    const rooms_peer_exe = b.addExecutable(.{ .name = "rooms-peer", .root_module = rooms_peer_shim_mod });
    b.installArtifact(rooms_peer_exe);
    check_step.dependOn(&b.addObject(.{ .name = "rooms-peer-shim-check", .root_module = rooms_peer_shim_mod }).step);
    const rooms_peer_run = b.addRunArtifact(pancake_cli_exe);
    rooms_peer_run.setCwd(b.path("."));
    rooms_peer_run.has_side_effects = true;
    rooms_peer_run.addArgs(&.{ "app", "rooms-peer" });
    if (b.args) |args| rooms_peer_run.addArgs(args);
    b.step("rooms-peer", "Run rooms presence via `pancake app rooms-peer`; pass `-- <verb> [flags]`")
        .dependOn(&rooms_peer_run.step);

    // Hermetic CLI tests: registry meta plus loopback session/capture goldens.
    // Same imports as the product CLI (build_options + iroh resident for
    // tree/rooms-peer). Link the sidecar so iroh resident externs resolve; tests that
    // dial live iroh stay out of this suite.
    const cli_api_mod = b.createModule(.{
        .root_source_file = b.path("cli/test_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_api_mod.addImport("pancake", lib_mod);
    cli_api_mod.addImport("vaxis", vaxis_mod);
    cli_api_mod.addImport("iroh", iroh_resident_mod);
    cli_api_mod.addOptions("build_options", pancake_cli_opts);
    linkIrohSidecar(b, cli_api_mod);
    const cli_tests_mod = b.createModule(.{
        .root_source_file = b.path("test/cli/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_tests_mod.addImport("cli", cli_api_mod);
    cli_tests_mod.addImport("pancake", lib_mod);
    cli_tests_mod.addImport("vaxis", vaxis_mod);
    const cli_tests = b.addTest(.{
        .root_module = cli_tests_mod,
        .name = "cli-registry-test",
        .filters = if (test_filter) |f| b.dupeStrings(&.{f}) else &.{},
    });
    cli_tests.step.dependOn(&iroh_lib.step);
    const cli_tests_run = b.addRunArtifact(cli_tests);
    check_step.dependOn(&cli_tests_run.step);
    b.step("cli-test", "Run hermetic pancake CLI registry + session/capture tests")
        .dependOn(&cli_tests_run.step);
    // Discoverable alias: `zig build cli` (same as cli-test).
    b.step("cli", "Alias for cli-test — hermetic pancake CLI goldens")
        .dependOn(&cli_tests_run.step);

    const rooms_demo_iroh = addInstalledSystemRun(b, &.{
        "deno",               "run", "-A", "--unstable-ffi",
        "apps/rooms/demo.ts",
    });
    rooms_demo_iroh.addArtifactArg(rooms_client_iroh_exe); // the iroh-enabled Zig client
    rooms_demo_iroh.addArg("--transport=iroh");
    if (pin_port) |p| rooms_demo_iroh.addArg(b.fmt("--port={d}", .{p}));
    // The cross-language clients and the Deno server dial iroh through the iroh
    // C ABI companion library, so it must be built and installed first.
    rooms_demo_iroh.step.dependOn(iroh_abi_step);
    const rooms_demo_iroh_step = b.step("demo-rooms-iroh", "Run the cross-language rooms demo over iroh's encrypted QUIC (needs cargo + deno; joins python3/racket/cargo clients when present)");
    rooms_demo_iroh_step.dependOn(&rooms_demo_iroh.step);

    // The iroh sibling of `demo-rooms-dm`: a room introduces two members who then
    // DM directly, every hop over iroh's encrypted QUIC. The cross-endpoint proof
    // that a gift can name an exporter reachable only by a dial hint (an iroh
    // endpoint's direct addresses) and a recipient redeems it by dialing that
    // endpoint directly, no discovery service and no relay. Three iroh endpoints in
    // one process for precise, flake-free assertions. Needs cargo (the sidecar +
    // iroh ABI companion) and deno, so it is a sibling of `check`.
    const rooms_dm_iroh = addInstalledSystemRun(b, &.{
        "deno",                       "run", "-A", "--unstable-ffi",
        "apps/rooms/dm_demo_iroh.ts",
    });
    rooms_dm_iroh.step.dependOn(iroh_abi_step);
    b.step("demo-rooms-dm-iroh", "Rooms DM-by-introduction over iroh: a room introduces two members who then DM directly over encrypted QUIC, room out of the path (needs cargo + deno)")
        .dependOn(&rooms_dm_iroh.step);

    // The discovery sibling of `demo-rooms-dm-iroh`: the same three-party handoff,
    // but every hop reaches its partner by node id ALONE over real n0 discovery
    // (relays + DNS/pkarr): the give names the exporter by id with no
    // direct-address hints, and the recipient resolves that id. Like
    // `iroh-reachability`, it touches public n0 infrastructure and pkarr-propagation
    // timing, so it is opt-in and never part of `check`; the offline, deterministic
    // proof of the same handoff is `demo-rooms-dm-iroh` (the Direct posture).
    const rooms_dm_iroh_discovery = addInstalledSystemRun(b, &.{
        "deno",                                 "run", "-A", "--unstable-ffi",
        "apps/rooms/dm_demo_iroh_discovery.ts",
    });
    rooms_dm_iroh_discovery.step.dependOn(iroh_abi_step);
    b.step("demo-rooms-dm-iroh-discovery", "Opt-in: rooms DM-by-introduction over iroh by node id ALONE through n0 discovery (relays + DNS/pkarr), no direct-address hints (needs cargo + deno + internet)")
        .dependOn(&rooms_dm_iroh_discovery.step);

    // The rooms browser UI: a Deno process that serves a single-page chat and, for
    // each browser tab, bridges a real pancake connection to the room directory. It
    // carries public rooms and direct messages by introduction, the three-party
    // handoff a browser cannot make on its own. It is a long-running server, so it
    // runs like `docs-serve`: start it, then open the URL it prints. `-Dport` pins
    // the HTTP port (default 8000). Needs `deno`.
    const rooms_web = addInstalledSystemRun(b, &.{
        "deno",                   "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run",
        "apps/rooms/deno/web.ts",
    });
    if (pin_port) |p| rooms_web.addArg(b.fmt("{d}", .{p}));
    const rooms_web_step = b.step("rooms-web", "Serve the rooms browser UI over TCP (public rooms + direct messages by introduction); open the printed URL (needs deno)");
    rooms_web_step.dependOn(&rooms_web.step);

    // The rooms-web browser-peer proof: a wasm browser peer drives the real
    // room directory through
    // web.ts's `/relay` byte pipe, no dlopen and no JSON bridge in its process.
    // Needs the wasm module and the native archives (web.ts and the room server
    // are native children). A sibling step (needs deno), not folded into the
    // Zig-hermetic `check`.
    const rooms_web_relay_peer = b.addSystemCommand(&.{
        "deno",                                   "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "--allow-env",
        "apps/rooms/deno/web_relay_peer_test.ts",
    });
    rooms_web_relay_peer.setCwd(b.path("."));
    rooms_web_relay_peer.has_side_effects = true;
    rooms_web_relay_peer.step.dependOn(&wasm_driver_install.step);
    rooms_web_relay_peer.step.dependOn(b.getInstallStep());
    const rooms_web_relay_peer_step = b.step("rooms-web-relay-peer", "Prove a wasm browser peer drives the room directory through web.ts's /relay byte pipe (needs deno)");
    rooms_web_relay_peer_step.dependOn(&rooms_web_relay_peer.step);

    // The same proof in a REAL headless browser: a Playwright Chromium loads a
    // page that bundles @pancake/web and drives the room directory through
    // /relay — the full shipped path (browser wasm Host, WebSocket channel, a
    // capability call, no dlopen). Needs deno, the wasm module, the native
    // archives (web.ts's children), and a Playwright Chromium
    // (`npx playwright install chromium && sudo npx playwright install-deps`).
    // A sibling step, not folded into `check` (it needs a browser binary).
    const rooms_web_browser_peer = b.addSystemCommand(&.{
        "deno", "run", "--allow-all", "apps/rooms/deno/browser_peer_test.ts",
    });
    rooms_web_browser_peer.setCwd(b.path("."));
    rooms_web_browser_peer.has_side_effects = true;
    rooms_web_browser_peer.step.dependOn(&wasm_driver_install.step);
    rooms_web_browser_peer.step.dependOn(b.getInstallStep());
    const rooms_web_browser_peer_step = b.step("rooms-web-browser-peer", "Prove a real headless Chromium runs the @pancake/web peer through web.ts's /relay (needs deno + a Playwright Chromium)");
    rooms_web_browser_peer_step.dependOn(&rooms_web_browser_peer.step);

    // The whole rooms page as a browser peer: a real headless Chromium loads
    // the page web.ts serves (bundled @pancake/web graph, the wasm module, the
    // UI), joins a room through /relay, and round-trips a chat line over the
    // room capability — no JSON bridge on the page's path. Same needs as
    // rooms-web-browser-peer. A sibling step, not folded into `check`.
    const rooms_web_page = b.addSystemCommand(&.{
        "deno", "run", "--allow-all", "apps/rooms/deno/web_page_test.ts",
    });
    rooms_web_page.setCwd(b.path("."));
    rooms_web_page.has_side_effects = true;
    rooms_web_page.step.dependOn(&wasm_driver_install.step);
    rooms_web_page.step.dependOn(b.getInstallStep());
    const rooms_web_page_step = b.step("rooms-web-page", "Prove the whole rooms page runs as a browser peer: join a room through /relay and round-trip a line over the room capability (needs deno + a Playwright Chromium)");
    rooms_web_page_step.dependOn(&rooms_web_page.step);

    // The browser sends a direct message end to end: a real headless Chromium
    // redeems a room introduction and dials the member's iroh endpoint through
    // the relay, delivering off-room. Runs the room + relay over iroh, so it needs
    // the iroh C ABI companion (cargo) as well as the wasm module and a Chromium.
    const rooms_web_dm = b.addSystemCommand(&.{
        "deno", "run", "--allow-all", "apps/rooms/deno/web_dm_test.ts",
    });
    rooms_web_dm.setCwd(b.path("."));
    rooms_web_dm.has_side_effects = true;
    rooms_web_dm.step.dependOn(&wasm_driver_install.step);
    rooms_web_dm.step.dependOn(iroh_abi_step);
    rooms_web_dm.step.dependOn(b.getInstallStep());
    const rooms_web_dm_step = b.step("rooms-web-dm", "Prove the rooms page sends a direct message from a real browser: redeem a room introduction and dial the member's iroh endpoint through /relay, delivered off-room (needs cargo + deno + a Playwright Chromium)");
    rooms_web_dm_step.dependOn(&rooms_web_dm.step);

    // The same browser UI with its rooms and its direct-message members over iroh's
    // encrypted QUIC instead of TCP. The bridge announces and dials ocapn:// URIs,
    // so it needs the iroh C ABI companion built first, and thus `cargo`.
    const rooms_web_iroh = addInstalledSystemRun(b, &.{
        "deno",                   "run",              "-A", "--unstable-ffi",
        "apps/rooms/deno/web.ts", "--transport=iroh",
    });
    if (pin_port) |p| rooms_web_iroh.addArg(b.fmt("{d}", .{p}));
    rooms_web_iroh.step.dependOn(iroh_abi_step);
    const rooms_web_iroh_step = b.step("rooms-web-iroh", "Serve the rooms browser UI over iroh's encrypted QUIC (public rooms + direct messages by introduction); open the printed URL (needs cargo + deno)");
    rooms_web_iroh_step.dependOn(&rooms_web_iroh.step);

    // The tasks cross-language application demo: a capability-secure shared task
    // board with CRUD operations and live change notifications through capability
    // callbacks. One Zig-built native client plus the Deno server and
    // Deno/Python/Racket/Rust clients, all managing tasks on one board over TCP. Like
    // rooms, it needs `deno` (which hosts the board and runs the orchestrator)
    // and the Zig client, always built here. Python, Racket, and Rust join when their
    // runtimes are on PATH. It is a sibling step, not part of the hermetic gate.
    const tasks_client_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-tasks-client", "apps/tasks/zig/client.zig");
    tasks_client_exe.root_module.addImport("demo_usage", demo_usage_mod);
    check_step.dependOn(&tasks_client_exe.step);

    const tasks_demo = addInstalledSystemRun(b, &.{
        "deno",               "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "--allow-env",
        "apps/tasks/demo.ts",
    });
    tasks_demo.addArtifactArg(tasks_client_exe);
    if (pin_port) |p| tasks_demo.addArg(b.fmt("--port={d}", .{p}));
    if (attach) tasks_demo.addArg("--attach");
    const tasks_demo_step = b.step("demo-tasks", "Run the cross-language tasks board demo (needs deno; joins python3/racket/cargo clients when present)");
    tasks_demo_step.dependOn(&tasks_demo.step);

    // The tools capability showcase: an AI-tool-harness shaped demo. A Deno
    // coordinator hands an agent capabilities to tools — attenuated to read-only,
    // and revocable — and each agent proves delegation, attenuation, and
    // revocation over an OCapN session on the `tcp` netlayer. The coordinator and agent are different languages
    // on the wire, so the capability trio is real, not in-process. It needs `deno`
    // (which hosts the coordinator and runs the orchestrator); Python, Racket,
    // and Rust agents join when their runtimes are on PATH. A sibling step, not
    // part of the hermetic gate.
    const tools_agent_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-tools-agent", "apps/tools/zig/agent.zig");
    tools_agent_exe.root_module.addImport("demo_tools_check", demo_tools_check_mod);
    tools_agent_exe.root_module.addImport("demo_usage", demo_usage_mod);
    check_step.dependOn(&tools_agent_exe.step);

    const tools_demo = addInstalledSystemRun(b, &.{
        "deno",               "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "--allow-env",
        "apps/tools/demo.ts",
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
    // (KERI), Episodes, and the transparency log all live above pancake, the app
    // imports the `pancake` module and never reaches into the core. It needs no
    // extra runtime, so it rides the gate as an application contract (below). The
    // app source lives under `apps/accountability-on-pancake/`, beside
    // the other worked applications.
    const run_accountability = addPancakeRun(b, lib_mod, target, optimize, "accountability-on-pancake", "apps/accountability-on-pancake/zig/main.zig");
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
    const host_exe = pancakeExecutable(b, lib_mod, target, optimize, "accountability-host", "apps/accountability-on-pancake/zig/host.zig");
    const host_install = b.addInstallArtifact(host_exe, .{});
    const accountability_demo = addInstalledSystemRun(b, &.{
        "deno",                                        "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "--allow-env",
        "apps/accountability-on-pancake/deno/demo.ts",
    });
    accountability_demo.addArtifactArg(host_exe); // the Zig host's built path
    if (pin_port) |p| accountability_demo.addArg(b.fmt("--port={d}", .{p}));
    if (attach) accountability_demo.addArg("--attach"); // the orchestrator rejects it: each caller needs a fresh host
    const accountability_demo_step = b.step("demo-accountability", "Run the cross-language accountability demo: Zig host + Deno/Python callers (needs deno)");
    accountability_demo_step.dependOn(&host_install.step);
    accountability_demo_step.dependOn(&accountability_demo.step);

    // Three-party accountability test: proves that a handoff-introduced caller's
    // Episode attributes the true caller, not the introducer. In-memory, protocol-
    // level, the same test the Zig-native and cross-seam demos make over TCP.
    const three_party_mod = b.createModule(.{
        .root_source_file = b.path("apps/accountability-on-pancake/zig/three_party_test.zig"),
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
    // is compiled only when these steps run, the same way the cargo, deno, and
    // racket sibling steps reach for their tool at run time. The hermetic
    // `check` graph never imports it, so the root build stays dependency-free.
    // The autodoc-only step, grouped here with the site steps that also render
    // documentation; it emits the public `pancake` module's reference under
    // zig-out/docs/ from the artifact built in the autodoc section above.
    const docs_step = b.step("docs", "Generate the Zig API reference (autodoc) under zig-out/docs/");
    docs_step.dependOn(&install_docs.step);

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
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .{ .custom = "site" },
        .install_subdir = "reference/api",
    });
    site_docs_install.step.dependOn(&render_site.step);
    const site_step = b.step("site", "Build the documentation site (Zine + autodoc) under zig-out/site/");
    site_step.dependOn(&site_docs_install.step);

    // `docs-serve` is the normal local preview: Zine's development server
    // rebuilds and reloads as the content and templates change. It serves the
    // Zine pages only, the generated autodoc reference is a release-time
    // install, so preview the API reference with `zig build site`.
    //
    // The inner `zig build … docs-serve` launches Zine's dev server as a
    // grandchild, and `zig build` does not reap that subtree when an ancestor is
    // stopped, so the server can be left orphaned and bound to its port.
    // `site/docs-serve.sh` is a minimal launcher that runs the inner build in
    // its own process group and tears the whole group down on any stop signal or
    // exit. It is the lifecycle detail of this step, not a new user command; the
    // public `zig build docs-serve` is unchanged.
    const serve_site = b.addSystemCommand(&.{
        "bash",           b.pathJoin(&.{ b.build_root.path.?, "site", "docs-serve.sh" }),
        b.graph.zig_exe,  "--build-file",
        "site/build.zig", "--cache-dir",
        site_cache_dir,   "docs-serve",
    });
    if (pin_port) |p| serve_site.addArg(b.fmt("-Dport={d}", .{p}));
    serve_site.has_side_effects = true;
    const docs_serve_step = b.step("docs-serve", "Serve the documentation site locally with Zine's development server");
    docs_serve_step.dependOn(&serve_site.step);

    // ── Formatting ───────────────────────────────────────────────────────────
    // The formatting gate splits the same way the correctness gate does. The
    // Zig formatter needs only the Zig toolchain, so `fmt` (write) and
    // `fmt-check` (check) are hermetic and `fmt-check` rides `check`. The Rust
    // and TypeScript formatters need cargo and deno on PATH, so `bindings-fmt`
    // and `bindings-fmt-check` are siblings of `check`, the same posture as
    // `rust-dogfood` and `bindings`. Python and Racket have no formatter in the
    // toolchain — Python's formatters forbid tabs and Racket indentation is
    // alignment-sensitive — so they are governed by `.editorconfig` alone. The
    // indentation policy itself lives in `.editorconfig`, `rustfmt.toml`, and
    // the `deno.json` `fmt` blocks; these steps only run the tools.
    //
    // `site/zig-pkg/` (Zig's fetched-package dir for the site sub-build) is
    // generated and never formatted, so the site rows name its two source files
    // directly rather than the `site` directory.
    const zig_fmt_paths = [_][]const u8{
        "build.zig",          "build.zig.zon", "src",     "test",     "tools",
        "bench",              "conformance",   "interop", "examples", "site/build.zig",
        "site/build.zig.zon",
    };
    const fmt_write = b.addFmt(.{ .paths = &zig_fmt_paths });
    b.step("fmt", "Format Zig sources in place (zig fmt)").dependOn(&fmt_write.step);
    const fmt_check = b.addFmt(.{ .paths = &zig_fmt_paths, .check = true });
    b.step("fmt-check", "Check Zig formatting without writing (zig fmt --check)").dependOn(&fmt_check.step);
    check_step.dependOn(&fmt_check.step);

    // Every Rust crate shares the root `rustfmt.toml` (hard tabs); rustfmt finds
    // it by searching upward, so one config governs all of them.
    const rust_manifests = [_][]const u8{
        "bindings/rust/Cargo.toml",
        "bench/langs/clients/rust_bench/Cargo.toml",
        "apps/tools/rust/Cargo.toml",
        "apps/tasks/rust/Cargo.toml",
        "apps/rooms/rust/Cargo.toml",
        "transports/iroh/Cargo.toml",
    };
    const bindings_fmt_step = b.step("bindings-fmt", "Format the Rust crates and TypeScript bindings in place (needs cargo + deno)");
    const bindings_fmt_check_step = b.step("bindings-fmt-check", "Check Rust + TypeScript formatting, the TypeScript lint rules, and the TypeScript type-check without writing (needs cargo + deno)");
    for (rust_manifests) |manifest| {
        const write = b.addSystemCommand(&.{ "cargo", "fmt", "--manifest-path", manifest });
        write.has_side_effects = true;
        bindings_fmt_step.dependOn(&write.step);
        const check = b.addSystemCommand(&.{ "cargo", "fmt", "--check", "--manifest-path", manifest });
        bindings_fmt_check_step.dependOn(&check.step);
    }
    // The loose TypeScript under the root `deno.json` and the `bindings/ts` deno
    // workspace are separate config scopes, so each is formatted from its own
    // working directory.
    const deno_dirs = [_][]const u8{ ".", "bindings/ts" };
    for (deno_dirs) |dir| {
        const write = b.addSystemCommand(&.{ "deno", "fmt" });
        write.setCwd(b.path(dir));
        write.has_side_effects = true;
        bindings_fmt_step.dependOn(&write.step);
        const check = b.addSystemCommand(&.{ "deno", "fmt", "--check" });
        check.setCwd(b.path(dir));
        bindings_fmt_check_step.dependOn(&check.step);
    }
    // The `bindings/ts` workspace also carries a `deno.json` lint config; run it
    // here so the lint rules gate alongside the formatter instead of rotting
    // unwired.
    const deno_lint = b.addSystemCommand(&.{ "deno", "lint" });
    deno_lint.setCwd(b.path("bindings/ts"));
    bindings_fmt_check_step.dependOn(&deno_lint.step);

    // Type-check the TypeScript binding. `deno-dogfood` and `wasm-driver-test`
    // both run their entry without type-checking (modern `deno run` does not
    // type-check by default), so a type error would otherwise ship silently;
    // check the public entry points, the dogfood, and the wasm browser-binding
    // proof here. The graph is the Deno one: the experimental
    // Node adapter imports `node:ffi`, which Deno cannot resolve, so it stays out
    // (it is `@ts-nocheck` and only loaded under Node).
    const deno_check = b.addSystemCommand(&.{
        "deno",                        "check",
        "stack/mod.ts",                "stack/transport/tcp.ts",
        "stack/transport/inproc.ts",   "stack/ffi.ts",
        "iroh/mod.ts",                 "iroh/internal.ts",
        "dogfood/zig_smoke.ts",        "dogfood/gifter_handoff.ts",
        "web/wasm_handshake_smoke.ts",
    });
    deno_check.setCwd(b.path("bindings/ts"));
    bindings_fmt_check_step.dependOn(&deno_check.step);

    // Serena's SolidLSP ZLS adapter currently hard-codes build-on-save args to
    // `zig build build`; keep that editor-only alias pointed at the normal
    // install step. The project correctness gate remains `zig build check`.
    const build_step = b.step("build", "Build and install the pancake C ABI archives");
    build_step.dependOn(b.getInstallStep());
}
