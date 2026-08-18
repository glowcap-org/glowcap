//! The generated headers and binding mirrors (per archive; ADR-0059): one
//! shared verify/emit harness, the base header rows over the pure-Zig
//! archives, and the resident-dependent rows — the iroh and WebRTC headers
//! plus the Rust, Racket, Python, TypeScript-layout, and constants mirrors —
//! that join once the residents exist. `*-check` steps ride `check`; the
//! bare steps rewrite in place.

const std = @import("std");
const root = @import("../../build.zig");
const common = @import("common.zig");

const AbiImport = common.AbiImport;
const transportAbiModule = common.transportAbiModule;
const layerIndex = root.layerIndex;
const iroh_build = @import("iroh.zig");
const webrtc_build = @import("webrtc.zig");

/// The iroh C ABI module: `transportAbiModule` over
/// `src/c_abi/net_transport/iroh/mod.zig` with the injected `iroh` resident
/// alongside the shared layer instances. The shared vocabulary leaf (not the
/// `c_abi` ocapn root) keeps `libpancake_net_transport_iroh` symbol-disjoint
/// from `libpancake_ocapn`.
pub fn irohAbiModule(
    b: *std.Build,
    t: std.Build.ResolvedTarget,
    o: std.builtin.OptimizeMode,
    host_mods: []*std.Build.Module,
    resident: *std.Build.Module,
) *std.Build.Module {
    return iroh_build.abiModule(b, t, o, host_mods[layerIndex("model")], host_mods[layerIndex("net")], host_mods[layerIndex("c_abi_shared")], resident);
}

/// The webrtc C ABI module over `host_mods`; the body lives with the WebRTC
/// family in `tools/build/webrtc.zig` (ADR-0089 phase 3, mirroring
/// `irohAbiModule`), and this adapter only resolves the layer instances.
pub fn webrtcAbiModule(
    b: *std.Build,
    t: std.Build.ResolvedTarget,
    o: std.builtin.OptimizeMode,
    host_mods: []*std.Build.Module,
    resident: *std.Build.Module,
) *std.Build.Module {
    return webrtc_build.abiModule(b, t, o, host_mods[layerIndex("foundation")], host_mods[layerIndex("c_abi_shared")], resident);
}

const HeaderGen = struct {
    check_step_name: []const u8,
    check_desc: []const u8,
    write_step_name: []const u8,
    write_desc: []const u8,
    generator: []const u8,
    import_name: []const u8,
    import_module: *std.Build.Module,
    /// Additional reflected modules, for a generator that mirrors more than
    /// one archive (the TS mirror and the FFI generators each cover several
    /// transport archives). One slice, so a name can never be set without its
    /// module and there is no fixed ceiling on how many a generator reflects.
    extra_imports: []const AbiImport = &.{},
};

fn addHeaderGen(bb: *std.Build, check_agg: *std.Build.Step, tgt: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, hg: HeaderGen) void {
    const gen_mod = bb.createModule(.{
        .root_source_file = bb.path(hg.generator),
        .target = tgt,
        .optimize = opt,
    });
    gen_mod.addImport(hg.import_name, hg.import_module);
    for (hg.extra_imports) |imp| gen_mod.addImport(imp.name, imp.module);
    // Available to every generator; the emit/verify harness roots
    // force-link these so reflecting a transport archive that calls a
    // Rust sidecar stays cargo-free without each generator remembering.
    gen_mod.addImport("iroh_sidecar_stub", bb.createModule(.{
        .root_source_file = bb.path("tools/gen/stub/iroh_sidecar.zig"),
        .target = tgt,
        .optimize = opt,
    }));
    gen_mod.addImport("webrtc_sidecar_stub", bb.createModule(.{
        .root_source_file = bb.path("tools/gen/stub/webrtc_sidecar.zig"),
        .target = tgt,
        .optimize = opt,
    }));
    // The one output descriptor (`{ path, generate }`) every generator
    // lists in its `outputs` slice, shared so no generator redeclares it.
    gen_mod.addImport("output", bb.createModule(.{
        .root_source_file = bb.path("tools/gen/output.zig"),
        .target = tgt,
        .optimize = opt,
    }));
    // Comptime reflection helpers (e.g. `baseName`) shared by the
    // header and FFI generators, so no generator redeclares them.
    gen_mod.addImport("reflect", bb.createModule(.{
        .root_source_file = bb.path("tools/gen/reflect.zig"),
        .target = tgt,
        .optimize = opt,
    }));

    const check_mod = bb.createModule(.{
        .root_source_file = bb.path("tools/gen/verify.zig"),
        .target = tgt,
        .optimize = opt,
    });
    check_mod.addImport("generator", gen_mod);
    check_mod.addImport("iroh_sidecar_stub", gen_mod.import_table.get("iroh_sidecar_stub").?);
    check_mod.addImport("webrtc_sidecar_stub", gen_mod.import_table.get("webrtc_sidecar_stub").?);
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
    write_mod.addImport("iroh_sidecar_stub", gen_mod.import_table.get("iroh_sidecar_stub").?);
    write_mod.addImport("webrtc_sidecar_stub", gen_mod.import_table.get("webrtc_sidecar_stub").?);
    const write_exe = bb.addExecutable(.{ .name = hg.write_step_name, .root_module = write_mod });
    const write_run = bb.addRunArtifact(write_exe);
    write_run.setCwd(bb.path("."));
    write_run.has_side_effects = true;
    const write_step_h = bb.step(hg.write_step_name, hg.write_desc);
    write_step_h.dependOn(&write_run.step);
}

pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    check_step: *std.Build.Step,
    host_mods: []*std.Build.Module,
    host_abi_mod: *std.Build.Module,
    driver_abi_mod: *std.Build.Module,
    relay_check_abi_mod: *std.Build.Module,
};

/// The base rows: every generator that needs no injected sidecar resident.
pub fn register(ctx: Context) void {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const check_step = ctx.check_step;
    const host_mods = ctx.host_mods;
    const host_abi_mod = ctx.host_abi_mod;
    const driver_abi_mod = ctx.driver_abi_mod;
    const relay_check_abi_mod = ctx.relay_check_abi_mod;

    // ── Generated headers / binding mirrors (per archive; ADR-0059) ──────────
    // Each archive's header is generated from its C ABI module (reflected
    // layouts, constant values, and function signatures): the Zig source is the
    // single source of truth. `include/pancake_ocapn.h` carries the shared
    // vocabulary and the peer/uri families. Multi-session CapTP product
    // work uses `pancake_host_*` in `pancake_host.h`.
    // `include/pancake_net_transport_tcp.h` and `include/pancake_net_transport_inproc.h`
    // `#include` the ocapn header and add their transport family. The `*-check`
    // steps ride `check` and fail when a committed header is stale; the bare
    // steps are the fixers that rewrite in place. Every row drives the shared
    // `tools/gen/verify.zig` / `tools/gen/emit.zig` harness with the concrete
    // generator as `@import("generator")`.
    const header_gens = [_]HeaderGen{
        .{
            .check_step_name = "gen-header-locator-check",
            .check_desc = "Verify include/pancake_locator.h matches the shared locator ABI (fails if stale)",
            .write_step_name = "gen-header-locator",
            .write_desc = "Regenerate include/pancake_locator.h from c_abi/shared/locator.zig",
            .generator = "tools/gen/header/locator.zig",
            .import_name = "c_abi_shared",
            .import_module = host_mods[layerIndex("c_abi_shared")],
        },
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
            .check_step_name = "gen-header-host-check",
            .check_desc = "Verify include/pancake_host.h matches src/c_abi/host (fails if stale)",
            .write_step_name = "gen-header-host",
            .write_desc = "Regenerate include/pancake_host.h from src/c_abi/host",
            .generator = "tools/gen/header/host.zig",
            .import_name = "c_abi_host",
            .import_module = host_abi_mod,
        },
        .{
            .check_step_name = "gen-header-transport-provider-check",
            .check_desc = "Verify include/pancake_transport_provider.h matches the shared provider ABI (fails if stale)",
            .write_step_name = "gen-header-transport-provider",
            .write_desc = "Regenerate include/pancake_transport_provider.h from c_abi/shared",
            .generator = "tools/gen/header/transport_provider.zig",
            .import_name = "c_abi_shared",
            .import_module = host_mods[layerIndex("c_abi_shared")],
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
                .{ .name = "foundation", .module = host_mods[layerIndex("foundation")] },
                .{ .name = "model", .module = host_mods[layerIndex("model")] },
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
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
            .check_step_name = "gen-header-net-transport-relay-check",
            .check_desc = "Verify include/pancake_net_transport_relay.h matches src/c_abi/net_transport/relay (fails if stale)",
            .write_step_name = "gen-header-net-transport-relay",
            .write_desc = "Regenerate include/pancake_net_transport_relay.h from src/c_abi/net_transport/relay",
            .generator = "tools/gen/header/net_relay.zig",
            .import_name = "c_abi_net_transport_relay",
            .import_module = relay_check_abi_mod,
        },
        .{
            .check_step_name = "gen-header-net-transport-onion-check",
            .check_desc = "Verify include/pancake_net_transport_onion.h matches src/c_abi/net_transport/onion (fails if stale)",
            .write_step_name = "gen-header-net-transport-onion",
            .write_desc = "Regenerate include/pancake_net_transport_onion.h from src/c_abi/net_transport/onion",
            .generator = "tools/gen/header/net_onion.zig",
            .import_name = "c_abi_net_transport_onion",
            .import_module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/onion/mod.zig", &.{
                .{ .name = "model", .module = host_mods[layerIndex("model")] },
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }),
        },
        .{
            .check_step_name = "gen-binding-host-action-check",
            .check_desc = "Verify binding HostAction decode/types match src/c_abi/host (fails if stale)",
            .write_step_name = "gen-binding-host-action",
            .write_desc = "Regenerate binding HostAction decode/types from src/c_abi/host",
            .generator = "tools/gen/binding/host_action.zig",
            .import_name = "c_abi_host",
            .import_module = host_abi_mod,
        },
    };

    for (header_gens) |hg| {
        addHeaderGen(b, check_step, target, optimize, hg);
    }
}

/// The resident-dependent rows: the iroh and WebRTC headers and every
/// binding mirror that reflects them, joined once the resident modules
/// exist.
pub fn registerMirrors(
    ctx: Context,
    iroh_resident_mod: *std.Build.Module,
    webrtc_resident_mod: *std.Build.Module,
) void {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const check_step = ctx.check_step;
    const host_mods = ctx.host_mods;
    const host_abi_mod = ctx.host_abi_mod;
    const driver_abi_mod = ctx.driver_abi_mod;
    const relay_check_abi_mod = ctx.relay_check_abi_mod;

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
        .check_step_name = "gen-header-net-transport-webrtc-check",
        .check_desc = "Verify include/pancake_net_transport_webrtc.h matches src/c_abi/net_transport/webrtc/mod.zig (fails if stale)",
        .write_step_name = "gen-header-net-transport-webrtc",
        .write_desc = "Regenerate include/pancake_net_transport_webrtc.h from src/c_abi/net_transport/webrtc/mod.zig",
        .generator = "tools/gen/header/webrtc.zig",
        .import_name = "c_abi_net_transport_webrtc",
        .import_module = webrtcAbiModule(b, target, optimize, host_mods, webrtc_resident_mod),
        .extra_imports = &.{
            .{ .name = "webrtc_sidecar_stub", .module = b.createModule(.{ .root_source_file = b.path("tools/gen/stub/webrtc_sidecar.zig"), .target = target, .optimize = optimize }) },
        },
    });
    addHeaderGen(b, check_step, target, optimize, .{
        .check_step_name = "gen-binding-rust-ffi-check",
        .check_desc = "Verify the generated Rust extern blocks match src/c_abi (fails if stale)",
        .write_step_name = "gen-binding-rust-ffi",
        .write_desc = "Regenerate the Rust binding's extern blocks from src/c_abi (types reflected, names from the generated headers)",
        .generator = "tools/gen/binding/rust_ffi.zig",
        .import_name = "c_abi_net_transport_iroh",
        .import_module = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod),
        .extra_imports = &.{
            .{ .name = "c_abi", .module = host_mods[layerIndex("c_abi")] },
            .{ .name = "c_abi_host", .module = host_abi_mod },
            .{ .name = "c_abi_driver", .module = driver_abi_mod },
            .{ .name = "c_abi_net_transport_tcp", .module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/tcp/mod.zig", &.{
                .{ .name = "foundation", .module = host_mods[layerIndex("foundation")] },
                .{ .name = "model", .module = host_mods[layerIndex("model")] },
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "driver", .module = host_mods[layerIndex("driver")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }) },
            .{ .name = "c_abi_net_transport_inproc", .module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/inproc/mod.zig", &.{
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }) },
            .{ .name = "c_abi_net_transport_onion", .module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/onion/mod.zig", &.{
                .{ .name = "model", .module = host_mods[layerIndex("model")] },
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }) },
            .{ .name = "c_abi_net_transport_relay", .module = relay_check_abi_mod },
            .{ .name = "c_abi_net_transport_webrtc", .module = webrtcAbiModule(b, target, optimize, host_mods, webrtc_resident_mod) },
        },
    });
    addHeaderGen(b, check_step, target, optimize, .{
        .check_step_name = "gen-binding-racket-ffi-check",
        .check_desc = "Verify the generated Racket FFI tables match src/c_abi (fails if stale)",
        .write_step_name = "gen-binding-racket-ffi",
        .write_desc = "Regenerate the Racket binding's FFI tables from src/c_abi (types reflected, wrapper argument names from the generated headers)",
        .generator = "tools/gen/binding/racket_ffi.zig",
        .import_name = "c_abi_net_transport_iroh",
        .import_module = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod),
        .extra_imports = &.{
            .{ .name = "c_abi", .module = host_mods[layerIndex("c_abi")] },
            .{ .name = "c_abi_host", .module = host_abi_mod },
            .{ .name = "c_abi_driver", .module = driver_abi_mod },
            .{ .name = "c_abi_net_transport_tcp", .module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/tcp/mod.zig", &.{
                .{ .name = "foundation", .module = host_mods[layerIndex("foundation")] },
                .{ .name = "model", .module = host_mods[layerIndex("model")] },
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "driver", .module = host_mods[layerIndex("driver")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }) },
            .{ .name = "c_abi_net_transport_inproc", .module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/inproc/mod.zig", &.{
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }) },
            .{ .name = "c_abi_net_transport_onion", .module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/onion/mod.zig", &.{
                .{ .name = "model", .module = host_mods[layerIndex("model")] },
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }) },
            .{ .name = "c_abi_net_transport_relay", .module = relay_check_abi_mod },
            .{ .name = "c_abi_net_transport_webrtc", .module = webrtcAbiModule(b, target, optimize, host_mods, webrtc_resident_mod) },
        },
    });
    addHeaderGen(b, check_step, target, optimize, .{
        .check_step_name = "gen-binding-python-ffi-check",
        .check_desc = "Verify the generated Python ctypes signature tables match src/c_abi (fails if stale)",
        .write_step_name = "gen-binding-python-ffi",
        .write_desc = "Regenerate the Python binding's ctypes signature tables from src/c_abi (types reflected; the sigs dicts are positional)",
        .generator = "tools/gen/binding/python_ffi.zig",
        .import_name = "c_abi_net_transport_iroh",
        .import_module = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod),
        .extra_imports = &.{
            .{ .name = "c_abi", .module = host_mods[layerIndex("c_abi")] },
            .{ .name = "c_abi_host", .module = host_abi_mod },
            .{ .name = "c_abi_driver", .module = driver_abi_mod },
            .{ .name = "c_abi_net_transport_tcp", .module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/tcp/mod.zig", &.{
                .{ .name = "foundation", .module = host_mods[layerIndex("foundation")] },
                .{ .name = "model", .module = host_mods[layerIndex("model")] },
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "driver", .module = host_mods[layerIndex("driver")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }) },
            .{ .name = "c_abi_net_transport_inproc", .module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/inproc/mod.zig", &.{
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }) },
            .{ .name = "c_abi_net_transport_onion", .module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/onion/mod.zig", &.{
                .{ .name = "model", .module = host_mods[layerIndex("model")] },
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }) },
            .{ .name = "c_abi_net_transport_relay", .module = relay_check_abi_mod },
            .{ .name = "c_abi_net_transport_webrtc", .module = webrtcAbiModule(b, target, optimize, host_mods, webrtc_resident_mod) },
        },
    });
    addHeaderGen(b, check_step, target, optimize, .{
        .check_step_name = "gen-binding-ffi-layouts-check",
        .check_desc = "Verify binding FFI layout facts match src/c_abi (fails if stale)",
        .write_step_name = "gen-binding-ffi-layouts",
        .write_desc = "Regenerate binding FFI layout facts from src/c_abi (the ocapn, driver, iroh, and WebRTC transport archives)",
        .generator = "tools/gen/binding/ffi_layouts.zig",
        .import_name = "c_abi",
        .import_module = host_mods[layerIndex("c_abi")],
        .extra_imports = &.{
            .{ .name = "c_abi_host", .module = host_abi_mod },
            .{ .name = "c_abi_driver", .module = driver_abi_mod },
            .{ .name = "c_abi_net_transport_tcp", .module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/tcp/mod.zig", &.{
                .{ .name = "foundation", .module = host_mods[layerIndex("foundation")] },
                .{ .name = "model", .module = host_mods[layerIndex("model")] },
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "driver", .module = host_mods[layerIndex("driver")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }) },
            .{ .name = "c_abi_net_transport_iroh", .module = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod) },
            .{ .name = "c_abi_net_transport_relay", .module = relay_check_abi_mod },
            .{ .name = "c_abi_net_transport_webrtc", .module = webrtcAbiModule(b, target, optimize, host_mods, webrtc_resident_mod) },
        },
    });
    addHeaderGen(b, check_step, target, optimize, .{
        .check_step_name = "gen-ts-abi-check",
        .check_desc = "Verify the generated TypeScript ABI mirror files match src/c_abi (fails if stale)",
        .write_step_name = "gen-ts-abi",
        .write_desc = "Regenerate the TypeScript ABI mirror from src/c_abi (the ocapn, driver, iroh, and WebRTC transport archives)",
        .generator = "tools/gen/binding/ts_abi.zig",
        .import_name = "c_abi",
        .import_module = host_mods[layerIndex("c_abi")],
        .extra_imports = &.{
            .{ .name = "model", .module = host_mods[layerIndex("model")] },
            .{ .name = "c_abi_host", .module = host_abi_mod },
            .{ .name = "c_abi_driver", .module = driver_abi_mod },
            .{ .name = "c_abi_net_transport_iroh", .module = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod) },
            .{ .name = "c_abi_net_transport_webrtc", .module = webrtcAbiModule(b, target, optimize, host_mods, webrtc_resident_mod) },
            .{ .name = "c_abi_net_transport_relay", .module = relay_check_abi_mod },
            .{ .name = "c_abi_net_transport_tcp", .module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/tcp/mod.zig", &.{
                .{ .name = "foundation", .module = host_mods[layerIndex("foundation")] },
                .{ .name = "model", .module = host_mods[layerIndex("model")] },
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "driver", .module = host_mods[layerIndex("driver")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }) },
            .{ .name = "c_abi_net_transport_inproc", .module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/inproc/mod.zig", &.{
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }) },
            .{ .name = "c_abi_net_transport_onion", .module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/onion/mod.zig", &.{
                .{ .name = "model", .module = host_mods[layerIndex("model")] },
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }) },
        },
    });
    addHeaderGen(b, check_step, target, optimize, .{
        .check_step_name = "gen-binding-constants-check",
        .check_desc = "Verify binding ABI constants match src/c_abi (fails if stale)",
        .write_step_name = "gen-binding-constants",
        .write_desc = "Regenerate binding ABI constants from src/c_abi (the ocapn, driver, iroh, and WebRTC transport archives)",
        .generator = "tools/gen/binding/constants.zig",
        .import_name = "c_abi",
        .import_module = host_mods[layerIndex("c_abi")],
        .extra_imports = &.{
            .{ .name = "model", .module = host_mods[layerIndex("model")] },
            .{ .name = "c_abi_host", .module = host_abi_mod },
            .{ .name = "c_abi_driver", .module = driver_abi_mod },
            .{ .name = "c_abi_net_transport_iroh", .module = irohAbiModule(b, target, optimize, host_mods, iroh_resident_mod) },
            .{ .name = "c_abi_net_transport_webrtc", .module = webrtcAbiModule(b, target, optimize, host_mods, webrtc_resident_mod) },
            .{ .name = "c_abi_net_transport_relay", .module = relay_check_abi_mod },
            .{ .name = "c_abi_net_transport_tcp", .module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/tcp/mod.zig", &.{
                .{ .name = "foundation", .module = host_mods[layerIndex("foundation")] },
                .{ .name = "model", .module = host_mods[layerIndex("model")] },
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "driver", .module = host_mods[layerIndex("driver")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }) },
            .{ .name = "c_abi_net_transport_inproc", .module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/inproc/mod.zig", &.{
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }) },
            .{ .name = "c_abi_net_transport_onion", .module = transportAbiModule(b, target, optimize, "src/c_abi/net_transport/onion/mod.zig", &.{
                .{ .name = "model", .module = host_mods[layerIndex("model")] },
                .{ .name = "net", .module = host_mods[layerIndex("net")] },
                .{ .name = "c_abi_shared", .module = host_mods[layerIndex("c_abi_shared")] },
            }) },
        },
    });
}

/// The Cap'n Proto golden-fixture generator, beside the mirrors because it
/// is the same posture: a generated corpus, regenerated on purpose.
pub fn registerCapnpFixtures(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
) void {
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
}
