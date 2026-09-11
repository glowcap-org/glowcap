//! The rooms application's build steps, registered as one subject the root
//! `build.zig` composes: the native Zig clients (TCP and iroh), the hermetic
//! Deno suite that rides `check`, the cross-language demos, the browser UI
//! serve steps, the `rooms-web-*` proof family, and the deploy bundle. The
//! product CLI (`glowcap app rooms-peer`) is its own subject and stays in the
//! root beside the other CLI steps.
//!
//! The demos and serves are sibling steps of `check`, not members: they need
//! deno, and the iroh legs need cargo. What does ride `check` is the hermetic
//! suite plus a compile guard for every client variant, so an API change
//! cannot rot a client only the demo steps run.
//!
//! One row is a member: `rooms-dm-reredeem` runs a proof that lives in
//! `apps/rooms/test/`, and a proof outside every gate is the one kind of red
//! nobody sees. See `DmDemo.gated`.

const std = @import("std");
const common = @import("common.zig");
const execution = @import("execution.zig");
const rooms_tests = @import("rooms/tests.zig");
const rooms_rust = @import("rooms/rust.zig");
const rooms_peers = @import("rooms/peers.zig");
const rooms_web_native = @import("rooms/web.zig");

/// What the rooms family draws from the root build graph. Everything here is
/// minted by the root before the family registers; the family adds no layer
/// of its own.
pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// The public `glowcap` module.
    lib_mod: *std.Build.Module,
    iroh_resident_mod: *std.Build.Module,
    demo_rooms_cli_mod: *std.Build.Module,
    demo_usage_mod: *std.Build.Module,
    check_step: *std.Build.Step,
    browser_preflight: *std.Build.Step,
    wasm_driver_install: *std.Build.Step,
    wasm_archives: *std.Build.Step,
    iroh_abi_step: *std.Build.Step,
    iroh_sidecar_archive: std.Build.LazyPath,
    /// The dynamic-install steps of exactly the archives the hermetic suite
    /// dlopens. The native archive separately depends on the iroh companion.
    ocapn_install: *std.Build.Step,
    host_install: *std.Build.Step,
    driver_install: *std.Build.Step,
    tcp_install: *std.Build.Step,
    relay_install: *std.Build.Step,
    pin_port: ?u16,
    attach: bool,
    diagnostics: bool,
    admin_listeners: bool,
    operator: bool,
    peering: bool,
    viz: bool,
};

/// One `rooms-web-*` proof: a Deno harness driving the served page or its
/// peers, needing the wasm module and the installed archives, plus a
/// Playwright Chromium for every row that opens a real browser and the iroh
/// C ABI companion for the rows that run the room over iroh.
const WebProof = struct {
    step_name: []const u8,
    description: []const u8,
    source: []const u8,
    needs_browser: bool = true,
    needs_iroh: bool = false,
    needs_archive: bool = false,
    /// The proof attaches browsers to the installed native session peer.
    needs_session: bool = false,
};

/// One native direct-message demo: a Deno scenario over the installed
/// archives, TCP only, no browser.
const DmDemo = struct {
    step_name: []const u8,
    description: []const u8,
    source: []const u8,
    /// Whether `check` runs it. Demos stay opt-in, while proofs under
    /// `apps/rooms/test/` must ride a gate so their contracts cannot rot.
    gated: bool = false,
};

pub fn register(ctx: Context) *std.Build.Step {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const lib_mod = ctx.lib_mod;
    const check_step = ctx.check_step;
    const peers = rooms_peers.register(b, check_step, ctx.iroh_abi_step);
    const archive_install = peers.installed;
    const browser_application = rooms_rust.register(b, check_step, ctx.wasm_archives, ctx.wasm_driver_install, archive_install);
    peers.web_build.dependOn(browser_application);
    rooms_web_native.register(b, check_step, archive_install, browser_application);

    const rooms_client_exe = common.glowcapExecutable(b, lib_mod, target, optimize, "glowcap-rooms-client", "apps/rooms/clients/zig/client.zig");
    rooms_client_exe.root_module.addImport("demo_rooms_cli", ctx.demo_rooms_cli_mod);
    rooms_client_exe.root_module.addImport("demo_usage", ctx.demo_usage_mod);
    // The default rooms client is TCP-only: a build option flips the iroh dial
    // path off so the `@import("iroh")` inside it is comptime-elided and the
    // hermetic build never pulls the Rust sidecar into its graph.
    const rooms_tcp_opts = b.addOptions();
    rooms_tcp_opts.addOption(bool, "iroh_enabled", false);
    rooms_client_exe.root_module.addOptions("rooms_client_build_options", rooms_tcp_opts);

    // The Zig front's own contracts, beside the Rust, Python, and Racket ones
    // under `rooms-terminal-client-test` below: watcher validation, the null
    // count and offer in a publication record, and the membership-ended notice.
    // All are pure over wire arguments and need no room server, so they ride
    // `check` as well.
    const rooms_client_tests = b.addTest(.{ .name = "rooms-client-test", .root_module = rooms_client_exe.root_module });
    const run_rooms_client_tests = execution.addZigTest(b, rooms_client_tests, .{ .deterministic = 30 });
    check_step.dependOn(&run_rooms_client_tests.step);

    // Run that same TCP client by hand against a room you started yourself, so
    // the README's Zig one-liner is a real command: `zig build rooms-client --
    // <locator> <room> <nick> <line> [roster]` forwards everything after `--` to the
    // client. It is a convenience runner for the artifact the demo already
    // builds, not part of any gate.
    const rooms_client_run = execution.addArtifact(b, .{ .deterministic = 30 }, rooms_client_exe);
    rooms_client_run.addPassthruArgs();
    const rooms_client_step = b.step("rooms-client", "Run the native Zig rooms chat client (one-shot); pass `-- <locator> <room> <nick> <line> [roster]`");
    rooms_client_step.dependOn(&rooms_client_run.step);

    // The demo Zig clients only run under demo steps that need deno (and
    // cargo for the iroh variant), so an API or module-wiring change can rot
    // them unnoticed by every hermetic gate. Compile them under `check`,
    // compile-only, the same rot guard the bench-langs executables carry.
    check_step.dependOn(&rooms_client_exe.step);

    const rooms_server_test_step = rooms_tests.register(.{
        .b = b,
        .check_step = check_step,
        .ocapn_install = ctx.ocapn_install,
        .host_install = ctx.host_install,
        .driver_install = ctx.driver_install,
        .tcp_install = ctx.tcp_install,
        .relay_install = ctx.relay_install,
        .archive_install = archive_install,
        .wasm_install = browser_application,
    });

    // The rooms cross-language application demo: one Zig-built native client plus
    // the Rust server and the Deno/Python/Racket/Rust clients, all joining one
    // capability-secure chat room over TCP. It needs `deno` for the orchestrator and the Zig client, always built here. Python,
    // Racket, and Rust each join only when their runtime is on PATH; the demo
    // builds the Rust client itself when `cargo` is present and reports any
    // language it skipped rather than failing. So it is a sibling step, not part of
    // the hermetic gate. The native-server compatibility tests cover attached-room
    // cleanup, then the orchestrator (`apps/rooms/demos/demo.ts`) starts the
    // server, runs whichever clients are available, and asserts the all-to-all
    // broadcast among them.
    const rooms_demo = common.addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{"env"});
    rooms_demo.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
    rooms_demo.step.dependOn(archive_install);
    rooms_demo.addArgs(&.{
        "deno",                     "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "--allow-env",
        "apps/rooms/demos/demo.ts",
    });
    rooms_demo.addArtifactArg(rooms_client_exe); // the Zig client's built path
    if (ctx.pin_port) |p| rooms_demo.addArg(b.fmt("--port={d}", .{p}));
    if (ctx.attach) rooms_demo.addArg("--attach");
    rooms_demo.step.dependOn(rooms_server_test_step);
    const rooms_demo_step = b.step("demo-rooms", "Run the cross-language rooms chat demo (needs deno; joins python3/racket/cargo clients when present)");
    rooms_demo_step.dependOn(&rooms_demo.step);

    // The small language fronts own behavior that their compilers cannot prove:
    // malformed watch callbacks fail closed, a membership-ended notice ends the
    // line stream, and slow readers cannot grow an unread queue forever. Keep
    // those contracts runnable without starting a room server, one native test
    // runner per language; the Zig one also rides `check` above.
    const terminal_client_test_step = b.step("rooms-terminal-client-test", "Run the Zig, Rust, Python, and Racket terminal-client contract tests (needs cargo + python3 + racket)");
    terminal_client_test_step.dependOn(&run_rooms_client_tests.step);
    const rust_client_test = common.addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{
        "cargo", "test", "--manifest-path", "apps/rooms/clients/rust/Cargo.toml", "--no-default-features",
    });
    const python_client_test = common.addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{
        "python3", "-m", "unittest", "discover", "-s", "apps/rooms/clients/python", "-p", "test_room_client.py",
    });
    const racket_client_test = common.addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{
        "raco", "test", "apps/rooms/clients/racket/room-client.rkt",
    });
    terminal_client_test_step.dependOn(&rust_client_test.step);
    terminal_client_test_step.dependOn(&python_client_test.step);
    terminal_client_test_step.dependOn(&racket_client_test.step);

    // The standardized transport proof uses the same Rooms directory and client
    // behaviors with three independently owned native loops. The harness starts
    // Tor explicitly; each product edge installs the onion provider package into
    // an otherwise transport-empty generic driver.
    const rooms_onion_demo = common.addInstalledSystemRun(b, .real_internet, &.{"env"});
    rooms_onion_demo.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
    rooms_onion_demo.addArgs(&.{ "bash", "apps/rooms/demos/run-onion.sh" });
    rooms_onion_demo.step.dependOn(archive_install);
    const rooms_onion_demo_step = b.step("demo-rooms-onion", "Run the Rooms application over real Tor with one onion service and two independent peers (needs deno + tor + network)");
    rooms_onion_demo_step.dependOn(&rooms_onion_demo.step);

    // Four native direct-message scenarios over TCP, one table because their
    // wiring is identical and only the scenario differs.
    //
    //   demo-rooms-dm — the rooms-app face of the gifter handoff
    //     (`deno-gifter-handoff`): a rendezvous room introduces two members
    //     who then DM directly, room out of the path. Exercises the real rooms
    //     directory's `register`/`introduce` and a member's exported `dm`
    //     object, the three proofs (live cap, brand-new inbound, no relay)
    //     asserted. Its iroh sibling is `demo-rooms-dm-iroh`.
    //   demo-rooms-dm-reply — the bidirectional completion of the
    //     introduction: a host-wide giftable reads its caller's connection
    //     through `currentSession()` and replies over it, so a non-listening
    //     caller (a browser peer) receives the reply on the connection it
    //     opened. Direct 2-party TCP, no room, no dial-back.
    //   demo-rooms-dm-back — the redeemed-introduction back-channel: a member
    //     answers a non-listening sender across a three-party handoff. The
    //     sender hosts a reply inbox on the redeemed direct connection
    //     (`Session.sendRedeeming`), so the member replies over it without
    //     dialing the sender. The native, Chromium-free sibling of
    //     `rooms-web-dm`, driving the same `room_client.ts` DirectMessage.
    //   rooms-dm-reredeem — redeem attribution is deterministic:
    //     `Session.sendRedeeming` resolves the direct exporter session from
    //     the reply's own route, so a re-redeem to an already-dialed exporter
    //     resolves the same live session even though it runs no new dial —
    //     the case a capture-window heuristic would surface as null
    //     (ADR-0088).
    const dm_demos = [_]DmDemo{
        .{ .step_name = "demo-rooms-dm", .description = "Rooms direct-message-by-introduction over TCP: a room introduces two members who then DM directly, room out of the path (needs deno)", .source = "apps/rooms/demos/dm_demo.ts" },
        .{ .step_name = "demo-rooms-dm-reply", .description = "A host-wide giftable replies to its caller over the arriving connection via currentSession(), so a non-listening peer receives the reply (needs deno)", .source = "apps/rooms/demos/dm_reply_demo.ts" },
        .{ .step_name = "demo-rooms-dm-back", .description = "A member replies to a non-listening sender across a redeemed introduction: the sender hosts a reply inbox on the redeemed direct connection (sendRedeeming), room out of the path (needs deno)", .source = "apps/rooms/demos/dm_back_demo.ts" },
        .{ .step_name = "rooms-dm-reredeem", .description = "sendRedeeming resolves the direct exporter from the reply's route: a re-redeem to an already-dialed exporter resolves the same live session with no second dial (needs deno)", .source = "apps/rooms/test/dm_reredeem_test.ts", .gated = true },
    };
    for (dm_demos) |demo| {
        const run = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{"env"});
        run.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
        run.addArgs(&.{ "deno", "run", "--allow-run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-env", demo.source });
        run.step.dependOn(archive_install);
        const cache = execution.addSystemCommand(b, .build_tool, &.{ "deno", "cache", demo.source });
        run.step.dependOn(&cache.step);
        run.step.dependOn(b.getInstallStep());
        b.step(demo.step_name, demo.description).dependOn(&run.step);
        if (demo.gated) check_step.dependOn(&run.step);
    }

    // The same rooms demo over iroh's encrypted QUIC. The Zig client is built as
    // a second, iroh-enabled artifact that links the Rust sidecar (so it can dial
    // an ocapn:// URI), and the cross-language clients reach the room through the
    // iroh C ABI companion library. Needs cargo (sidecar + iroh ABI) and deno, so
    // it is a sibling of `check`, like `iroh-interop`.
    const rooms_client_iroh_mod = common.irohDriverModule(b, target, optimize, lib_mod, ctx.iroh_resident_mod, "apps/rooms/clients/zig/client.zig");
    const rooms_iroh_opts = b.addOptions();
    rooms_iroh_opts.addOption(bool, "iroh_enabled", true);
    rooms_client_iroh_mod.addOptions("rooms_client_build_options", rooms_iroh_opts);
    rooms_client_iroh_mod.addImport("demo_rooms_cli", ctx.demo_rooms_cli_mod);
    rooms_client_iroh_mod.addImport("demo_usage", ctx.demo_usage_mod);
    common.linkIrohSidecar(b, rooms_client_iroh_mod, target, ctx.iroh_sidecar_archive);
    const rooms_client_iroh_exe = b.addExecutable(.{ .name = "glowcap-rooms-client-iroh", .root_module = rooms_client_iroh_mod });
    // The client's `dialIroh` path lives behind `iroh_enabled`, so the TCP client
    // that rides `check` (above) compiles it out. Ride a second, cargo-free
    // compile guard on `check` with the flag on — externs stay unresolved — so a
    // core-API change through the iroh resident cannot break this consumer unseen,
    // the same split as `rooms-peer-shim-check`.
    const rooms_client_iroh_check_mod = common.irohDriverModule(b, target, optimize, lib_mod, ctx.iroh_resident_mod, "apps/rooms/clients/zig/client.zig");
    rooms_client_iroh_check_mod.addOptions("rooms_client_build_options", rooms_iroh_opts);
    rooms_client_iroh_check_mod.addImport("demo_rooms_cli", ctx.demo_rooms_cli_mod);
    rooms_client_iroh_check_mod.addImport("demo_usage", ctx.demo_usage_mod);
    check_step.dependOn(&b.addObject(.{ .name = "rooms-client-iroh-check", .root_module = rooms_client_iroh_check_mod }).step);

    const rooms_demo_iroh = common.addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{"env"});
    rooms_demo_iroh.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
    rooms_demo_iroh.step.dependOn(archive_install);
    rooms_demo_iroh.addArgs(&.{
        "deno",                     "run", "-A", "--unstable-ffi",
        "apps/rooms/demos/demo.ts",
    });
    rooms_demo_iroh.addArtifactArg(rooms_client_iroh_exe); // the iroh-enabled Zig client
    rooms_demo_iroh.addArg("--transport=iroh");
    if (ctx.pin_port) |p| rooms_demo_iroh.addArg(b.fmt("--port={d}", .{p}));
    // The cross-language clients and native server dial iroh through the iroh
    // C ABI companion library, so it must be built and installed first.
    rooms_demo_iroh.step.dependOn(ctx.iroh_abi_step);
    const rooms_demo_iroh_step = b.step("demo-rooms-iroh", "Run the cross-language rooms demo over iroh's encrypted QUIC (needs cargo + deno; joins python3/racket/cargo clients when present)");
    rooms_demo_iroh_step.dependOn(&rooms_demo_iroh.step);

    // The iroh sibling of `demo-rooms-dm`: a room introduces two members who then
    // DM directly, every hop over iroh's encrypted QUIC. The cross-endpoint proof
    // that a gift can name an exporter reachable only by a dial hint (an iroh
    // endpoint's direct addresses) and a recipient redeems it by dialing that
    // endpoint directly, no discovery service and no relay. Three iroh endpoints:
    // two client hosts plus the native server process. Needs cargo (the sidecar +
    // iroh ABI companion) and deno, so it is a sibling of `check`.
    const rooms_dm_iroh = common.addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{"env"});
    rooms_dm_iroh.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
    rooms_dm_iroh.step.dependOn(archive_install);
    rooms_dm_iroh.addArgs(&.{
        "deno",                             "run", "-A", "--unstable-ffi",
        "apps/rooms/demos/dm_demo_iroh.ts",
    });
    rooms_dm_iroh.step.dependOn(ctx.iroh_abi_step);
    b.step("demo-rooms-dm-iroh", "Rooms DM-by-introduction over iroh: a room introduces two members who then DM directly over encrypted QUIC, room out of the path (needs cargo + deno)")
        .dependOn(&rooms_dm_iroh.step);

    // The discovery sibling of `demo-rooms-dm-iroh`: the same three-party handoff,
    // but every hop reaches its partner by node id ALONE over real n0 discovery
    // (relays + DNS/pkarr): the give names the exporter by id with no
    // direct-address hints, and the recipient resolves that id. Like
    // `iroh-reachability`, it touches public n0 infrastructure and pkarr-propagation
    // timing, so it is opt-in and never part of `check`; the offline, deterministic
    // proof of the same handoff is `demo-rooms-dm-iroh` (the Direct posture).
    const rooms_dm_iroh_discovery = common.addInstalledSystemRun(b, .real_internet, &.{"env"});
    rooms_dm_iroh_discovery.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
    rooms_dm_iroh_discovery.step.dependOn(archive_install);
    rooms_dm_iroh_discovery.addArgs(&.{
        "deno",                                       "run", "-A", "--unstable-ffi",
        "apps/rooms/demos/dm_demo_iroh_discovery.ts",
    });
    rooms_dm_iroh_discovery.step.dependOn(ctx.iroh_abi_step);
    b.step("demo-rooms-dm-iroh-discovery", "Opt-in: rooms DM-by-introduction over iroh by node id ALONE through n0 discovery (relays + DNS/pkarr), no direct-address hints (needs cargo + deno + internet)")
        .dependOn(&rooms_dm_iroh_discovery.step);

    // The native front serves browser assets and relays opaque byte streams.
    // Deno is used only to compile the browser when its source graph changes.
    // TCP is explicit; the ordinary rooms-web launch below selects iroh.
    const rooms_web = common.addRootedSystemCommand(b, .service, &.{"env"});
    rooms_web.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
    rooms_web.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-web" } }, .{ .make_absolute = true });
    rooms_web.addArg("--transport=tcp");
    if (ctx.pin_port) |p| rooms_web.addArg(b.fmt("{d}", .{p}));
    if (ctx.diagnostics) rooms_web.addArg("--diagnostics");
    if (ctx.admin_listeners) rooms_web.addArg("--admin-listeners");
    if (ctx.operator) rooms_web.addArg("--operator");
    if (ctx.peering) rooms_web.addArg("--peering");
    if (ctx.viz) rooms_web.addArg("--viz");
    rooms_web.addPassthruArgs();
    // The front opens these dynamic archives and launches the installed Rust
    // server. The browser also loads the Wasm Host module; serving a stale
    // one ships a layout descriptor the freshly bundled page refuses.
    rooms_web.has_side_effects = true;
    rooms_web.step.dependOn(ctx.ocapn_install);
    rooms_web.step.dependOn(ctx.host_install);
    rooms_web.step.dependOn(ctx.driver_install);
    rooms_web.step.dependOn(ctx.tcp_install);
    rooms_web.step.dependOn(ctx.relay_install);
    rooms_web.step.dependOn(browser_application);
    rooms_web.step.dependOn(archive_install);
    const rooms_web_step = b.step("rooms-web-tcp", "Serve the rooms browser UI over cleartext TCP (public rooms + direct messages by introduction); open the printed URL. Prefer rooms-web, which serves the same UI over encrypted QUIC (needs deno). `-Ddiagnostics` / `-Dadmin-listeners` / `-Doperator` / `-Dpeering` / `-Dviz` mint the operations capabilities; `-- --bind=<host> --announce-host=<host>` expose the cleartext room on a LAN");
    rooms_web_step.dependOn(&rooms_web.step);

    // The same browser UI with the room directory published as a Tor onion
    // service (`--transport=onion` on rooms-web). The supervisor starts a
    // private Tor unless GLOWCAP_ONION_SOCKS / GLOWCAP_ONION_CONTROL already
    // name one, so it wants `tor` on PATH; browser tabs still reach the room
    // through /relay, which carries an admitted onion target to the service's
    // local forward endpoint.
    const rooms_web_onion = common.addInstalledSystemRun(b, .real_internet, &.{"env"});
    rooms_web_onion.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
    rooms_web_onion.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-web" } }, .{ .make_absolute = true });
    rooms_web_onion.addArg("--transport=onion");
    if (ctx.pin_port) |p| rooms_web_onion.addArg(b.fmt("{d}", .{p}));
    if (ctx.diagnostics) rooms_web_onion.addArg("--diagnostics");
    if (ctx.admin_listeners) rooms_web_onion.addArg("--admin-listeners");
    if (ctx.operator) rooms_web_onion.addArg("--operator");
    if (ctx.peering) rooms_web_onion.addArg("--peering");
    if (ctx.viz) rooms_web_onion.addArg("--viz");
    rooms_web_onion.addPassthruArgs();
    // Same stale-wasm guard as `rooms-web-tcp` above.
    rooms_web_onion.step.dependOn(browser_application);
    rooms_web_onion.step.dependOn(archive_install);
    const rooms_web_onion_step = b.step("rooms-web-onion", "Serve the rooms browser UI with the room directory published as a Tor onion service; open the printed URL (needs deno + tor). `-Ddiagnostics` / `-Dadmin-listeners` / `-Doperator` / `-Dpeering` / `-Dviz` mint the operations capabilities");
    rooms_web_onion_step.dependOn(&rooms_web_onion.step);

    // The rooms browser-peer proof: a wasm browser peer drives the real
    // room directory through
    // the native web front's `/relay` byte pipe, no dlopen and no JSON bridge in its process.
    // Needs the wasm module and the native archives (rooms-web and the room server
    // are native children). A sibling step (needs deno), not folded into the
    // Zig-hermetic `check`.
    const rooms_web_relay_peer = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{"env"});
    rooms_web_relay_peer.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
    rooms_web_relay_peer.addArgs(&.{
        "deno",                                   "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "--allow-env",
        "apps/rooms/test/web/relay_peer_test.ts",
    });
    rooms_web_relay_peer.setCwd(b.path("."));
    rooms_web_relay_peer.has_side_effects = true;
    rooms_web_relay_peer.step.dependOn(browser_application);
    rooms_web_relay_peer.step.dependOn(archive_install);
    rooms_web_relay_peer.step.dependOn(b.getInstallStep());
    const rooms_web_relay_peer_step = b.step("rooms-web-relay-peer", "Prove a wasm browser peer drives the room directory through the native web front's /relay byte pipe (needs deno)");
    rooms_web_relay_peer_step.dependOn(&rooms_web_relay_peer.step);

    // The rooms-web proof family: every row is a Deno harness needing the wasm
    // module and the installed archives, plus a real headless Playwright
    // Chromium, and the rows that run the room over iroh add the iroh C ABI
    // companion (cargo). All are siblings of `check`, never members. What each
    // proves:
    //
    //   rooms-web-page — the whole rooms page as a browser peer: load the
    //     served page, join a room through /relay, and round-trip a chat line
    //     over the room capability, no JSON bridge on the page's path.
    //   rooms-web-hosted-session — one browser promotes its local session and
    //     a browser on another Rooms origin follows the capability's signaling
    //     directory to attach to that in-tab Host over WebRTC.
    //   rooms-web-reconnect — the page surviving the loss of its room server.
    //     Which state belongs to a directory session is only observable when
    //     one dies, so this kills the room out from under a joined page: it
    //     must notice, come back, re-enter a listed room by name and a private
    //     room by its retained sturdyref, keep both conversations the dead
    //     session delivered, and reach both rooms over the new one. Runs the
    //     room over iroh so a restart changes its routing hints while preserving
    //     its durable authority.
    //   rooms-web-manager — a managed room's authority across a reload: the
    //     card draws the workspace's saved manager sturdyref, while the acts
    //     beside it need the capability the room took on entry, and re-entering
    //     a name the directory already knows answers with no authority to take.
    //     Presses the act rather than reading the card.
    //   rooms-web-dm — the browser sends a direct message end to end: redeem
    //     a room introduction and dial the member's iroh endpoint through the
    //     relay, delivering off-room.
    //   rooms-web-dm-tabs — two browser tabs cold-dial each other by relay
    //     rendezvous (ADR-0088 capability 5): each registers its durable
    //     identity and advertises a `noise-relay` locator, one redeems the
    //     room's introduction by cold-dialing the other tab-to-tab off-room,
    //     the sealed session opens end to end, and the reply rides back over
    //     the arriving connection. Browser-to-browser on a shared relay, not
    //     a general stranger cold-dial.
    //   rooms-web-dm-viz — the DM conversation appears on the live timeline
    //     (ADR-0104). The room server serves the endpoint; each tab publishes
    //     its OWN trace to it, because the DM is a session the room does not
    //     carry and must not start carrying.
    //   rooms-web-viz-lifecycle — the whole picture over a member's life in a
    //     room, counted after every step through ocapnviz's OWN converter:
    //     joins, a DM, leaving, closing, reopening, going away.
    //   rooms-web-dm-native — a NATIVE peer cold-dials a browser member by
    //     relay rendezvous (ADR-0088, the native-dialer row): the tab
    //     registers its Noise-sealed relay identity, the native Host redeems the room's
    //     introduction and bridges onto the held socket through the relay
    //     provider it composes for rendezvous dials.
    //   rooms-web-dm-noise — two browser tabs use that same sealed rendezvous
    //     in both directions, pinning the managed browser connector as dialer.
    //   rooms-web-dm-webrtc — the live webrtc handoff-redeem proof
    //     (ADR-0089): the give's exporter locator names a bare webrtc
    //     designator, the redeeming host signals through the room directory
    //     by its composed webrtc connector, and the DM crosses the
    //     DataChannel with the room out of the byte path. The live timeline
    //     must name `webrtc`, so relay delivery cannot impersonate this proof.
    //   rooms-web-private — a room nobody can look up: in no list, answering
    //     to no name, taking no name from anybody; its Capabilities control
    //     mints the bearer link another tab uses to enter it.
    //   rooms-web-dm-foreign — starting a direct message from somebody else's
    //     room. A visitor holds two directories, their own page's and the one
    //     they joined, and a `webrtc` locator names a designator and nothing
    //     else — so the redeeming connector has to ask which directory to
    //     signal through, and answering with the first one meant a visitor
    //     could receive direct messages and never start one.
    //   rooms-web-dm-retarget — a nickname is a claim the room grants and
    //     takes back, so a conversation cannot be keyed on one: talk to ada,
    //     ada leaves, somebody else is granted the name, then type into the
    //     conversation you already had.
    //   rooms-web-dm-reopen — closing a direct conversation and reopening it
    //     has to open a second connection, and the second one has to carry.
    //     The sibling proofs ask only whether the message arrived, which a
    //     reopen resolving to the connection the close was supposed to end
    //     also satisfies, so this one watches the live timeline and requires
    //     a session id nobody had seen.
    //   rooms-web-archive — a member selects a durable archive peer, writes a
    //     direct-message history through it, closes the whole browser profile,
    //     then recovers that history through the same authority in a fresh one.
    const web_proofs = [_]WebProof{
        .{ .step_name = "rooms-web-page", .description = "Prove the whole rooms page runs as a browser peer: join a room through /relay and round-trip a line over the room capability (needs deno + a Playwright Chromium)", .source = "apps/rooms/test/web/page_test.ts" },
        .{ .step_name = "rooms-web-shared-session", .description = "Prove two browser profiles attach to one native durable Rooms session peer and mirror its member, selection, draft, lines, and capability vault (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/shared_session_test.ts", .needs_session = true },
        .{ .step_name = "rooms-web-operations-refresh", .description = "Prove Rust operations pagination, latest search, credential removal and reload on the real page (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/operations_refresh_test.ts" },
        .{ .step_name = "rooms-web-hosted-session", .description = "Prove a browser-hosted local session attaches from a different Rooms page through its named iroh signaling directory (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/hosted_session_test.ts", .needs_iroh = true },
        .{ .step_name = "rooms-web-reconnect", .description = "Prove the rooms page survives losing its iroh room server: it refreshes changed routing hints without changing authority, then re-enters a listed room by name and a private room by its retained link (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/reconnect_test.ts", .needs_iroh = true },
        .{ .step_name = "rooms-web-dm", .description = "Prove the rooms page sends a direct message from a real browser: redeem a room introduction and dial the member's iroh endpoint through /relay, delivered off-room (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/dm_test.ts", .needs_iroh = true },
        .{ .step_name = "rooms-web-dm-tabs", .description = "Prove two browser tabs direct-message each other over the default WebRTC path, including closing and reopening the introduced line (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/dm_tabs_test.ts" },
        .{ .step_name = "rooms-web-dm-viz", .description = "Prove a browser-to-browser direct message reaches the live timeline endpoint (ADR-0104): each tab publishes its own trace, the endpoint scopes both producers' session ids apart and carries both ends of the wire, and the room stays off the DM's path (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/dm_viz_test.ts" },
        .{ .step_name = "rooms-web-viz-lifecycle", .description = "Prove the live timeline draws a member's whole life in a room, counted through ocapnviz's own converter: two tabs in a room are three peers and two sessions, a direct message adds a session between the members with the room off its path, leaving the room keeps the session and drops the nickname, closing the direct message closes its session from either end, and a tab going away takes its peer and both its sessions (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/viz_lifecycle_test.ts" },
        .{ .step_name = "rooms-web-dm-native", .description = "Prove a native peer cold-dials a browser member by sealed relay rendezvous (ADR-0088): the tab advertises noise-relay, the native Host redeems through its relay provider, the encrypted session opens native-to-tab off-room, and the reply rides back over the arriving connection (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/dm_native_dial_test.ts" },
        .{ .step_name = "rooms-web-dm-noise", .description = "Prove two browser members direct-message through the room relay over an end-to-end Noise-sealed session: one managed browser connector cold-dials the other's rendezvous and the reply rides back off-room (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/dm_noise_relay_test.ts" },
        .{ .step_name = "rooms-web-dm-webrtc", .description = "Prove two browser members direct-message over a WebRTC DataChannel by redeeming a webrtc handoff give (ADR-0089): the room directory carries only signaling, the live timeline must name webrtc rather than keyed-relay, and the reply rides back over the arriving connection (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/dm_webrtc_test.ts" },
        .{ .step_name = "rooms-web-routes", .description = "Prove the rooms page's address is a shareable place to stand: a cold /room/<name> link arrives named, opening writes its address, back and forward walk it with the view, following an address never moves the rail, a private room's key stays out of it, the join card standing in for a link reflects what that link gates rather than what was used last, and an unanswered address folds back to the front (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/routes_test.ts" },
        .{ .step_name = "rooms-web-manager", .description = "Prove a reloaded workspace re-enters the rooms it manages by name and keeps its saved manager capability usable rather than merely drawn (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/room_manager_test.ts" },
        .{ .step_name = "rooms-web-boot-theme", .description = "Prove the page's first paint is the theme the reader left, guessed from the stored workspace before any application code exists, and that a browser holding no workspace is left to its own preference (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/boot_theme_test.ts" },
        .{ .step_name = "rooms-web-private", .description = "Prove a private room is reachable only by the reference to it: it is in no room list, naming the same thing opens a different room, handing it over is what puts somebody else in it, and declining leaves them out (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/private_room_test.ts" },
        .{ .step_name = "rooms-web-dm-foreign", .description = "Prove a visitor can start a direct message in a room they joined: the tab holds its own page's directory and the one it went to, and the redeem signals through the directory that introduced the member rather than through whichever was opened first (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/dm_foreign_room_test.ts" },
        .{ .step_name = "rooms-web-dm-retarget", .description = "Prove a nickname changing hands cannot move a direct conversation: the member leaves, someone else is granted the name, and a message typed into the original conversation reaches nobody and says why (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/dm_retarget_test.ts" },
        .{ .step_name = "rooms-web-dm-reopen", .description = "Prove reopening a closed direct conversation opens a second connection and that the second one carries: the live timeline must show the first session gone and a session id nobody had seen, and the reply must ride back over it, run once over webrtc and once over noise-relay (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/dm_reopen_test.ts" },
        .{ .step_name = "rooms-web-archive", .description = "Prove a member explicitly selects a durable archive peer, a generation split across two archives reads back as one account under both keepers, and a fresh browser profile recovers direct-message history from the same sturdyref (needs cargo + deno + a Playwright Chromium)", .source = "apps/rooms/test/web/archive_peer_test.ts", .needs_iroh = true, .needs_archive = true },
    };
    for (web_proofs) |proof| {
        const run = execution.addSystemCommand(b, .{ .browser_proof = 330 }, &.{"env"});
        run.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-web" } }, .{ .prefix = "GLOWCAP_ROOMS_WEB_BIN=", .make_absolute = true });
        if (proof.needs_archive) {
            run.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-archive" } }, .{ .prefix = "GLOWCAP_ROOMS_ARCHIVE_TEST_BIN=", .make_absolute = true });
            run.step.dependOn(archive_install);
        }
        if (proof.needs_session) {
            run.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-session" } }, .{ .prefix = "GLOWCAP_ROOMS_SESSION_TEST_BIN=", .make_absolute = true });
            run.step.dependOn(archive_install);
        }
        {
            run.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
            run.step.dependOn(archive_install);
        }
        run.addArgs(&.{ "deno", "run", "--allow-all", proof.source });
        const cache = execution.addSystemCommand(b, .build_tool, &.{ "deno", "cache", proof.source });
        run.step.dependOn(&cache.step);
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        if (proof.needs_browser) run.step.dependOn(ctx.browser_preflight);
        run.step.dependOn(browser_application);
        if (proof.needs_iroh) run.step.dependOn(ctx.iroh_abi_step);
        run.step.dependOn(b.getInstallStep());
        b.step(proof.step_name, proof.description).dependOn(&run.step);
    }

    // The same browser UI with its rooms and its direct-message members over iroh's
    // encrypted QUIC instead of TCP. The bridge announces and dials ocapn:// URIs,
    // so it needs the iroh C ABI companion built first, and thus `cargo`.
    const rooms_web_iroh = common.addInstalledSystemRun(b, .service, &.{"env"});
    rooms_web_iroh.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-server" } }, .{ .prefix = "GLOWCAP_ROOMS_SERVER_BIN=", .make_absolute = true });
    rooms_web_iroh.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-web" } }, .{ .make_absolute = true });
    rooms_web_iroh.addArg("--transport=iroh");
    if (ctx.pin_port) |p| rooms_web_iroh.addArg(b.fmt("{d}", .{p}));
    if (ctx.diagnostics) rooms_web_iroh.addArg("--diagnostics");
    if (ctx.admin_listeners) rooms_web_iroh.addArg("--admin-listeners");
    if (ctx.operator) rooms_web_iroh.addArg("--operator");
    if (ctx.peering) rooms_web_iroh.addArg("--peering");
    if (ctx.viz) rooms_web_iroh.addArg("--viz");
    rooms_web_iroh.addPassthruArgs();
    rooms_web_iroh.step.dependOn(ctx.iroh_abi_step);
    // Same stale-wasm guard as `rooms-web-tcp` above.
    rooms_web_iroh.step.dependOn(browser_application);
    rooms_web_iroh.step.dependOn(archive_install);
    const rooms_web_iroh_step = b.step("rooms-web-iroh", "Serve the rooms browser UI over iroh's encrypted QUIC (public rooms + direct messages by introduction); open the printed URL (needs cargo + deno). `-Ddiagnostics` / `-Dadmin-listeners` / `-Doperator` / `-Dpeering` / `-Dviz` mint the operations capabilities");
    rooms_web_iroh_step.dependOn(&rooms_web_iroh.step);
    // The short name is this step: iroh is the ordinary way to run the UI.
    b.step("rooms-web", "Serve the rooms browser UI over iroh (same as rooms-web-iroh); open the printed URL (needs cargo + deno). `-Ddiagnostics` / `-Dadmin-listeners` / `-Doperator` / `-Dpeering` / `-Dviz` mint the operations capabilities")
        .dependOn(rooms_web_iroh_step);

    // Prepare one complete browser artifact after its native publisher and
    // Wasm host exist. The deployment runs no compiler and mounts no source.
    const rooms_deploy_bundle = execution.addSystemCommand(b, .build_tool, &.{"env"});
    rooms_deploy_bundle.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "rooms-web" } }, .{ .make_absolute = true });
    rooms_deploy_bundle.addArg("--prepare=zig-out/rooms-web");
    rooms_deploy_bundle.setCwd(b.path("."));
    rooms_deploy_bundle.has_side_effects = true;
    rooms_deploy_bundle.step.dependOn(archive_install);
    rooms_deploy_bundle.step.dependOn(browser_application);
    // This marker commits last. The deployment front can therefore distinguish
    // "the UI was bundled" from "every mounted artifact finished for this
    // checkout" without trying to reverse-engineer Zig's build cache.
    const rooms_deploy_finish = execution.addSystemCommand(b, .build_tool, &.{
        "sh", "apps/rooms/web/finish-deployment.sh",
    });
    rooms_deploy_finish.setCwd(b.path("."));
    rooms_deploy_finish.has_side_effects = true;
    rooms_deploy_finish.step.dependOn(b.getInstallStep());
    rooms_deploy_finish.step.dependOn(ctx.iroh_abi_step);
    rooms_deploy_finish.step.dependOn(archive_install);
    rooms_deploy_finish.step.dependOn(&rooms_deploy_bundle.step);
    const rooms_deploy_step = b.step("rooms-deploy-prep", "Build and version everything the rooms deploy container mounts: shared libraries, iroh, the wasm Host, browser UI, and native peers (needs cargo + deno)");
    rooms_deploy_step.dependOn(&rooms_deploy_finish.step);
    return archive_install;
}
