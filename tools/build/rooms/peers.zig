//! The Rooms peers, `rooms-archive`, `rooms-session`, and
//! `rooms-server`: their build, install, run steps, and the identity,
//! transport, restart, and shutdown proofs that ride `runtime-check`.
const std = @import("std");
const execution = @import("../execution.zig");

pub const Peers = struct {
    installed: *std.Build.Step,
    web_build: *std.Build.Step,
};

pub fn register(b: *std.Build, runtime_gate: *execution.RuntimeGate, iroh_abi: *std.Build.Step) Peers {
    const compile = execution.addSystemCommand(b, .build_tool, &.{"env"});
    compile.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    compile.addArgs(&.{
        "cargo",         "build",          "--quiet",      "--locked",   "--release",        "--manifest-path", "apps/rooms/rust/Cargo.toml",
        "-p",            "rooms-services", "--features",   "processes",  "--bin",            "rooms-archive",   "--bin",
        "rooms-session", "--bin",          "rooms-server", "--bin",      "rooms-irc-bridge", "--bin",           "rooms-irc-front",
        "--bin",         "rooms-web",      "--bin",        "rooms-chat",
    });
    compile.addDirectoryArg2(b.path("apps/rooms/rust/target"), .{ .prefix = "--target-dir=", .make_absolute = true });
    compile.setCwd(b.path("."));
    compile.step.dependOn(b.getInstallStep());
    compile.step.dependOn(iroh_abi);
    const chat_install = b.addInstallBinFile(b.path("apps/rooms/rust/target/release/rooms-chat"), "rooms-chat");
    chat_install.step.dependOn(&compile.step);
    b.step("rooms-chat-build", "Build and install the interactive Rooms client").dependOn(&chat_install.step);
    const chat_run = execution.addSystemCommand(b, .service, &.{"env"});
    chat_run.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-chat" } });
    chat_run.setCwd(b.path("."));
    chat_run.addPassthruArgs();
    chat_run.step.dependOn(&chat_install.step);
    b.step("rooms-chat", "Chat interactively; pass -- <locator> <room> <nick>").dependOn(&chat_run.step);
    const install = b.addInstallBinFile(b.path("apps/rooms/rust/target/release/rooms-archive"), "rooms-archive");
    install.step.dependOn(&compile.step);
    install.step.dependOn(&chat_install.step);
    const session_install = b.addInstallBinFile(b.path("apps/rooms/rust/target/release/rooms-session"), "rooms-session");
    session_install.step.dependOn(&compile.step);
    const server_install = b.addInstallBinFile(b.path("apps/rooms/rust/target/release/rooms-server"), "rooms-server");
    server_install.step.dependOn(&compile.step);
    install.step.dependOn(&session_install.step);
    install.step.dependOn(&server_install.step);
    const bridge_install = b.addInstallBinFile(b.path("apps/rooms/rust/target/release/rooms-irc-bridge"), "rooms-irc-bridge");
    bridge_install.step.dependOn(&compile.step);
    install.step.dependOn(&bridge_install.step);
    const web_install = b.addInstallBinFile(b.path("apps/rooms/rust/target/release/rooms-web"), "rooms-web");
    web_install.step.dependOn(&compile.step);
    install.step.dependOn(&web_install.step);
    const web_build = b.step("rooms-web-build", "Build and install the Rooms HTTP front and browser application (needs cargo + wasm-bindgen)");
    web_build.dependOn(&web_install.step);
    const front_install = b.addInstallBinFile(b.path("apps/rooms/rust/target/release/rooms-irc-front"), "rooms-irc-front");
    front_install.step.dependOn(&compile.step);
    install.step.dependOn(&front_install.step);
    b.step("rooms-irc-front-build", "Build and install the IRC client front (needs cargo)").dependOn(&front_install.step);
    const front_run = execution.addSystemCommand(b, .service, &.{"env"});
    front_run.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-irc-front" } });
    front_run.setCwd(b.path("."));
    front_run.addPassthruArgs();
    front_run.step.dependOn(&front_install.step);
    b.step("rooms-irc-front", "Serve a Rooms directory to ordinary IRC clients through the front").dependOn(&front_run.step);
    b.step("rooms-irc-bridge-build", "Build and install the standalone IRC bridge (needs cargo)").dependOn(&bridge_install.step);
    const bridge_run = execution.addSystemCommand(b, .service, &.{"env"});
    bridge_run.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-irc-bridge" } });
    bridge_run.setCwd(b.path("."));
    bridge_run.addPassthruArgs();
    bridge_run.step.dependOn(&bridge_install.step);
    b.step("rooms-irc-bridge", "Serve one IRC channel as a Rooms directory with the bridge (read-only by default)").dependOn(&bridge_run.step);
    const build = b.step("rooms-archive-build", "Build and install the archive peer (needs cargo)");
    build.dependOn(&install.step);
    const session_build = b.step("rooms-session-build", "Build and install the session peer (needs cargo)");
    session_build.dependOn(&session_install.step);
    const server_build = b.step("rooms-server-build", "Build and install the Rooms server (needs cargo)");
    server_build.dependOn(&server_install.step);
    const run = execution.addSystemCommand(b, .service, &.{"env"});
    run.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-archive" } });
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    run.step.dependOn(&install.step);
    b.step("rooms-archive", "Run the durable archive peer; pass -- --state=<directory> (iroh by default)").dependOn(&run.step);
    const session_run = execution.addSystemCommand(b, .service, &.{"env"});
    session_run.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-session" } });
    session_run.setCwd(b.path("."));
    session_run.addPassthruArgs();
    session_run.step.dependOn(&session_install.step);
    b.step("rooms-session", "Run the durable Rooms session capability; pass `-- --state=<directory> [--checkpoint=<Rooms JSON>]` (iroh by default, needs cargo)").dependOn(&session_run.step);
    const server_run = execution.addSystemCommand(b, .service, &.{"env"});
    server_run.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } });
    server_run.setCwd(b.path("."));
    server_run.addPassthruArgs();
    server_run.step.dependOn(&server_install.step);
    b.step("rooms-server", "Run the Rooms server: the directory members register with and the rooms they enter; pass `-- [--state=<directory>] [--history] [--admin-listeners] [--diagnostics] [--operator] [--peering] [--trace]` (iroh by default, needs cargo)").dependOn(&server_run.step);

    const compile_tests = execution.addSystemCommand(b, .build_tool, &.{"env"});
    compile_tests.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    compile_tests.addArgs(&.{
        "cargo",        "test",            "--quiet",    "--locked",       "--no-run", "--manifest-path",  "apps/rooms/rust/Cargo.toml",
        "-p",           "rooms-services",  "--features", "processes",      "--lib",    "--test",           "archive_process",
        "--test",       "session_process", "--test",     "server_process", "--test",   "postgres_process", "--test",
        "chat_process",
    });
    compile_tests.addDirectoryArg2(b.path("apps/rooms/rust/target"), .{ .prefix = "--target-dir=", .make_absolute = true });
    compile_tests.setCwd(b.path("."));
    compile_tests.step.dependOn(iroh_abi);
    compile_tests.step.dependOn(b.getInstallStep());
    // Unit semantics and installed-process behavior are two separately bounded
    // subjects. Combining them let a successful 177-test library run spend the
    // whole deterministic budget before any process proof began.
    // Host execution adapters moved to rooms-platform. Keep their client
    // contracts in this focused gate instead of leaving a services filter that
    // silently selects no tests.
    const platform_unit = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{"env"});
    platform_unit.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "LD_LIBRARY_PATH=", .make_absolute = true });
    platform_unit.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    platform_unit.addArgs(&.{
        "cargo", "test",           "--locked", "--manifest-path", "apps/rooms/rust/Cargo.toml",
        "-p",    "rooms-platform", "--lib",    "execution::",
    });
    platform_unit.addDirectoryArg2(b.path("apps/rooms/rust/target"), .{ .prefix = "--target-dir=", .make_absolute = true });
    platform_unit.setCwd(b.path("."));
    platform_unit.step.dependOn(&compile_tests.step);

    const unit_filters = [_][]const []const u8{
        &.{"archive::"},
        &.{"server::"},
        &.{"session_command_tests::"},
        &.{"session_runtime::"},
        &.{"session::"},
        &.{
            "--",                "--skip", "archive::",               "--skip",
            "server::",          "--skip", "session_command_tests::", "--skip",
            "session_runtime::", "--skip", "session::",
        },
    };
    var previous_unit: *std.Build.Step = &platform_unit.step;
    for (unit_filters) |filter| {
        const unit = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{"env"});
        unit.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "LD_LIBRARY_PATH=", .make_absolute = true });
        unit.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
        unit.addArgs(&.{
            "cargo", "test",           "--locked",   "--manifest-path", "apps/rooms/rust/Cargo.toml",
            "-p",    "rooms-services", "--features", "processes",       "--lib",
        });
        unit.addDirectoryArg2(b.path("apps/rooms/rust/target"), .{ .prefix = "--target-dir=", .make_absolute = true });
        unit.addArgs(filter);
        unit.setCwd(b.path("."));
        unit.step.dependOn(previous_unit);
        previous_unit = &unit.step;
    }

    const process_run = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{"env"});
    process_run.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "LD_LIBRARY_PATH=", .make_absolute = true });
    process_run.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "GLOWCAP_LIB_DIR=", .make_absolute = true });
    process_run.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-archive" } }, .{ .prefix = "GLOWCAP_ROOMS_ARCHIVE_TEST_BIN=", .make_absolute = true });
    process_run.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-session" } }, .{ .prefix = "GLOWCAP_ROOMS_SESSION_TEST_BIN=", .make_absolute = true });
    process_run.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_TEST_BIN=", .make_absolute = true });
    process_run.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-chat" } }, .{ .prefix = "GLOWCAP_ROOMS_CHAT_TEST_BIN=", .make_absolute = true });
    process_run.addArgs(&.{
        "cargo",           "test",           "--locked",        "--manifest-path", "apps/rooms/rust/Cargo.toml",
        "-p",              "rooms-services", "--features",      "processes",       "--test",
        "archive_process", "--test",         "session_process", "--test",          "server_process",
        "--test",          "chat_process",
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
    // The database is an explicit opt-in dependency, never a network service
    // a default check silently assumes. Its URL names a disposable database.
    const postgres = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{"env"});
    postgres.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "LD_LIBRARY_PATH=", .make_absolute = true });
    postgres.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_TEST_BIN=", .make_absolute = true });
    postgres.addArgs(&.{ "cargo", "test", "--locked", "--manifest-path", "apps/rooms/rust/Cargo.toml", "-p", "rooms-services", "--features", "processes", "--test", "postgres_process", "--", "--ignored" });
    postgres.setCwd(b.path("."));
    postgres.step.dependOn(&server_install.step);
    postgres.step.dependOn(&compile_tests.step);
    b.step("rooms-postgres-test", "Opt-in: prove the installed Rooms server's PostgreSQL history, restart and exclusive custody (set GLOWCAP_ROOMS_STORAGE_LIVE_URL to a disposable local database)").dependOn(&postgres.step);
    return .{ .installed = &install.step, .web_build = web_build };
}
