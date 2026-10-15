//! Live proof of the WebRTC provider inside the generic C driver.
//!
//! The offerer dials through the driver and the answerer listens through it.
//! `glowcap_driver_dial` names the answerer's key and the offerer's provider
//! runs the dial (ADR-0226). `glowcap_driver_listen` opens the answerer's
//! listener, this program hands the offer in with
//! `glowcap_webrtc_netlayer_provide_offer`, and the answerer's provider runs
//! the accept (ADR-0232). The program only carries the texts the two
//! signaling tables in `signaling.zig` produce. After that
//! `glowcap_driver_step` is the only progress: no WebRTC try-I/O is called.
//! A second dial, to a key nobody answers, is still in flight when the
//! offerer's loop is released, which cancels it and fires its `done`.

const std = @import("std");

const cs = @import("c_abi_shared");
const ch = @import("c_abi_host");
const cd = @import("c_abi_driver");
const cw = @import("c_abi_net_transport_webrtc");
const signaling = @import("signaling.zig");

const transport = "webrtc";
const frame_cap: usize = 4096;

fn expectOk(rc: i32) !void {
    if (rc == cs.GLOWCAP_OK) return;
    var message: [512]u8 = undefined;
    const driver_len = cd.glowcap_driver_last_error(&message, message.len);
    if (driver_len != 0) {
        std.debug.print("webrtc-driver-provider: driver error {d}: {s}\n", .{
            rc,
            message[0..@min(driver_len, message.len - 1)],
        });
    }
    const host_len = ch.glowcap_host_last_error(&message, message.len);
    if (host_len != 0) {
        std.debug.print("webrtc-driver-provider: host error {d}: {s}\n", .{
            rc,
            message[0..@min(host_len, message.len - 1)],
        });
    }
    const webrtc_len = cw.glowcap_webrtc_last_error(&message, message.len);
    if (webrtc_len != 0) {
        std.debug.print("webrtc-driver-provider: webrtc error {d}: {s}\n", .{
            rc,
            message[0..@min(webrtc_len, message.len - 1)],
        });
    }
    return error.CAbiCallFailed;
}

fn reportCleanup(label: []const u8, rc: i32) void {
    expectOk(rc) catch |err| std.log.err("{s}: {s}", .{ label, @errorName(err) });
}

fn reportDriverFailure(label: []const u8, rc: i32, failure: cd.GlowcapDriverFailure) void {
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

fn addDriverProvider(loop: ?*cd.GlowcapDriverLoop, provider: *const cs.GlowcapTransportProvider) !void {
    var failure = cd.GlowcapDriverFailure.init();
    const rc = cd.glowcap_driver_add_provider(loop, provider, &failure);
    reportDriverFailure("WebRTC driver provider installation failed", rc, failure);
    try expectOk(rc);
}

fn releaseDriver(label: []const u8, loop: ?*cd.GlowcapDriverLoop) void {
    var failure = cd.GlowcapDriverFailure.init();
    const rc = cd.glowcap_driver_release(loop, &failure);
    reportDriverFailure(label, rc, failure);
    reportCleanup(label, rc);
}

fn expectStep(rc: i32) !void {
    if (rc == cs.GLOWCAP_OK or rc == cs.GLOWCAP_ERR_WOULD_BLOCK) return;
    try expectOk(rc);
}

fn newHostLoop(seed: *const [64]u8, advertise: bool) !?*cd.GlowcapDriverLoop {
    var host: ?*ch.GlowcapHost = null;
    try expectOk(ch.glowcap_host_new(
        seed,
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
    errdefer reportCleanup("WebRTC host rollback failed", ch.glowcap_host_release(host));

    if (advertise) {
        try expectOk(ch.glowcap_host_ensure_advertised_locator(host, transport, transport.len));
    }

    var loop: ?*cd.GlowcapDriverLoop = null;
    const options: cd.GlowcapDriverOptions = .{
        .abi_version = cd.GLOWCAP_DRIVER_OPTIONS_ABI_VERSION,
        .struct_size = @sizeOf(cd.GlowcapDriverOptions),
        .wire_buffer_bytes = 16 << 10,
        .max_pending_opens = 256,
        .handshake_ms = 15_000,
        .listener_setup_ms = 15_000,
        .settle_ms = 15_000,
        .busy_poll_ns = 0,
    };
    try expectOk(cd.glowcap_driver_take_host(host, &options, &loop));
    host = null;
    return loop;
}

fn newNetlayer(table: cw.GlowcapWebrtcSignaling) !?*cw.GlowcapWebrtcNetlayer {
    const config = cw.GlowcapWebrtcConfig{
        .ice_servers = null,
        .ice_server_count = 0,
        .include_loopback_candidates = 1,
        .worker_threads = 0,
        .signaling = table,
    };
    var netlayer: ?*cw.GlowcapWebrtcNetlayer = null;
    try expectOk(cw.glowcap_webrtc_netlayer_new(&config, &netlayer));
    return netlayer;
}

fn locatorView(designator: *const [64]u8) cs.GlowcapLocatorView {
    return .{
        .abi_version = cs.GLOWCAP_LOCATOR_VIEW_ABI_VERSION,
        .struct_size = @sizeOf(cs.GlowcapLocatorView),
        .transport = transport.ptr,
        .transport_len = transport.len,
        .designator = designator,
        .designator_len = designator.len,
        .hints = null,
        .hint_count = 0,
        .hint_wire_form = cs.GLOWCAP_HINTS_BOOLEAN_FALSE,
    };
}

fn behavior(
    _: ?*anyopaque,
    _: ?*ch.GlowcapHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    _: ?[*]const cs.GlowcapArgument,
    _: usize,
    out_reply: *cs.GlowcapArgument,
) callconv(.c) i32 {
    if (!std.mem.eql(u8, verb[0..verb_len], "describe")) return cs.GLOWCAP_ERR_INVALID_ARGUMENT;
    const reply = "generic driver provider";
    out_reply.* = .{
        .kind = cs.GLOWCAP_ARG_STRING,
        .boolean = 0,
        .integer = 0,
        .float64 = 0,
        .bytes = reply,
        .bytes_len = reply.len,
        .reference = .{ .id = 0 },
        .items = null,
        .items_len = 0,
    };
    return cs.GLOWCAP_OK;
}

fn requireAuthenticatedTransport(session: ?*ch.GlowcapHostSession, expected_designator: []const u8) !void {
    var identity: ch.GlowcapPartnerIdentity = undefined;
    try expectOk(ch.glowcap_host_session_partner_identity(session, &identity));
    if (identity.provenance != ch.GLOWCAP_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT) {
        return error.UnauthenticatedTransportProvenance;
    }
    const designator = identity.designator orelse return error.MissingAuthenticatedDesignator;
    if (!std.mem.eql(u8, designator[0..identity.designator_len], expected_designator)) {
        return error.WrongAuthenticatedDesignator;
    }
}

const LoopState = struct {
    loop: ?*cd.GlowcapDriverLoop,
    operation_id: u64,
    /// The dial nobody answers, whose only acceptable outcome is a failure.
    absent_operation_id: u64 = 0,
    absent_failed: bool = false,
    /// The answerer's listener, whose accept brings the session.
    listener_id: u64 = 0,
    listener_ready: bool = false,
    session: ?*ch.GlowcapHostSession = null,
    failed: bool = false,
    fetch_vow: u64 = 0,
    fetch_settled: bool = false,
};

fn drainEvents(state: *LoopState) !void {
    var event: cd.GlowcapDriverEvent = undefined;
    while (true) {
        const rc = cd.glowcap_driver_next_event(state.loop, &event);
        if (rc == cs.GLOWCAP_ERR_WOULD_BLOCK) return;
        try expectOk(rc);
        switch (event.kind) {
            cd.GLOWCAP_DRIVER_EVENT_OPENED => {
                if (event.operation_id == state.operation_id) {
                    state.session = event.session;
                } else return error.UnexpectedOpenOperationId;
            },
            cd.GLOWCAP_DRIVER_EVENT_OPEN_FAILED => {
                if (event.operation_id == state.operation_id) {
                    state.failed = true;
                } else if (event.operation_id == state.absent_operation_id) {
                    state.absent_failed = true;
                } else return error.UnexpectedFailureOperationId;
            },
            cd.GLOWCAP_DRIVER_EVENT_COMPLETION => {
                if (event.action.kind == ch.GLOWCAP_HOST_ACTION_SETTLE and
                    event.action.ticket == state.fetch_vow)
                {
                    if (event.action.value.kind != cs.GLOWCAP_ARG_REFERENCE or event.action.value.reference.id == 0) {
                        return error.FetchDidNotReturnCapability;
                    }
                    state.fetch_settled = true;
                } else if (event.action.kind == ch.GLOWCAP_HOST_ACTION_FAIL) {
                    return error.FetchFailed;
                } else if (event.action.kind != ch.GLOWCAP_HOST_ACTION_SETTLE) {
                    return error.UnexpectedCompletionKind;
                }
            },
            cd.GLOWCAP_DRIVER_EVENT_SESSION_CLOSED => return error.SessionClosed,
            cd.GLOWCAP_DRIVER_EVENT_LISTENER_READY => {
                if (event.listener_id != state.listener_id) return error.UnexpectedListenerId;
                state.listener_ready = true;
            },
            cd.GLOWCAP_DRIVER_EVENT_LISTENER_FAILED => return error.ListenerFailed,
            cd.GLOWCAP_DRIVER_EVENT_ACCEPTED => {
                if (state.listener_id == 0 or event.listener_id != state.listener_id) return error.UnexpectedAcceptedEvent;
                if (state.session != null) return error.AcceptedTwice;
                state.session = event.session;
            },
            else => return error.UnexpectedDriverEvent,
        }
    }
}

pub fn main(init: std.process.Init) !void {
    _ = init;

    const offerer_seed: [64]u8 = @splat(0x51);
    const answerer_seed: [64]u8 = @splat(0x52);
    const absent_seed: [64]u8 = @splat(0x53);
    var offerer_designator: [64]u8 = undefined;
    var answerer_designator: [64]u8 = undefined;
    var absent_designator: [64]u8 = undefined;
    try expectOk(ch.glowcap_host_designator_from_seed(&offerer_seed, 32, &offerer_designator, offerer_designator.len));
    try expectOk(ch.glowcap_host_designator_from_seed(&answerer_seed, 32, &answerer_designator, answerer_designator.len));
    try expectOk(ch.glowcap_host_designator_from_seed(&absent_seed, 32, &absent_designator, absent_designator.len));

    var carrier = signaling.Carrier{ .answerer_designator = &answerer_designator };
    const offerer_netlayer = try newNetlayer(carrier.signaling());
    defer reportCleanup("WebRTC offerer netlayer teardown failed", cw.glowcap_webrtc_netlayer_release(offerer_netlayer));
    var acceptor = signaling.Acceptor{ .offerer_designator = &offerer_designator };
    const answerer_netlayer = try newNetlayer(acceptor.signaling());
    defer reportCleanup("WebRTC answerer netlayer teardown failed", cw.glowcap_webrtc_netlayer_release(answerer_netlayer));

    const offerer_loop = try newHostLoop(&offerer_seed, false);
    var offerer_loop_released = false;
    defer if (!offerer_loop_released) releaseDriver("WebRTC offerer driver teardown failed", offerer_loop);
    const answerer_loop = try newHostLoop(&answerer_seed, true);
    defer releaseDriver("WebRTC answerer driver teardown failed", answerer_loop);

    var offerer_provider: cs.GlowcapTransportProvider = undefined;
    try expectOk(cw.glowcap_webrtc_transport_provider(offerer_netlayer, &offerer_provider));
    try addDriverProvider(offerer_loop, &offerer_provider);
    var answerer_provider: cs.GlowcapTransportProvider = undefined;
    try expectOk(cw.glowcap_webrtc_transport_provider(answerer_netlayer, &answerer_provider));
    try addDriverProvider(answerer_loop, &answerer_provider);

    // The answerer listens like any transport: the listener is named by the
    // Host's own key, and the offer this program hands in names the offerer's.
    var answerer = LoopState{ .loop = answerer_loop, .operation_id = 0 };
    try expectOk(cd.glowcap_driver_listen(answerer_loop, transport, transport.len, null, 0, null, &answerer.listener_id));

    // The offerer dials like any transport. The dialed key is the one the
    // channel is authorized to carry.
    const answerer_locator = locatorView(&answerer_designator);
    var offerer_ticket: u64 = 0;
    try expectOk(cd.glowcap_driver_dial(offerer_loop, &answerer_locator, null, &offerer_ticket));
    const absent_locator = locatorView(&absent_designator);
    var absent_ticket: u64 = 0;
    try expectOk(cd.glowcap_driver_dial(offerer_loop, &absent_locator, null, &absent_ticket));

    var offerer = LoopState{ .loop = offerer_loop, .operation_id = offerer_ticket, .absent_operation_id = absent_ticket };
    var published = false;
    var sessions_served = false;
    var rounds: usize = 0;
    while (!offerer.fetch_settled and rounds < 4_000) : (rounds += 1) {
        try expectStep(cd.glowcap_driver_step(answerer_loop, 1));
        try drainEvents(&answerer);
        // The offer waits until the listener is ready to take it.
        if (answerer.listener_ready) try signaling.carry(&carrier, &acceptor, offerer_netlayer, answerer_netlayer);
        if (answerer.session) |session| {
            try requireAuthenticatedTransport(session, &offerer_designator);
            if (!published) {
                var published_ref: cs.GlowcapReference = undefined;
                try expectOk(ch.glowcap_host_session_publish(
                    session,
                    "greeter",
                    7,
                    behavior,
                    null,
                    null,
                    &published_ref,
                ));
                published = true;
            }
        }

        try expectStep(cd.glowcap_driver_step(offerer_loop, 1));
        try drainEvents(&offerer);
        if (offerer.failed) return error.OffererDialFailed;
        if (offerer.session) |session| {
            try requireAuthenticatedTransport(session, &answerer_designator);
            if (!sessions_served and answerer.session != null) {
                try expectOk(cd.glowcap_driver_session_serve(offerer_loop, offerer.session));
                try expectOk(cd.glowcap_driver_session_serve(answerer_loop, answerer.session));
                sessions_served = true;
            }
            if (sessions_served and offerer.fetch_vow == 0 and published) {
                try expectOk(ch.glowcap_host_session_fetch(session, "greeter", 7, &offerer.fetch_vow));
            }
        }
    }

    if (answerer.session == null) return error.AnswererNeverAccepted;
    if (offerer.session == null) return error.OffererNeverOpened;
    // The accept's exchange ended when the driver claimed the connection.
    if (acceptor.done_count != 1 or acceptor.exchange != null) return error.AcceptExchangeNotEnded;
    if (!published) return error.CapabilityNeverPublished;
    if (offerer.fetch_vow == 0) return error.FetchNeverStarted;
    if (!offerer.fetch_settled) return error.FetchNeverSettled;

    // The answered exchange is over. The absent one still waits for an
    // answer unless the driver's handshake deadline failed it first.
    if (carrier.absent_exchange == null) return error.AbsentOfferNeverSent;
    const ended_before_release: usize = if (offerer.absent_failed) 2 else 1;
    if (carrier.done_count != ended_before_release or carrier.done_exchanges[0] != offerer_ticket) return error.UnexpectedExchangeEnd;

    try expectOk(cd.glowcap_driver_session_release(offerer_loop, offerer.session));
    offerer.session = null;
    try expectOk(cd.glowcap_driver_session_release(answerer_loop, answerer.session));
    answerer.session = null;

    // Releasing the loop cancels the dial in flight, and the provider says so.
    offerer_loop_released = true;
    releaseDriver("WebRTC offerer driver teardown failed", offerer_loop);
    if (carrier.done_count != 2 or carrier.done_exchanges[1] != carrier.absent_exchange.?) return error.PendingDialNotCancelled;
    std.debug.print("webrtc-driver-provider: OK - the generic driver dials and listens through the WebRTC provider, owns both byte paths and authenticated fetch provenance, and cancels a dial it releases\n", .{});
}
