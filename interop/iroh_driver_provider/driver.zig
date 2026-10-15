//! The driver-provider seam proof (ADR-0112): the driver archive
//! (`libglowcap_driver`) carries a whole CapTP conversation over a real iroh
//! endpoint it reaches only through the C multiplexed-transport table. Two iroh
//! archives fill the same table and two driver loops adopt it: the server
//! listens and accepts through the generic listener operations while the
//! client dials through the generic connect operations. No binding-side iroh
//! accept loop exists. Every QUIC byte crosses try_read/try_write and each
//! channel-proved key crosses conn_remote_key before the CapTP hello.

const std = @import("std");

const glowcap = @import("glowcap");
const cs = @import("c_abi_shared");
const cd = @import("c_abi_host");
const cdrv = @import("c_abi_driver");
const ci = @import("c_abi_net_transport_iroh");

const model = glowcap.ocapn.model;

const frame_cap = 4096;

fn expectOk(rc: i32) !void {
    if (rc == cs.GLOWCAP_OK) return;
    var message: [256]u8 = undefined;
    const driver_len = cdrv.glowcap_driver_last_error(&message, message.len);
    if (driver_len > 0) {
        std.debug.print("iroh-driver-provider: driver error {d}: {s}\n", .{ rc, message[0..@min(driver_len, message.len)] });
    }
    const iroh_len = ci.glowcap_iroh_last_error(&message, message.len);
    if (iroh_len > 0) {
        std.debug.print("iroh-driver-provider: iroh error {d}: {s}\n", .{ rc, message[0..@min(iroh_len, message.len)] });
    }
    return error.CAbiCallFailed;
}

fn reportCleanup(label: []const u8, rc: i32) void {
    expectOk(rc) catch |err| std.log.err("{s}: {s}", .{ label, @errorName(err) });
}

fn reportDriverFailure(label: []const u8, rc: i32, failure: cdrv.GlowcapDriverFailure) void {
    if (rc == cs.GLOWCAP_OK) return;
    const primary = if (failure.primary_name) |name| name[0..failure.primary_name_len] else "missing failure";
    std.log.err("{s}: {s} ({d})", .{ label, primary, rc });
    if (failure.secondary_name) |name| {
        std.log.err("{s}: cleanup: {s} ({d} consequences)", .{
            label,
            name[0..failure.secondary_name_len],
            failure.secondary_count,
        });
    }
}

fn addDriverProvider(loop: ?*cdrv.GlowcapDriverLoop, provider: *const cs.GlowcapTransportProvider) !void {
    var failure = cdrv.GlowcapDriverFailure.init();
    const rc = cdrv.glowcap_driver_add_provider(loop, provider, &failure);
    reportDriverFailure("iroh driver provider installation failed", rc, failure);
    try expectOk(rc);
}

fn releaseDriver(label: []const u8, loop: ?*cdrv.GlowcapDriverLoop) void {
    var failure = cdrv.GlowcapDriverFailure.init();
    const rc = cdrv.glowcap_driver_release(loop, &failure);
    reportDriverFailure(label, rc, failure);
    reportCleanup(label, rc);
}

fn expectStep(rc: i32) !void {
    if (rc == cs.GLOWCAP_OK or rc == cs.GLOWCAP_ERR_WOULD_BLOCK) return;
    return expectOk(rc);
}

/// What the loop's drained events amounted to, scalar facts only, because a
/// COMPLETION's views die at the next `glowcap_driver_next_event`.
const Drained = struct {
    dialed_session: ?*cd.GlowcapHostSession = null,
    dialed_operation_id: u64 = 0,
    dial_failed: bool = false,
    accepted_session: ?*cd.GlowcapHostSession = null,
    accepted_listener: u64 = 0,
    listener_ready: bool = false,
    ready_listener: u64 = 0,
    settle_ticket: u64 = 0,
    fail_ticket: u64 = 0,
};

fn drainEvents(loop: ?*cdrv.GlowcapDriverLoop, into: *Drained) !void {
    var event: cdrv.GlowcapDriverEvent = undefined;
    while (true) {
        const rc = cdrv.glowcap_driver_next_event(loop, &event);
        if (rc == cs.GLOWCAP_ERR_WOULD_BLOCK) return;
        try expectOk(rc);
        switch (event.kind) {
            cdrv.GLOWCAP_DRIVER_EVENT_OPENED => {
                into.dialed_session = event.session;
                into.dialed_operation_id = event.operation_id;
            },
            cdrv.GLOWCAP_DRIVER_EVENT_OPEN_FAILED => {
                into.dial_failed = true;
                if (event.primary_name) |name| {
                    std.debug.print("iroh-driver-provider: dial failed: {s}\n", .{name[0..event.primary_name_len]});
                }
            },
            cdrv.GLOWCAP_DRIVER_EVENT_ACCEPTED => {
                into.accepted_session = event.session;
                into.accepted_listener = event.listener_id;
            },
            cdrv.GLOWCAP_DRIVER_EVENT_LISTENER_READY => {
                into.listener_ready = true;
                into.ready_listener = event.listener_id;
            },
            cdrv.GLOWCAP_DRIVER_EVENT_SESSION_CLOSED => {},
            cdrv.GLOWCAP_DRIVER_EVENT_COMPLETION => switch (event.action.kind) {
                cd.GLOWCAP_HOST_ACTION_SETTLE => into.settle_ticket = event.action.ticket,
                cd.GLOWCAP_HOST_ACTION_FAIL => {
                    into.fail_ticket = event.action.ticket;
                    if (event.action.message) |msg| {
                        std.debug.print("iroh-driver-provider: vow failed: {s}\n", .{msg[0..event.action.message_len]});
                    }
                },
                else => return error.UnexpectedCompletionKind,
            },
            else => return error.UnexpectedEventKind,
        }
    }
}

fn readListenerLocator(loop: ?*cdrv.GlowcapDriverLoop, listener: u64) !model.PeerLocator {
    var view: cdrv.GlowcapLocatorView = undefined;
    try expectOk(cdrv.glowcap_driver_listener_locator(loop, listener, &view));
    return cs.locator_adapter.cloneView(std.heap.page_allocator, &view);
}

fn unusedBehavior(
    _: ?*anyopaque,
    _: ?*cd.GlowcapHostTurn,
    _: [*]const u8,
    _: usize,
    _: ?[*]const cs.GlowcapArgument,
    _: usize,
    _: *cs.GlowcapArgument,
) callconv(.c) i32 {
    return cs.GLOWCAP_ERR_INVALID_ARGUMENT;
}

fn newNetlayer(seed: *const [32]u8) !?*ci.GlowcapIrohNetlayer {
    var netlayer: ?*ci.GlowcapIrohNetlayer = null;
    const config = ci.GlowcapIrohConfig{
        .reachability = ci.GLOWCAP_IROH_REACH_LOCAL_DISCOVERY,
        .connect_timeout_ms = 15_000,
        .idle_timeout_ms = 0,
        .worker_threads = 0,
    };
    try expectOk(ci.glowcap_iroh_netlayer_new(seed, seed.len, &config, &netlayer, null, 0, null));
    return netlayer;
}

fn newLoop(seed_byte: u8) !?*cdrv.GlowcapDriverLoop {
    var seed: [64]u8 = undefined;
    @memset(seed[0..32], seed_byte);
    @memset(seed[32..], seed_byte ^ 0xa5);
    var host: ?*cd.GlowcapHost = null;
    try expectOk(cd.glowcap_host_new(
        &seed,
        seed.len,
        frame_cap,
        1,
        cs.GLOWCAP_CODEC_SYRUP,
        cs.GLOWCAP_CAPTP_V1_0,
        cs.GLOWCAP_FEATURE_FULL,
        0,
        1,
        &host,
    ));
    errdefer reportCleanup("iroh driver-provider host rollback failed", cd.glowcap_host_release(host));
    var loop: ?*cdrv.GlowcapDriverLoop = null;
    const options: cdrv.GlowcapDriverOptions = .{
        .abi_version = cdrv.GLOWCAP_DRIVER_OPTIONS_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.GlowcapDriverOptions),
        .wire_buffer_bytes = 16 << 10,
        .max_pending_opens = 256,
        .handshake_ms = 15_000,
        .listener_setup_ms = 15_000,
        .settle_ms = 15_000,
        .busy_poll_ns = 0,
    };
    try expectOk(cdrv.glowcap_driver_take_host(
        host,
        &options,
        &loop,
    ));
    return loop;
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    const server_seed: [32]u8 = @splat(0x51);
    const client_seed: [32]u8 = @splat(0x52);
    const server_netlayer = try newNetlayer(&server_seed);
    defer reportCleanup("iroh server netlayer teardown failed", ci.glowcap_iroh_netlayer_release(server_netlayer, null, 0, null));
    const client_netlayer = try newNetlayer(&client_seed);
    defer reportCleanup("iroh client netlayer teardown failed", ci.glowcap_iroh_netlayer_release(client_netlayer, null, 0, null));

    const server_loop = try newLoop(0x51);
    defer releaseDriver("iroh server driver teardown failed", server_loop);
    const client_loop = try newLoop(0x52);
    defer releaseDriver("iroh client driver teardown failed", client_loop);

    var server_provider: cs.GlowcapTransportProvider = undefined;
    try expectOk(ci.glowcap_iroh_transport_provider(server_netlayer, &server_provider));
    try addDriverProvider(server_loop, &server_provider);
    var client_provider: cs.GlowcapTransportProvider = undefined;
    try expectOk(ci.glowcap_iroh_transport_provider(client_netlayer, &client_provider));
    try addDriverProvider(client_loop, &client_provider);

    var listener: u64 = 0;
    try expectOk(cdrv.glowcap_driver_listen(server_loop, model.transport.iroh.ptr, model.transport.iroh.len, null, 0, null, &listener));
    var server_seen = Drained{};
    var listener_rounds: usize = 0;
    while (!server_seen.listener_ready and listener_rounds < 4000) : (listener_rounds += 1) {
        try expectStep(cdrv.glowcap_driver_step(server_loop, 1));
        try drainEvents(server_loop, &server_seen);
    }
    if (!server_seen.listener_ready or server_seen.ready_listener != listener)
        return error.ListenerNeverReady;
    try expectOk(cdrv.glowcap_driver_listener_select(server_loop, listener));
    const locator = try readListenerLocator(server_loop, listener);
    defer model.freePeerLocator(std.heap.page_allocator, locator);
    std.debug.print("iroh-driver-provider: generic listener published {s}\n", .{locator.designator});

    var operation_id: u64 = 0;
    var hint_views: [8]cs.GlowcapLocatorHintView = undefined;
    var projection = try cs.locator_adapter.Projection.init(std.heap.page_allocator, locator, &hint_views);
    defer projection.deinit(std.heap.page_allocator);
    try expectOk(cdrv.glowcap_driver_dial(client_loop, &projection.view, null, &operation_id));

    var client_seen = Drained{};
    var greeter_published = false;
    var sessions_served = false;
    var fetch_vow: u64 = 0;
    var rounds: usize = 0;
    while (client_seen.settle_ticket == 0 and rounds < 4000) : (rounds += 1) {
        try expectStep(cdrv.glowcap_driver_step(server_loop, 1));
        try drainEvents(server_loop, &server_seen);
        if (server_seen.accepted_session != null and server_seen.accepted_listener != listener)
            return error.ListenerMismatch;
        if (server_seen.accepted_session) |session| {
            if (!greeter_published) {
                var published: cs.GlowcapReference = undefined;
                try expectOk(cd.glowcap_host_session_publish(session, "greeter", 7, unusedBehavior, null, null, &published));
                greeter_published = true;
            }
        }

        try expectStep(cdrv.glowcap_driver_step(client_loop, 1));
        try drainEvents(client_loop, &client_seen);
        if (client_seen.dial_failed) return error.DialFailed;
        if (client_seen.fail_ticket != 0) return error.FetchFailed;
        if (!sessions_served and client_seen.dialed_session != null and server_seen.accepted_session != null) {
            try expectOk(cdrv.glowcap_driver_session_serve(client_loop, client_seen.dialed_session));
            try expectOk(cdrv.glowcap_driver_session_serve(server_loop, server_seen.accepted_session));
            sessions_served = true;
        }
        if (sessions_served and fetch_vow == 0) {
            if (client_seen.dialed_operation_id != operation_id) return error.OperationIdMismatch;
            try expectOk(cd.glowcap_host_session_fetch(client_seen.dialed_session, "greeter", 7, &fetch_vow));
        }
    }
    if (server_seen.accepted_session == null) return error.AcceptNeverCompleted;
    if (client_seen.dialed_session == null) return error.DialNeverCompleted;
    if (client_seen.settle_ticket != fetch_vow) return error.FetchNeverSettled;

    try expectOk(cdrv.glowcap_driver_session_release(client_loop, client_seen.dialed_session));
    try expectOk(cdrv.glowcap_driver_session_release(server_loop, server_seen.accepted_session));
    var listener_close_failure = cdrv.GlowcapDriverFailure.init();
    try expectOk(cdrv.glowcap_driver_listener_close(server_loop, listener, &listener_close_failure));
    std.debug.print("iroh-driver-provider: OK — generic dial and listen both crossed the multiplexed-transport table\n", .{});
}
