//! The wired-pair harness the `libpancake_host` suite drives: hosts opened
//! from a seed, dialed/accepted/keyed session pairs, the frame shuttle whose
//! outbound is the partner's inbound, the action pump that answers dials and
//! watches, and the close-option vocabulary. No test lives here; every file in
//! this directory opens with it.

const std = @import("std");

// The shared C-ABI vocabulary (frame/argument types, codes, managed-frame
// release) is reused from the ocapn archive by layout; the byte-fed host
// family is `libpancake_host`.
const c = @import("c_abi");
const cd = @import("c_abi_host");
const pancake = @import("pancake");
const model = pancake.ocapn.model;

pub fn sessionLimitOptions(
    max_frame_bytes: usize,
    queue_cap: usize,
    outbound_high_water_bytes: usize,
    max_retained_sent_answer_bytes: usize,
) cd.PancakeSessionLimitOptions {
    return .{
        .abi_version = cd.PANCAKE_SESSION_LIMIT_OPTIONS_ABI_VERSION,
        .struct_size = @sizeOf(cd.PancakeSessionLimitOptions),
        .max_frame_bytes = max_frame_bytes,
        .queue_cap = queue_cap,
        .outbound_high_water_bytes = outbound_high_water_bytes,
        .max_retained_sent_answer_bytes = max_retained_sent_answer_bytes,
    };
}
const keyed_relay = pancake.net.relay;
const stream_framing = pancake.foundation.stream_framing;
const c_args = @import("../../support/c_abi_args.zig");
pub const argBase = c_args.argBase;
pub const argInt = c_args.argInt;
pub const argStr = c_args.argStr;
pub const argRef = c_args.argRef;

pub const frame_cap: usize = 4096;
pub const key_designator = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

pub const close_cancel: cd.PancakeCloseOptions = .{
    .abi_version = cd.PANCAKE_CLOSE_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cd.PancakeCloseOptions),
    .pending = cd.PANCAKE_PENDING_CANCEL,
    .grace_mode = cd.PANCAKE_CLOSE_GRACE_UNSPECIFIED,
    .grace_ms = 0,
};

pub const close_finish_unbounded: cd.PancakeCloseOptions = .{
    .abi_version = cd.PANCAKE_CLOSE_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cd.PancakeCloseOptions),
    .pending = cd.PANCAKE_PENDING_FINISH,
    .grace_mode = cd.PANCAKE_CLOSE_GRACE_UNBOUNDED,
    .grace_ms = 0,
};

pub fn closeFinish(grace_ms: u32) cd.PancakeCloseOptions {
    return .{
        .abi_version = cd.PANCAKE_CLOSE_OPTIONS_ABI_VERSION,
        .struct_size = @sizeOf(cd.PancakeCloseOptions),
        .pending = cd.PANCAKE_PENDING_FINISH,
        .grace_mode = cd.PANCAKE_CLOSE_GRACE_FINITE,
        .grace_ms = grace_ms,
    };
}

pub fn expectOk(rc: i32) !void {
    try std.testing.expectEqual(c.PANCAKE_OK, rc);
}

/// Durable identity in the first 32 bytes, deterministic session-key root in the
/// rest — the only seed length `pancake_host_new` accepts (ADR-0097).
pub fn hostSeed(durable_byte: u8) [64]u8 {
    var seed: [64]u8 = undefined;
    @memset(seed[0..32], durable_byte);
    @memset(seed[32..], durable_byte ^ 0xa5);
    return seed;
}

pub fn openDialed(
    host: ?*cd.PancakeHost,
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    out_session: ?*?*cd.PancakeHostSession,
) i32 {
    // The locator travels whole as one hintless view; the host retains its
    // own dial default for the transport.
    var no_hints: [0]cd.PancakeLocatorHintView = .{};
    const view = locatorView(.{
        .transport = transport.?[0..transport_len],
        .designator = designator.?[0..designator_len],
        .hints = model.Hints.emptyFalse(),
    }, &no_hints);
    return cd.pancake_host_session_open_dialed_locator(host, &view, out_session);
}

pub fn openAccepted(
    host: ?*cd.PancakeHost,
    transport: ?[*]const u8,
    transport_len: usize,
    out_session: ?*?*cd.PancakeHostSession,
) i32 {
    // Address scheme with no accepted address: the candidate is the
    // unreachable-client placeholder, and every test that cares about the
    // signed locator selects one explicitly first, which the ensure keeps.
    return cd.pancake_host_session_open_accepted(
        host,
        transport,
        transport_len,
        cd.PANCAKE_DESIGNATOR_SCHEME_ADDRESS,
        null,
        0,
        null,
        0,
        out_session,
    );
}

pub fn openAcceptedKeyed(
    host: ?*cd.PancakeHost,
    transport: []const u8,
    designator: []const u8,
    accepted_local_addr: []const u8,
    out_session: ?*?*cd.PancakeHostSession,
) i32 {
    return cd.pancake_host_session_open_accepted(
        host,
        transport.ptr,
        transport.len,
        cd.PANCAKE_DESIGNATOR_SCHEME_KEY,
        designator.ptr,
        designator.len,
        accepted_local_addr.ptr,
        accepted_local_addr.len,
        out_session,
    );
}

pub fn newHostWithProfile(seed_byte: u8, codec: u32, captp_version: u32) !?*cd.PancakeHost {
    return newHostWithFeatures(seed_byte, codec, captp_version, c.PANCAKE_FEATURE_FULL);
}

pub fn newHostWithFeatures(seed_byte: u8, codec: u32, captp_version: u32, features: u32) !?*cd.PancakeHost {
    var host: ?*cd.PancakeHost = null;
    const seed = hostSeed(seed_byte);
    try expectOk(cd.pancake_host_new(&seed, seed.len, frame_cap, 1, codec, captp_version, features, 0, &host));
    return host;
}

pub fn newHostWith(seed_byte: u8, codec: u32) !?*cd.PancakeHost {
    return newHostWithProfile(seed_byte, codec, c.PANCAKE_CAPTP_V1_0);
}

pub fn newHost(seed_byte: u8) !?*cd.PancakeHost {
    return newHostWith(seed_byte, c.PANCAKE_CODEC_SYRUP);
}

pub fn locatorView(locator: model.PeerLocator, hints: []cd.PancakeLocatorHintView) cd.PancakeLocatorView {
    std.debug.assert(hints.len == locator.hints.entries.len);
    for (locator.hints.entries, hints) |entry, *out| {
        out.* = .{
            .name = entry.name.ptr,
            .name_len = entry.name.len,
            .kind = undefined,
            .bytes = null,
            .bytes_len = 0,
            .boolean_value = 0,
            .integer_value = 0,
        };
        switch (entry.value) {
            .string => |value| {
                out.kind = c.PANCAKE_HINT_STRING;
                out.bytes = value.ptr;
                out.bytes_len = value.len;
            },
            .bytes => |value| {
                out.kind = c.PANCAKE_HINT_BYTES;
                out.bytes = value.ptr;
                out.bytes_len = value.len;
            },
            .boolean => |value| {
                out.kind = c.PANCAKE_HINT_BOOLEAN;
                out.boolean_value = @intFromBool(value);
            },
            .integer => |value| {
                out.kind = c.PANCAKE_HINT_INTEGER;
                out.integer_value = value;
            },
        }
    }
    return .{
        .abi_version = c.PANCAKE_LOCATOR_VIEW_ABI_VERSION,
        .struct_size = @sizeOf(cd.PancakeLocatorView),
        .transport = locator.transport.ptr,
        .transport_len = locator.transport.len,
        .designator = locator.designator.ptr,
        .designator_len = locator.designator.len,
        .hints = if (hints.len == 0) null else hints.ptr,
        .hint_count = hints.len,
        .hint_wire_form = switch (locator.hints.wire_form) {
            .map => c.PANCAKE_HINTS_MAP,
            .boolean_false => c.PANCAKE_HINTS_BOOLEAN_FALSE,
        },
    };
}

pub fn setAdvertisedLocator(host: ?*cd.PancakeHost, locator: model.PeerLocator) !void {
    var hint_storage: [8]cd.PancakeLocatorHintView = undefined;
    try std.testing.expect(locator.hints.entries.len <= hint_storage.len);
    var view = locatorView(locator, hint_storage[0..locator.hints.entries.len]);
    try expectOk(cd.pancake_host_set_advertised_locator(host, &view));
}

pub fn ensureAdvertisedLocator(host: ?*cd.PancakeHost, transport: []const u8) !void {
    try expectOk(cd.pancake_host_ensure_advertised_locator(host, transport.ptr, transport.len));
}

pub fn tcpLocator(designator: []const u8) model.PeerLocator {
    return .{ .transport = "tcp", .designator = designator, .hints = model.Hints.emptyFalse() };
}

// ── The byte shuttle and action pump ─────────────────────────────────────────

/// A wired pair: one host's connection whose outbound is the other's inbound.
pub const Pair = struct {
    a: ?*cd.PancakeHostSession,
    b: ?*cd.PancakeHostSession,
};

pub fn takeOutbound(raw: ?*cd.PancakeHostSession, out: *c.PancakeManagedFrame) i32 {
    var prefix: [cd.PANCAKE_HOST_OUTBOUND_PREFIX_CAP]u8 = undefined;
    var prefix_len: usize = undefined;
    return cd.pancake_host_session_take_outbound(raw, out, &prefix, prefix.len, &prefix_len);
}

/// One DIAL action parked for the test to execute, dial parts copied clear of
/// the action queue's popped-view lifetime.
pub const ParkedDial = struct {
    host: ?*cd.PancakeHost,
    ticket: u64,
    route_index: usize,
    transport: [32]u8 = undefined,
    transport_len: usize = 0,
    designator: [64]u8 = undefined,
    designator_len: usize = 0,
    hint_count: usize = 0,
    relay_route: [128]u8 = undefined,
    relay_route_len: usize = 0,
};

pub const Dials = struct {
    items: [4]ParkedDial = undefined,
    len: usize = 0,
};

/// Drain every encoded outbound frame from `from` and feed each, borrowed, to
/// `to`, releasing the owned managed frame after — the socketless read/write
/// loop.
pub fn shuttle(from: ?*cd.PancakeHostSession, to: ?*cd.PancakeHostSession) !bool {
    var moved = false;
    while (true) {
        var mf: c.PancakeManagedFrame = undefined;
        const rc = takeOutbound(from, &mf);
        if (rc == c.PANCAKE_ERR_WOULD_BLOCK) break;
        try expectOk(rc);
        defer c.pancake_managed_frame_release(&mf);
        const borrowed: c.PancakeFrame = .{ .bytes = mf.bytes, .len = mf.len, .shape = mf.shape };
        try expectOk(cd.pancake_host_session_feed(to, &borrowed));
        moved = true;
    }
    return moved;
}

/// One vow's drain-routed outcome, filled when its SETTLE/FAIL action pops:
/// the argument struct is snapshotted (its POD fields stay readable) and any
/// string payload is copied out of the popped action's until-next-pop
/// lifetime.
pub const CapturedSettle = struct {
    fired: bool = false,
    kind: u32 = 0xffff_ffff,
    value: c.PancakeArgument = undefined,
    text: [64]u8 = undefined,
    text_len: usize = 0,
    msg: [160]u8 = undefined,
    msg_len: usize = 0,

    pub fn recordSettle(self: *CapturedSettle, action: *const cd.PancakeHostAction) void {
        self.fired = true;
        self.kind = c.PANCAKE_RESOLUTION_FULFILL;
        self.value = action.value;
        if ((action.value.kind == c.PANCAKE_ARG_STRING or action.value.kind == c.PANCAKE_ARG_ERROR) and action.value.bytes != null) {
            self.text_len = @min(action.value.bytes_len, self.text.len);
            @memcpy(self.text[0..self.text_len], action.value.bytes.?[0..self.text_len]);
        }
    }

    pub fn recordFail(self: *CapturedSettle, action: *const cd.PancakeHostAction) void {
        self.fired = true;
        self.kind = c.PANCAKE_RESOLUTION_BREAK;
        self.value = argBase();
        if (action.message) |m| {
            self.msg_len = @min(action.message_len, self.msg.len);
            @memcpy(self.msg[0..self.msg_len], m[0..self.msg_len]);
        }
    }

    pub fn requireRef(self: *const CapturedSettle) !c.PancakeReference {
        try std.testing.expect(self.fired);
        try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, self.kind);
        try std.testing.expectEqual(c.PANCAKE_ARG_REFERENCE, self.value.kind);
        return self.value.reference;
    }
};

/// The drain-routed vow registry: the test registers each vow it minted with
/// `add`, and `drainActions` routes each SETTLE/FAIL action to the registered
/// capture by (host, ticket) — a binding's vow table in miniature. A
/// completion nobody registered for is dropped, exactly as a binding drops an
/// outcome no caller awaits (a NEAR send's already-settled local vow).
pub const Watches = struct {
    items: [16]Watch = undefined,
    len: usize = 0,

    const Watch = struct { host: ?*cd.PancakeHost, ticket: u64, capture: *CapturedSettle };

    pub fn add(self: *Watches, host: ?*cd.PancakeHost, ticket: u64, capture: *CapturedSettle) void {
        self.items[self.len] = .{ .host = host, .ticket = ticket, .capture = capture };
        self.len += 1;
    }

    pub fn route(self: *Watches, host: ?*cd.PancakeHost, action: *const cd.PancakeHostAction) void {
        for (self.items[0..self.len], 0..) |w, i| {
            if (w.host == host and w.ticket == action.ticket) {
                if (action.kind == cd.PANCAKE_HOST_ACTION_SETTLE) {
                    w.capture.recordSettle(action);
                } else {
                    w.capture.recordFail(action);
                }
                // One-shot: a vow settles once.
                self.items[i] = self.items[self.len - 1];
                self.len -= 1;
                return;
            }
        }
    }
};

/// Drain every host's action queue, honoring the one loop rule: gift-id
/// requests are answered inline with deterministic bytes (entropy is the
/// embedder's job), flush/close notices are no-ops here (the shuttle polls every
/// connection anyway), dial requests park on `dials` for the test to execute
/// explicitly, and SETTLE/FAIL completions route to the watching capture.
pub fn drainActions(hosts: []const ?*cd.PancakeHost, dials: *Dials, watches: *Watches) !bool {
    const Exec = struct {
        dials: *Dials,
        watches: *Watches,

        pub fn flush(_: @This(), _: ?*cd.PancakeHost, _: *const cd.PancakeHostAction) !bool {
            return false;
        }
        pub fn close(_: @This(), _: ?*cd.PancakeHost, _: *const cd.PancakeHostAction) !bool {
            return false;
        }
        pub fn needGiftId(_: @This(), host: ?*cd.PancakeHost, action: *const cd.PancakeHostAction) !bool {
            const gift_id = @as([32]u8, @splat(0x5a));
            try expectOk(cd.pancake_host_provide_gift_id(host, action.ticket, &gift_id, gift_id.len));
            return true;
        }
        pub fn complete(self: @This(), host: ?*cd.PancakeHost, action: *const cd.PancakeHostAction) !bool {
            self.watches.route(host, action);
            return true;
        }
        pub fn dial(self: @This(), host: ?*cd.PancakeHost, action: *const cd.PancakeHostAction) !bool {
            if (action.kind == cd.PANCAKE_HOST_ACTION_CANCEL_DIAL) {
                try expectOk(cd.pancake_host_dial_cancelled(host, action.ticket, action.route_index));
                return true;
            }
            var parked = ParkedDial{
                .host = host,
                .ticket = action.ticket,
                .route_index = action.route_index,
            };
            const Capture = struct {
                fn receive(raw: ?*anyopaque, view_ptr: ?*const cd.PancakeLocatorView) callconv(.c) i32 {
                    const out: *ParkedDial = @ptrCast(@alignCast(raw orelse return c.PANCAKE_ERR_NULL_POINTER));
                    const view = view_ptr orelse return c.PANCAKE_ERR_NULL_POINTER;
                    if (view.transport_len > out.transport.len or view.designator_len > out.designator.len)
                        return c.PANCAKE_ERR_BUFFER_TOO_SMALL;
                    out.transport_len = view.transport_len;
                    @memcpy(out.transport[0..view.transport_len], view.transport.?[0..view.transport_len]);
                    out.designator_len = view.designator_len;
                    @memcpy(out.designator[0..view.designator_len], view.designator.?[0..view.designator_len]);
                    out.hint_count = view.hint_count;
                    const hints = if (view.hint_count == 0) &.{} else view.hints.?[0..view.hint_count];
                    for (hints) |hint| {
                        const name = hint.name.?[0..hint.name_len];
                        if (!std.mem.eql(u8, name, keyed_relay.rendezvous_relay_hint)) continue;
                        if (hint.bytes_len > out.relay_route.len) return c.PANCAKE_ERR_BUFFER_TOO_SMALL;
                        out.relay_route_len = hint.bytes_len;
                        if (hint.bytes_len != 0) @memcpy(out.relay_route[0..hint.bytes_len], hint.bytes.?[0..hint.bytes_len]);
                    }
                    return c.PANCAKE_OK;
                }
            };
            var view: cd.PancakeLocatorView = undefined;
            var hint_count: usize = 0;
            const probe_rc = cd.pancake_host_pending_dial(
                host,
                action.ticket,
                action.route_index,
                null,
                0,
                &view,
                &hint_count,
            );
            if (probe_rc == c.PANCAKE_ERR_BUFFER_TOO_SMALL) {
                try std.testing.expect(hint_count > 0);
                var hint_storage: [8]cd.PancakeLocatorHintView = undefined;
                try std.testing.expect(hint_count <= hint_storage.len);
                try expectOk(cd.pancake_host_pending_dial(
                    host,
                    action.ticket,
                    action.route_index,
                    &hint_storage,
                    hint_count,
                    &view,
                    &hint_count,
                ));
            } else {
                try expectOk(probe_rc);
            }
            try expectOk(Capture.receive(&parked, &view));
            try std.testing.expectEqual(view.hint_count, hint_count);
            self.dials.items[self.dials.len] = parked;
            self.dials.len += 1;
            return true;
        }
    };
    return (try cd.embedder_pump.drainHosts(
        cd,
        c,
        hosts,
        Exec{ .dials = dials, .watches = watches },
    )).acted;
}

/// Pump shuttles and action drains until the whole network is quiescent.
pub fn pump(hosts: []const ?*cd.PancakeHost, pairs: []const Pair, dials: *Dials, watches: *Watches) !void {
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        var progressed = false;
        for (pairs) |pair| {
            if (try shuttle(pair.a, pair.b)) progressed = true;
            if (try shuttle(pair.b, pair.a)) progressed = true;
        }
        if (try drainActions(hosts, dials, watches)) progressed = true;
        if (!progressed) return;
    }
    return error.PumpDidNotQuiesce;
}

/// Open a dialed/accepted pair between two hosts and drive the keyed
/// handshake open over fed bytes.
pub fn openPair(
    hosts: []const ?*cd.PancakeHost,
    dialer: ?*cd.PancakeHost,
    acceptor: ?*cd.PancakeHost,
    designator: []const u8,
    dials: *Dials,
    watches: *Watches,
) !Pair {
    try ensureAdvertisedLocator(dialer, "tcp");
    try setAdvertisedLocator(acceptor, tcpLocator(designator));
    var accepted: ?*cd.PancakeHostSession = null;
    try expectOk(openAccepted(acceptor, "tcp", 3, &accepted));
    var dialed: ?*cd.PancakeHostSession = null;
    try expectOk(openDialed(dialer, "tcp", 3, designator.ptr, designator.len, &dialed));
    const pair = Pair{ .a = dialed, .b = accepted };
    try pump(hosts, &.{pair}, dials, watches);
    try std.testing.expect(cd.pancake_host_session_is_open(dialed) != 0);
    try std.testing.expect(cd.pancake_host_session_is_open(accepted) != 0);
    return pair;
}
