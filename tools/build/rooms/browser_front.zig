//! The Rooms browser front owns one production asset generation, the native
//! serve step, the Vite development supervisor, its native process proofs, and
//! the deploy-preparation marker. All launches share one transport option and
//! one dependency recipe.

const std = @import("std");
const common = @import("../common.zig");
const execution = @import("../execution.zig");
const web_tests = @import("web.zig");

pub const Context = struct {
    b: *std.Build,
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
    prepare.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-web" } }, .{ .make_absolute = true });
    prepare.addArg("--prepare=zig-out/rooms-web");
    prepare.setCwd(b.path("."));
    prepare.has_side_effects = true;
    prepare.step.dependOn(ctx.archive_install);
    prepare.step.dependOn(ctx.browser_application);
    web_tests.register(b, ctx.runtime_gate, ctx.archive_install, &prepare.step);

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

    // The marker commits last, after every artifact mounted by the deployment
    // has finished. The deployment itself runs no compiler and mounts no source.
    const deploy_finish = execution.addSystemCommand(b, .build_tool, &.{
        "sh", "apps/rooms/web/finish-deployment.sh",
    });
    deploy_finish.setCwd(b.path("."));
    deploy_finish.has_side_effects = true;
    deploy_finish.step.dependOn(b.getInstallStep());
    deploy_finish.step.dependOn(ctx.iroh_abi_step);
    deploy_finish.step.dependOn(ctx.archive_install);
    deploy_finish.step.dependOn(&prepare.step);
    const deploy_step = b.step("rooms-deploy-prep", "Build and version everything the rooms deploy container mounts: shared libraries, iroh, the wasm Host, browser UI, and native peers (needs cargo + deno)");
    deploy_step.dependOn(&deploy_finish.step);
}

fn addLaunch(ctx: Context, transport: Transport, launch: Launch) *std.Build.Step.Run {
    const b = ctx.b;
    const run = common.addInstalledSystemRun(b, postureFor(transport), &.{"env"});
    addEnvironment(run, b, launch);
    if (launch.hot_reload) run.addArgs(&.{
        "deno", "run", "-A", "--config=apps/rooms/web/deno.json", "apps/rooms/web/dev.ts",
    });
    run.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-web" } }, .{ .make_absolute = true });
    if (ctx.pin_port != null or launch.hot_reload) run.addArg(b.fmt("{d}", .{ctx.pin_port orelse 8000}));
    addOptions(run, b, transport, launch);
    addDependencies(run, ctx, transport);
    return run;
}

fn addEnvironment(run: *std.Build.Step.Run, b: *std.Build, launch: Launch) void {
    run.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
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
