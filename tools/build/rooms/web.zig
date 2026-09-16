//! Installed HTTP front proofs, including acquisition and retirement. Browser
//! compilation is a build-tool dependency; no Deno service runs in these tests.
const std = @import("std");
const execution = @import("../execution.zig");

pub fn register(
    b: *std.Build,
    runtime_gate: *execution.RuntimeGate,
    peers: *std.Build.Step,
    browser_prepare: *std.Build.Step,
) void {
    const args: []const []const u8 = &.{
        "cargo", "test",           "--quiet",    "--locked",  "--manifest-path", "apps/rooms/rust/Cargo.toml",
        "-p",    "rooms-services", "--features", "processes", "--test",          "web_process",
    };
    const compile = execution.addSystemCommand(b, .build_tool, &.{"env"});
    compile.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    compile.addArgs(args);
    compile.addArg("--no-run");
    compile.setCwd(b.path("."));
    compile.step.dependOn(peers);

    const web_test_step = b.step("rooms-web-test", "Prove the installed web front's HTTP, relay admission and startup/shutdown custody (needs cargo + deno + python3)");
    const tor_step = b.step("rooms-web-tor-test", "Opt-in: prove the web front owns a private Tor and preserves its directory service key, with networking disabled (needs cargo + deno + python3 + tor)");
    runtime_gate.add(web_test_step);

    inline for (.{ false, true }) |tor| {
        const run = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{"env"});
        run.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "LD_LIBRARY_PATH=", .make_absolute = true });
        run.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
        run.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-web" } }, .{ .prefix = "GLOWCAP_ROOMS_WEB_TEST_BIN=", .make_absolute = true });
        run.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_TEST_BIN=", .make_absolute = true });
        run.addArgs(args);
        if (tor) run.addArgs(&.{ "--", "--ignored" });
        run.setCwd(b.path("."));
        run.step.dependOn(&compile.step);
        run.step.dependOn(browser_prepare);
        const step = if (tor) tor_step else web_test_step;
        step.dependOn(&run.step);
    }
}
