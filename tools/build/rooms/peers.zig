//! The Rooms peers, `rooms-archive`, `rooms-session`, and
//! `rooms-server`: their build, install, run steps, and the identity,
//! transport, restart, and shutdown proofs that ride `runtime-check`.
const std = @import("std");
const execution = @import("../execution.zig");

pub const Peers = struct {
    installed: *std.Build.Step,
    browser_installed: *std.Build.Step,
    web_build: *std.Build.Step,
};

pub fn register(b: *std.Build, runtime_gate: *execution.RuntimeGate, iroh_abi: *std.Build.Step, zig_archives: []const *std.Build.Step) Peers {
    const proof_compile = compileWithProfile(b, iroh_abi, zig_archives, &.{ "rooms-web", "rooms-server" }, "browser-proof", "apps/rooms/rust/target/browser-server-proof");
    const proof_web = b.addInstallFileWithDir(b.path("apps/rooms/rust/target/browser-server-proof/browser-proof/rooms-web"), .prefix, "libexec/rooms-web-proof");
    proof_web.step.dependOn(&proof_compile.step);
    const proof_server = b.addInstallFileWithDir(b.path("apps/rooms/rust/target/browser-server-proof/browser-proof/rooms-server"), .prefix, "libexec/rooms-server-proof");
    proof_server.step.dependOn(&proof_compile.step);
    proof_server.step.dependOn(&proof_web.step);
    const browser_compile = compilePeers(b, iroh_abi, zig_archives, &.{ "rooms-web", "rooms-server" });
    const compile = compilePeers(b, iroh_abi, zig_archives, &.{ "rooms-archive", "rooms-session", "rooms-irc-bridge", "rooms-irc-server", "rooms-chat" });
    // These groups share Cargo's output directory. Complete product builds
    // serialize them; browser builds never enter the unrelated second group.
    compile.step.dependOn(&browser_compile.step);
    const chat_install = b.addInstallFileWithDir(b.path("apps/rooms/rust/target/release/rooms-chat"), .prefix, "libexec/rooms-chat");
    chat_install.step.dependOn(&compile.step);
    b.step("rooms-chat-build", "Build and install the interactive Rooms client (needs cargo)").dependOn(&chat_install.step);
    const chat_run = execution.addSystemCommand(b, .service, &.{"env"});
    chat_run.addFileArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-chat" } });
    chat_run.setCwd(b.path("."));
    chat_run.addPassthruArgs();
    chat_run.step.dependOn(&chat_install.step);
    b.step("rooms-chat", "Chat interactively; pass -- <locator> <room> <nick> (needs cargo)").dependOn(&chat_run.step);
    const install = b.addInstallFileWithDir(b.path("apps/rooms/rust/target/release/rooms-archive"), .prefix, "libexec/rooms-archive");
    install.step.dependOn(&compile.step);
    install.step.dependOn(&chat_install.step);
    const session_install = b.addInstallFileWithDir(b.path("apps/rooms/rust/target/release/rooms-session"), .prefix, "libexec/rooms-session");
    session_install.step.dependOn(&compile.step);
    const server_install = b.addInstallFileWithDir(b.path("apps/rooms/rust/target/release/rooms-server"), .prefix, "libexec/rooms-server");
    server_install.step.dependOn(&browser_compile.step);
    install.step.dependOn(&session_install.step);
    install.step.dependOn(&server_install.step);
    const bridge_install = b.addInstallFileWithDir(b.path("apps/rooms/rust/target/release/rooms-irc-bridge"), .prefix, "libexec/rooms-irc-bridge");
    bridge_install.step.dependOn(&compile.step);
    install.step.dependOn(&bridge_install.step);
    const web_install = b.addInstallFileWithDir(b.path("apps/rooms/rust/target/release/rooms-web"), .prefix, "libexec/rooms-web");
    web_install.step.dependOn(&browser_compile.step);
    install.step.dependOn(&web_install.step);
    const web_build = b.step("rooms-web-build", "Build and install the Rooms HTTP front and browser application (needs cargo + wasm-bindgen)");
    web_build.dependOn(&web_install.step);
    server_install.step.dependOn(&web_install.step);
    web_build.dependOn(&server_install.step);
    const irc_server_install = b.addInstallFileWithDir(b.path("apps/rooms/rust/target/release/rooms-irc-server"), .prefix, "libexec/rooms-irc-server");
    irc_server_install.step.dependOn(&compile.step);
    install.step.dependOn(&irc_server_install.step);
    b.step("rooms-irc-server-build", "Build and install the Rooms IRC server (needs cargo)").dependOn(&irc_server_install.step);
    const irc_server_run = execution.addSystemCommand(b, .service, &.{"env"});
    irc_server_run.addFileArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-irc-server" } });
    irc_server_run.setCwd(b.path("."));
    irc_server_run.addPassthruArgs();
    irc_server_run.step.dependOn(&irc_server_install.step);
    b.step("rooms-irc-server", "Serve a Rooms directory to ordinary IRC clients as an IRC server").dependOn(&irc_server_run.step);
    b.step("rooms-irc-bridge-build", "Build and install the standalone IRC bridge (needs cargo)").dependOn(&bridge_install.step);
    const bridge_run = execution.addSystemCommand(b, .service, &.{"env"});
    bridge_run.addFileArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-irc-bridge" } });
    bridge_run.setCwd(b.path("."));
    bridge_run.addPassthruArgs();
    bridge_run.step.dependOn(&bridge_install.step);
    b.step("rooms-irc-bridge", "Serve one IRC channel as a Rooms directory with the bridge (read-only by default)").dependOn(&bridge_run.step);
    const build = b.step("rooms-archive-build", "Build and install the archive peer (needs cargo)");
    build.dependOn(&install.step);
    const session_build = b.step("rooms-session-build", "Build and install the durable Rooms session runtime (needs cargo)");
    session_build.dependOn(&session_install.step);
    const server_build = b.step("rooms-server-build", "Build and install the Rooms server (needs cargo)");
    server_build.dependOn(&server_install.step);
    const run = execution.addSystemCommand(b, .service, &.{"env"});
    run.addFileArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-archive" } });
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    run.step.dependOn(&install.step);
    b.step("rooms-archive", "Run the durable archive peer; pass -- --state=<directory> (iroh by default)").dependOn(&run.step);
    const server_run = execution.addSystemCommand(b, .service, &.{"env"});
    server_run.addFileArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-server" } });
    server_run.setCwd(b.path("."));
    server_run.addPassthruArgs();
    server_run.step.dependOn(&server_install.step);
    b.step("rooms-server", "Run the Rooms server: the directory members register with and the rooms they enter; pass `-- [--state=<directory>] [--history] [--admin-listeners] [--diagnostics] [--operator] [--peering] [--trace]` (iroh by default, needs cargo)").dependOn(&server_run.step);

    const compile_tests = execution.addSystemCommand(b, .build_tool, &.{"env"});
    compile_tests.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    compile_tests.addArgs(&.{
        "cargo",          "test",          "--quiet",      "--locked",        "--no-run",      "--manifest-path", "apps/rooms/rust/Cargo.toml",
        "-p",             "rooms-product", "--test",       "archive_process", "--test",        "session_process", "--test",
        "server_process", "--test",        "chat_process", "--bin",           "rooms-session",
    });
    compile_tests.addDirectoryArg2(b.path("apps/rooms/rust/target"), .{ .prefix = "--target-dir=", .make_absolute = true });
    compile_tests.setCwd(b.path("."));
    compile_tests.step.dependOn(iroh_abi);
    for (zig_archives) |archive| compile_tests.step.dependOn(archive);
    const service_unit_args: []const []const u8 = &.{ "cargo", "test", "--locked", "--manifest-path", "apps/rooms/rust/Cargo.toml", "-p", "rooms-services", "--features", "processes", "--lib" };
    const compile_units = execution.addSystemCommand(b, .build_tool, &.{"env"});
    compile_units.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    compile_units.addArgs(service_unit_args);
    compile_units.addArgs(&.{ "--quiet", "--no-run" });
    compile_units.addDirectoryArg2(b.path("apps/rooms/rust/target"), .{ .prefix = "--target-dir=", .make_absolute = true });
    compile_units.setCwd(b.path("."));
    compile_units.step.dependOn(&compile_tests.step);
    // Unit semantics and installed-process behavior are two separately bounded
    // subjects, so a long library run cannot spend the deadline a process
    // proof needs.
    // The host execution adapters and the directory signaling adapter live in
    // rooms-platform. Their client contracts run in this focused step, because
    // a services filter would silently select no tests.
    // Compile without a deadline first, as for the other units, so the timed
    // run measures the tests rather than a rebuild after a binding change.
    const platform_unit_args: []const []const u8 = &.{ "cargo", "test", "--locked", "--manifest-path", "apps/rooms/rust/Cargo.toml", "-p", "rooms-platform", "--lib" };
    const compile_platform = execution.addSystemCommand(b, .build_tool, &.{"env"});
    compile_platform.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    compile_platform.addArgs(platform_unit_args);
    compile_platform.addArgs(&.{ "--quiet", "--no-run" });
    compile_platform.addDirectoryArg2(b.path("apps/rooms/rust/target"), .{ .prefix = "--target-dir=", .make_absolute = true });
    compile_platform.setCwd(b.path("."));
    compile_platform.step.dependOn(&compile_units.step);
    const platform_unit = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{"env"});
    platform_unit.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "LD_LIBRARY_PATH=", .make_absolute = true });
    platform_unit.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    platform_unit.addArgs(platform_unit_args);
    platform_unit.addDirectoryArg2(b.path("apps/rooms/rust/target"), .{ .prefix = "--target-dir=", .make_absolute = true });
    platform_unit.addArgs(&.{ "--", "execution::", "signaling::" });
    platform_unit.setCwd(b.path("."));
    platform_unit.step.dependOn(&compile_platform.step);

    const unit_filters = [_][]const []const u8{
        &.{"archive::"},
        &.{"server::"},
        &.{"session::"},
        &.{ "--", "--skip", "archive::", "--skip", "server::", "--skip", "session::" },
    };
    var previous_unit: *std.Build.Step = &platform_unit.step;
    for (unit_filters) |filter| {
        const unit = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{"env"});
        unit.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "LD_LIBRARY_PATH=", .make_absolute = true });
        unit.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
        unit.addArgs(service_unit_args);
        unit.addDirectoryArg2(b.path("apps/rooms/rust/target"), .{ .prefix = "--target-dir=", .make_absolute = true });
        unit.addArgs(filter);
        unit.setCwd(b.path("."));
        unit.step.dependOn(previous_unit);
        previous_unit = &unit.step;
    }

    const process_run = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{"env"});
    process_run.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "LD_LIBRARY_PATH=", .make_absolute = true });
    process_run.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    process_run.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-archive" } }, .{ .prefix = "GLOWCAP_ROOMS_ARCHIVE_TEST_BIN=", .make_absolute = true });
    process_run.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-session" } }, .{ .prefix = "GLOWCAP_ROOMS_SESSION_TEST_BIN=", .make_absolute = true });
    process_run.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_TEST_BIN=", .make_absolute = true });
    process_run.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-chat" } }, .{ .prefix = "GLOWCAP_ROOMS_CHAT_TEST_BIN=", .make_absolute = true });
    process_run.addArgs(&.{
        "cargo",           "test",          "--locked",       "--manifest-path", "apps/rooms/rust/Cargo.toml",
        "-p",              "rooms-product", "--test",         "archive_process", "--test",
        "session_process", "--test",        "server_process", "--test",          "chat_process",
        "--bin",           "rooms-session",
    });
    process_run.addDirectoryArg2(b.path("apps/rooms/rust/target"), .{ .prefix = "--target-dir=", .make_absolute = true });
    process_run.setCwd(b.path("."));
    process_run.step.dependOn(previous_unit);
    const test_step = b.step("rooms-peers-test", "Prove the archive peer, session peer, and Rooms server's identity, transport, restart and shutdown (needs cargo)");
    process_run.step.dependOn(&install.step);
    process_run.step.dependOn(&session_install.step);
    process_run.step.dependOn(&server_install.step);
    test_step.dependOn(&process_run.step);
    runtime_gate.add(test_step);
    // The same finite journey runs against release archives on Intel macOS.
    // Every command, readiness wait and shutdown owns its deadline.
    const agent_run = execution.addSystemCommand(b, .child_bounded, &.{ "python3", "tools/check/rooms_peer.py" });
    agent_run.setCwd(b.path("."));
    agent_run.step.dependOn(&session_install.step);
    agent_run.step.dependOn(&server_install.step);
    const agent_test = b.step("rooms-agent-test", "Exercise the Rooms agent skill across rooms, DMs, restart and acknowledgement (needs cargo + python3)");
    agent_test.dependOn(&agent_run.step);
    runtime_gate.add(agent_test);
    return .{ .installed = &install.step, .browser_installed = &proof_server.step, .web_build = web_build };
}

fn compilePeers(b: *std.Build, iroh_abi: *std.Build.Step, zig_archives: []const *std.Build.Step, binaries: []const []const u8) *std.Build.Step.Run {
    return compileWithProfile(b, iroh_abi, zig_archives, binaries, "release", "apps/rooms/rust/target");
}

fn compileWithProfile(b: *std.Build, iroh_abi: *std.Build.Step, zig_archives: []const *std.Build.Step, binaries: []const []const u8, profile: []const u8, target_dir: []const u8) *std.Build.Step.Run {
    const compile = execution.addSystemCommand(b, .build_tool, &.{"env"});
    compile.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    compile.addArgs(&.{ "cargo", "build", "--quiet", "--locked", "--profile", profile, "--manifest-path", "apps/rooms/rust/Cargo.toml", "-p", "rooms-product" });
    for (binaries) |binary| compile.addArgs(&.{ "--bin", binary });
    compile.addDirectoryArg2(b.path(target_dir), .{ .prefix = "--target-dir=", .make_absolute = true });
    compile.setCwd(b.path("."));
    for (zig_archives) |archive| compile.step.dependOn(archive);
    compile.step.dependOn(iroh_abi);
    return compile;
}
