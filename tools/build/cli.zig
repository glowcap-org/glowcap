//! Product CLI, install alias, and hermetic CLI test roots.

const std = @import("std");
const common = @import("common.zig");
const execution = @import("execution.zig");

pub const Inputs = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    glowcap: *std.Build.Module,
    iroh: *std.Build.Module,
    native_relay: *std.Build.Module,
    check_relay: *std.Build.Module,
    version: std.SemanticVersion,
    iroh_sidecar_archive: std.Build.LazyPath,
    check: *std.Build.Step,
    test_filter: ?[]const u8,
};

pub fn add(b: *std.Build, in: Inputs) void {
    const options = b.addOptions();
    options.addOption(u32, "version_major", @intCast(in.version.major));
    options.addOption(u32, "version_minor", @intCast(in.version.minor));
    options.addOption(u32, "version_patch", @intCast(in.version.patch));
    options.addOption([]const u8, "captp_profile", "ocapn-captp");
    const vaxis = if (b.lazyDependency("vaxis", .{
        .target = in.target,
        .optimize = in.optimize,
    })) |dep| dep.module("vaxis") else return;

    const product = cliModule(b, in, vaxis, options, "cli/main.zig", true, in.native_relay);
    const exe = b.addExecutable(.{ .name = "glowcap", .root_module = product });
    b.installArtifact(exe);
    const run = execution.addArtifact(b, .service, exe);
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    run.addPassthruArgs();
    b.step("glowcap", "Run the glowcap CapTP CLI; pass `-- <command> …` (ocapn|repl|mcp|app rooms-peer|…)")
        .dependOn(&run.step);

    const product_check = cliModule(b, in, vaxis, options, "cli/main.zig", false, in.check_relay);
    in.check.dependOn(&b.addObject(.{
        .name = "glowcap-cli-check",
        .root_module = product_check,
    }).step);

    const shim = b.createModule(.{
        .root_source_file = b.path("cli/rooms_peer_shim.zig"),
        .target = in.target,
        .optimize = in.optimize,
    });
    b.installArtifact(b.addExecutable(.{ .name = "rooms-peer", .root_module = shim }));
    in.check.dependOn(&b.addObject(.{
        .name = "rooms-peer-shim-check",
        .root_module = shim,
    }).step);
    const rooms_peer = execution.addArtifact(b, .service, exe);
    rooms_peer.setCwd(b.path("."));
    rooms_peer.has_side_effects = true;
    rooms_peer.addArgs(&.{ "app", "rooms-peer" });
    rooms_peer.addPassthruArgs();
    b.step("rooms-peer", "Run rooms presence via `glowcap app rooms-peer`; pass `-- <verb> [flags]`")
        .dependOn(&rooms_peer.step);

    const iroh_stub = b.createModule(.{
        .root_source_file = b.path("tools/gen/stub/iroh_sidecar.zig"),
        .target = in.target,
        .optimize = in.optimize,
    });
    const api = testApiModule(b, in, vaxis, options, iroh_stub);
    const test_root = b.createModule(.{
        .root_source_file = b.path("test/cli/all.zig"),
        .target = in.target,
        .optimize = in.optimize,
    });
    test_root.addImport("cli", api);
    test_root.addImport("glowcap", in.glowcap);
    test_root.addImport("vaxis", vaxis);
    const registry_tests = b.addTest(.{
        .root_module = test_root,
        .name = "cli-registry-test",
        .filters = filters(b, in.test_filter),
    });
    const run_registry = execution.addZigTest(b, registry_tests, .unit_test);
    in.check.dependOn(&run_registry.step);

    // Dependency tests are not collected, so root the CLI sources separately.
    const source_tests = b.addTest(.{
        .root_module = testApiModule(b, in, vaxis, options, iroh_stub),
        .name = "cli-src-test",
        .filters = filters(b, in.test_filter),
    });
    const run_source = execution.addZigTest(b, source_tests, .unit_test);
    in.check.dependOn(&run_source.step);
    const cli_test = b.step("cli-test", "Run hermetic glowcap CLI registry + session/capture tests");
    cli_test.dependOn(&run_registry.step);
    cli_test.dependOn(&run_source.step);
    b.step("cli", "Alias for cli-test — hermetic glowcap CLI goldens")
        .dependOn(cli_test);
}

fn cliModule(
    b: *std.Build,
    in: Inputs,
    vaxis: *std.Build.Module,
    options: *std.Build.Step.Options,
    root: []const u8,
    link_iroh: bool,
    native_relay: *std.Build.Module,
) *std.Build.Module {
    const module = common.irohDriverModule(
        b,
        in.target,
        in.optimize,
        in.glowcap,
        in.iroh,
        root,
    );
    module.addImport("native_relay", native_relay);
    module.addImport("vaxis", vaxis);
    module.addOptions("build_options", options);
    if (link_iroh) common.linkIrohSidecar(b, module, in.target, in.iroh_sidecar_archive);
    return module;
}

fn testApiModule(
    b: *std.Build,
    in: Inputs,
    vaxis: *std.Build.Module,
    options: *std.Build.Step.Options,
    iroh_stub: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("cli/test_api.zig"),
        .target = in.target,
        .optimize = in.optimize,
    });
    module.addImport("glowcap", in.glowcap);
    module.addImport("native_relay", in.check_relay);
    module.addImport("vaxis", vaxis);
    module.addImport("iroh", in.iroh);
    module.addImport("iroh_sidecar_stub", iroh_stub);
    module.addOptions("build_options", options);
    return module;
}

fn filters(b: *std.Build, filter: ?[]const u8) []const []const u8 {
    return if (filter) |value| b.dupeStrings(&.{value}) else &.{};
}
