//! The Rooms browser front owns one production asset generation, the serve
//! step, the Vite development supervisor, and its process proofs.
//! All launches share one transport option and
//! one dependency recipe.

const std = @import("std");
const common = @import("../common.zig");
const execution = @import("../execution.zig");
const web_tests = @import("web.zig");

pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    version: std.SemanticVersion,
    runtime_gate: *execution.RuntimeGate,
    browser_application: *std.Build.Step,
    archive_install: *std.Build.Step,
    iroh_abi_step: *std.Build.Step,
    ocapn_install: *std.Build.Step,
    host_install: *std.Build.Step,
    driver_install: *std.Build.Step,
    tcp_install: *std.Build.Step,
    relay_install: *std.Build.Step,
    pin_port: ?u16,
};

const Transport = enum { iroh, tcp, onion };

const Launch = struct {
    /// A state directory for the room server, or the front's temporary one.
    state_dir: ?[]const u8 = null,
    /// Mint every operator capability for development. Production only mints
    /// capabilities selected by server flags passed after `--`.
    mint_everything: bool = false,
    /// Serve source modules through the app's Fast Refresh supervisor.
    hot_reload: bool = false,
};

pub fn register(ctx: Context) void {
    const b = ctx.b;

    // One immutable production generation serves the native process proofs and
    // deployment. Source-compilation tests keep their own isolated roots.
    const prepare = execution.addSystemCommand(b, .build_tool, &.{"env"});
    prepare.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-web" } }, .{ .make_absolute = true });
    prepare.addArg("--prepare=zig-out/rooms-web");
    prepare.setCwd(b.path("."));
    prepare.has_side_effects = true;
    prepare.step.dependOn(ctx.archive_install);
    prepare.step.dependOn(ctx.browser_application);
    web_tests.register(b, ctx.runtime_gate, ctx.archive_install, &prepare.step);

    const staging = @import("../release/stage.zig");
    const product = staging.add(b, ctx.target, ctx.version, "product", staging.product);
    product.step.dependOn(&prepare.step);
    const resources = staging.installResources(b, "product");
    resources.step.dependOn(&product.step);
    const rooms_build = b.step("rooms-build", "Install the complete glowcap product and stage its deployment tree: CLI, Rooms runtimes, browser assets and skills");
    rooms_build.dependOn(&resources.step);
    const install_proof = common.addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/glowcap_release.py", "--installed" });
    install_proof.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix } }, .{ .make_absolute = true });
    install_proof.addFileArg(b.path("glowcap"));
    install_proof.step.dependOn(rooms_build);
    const install_test = b.step("glowcap-install-test", "Prove the source launcher serves Rooms after rooms-build, with installed sessions, skills, and completion");
    install_test.dependOn(&install_proof.step);
    ctx.runtime_gate.add(install_test);

    const host_proof = common.addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/glowcap_host.py" });
    host_proof.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "product" } }, .{ .make_absolute = true });
    host_proof.step.dependOn(rooms_build);
    const host_test = b.step("glowcap-host-test", "Prove verified host installation and Docker deployment commands without a daemon");
    host_test.dependOn(&host_proof.step);
    // The deliberately exhausted 15-second product query budget needs its
    // own calibrated process deadline, separate from installation/deployment.
    const deadline_proof = common.addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/glowcap_host.py" });
    deadline_proof.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "product" } }, .{ .make_absolute = true });
    deadline_proof.addArg("--deadline");
    deadline_proof.step.dependOn(rooms_build);
    host_test.dependOn(&deadline_proof.step);
    ctx.runtime_gate.add(host_test);

    // The room transport is one option because the native and development
    // fronts forward the same `--transport=` contract to the room server.
    const transport = b.option(Transport, "transport", "The room transport rooms-web and rooms-dev serve: iroh (default, encrypted QUIC), tcp (cleartext, for a peer that speaks nothing else), or onion (a Tor onion service that requires tor)") orelse .iroh;

    const production = addLaunch(ctx, transport, .{});
    b.step("rooms-web", "Serve the rooms browser UI for public rooms and direct messages by introduction. Open the printed URL. This needs cargo and deno, while onion also needs tor. `-Dtransport=iroh|tcp|onion` picks the room transport, default iroh. Server flags follow `--`: `--diagnostics` / `--admin-listeners` / `--operator` / `--peering` / `--trace` / `--irc` mint the operations capabilities. `--bind=<host> --announce-host=<host>` expose a cleartext room on a LAN")
        .dependOn(&production.step);

    // Both development fronts share state, grants, transport, and dependencies.
    // Fast Refresh changes who serves the browser, not the native service setup.
    const development: Launch = .{
        .state_dir = common.rootPath(b, ".local/.state/rooms"),
        .mint_everything = true,
        .hot_reload = b.option(bool, "hot-reload", "Use Vite Fast Refresh for rooms-dev; false serves compiled generations through the native web front") orelse true,
    };
    const rooms_dev = addLaunch(ctx, transport, development);
    b.step("rooms-dev", "Serve Rooms with every operator capability minted and state under .local/.state/rooms; `-Dhot-reload=false` uses native generation serving, and `-Dtransport` works as on rooms-web (needs cargo + deno)")
        .dependOn(&rooms_dev.step);

    const deploy_step = b.step("rooms-deploy-prep", "Prepare the complete Linux product as a Docker image build context (needs cargo + deno)");
    if (ctx.target.result.os.tag != .linux or b.graph.host.result.os.tag != .linux) {
        deploy_step.dependOn(&b.addFail("Docker requires a Linux product; run rooms-deploy-prep in the Linux devcontainer").step);
    } else {
        deploy_step.dependOn(rooms_build);
    }
}

fn addLaunch(ctx: Context, transport: Transport, launch: Launch) *std.Build.Step.Run {
    const b = ctx.b;
    const run = common.addInstalledSystemRun(b, postureFor(transport), &.{"env"});
    addEnvironment(run, b, launch);
    if (launch.hot_reload) run.addArgs(&.{
        "deno", "run", "-A", "--config=apps/rooms/web/deno.json", "apps/rooms/web/dev.ts",
    });
    run.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-web" } }, .{ .make_absolute = true });
    if (ctx.pin_port != null or launch.hot_reload) run.addArg(b.fmt("{d}", .{ctx.pin_port orelse 8080}));
    addOptions(run, b, transport, launch);
    addDependencies(run, ctx, transport);
    return run;
}

fn addEnvironment(run: *std.Build.Step.Run, b: *std.Build, launch: Launch) void {
    run.addFileArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "libexec/rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
    if (launch.state_dir) |dir| run.addArg(b.fmt("GLOWCAP_ROOMS_STATE={s}", .{dir}));
}

fn addOptions(run: *std.Build.Step.Run, b: *std.Build, transport: Transport, launch: Launch) void {
    run.addArg(b.fmt("--transport={s}", .{@tagName(transport)}));
    if (launch.mint_everything) {
        run.addArgs(&.{ "--admin-listeners", "--diagnostics", "--irc", "--operator", "--peering", "--trace" });
    }
    run.addPassthruArgs();
}

fn addDependencies(run: *std.Build.Step.Run, ctx: Context, transport: Transport) void {
    run.step.dependOn(ctx.browser_application);
    run.step.dependOn(ctx.archive_install);
    switch (transport) {
        .iroh => run.step.dependOn(ctx.iroh_abi_step),
        .tcp => {
            run.step.dependOn(ctx.ocapn_install);
            run.step.dependOn(ctx.host_install);
            run.step.dependOn(ctx.driver_install);
            run.step.dependOn(ctx.tcp_install);
            run.step.dependOn(ctx.relay_install);
        },
        .onion => {},
    }
}

fn postureFor(transport: Transport) execution.Posture {
    return if (transport == .onion) .real_internet else .service;
}
