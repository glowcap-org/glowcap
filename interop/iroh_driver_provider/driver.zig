//! The driver-provider seam proof (ADR-0112): the driver archive
//! (`libpancake_driver`) carries a whole CapTP conversation over a real iroh
//! endpoint it reaches only through the C multiplexed-transport table. Two iroh
//! archives fill the same table and two driver loops adopt it: the server
//! listens and accepts through the generic listener operations while the
//! client dials through the generic connect operations. No binding-side iroh
//! accept loop exists. Every QUIC byte crosses try_read/try_write and each
//! channel-proved key crosses conn_remote_key before the CapTP hello.

const std = @import("std");

const pancake = @import("pancake");
const cs = @import("c_abi_shared");
const cd = @import("c_abi_host");
const cdrv = @import("c_abi_driver");
const ci = @import("c_abi_net_transport_iroh");

const model = pancake.ocapn.model;

const frame_cap = 4096;

fn expectOk(rc: i32) !void {
    if (rc == cs.PANCAKE_OK) return;
    var message: [256]u8 = undefined;
    const driver_len = cdrv.pancake_driver_last_error(&message, message.len);
    if (driver_len > 0) {
        std.debug.print("iroh-driver-provider: driver error {d}: {s}\n", .{ rc, message[0..@min(driver_len, message.len)] });
    }
    const iroh_len = ci.pancake_iroh_last_error(&message, message.len);
    if (iroh_len > 0) {
        std.debug.print("iroh-driver-provider: iroh error {d}: {s}\n", .{ rc, message[0..@min(iroh_len, message.len)] });
    }
    return error.CAbiCallFailed;
}

fn expectStep(rc: i32) !void {
    if (rc == cs.PANCAKE_OK or rc == cs.PANCAKE_ERR_WOULD_BLOCK) return;
    return expectOk(rc);
}

/// What the loop's drained events amounted to; scalar facts only, because a
/// COMPLETION's views die at the next `pancake_driver_next_event`.
const Drained = struct {
    dialed_session: ?*cd.PancakeHostSession = null,
    dialed_ticket: u64 = 0,
    dial_failed: bool = false,
    accepted_session: ?*cd.PancakeHostSession = null,
    accepted_listener: u64 = 0,
    settle_ticket: u64 = 0,
    fail_ticket: u64 = 0,
};

fn drainEvents(loop: ?*cdrv.PancakeDriverLoop, into: *Drained) !void {
    var event: cdrv.PancakeDriverEvent = undefined;
    while (true) {
        const rc = cdrv.pancake_driver_next_event(loop, &event);
        if (rc == cs.PANCAKE_ERR_WOULD_BLOCK) return;
        try expectOk(rc);
        switch (event.kind) {
            cdrv.PANCAKE_DRIVER_EVENT_OPENED => {
                into.dialed_session = event.session;
                into.dialed_ticket = event.ticket;
            },
            cdrv.PANCAKE_DRIVER_EVENT_OPEN_FAILED => {
                into.dial_failed = true;
                if (event.message) |msg| {
                    std.debug.print("iroh-driver-provider: dial failed: {s}\n", .{msg[0..event.message_len]});
                }
            },
            cdrv.PANCAKE_DRIVER_EVENT_ACCEPTED => {
                into.accepted_session = event.session;
                into.accepted_listener = event.ticket;
            },
            cdrv.PANCAKE_DRIVER_EVENT_SESSION_CLOSED => {},
            cdrv.PANCAKE_DRIVER_EVENT_COMPLETION => switch (event.action.kind) {
                cd.PANCAKE_HOST_ACTION_SETTLE => into.settle_ticket = event.action.ticket,
                cd.PANCAKE_HOST_ACTION_FAIL => {
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

fn readListenerLocator(loop: ?*cdrv.PancakeDriverLoop, listener: u64) !model.PeerLocator {
    var view: cdrv.PancakeLocatorView = undefined;
    try expectOk(cdrv.pancake_driver_listener_locator(loop, listener, &view));
    return cs.locator_adapter.cloneView(std.heap.page_allocator, &view);
}

fn unusedBehavior(
    _: ?*anyopaque,
    _: ?*cd.PancakeHostTurn,
    _: [*]const u8,
    _: usize,
    _: ?[*]const cs.PancakeArgument,
    _: usize,
    _: *cs.PancakeArgument,
) callconv(.c) i32 {
    return cs.PANCAKE_ERR_INVALID_ARGUMENT;
}

fn newNetlayer(seed: *const [32]u8) !?*ci.PancakeIrohNetlayer {
    var netlayer: ?*ci.PancakeIrohNetlayer = null;
    const config = ci.PancakeIrohConfig{
        .reachability = ci.PANCAKE_IROH_REACH_LOCAL_DISCOVERY,
        .connect_timeout_ms = 15_000,
        .idle_timeout_ms = 0,
        .worker_threads = 0,
    };
    try expectOk(ci.pancake_iroh_netlayer_new(seed, seed.len, &config, &netlayer));
    return netlayer;
}

fn newLoop(seed_byte: u8) !?*cdrv.PancakeDriverLoop {
    var seed: [64]u8 = undefined;
    @memset(seed[0..32], seed_byte);
    @memset(seed[32..], seed_byte ^ 0xa5);
    var host: ?*cd.PancakeHost = null;
    try expectOk(cd.pancake_host_new(
        &seed,
        seed.len,
        frame_cap,
        1,
        cs.PANCAKE_CODEC_SYRUP,
        cs.PANCAKE_CAPTP_V1_0,
        cs.PANCAKE_FEATURE_FULL,
        0,
        &host,
    ));
    errdefer _ = cd.pancake_host_release(host);
    var loop: ?*cdrv.PancakeDriverLoop = null;
    const options: cdrv.PancakeDriverOptions = .{
        .abi_version = cdrv.PANCAKE_DRIVER_OPTIONS_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.PancakeDriverOptions),
        .wire_buffer_bytes = 16 << 10,
        .max_pending_opens = 256,
        .handshake_ms = 15_000,
        .settle_ms = 15_000,
    };
    try expectOk(cdrv.pancake_driver_take_host(
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
    defer ci.pancake_iroh_netlayer_release(server_netlayer);
    const client_netlayer = try newNetlayer(&client_seed);
    defer ci.pancake_iroh_netlayer_release(client_netlayer);

    const server_loop = try newLoop(0x51);
    defer _ = cdrv.pancake_driver_release(server_loop);
    const client_loop = try newLoop(0x52);
    defer _ = cdrv.pancake_driver_release(client_loop);

    var server_provider: cs.PancakeTransportProvider = undefined;
    try expectOk(ci.pancake_iroh_transport_provider(server_netlayer, &server_provider));
    try expectOk(cdrv.pancake_driver_add_provider(server_loop, &server_provider));
    var client_provider: cs.PancakeTransportProvider = undefined;
    try expectOk(ci.pancake_iroh_transport_provider(client_netlayer, &client_provider));
    try expectOk(cdrv.pancake_driver_add_provider(client_loop, &client_provider));

    var listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(server_loop, model.transport.iroh.ptr, model.transport.iroh.len, null, 0, &listener));
    const locator = try readListenerLocator(server_loop, listener);
    defer model.freePeerLocator(std.heap.page_allocator, locator);
    std.debug.print("iroh-driver-provider: generic listener published {s}\n", .{locator.designator});

    var ticket: u64 = 0;
    var hint_views: [8]cs.PancakeLocatorHintView = undefined;
    var projection = try cs.locator_adapter.Projection.init(std.heap.page_allocator, locator, &hint_views);
    defer projection.deinit(std.heap.page_allocator);
    try expectOk(cdrv.pancake_driver_dial(client_loop, &projection.view, &ticket));

    var server_seen = Drained{};
    var client_seen = Drained{};
    var greeter_published = false;
    var fetch_vow: u64 = 0;
    var rounds: usize = 0;
    while (client_seen.settle_ticket == 0 and rounds < 4000) : (rounds += 1) {
        try expectStep(cdrv.pancake_driver_step(server_loop, 1));
        try drainEvents(server_loop, &server_seen);
        if (server_seen.accepted_session != null and server_seen.accepted_listener != listener)
            return error.ListenerMismatch;
        if (server_seen.accepted_session) |session| {
            if (!greeter_published) {
                var published: cs.PancakeReference = undefined;
                try expectOk(cd.pancake_host_session_publish(session, "greeter", 7, unusedBehavior, null, null, &published));
                greeter_published = true;
            }
        }

        try expectStep(cdrv.pancake_driver_step(client_loop, 1));
        try drainEvents(client_loop, &client_seen);
        if (client_seen.dial_failed) return error.DialFailed;
        if (client_seen.fail_ticket != 0) return error.FetchFailed;
        if (client_seen.dialed_session != null and fetch_vow == 0 and server_seen.accepted_session != null) {
            if (client_seen.dialed_ticket != ticket) return error.TicketMismatch;
            try expectOk(cd.pancake_host_session_fetch(client_seen.dialed_session, "greeter", 7, &fetch_vow));
        }
    }
    if (server_seen.accepted_session == null) return error.AcceptNeverCompleted;
    if (client_seen.dialed_session == null) return error.DialNeverCompleted;
    if (client_seen.settle_ticket != fetch_vow) return error.FetchNeverSettled;

    try expectOk(cdrv.pancake_driver_session_release(client_loop, client_seen.dialed_session));
    try expectOk(cdrv.pancake_driver_session_release(server_loop, server_seen.accepted_session));
    try expectOk(cdrv.pancake_driver_listener_close(server_loop, listener));
    std.debug.print("iroh-driver-provider: OK — generic dial and listen both crossed the multiplexed-transport table\n", .{});
}
