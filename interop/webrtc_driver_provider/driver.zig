//! Live proof of the generic externally-established endpoint seam.
//!
//! WebRTC signaling belongs to the WebRTC C archive. Once both DataChannels
//! are open, the generic driver owns the sessions and all CapTP bytes. This
//! proof deliberately does not call WebRTC try-I/O after adoption: the only
//! post-adoption progress is `pancake_driver_step`.

const std = @import("std");

const cs = @import("c_abi_shared");
const ch = @import("c_abi_host");
const cd = @import("c_abi_driver");
const cw = @import("c_abi_net_transport_webrtc");

const transport = "webrtc";
const frame_cap: usize = 4096;
const sdp_cap: usize = 64 * 1024;
const candidate_cap: usize = 16 * 1024;

fn expectOk(rc: i32) !void {
    if (rc == cs.PANCAKE_OK) return;
    var message: [512]u8 = undefined;
    const driver_len = cd.pancake_driver_last_error(&message, message.len);
    if (driver_len != 0) {
        std.debug.print("webrtc-driver-provider: driver error {d}: {s}\n", .{
            rc,
            message[0..@min(driver_len, message.len - 1)],
        });
    }
    const host_len = ch.pancake_host_last_error(&message, message.len);
    if (host_len != 0) {
        std.debug.print("webrtc-driver-provider: host error {d}: {s}\n", .{
            rc,
            message[0..@min(host_len, message.len - 1)],
        });
    }
    const webrtc_len = cw.pancake_webrtc_last_error(&message, message.len);
    if (webrtc_len != 0) {
        std.debug.print("webrtc-driver-provider: webrtc error {d}: {s}\n", .{
            rc,
            message[0..@min(webrtc_len, message.len - 1)],
        });
    }
    return error.CAbiCallFailed;
}

fn expectWouldBlock(rc: i32) !void {
    if (rc == cs.PANCAKE_ERR_WOULD_BLOCK) return;
    try expectOk(rc);
}

fn expectStep(rc: i32) !void {
    if (rc == cs.PANCAKE_OK or rc == cs.PANCAKE_ERR_WOULD_BLOCK) return;
    try expectOk(rc);
}

fn newHostLoop(seed: *const [64]u8, advertise: bool) !?*cd.PancakeDriverLoop {
    var host: ?*ch.PancakeHost = null;
    try expectOk(ch.pancake_host_new(
        seed,
        seed.len,
        frame_cap,
        1,
        cs.PANCAKE_CODEC_SYRUP,
        cs.PANCAKE_CAPTP_V1_0,
        cs.PANCAKE_FEATURE_FULL,
        0,
        &host,
    ));
    errdefer _ = ch.pancake_host_release(host);

    if (advertise) {
        try expectOk(ch.pancake_host_ensure_advertised_locator(host, transport, transport.len));
    }

    var loop: ?*cd.PancakeDriverLoop = null;
    const options: cd.PancakeDriverOptions = .{
        .abi_version = cd.PANCAKE_DRIVER_OPTIONS_ABI_VERSION,
        .struct_size = @sizeOf(cd.PancakeDriverOptions),
        .wire_buffer_bytes = 16 << 10,
        .max_pending_opens = 256,
        .handshake_ms = 15_000,
        .listener_setup_ms = 15_000,
        .settle_ms = 15_000,
    };
    try expectOk(cd.pancake_driver_take_host(host, &options, &loop));
    host = null;
    return loop;
}

fn newNetlayer() !?*cw.PancakeWebrtcNetlayer {
    const config = cw.PancakeWebrtcConfig{
        .ice_servers = null,
        .ice_servers_len = 0,
        .include_loopback_candidates = 1,
        .worker_threads = 0,
    };
    var netlayer: ?*cw.PancakeWebrtcNetlayer = null;
    try expectOk(cw.pancake_webrtc_netlayer_new(&config, &netlayer));
    return netlayer;
}

fn readinessFd(netlayer: ?*cw.PancakeWebrtcNetlayer) !i32 {
    const fd = cw.pancake_webrtc_netlayer_readiness_fd(netlayer);
    if (fd < 0) {
        try expectOk(fd);
    }
    return fd;
}

fn drainReady(netlayer: ?*cw.PancakeWebrtcNetlayer, peer: ?*cw.PancakeWebrtcPeer) !u32 {
    var events: [32]cw.PancakeWebrtcReadyEvent = undefined;
    var count: usize = 0;
    try expectOk(cw.pancake_webrtc_netlayer_drain_ready(netlayer, &events, events.len, &count));

    const expected_subject = cw.pancake_webrtc_peer_id(peer);
    var flags: u32 = 0;
    for (events[0..count]) |event| {
        if (event.subject != expected_subject) return error.UnexpectedReadySubject;
        flags |= event.events;
    }
    return flags;
}

fn drainCandidates(
    from: ?*cw.PancakeWebrtcPeer,
    to: ?*cw.PancakeWebrtcPeer,
    candidate: []u8,
) !void {
    while (true) {
        var candidate_len: usize = 0;
        const rc = cw.pancake_webrtc_peer_next_local_candidate(from, candidate.ptr, candidate.len, &candidate_len);
        if (rc == cs.PANCAKE_ERR_WOULD_BLOCK) return;
        try expectOk(rc);
        try expectOk(cw.pancake_webrtc_peer_add_remote_candidate(to, candidate.ptr, candidate_len));
    }
}

fn waitForOpen(
    offerer_netlayer: ?*cw.PancakeWebrtcNetlayer,
    offerer: ?*cw.PancakeWebrtcPeer,
    answerer_netlayer: ?*cw.PancakeWebrtcNetlayer,
    answerer: ?*cw.PancakeWebrtcPeer,
) !void {
    var offer: [sdp_cap]u8 = undefined;
    var answer: [sdp_cap]u8 = undefined;
    var candidate: [candidate_cap]u8 = undefined;
    var offer_len: usize = 0;
    var answer_len: usize = 0;

    try expectOk(cw.pancake_webrtc_peer_create_offer(offerer, &offer, offer.len, &offer_len));
    try expectOk(cw.pancake_webrtc_peer_set_remote_offer(answerer, &offer, offer_len));
    try expectOk(cw.pancake_webrtc_peer_create_answer(answerer, &answer, answer.len, &answer_len));
    try expectOk(cw.pancake_webrtc_peer_set_remote_answer(offerer, &answer, answer_len));

    var fds = [_]std.posix.pollfd{
        .{ .fd = try readinessFd(offerer_netlayer), .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = try readinessFd(answerer_netlayer), .events = std.posix.POLL.IN, .revents = 0 },
    };

    var round: usize = 0;
    while (round < 600) : (round += 1) {
        _ = try drainReady(offerer_netlayer, offerer);
        _ = try drainReady(answerer_netlayer, answerer);
        try drainCandidates(offerer, answerer, &candidate);
        try drainCandidates(answerer, offerer, &candidate);

        const offerer_open = cw.pancake_webrtc_peer_is_open(offerer);
        const answerer_open = cw.pancake_webrtc_peer_is_open(answerer);
        if (offerer_open == cs.PANCAKE_OK and answerer_open == cs.PANCAKE_OK) return;
        if (offerer_open == cs.PANCAKE_ERR_CLOSED or answerer_open == cs.PANCAKE_ERR_CLOSED) {
            return error.WebRtcChannelClosed;
        }
        try expectWouldBlock(offerer_open);
        try expectWouldBlock(answerer_open);

        fds[0].revents = 0;
        fds[1].revents = 0;
        _ = try std.posix.poll(&fds, 50);
    }
    return error.WebRtcOpenTimedOut;
}

fn behavior(
    _: ?*anyopaque,
    _: ?*ch.PancakeHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    _: ?[*]const cs.PancakeArgument,
    _: usize,
    out_reply: *cs.PancakeArgument,
) callconv(.c) i32 {
    if (!std.mem.eql(u8, verb[0..verb_len], "describe")) return cs.PANCAKE_ERR_INVALID_ARGUMENT;
    const reply = "generic driver provider";
    out_reply.* = .{
        .kind = cs.PANCAKE_ARG_STRING,
        .boolean = 0,
        .integer = 0,
        .float64 = 0,
        .bytes = reply,
        .bytes_len = reply.len,
        .reference = .{ .id = 0 },
        .items = null,
        .items_len = 0,
    };
    return cs.PANCAKE_OK;
}

fn requireAuthenticatedTransport(session: ?*ch.PancakeHostSession, expected_designator: []const u8) !void {
    var identity: ch.PancakePartnerIdentity = undefined;
    try expectOk(ch.pancake_host_session_partner_identity(session, &identity));
    if (identity.provenance != ch.PANCAKE_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT) {
        return error.UnauthenticatedTransportProvenance;
    }
    const designator = identity.designator orelse return error.MissingAuthenticatedDesignator;
    if (!std.mem.eql(u8, designator[0..identity.designator_len], expected_designator)) {
        return error.WrongAuthenticatedDesignator;
    }
}

const LoopState = struct {
    loop: ?*cd.PancakeDriverLoop,
    operation_id: u64,
    session: ?*ch.PancakeHostSession = null,
    failed: bool = false,
    fetch_vow: u64 = 0,
    fetch_settled: bool = false,
};

fn drainEvents(state: *LoopState) !void {
    var event: cd.PancakeDriverEvent = undefined;
    while (true) {
        const rc = cd.pancake_driver_next_event(state.loop, &event);
        if (rc == cs.PANCAKE_ERR_WOULD_BLOCK) return;
        try expectOk(rc);
        switch (event.kind) {
            cd.PANCAKE_DRIVER_EVENT_OPENED => {
                if (event.operation_id == state.operation_id) {
                    state.session = event.session;
                } else return error.UnexpectedOpenOperationId;
            },
            cd.PANCAKE_DRIVER_EVENT_OPEN_FAILED => {
                if (event.operation_id == state.operation_id) {
                    state.failed = true;
                } else return error.UnexpectedFailureOperationId;
            },
            cd.PANCAKE_DRIVER_EVENT_COMPLETION => {
                if (event.action.kind == ch.PANCAKE_HOST_ACTION_SETTLE and
                    event.action.ticket == state.fetch_vow)
                {
                    if (event.action.value.kind != cs.PANCAKE_ARG_REFERENCE or event.action.value.reference.id == 0) {
                        return error.FetchDidNotReturnCapability;
                    }
                    state.fetch_settled = true;
                } else if (event.action.kind == ch.PANCAKE_HOST_ACTION_FAIL) {
                    return error.FetchFailed;
                } else if (event.action.kind != ch.PANCAKE_HOST_ACTION_SETTLE) {
                    return error.UnexpectedCompletionKind;
                }
            },
            cd.PANCAKE_DRIVER_EVENT_SESSION_CLOSED => return error.SessionClosed,
            cd.PANCAKE_DRIVER_EVENT_ACCEPTED => return error.UnexpectedAcceptedEvent,
            else => return error.UnexpectedDriverEvent,
        }
    }
}

pub fn main(init: std.process.Init) !void {
    _ = init;

    const offerer_seed: [64]u8 = @splat(0x51);
    const answerer_seed: [64]u8 = @splat(0x52);
    var offerer_designator: [64]u8 = undefined;
    var answerer_designator: [64]u8 = undefined;
    try expectOk(ch.pancake_host_designator_from_seed(&offerer_seed, 32, &offerer_designator, offerer_designator.len));
    try expectOk(ch.pancake_host_designator_from_seed(&answerer_seed, 32, &answerer_designator, answerer_designator.len));

    const offerer_netlayer = try newNetlayer();
    defer cw.pancake_webrtc_netlayer_release(offerer_netlayer);
    const answerer_netlayer = try newNetlayer();
    defer cw.pancake_webrtc_netlayer_release(answerer_netlayer);

    var offerer_peer: ?*cw.PancakeWebrtcPeer = null;
    try expectOk(cw.pancake_webrtc_peer_new(offerer_netlayer, 1, &offerer_peer));
    defer _ = cw.pancake_webrtc_peer_release(offerer_peer);
    var answerer_peer: ?*cw.PancakeWebrtcPeer = null;
    try expectOk(cw.pancake_webrtc_peer_new(answerer_netlayer, 0, &answerer_peer));
    defer _ = cw.pancake_webrtc_peer_release(answerer_peer);

    // The signaling authority supplies these durable keys before either peer
    // can open. The provider later exposes exactly this authorized key as
    // transport provenance; no identity is inferred from SDP or a locator.
    try expectOk(cw.pancake_webrtc_peer_authorize_remote(offerer_peer, &answerer_designator, answerer_designator.len));
    try expectOk(cw.pancake_webrtc_peer_authorize_remote(answerer_peer, &offerer_designator, offerer_designator.len));
    try waitForOpen(offerer_netlayer, offerer_peer, answerer_netlayer, answerer_peer);

    const offerer_loop = try newHostLoop(&offerer_seed, false);
    defer _ = cd.pancake_driver_release(offerer_loop);
    const answerer_loop = try newHostLoop(&answerer_seed, true);
    defer _ = cd.pancake_driver_release(answerer_loop);

    var offerer_provider: cs.PancakeTransportProvider = undefined;
    try expectOk(cw.pancake_webrtc_transport_provider(offerer_netlayer, &offerer_provider));
    try expectOk(cd.pancake_driver_add_provider(offerer_loop, &offerer_provider));
    var answerer_provider: cs.PancakeTransportProvider = undefined;
    try expectOk(cw.pancake_webrtc_transport_provider(answerer_netlayer, &answerer_provider));
    try expectOk(cd.pancake_driver_add_provider(answerer_loop, &answerer_provider));

    var offerer_ticket: u64 = 0;
    try expectOk(cd.pancake_driver_adopt_external(
        offerer_loop,
        transport,
        transport.len,
        @intCast(cw.pancake_webrtc_peer_id(offerer_peer)),
        cd.PANCAKE_DRIVER_ADOPT_DIALED,
        &offerer_ticket,
    ));
    var answerer_ticket: u64 = 0;
    try expectOk(cd.pancake_driver_adopt_external(
        answerer_loop,
        transport,
        transport.len,
        @intCast(cw.pancake_webrtc_peer_id(answerer_peer)),
        cd.PANCAKE_DRIVER_ADOPT_ACCEPTED,
        &answerer_ticket,
    ));

    var offerer = LoopState{ .loop = offerer_loop, .operation_id = offerer_ticket };
    var answerer = LoopState{ .loop = answerer_loop, .operation_id = answerer_ticket };
    var published = false;
    var rounds: usize = 0;
    while (!offerer.fetch_settled and rounds < 4_000) : (rounds += 1) {
        try expectStep(cd.pancake_driver_step(answerer_loop, 1));
        try drainEvents(&answerer);
        if (answerer.failed) return error.AnswererAdoptionFailed;
        if (answerer.session) |session| {
            try requireAuthenticatedTransport(session, &offerer_designator);
            if (!published) {
                var published_ref: cs.PancakeReference = undefined;
                try expectOk(ch.pancake_host_session_publish(
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

        try expectStep(cd.pancake_driver_step(offerer_loop, 1));
        try drainEvents(&offerer);
        if (offerer.failed) return error.OffererAdoptionFailed;
        if (offerer.session) |session| {
            try requireAuthenticatedTransport(session, &answerer_designator);
            if (offerer.fetch_vow == 0 and published) {
                try expectOk(ch.pancake_host_session_fetch(session, "greeter", 7, &offerer.fetch_vow));
            }
        }
    }

    if (answerer.session == null) return error.AnswererNeverOpened;
    if (offerer.session == null) return error.OffererNeverOpened;
    if (!published) return error.CapabilityNeverPublished;
    if (offerer.fetch_vow == 0) return error.FetchNeverStarted;
    if (!offerer.fetch_settled) return error.FetchNeverSettled;

    try expectOk(cd.pancake_driver_session_release(offerer_loop, offerer.session));
    offerer.session = null;
    try expectOk(cd.pancake_driver_session_release(answerer_loop, answerer.session));
    answerer.session = null;
    std.debug.print("webrtc-driver-provider: OK - generic driver adoption owns both WebRTC byte paths and authenticated fetch provenance\n", .{});
}
