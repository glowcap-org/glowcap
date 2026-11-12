//! The browser binding's freestanding `wasm32` artifact (ADR-0034): the byte-fed
//! CapTP Host (`libglowcap_host`) and the shared `libglowcap_ocapn` vocabulary
//! compiled to one loadable wasm module. It roots on `src/c_abi/wasm/mod.zig`,
//! which forces both export families in and adds the JS<->wasm linear-memory
//! primitives. The module graph is the sans-io core (the `core = true` prefix)
//! plus the two ocapn C ABI vocabulary rows. The I/O layers (`net`, `driver`)
//! wasm lacks are excluded. ReleaseSmall keeps the download small. The
//! freestanding Host carries no thread-id reader, so it checks no affinity.
//!
//! This file also registers its install step, the static Wasm archives, and the
//! deno proofs of the module: `wasm-host`, `wasm-archives`, `wasm-host-test`,
//! `wasm-abi-layout-check`, `web-peer-test`, and `wasm-import-check`.

const std = @import("std");
const root = @import("../../build.zig");
const arch_check = @import("../check/arch_check.zig");
const archives = @import("archives.zig");
const commands = @import("commands.zig");
const modules = @import("modules.zig");

const transportAbiModule = modules.transportAbiModule;
const layer_table = root.layer_table;
const layerIndex = root.layerIndex;
const graphFromTable = root.graphFromTable;

/// The `layer_table` rows the wasm driver's base module graph transitively
/// needs, as a keep-mask over `layer_table`.
///
/// It is the import-closure of the `c_abi_wasm` root's forced families, its own
/// declared imports, `{c_abi_shared, c_abi, c_abi_host}`, followed over
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
    // Edges point only to earlier rows. One reverse traversal visits every
    // reached dependency before advancing to its own prerequisites.
    var cursor = layer_table.len;
    while (cursor != 0) {
        cursor -= 1;
        if (!reached[cursor]) continue;
        for (layer_table[cursor].imports) |name| reached[layerIndex(name)] = true;
    }
    var mask: [layer_table.len]bool = @splat(false);
    for (layer_table, 0..) |spec, i| mask[i] = reached[i] and spec.graph;
    return mask;
}

const WasmModules = struct {
    browser: *std.Build.Module,
    host: *std.Build.Module,
    ocapn: *std.Build.Module,
    loam: *std.Build.Module,
};

fn wasmModules(b: *std.Build, o: std.builtin.OptimizeMode) WasmModules {
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
    const host_imports = [_]modules.AbiImport{
        .{ .name = "net_thread_id", .module = pick(sub, mods, "net_thread_id") },
        .{ .name = "foundation", .module = pick(sub, mods, "foundation") },
        .{ .name = "model", .module = pick(sub, mods, "model") },
        .{ .name = "engine", .module = pick(sub, mods, "engine") },
        .{ .name = "actors", .module = pick(sub, mods, "actors") },
        .{ .name = "driver_core", .module = pick(sub, mods, "driver_core") },
        .{ .name = "c_abi_shared", .module = pick(sub, mods, "c_abi_shared") },
    };
    const host_mod = transportAbiModule(b, t, o, "src/c_abi/host/mod.zig", &host_imports);
    const host_archive = transportAbiModule(b, t, o, "src/c_abi/host/archive.zig", &host_imports);
    const loam_imports = [_]modules.AbiImport{
        .{ .name = "loam_core", .module = pick(sub, mods, "loam_core") },
        .{ .name = "loam_access", .module = pick(sub, mods, "loam_access") },
        .{ .name = "loam_hosting", .module = pick(sub, mods, "loam_hosting") },
        .{ .name = "driver_core", .module = pick(sub, mods, "driver_core") },
        .{ .name = "c_abi_shared", .module = pick(sub, mods, "c_abi_shared") },
        .{ .name = "c_abi_host", .module = host_mod },
    };
    const loam_mod = transportAbiModule(b, t, o, "src/c_abi/loam/mod.zig", &loam_imports);
    const loam_archive = transportAbiModule(b, t, o, "src/c_abi/loam/archive.zig", &loam_imports);
    const wasm_root = transportAbiModule(b, t, o, "src/c_abi/wasm/mod.zig", &.{
        .{ .name = "c_abi_shared", .module = pick(sub, mods, "c_abi_shared") },
        .{ .name = "c_abi", .module = pick(sub, mods, "c_abi") },
        .{ .name = "c_abi_host", .module = host_mod },
        .{ .name = "c_abi_loam", .module = loam_mod },
    });
    return .{ .browser = wasm_root, .host = host_archive, .ocapn = pick(sub, mods, "c_abi"), .loam = loam_archive };
}

fn wasmDriverExe(b: *std.Build, o: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{ .name = "glowcap_host", .root_module = wasmModules(b, o).browser });
    // A loadable module, not a command: no `_start`, exports discovered from the
    // `export fn`s (`entry = .disabled`, `rdynamic`). The linker exports linear
    // memory so JS can read/write `ptr + len` across the boundary.
    exe.entry = .disabled;
    exe.rdynamic = true;
    return exe;
}

pub const Registered = struct {
    /// The module's install step. Every serve path and browser proof reads the
    /// on-disk artifact it writes.
    install: *std.Build.Step,
    archives: *std.Build.Step,
};

/// Register the Wasm Host module, its static archives, and their proofs, and
/// fold the module into `cross_check_step` and the default install.
pub fn register(b: *std.Build, cross_check_step: *std.Build.Step) Registered {
    // The browser binding's freestanding wasm32 Host module (ADR-0034): the
    // byte-fed driver tier plus the shared ocapn vocabulary, one loadable
    // `glowcap_host.wasm` under zig-out/wasm/ that a browser instantiates and
    // drives with bytes. Building it also folds the whole browser-binding graph
    // (`c_abi_host`, `c_abi_wasm`) into `cross-check`, so a wasm regression
    // fails the gate.
    const wasm_driver = wasmDriverExe(b, .ReleaseSmall);
    const wasm_driver_install = b.addInstallArtifact(wasm_driver, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });
    // The wasm module is a shipped artifact like the archives, so fold its
    // install into the default `zig build` install. Every serve path reads the
    // on-disk `zig-out/wasm/glowcap_host.wasm`. Each rooms serve path depends on
    // this exact install step, and the compose deploy runs plain `zig build`.
    // Without this edge a renamed C-ABI symbol leaves the served module stale,
    // and the browser can only report the missing export at dlopen time.
    b.getInstallStep().dependOn(&wasm_driver_install.step);
    const wasm_driver_step = b.step("wasm-host", "Build the browser binding's freestanding wasm32 Host module (ADR-0034) into zig-out/wasm/");
    wasm_driver_step.dependOn(&wasm_driver_install.step);
    cross_check_step.dependOn(&wasm_driver.step);

    // Static consumers share a linear memory with the Host and call the C ABI
    // directly. They do not need the JavaScript trampolines in the browser root.
    const wasm_static = wasmModules(b, .ReleaseSmall);
    const wasm_archives_step = b.step("wasm-archives", "Build freestanding Host, OCapN, and Loam static archives for Wasm application linking");
    inline for (.{
        .{ "glowcap_host", wasm_static.host },
        .{ "glowcap_ocapn", wasm_static.ocapn },
        .{ "glowcap_loam", wasm_static.loam },
    }) |entry| {
        const archive = b.addLibrary(.{ .name = entry[0], .linkage = .static, .root_module = entry[1] });
        wasm_archives_step.dependOn(archives.installIfChanged(b, archive, .{ .relative = .{ .base = .install_prefix, .sub_path = "wasm/lib" } }));
    }

    // Behavioral proof that the wasm32 Host runs real CapTP from JavaScript: two
    // Hosts with distinct identities complete a keyed handshake over an in-memory
    // byte pipe, then the dialer refuses a wrong-peer sturdyref before output.
    // A sibling step (needs deno on PATH), not folded into the Zig-hermetic `check`.
    const wasm_driver_test = commands.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{ "deno", "run", "--allow-read", "bindings/ts/web/test/wasm_handshake.ts" });
    wasm_driver_test.has_side_effects = true;
    wasm_driver_test.step.dependOn(&wasm_driver_install.step);
    const wasm_driver_test_step = b.step("wasm-host-test", "Prove the wasm32 Host handshakes and checks sturdyref peer authority from JS (needs deno, ADR-0034 and ADR-0007)");
    wasm_driver_test_step.dependOn(&wasm_driver_test.step);

    // The wasm32 layout descriptor (`glowcap_wasm_abi_layout`) decodes cleanly:
    // instantiate the module, read the blob, prove it is well formed, and
    // cross-check each struct's field count against the `abi.ts` host mirror. A
    // sibling step (needs deno), not folded into the Zig-hermetic `check`.
    const wasm_abi_layout_check = commands.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{ "deno", "run", "--allow-read", "tools/wasm/abi_layout_check.ts" });
    wasm_abi_layout_check.has_side_effects = true;
    wasm_abi_layout_check.step.dependOn(&wasm_driver_install.step);
    const wasm_abi_layout_check_step = b.step("wasm-abi-layout-check", "Prove the wasm32 Host's layout descriptor (glowcap_wasm_abi_layout) decodes cleanly and agrees with the abi.ts field counts (needs deno, ADR-0034)");
    wasm_abi_layout_check_step.dependOn(&wasm_abi_layout_check.step);

    // Product proof for the @glowcap/web Wasm peer: keyed WebSocket call and
    // callback against a Zig host, then a Zig CLI cold-dial into that
    // browser-shaped Host over sealed noise-relay rendezvous. Needs the wasm
    const web_peer_test = commands.addRootedSystemCommand(b, .{ .browser_proof = 120 }, &.{
        "deno",                                  "run", "--config", "deno.json", "--allow-all",
        "bindings/ts/web/test/web_peer_test.ts",
    });
    web_peer_test.has_side_effects = true;
    web_peer_test.step.dependOn(&wasm_driver_install.step);
    web_peer_test.step.dependOn(b.getInstallStep());
    const web_peer_test_step = b.step("web-peer-test", "Prove @glowcap/web holds keyed WebSocket and sealed Noise-relay sessions with Zig peers (needs deno + Playwright, ADR-0034 and ADR-0041)");
    web_peer_test_step.dependOn(&web_peer_test.step);

    // The wasm32 Host imports exactly the behavior-dispatch and hosted-
    // retirement seams (ADR-0034). Parse the module statically and assert that
    // fixed set, so an accidental extra import or rename fails the build. A
    // sibling step (needs deno), not folded into the Zig-hermetic `check`.
    const wasm_import_check = commands.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{ "deno", "run", "--allow-read", "tools/wasm/import_check.ts" });
    wasm_import_check.has_side_effects = true;
    wasm_import_check.step.dependOn(&wasm_driver_install.step);
    const wasm_import_check_step = b.step("wasm-import-check", "Prove the wasm32 Host imports exactly its behavior and hosted-retirement callbacks (needs deno, ADR-0034)");
    wasm_import_check_step.dependOn(&wasm_import_check.step);

    return .{ .install = &wasm_driver_install.step, .archives = wasm_archives_step };
}
