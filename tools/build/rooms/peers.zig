//! The Rooms peers, `rooms-archive`, `rooms-session`, and
//! `rooms-server`: their build, install, run steps, and the identity,
//! transport, restart, and shutdown proofs that ride `runtime-check`.
const std = @import("std");
const commands = @import("../commands.zig");
const execution = @import("../execution.zig");

/// An installed Rooms executable: the file it installs as under `libexec/`,
/// the Cargo binary that builds it, and the environment variables a run reads
/// its absolute path from. Every step that installs, runs, or hands one to a
/// proof names it here, so a name and its variable are spelled once.
pub const Binary = enum {
    chat,
    archive,
    session,
    server,
    irc_bridge,
    irc_server,
    web,
    web_proof,
    server_proof,

    const Row = struct {
        name: []const u8,
        /// The Cargo binary the install copies, when it is not `name`.
        cargo: ?[]const u8 = null,
        /// Names the path to a demo or product proof's executable.
        env: ?[]const u8 = null,
        /// Names the path to the executable a test drives.
        test_env: ?[]const u8 = null,
    };

    const rows = std.EnumArray(Binary, Row).init(.{
        .chat = .{ .name = "rooms-chat", .test_env = "GLOWCAP_ROOMS_CHAT_TEST_BIN" },
        .archive = .{ .name = "rooms-archive", .env = "GLOWCAP_ROOMS_ARCHIVE_BIN", .test_env = "GLOWCAP_ROOMS_ARCHIVE_TEST_BIN" },
        .session = .{ .name = "rooms-session", .env = "GLOWCAP_ROOMS_SESSION_BIN", .test_env = "GLOWCAP_ROOMS_SESSION_TEST_BIN" },
        .server = .{ .name = "rooms-server", .env = "GLOWCAP_ROOMS_SERVER_BIN", .test_env = "GLOWCAP_ROOMS_SERVER_TEST_BIN" },
        .irc_bridge = .{ .name = "rooms-irc-bridge", .env = "GLOWCAP_ROOMS_IRC_BRIDGE_BIN" },
        .irc_server = .{ .name = "rooms-irc-server", .env = "GLOWCAP_ROOMS_IRC_SERVER_BIN" },
        .web = .{ .name = "rooms-web", .env = "GLOWCAP_ROOMS_WEB_BIN", .test_env = "GLOWCAP_ROOMS_WEB_TEST_BIN" },
        .web_proof = .{ .name = "rooms-web-proof", .cargo = "rooms-web", .test_env = "GLOWCAP_ROOMS_WEB_TEST_BIN" },
        .server_proof = .{ .name = "rooms-server-proof", .cargo = "rooms-server", .test_env = "GLOWCAP_ROOMS_SERVER_TEST_BIN" },
    });

    fn row(self: Binary) Row {
        return rows.get(self);
    }

    fn libexec(self: Binary, b: *std.Build) []const u8 {
        return b.fmt("libexec/{s}", .{self.row().name});
    }

    /// Install the Cargo binary built into `target_dir` as this executable.
    pub fn addInstall(self: Binary, b: *std.Build, target_dir: []const u8) *std.Build.Step.InstallFile {
        const built = self.row().cargo orelse self.row().name;
        return b.addInstallFileWithDir(b.path(b.fmt("{s}/{s}", .{ target_dir, built })), .prefix, self.libexec(b));
    }

    /// Pass the installed path as an argument.
    pub fn addArg(self: Binary, run: *std.Build.Step.Run) void {
        run.addFileArg(.{ .relative = .{ .base = .install_prefix, .sub_path = self.libexec(run.step.owner) } });
    }

    /// Pass the installed absolute path as an argument, for a command that
    /// changes directory.
    pub fn addAbsoluteArg(self: Binary, run: *std.Build.Step.Run) void {
        run.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = self.libexec(run.step.owner) } }, .{ .make_absolute = true });
    }

    /// Pass `<env>=<installed path>` to a command started through `env`.
    pub fn addEnv(self: Binary, run: *std.Build.Step.Run) void {
        self.addNamedEnv(run, self.row().env.?);
    }

    /// Pass `<test_env>=<installed path>` to a command started through `env`.
    pub fn addTestEnv(self: Binary, run: *std.Build.Step.Run) void {
        self.addNamedEnv(run, self.row().test_env.?);
    }

    /// Set `<test_env>` to the installed path in the command's environment.
    /// The build API gives configure no install path, so this names the
    /// default prefix.
    pub fn setTestEnv(self: Binary, run: *std.Build.Step.Run) void {
        const b = run.step.owner;
        run.setEnvironmentVariable(self.row().test_env.?, commands.rootPath(b, b.fmt("zig-out/{s}", .{self.libexec(b)})));
    }

    fn addNamedEnv(self: Binary, run: *std.Build.Step.Run, variable: []const u8) void {
        const b = run.step.owner;
        run.addFileArg2(
            .{ .relative = .{ .base = .install_prefix, .sub_path = self.libexec(b) } },
            .{ .prefix = b.fmt("{s}=", .{variable}), .make_absolute = true },
        );
    }
};

/// Where Cargo's release profile writes the peers.
const release_dir = "apps/rooms/rust/target/release";
/// Where the browser-proof profile writes the proof builds of the web front and server.
const proof_dir = "apps/rooms/rust/target/browser-server-proof/browser-proof";

pub const Peers = struct {
    installed: *std.Build.Step,
    browser_installed: *std.Build.Step,
    web_build: *std.Build.Step,
};

pub fn register(b: *std.Build, runtime_gate: *execution.RuntimeGate, iroh_abi: *std.Build.Step, zig_archives: []const *std.Build.Step) Peers {
    const proof_compile = compileWithProfile(b, iroh_abi, zig_archives, &.{ "rooms-web", "rooms-server" }, "browser-proof", "apps/rooms/rust/target/browser-server-proof");
    const proof_web = Binary.web_proof.addInstall(b, proof_dir);
    proof_web.step.dependOn(&proof_compile.step);
    const proof_server = Binary.server_proof.addInstall(b, proof_dir);
    proof_server.step.dependOn(&proof_compile.step);
    proof_server.step.dependOn(&proof_web.step);
    const browser_compile = compilePeers(b, iroh_abi, zig_archives, &.{ "rooms-web", "rooms-server" });
    const compile = compilePeers(b, iroh_abi, zig_archives, &.{ "rooms-archive", "rooms-session", "rooms-irc-bridge", "rooms-irc-server", "rooms-chat" });
    // These groups share Cargo's output directory. Complete product builds
    // serialize them; browser builds never enter the unrelated second group.
    compile.step.dependOn(&browser_compile.step);
    const chat_install = Binary.chat.addInstall(b, release_dir);
    chat_install.step.dependOn(&compile.step);
    b.step("rooms-chat-build", "Build and install the interactive Rooms client (needs cargo)").dependOn(&chat_install.step);
    const chat_run = commands.addRootedSystemCommand(b, .service, &.{"env"});
    Binary.chat.addArg(chat_run);
    chat_run.addPassthruArgs();
    chat_run.step.dependOn(&chat_install.step);
    b.step("rooms-chat", "Chat interactively; pass -- <locator> <room> <nick> (needs cargo)").dependOn(&chat_run.step);
    const install = Binary.archive.addInstall(b, release_dir);
    install.step.dependOn(&compile.step);
    install.step.dependOn(&chat_install.step);
    const session_install = Binary.session.addInstall(b, release_dir);
    session_install.step.dependOn(&compile.step);
    const server_install = Binary.server.addInstall(b, release_dir);
    server_install.step.dependOn(&browser_compile.step);
    install.step.dependOn(&session_install.step);
    install.step.dependOn(&server_install.step);
    const bridge_install = Binary.irc_bridge.addInstall(b, release_dir);
    bridge_install.step.dependOn(&compile.step);
    install.step.dependOn(&bridge_install.step);
    const web_install = Binary.web.addInstall(b, release_dir);
    web_install.step.dependOn(&browser_compile.step);
    install.step.dependOn(&web_install.step);
    const web_build = b.step("rooms-web-build", "Build and install the Rooms HTTP front and browser application (needs cargo + wasm-bindgen)");
    web_build.dependOn(&web_install.step);
    server_install.step.dependOn(&web_install.step);
    web_build.dependOn(&server_install.step);
    const irc_server_install = Binary.irc_server.addInstall(b, release_dir);
    irc_server_install.step.dependOn(&compile.step);
    install.step.dependOn(&irc_server_install.step);
    b.step("rooms-irc-server-build", "Build and install the Rooms IRC server (needs cargo)").dependOn(&irc_server_install.step);
    const irc_server_run = commands.addRootedSystemCommand(b, .service, &.{"env"});
    Binary.irc_server.addArg(irc_server_run);
    irc_server_run.addPassthruArgs();
    irc_server_run.step.dependOn(&irc_server_install.step);
    b.step("rooms-irc-server", "Serve a Rooms directory to ordinary IRC clients as an IRC server").dependOn(&irc_server_run.step);
    b.step("rooms-irc-bridge-build", "Build and install the standalone IRC bridge (needs cargo)").dependOn(&bridge_install.step);
    const bridge_run = commands.addRootedSystemCommand(b, .service, &.{"env"});
    Binary.irc_bridge.addArg(bridge_run);
    bridge_run.addPassthruArgs();
    bridge_run.step.dependOn(&bridge_install.step);
    b.step("rooms-irc-bridge", "Serve one IRC channel as a Rooms directory with the bridge (read-only by default)").dependOn(&bridge_run.step);
    const build = b.step("rooms-archive-build", "Build and install the archive peer (needs cargo)");
    build.dependOn(&install.step);
    const session_build = b.step("rooms-session-build", "Build and install the durable Rooms session runtime (needs cargo)");
    session_build.dependOn(&session_install.step);
    const server_build = b.step("rooms-server-build", "Build and install the Rooms server (needs cargo)");
    server_build.dependOn(&server_install.step);
    const run = commands.addRootedSystemCommand(b, .service, &.{"env"});
    Binary.archive.addArg(run);
    run.addPassthruArgs();
    run.step.dependOn(&install.step);
    b.step("rooms-archive", "Run the durable archive peer; pass -- --state=<directory> (iroh by default)").dependOn(&run.step);
    const server_run = commands.addRootedSystemCommand(b, .service, &.{"env"});
    Binary.server.addArg(server_run);
    server_run.addPassthruArgs();
    server_run.step.dependOn(&server_install.step);
    b.step("rooms-server", "Run the Rooms server: the directory members register with and the rooms they enter; pass `-- [--state=<directory>] [--history] [--admin-listeners] [--diagnostics] [--operator] [--peering] [--trace]` (iroh by default, needs cargo)").dependOn(&server_run.step);

    const compile_tests = commands.addRootedSystemCommand(b, .build_tool, &.{"env"});
    commands.addLibDirArg(compile_tests, .host);
    compile_tests.addArgs(&.{
        "cargo",          "test",          "--quiet",      "--locked",        "--no-run",      "--manifest-path", "apps/rooms/rust/Cargo.toml",
        "-p",             "rooms-product", "--test",       "archive_process", "--test",        "session_process", "--test",
        "server_process", "--test",        "chat_process", "--bin",           "rooms-session",
    });
    compile_tests.addDirectoryArg2(b.path("apps/rooms/rust/target"), .{ .prefix = "--target-dir=", .make_absolute = true });
    compile_tests.step.dependOn(iroh_abi);
    for (zig_archives) |archive| compile_tests.step.dependOn(archive);
    const service_unit_args: []const []const u8 = &.{ "cargo", "test", "--locked", "--manifest-path", "apps/rooms/rust/Cargo.toml", "-p", "rooms-services", "--features", "processes", "--lib" };
    const compile_units = commands.addRootedSystemCommand(b, .build_tool, &.{"env"});
    commands.addLibDirArg(compile_units, .host);
    compile_units.addArgs(service_unit_args);
    compile_units.addArgs(&.{ "--quiet", "--no-run" });
    compile_units.addDirectoryArg2(b.path("apps/rooms/rust/target"), .{ .prefix = "--target-dir=", .make_absolute = true });
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
    const compile_platform = commands.addRootedSystemCommand(b, .build_tool, &.{"env"});
    commands.addLibDirArg(compile_platform, .host);
    compile_platform.addArgs(platform_unit_args);
    compile_platform.addArgs(&.{ "--quiet", "--no-run" });
    compile_platform.addDirectoryArg2(b.path("apps/rooms/rust/target"), .{ .prefix = "--target-dir=", .make_absolute = true });
    compile_platform.step.dependOn(&compile_units.step);
    const platform_unit = commands.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{"env"});
    platform_unit.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "LD_LIBRARY_PATH=", .make_absolute = true });
    commands.addLibDirArg(platform_unit, .host);
    platform_unit.addArgs(platform_unit_args);
    platform_unit.addDirectoryArg2(b.path("apps/rooms/rust/target"), .{ .prefix = "--target-dir=", .make_absolute = true });
    platform_unit.addArgs(&.{ "--", "execution::", "signaling::" });
    platform_unit.step.dependOn(&compile_platform.step);

    const unit_filters = [_][]const []const u8{
        &.{"archive::"},
        &.{"server::"},
        &.{"session::"},
        &.{ "--", "--skip", "archive::", "--skip", "server::", "--skip", "session::" },
    };
    var previous_unit: *std.Build.Step = &platform_unit.step;
    for (unit_filters) |filter| {
        const unit = commands.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{"env"});
        unit.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "LD_LIBRARY_PATH=", .make_absolute = true });
        commands.addLibDirArg(unit, .host);
        unit.addArgs(service_unit_args);
        unit.addDirectoryArg2(b.path("apps/rooms/rust/target"), .{ .prefix = "--target-dir=", .make_absolute = true });
        unit.addArgs(filter);
        unit.step.dependOn(previous_unit);
        previous_unit = &unit.step;
    }

    const process_run = commands.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{"env"});
    process_run.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{ .prefix = "LD_LIBRARY_PATH=", .make_absolute = true });
    commands.addLibDirArg(process_run, .host);
    Binary.archive.addTestEnv(process_run);
    Binary.session.addTestEnv(process_run);
    Binary.server.addTestEnv(process_run);
    Binary.chat.addTestEnv(process_run);
    process_run.addArgs(&.{
        "cargo",           "test",          "--locked",       "--manifest-path", "apps/rooms/rust/Cargo.toml",
        "-p",              "rooms-product", "--test",         "archive_process", "--test",
        "session_process", "--test",        "server_process", "--test",          "chat_process",
        "--bin",           "rooms-session",
    });
    process_run.addDirectoryArg2(b.path("apps/rooms/rust/target"), .{ .prefix = "--target-dir=", .make_absolute = true });
    process_run.step.dependOn(previous_unit);
    const test_step = b.step("rooms-peers-test", "Prove the archive peer, session peer, and Rooms server's identity, transport, restart and shutdown (needs cargo)");
    process_run.step.dependOn(&install.step);
    process_run.step.dependOn(&session_install.step);
    process_run.step.dependOn(&server_install.step);
    test_step.dependOn(&process_run.step);
    runtime_gate.add(test_step);
    // The same finite journey runs against release archives on Intel macOS.
    // Every command, readiness wait and shutdown owns its deadline.
    const agent_run = commands.addRootedSystemCommand(b, .child_bounded, &.{ "python3", "tools/check/rooms_peer.py" });
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
    const compile = commands.addRootedSystemCommand(b, .build_tool, &.{"env"});
    commands.addLibDirArg(compile, .host);
    compile.addArgs(&.{ "cargo", "build", "--quiet", "--locked", "--profile", profile, "--manifest-path", "apps/rooms/rust/Cargo.toml", "-p", "rooms-product" });
    for (binaries) |binary| compile.addArgs(&.{ "--bin", binary });
    compile.addDirectoryArg2(b.path(target_dir), .{ .prefix = "--target-dir=", .make_absolute = true });
    for (zig_archives) |archive| compile.step.dependOn(archive);
    compile.step.dependOn(iroh_abi);
    return compile;
}
