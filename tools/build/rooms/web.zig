//! Installed HTTP front proofs, including acquisition and retirement. Browser
//! compilation is a build-tool dependency. No Deno service runs in these tests.
const std = @import("std");
const commands = @import("../commands.zig");
const execution = @import("../execution.zig");
const Binary = @import("peers.zig").Binary;

pub fn register(
    b: *std.Build,
    runtime_gate: *execution.RuntimeGate,
    peers: *std.Build.Step,
    browser_prepare: *std.Build.Step,
) void {
    const args: []const []const u8 = &.{
        "cargo", "test",          "--quiet", "--locked",    "--manifest-path", "apps/rooms/rust/Cargo.toml",
        "-p",    "rooms-product", "--test",  "web_process", "--bin",           "rooms-web",
    };
    const compile = commands.addRootedSystemCommand(b, .build_tool, &.{"env"});
    commands.addLibDirArg(compile, .host);
    compile.addArgs(args);
    compile.addArg("--no-run");
    compile.step.dependOn(peers);

    const web_test_step = b.step("rooms-web-test", "Prove the installed web front's HTTP, relay admission and startup/shutdown custody (needs cargo + deno + python3)");
    const tor_step = b.step("rooms-web-tor-test", "Prove the web front owns a private Tor and preserves its directory service key, with networking disabled (needs cargo + deno + python3 + tor)");
    runtime_gate.add(web_test_step);

    inline for (.{ false, true }) |tor| {
        const run = commands.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{"env"});
        commands.addLoaderPathArg(run);
        commands.addLibDirArg(run, .host);
        Binary.web.addTestEnv(run);
        Binary.server.addTestEnv(run);
        run.addArgs(args);
        if (tor) run.addArgs(&.{ "--", "--ignored" });
        run.step.dependOn(&compile.step);
        run.step.dependOn(browser_prepare);
        const step = if (tor) tor_step else web_test_step;
        step.dependOn(&run.step);
    }
}
