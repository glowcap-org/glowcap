const std = @import("std");
const arch_check = @import("tools/arch_check.zig");
const meta_check = @import("tools/meta_check.zig");

/// C ABI version (keep in lockstep with `PANCAKE_VERSION_*` in
/// `include/pancake_ocapn.h` and `src/c_abi/ocapn/mod.zig`, and with `.version`
/// in `build.zig.zon` — the meta gate holds the zon triple to this one). Each
/// archive's dynamic library soname tracks `major`.
const abi_version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

/// The layer DAG, the one authoritative statement of the architecture
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

    // ── Generated headers (per archive; ADR-0059) ────────────────────────────
    // Each archive's header is generated from its C ABI module (reflected
    // layouts, constant values, and function signatures): the Zig source is the
    // single source of truth. `include/pancake_ocapn.h` carries the shared
    // vocabulary and the peer/uri families. Multi-session CapTP product
    // work uses `pancake_host_*` in `pancake_driver.h`.
    // `include/pancake_net_transport_tcp.h` and `include/pancake_net_transport_inproc.h`
    // `#include` the ocapn header and add their transport family. The `*-check`
    // steps ride `check` and fail when a committed header is stale; the bare
    // steps are the fixers that rewrite in place.
    const HeaderGen = struct {
        check_step_name: []const u8,
        check_desc: []const u8,
        write_step_name: []const u8,
        write_desc: []const u8,
        check_tool: []const u8,
        write_tool: []const u8,
        import_name: []const u8,
        import_module: *std.Build.Module,
        /// A second reflected module, for a generator that mirrors more than
        /// one archive (the TS mirror covers ocapn and driver).
        extra_import_name: ?[]const u8 = null,
        extra_import_module: ?*std.Build.Module = null,
    };
    const header_gens = [_]HeaderGen{
        .{
            .check_step_name = "gen-header-ocapn-check",
            .check_desc = "Verify include/pancake_ocapn.h matches src/c_abi/ocapn (fails if stale)",
            .write_step_name = "gen-header-ocapn",
            .write_desc = "Regenerate include/pancake_ocapn.h from src/c_abi/ocapn",
            .check_tool = "tools/gen_header_check.zig",
            .write_tool = "tools/gen_header_write.zig",
            .import_name = "c_abi",
            .import_module = host_mods[layerIndex("c_abi")],
        },
        .{
            .check_step_name = "gen-header-driver-check",
            .check_desc = "Verify include/pancake_driver.h matches src/c_abi/driver (fails if stale)",
            .write_step_name = "gen-header-driver",
            .write_desc = "Regenerate include/pancake_driver.h from src/c_abi/driver",
            .check_tool = "tools/gen_header_driver_check.zig",
            .write_tool = "tools/gen_header_driver_write.zig",
            .import_name = "c_abi_driver",
            .import_module = driver_abi_mod,
        },
        .{
            .check_step_name = "gen-header-net-transport-tcp-check",
            .check_desc = "Verify include/pancake_net_transport_tcp.h matches src/c_abi/net_transport/tcp (fails if stale)",
            .write_step_name = "gen-header-net-transport-tcp",
            .write_desc = "Regenerate include/pancake_net_transport_tcp.h from src/c_abi/net_transport/tcp",
            .check_tool = "tools/gen_header_net_tcp_check.zig",
            .write_tool = "tools/gen_header_net_tcp_write.zig",
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
            .check_tool = "tools/gen_header_net_inproc_check.zig",
            .write_tool = "tools/gen_header_net_inproc_write.zig",
            .import_name = "c_abi_net_transport_inproc",
            .import_module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/inproc/mod.zig", &.{
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }),
        },
    };
    // The TypeScript ABI mirror rides the same generator loop: JS FFI has no
    // struct types, so the TS binding reads C structs through byte offsets, and
    // this is the one binding mirror that must be generated rather than
    // declared symbolically. Same check-or-regenerate discipline as the headers.
    const ts_abi_gen = HeaderGen{
        .check_step_name = "gen-ts-abi-check",
        .check_desc = "Verify bindings/ts/stack/internal/abi.ts matches src/c_abi (fails if stale)",
        .write_step_name = "gen-ts-abi",
        .write_desc = "Regenerate bindings/ts/stack/internal/abi.ts from src/c_abi (the ocapn and driver archives)",
        .check_tool = "tools/gen_ts_abi_check.zig",
        .write_tool = "tools/gen_ts_abi_write.zig",
        .import_name = "c_abi",
        .import_module = host_mods[layerIndex("c_abi")],
        .extra_import_name = "c_abi_driver",
        .extra_import_module = driver_abi_mod,
    };
    // HostAction kind constants + typed decode for every language binding
    // (binding spine Pass 2). Authority is src/c_abi/driver; executor arms stay
    // hand-written in each binding's action module.
    const binding_host_action_gen = HeaderGen{
        .check_step_name = "gen-binding-host-action-check",
        .check_desc = "Verify binding HostAction decode/types match src/c_abi/driver (fails if stale)",
        .write_step_name = "gen-binding-host-action",
        .write_desc = "Regenerate binding HostAction decode/types from src/c_abi/driver",
        .check_tool = "tools/gen_binding_host_action_check.zig",
        .write_tool = "tools/gen_binding_host_action_write.zig",
        .import_name = "c_abi_driver",
        .import_module = driver_abi_mod,
    };
    // The reflected integer ABI constants (return codes, reference/argument
    // kinds, codec/abort/dial families, caps) for every language binding, from
    // one table so a value is mirrored once and cannot drift. Rides the same
    // generator loop; the transport string symbols stay hand-kept.
    const binding_constants_gen = HeaderGen{
        .check_step_name = "gen-binding-constants-check",
        .check_desc = "Verify binding ABI constants match src/c_abi (fails if stale)",
        .write_step_name = "gen-binding-constants",
        .write_desc = "Regenerate binding ABI constants from src/c_abi (the ocapn and driver archives)",
        .check_tool = "tools/gen_binding_constants_check.zig",
        .write_tool = "tools/gen_binding_constants_write.zig",
        .import_name = "c_abi",
        .import_module = host_mods[layerIndex("c_abi")],
        .extra_import_name = "c_abi_driver",
        .extra_import_module = driver_abi_mod,
    };

    for (header_gens ++ [_]HeaderGen{ ts_abi_gen, binding_host_action_gen, binding_constants_gen }) |hg| {
        const check_mod = b.createModule(.{
            .root_source_file = b.path(hg.check_tool),
            .target = target,
            .optimize = optimize,
        });
        check_mod.addImport(hg.import_name, hg.import_module);
        if (hg.extra_import_name) |extra| check_mod.addImport(extra, hg.extra_import_module.?);
        const check_exe = b.addExecutable(.{ .name = hg.check_step_name, .root_module = check_mod });
        const check_run = b.addRunArtifact(check_exe);
        check_run.setCwd(b.path("."));
        const check_step_h = b.step(hg.check_step_name, hg.check_desc);
        check_step_h.dependOn(&check_run.step);
        check_step.dependOn(check_step_h);

        const write_mod = b.createModule(.{
            .root_source_file = b.path(hg.write_tool),
            .target = target,
            .optimize = optimize,
        });
        write_mod.addImport(hg.import_name, hg.import_module);
        if (hg.extra_import_name) |extra| write_mod.addImport(extra, hg.extra_import_module.?);
        const write_exe = b.addExecutable(.{ .name = hg.write_step_name, .root_module = write_mod });
        const write_run = b.addRunArtifact(write_exe);
        write_run.setCwd(b.path("."));
        write_run.has_side_effects = true;
        const write_step_h = b.step(hg.write_step_name, hg.write_desc);
        write_step_h.dependOn(&write_run.step);
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
            .argv = &.{ "racket", "bindings/racket/zig-smoke.rkt" },
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

    // ── Live Goblins interop (siblings of `check`) ───────────────────────────
    // Live interop proof against a real Spritely Goblins vat: a pancake peer
    // dials the conformance Goblins host, completes the keyed op:start-session
    // handshake, and bootstrap-fetches its echo cap. Needs `racket` + the
    // `goblins` collection on PATH (like the binding dogfoods), so it is a
    // sibling of `check`, not part of the hermetic gate. The driver spawns and
    // tears down the Goblins vat itself.
    const goblins_interop_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-goblins-interop", "interop/goblins_interop/driver.zig");
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

    // Live TCP scale over the loop-fed host bridge (ADR-0076): one completion
    // loop thread serves a full byte-fed node through `driver.Bridge`,
    // many concurrent BlockingSession clients across two waves. Binds real
    // loopback sockets at scale, so it is a sibling of `check`, port-exclusive
    // like every live step; `check` still compiles it so an API change cannot
    // silently rot it.
    const tcp_loop_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-tcp-loop", "interop/tcp_loop/driver.zig");
    const run_tcp_loop = b.addRunArtifact(tcp_loop_exe);
    run_tcp_loop.setCwd(b.path("."));
    run_tcp_loop.has_side_effects = true;
    const tcp_loop_step = b.step("tcp-loop", "Live TCP scale: many concurrent connections served from one loop thread through the Host bridge (ADR-0076)");
    tcp_loop_step.dependOn(&run_tcp_loop.step);
    check_step.dependOn(&tcp_loop_exe.step);

    // Live three-party handoff, pancake as recipient (needs racket + goblins).
    // It runs two Goblins listeners (alice, bob), so `-Dport=N` pins N and N+1.
    const goblins_handoff_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-goblins-handoff", "interop/goblins_interop/handoff_driver.zig");
    const run_goblins_handoff = b.addRunArtifact(goblins_handoff_exe);
    run_goblins_handoff.setCwd(b.path("."));
    run_goblins_handoff.has_side_effects = true;
    check_step.dependOn(&goblins_handoff_exe.step);
    if (pin_port) |p| run_goblins_handoff.addArg(b.fmt("--port={d}", .{p}));
    const goblins_handoff_step = b.step("goblins-handoff", "Live three-party handoff vs Goblins, pancake as recipient (needs racket + goblins)");
    goblins_handoff_step.dependOn(&run_goblins_handoff.step);

    // Each binding drives the same keyed conversation against a real Goblins
    // vat through the installed C ABI archives, the binding↔live-Goblins keyed
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
            .argv = &.{ "deno", "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "interop/goblins_interop/deno_client.ts" },
        },
        .{
            .step_name = "python-goblins-interop",
            .description = "Live keyed OCapN conversation: Python binding vs a real Goblins vat (needs python3 + racket + goblins)",
            .argv = &.{ "python3", "interop/goblins_interop/python_client.py" },
        },
        .{
            .step_name = "racket-goblins-interop",
            .description = "Live keyed OCapN conversation: Racket binding vs a real Goblins vat (needs racket + goblins)",
            .argv = &.{ "racket", "interop/goblins_interop/racket_client.rkt" },
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

    // Live three-party handoff with a binding as recipient: the binding redeems a
    // `desc:handoff-give` from a real Goblins introducer transparently through
    // `connect`/`fetch`/`send`, then calls the exporter object directly. The
    // binding counterpart of `goblins-handoff` (which proves it at the Zig driver
    // level). Spawns the Goblins introducer + exporter pair itself; `-Dport=N`
    // pins the introducer port (the exporter listens on N+1).
    const run_deno_handoff = addInstalledSystemRun(b, &.{
        "deno",                                           "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run",
        "interop/goblins_interop/deno_handoff_client.ts",
    });
    if (pin_port) |p| run_deno_handoff.addArg(b.fmt("--port={d}", .{p}));
    b.step("deno-goblins-handoff", "Live three-party handoff: the Deno binding redeems a give from a real Goblins introducer and calls the exporter (needs deno + racket + goblins)")
        .dependOn(&run_deno_handoff.step);

    const run_python_handoff = addInstalledSystemRun(b, &.{
        "python3", "interop/goblins_interop/python_handoff_client.py",
    });
    if (pin_port) |p| run_python_handoff.addArg(b.fmt("--port={d}", .{p}));
    b.step("python-goblins-handoff", "Live three-party handoff: the Python binding redeems a give from a real Goblins introducer and calls the exporter (needs python3 + racket + goblins)")
        .dependOn(&run_python_handoff.step);

    const run_rust_handoff = addInstalledSystemRun(b, &.{
        "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async", "--example", "goblins_handoff",
    });
    if (pin_port) |p| {
        run_rust_handoff.addArg("--");
        run_rust_handoff.addArg(b.fmt("--port={d}", .{p}));
    }
    b.step("rust-goblins-handoff", "Live three-party handoff: the Rust binding redeems a give from a real Goblins introducer and calls the exporter (needs cargo + racket + goblins)")
        .dependOn(&run_rust_handoff.step);

    const run_racket_handoff = addInstalledSystemRun(b, &.{
        "racket", "interop/goblins_interop/racket_handoff_client.rkt",
    });
    if (pin_port) |p| run_racket_handoff.addArg(b.fmt("--port={d}", .{p}));
    b.step("racket-goblins-handoff", "Live three-party handoff: the Racket binding redeems a give from a real Goblins introducer and calls the exporter (needs racket + goblins)")
        .dependOn(&run_racket_handoff.step);

    // Live three-party handoff with the Deno binding as the *gifter*: pancake
    // fetches a greeter from a Goblins exporter, publishes an introducer, and
    // mints a `desc:handoff-give` a Goblins recipient redeems, reaching the
    // exporter directly. The mirror of `deno-goblins-handoff`, proving the
    // exporter half of ADR-0009 cross-implementation: Goblins accepts pancake's
    // `deposit-gift` and redeems pancake's give. The client spawns the Goblins
    // exporter + recipient itself; `-Dport=N` pins the exporter port (the
    // recipient binds on N+1; the gifter takes an ephemeral port).
    const run_deno_gift = addInstalledSystemRun(b, &.{
        "deno",                                        "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "--allow-env",
        "interop/goblins_interop/deno_gift_client.ts",
    });
    if (pin_port) |p| run_deno_gift.addArg(b.fmt("--port={d}", .{p}));
    b.step("deno-goblins-gift", "Live three-party handoff: the Deno binding mints a give a real Goblins recipient redeems, reaching the exporter (needs deno + racket + goblins)")
        .dependOn(&run_deno_gift.step);

    // The per-binding mirrors of `deno-goblins-gift`: pancake is the gifter in
    // each language, deposits with the live Goblins exporter, and mints a give a
    // live Goblins recipient redeems, proving the transparent gifter half of
    // ADR-0009 in Python, Rust, and Racket too. Each client spawns the shared
    // Goblins exporter + recipient scripts itself; `-Dport=N` pins the exporter
    // port (the recipient binds on N+1; the gifter takes an ephemeral port).
    const run_python_gift = addInstalledSystemRun(b, &.{
        "python3", "interop/goblins_interop/python_gift_client.py",
    });
    if (pin_port) |p| run_python_gift.addArg(b.fmt("--port={d}", .{p}));
    b.step("python-goblins-gift", "Live three-party handoff: the Python binding mints a give a real Goblins recipient redeems, reaching the exporter (needs python3 + racket + goblins)")
        .dependOn(&run_python_gift.step);

    const run_rust_gift = addInstalledSystemRun(b, &.{
        "cargo", "run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "async", "--example", "goblins_gift",
    });
    if (pin_port) |p| {
        run_rust_gift.addArg("--");
        run_rust_gift.addArg(b.fmt("--port={d}", .{p}));
    }
    b.step("rust-goblins-gift", "Live three-party handoff: the Rust binding mints a give a real Goblins recipient redeems, reaching the exporter (needs cargo + racket + goblins)")
        .dependOn(&run_rust_gift.step);

    const run_racket_gift = addInstalledSystemRun(b, &.{
        "racket", "interop/goblins_interop/racket_gift_client.rkt",
    });
    if (pin_port) |p| run_racket_gift.addArg(b.fmt("--port={d}", .{p}));
    b.step("racket-goblins-gift", "Live three-party handoff: the Racket binding mints a give a real Goblins recipient redeems, reaching the exporter (needs racket + goblins)")
        .dependOn(&run_racket_gift.step);

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
        const compile_obj = b.addObject(.{ .name = b.fmt("{s}-compile", .{drv.exe_name}), .root_module = compile_mod });
        check_step.dependOn(&compile_obj.step);

        // Runnable sibling of `check`: links the sidecar and runs from the root.
        const run_mod = irohDriverModule(b, target, optimize, lib_mod, iroh_resident_mod, drv.root_source);
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
            \\cp -a zig-out/lib zig-out/include zig-out/release/stage/
            \\if find zig-out/release/stage/lib \( -type l -o -type b -o -type c \) 2>/dev/null | grep -q .; then
            \\  echo 'release-pack: lib/ must contain only regular files and directories (no symlinks/special files)' >&2
            \\  exit 1
            \\fi
            \\cp LICENSE-APACHE zig-out/release/stage/
            \\tar -czf 'zig-out/release/{s}' -C zig-out/release/stage lib include LICENSE-APACHE
            \\rm -rf zig-out/release/stage
            \\cd zig-out/release
            \\(sha256sum '{s}' || shasum -a 256 '{s}') > SHA256SUMS
            \\echo 'release-pack: zig-out/release/{s}'
        , .{ release_tarball, release_tarball, release_tarball, release_tarball }),
    });
    release_pack_run.step.dependOn(iroh_abi_step);
    const release_pack_step = b.step("release-pack", "Stage the installed archives + headers into a versioned, checksummed per-target tarball under zig-out/release/ (needs cargo for the iroh companion)");
    release_pack_step.dependOn(&release_pack_run.step);

    // Per-binding iroh scale proof: the binding sibling of `iroh-loop`. Each
    // drives many concurrent connections served from one readiness loop through
    // the iroh C ABI companion (ADR-0057), so a peer in any binding reaches the
    // same scale as the native one, not only Deno. Each needs its runtime plus
    // the installed iroh ABI library, so they are siblings of `check` like
    // `iroh-interop`. The `bindings-iroh-loop` aggregate runs them together.
    const bindings_iroh_loop_step = b.step("bindings-iroh-loop", "Per-binding iroh scale proof: many connections served from one loop, every binding (needs cargo + the runtimes)");
    const iroh_loop_clients = [_]struct {
        step_name: []const u8,
        description: []const u8,
        argv: []const []const u8,
        /// True when the runner needs a `--` separator before program args
        /// (cargo run forwards trailing args to the example only after one).
        dashdash_before_args: bool = false,
    }{
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
            .argv = &.{ "racket", "interop/iroh_loop/racket_client.rkt" },
        },
    };
    for (iroh_loop_clients) |client| {
        const run = addInstalledSystemRun(b, client.argv);
        run.step.dependOn(iroh_abi_step);
        if (pin_port) |p| {
            if (client.dashdash_before_args) run.addArg("--");
            run.addArg(b.fmt("--port={d}", .{p}));
        }
        b.step(client.step_name, client.description).dependOn(&run.step);
        bindings_iroh_loop_step.dependOn(&run.step);
    }

    // Per-binding three-party handoff over iroh, each self-contained in one
    // process (exporter + gifter + recipient, relay-less Direct posture): the
    // binding sibling of the Deno `demo-rooms-dm-iroh` proof and the iroh
    // companion of the `*-goblins-handoff` gates. Each proves both halves of an
    // iroh handoff through its own surface, minting a give whose exporter
    // location names an iroh endpoint, and redeeming it by dialing that endpoint
    // directly over encrypted QUIC. Deterministic and flake-free: no discovery
    // service, no relays, no network.
    const bindings_iroh_handoff_step = b.step("bindings-iroh-handoff", "Per-binding three-party handoff over iroh: every binding mints and redeems an iroh handoff give in one process (needs cargo + the runtimes)");
    const iroh_handoff_clients = [_]struct {
        step_name: []const u8,
        description: []const u8,
        argv: []const []const u8,
        dashdash_before_args: bool = false,
    }{
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
            .argv = &.{ "racket", "interop/iroh_handoff/racket_client.rkt" },
        },
    };
    for (iroh_handoff_clients) |client| {
        const run = addInstalledSystemRun(b, client.argv);
        run.step.dependOn(iroh_abi_step);
        if (pin_port) |p| {
            if (client.dashdash_before_args) run.addArg("--");
            run.addArg(b.fmt("--port={d}", .{p}));
        }
        b.step(client.step_name, client.description).dependOn(&run.step);
        bindings_iroh_handoff_step.dependOn(&run.step);
    }

    // Per-binding hermetic proof that a recipient's configured redeem posture
    // governs a *hint-less* iroh give (one naming its exporter by node id alone,
    // no direct-addresses): each binding sets its recipient machine's redeem
    // posture to `local_discovery` and redeems the hint-less give by resolving the
    // exporter's id through an in-process address book, no network. A
    // discriminating proof: the default `discovery` posture would reach for n0's
    // relays + DNS and fail with no internet, so the redeem succeeds only because
    // `dial_exporter` honors the configured posture. Deterministic and flake-free,
    // like `bindings-iroh-handoff`.
    const bindings_iroh_redeem_step = b.step("bindings-iroh-redeem-posture", "Per-binding hermetic proof that a configured redeem posture governs a hint-less iroh give, every binding (needs cargo + the runtimes)");
    const iroh_redeem_clients = [_]struct {
        step_name: []const u8,
        description: []const u8,
        argv: []const []const u8,
        dashdash_before_args: bool = false,
    }{
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
            .argv = &.{ "racket", "interop/iroh_redeem_posture/racket_client.rkt" },
        },
    };
    for (iroh_redeem_clients) |client| {
        const run = addInstalledSystemRun(b, client.argv);
        run.step.dependOn(iroh_abi_step);
        if (pin_port) |p| {
            if (client.dashdash_before_args) run.addArg("--");
            run.addArg(b.fmt("--port={d}", .{p}));
        }
        b.step(client.step_name, client.description).dependOn(&run.step);
        bindings_iroh_redeem_step.dependOn(&run.step);
    }

    // Per-binding keyed-tcp restart proof (ADR-0075): happy path, key-squatter
    // refusal, and same-seed-fresh-port restart — the binding siblings of
    // `test/driver/keyed_tcp_restart_test.zig`. No iroh companion needed.
    const bindings_keyed_tcp_restart_step = b.step("bindings-keyed-tcp-restart", "Per-binding keyed-tcp restart proof: happy path, squatter refusal, same-seed fresh-port restart, every binding");
    const keyed_tcp_restart_clients = [_]struct {
        step_name: []const u8,
        description: []const u8,
        argv: []const []const u8,
        dashdash_before_args: bool = false,
    }{
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
            .argv = &.{ "racket", "interop/keyed_tcp_restart/racket_client.rkt" },
        },
    };
    for (keyed_tcp_restart_clients) |client| {
        const run = addInstalledSystemRun(b, client.argv);
        if (pin_port) |p| {
            if (client.dashdash_before_args) run.addArg("--");
            run.addArg(b.fmt("--port={d}", .{p}));
        }
        b.step(client.step_name, client.description).dependOn(&run.step);
        bindings_keyed_tcp_restart_step.dependOn(&run.step);
    }

    // Per-binding live real-internet reachability: each binding reaches a peer by
    // node id ALONE over n0's public relays and DNS/pkarr discovery — no
    // direct-address hints, no in-process address book — the binding siblings of
    // the Zig `iroh-reachability` driver. Each binds two `Discovery`-posture
    // endpoints in one process; the client dials by id only and the dial rides
    // the binding's `Discovery` settle/retry while the publish propagates. Like
    // `iroh-reachability`, these touch public n0 infrastructure and
    // pkarr-propagation timing, so they are opt-in and never part of `check` or
    // the deterministic `bindings-iroh-handoff`. The offline, deterministic
    // dial-by-id proof is `local_discovery` in the `*-iroh-loop` gates.
    const bindings_iroh_reach_step = b.step("bindings-iroh-reachability", "Per-binding live dial-by-id over n0 relays + DNS/pkarr discovery, every binding (opt-in; needs cargo + the runtimes + internet)");
    const iroh_reach_clients = [_]struct {
        step_name: []const u8,
        description: []const u8,
        argv: []const []const u8,
        dashdash_before_args: bool = false,
    }{
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
            .argv = &.{ "racket", "interop/iroh_reachability/racket_client.rkt" },
        },
    };
    for (iroh_reach_clients) |client| {
        const run = addInstalledSystemRun(b, client.argv);
        run.step.dependOn(iroh_abi_step);
        if (pin_port) |p| {
            if (client.dashdash_before_args) run.addArg("--");
            run.addArg(b.fmt("--port={d}", .{p}));
        }
        b.step(client.step_name, client.description).dependOn(&run.step);
        bindings_iroh_reach_step.dependOn(&run.step);
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

    // `include/pancake_net_transport_iroh.h` is generated from
    // `src/c_abi/net_transport/iroh/mod.zig` (reflected signatures): the Zig source is the
    // single source of truth, as for pancake_ocapn.h. Both gen steps reflect
    // types only and link the sidecar stubs, so they run cargo-free;
    // `gen-header-net-transport-iroh-check` rides `check`.
    const iroh_abi_for_gen = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod);
    const iroh_gen_check_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_header_iroh_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    iroh_gen_check_mod.addImport("c_abi_net_transport_iroh", iroh_abi_for_gen);
    const iroh_gen_check_exe = b.addExecutable(.{ .name = "gen-header-net-transport-iroh-check", .root_module = iroh_gen_check_mod });
    const iroh_header_check = b.addRunArtifact(iroh_gen_check_exe);
    iroh_header_check.setCwd(b.path("."));
    const gen_header_iroh_check_step = b.step("gen-header-net-transport-iroh-check", "Verify include/pancake_net_transport_iroh.h matches src/c_abi/net_transport/iroh/mod.zig (fails if stale)");
    gen_header_iroh_check_step.dependOn(&iroh_header_check.step);
    check_step.dependOn(gen_header_iroh_check_step);

    const iroh_abi_for_gen_write = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod);
    const iroh_gen_write_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_header_iroh_write.zig"),
        .target = target,
        .optimize = optimize,
    });
    iroh_gen_write_mod.addImport("c_abi_net_transport_iroh", iroh_abi_for_gen_write);
    const iroh_gen_write_exe = b.addExecutable(.{ .name = "gen-header-net-transport-iroh-write", .root_module = iroh_gen_write_mod });
    const iroh_gen_write_run = b.addRunArtifact(iroh_gen_write_exe);
    iroh_gen_write_run.setCwd(b.path("."));
    iroh_gen_write_run.has_side_effects = true;
    const gen_header_iroh_step = b.step("gen-header-net-transport-iroh", "Regenerate include/pancake_net_transport_iroh.h from src/c_abi/net_transport/iroh/mod.zig");
    gen_header_iroh_step.dependOn(&iroh_gen_write_run.step);

    // ── External conformance pressure (siblings of `check`) ──────────────────
    // A pancake peer the upstream OCapN test suite can dial: it serves the
    // canonical conformance swiss-nums over `tcp-testing-only`. The orchestrator
    // `run-against-pancake.sh` starts it and runs the suite against it, pointing
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
    const c_abi_extract = b.addSystemCommand(&.{ "bash", "tools/c-abi-extract-matrix.sh" });
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
    // cleanup, then the orchestrator (`examples/apps/rooms/demo.ts`) starts the
    // server, runs whichever clients are available, and asserts the all-to-all
    // broadcast among them.
    // The Zig demo clients' shared helper modules under
    // `examples/apps/_demo/zig/`: the typed room-error vocabulary, the
    // one-shot usage printer, and the tools capability checklist. Each std-only
    // leaf is minted once and imported by the clients that name it.
    const demo_rooms_cli_mod = b.createModule(.{ .root_source_file = b.path("examples/apps/_demo/zig/rooms_cli.zig"), .target = target, .optimize = optimize });
    const demo_usage_mod = b.createModule(.{ .root_source_file = b.path("examples/apps/_demo/zig/usage.zig"), .target = target, .optimize = optimize });
    const demo_tools_check_mod = b.createModule(.{ .root_source_file = b.path("examples/apps/_demo/zig/tools_check.zig"), .target = target, .optimize = optimize });

    const rooms_client_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-rooms-client", "examples/apps/rooms/zig/client.zig");
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
        "deno",                                    "test",                                 "--allow-ffi", "--unstable-ffi", "--allow-read", "--allow-net", "--allow-run", "--allow-env",
        "examples/apps/rooms/deno/server_test.ts", "examples/apps/rooms/deno/web_test.ts",
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

    // The rooms-app face of the gifter handoff (`deno-gifter-handoff`): a
    // rendezvous room introduces two members who then DM directly, room out of
    // the path. Exercises the real rooms directory's `register`/`introduce` and
    // a member's exported `dm` object, the three proofs (live cap, brand-new
    // inbound, no relay) asserted. Its iroh sibling is `demo-rooms-dm-iroh`.
    const run_rooms_dm = b.addSystemCommand(&.{
        "deno",                           "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-env",
        "examples/apps/rooms/dm_demo.ts",
    });
    run_rooms_dm.step.dependOn(b.getInstallStep());
    b.step("demo-rooms-dm", "Rooms direct-message-by-introduction over TCP: a room introduces two members who then DM directly, room out of the path (needs deno)")
        .dependOn(&run_rooms_dm.step);

    // The same rooms demo over iroh's encrypted QUIC. The Zig client is built as
    // a second, iroh-enabled artifact that links the Rust sidecar (so it can dial
    // an ocapn:// URI), and the cross-language clients reach the room through the
    // iroh C ABI companion library. Needs cargo (sidecar + iroh ABI) and deno, so
    // it is a sibling of `check`, like `iroh-interop`.
    const rooms_client_iroh_mod = irohDriverModule(b, target, optimize, lib_mod, iroh_resident_mod, "examples/apps/rooms/zig/client.zig");
    const rooms_iroh_opts = b.addOptions();
    rooms_iroh_opts.addOption(bool, "iroh_enabled", true);
    rooms_client_iroh_mod.addOptions("rooms_client_build_options", rooms_iroh_opts);
    rooms_client_iroh_mod.addImport("demo_rooms_cli", demo_rooms_cli_mod);
    rooms_client_iroh_mod.addImport("demo_usage", demo_usage_mod);
    linkIrohSidecar(b, rooms_client_iroh_mod);
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
        "deno",                                "run", "-A", "--unstable-ffi",
        "examples/apps/rooms/dm_demo_iroh.ts",
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
        "deno",                                          "run", "-A", "--unstable-ffi",
        "examples/apps/rooms/dm_demo_iroh_discovery.ts",
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
        "deno",                            "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run",
        "examples/apps/rooms/deno/web.ts",
    });
    if (pin_port) |p| rooms_web.addArg(b.fmt("{d}", .{p}));
    const rooms_web_step = b.step("rooms-web", "Serve the rooms browser UI over TCP (public rooms + direct messages by introduction); open the printed URL (needs deno)");
    rooms_web_step.dependOn(&rooms_web.step);

    // The same browser UI with its rooms and its direct-message members over iroh's
    // encrypted QUIC instead of TCP. The bridge announces and dials ocapn:// URIs,
    // so it needs the iroh C ABI companion built first, and thus `cargo`.
    const rooms_web_iroh = addInstalledSystemRun(b, &.{
        "deno",                            "run",              "-A", "--unstable-ffi",
        "examples/apps/rooms/deno/web.ts", "--transport=iroh",
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
    const tasks_client_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-tasks-client", "examples/apps/tasks/zig/client.zig");
    tasks_client_exe.root_module.addImport("demo_usage", demo_usage_mod);
    check_step.dependOn(&tasks_client_exe.step);

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
    // revocation over an OCapN session on the `tcp` netlayer. The coordinator and agent are different languages
    // on the wire, so the capability trio is real, not in-process. It needs `deno`
    // (which hosts the coordinator and runs the orchestrator); Python, Racket,
    // and Rust agents join when their runtimes are on PATH. A sibling step, not
    // part of the hermetic gate.
    const tools_agent_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-tools-agent", "examples/apps/tools/zig/agent.zig");
    tools_agent_exe.root_module.addImport("demo_tools_check", demo_tools_check_mod);
    tools_agent_exe.root_module.addImport("demo_usage", demo_usage_mod);
    check_step.dependOn(&tools_agent_exe.step);

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
    // (KERI), Episodes, and the transparency log all live above pancake, the app
    // imports the `pancake` module and never reaches into the core. It needs no
    // extra runtime, so it rides the gate as an application contract (below). The
    // app source lives under `examples/apps/accountability-on-pancake/`, beside
    // the other worked applications.
    const run_accountability = addPancakeRun(b, lib_mod, target, optimize, "accountability-on-pancake", "examples/apps/accountability-on-pancake/zig/main.zig");
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
    const host_exe = pancakeExecutable(b, lib_mod, target, optimize, "accountability-host", "examples/apps/accountability-on-pancake/zig/host.zig");
    const host_install = b.addInstallArtifact(host_exe, .{});
    const accountability_demo = addInstalledSystemRun(b, &.{
        "deno",                                                 "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run",
        "examples/apps/accountability-on-pancake/deno/demo.ts",
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
        .root_source_file = b.path("examples/apps/accountability-on-pancake/zig/three_party_test.zig"),
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
        "examples/apps/tools/rust/Cargo.toml",
        "examples/apps/tasks/rust/Cargo.toml",
        "examples/apps/rooms/rust/Cargo.toml",
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

    // Type-check the TypeScript binding. `deno-dogfood` runs the smoke with
    // `--no-check`, so a type error in the binding would otherwise ship silently;
    // check the public entry points and the dogfood here. The graph is the Deno
    // one: the experimental Node adapter imports `node:ffi`, which Deno cannot
    // resolve, so it stays out (it is `@ts-nocheck` and only loaded under Node).
    const deno_check = b.addSystemCommand(&.{
        "deno",                      "check",
        "stack/mod.ts",              "stack/transport/tcp.ts",
        "stack/transport/inproc.ts", "dogfood/zig_smoke.ts",
        "dogfood/gifter_handoff.ts",
    });
    deno_check.setCwd(b.path("bindings/ts"));
    bindings_fmt_check_step.dependOn(&deno_check.step);

    // Serena's SolidLSP ZLS adapter currently hard-codes build-on-save args to
    // `zig build build`; keep that editor-only alias pointed at the normal
    // install step. The project correctness gate remains `zig build check`.
    const build_step = b.step("build", "Build and install the pancake C ABI archives");
    build_step.dependOn(b.getInstallStep());
}
