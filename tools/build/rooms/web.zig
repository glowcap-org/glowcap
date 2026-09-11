//! Installed HTTP front proofs, including acquisition and retirement. Browser
//! compilation is a build-tool dependency; no Deno service runs in these tests.
const std = @import("std");
const execution = @import("../execution.zig");

pub fn register(b: *std.Build, check_step: *std.Build.Step, peers: *std.Build.Step, wasm: *std.Build.Step) void {
    const args: []const []const u8 = &.{
        "cargo",       "test",         "--locked",   "--manifest-path", "apps/rooms/rust/Cargo.toml",
        "-p",          "rooms-native", "--features", "service",         "--test",
        "web_process",
    };
    const compile = execution.addSystemCommand(b, .build_tool, &.{"env"});
    compile.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    compile.addArgs(args);
    compile.addArg("--no-run");
    compile.setCwd(b.path("."));
    compile.step.dependOn(peers);

    const native_step = b.step("rooms-web-native-test", "Prove installed native web HTTP, relay admission and startup/shutdown custody (needs cargo + deno + python3)");
    const tor_step = b.step("rooms-web-tor-test", "Opt-in: prove native web owns a private Tor and preserves its directory service key, with networking disabled (needs cargo + deno + python3 + tor)");
    check_step.dependOn(native_step);

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
        run.step.dependOn(wasm);
        const step = if (tor) tor_step else native_step;
        step.dependOn(&run.step);
    }
}
