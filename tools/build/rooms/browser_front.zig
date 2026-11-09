//! The Rooms browser front owns one production asset generation, the serve
//! step, the Vite development supervisor, and its process proofs.
//! All launches share one transport choice and one dependency recipe. The
//! build's choices reach the front as environment, so every argument on the
//! command line is the person's own and none is given twice.

const std = @import("std");
const commands = @import("../commands.zig");
const execution = @import("../execution.zig");
const Binary = @import("peers.zig").Binary;
const web_tests = @import("web.zig");

pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    version: std.SemanticVersion,
    runtime_gate: *execution.RuntimeGate,
    browser_application: *std.Build.Step,
    archive_install: *std.Build.Step,
    web_services: *std.Build.Step,
    iroh_abi_step: *std.Build.Step,
    ocapn_install: *std.Build.Step,
    host_install: *std.Build.Step,
    driver_install: *std.Build.Step,
    tcp_install: *std.Build.Step,
    relay_install: *std.Build.Step,
    pin_port: ?u16,
};

const Transport = enum { tcp, @"keyed-tcp", @"noise-tcp", iroh, @"keyed-relay", @"noise-relay", onion };

const Launch = struct {
    /// A state directory for the room server, or the front's temporary one.
    state_dir: ?[]const u8 = null,
    /// Mint every operator capability for development. Production only mints
    /// capabilities selected by server flags passed after `--`.
    mint_everything: bool = false,
    /// Serve source modules through the app's Fast Refresh supervisor.
    hot_reload: bool = false,
};

pub const Registered = struct {
    /// The prepared generation at zig-out/rooms-web/current.
    prepare: *std.Build.Step,
    /// The Rooms page exported under the site's assets, which the site
    /// render and preview serve at /rooms/app/.
    site_page: *std.Build.Step,
};

pub fn register(ctx: Context) Registered {
    const b = ctx.b;

    // One immutable production generation serves process and browser proofs
    // and deployment. Source-compilation tests keep their own isolated roots.
    const prepare = commands.addRootedSystemCommand(b, .build_tool, &.{"env"});
    Binary.web.addAbsoluteArg(prepare);
    prepare.addArg("--prepare=zig-out/rooms-web");
    prepare.has_side_effects = true;
    prepare.step.dependOn(ctx.web_services);
    prepare.step.dependOn(ctx.browser_application);
    b.step("rooms-web-prepare", "Build the Rooms server and write its browser assets as one prepared generation at zig-out/rooms-web/current, which the Rooms server binary's `--prepared` serves and `--export-static` exports (needs cargo + deno + wasm-bindgen)")
        .dependOn(&prepare.step);
    web_tests.register(b, ctx.runtime_gate, ctx.web_services, &prepare.step);

    // The page the website publishes at glowcap.org/rooms/app/: the prepared
    // generation exported for that base path into the site's assets, where
    // Zine serves it as a static directory, in the render and in the preview
    // alike, and `.gitignore` keeps it out of the tree.
    const site_page = commands.addRootedSystemCommand(b, .build_tool, &.{"env"});
    Binary.web.addAbsoluteArg(site_page);
    site_page.addArgs(&.{ "--export-static=site/assets/rooms/app", "--assets=zig-out/rooms-web/current", "--base=/rooms/app/" });
    site_page.has_side_effects = true;
    site_page.step.dependOn(&prepare.step);
    b.step("site-rooms-page", "Export the Rooms page into site/assets/rooms/app from the prepared browser generation, where the site and its preview serve it at /rooms/app/ with no Rooms server behind it (needs cargo + deno + wasm-bindgen)")
        .dependOn(&site_page.step);

    const staging = @import("../release/stage.zig");
    const product = staging.add(b, ctx.target, ctx.version, "product", staging.product);
    product.step.dependOn(&prepare.step);
    // The stage copies every Rooms helper and the iroh companion out of the
    // install prefix. Each must be installed by this build: without these
    // edges a leftover helper from an earlier build shipped beside a fresh status-allow: event or source ordering
    // companion, and the session refused the mismatched callable surface.
    product.step.dependOn(ctx.archive_install);
    product.step.dependOn(ctx.iroh_abi_step);
    const resources = staging.installResources(b, "product");
    resources.step.dependOn(&product.step);
    const rooms_build = b.step("glowcap-install", "Install the complete glowcap product and stage its deployment tree: CLI, Rooms runtimes, browser assets and skills (needs cargo + deno + wasm-bindgen)");
    rooms_build.dependOn(&resources.step);
    const install_proof = commands.addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/glowcap_release.py", "--installed" });
    install_proof.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix } }, .{ .make_absolute = true });
    install_proof.addFileArg(b.path("glowcap"));
    install_proof.step.dependOn(rooms_build);
    const install_test = b.step("glowcap-install-test", "Prove the source launcher serves Rooms after glowcap-install, with installed sessions, skills, and completion");
    install_test.dependOn(&install_proof.step);
    ctx.runtime_gate.add(install_test);

    const host_test = b.step("glowcap-host-test", "Prove verified host installation and Docker deployment commands without a daemon (needs python3)");
    // Installation verifies the complete product inventory, and each
    // deployment scenario owns its commands. Suite growth must not consume
    // another's deadline.
    inline for (.{ "--installation", "--deployment", "--deployment-builds", "--deployment-reset" }) |mode| {
        const host_proof = commands.addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/glowcap_host.py" });
        host_proof.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "product" } }, .{ .make_absolute = true });
        host_proof.addArg(mode);
        host_proof.step.dependOn(rooms_build);
        host_test.dependOn(&host_proof.step);
    }
    // The scenario waits out the product's fixed 15-second Docker query
    // budget, which no runner speed changes. Its one child run carries the
    // script's own 20-second bound, so the step is an orchestrator of a
    // bounded child rather than work a process deadline should scale.
    const deadline_proof = commands.addInstalledSystemRun(b, .child_bounded, &.{ "python3", "tools/check/glowcap_host.py" });
    deadline_proof.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "product" } }, .{ .make_absolute = true });
    deadline_proof.addArg("--deadline");
    deadline_proof.step.dependOn(rooms_build);
    host_test.dependOn(&deadline_proof.step);
    ctx.runtime_gate.add(host_test);

    // The room transport is one option because the production and development
    // fronts forward the same `--transport=` contract to the room server.
    const transport = b.option(Transport, "transport", "The room transport rooms-web and rooms-dev announce: iroh (default, encrypted QUIC), noise-tcp or noise-relay (Noise-sealed), tcp, keyed-tcp, or keyed-relay (cleartext, for a peer that speaks nothing else), or onion (a Tor onion service that requires tor)") orelse .iroh;

    const production = addLaunch(ctx, transport, .{});
    b.step("rooms-web", "Serve the rooms browser UI for public rooms and direct messages by introduction. Open the printed URL. This needs cargo and deno, while onion also needs tor. `-Dtransport=<transport>` picks the announced room transport from the seven the server accepts, default iroh. Server flags follow `--`: `--capabilities=all` or a comma-separated list of admin-listeners, diagnostics, operator, peering, irc, and trace mints the operations capabilities. `--bind=<host> --announce-host=<host>` expose a cleartext room on a LAN")
        .dependOn(&production.step);

    // Both development fronts share state, grants, transport, and dependencies.
    // Fast Refresh changes who serves the browser, not the Rooms service setup.
    const development: Launch = .{
        .state_dir = commands.rootPath(b, ".local/.state/rooms"),
        .mint_everything = true,
        .hot_reload = b.option(bool, "hot-reload", "Use Vite Fast Refresh for rooms-dev; false serves compiled generations through the Rooms web server") orelse true,
    };
    const rooms_dev = addLaunch(ctx, transport, development);
    b.step("rooms-dev", "Serve Rooms with every operator capability minted and state under .local/.state/rooms; `-Dhot-reload=false` uses compiled-generation serving, and `-Dtransport` works as on rooms-web (needs cargo + deno)")
        .dependOn(&rooms_dev.step);

    return .{ .prepare = &prepare.step, .site_page = &site_page.step };
}

fn addLaunch(ctx: Context, transport: Transport, launch: Launch) *std.Build.Step.Run {
    const b = ctx.b;
    const run = commands.addInstalledSystemRun(b, postureFor(transport), &.{"env"});
    addEnvironment(run, b, transport, launch);
    if (launch.hot_reload) run.addArgs(&.{
        "deno", "run", "-A", "--config=apps/rooms/deno.json", "apps/rooms/web/dev.ts",
    });
    Binary.web.addAbsoluteArg(run);
    if (ctx.pin_port != null or launch.hot_reload) run.addArg(b.fmt("{d}", .{ctx.pin_port orelse 8080}));
    run.addPassthruArgs();
    addDependencies(run, ctx, transport);
    return run;
}

fn addEnvironment(run: *std.Build.Step.Run, b: *std.Build, transport: Transport, launch: Launch) void {
    Binary.server.addEnv(run);
    run.addArg(b.fmt("GLOWCAP_ROOMS_TRANSPORT={s}", .{@tagName(transport)}));
    if (launch.state_dir) |dir| run.addArg(b.fmt("GLOWCAP_ROOMS_STATE={s}", .{dir}));
    if (launch.mint_everything) {
        run.addArg("GLOWCAP_ROOMS_CAPABILITIES=all");
        run.addArg(b.fmt("GLOWCAP_ROOMS_SESSION_STATE={s}", .{commands.rootPath(b, ".local/.state/rooms-session")}));
    }
}

fn addDependencies(run: *std.Build.Step.Run, ctx: Context, transport: Transport) void {
    run.step.dependOn(ctx.browser_application);
    run.step.dependOn(ctx.web_services);
    switch (transport) {
        .iroh => run.step.dependOn(ctx.iroh_abi_step),
        .tcp, .@"keyed-tcp", .@"noise-tcp", .@"keyed-relay", .@"noise-relay" => {
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
