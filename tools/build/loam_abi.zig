//! Optional Loam archives share the existing Host and storage Store modules.
const std = @import("std");
const common = @import("common.zig");
const root = @import("../../build.zig");
const execution = @import("execution.zig");
const Gates = @import("gates.zig").Registered;
pub const Registered = struct { portable: *std.Build.Module, storage: *std.Build.Module, native_installs: [2]*std.Build.Step };
pub fn register(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, version: std.SemanticVersion, modules: []*std.Build.Module, host: *std.Build.Module, lmdb: *std.Build.Module, gates: Gates) Registered {
    const imports = [_]common.AbiImport{
        .{ .name = "loam_core", .module = modules[root.layerIndex("loam_core")] },
        .{ .name = "loam_access", .module = modules[root.layerIndex("loam_access")] },
        .{ .name = "loam_hosting", .module = modules[root.layerIndex("loam_hosting")] },
        .{ .name = "driver_core", .module = modules[root.layerIndex("driver_core")] },
        .{ .name = "c_abi_shared", .module = modules[root.layerIndex("c_abi_shared")] },
        .{ .name = "c_abi_host", .module = host },
    };
    const portable = common.transportAbiModule(b, target, optimize, "src/c_abi/loam/mod.zig", &imports);
    const archive = common.transportAbiModule(b, target, optimize, "src/c_abi/loam/archive.zig", &imports);
    const portable_archive = common.installArchive(b, "glowcap_loam", archive, version);
    const storage_imports = [_]common.AbiImport{
        .{ .name = "loam_core", .module = modules[root.layerIndex("loam_core")] },
        .{ .name = "loam_lmdb", .module = lmdb },
        .{ .name = "c_abi_shared", .module = modules[root.layerIndex("c_abi_shared")] },
        .{ .name = "c_abi_loam", .module = portable },
    };
    const storage = common.transportAbiModule(b, target, optimize, "src/c_abi/loam_lmdb/mod.zig", &storage_imports);
    const storage_archive = common.transportAbiModule(b, target, optimize, "src/c_abi/loam_lmdb/archive.zig", &storage_imports);
    const lmdb_archive = common.installArchive(b, "glowcap_loam_lmdb", storage_archive, version);
    const test_mod = b.createModule(.{ .root_source_file = b.path("test/c_abi/loam_test.zig"), .target = target, .optimize = optimize });
    test_mod.addImport("c_abi_loam", portable);
    test_mod.addImport("c_abi", modules[root.layerIndex("c_abi")]);
    test_mod.addImport("loam_core", modules[root.layerIndex("loam_core")]);
    test_mod.addImport("loam_access", modules[root.layerIndex("loam_access")]);
    test_mod.addImport("loam_hosting", modules[root.layerIndex("loam_hosting")]);
    test_mod.addImport("driver_core", modules[root.layerIndex("driver_core")]);
    const counting = b.createModule(.{ .root_source_file = b.path("test/support/c_abi_counting_alloc.zig"), .target = target, .optimize = optimize });
    counting.addImport("c_abi", modules[root.layerIndex("c_abi")]);
    test_mod.addImport("support_c_abi_counting_alloc", counting);
    test_mod.addImport("support_alloc_metrics", b.createModule(.{ .root_source_file = b.path("test/support/alloc_metrics.zig"), .target = target, .optimize = optimize }));
    test_mod.addImport("c_abi_loam_lmdb", storage);
    test_mod.addImport("c_abi_host", host);
    test_mod.addImport("c_abi_shared", modules[root.layerIndex("c_abi_shared")]);
    const suite = b.addTest(.{ .root_module = test_mod });
    const run = execution.addZigTest(b, suite, .unit_test);
    const step = b.step("loam-abi-test", "Check Loam C ownership and atomic resource creation through atomic storage");
    step.dependOn(&run.step);
    const effect_tests = b.createModule(.{ .root_source_file = b.path("test/c_abi/loam_execution_test.zig"), .target = target, .optimize = optimize });
    effect_tests.addImport("c_abi_loam", portable);
    effect_tests.addImport("loam_core", modules[root.layerIndex("loam_core")]);
    effect_tests.addImport("c_abi_shared", modules[root.layerIndex("c_abi_shared")]);
    const effects = execution.addZigTest(b, b.addTest(.{ .root_module = effect_tests }), .unit_test);
    step.dependOn(&effects.step);
    gates.check_step.dependOn(step);
    const compile = common.addRootedSystemCommand(b, .build_tool, &.{ "cargo", "test", "--no-run", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "loam" });
    const standalone = common.addRootedSystemCommand(b, .build_tool, &.{ "cargo", "test", "--no-run", "--manifest-path", "bindings/rust/Cargo.toml", "--no-default-features", "--features", "loam" });
    const lint = common.addRootedSystemCommand(b, .build_tool, &.{ "cargo", "clippy", "--manifest-path", "bindings/rust/Cargo.toml", "--all-targets", "--features", "loam", "--", "-D", "warnings" });
    const rust = common.addRootedSystemCommand(b, .{ .deterministic = 15 }, &.{ "cargo", "test", "--manifest-path", "bindings/rust/Cargo.toml", "--features", "loam", "loam::" });
    compile.step.dependOn(b.getInstallStep());
    lint.step.dependOn(b.getInstallStep());
    standalone.step.dependOn(b.getInstallStep());
    rust.step.dependOn(&compile.step);
    rust.step.dependOn(&lint.step);
    rust.step.dependOn(&standalone.step);
    for ([_]*std.Build.Step.Run{ compile, standalone, lint, rust }) |command| {
        command.setEnvironmentVariable("GLOWCAP_LIB_DIR", common.rootPath(b, "zig-out/lib"));
    }
    const rust_step = b.step("loam-rust-test", "Prove Loam create/share/edit/restart/reopen and ownership through Rust (needs cargo)");
    rust_step.dependOn(&rust.step);
    gates.runtime_gate.add(rust_step);
    @import("loam_browser.zig").register(b, gates);
    return .{ .portable = portable, .storage = storage, .native_installs = .{ &portable_archive.static_install.step, &lmdb_archive.static_install.step } };
}
