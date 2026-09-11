//! glowcap's build manifest: module DAG, archive set, and check steps.
//!
//! `layer_table` is the import graph `arch-check` verifies. `archive_table`
//! names the composable C ABI archives. Helpers below those tables own the
//! repeated build shapes; `build()` registers the steps by section. `source-check`
//! keeps the documented step inventory in sync with `check`, so membership is a
//! checked fact rather than a comment convention.

const std = @import("std");
const execution = @import("tools/build/execution.zig");
const builtin = @import("builtin");
const arch_check = @import("tools/check/arch_check.zig");
const source_check = @import("tools/check/source_check.zig");
const build_common = @import("tools/build/common.zig");
const cli_build = @import("tools/build/cli.zig");
const iroh_build = @import("tools/build/iroh.zig");
const mbedtls_build = @import("tools/build/mbedtls.zig");
const webrtc_build = @import("tools/build/webrtc.zig");
const rooms_build = @import("tools/build/rooms.zig");
const binding_families_build = @import("tools/build/binding_families.zig");
const goblins_build = @import("tools/build/goblins.zig");
const site_build = @import("tools/build/site.zig");
const mark_build = @import("tools/build/mark.zig");
const gates_build = @import("tools/build/gates.zig");
const toolchain_build = @import("tools/build/toolchain.zig");
const gen_build = @import("tools/build/gen.zig");
const examples_build = @import("tools/build/examples.zig");
const bench_build = @import("tools/build/bench.zig");
const conformance_build = @import("tools/build/conformance.zig");
const apps_demos_build = @import("tools/build/apps_demos.zig");
const ocapnviz_steps_build = @import("tools/build/ocapnviz_steps.zig");
const release_build = @import("tools/build/release.zig");
const bindings_steps_build = @import("tools/build/bindings_steps.zig");
const relay_matrix_build = @import("tools/build/relay_matrix.zig");

const glowcapExecutable = build_common.glowcapExecutable;
const addGlowcapRun = build_common.addGlowcapRun;
const addRootedSystemCommand = build_common.addRootedSystemCommand;

/// C ABI version (keep in lockstep with `GLOWCAP_VERSION_*` in
/// `include/glowcap_ocapn.h` and `src/c_abi/ocapn/mod.zig`, and with `.version`
/// in `build.zig.zon` — the source gate holds the zon triple to this one). Each
/// archive's dynamic library soname tracks `major`.
const abi_version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

/// The layer DAG, the one authoritative statement of the architecture
/// (ADR-0040; ADR-0048 for the sibling-codec modules below the codec layer).
/// Every build graph is generated from this table, and `tools/check/arch_check.zig`
/// verifies it against the source tree: a granted edge no file imports fails
/// the gate, so the table carries the edges the code uses, never a wider
/// silent allowance. Rows are in dependency order; the sans-io core graph is
/// the table prefix ending at `actors`, and the final `glowcap` row is
/// `src/root.zig`, the curated public namespace over the layers.
pub const layer_table = [_]arch_check.LayerSpec{
    .{ .name = "foundation", .prefix = "foundation/", .imports = &.{}, .core = true },
    .{ .name = "model", .prefix = "ocapn/model/", .imports = &.{}, .core = true },
    .{ .name = "framing", .prefix = "ocapn/codec/framing.zig", .imports = &.{"model"}, .core = true },
    .{ .name = "codec_order", .prefix = "ocapn/codec/order.zig", .imports = &.{}, .core = true },
    .{ .name = "codec_limits", .prefix = "ocapn/codec/limits.zig", .imports = &.{"model"}, .core = true },
    .{ .name = "syrup", .prefix = "ocapn/codec/syrup/", .imports = &.{ "foundation", "model", "framing", "codec_order", "codec_limits" }, .core = true },
    .{ .name = "capnp", .prefix = "ocapn/codec/capnp/", .imports = &.{ "foundation", "model", "framing", "codec_order", "codec_limits" }, .core = true },
    .{ .name = "codec", .prefix = "ocapn/codec/", .imports = &.{ "foundation", "model", "framing", "codec_order", "codec_limits", "syrup", "capnp" }, .core = true },
    .{ .name = "session", .prefix = "ocapn/session/", .imports = &.{ "foundation", "model" }, .core = true },
    .{ .name = "engine", .prefix = "ocapn/engine/", .imports = &.{ "foundation", "model", "codec", "session" }, .core = true },
    .{ .name = "persistent", .prefix = "persistent/", .imports = &.{}, .core = true },
    .{ .name = "actors", .prefix = "actors/", .imports = &.{ "model", "engine" }, .core = true },
    .{ .name = "net", .prefix = "net/", .imports = &.{ "foundation", "model", "codec", "engine" }, .core = false },
    .{ .name = "oracle", .prefix = "oracle/", .imports = &.{ "foundation", "model", "engine" }, .core = false },
    .{ .name = "driver_core", .prefix = "driver/core/", .imports = &.{ "foundation", "model", "engine", "actors" }, .core = true },
    .{ .name = "driver", .prefix = "driver/", .imports = &.{ "foundation", "model", "engine", "actors", "net", "driver_core" }, .core = false },
    .{ .name = "diagnostics", .prefix = "diagnostics/", .imports = &.{}, .core = false },
    .{ .name = "c_abi_shared", .prefix = "c_abi/shared/", .imports = &.{ "foundation", "model", "engine", "diagnostics" }, .core = false },
    .{ .name = "c_abi", .prefix = "c_abi/ocapn/", .imports = &.{ "model", "engine", "c_abi_shared" }, .core = false },
    .{ .name = "c_abi_net_transport_iroh", .prefix = "c_abi/net_transport/iroh/", .imports = &.{ "model", "net", "c_abi_shared" }, .core = false, .graph = false },
    .{ .name = "c_abi_net_transport_webrtc", .prefix = "c_abi/net_transport/webrtc/", .imports = &.{ "foundation", "c_abi_shared" }, .core = false, .graph = false },
    .{ .name = "c_abi_net_transport_tcp", .prefix = "c_abi/net_transport/tcp/", .imports = &.{ "foundation", "model", "net", "c_abi_shared" }, .core = false, .graph = false },
    .{ .name = "c_abi_net_transport_relay", .prefix = "c_abi/net_transport/relay/", .imports = &.{ "foundation", "model", "net", "c_abi_shared" }, .core = false, .graph = false },
    .{ .name = "c_abi_net_transport_inproc", .prefix = "c_abi/net_transport/inproc/", .imports = &.{ "net", "c_abi_shared" }, .core = false, .graph = false },
    .{ .name = "c_abi_net_transport_onion", .prefix = "c_abi/net_transport/onion/", .imports = &.{ "model", "net", "c_abi_shared" }, .core = false, .graph = false },
    .{ .name = "c_abi_host", .prefix = "c_abi/host/", .imports = &.{ "foundation", "model", "engine", "actors", "driver_core", "c_abi_shared" }, .core = false, .graph = false },
    .{ .name = "c_abi_driver", .prefix = "c_abi/driver/", .imports = &.{ "foundation", "model", "engine", "net", "driver_core", "driver", "c_abi_shared", "c_abi_host" }, .core = false, .graph = false },
    .{ .name = "c_abi_wasm", .prefix = "c_abi/wasm/", .imports = &.{ "c_abi_shared", "c_abi", "c_abi_host" }, .core = false, .graph = false },
    .{ .name = "glowcap", .prefix = "root.zig", .imports = &.{ "foundation", "model", "codec", "session", "engine", "actors", "net", "driver", "c_abi" }, .core = false },
};

/// The composable C ABI archive set (ADR-0059), declared once beside
/// `layer_table`. Each row names an installed archive, the `layer_table` row
/// whose module supplies its C ABI root (the source of its export family), and
/// the public header it ships when the header is not installed by its owning
/// specialized build block. This table
/// drives the per-archive header install loop below and a comptime check that
/// each row's `layer` names a real `layer_table` row. The archives themselves
/// are built at their use sites, where each needs its own root module and link
/// handling; a consumer's link-alongside set is the real link line each C
/// example spells. Each transport embeds its private lower layers as local
/// symbols.
const ArchiveSpec = struct {
    /// Installed library name: `lib<artifact>.a` / `.so`.
    artifact: []const u8,
    /// The `layer_table` row supplying this archive's C ABI root module.
    layer: []const u8,
    /// The public header this archive installs.
    header: ?[]const u8 = null,
    /// False for an archive that links a non-Zig sidecar and so installs only
    /// behind its own sibling step (iroh), never on the default build.
    default_install: bool = true,
    /// Included in the target-specific release bundle. This is independent of
    /// default installation: iroh is release-packaged through its sibling
    /// build, while the experimental WebRTC companion is not published.
    release_install: bool = true,
};
const archive_table = [_]ArchiveSpec{
    .{ .artifact = "glowcap_ocapn", .layer = "c_abi", .header = "glowcap_ocapn.h" },
    .{ .artifact = "glowcap_net_transport_tcp", .layer = "c_abi_net_transport_tcp", .header = "glowcap_net_transport_tcp.h" },
    .{ .artifact = "glowcap_net_transport_relay", .layer = "c_abi_net_transport_relay", .header = "glowcap_net_transport_relay.h" },
    .{ .artifact = "glowcap_net_transport_inproc", .layer = "c_abi_net_transport_inproc", .header = "glowcap_net_transport_inproc.h" },
    .{ .artifact = "glowcap_net_transport_onion", .layer = "c_abi_net_transport_onion", .header = "glowcap_net_transport_onion.h" },
    .{ .artifact = "glowcap_host", .layer = "c_abi_host", .header = "glowcap_host.h" },
    .{ .artifact = "glowcap_driver", .layer = "c_abi_driver", .header = "glowcap_driver.h" },
    .{ .artifact = "glowcap_net_transport_iroh", .layer = "c_abi_net_transport_iroh", .header = "glowcap_net_transport_iroh.h", .default_install = false },
    .{ .artifact = "glowcap_net_transport_webrtc", .layer = "c_abi_net_transport_webrtc", .header = "glowcap_net_transport_webrtc.h", .default_install = false, .release_install = false },
};

const shared_header_table = [_][]const u8{
    "glowcap_locator.h",
    "glowcap_transport_provider.h",
};

comptime {
    // Hold `archive_table` honest against `layer_table`: every archive's root
    // layer must name a real row, so a typo or a removed layer fails the build.
    for (archive_table) |arch| _ = layerIndex(arch.layer);
}

/// Index of `name` in `layer_table`; edges may only point at earlier rows.
pub fn layerIndex(comptime name: []const u8) usize {
    inline for (layer_table, 0..) |spec, i| {
        if (comptime std.mem.eql(u8, spec.name, name)) return i;
    }
    @compileError("layer_table has no row named '" ++ name ++ "'");
}

/// Materialize one module per table row, in order, resolving each row's edges
/// against the earlier rows. Every module is position-independent so each
/// static archive (`libglowcap_ocapn.a`, the transport archives) links cleanly
/// into a PIE consumer (the Rust C ABI dogfood links a static archive into a
/// position-independent test binary;
/// without this, the archive's R_X86_64_32S relocations are rejected at link
/// time). The shared library requires PIC regardless, so both artifacts share
/// one PIC graph.
///
/// When `expose_root` is set, the `glowcap` row is registered through
/// `b.addModule`, so a downstream package's
/// `b.dependency("glowcap", ...).module("glowcap")` resolves to the same graph
/// the artifacts are built from. The cross-target graphs pass false: they are
/// compile-only gates, not the public module.
pub fn graphFromTable(
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
        mods[i] = if (expose_root and std.mem.eql(u8, spec.name, "glowcap"))
            b.addModule("glowcap", create_options)
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

const addInstalledSystemRun = build_common.addInstalledSystemRun;
const installArchive = build_common.installArchive;
const interopHarnessModule = build_common.interopHarnessModule;

const AbiImport = build_common.AbiImport;
const transportAbiModule = build_common.transportAbiModule;

const linkIrohSidecar = build_common.linkIrohSidecar;

const irohDriverModule = build_common.irohDriverModule;

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
    const rooms_diagnostics = b.option(bool, "diagnostics", "When serving the rooms web UI, mint an inspect capability and print its swiss") orelse false;
    const rooms_admin_listeners = b.option(bool, "admin-listeners", "When serving the rooms web UI, mint a listener-admin capability and print its swiss") orelse false;
    const rooms_operator = b.option(bool, "operator", "When serving the rooms web UI, mint a room-steward operator capability and print its swiss") orelse false;
    const rooms_peering = b.option(bool, "peering", "When serving the rooms web UI, mint a directory-peering capability and print its swiss") orelse false;
    const rooms_viz = b.option(bool, "viz", "When serving the rooms web UI, serve the live timeline endpoint (default port 9300; GLOWCAP_ROOMS_VIZ_PORT overrides) and mint the viz capability") orelse false;
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
    const lib_mod = host_mods[layerIndex("glowcap")];

    // The secure relay dependency is an explicit, networked sibling step. The
    // ordinary core library graph never fetches or links it; the secure relay
    // consumer makes this compile step part of its own graph.
    const native_relay = mbedtls_build.addFamily(b, target, optimize, host_mods[layerIndex("foundation")], host_mods[layerIndex("net")]);

    // ── Composable C ABI archives (ADR-0059) ─────────────────────────────────
    // The single umbrella artifact is dropped: each family
    // ships as its own archive linked à la carte, exporting only its
    // `glowcap_<family>_*` symbols and sharing core types by header layout.
    // `libglowcap_ocapn` is the shared vocabulary; each transport is a
    // self-contained companion that embeds its private lower layers as local
    // symbols.
    // The transport roots are minted by `transportAbiModule` because they sit
    // outside the layer DAG; ocapn and net root on their graph modules.
    const tcp_abi_mod = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/tcp/mod.zig", &.{
        .{ .name = "foundation", .module = host_mods[layerIndex("foundation")] },
        .{ .name = "model", .module = host_mods[layerIndex("model")] },
        .{ .name = "net", .module = host_mods[layerIndex("net")] },
        .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
    });
    const inproc_abi_mod = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/inproc/mod.zig", &.{
        .{ .name = "net", .module = host_mods[layerIndex("net")] },
        .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
    });
    const relay_abi = mbedtls_build.relayAbiModules(
        b,
        target,
        optimize,
        native_relay,
        host_mods[layerIndex("foundation")],
        host_mods[layerIndex("model")],
        host_mods[layerIndex("net")],
        host_mods[layerIndex("c_abi_shared")],
    );
    const relay_abi_mod = relay_abi.production;
    const relay_check_abi_mod = relay_abi.check;
    const onion_abi_mod = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/onion/mod.zig", &.{
        .{ .name = "model", .module = host_mods[layerIndex("model")] },
        .{ .name = "net", .module = host_mods[layerIndex("net")] },
        .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
    });
    // These two companions own native cancellation workers. A C ABI archive can
    // be loaded into a process that never ran Zig's executable startup, so Zig's
    // freestanding Linux thread implementation has no initialized TLS template
    // there. Use the host thread runtime for both static and shared consumers;
    // this is also the ordinary threading contract a C library should expose.
    tcp_abi_mod.linkSystemLibrary("c", .{});
    onion_abi_mod.linkSystemLibrary("c", .{});
    // `libglowcap_host`: the byte-fed driver tier over the C ABI (ADR-0072).
    // Roots on its own layer module, importing `driver_core` (the sans-io serve
    // core it wraps) and the shared vocabulary leaf, so it exports only
    // `glowcap_host_*`.
    const host_abi_imports = [_]AbiImport{
        .{ .name = "foundation", .module = host_mods[layerIndex("foundation")] },
        .{ .name = "model", .module = host_mods[layerIndex("model")] },
        .{ .name = "engine", .module = host_mods[layerIndex("engine")] },
        .{ .name = "actors", .module = host_mods[layerIndex("actors")] },
        .{ .name = "driver_core", .module = host_mods[layerIndex("driver_core")] },
        .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
    };
    const host_abi_mod = transportAbiModule(b, target, optimize, "src/c_abi/host/mod.zig", &host_abi_imports);
    const host_archive_mod = transportAbiModule(b, target, optimize, "src/c_abi/host/archive.zig", &host_abi_imports);

    // `libglowcap_driver`: the driver archive (ADR-0112). Roots on its
    // own layer module, importing `driver` (whose `HostRuntime` it steps) and the
    // Host implementation namespace without rooting the Host export family.
    // Owns a `std.Io.Threaded`, so it links libc like the transport archives.
    const driver_abi_imports = [_]AbiImport{
        .{ .name = "foundation", .module = host_mods[layerIndex("foundation")] },
        .{ .name = "model", .module = host_mods[layerIndex("model")] },
        .{ .name = "engine", .module = host_mods[layerIndex("engine")] },
        .{ .name = "net", .module = host_mods[layerIndex("net")] },
        .{ .name = "driver_core", .module = host_mods[layerIndex("driver_core")] },
        .{ .name = "driver", .module = host_mods[layerIndex("driver")] },
        .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
        .{ .name = "c_abi_host", .module = host_abi_mod },
    };
    const driver_abi_mod = transportAbiModule(b, target, optimize, "src/c_abi/driver/mod.zig", &driver_abi_imports);
    const driver_archive_mod = transportAbiModule(b, target, optimize, "src/c_abi/driver/archive.zig", &driver_abi_imports);
    driver_abi_mod.linkSystemLibrary("c", .{});
    driver_archive_mod.linkSystemLibrary("c", .{});

    // The static lib of each archive, kept so the C examples can link the
    // composed set the consumer would. `libglowcap_ocapn` roots on the `c_abi`
    // (ocapn) layer module directly — the same module the ocapn header generator
    // reflects over — so it exports exactly the sans-io ocapn family and nothing
    // the `glowcap` root module would otherwise drag in.
    const ocapn_archive = installArchive(b, "glowcap_ocapn", host_mods[layerIndex("c_abi")], abi_version);
    const ocapn_static = ocapn_archive.static;
    const tcp_archive = installArchive(b, "glowcap_net_transport_tcp", tcp_abi_mod, abi_version);
    const relay_archive = installArchive(b, "glowcap_net_transport_relay", relay_abi_mod, abi_version);
    mbedtls_build.addArchiveChecks(b, target, optimize, native_relay.secure_check, relay_archive.static, relay_archive.dynamic);
    _ = installArchive(b, "glowcap_net_transport_inproc", inproc_abi_mod, abi_version);
    const onion_archive = installArchive(b, "glowcap_net_transport_onion", onion_abi_mod, abi_version);
    const host_archive = installArchive(b, "glowcap_host", host_archive_mod, abi_version);
    const host_static = host_archive.static;
    const driver_archive = installArchive(b, "glowcap_driver", driver_archive_mod, abi_version);

    // Install each archive's public header.
    inline for (archive_table) |arch| {
        if (arch.header) |hdr| {
            if (arch.default_install) {
                const install_hdr = b.addInstallHeaderFile(b.path(b.fmt("include/{s}", .{hdr})), hdr);
                b.getInstallStep().dependOn(&install_hdr.step);
            }
        }
    }
    inline for (shared_header_table) |hdr| {
        const install_hdr = b.addInstallHeaderFile(b.path(b.fmt("include/{s}", .{hdr})), hdr);
        b.getInstallStep().dependOn(&install_hdr.step);
    }

    // ── The gate and its members ─────────────────────────────────────────────
    // The hermetic gate registers from tools/build/gates.zig: `check`, the
    // suites, fuzz wiring, the structure gates, cross-compile, and the wasm32
    // Host family. The handles come back for everything below.
    const gates = gates_build.register(.{
        .b = b,
        .target = target,
        .optimize = optimize,
        .lib_mod = lib_mod,
        .host_mods = host_mods,
        .tcp_abi_mod = tcp_abi_mod,
        .relay_check_abi_mod = relay_check_abi_mod,
        .inproc_abi_mod = inproc_abi_mod,
        .onion_abi_mod = onion_abi_mod,
        .host_abi_mod = host_abi_mod,
        .driver_abi_mod = driver_abi_mod,
    });
    const check_step = gates.check_step;
    const test_filter = gates.test_filter;
    const wasm_driver_install_step = gates.wasm_install;

    // The generated headers and binding mirrors register from
    // tools/build/gen.zig; the resident-dependent rows join below once the
    // iroh and WebRTC residents exist.
    const gen_support = gen_build.createSupport(b, target, optimize, host_mods);
    const gen_reflected_archives = gen_build.ReflectedArchives{
        .tcp = tcp_abi_mod,
        .inproc = inproc_abi_mod,
        .relay = relay_check_abi_mod,
        .onion = onion_abi_mod,
    };
    const gen_ctx = gen_build.Context{
        .b = b,
        .target = target,
        .optimize = optimize,
        .check_step = check_step,
        .host_mods = host_mods,
        .host_abi_mod = host_abi_mod,
        .driver_abi_mod = driver_abi_mod,
        .reflected_archives = gen_reflected_archives,
        .support = gen_support,
    };
    gen_build.register(gen_ctx);

    // The documentation site pipeline (autodoc, the transport example
    // snippets and their per-language checks, the Zine render, and the local
    // preview) registers as one subject from tools/build/site.zig; the
    // language-check handles come back for the `bindings` aggregate.

    // ── Browser proofs: one preflight for all of them ────────────────────────
    // Every step that drives a real headless Chromium depends on this. The
    // devcontainer ships the browser in its image, so an absent one means the
    // image predates that or the build is running somewhere else, and Playwright's
    // own error names a remedy this project does not use. The script says which
    // version to install and where the version is written; every browser step
    // borrows that one answer rather than restating it in a header comment.
    const browser_preflight = execution.addSystemCommand(b, .build_tool, &.{ "bash", "tools/check/playwright-preflight.sh" });
    browser_preflight.setCwd(b.path("."));
    browser_preflight.has_side_effects = true;

    mark_build.register(b, &browser_preflight.step);

    const site_reg = site_build.register(.{
        .b = b,
        .target = target,
        .optimize = optimize,
        .lib_mod = lib_mod,
        .model_mod = host_mods[layerIndex("model")],
        .check_step = check_step,
        .pin_port = pin_port,
        .browser_preflight = &browser_preflight.step,
    });
    mbedtls_build.addSiteRelayExamples(
        b,
        target,
        optimize,
        lib_mod,
        native_relay.check_relay,
        site_reg.zig_examples_check,
    );

    // The examples register from tools/build/examples.zig; all of them ride
    // `check`.
    examples_build.register(b, target, optimize, lib_mod, check_step, ocapn_static, host_static);
    // Optimize mode is per-module: every consumer that claims optimized
    // glowcap figures imports this dedicated ReleaseFast graph, never
    // `lib_mod`. The benches and their `perf-check` tripwire register from
    // tools/build/bench.zig; the Cap'n Proto fixture generator joins the gen
    // family it belongs to.
    const fast_lib_mod = graphFromTable(b, target, .ReleaseFast, &layer_table, false)[layerIndex("glowcap")];
    bench_build.register(b, target, optimize, lib_mod, fast_lib_mod, host_mods, check_step);
    gen_build.registerCapnpFixtures(b, target, optimize, lib_mod, check_step);

    // The per-language dogfoods and their aggregates register from
    // tools/build/bindings_steps.zig; the iroh-dependent wiring joins below,
    // where the iroh ABI steps exist.
    const bindings_reg = bindings_steps_build.register(b, site_reg);
    const bindings_step = bindings_reg.bindings_step;
    const dogfood_runs = bindings_reg.dogfood_runs;

    // Shared Zig interop-driver harness, one instance for every interop
    // executable (the goblins family's drivers and the iroh drivers below).
    const interop_harness_mod = interopHarnessModule(b, target, optimize, lib_mod);

    // The live external-authority family (every conversation against a real
    // Goblins vat, the live transport-scale and Tor proofs, and the
    // cross-implementation benches) registers as one subject from
    // tools/build/goblins.zig; the handles come back for `check-external`.
    const goblins_reg = goblins_build.register(.{
        .b = b,
        .target = target,
        .optimize = optimize,
        .lib_mod = lib_mod,
        .fast_lib_mod = fast_lib_mod,
        .interop_harness_mod = interop_harness_mod,
        .check_step = check_step,
        .pin_port = pin_port,
    });

    // The runtime plumbing both Rust sidecars share (transports/sidecar-common)
    // is tested on its own; each sidecar's cargo build pulls it in by path.
    build_common.registerSidecarCommon(b);

    // The iroh netlayer family (sidecar, resident, live drivers, the
    // ADR-0112 seam, the site snippets and locator suite, and the C ABI
    // companion) registers from tools/build/iroh.zig.
    const iroh_reg = iroh_build.registerSteps(.{
        .b = b,
        .target = target,
        .optimize = optimize,
        .abi_version = abi_version,
        .lib_mod = lib_mod,
        .host_mods = host_mods,
        .host_abi_mod = host_abi_mod,
        .driver_abi_mod = driver_abi_mod,
        .interop_harness_mod = interop_harness_mod,
        .check_step = check_step,
        .site_zig_examples_check = site_reg.zig_examples_check,
    });
    const iroh_resident_mod = iroh_reg.resident_mod;
    const iroh_sidecar_archive = iroh_reg.sidecar_archive;
    const iroh_abi_step = iroh_reg.abi_step;
    for (bindings_steps_build.dogfoods, dogfood_runs) |dogfood, run| {
        if (dogfood.needs_iroh_abi) run.step.dependOn(iroh_abi_step);
    }
    bindings_step.dependOn(iroh_reg.abi_test_step);

    // The WebRTC DataChannel netlayer family (ADR-0089) registers as one
    // subject from tools/build/webrtc.zig: the sidecar's cargo steps, the
    // hermetic compile objects that ride `check`, the live interop and
    // browser proofs, the driver-provider seam, and the public C ABI
    // companion. The resident module comes back for the generated-header and
    // binding-layout steps below, which mint their own C ABI modules over it.
    const webrtc_reg = webrtc_build.register(.{
        .b = b,
        .target = target,
        .optimize = optimize,
        .abi_version = abi_version,
        .lib_mod = lib_mod,
        .foundation_mod = host_mods[layerIndex("foundation")],
        .model_mod = host_mods[layerIndex("model")],
        .engine_mod = host_mods[layerIndex("engine")],
        .net_mod = host_mods[layerIndex("net")],
        .c_abi_shared_mod = host_mods[layerIndex("c_abi_shared")],
        .host_abi_mod = host_abi_mod,
        .driver_abi_mod = driver_abi_mod,
        .interop_harness_mod = interop_harness_mod,
        .check_step = check_step,
        .browser_preflight = &browser_preflight.step,
        .wasm_driver_install = wasm_driver_install_step,
    });
    const webrtc_resident_mod = webrtc_reg.resident_mod;

    // Hermetic type-check of the public iroh C ABI: an object, so its externs
    // need no definition, `zig build check` catches rot in this module (and the
    // resident surface it drives) without cargo. Linking stays in `iroh-abi`.
    const iroh_abi_check_mod = gen_build.irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod);
    const iroh_abi_check = b.addObject(.{
        .name = "iroh-abi-check",
        .root_module = iroh_abi_check_mod,
    });
    check_step.dependOn(&iroh_abi_check.step);

    // `include/glowcap_net_transport_iroh.h` and the binding FFI layout facts

    gen_build.registerMirrors(gen_ctx, iroh_resident_mod, webrtc_resident_mod);

    // The per-binding client families (the `bindings-*` aggregates and their
    // per-language rows) register from tools/build/binding_families.zig.
    binding_families_build.register(b, pin_port, iroh_abi_step);

    // Release packaging consumes the archive table directly. The stage copies
    // only these names, so a dirty zig-out cannot leak another target or an
    // internal artifact into a published bundle.
    var release_static_archives: std.ArrayList([]const u8) = .empty;
    var release_dynamic_archives: std.ArrayList([]const u8) = .empty;
    var release_headers: std.ArrayList([]const u8) = .empty;
    for (archive_table) |arch| {
        if (!arch.release_install) continue;
        if (arch.default_install) release_static_archives.append(b.allocator, arch.artifact) catch @panic("OOM");
        release_dynamic_archives.append(b.allocator, arch.artifact) catch @panic("OOM");
        if (arch.header) |header| release_headers.append(b.allocator, header) catch @panic("OOM");
    }
    for (shared_header_table) |header| release_headers.append(b.allocator, header) catch @panic("OOM");
    release_build.register(b, target, optimize, abi_version, iroh_abi_step, .{
        .static_archives = release_static_archives.items,
        .dynamic_archives = release_dynamic_archives.items,
        .headers = release_headers.items,
        .binaries = &.{ "glowcap", "rooms-peer" },
    });
    // External conformance pressure registers from tools/build/conformance.zig,
    // bundling the upstream suite, the findings, corpus parity, and the live
    // Goblins steps into `check-external`.
    conformance_build.register(b, target, optimize, lib_mod, check_step, pin_port, goblins_reg);
    // ── Cross-language application demos (siblings of `check`) ───────────────
    // The Zig demo clients' shared helper modules under
    // `apps/_demo/zig/`: the typed room-error vocabulary, the
    // one-shot usage printer, and the tools capability checklist. Each std-only
    // leaf is minted once and imported by the clients that name it.
    const demo_rooms_cli_mod = b.createModule(.{ .root_source_file = b.path("apps/_demo/zig/rooms_cli.zig"), .target = target, .optimize = optimize });
    const demo_usage_mod = b.createModule(.{ .root_source_file = b.path("apps/_demo/zig/usage.zig"), .target = target, .optimize = optimize });
    const demo_tools_check_mod = b.createModule(.{ .root_source_file = b.path("apps/_demo/zig/tools_check.zig"), .target = target, .optimize = optimize });

    // The rooms application family (native clients, the hermetic suite that
    // rides `check`, the demos, the browser UI serves, the rooms-web proofs,
    // and deploy prep) registers as one subject from tools/build/rooms.zig.
    // The product CLI below stays here as its own subject.
    const rooms_native_install = rooms_build.register(.{
        .b = b,
        .target = target,
        .optimize = optimize,
        .lib_mod = lib_mod,
        .iroh_resident_mod = iroh_resident_mod,
        .demo_rooms_cli_mod = demo_rooms_cli_mod,
        .demo_usage_mod = demo_usage_mod,
        .check_step = check_step,
        .browser_preflight = &browser_preflight.step,
        .wasm_driver_install = wasm_driver_install_step,
        .wasm_archives = gates.wasm_archives,
        .iroh_abi_step = iroh_abi_step,
        .iroh_sidecar_archive = iroh_sidecar_archive,
        .ocapn_install = &ocapn_archive.dynamic_install.step,
        .host_install = &host_archive.dynamic_install.step,
        .driver_install = &driver_archive.dynamic_install.step,
        .tcp_install = &tcp_archive.dynamic_install.step,
        .relay_install = &relay_archive.dynamic_install.step,
        .pin_port = pin_port,
        .attach = attach,
        .diagnostics = rooms_diagnostics,
        .admin_listeners = rooms_admin_listeners,
        .operator = rooms_operator,
        .peering = rooms_peering,
        .viz = rooms_viz,
    });

    // The cross-runtime relay matrix and the live Goblins relay/rooms proofs
    // register from tools/build/relay_matrix.zig.
    relay_matrix_build.register(b, pin_port, wasm_driver_install_step, &browser_preflight.step, iroh_abi_step, rooms_native_install);

    cli_build.add(b, .{
        .target = target,
        .optimize = optimize,
        .glowcap = lib_mod,
        .iroh = iroh_resident_mod,
        .native_relay = native_relay.relay,
        .check_relay = native_relay.check_relay,
        .version = abi_version,
        .iroh_sidecar_archive = iroh_sidecar_archive,
        .check = check_step,
        .test_filter = test_filter,
    });

    // The tasks, tools, and accountability applications register from
    // tools/build/apps_demos.zig.
    apps_demos_build.register(b, target, optimize, lib_mod, check_step, pin_port, attach, demo_usage_mod, demo_tools_check_mod);

    // The formatting and per-scope checks register from
    // tools/build/bindings_steps.zig, over the archives and dogfood runs.
    bindings_steps_build.registerChecks(b, check_step, &onion_archive.dynamic_install.step, bindings_reg);

    // The ocapnviz visualizer's steps register from tools/build/ocapnviz_steps.zig.
    ocapnviz_steps_build.register(b, check_step, wasm_driver_install_step, &browser_preflight.step, rooms_native_install);

    // Finalize graph-level runtime policing after every registrar has had a
    // chance to add members to `check`.
    toolchain_build.register(b, check_step, target, optimize);

    // Serena's SolidLSP ZLS adapter currently hard-codes build-on-save args to
    // `zig build build`; keep that editor-only alias pointed at the normal
    // install step. The project correctness gate remains `zig build check`.
    const build_step = b.step("build", "Build and install the glowcap C ABI archives");
    build_step.dependOn(b.getInstallStep());
}
