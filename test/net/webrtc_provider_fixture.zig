//! The shared fixture for the managed WebRTC exchange tests through the C
//! provider table, against the scripted sidecar in `webrtc_sidecar_stub.zig`:
//! a netlayer, its provider table, a far key, and the record of what the
//! application's signaling callbacks saw. `webrtc_provider_dial_test.zig` and
//! `webrtc_provider_accept_test.zig` build on it.

const std = @import("std");
const c = @import("c_abi_shared");
const foundation = @import("foundation");
const webrtc = @import("webrtc");
const webrtc_archive = @import("c_abi_net_transport_webrtc");
const stub = @import("webrtc_sidecar_stub.zig");

pub const designator_len = foundation.crypto.PeerKey.designator_len;

/// What the application's callbacks saw, written by the C callbacks below.
pub const Signals = struct {
    offer_exchange: ?u64 = null,
    offer_designator: [designator_len]u8 = undefined,
    offer_introducer: [designator_len]u8 = undefined,
    offer_introducer_len: ?usize = null,
    offer_sdp_len: usize = 0,
    answer_exchange: ?u64 = null,
    answer_designator: [designator_len]u8 = undefined,
    answer_sdp_len: usize = 0,
    candidate_exchange: ?u64 = null,
    candidate_len: usize = 0,
    done_exchange: ?u64 = null,
    done_calls: usize = 0,
    refuse_offer: bool = false,
    refuse_answer: bool = false,
    refuse_candidate: bool = false,
};

pub var signals: Signals = .{};

pub fn sendOffer(
    _: ?*anyopaque,
    exchange: u64,
    designator: ?[*]const u8,
    designator_count: usize,
    introducer: ?[*]const u8,
    introducer_len: usize,
    sdp: ?[*]const u8,
    sdp_len: usize,
) callconv(.c) i32 {
    signals.offer_exchange = exchange;
    @memcpy(&signals.offer_designator, designator.?[0..designator_count]);
    signals.offer_introducer_len = introducer_len;
    if (introducer) |ptr| @memcpy(signals.offer_introducer[0..introducer_len], ptr[0..introducer_len]);
    signals.offer_sdp_len = sdp_len;
    for (sdp.?[0..sdp_len]) |byte| std.debug.assert(byte == 'o');
    return if (signals.refuse_offer) -1 else 0;
}

pub fn sendAnswer(
    _: ?*anyopaque,
    exchange: u64,
    designator: ?[*]const u8,
    designator_count: usize,
    _: ?[*]const u8,
    sdp_len: usize,
) callconv(.c) i32 {
    signals.answer_exchange = exchange;
    @memcpy(&signals.answer_designator, designator.?[0..designator_count]);
    signals.answer_sdp_len = sdp_len;
    return if (signals.refuse_answer) -1 else 0;
}

pub fn sendCandidate(_: ?*anyopaque, exchange: u64, _: ?[*]const u8, ice_len: usize) callconv(.c) i32 {
    signals.candidate_exchange = exchange;
    signals.candidate_len = ice_len;
    return if (signals.refuse_candidate) -1 else 0;
}

pub fn done(_: ?*anyopaque, exchange: u64) callconv(.c) void {
    signals.done_exchange = exchange;
    signals.done_calls += 1;
}

/// Signaling that can both dial and answer.
pub const full_signaling: webrtc_archive.GlowcapWebrtcSignaling = .{
    .ctx = null,
    .send_offer = sendOffer,
    .send_answer = sendAnswer,
    .send_candidate = sendCandidate,
    .done = done,
};

/// The id the stub gives a fixture's first peer.
pub const stub_peer_id: u64 = 2;

/// A netlayer, its provider table, and a far key, torn down together.
pub const Fixture = struct {
    netlayer: ?*webrtc_archive.GlowcapWebrtcNetlayer = null,
    package: c.GlowcapTransportProvider = undefined,
    designator: [designator_len]u8 = undefined,
    failure: c.GlowcapProviderFailure = c.transport_provider.emptyProviderFailure(),

    pub fn init(signaling: webrtc_archive.GlowcapWebrtcSignaling) !Fixture {
        signals = .{};
        stub.freed_peers = 0;
        stub.next_connection_id = stub_peer_id;
        stub.create_offer_result = 0;
        stub.create_answer_result = 0;
        stub.create_signal_len = 64;
        stub.set_remote_calls = 0;
        stub.set_remote_result = 0;
        stub.add_remote_candidate_calls = 0;
        stub.add_remote_candidate_result = 0;
        stub.driver_event_count = 0;
        var self: Fixture = .{};
        var config: webrtc_archive.GlowcapWebrtcConfig = std.mem.zeroes(webrtc_archive.GlowcapWebrtcConfig);
        config.signaling = signaling;
        try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_netlayer_new(&config, &self.netlayer));
        errdefer _ = webrtc_archive.glowcap_webrtc_netlayer_release(self.netlayer);
        try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_transport_provider(self.netlayer, &self.package));
        self.designator = foundation.crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x4d))).publicKey().toDesignator();
        return self;
    }

    pub fn table(self: *Fixture) *const c.GlowcapMultiplexedTransport {
        for (self.package.entries.?[0..self.package.entry_count]) |entry| {
            const profile = entry.profile.?;
            if (std.mem.eql(u8, profile.transport_name.?[0..profile.transport_name_len], webrtc.transport_name))
                return @ptrCast(@alignCast(entry.implementation.?));
        }
        unreachable;
    }

    pub fn deinit(self: *Fixture) void {
        stub.create_offer_result = -2;
        stub.create_answer_result = -2;
        stub.create_signal_len = 0;
        stub.set_remote_result = -1;
        stub.add_remote_candidate_result = -1;
        stub.open_result = -2;
        stub.driver_event_count = 0;
        std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_netlayer_release(self.netlayer)) catch unreachable;
    }

    /// The `webrtc` locator for `designator`.
    pub fn locatorFor(designator: *const [designator_len]u8) c.GlowcapLocatorView {
        return .{
            .abi_version = c.GLOWCAP_LOCATOR_VIEW_ABI_VERSION,
            .struct_size = @sizeOf(c.GlowcapLocatorView),
            .transport = webrtc.transport_name.ptr,
            .transport_len = webrtc.transport_name.len,
            .designator = designator,
            .designator_len = designator.len,
            .hints = null,
            .hint_count = 0,
            .hint_wire_form = c.GLOWCAP_HINTS_BOOLEAN_FALSE,
        };
    }

    pub fn locator(self: *const Fixture) c.GlowcapLocatorView {
        return locatorFor(&self.designator);
    }

    /// Hand the driver every queued readiness record and return them.
    pub fn drain(self: *Fixture, out: []c.GlowcapMultiplexedReadyEvent) ![]c.GlowcapMultiplexedReadyEvent {
        const t = self.table();
        var count: usize = 0;
        try std.testing.expectEqual(c.GLOWCAP_OK, t.drain_ready.?(t.ctx, out.ptr, out.len, &count, &self.failure));
        return out[0..count];
    }
};

pub fn expectLastErrorContains(message_part: []const u8) !void {
    var message: [256]u8 = undefined;
    const len = @min(webrtc_archive.glowcap_webrtc_last_error(&message, message.len), message.len);
    try std.testing.expect(std.mem.indexOf(u8, message[0..len], message_part) != null);
}
