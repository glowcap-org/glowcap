//! The Zig modules and executables the build graph mints over the public
//! `glowcap` module, the transport and interop-harness module shapes, and the
//! baseline target they build for.

const std = @import("std");

/// Resolve `-Dtarget`/`-Dcpu` with the baseline CPU as the default, the one
/// releases ship, and build every host tool for it too. Selecting the host's
/// CPU keys each compile on the model of whichever core ran the build process, so
/// heterogeneous cores and the separate machines of CI build and test jobs
/// each miss the others' cache. Call it first in `build`, before any
/// dependency configures, so their generators use the same host. Measure the
/// host with -Dcpu=native.
pub fn baselineTarget(b: *std.Build) std.Build.ResolvedTarget {
    b.graph.host = b.resolveTargetQuery(.{ .cpu_model = .baseline });
    return b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
}

/// Build one executable over the public `glowcap` module.
pub fn glowcapExecutable(
    b: *std.Build,
    lib_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root_source: []const u8,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(root_source),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("glowcap", lib_mod);
    return b.addExecutable(.{ .name = name, .root_module = module });
}

pub const AbiImport = struct { name: []const u8, module: *std.Build.Module };

/// A module over a transport's public C ABI root (`src/c_abi/net_transport/<transport>/mod.zig`),
/// the generalization of the iroh companion (ADR-0021) to every transport
/// archive (ADR-0022). Minted fresh per call so the artifact, the hermetic check
/// object, and the header generator can each have their own (no source file
/// lands in two modules of one compilation). `imports` supplies the layer
/// instances the transport draws on, always the shared vocabulary leaf
/// (`c_abi_shared`), never the `c_abi` ocapn root, so the artifact stays
/// symbol-disjoint from `libglowcap_ocapn`. These are the `.graph = false`
/// `c_abi_*` rows' only materialization: they sit outside the layer DAG because
/// a transport's injected sidecar resident is not a DAG edge.
pub fn transportAbiModule(
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

/// The shared Zig interop-driver harness (`interop/_common/zig/harness.zig`),
/// imported as `interop_harness` by every Zig interop executable. Scaffolding
/// like `test/support`, so it sits outside the `src/` layer DAG. The wait
/// vocabulary is `test/support/wait.zig` itself, handed in as `support_wait`
/// so the two scaffolding trees share one owner instead of hand-synced copies.
pub fn interopHarnessModule(
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
    mod.addImport("glowcap", lib_mod);
    mod.addImport("support_wait", wait_mod);
    return mod;
}

/// The C ABI glue the two driver-provider seam proofs share
/// (`interop/_common/zig/driver_provider.zig`), imported as
/// `interop_driver_provider`. It reads the `c_abi_shared` and `c_abi_driver`
/// instances the proof itself imports, so every export lands once.
pub fn interopDriverProviderModule(
    b: *std.Build,
    t: std.Build.ResolvedTarget,
    o: std.builtin.OptimizeMode,
    c_abi_shared: *std.Build.Module,
    c_abi_driver: *std.Build.Module,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("interop/_common/zig/driver_provider.zig"),
        .target = t,
        .optimize = o,
    });
    mod.addImport("c_abi_shared", c_abi_shared);
    mod.addImport("c_abi_driver", c_abi_driver);
    return mod;
}
