//! `libpancake_host` loopback: the byte-fed host tier over the C ABI.
//!
//! Multi-connection `PancakeHost`s are wired by shuttling frames between
//! `pancake_host_session_take_outbound` and `pancake_host_session_feed`, with no
//! socket anywhere, and every host effect (a dial, gift-id entropy) is
//! answered through the C action queue (ADR-0072). The capstone is the full
//! three-party handoff driven entirely from C: a gifter's reply becomes a
//! signed give, the recipient's host surfaces one DIAL action the test
//! executes, and the settled vow carries a routable token that pokes the
//! exporter's object. That object is published once in the Host Vat and each
//! session projects a wire name for the same actor.

const std = @import("std");

// The shared C-ABI vocabulary (frame/argument types, codes, managed-frame
// release) is reused from the ocapn archive by layout; the byte-fed host
// family is `libpancake_host`.
const c = @import("c_abi");
const cd = @import("c_abi_host");
const model = @import("pancake").ocapn.model;

const frame_cap: usize = 4096;

fn expectOk(rc: i32) !void {
    try std.testing.expectEqual(c.PANCAKE_OK, rc);
}

fn newHostWith(seed_byte: u8, codec: u32) !?*cd.PancakeHost {
    var host: ?*cd.PancakeHost = null;
    const seed = [_]u8{seed_byte} ** 32;
    try expectOk(cd.pancake_host_new(&seed, seed.len, frame_cap, 1, codec, 0, &host));
    return host;
}

fn newHost(seed_byte: u8) !?*cd.PancakeHost {
    return newHostWith(seed_byte, c.PANCAKE_CODEC_SYRUP);
}

test "pancake_host_set_session_limits overrides queue_cap before mint (ADR-0082)" {
    const host = try newHost(0x51);
    defer _ = cd.pancake_host_release(host);
    try expectOk(cd.pancake_host_set_session_limits(host, 0, 19));
    // Mint a dialed session; limits land via Host.negotiatingOptions.
    var session: ?*cd.PancakeHostSession = null;
    try expectOk(cd.pancake_host_session_open_dialed_locator(
        host,
        "tcp",
        3,
        "127.0.0.1:1",
        11,
        &session,
    ));
    defer _ = cd.pancake_host_session_release(session);
    try std.testing.expect(session != null);
}

test "libpancake_host: opaque references cannot cross Host authority" {
    const a = try newHost(0x53);
    defer _ = cd.pancake_host_release(a);
    const b = try newHost(0x54);
    defer _ = cd.pancake_host_release(b);

    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ a, b };
    const pair = try openPair(&hosts, a, b, "127.0.0.1:7000", &dials, &watches);
    defer _ = cd.pancake_host_session_release(pair.a);
    defer _ = cd.pancake_host_session_release(pair.b);

    var a_ref: c.PancakeReference = .{ .id = 0 };
    var b_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_spawn(pair.a, widgetBehavior, null, null, &a_ref));
    try expectOk(cd.pancake_host_session_spawn(pair.b, widgetBehavior, null, null, &b_ref));
    try std.testing.expect(a_ref.id != b_ref.id);

    var vow: u64 = 0;
    try std.testing.expectEqual(c.PANCAKE_ERR_NOT_FOUND, cd.pancake_host_session_send(pair.b, &a_ref, "poke", 4, null, 0, &vow));
    try std.testing.expectEqual(c.PANCAKE_ERR_NOT_FOUND, cd.pancake_host_session_tell(pair.b, &a_ref, "poke", 4, null, 0));
    try std.testing.expectEqual(c.PANCAKE_ERR_NOT_FOUND, cd.pancake_host_ref_release(b, &a_ref, 1));

    var exporter: ?*cd.PancakeHostSession = undefined;
    try expectOk(cd.pancake_host_reference_exporter(b, &a_ref, &exporter));
    try std.testing.expect(exporter == null);
    try expectOk(cd.pancake_host_reference_exporter(b, &b_ref, &exporter));
    // A local actor belongs to the Host Vat, not to the Port that first
    // projected it, so it has no unique exporter session.
    try std.testing.expect(exporter == null);
    try expectOk(cd.pancake_host_ref_release(b, &b_ref, 1));
    try std.testing.expectEqual(c.PANCAKE_ERR_NOT_FOUND, cd.pancake_host_ref_release(b, &b_ref, 1));
}

test "libpancake_host: raw capability ids are opaque and process-unique across equal-seed Hosts" {
    const a = try newHost(0x55);
    defer _ = cd.pancake_host_release(a);
    const b = try newHost(0x55);
    defer _ = cd.pancake_host_release(b);
    var a_session: ?*cd.PancakeHostSession = null;
    try expectOk(cd.pancake_host_session_open_accepted(a, "tcp", 3, "a", 1, null, 0, &a_session));
    defer _ = cd.pancake_host_session_release(a_session);
    var b_session: ?*cd.PancakeHostSession = null;
    try expectOk(cd.pancake_host_session_open_accepted(b, "tcp", 3, "b", 1, null, 0, &b_session));
    defer _ = cd.pancake_host_session_release(b_session);

    var a_first: c.PancakeReference = .{ .id = 0 };
    var a_second: c.PancakeReference = .{ .id = 0 };
    var b_first: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_spawn(a_session, widgetBehavior, null, null, &a_first));
    try expectOk(cd.pancake_host_session_spawn(a_session, widgetBehavior, null, null, &a_second));
    try expectOk(cd.pancake_host_session_spawn(b_session, widgetBehavior, null, null, &b_first));

    try std.testing.expect(a_first.id != 0 and a_second.id != 0 and b_first.id != 0);
    try std.testing.expect(a_first.id != b_first.id);
    try std.testing.expect(a_second.id != a_first.id +% 1);
    try std.testing.expect(a_first.id != (@as(u64, 1) << 62));
}

test "libpancake_host: a hosted actor survives its originating Port" {
    const first_client = try newHost(0x57);
    defer _ = cd.pancake_host_release(first_client);
    const second_client = try newHost(0x58);
    defer _ = cd.pancake_host_release(second_client);
    const server = try newHost(0x59);
    defer _ = cd.pancake_host_release(server);

    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ first_client, second_client, server };
    const first = try openPair(&hosts, first_client, server, "127.0.0.1:7057", &dials, &watches);
    const second = try openPair(&hosts, second_client, server, "127.0.0.1:7058", &dials, &watches);
    defer _ = cd.pancake_host_session_release(second.a);
    defer _ = cd.pancake_host_session_release(second.b);

    var counter = Counter{};
    var hosted: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(first.b, "widget", 6, widgetBehavior, &counter, null, &hosted));

    // The actor belongs to the server Host Vat, not to the Port that selected
    // its first projection. Retire both ends of that connection, then call the
    // same opaque Host identity through a sibling server Port.
    try expectOk(cd.pancake_host_session_release(first.a));
    try expectOk(cd.pancake_host_session_release(first.b));
    try expectOk(cd.pancake_host_session_tell(second.b, &hosted, "poke", 4, null, 0));
    try std.testing.expectEqual(@as(u32, 1), counter.pokes);
}

test "libpancake_host: rejected recursive projection releases every reference occurrence" {
    const client = try newHost(0x55);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0x56);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7003", &dials, &watches);
    defer _ = cd.pancake_host_session_release(pair.a);
    defer _ = cd.pancake_host_session_release(pair.b);

    // Two wire occurrences of the same import surround a Struct arm that the
    // typed C value cannot represent. The whole projection fails, and neither
    // occurrence may survive as invisible Host or import authority.
    try cd.testing.importObject(pair.a, 7);
    try cd.testing.importObject(pair.a, 7);
    const fields = [_]model.StructEntry{.{ .key = "unsupported", .value = .{ .void = {} } }};
    const args = [_]model.Argument{
        .{ .reference = .{ .far = model.FarRef.object(7) } },
        .{ .@"struct" = &fields },
        .{ .reference = .{ .far = model.FarRef.object(7) } },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedValue, cd.testing.projectArgs(client, pair.a, arena.allocator(), &args));
    try std.testing.expectEqual(@as(usize, 0), try cd.testing.liveCapabilityCount(client));
    try std.testing.expectEqual(@as(u64, 0), try cd.testing.importRefcount(pair.a, 7));
}

// ── C argument/reference construction (shared across the c_abi suite) ────────

const c_args = @import("../support/c_abi_args.zig");
const argBase = c_args.argBase;
const argInt = c_args.argInt;
const argStr = c_args.argStr;
const argRef = c_args.argRef;

// ── The byte shuttle and action pump ─────────────────────────────────────────

/// A wired pair: one host's connection whose outbound is the other's inbound.
const Pair = struct {
    a: ?*cd.PancakeHostSession,
    b: ?*cd.PancakeHostSession,
};

/// One DIAL action parked for the test to execute, dial parts copied clear of
/// the action queue's popped-view lifetime.
const ParkedDial = struct {
    host: ?*cd.PancakeHost,
    ticket: u64,
    transport: [32]u8 = undefined,
    transport_len: usize = 0,
    designator: [64]u8 = undefined,
    designator_len: usize = 0,
    hint_len: usize = 0,
};

const Dials = struct {
    items: [4]ParkedDial = undefined,
    len: usize = 0,
};

/// Drain every encoded outbound frame from `from` and feed each, borrowed, to
/// `to`, releasing the owned managed frame after — the socketless read/write
/// loop.
fn shuttle(from: ?*cd.PancakeHostSession, to: ?*cd.PancakeHostSession) !bool {
    var moved = false;
    while (true) {
        var mf: c.PancakeManagedFrame = undefined;
        const rc = cd.pancake_host_session_take_outbound(from, &mf);
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
const CapturedSettle = struct {
    fired: bool = false,
    kind: u32 = 0xffff_ffff,
    value: c.PancakeArgument = undefined,
    text: [64]u8 = undefined,
    text_len: usize = 0,
    msg: [160]u8 = undefined,
    msg_len: usize = 0,

    fn recordSettle(self: *CapturedSettle, action: *const cd.PancakeHostAction) void {
        self.fired = true;
        self.kind = c.PANCAKE_RESOLUTION_FULFILL;
        self.value = action.value;
        if (action.value.kind == c.PANCAKE_ARG_STRING and action.value.bytes != null) {
            self.text_len = @min(action.value.bytes_len, self.text.len);
            @memcpy(self.text[0..self.text_len], action.value.bytes.?[0..self.text_len]);
        }
    }

    fn recordFail(self: *CapturedSettle, action: *const cd.PancakeHostAction) void {
        self.fired = true;
        self.kind = c.PANCAKE_RESOLUTION_BREAK;
        self.value = argBase();
        if (action.message) |m| {
            self.msg_len = @min(action.message_len, self.msg.len);
            @memcpy(self.msg[0..self.msg_len], m[0..self.msg_len]);
        }
    }

    fn requireRef(self: *const CapturedSettle) !c.PancakeReference {
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
const Watches = struct {
    items: [16]Watch = undefined,
    len: usize = 0,

    const Watch = struct { host: ?*cd.PancakeHost, ticket: u64, capture: *CapturedSettle };

    fn add(self: *Watches, host: ?*cd.PancakeHost, ticket: u64, capture: *CapturedSettle) void {
        self.items[self.len] = .{ .host = host, .ticket = ticket, .capture = capture };
        self.len += 1;
    }

    fn route(self: *Watches, host: ?*cd.PancakeHost, action: *const cd.PancakeHostAction) void {
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
fn drainActions(hosts: []const ?*cd.PancakeHost, dials: *Dials, watches: *Watches) !bool {
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
            const gift_id = [_]u8{0x5a} ** 32;
            try expectOk(cd.pancake_host_provide_gift_id(host, action.ticket, &gift_id, gift_id.len));
            return true;
        }
        pub fn complete(self: @This(), host: ?*cd.PancakeHost, action: *const cd.PancakeHostAction) !bool {
            self.watches.route(host, action);
            return true;
        }
        pub fn dial(self: @This(), host: ?*cd.PancakeHost, action: *const cd.PancakeHostAction) !bool {
            // Ticket-only DIAL: one pending-dial view (transport/designator/hint).
            var view: cd.PancakePendingDial = undefined;
            try expectOk(cd.pancake_host_pending_dial(host, action.ticket, &view));
            var parked = ParkedDial{ .host = host, .ticket = action.ticket };
            parked.transport_len = view.transport_len;
            if (view.transport_len != 0) @memcpy(parked.transport[0..view.transport_len], view.transport.?[0..view.transport_len]);
            parked.designator_len = view.designator_len;
            if (view.designator_len != 0) @memcpy(parked.designator[0..view.designator_len], view.designator.?[0..view.designator_len]);
            parked.hint_len = view.hint_len;
            self.dials.items[self.dials.len] = parked;
            self.dials.len += 1;
            return true;
        }
    };
    return cd.embedder_pump.drainHosts(cd, c, hosts, Exec{ .dials = dials, .watches = watches });
}

/// Pump shuttles and action drains until the whole network is quiescent.
fn pump(hosts: []const ?*cd.PancakeHost, pairs: []const Pair, dials: *Dials, watches: *Watches) !void {
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
fn openPair(
    hosts: []const ?*cd.PancakeHost,
    dialer: ?*cd.PancakeHost,
    acceptor: ?*cd.PancakeHost,
    designator: []const u8,
    dials: *Dials,
    watches: *Watches,
) !Pair {
    var accepted: ?*cd.PancakeHostSession = null;
    try expectOk(cd.pancake_host_session_open_accepted(acceptor, "tcp", 3, designator.ptr, designator.len, null, 0, &accepted));
    var dialed: ?*cd.PancakeHostSession = null;
    try expectOk(cd.pancake_host_session_open_dialed_locator(dialer, "tcp", 3, designator.ptr, designator.len, &dialed));
    const pair = Pair{ .a = dialed, .b = accepted };
    try pump(hosts, &.{pair}, dials, watches);
    try std.testing.expect(cd.pancake_host_session_is_open(dialed) != 0);
    try std.testing.expect(cd.pancake_host_session_is_open(accepted) != 0);
    return pair;
}

// ── Behaviors and captures ───────────────────────────────────────────────────

const Counter = struct { pokes: u32 = 0 };

/// The served object: counts pokes and replies with a fixed string.
fn widgetBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.PancakeHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.PancakeArgument,
    args_len: usize,
    out_reply: *c.PancakeArgument,
) callconv(.c) i32 {
    _ = .{ turn, args, args_len };
    if (!std.mem.eql(u8, verb[0..verb_len], "poke")) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    if (ctx) |p| {
        const counter: *Counter = @ptrCast(@alignCast(p));
        counter.pokes += 1;
    }
    out_reply.* = argStr("poked over the C surface");
    return c.PANCAKE_OK;
}

const TypedCapture = struct {
    seen: bool = false,
    nested_ref: c.PancakeReference = .{ .id = 0 },
};

fn typedBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.PancakeHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.PancakeArgument,
    args_len: usize,
    out_reply: *c.PancakeArgument,
) callconv(.c) i32 {
    _ = turn;
    if (!std.mem.eql(u8, verb[0..verb_len], "typed") or args_len != 4) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    const values = args orelse return c.PANCAKE_ERR_NULL_POINTER;
    const set = values[0];
    const tagged = values[1];
    const keyword = values[2];
    const big = values[3];
    if (set.kind != c.PANCAKE_ARG_SET or set.items_len != 2 or set.items == null) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    if (set.items.?[0].kind != c.PANCAKE_ARG_INTEGER or set.items.?[0].integer != 1) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    if (set.items.?[1].kind != c.PANCAKE_ARG_INTEGER or set.items.?[1].integer != 2) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    if (tagged.kind != c.PANCAKE_ARG_TAGGED or tagged.bytes == null or tagged.items == null or tagged.items_len != 1) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    if (!std.mem.eql(u8, tagged.bytes.?[0..tagged.bytes_len], "Point")) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    if (tagged.items.?[0].kind != c.PANCAKE_ARG_REFERENCE or tagged.items.?[0].reference.id == 0) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    if (keyword.kind != c.PANCAKE_ARG_KEYWORD or keyword.bytes == null) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    if (!std.mem.eql(u8, keyword.bytes.?[0..keyword.bytes_len], "color")) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    if (big.kind != c.PANCAKE_ARG_BIG_INTEGER or big.boolean != 1 or big.bytes == null) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    if (!std.mem.eql(u8, big.bytes.?[0..big.bytes_len], "1267650600228229401496703205376")) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    const capture: *TypedCapture = @ptrCast(@alignCast(ctx.?));
    capture.seen = true;
    capture.nested_ref = tagged.items.?[0].reference;
    out_reply.* = argStr("typed values arrived");
    return c.PANCAKE_OK;
}

const IntroducerCtx = struct { widget: c.PancakeReference };

/// The gifter's introducer: replies with the foreign capability it fetched;
/// the host's own origination turns that reply into a signed give.
fn introducerBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.PancakeHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.PancakeArgument,
    args_len: usize,
    out_reply: *c.PancakeArgument,
) callconv(.c) i32 {
    _ = .{ turn, args, args_len };
    if (!std.mem.eql(u8, verb[0..verb_len], "introduce")) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    const ic: *IntroducerCtx = @ptrCast(@alignCast(ctx.?));
    out_reply.* = argRef(ic.widget);
    return c.PANCAKE_OK;
}

const CaretakerCtx = struct { target_ref: c.PancakeReference };

/// A forwarding proxy: "poke" forwards this turn's call (and answer) to the
/// wrapped local object; "kick" pokes it twice through the turn's own send and
/// tell verbs and replies void itself.
fn caretakerBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.PancakeHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.PancakeArgument,
    args_len: usize,
    out_reply: *c.PancakeArgument,
) callconv(.c) i32 {
    const cc: *CaretakerCtx = @ptrCast(@alignCast(ctx.?));
    const target = cc.target_ref;
    if (std.mem.eql(u8, verb[0..verb_len], "poke")) {
        return cd.pancake_host_turn_forward(turn, &target, verb, verb_len, args, args_len, out_reply);
    }
    if (std.mem.eql(u8, verb[0..verb_len], "kick")) {
        var vow: u64 = 0;
        if (cd.pancake_host_turn_send(turn, &target, "poke", 4, null, 0, &vow) != c.PANCAKE_OK) return c.PANCAKE_ERR_INTERNAL;
        if (cd.pancake_host_turn_tell(turn, &target, "poke", 4, null, 0) != c.PANCAKE_OK) return c.PANCAKE_ERR_INTERNAL;
        out_reply.* = argBase();
        return c.PANCAKE_OK;
    }
    return c.PANCAKE_ERR_INVALID_ARGUMENT;
}

/// A served factory: "make" spawns a fresh widget mid-turn (the turn-time
/// spawn) and replies with its NEAR reference; "deny" refuses with a
/// caller-supplied diagnostic through turn_break instead of a bare non-OK.
fn factoryBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.PancakeHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.PancakeArgument,
    args_len: usize,
    out_reply: *c.PancakeArgument,
) callconv(.c) i32 {
    _ = .{ args, args_len };
    const counter: *Counter = @ptrCast(@alignCast(ctx.?));
    if (std.mem.eql(u8, verb[0..verb_len], "make")) {
        var spawned_ref: c.PancakeReference = .{ .id = 0 };
        if (cd.pancake_host_turn_spawn(turn, widgetBehavior, counter, null, &spawned_ref) != c.PANCAKE_OK)
            return c.PANCAKE_ERR_INTERNAL;
        out_reply.* = argRef(spawned_ref);
        return c.PANCAKE_OK;
    }
    if (std.mem.eql(u8, verb[0..verb_len], "deny")) {
        if (cd.pancake_host_turn_break(turn, "Attenuated", 10) != c.PANCAKE_OK)
            return c.PANCAKE_ERR_INTERNAL;
        return c.PANCAKE_OK;
    }
    return c.PANCAKE_ERR_INVALID_ARGUMENT;
}

const kitchen_pair_items = [_]c.PancakeArgument{ argInt(11), argInt(22) };
const kitchen_boxed_items = [_]c.PancakeArgument{argInt(7)};

const KitchenCtx = struct { widget_local_ref: c.PancakeReference };

/// The pipelining fixture: "make" replies with a capability to the widget,
/// "pair" with a two-element list, "boxed" with a single-value Tagged.
fn kitchenBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.PancakeHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.PancakeArgument,
    args_len: usize,
    out_reply: *c.PancakeArgument,
) callconv(.c) i32 {
    _ = .{ turn, args, args_len };
    const kc: *KitchenCtx = @ptrCast(@alignCast(ctx.?));
    const v = verb[0..verb_len];
    if (std.mem.eql(u8, v, "make")) {
        out_reply.* = argRef(kc.widget_local_ref);
        return c.PANCAKE_OK;
    }
    if (std.mem.eql(u8, v, "pair")) {
        var reply = argBase();
        reply.kind = c.PANCAKE_ARG_LIST;
        reply.items = &kitchen_pair_items;
        reply.items_len = kitchen_pair_items.len;
        out_reply.* = reply;
        return c.PANCAKE_OK;
    }
    if (std.mem.eql(u8, v, "boxed")) {
        var reply = argBase();
        reply.kind = c.PANCAKE_ARG_TAGGED;
        reply.bytes = "box";
        reply.bytes_len = 3;
        reply.items = &kitchen_boxed_items;
        reply.items_len = kitchen_boxed_items.len;
        out_reply.* = reply;
        return c.PANCAKE_OK;
    }
    return c.PANCAKE_ERR_INVALID_ARGUMENT;
}

/// Counts `PancakeHostCtxFree` runs, pinning the exactly-once contract.
const FreeFlag = struct {
    var runs: u32 = 0;
    fn cb(ctx: ?*anyopaque) callconv(.c) void {
        _ = ctx;
        runs += 1;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "libpancake_host: two byte-fed hosts open a keyed session through the C surface (ADR-0072)" {
    var context: ?*c.PancakeContext = null;
    try expectOk(c.pancake_context_new(&context));
    defer c.pancake_context_release(context);

    // The dialer allocates through a context, the acceptor through the
    // library allocator, so both constructors are exercised.
    var dialer: ?*cd.PancakeHost = null;
    const dialer_seed = [_]u8{0x0a} ** 32;
    try expectOk(cd.pancake_host_new_in(context, &dialer_seed, dialer_seed.len, frame_cap, 1, c.PANCAKE_CODEC_SYRUP, 0, &dialer));
    defer _ = cd.pancake_host_release(dialer);
    const acceptor = try newHost(0x0b);
    defer _ = cd.pancake_host_release(acceptor);

    // The dialer also listens, so its hellos sign a real designator; an
    // over-long designator is refused before anything is retained.
    try expectOk(cd.pancake_host_set_self_designator(dialer, "127.0.0.1:9999", 14));
    const too_long = [_]u8{'x'} ** 65;
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cd.pancake_host_set_self_designator(dialer, &too_long, too_long.len));

    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ dialer, acceptor };
    const pair = try openPair(&hosts, dialer, acceptor, "127.0.0.1:7001", &dials, &watches);
    try std.testing.expectEqual(@as(usize, 0), dials.len);

    // Quiescent: nothing queued on either side, on either channel.
    var mf: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cd.pancake_host_session_take_outbound(pair.a, &mf));
    var action: cd.PancakeHostAction = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cd.pancake_host_next_action(dialer, &action));

    // Connections release before their hosts.
    _ = cd.pancake_host_session_release(pair.a);
    _ = cd.pancake_host_session_release(pair.b);
}

test "libpancake_host: a malformed frame classifies CODEC, conn_last_abort names it, and the partner retains the abort" {
    const dialer = try newHost(0x11);
    defer _ = cd.pancake_host_release(dialer);
    const acceptor = try newHost(0x12);
    defer _ = cd.pancake_host_release(acceptor);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ dialer, acceptor };
    const pair = try openPair(&hosts, dialer, acceptor, "127.0.0.1:7001", &dials, &watches);

    // No abort yet, on either accessor.
    var abort_info: c.PancakeLastAbort = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cd.pancake_host_session_last_abort(pair.b, &abort_info));
    var kind_name: ?[*]const u8 = null;
    var kind_name_len: usize = 0;
    var partner_msg: [160]u8 = undefined;
    var partner_len: usize = 0;
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cd.pancake_host_session_partner_abort(pair.a, &kind_name, &kind_name_len, &partner_msg, partner_msg.len, &partner_len));

    // Attacker-shaped input: not a Syrup frame at all. The classified code
    // must be CODEC (the shared taxonomy), never a flattened SESSION.
    const garbage = "not a syrup frame";
    const borrowed: c.PancakeFrame = .{ .bytes = @constCast(garbage.ptr), .len = garbage.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
    try std.testing.expectEqual(c.PANCAKE_ERR_CODEC, cd.pancake_host_session_feed(pair.b, &borrowed));

    // The cause is readable through the family's own error channel, and the
    // slot clears on demand.
    var err_buf: [128]u8 = undefined;
    try std.testing.expect(cd.pancake_host_last_error(&err_buf, err_buf.len) > 0);
    cd.pancake_host_clear_last_error();
    try std.testing.expectEqual(@as(usize, 0), cd.pancake_host_last_error(&err_buf, err_buf.len));

    // The typed cause is retained on the failing side.
    try expectOk(cd.pancake_host_session_last_abort(pair.b, &abort_info));
    try std.testing.expectEqual(c.PANCAKE_ABORT_DOMAIN_CODEC, abort_info.domain);
    try std.testing.expect(abort_info.has_kind != 0);

    // The failure is loud on the wire: a typed op:abort is queued for the
    // partner, and once fed the partner retains kind and diagnostic.
    var mf: c.PancakeManagedFrame = undefined;
    try expectOk(cd.pancake_host_session_take_outbound(pair.b, &mf));
    const abort_frame: c.PancakeFrame = .{ .bytes = mf.bytes, .len = mf.len, .shape = mf.shape };
    _ = cd.pancake_host_session_feed(pair.a, &abort_frame);
    c.pancake_managed_frame_release(&mf);
    try expectOk(cd.pancake_host_session_partner_abort(pair.a, &kind_name, &kind_name_len, &partner_msg, partner_msg.len, &partner_len));
    try std.testing.expect(kind_name_len > 0);
    try std.testing.expectEqualStrings("MalformedFrame", kind_name.?[0..kind_name_len]);
}

test "libpancake_host: publish, fetch, send, tell, and the enliven cache hit's pre-queued completion" {
    const client = try newHost(0x21);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0x22);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7001", &dials, &watches);

    var counter = Counter{};
    var widget_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(pair.b, "widget", 6, widgetBehavior, &counter, null, &widget_local_ref));

    // Fetch arrives already enrolled as a node-unique token.
    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "widget", 6, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const widget_ref = try fetched.requireRef();

    // A send through the token settles with the served reply, drained as the
    // vow's SETTLE action.
    var vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &widget_ref, "poke", 4, null, 0, &vow));
    var settled = CapturedSettle{};
    watches.add(client, vow, &settled);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(settled.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, settled.kind);
    try std.testing.expectEqualStrings("poked over the C surface", settled.text[0..settled.text_len]);
    try std.testing.expectEqual(@as(u32, 1), counter.pokes);

    // Fire-and-forget still runs the served turn.
    try expectOk(cd.pancake_host_session_tell(pair.a, &widget_ref, "poke", 4, null, 0));
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expectEqual(@as(u32, 2), counter.pokes);

    // The empty verb is a real message — Goblins invokes a capability
    // positionally with verb "" — and the family's `ptr + len` contract admits
    // `(null, 0)` as the empty view, which is exactly what a wasm caller
    // stages for an empty buffer. The call must be accepted at the ABI seam
    // and travel to the behavior, which refuses the verb *there* (a broken
    // reply), not as a NullPointer at the boundary.
    var empty_verb_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &widget_ref, null, 0, null, 0, &empty_verb_vow));
    var empty_verb_settled = CapturedSettle{};
    watches.add(client, empty_verb_vow, &empty_verb_settled);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(empty_verb_settled.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_BREAK, empty_verb_settled.kind);

    // A fresh enliven rides the wire; the second one hits the dedup cache and
    // its completion is queued before the registering call returns — no wire
    // traffic, just the next drain.
    const sturdyref = "ocapn://127.0.0.1%3A7001.tcp/s/widget";
    const wrong_peer = "ocapn://127.0.0.1%3A7999.tcp/s/widget";
    var refused_vow: u64 = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cd.pancake_host_session_enliven(pair.a, wrong_peer, wrong_peer.len, &refused_vow),
    );
    var no_fetch: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cd.pancake_host_session_take_outbound(pair.a, &no_fetch));
    var enlivened = CapturedSettle{};
    var enlivened_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_enliven(pair.a, sturdyref, sturdyref.len, &enlivened_vow));
    watches.add(client, enlivened_vow, &enlivened);
    try std.testing.expect(!enlivened.fired);
    try pump(&hosts, &.{pair}, &dials, &watches);
    _ = try enlivened.requireRef();
    var cache_hit = CapturedSettle{};
    var cache_hit_vow: u64 = 0;
    const same_peer_new_hints = "ocapn://127.0.0.1%3A7001.tcp/s/widget?route=changed";
    try expectOk(cd.pancake_host_session_enliven(pair.a, same_peer_new_hints, same_peer_new_hints.len, &cache_hit_vow));
    watches.add(client, cache_hit_vow, &cache_hit);
    try std.testing.expect(!cache_hit.fired);
    _ = try drainActions(&hosts, &dials, &watches);
    try std.testing.expect(cache_hit.fired);
    _ = try cache_hit.requireRef();
}

test "libpancake_host: a nonzero local_turn_budget constructs a host (ADR-0076)" {
    var host: ?*cd.PancakeHost = null;
    const seed = [_]u8{0x41} ** 32;
    try expectOk(cd.pancake_host_new(&seed, seed.len, frame_cap, 1, c.PANCAKE_CODEC_SYRUP, 64, &host));
    defer _ = cd.pancake_host_release(host);
    // 0 remains the unbounded default; a second host with 0 still constructs.
    const unbounded = try newHost(0x42);
    defer _ = cd.pancake_host_release(unbounded);
}

test "libpancake_host: the host codec option carries a Cap'n Proto session end to end" {
    // A codec outside the family is refused before anything is allocated.
    var refused: ?*cd.PancakeHost = null;
    const seed = [_]u8{0x31} ** 32;
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cd.pancake_host_new(&seed, seed.len, frame_cap, 1, 99, 0, &refused));

    const client = try newHostWith(0x31, c.PANCAKE_CODEC_CAPNP);
    defer _ = cd.pancake_host_release(client);
    const server = try newHostWith(0x32, c.PANCAKE_CODEC_CAPNP);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };

    // Open the halves by hand so the dialer's first outbound frame can be
    // inspected: a capnp frame leads with its single-segment table word (low
    // u32 zero), never Syrup's record-open byte.
    const designator = "127.0.0.1:7002";
    var accepted: ?*cd.PancakeHostSession = null;
    try expectOk(cd.pancake_host_session_open_accepted(server, "tcp", 3, designator.ptr, designator.len, null, 0, &accepted));
    var dialed: ?*cd.PancakeHostSession = null;
    try expectOk(cd.pancake_host_session_open_dialed_locator(client, "tcp", 3, designator.ptr, designator.len, &dialed));
    var hello: c.PancakeManagedFrame = undefined;
    try expectOk(cd.pancake_host_session_take_outbound(dialed, &hello));
    try std.testing.expect(hello.len >= 8);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, hello.bytes.?[0..4]);
    const borrowed: c.PancakeFrame = .{ .bytes = hello.bytes, .len = hello.len, .shape = hello.shape };
    try expectOk(cd.pancake_host_session_feed(accepted, &borrowed));
    c.pancake_managed_frame_release(&hello);
    const pair = Pair{ .a = dialed, .b = accepted };
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(cd.pancake_host_session_is_open(dialed) != 0);
    try std.testing.expect(cd.pancake_host_session_is_open(accepted) != 0);

    // A publish/fetch/send round-trip carries through the capnp session.
    var counter = Counter{};
    var widget_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(pair.b, "widget", 6, widgetBehavior, &counter, null, &widget_local_ref));
    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "widget", 6, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const widget_ref = try fetched.requireRef();
    var vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &widget_ref, "poke", 4, null, 0, &vow));
    var settled = CapturedSettle{};
    watches.add(client, vow, &settled);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(settled.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, settled.kind);
    try std.testing.expectEqualStrings("poked over the C surface", settled.text[0..settled.text_len]);
    try std.testing.expectEqual(@as(u32, 1), counter.pokes);
}

test "libpancake_host: uncommon typed values and a nested capability cross the Host ABI" {
    const client = try newHost(0x37);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0x38);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7004", &dials, &watches);
    defer _ = cd.pancake_host_session_release(pair.a);
    defer _ = cd.pancake_host_session_release(pair.b);

    var capture = TypedCapture{};
    var local_target: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(pair.b, "typed", 5, typedBehavior, &capture, null, &local_target));
    var fetched = CapturedSettle{};
    var fetch_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "typed", 5, &fetch_vow));
    watches.add(client, fetch_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const target = try fetched.requireRef();

    // A local client actor nested inside Tagged proves the complete value walk
    // lowers references while preserving uncommon pass-by-copy arms.
    var nested: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_spawn(pair.a, widgetBehavior, null, null, &nested));
    const set_items = [_]c.PancakeArgument{ argInt(1), argInt(2) };
    var set = argBase();
    set.kind = c.PANCAKE_ARG_SET;
    set.items = set_items[0..].ptr;
    set.items_len = set_items.len;
    const tagged_items = [_]c.PancakeArgument{argRef(nested)};
    var tagged = argBase();
    tagged.kind = c.PANCAKE_ARG_TAGGED;
    tagged.bytes = "Point";
    tagged.bytes_len = 5;
    tagged.items = tagged_items[0..].ptr;
    tagged.items_len = tagged_items.len;
    var keyword = argBase();
    keyword.kind = c.PANCAKE_ARG_KEYWORD;
    keyword.bytes = "color";
    keyword.bytes_len = 5;
    const digits = "1267650600228229401496703205376";
    var big = argBase();
    big.kind = c.PANCAKE_ARG_BIG_INTEGER;
    big.boolean = 1;
    big.bytes = digits;
    big.bytes_len = digits.len;
    const args = [_]c.PancakeArgument{ set, tagged, keyword, big };

    var send_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &target, "typed", 5, args[0..].ptr, args.len, &send_vow));
    var settled = CapturedSettle{};
    watches.add(client, send_vow, &settled);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(capture.seen);
    try std.testing.expect(capture.nested_ref.id != 0);
    try std.testing.expectEqualStrings("typed values arrived", settled.text[0..settled.text_len]);

    // A noncanonical bignum that fits i64 is rejected before any call queues.
    var small = argBase();
    small.kind = c.PANCAKE_ARG_BIG_INTEGER;
    small.bytes = "7";
    small.bytes_len = 1;
    var refused_vow: u64 = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_UNSUPPORTED_VALUE,
        cd.pancake_host_session_send(pair.a, &target, "typed", 5, @ptrCast(&small), 1, &refused_vow),
    );
    var outbound: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cd.pancake_host_session_take_outbound(pair.a, &outbound));

    try expectOk(cd.pancake_host_ref_release(client, &nested, 1));
    try expectOk(cd.pancake_host_ref_release(client, &target, 1));
}

test "libpancake_host: a spawned object behind a caretaker — turn_forward, turn_send, turn_tell" {
    const client = try newHost(0x31);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0x32);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7001", &dials, &watches);

    // The wrapped object has no fetchable name; only the caretaker is
    // published, and it reaches the widget through the turn verbs.
    var counter = Counter{};
    var widget_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_spawn(pair.b, widgetBehavior, &counter, null, &widget_local_ref));
    var caretaker_ctx = CaretakerCtx{ .target_ref = widget_local_ref };
    var caretaker_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(pair.b, "caretaker", 9, caretakerBehavior, &caretaker_ctx, null, &caretaker_local_ref));

    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "caretaker", 9, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const caretaker_ref = try fetched.requireRef();

    // Forwarded call: the caretaker's own answer settles on the widget's reply.
    var vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &caretaker_ref, "poke", 4, null, 0, &vow));
    var settled = CapturedSettle{};
    watches.add(client, vow, &settled);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(settled.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, settled.kind);
    try std.testing.expectEqualStrings("poked over the C surface", settled.text[0..settled.text_len]);
    try std.testing.expectEqual(@as(u32, 1), counter.pokes);

    // The turn's own send and tell each land one more poke.
    var kick_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &caretaker_ref, "kick", 4, null, 0, &kick_vow));
    var kicked = CapturedSettle{};
    watches.add(client, kick_vow, &kicked);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(kicked.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, kicked.kind);
    try std.testing.expectEqual(@as(u32, 3), counter.pokes);
}

test "libpancake_host: turn_spawn mints a capability mid-turn, and turn_break carries the refusal's own words" {
    const client = try newHost(0x61);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0x62);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7001", &dials, &watches);

    var counter = Counter{};
    var factory_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(pair.b, "factory", 7, factoryBehavior, &counter, null, &factory_local_ref));

    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "factory", 7, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const factory_ref = try fetched.requireRef();

    // The served "make" spawns a widget inside its own turn and replies with
    // it; the reply's capability is live, so a follow-up poke lands.
    var make_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &factory_ref, "make", 4, null, 0, &make_vow));
    var made = CapturedSettle{};
    watches.add(client, make_vow, &made);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(made.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, made.kind);
    try std.testing.expectEqual(c.PANCAKE_ARG_REFERENCE, made.value.kind);
    const widget_ref = made.value.reference;

    var poke_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &widget_ref, "poke", 4, null, 0, &poke_vow));
    var poked = CapturedSettle{};
    watches.add(client, poke_vow, &poked);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(poked.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, poked.kind);
    try std.testing.expectEqual(@as(u32, 1), counter.pokes);

    // A refusal through turn_break reaches the caller with the behavior's own
    // diagnostic, not a generic reason.
    var deny_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &factory_ref, "deny", 4, null, 0, &deny_vow));
    var denied = CapturedSettle{};
    watches.add(client, deny_vow, &denied);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(denied.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_BREAK, denied.kind);
    try std.testing.expectEqualStrings("Attenuated", denied.msg[0..denied.msg_len]);
}

test "libpancake_host: promise pipelining — vow_send, vow_index, vow_untag, vow_get before the answers exist" {
    const client = try newHost(0x41);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0x42);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7001", &dials, &watches);

    var counter = Counter{};
    var widget_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_spawn(pair.b, widgetBehavior, &counter, null, &widget_local_ref));
    var kitchen_ctx = KitchenCtx{ .widget_local_ref = widget_local_ref };
    var kitchen_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(pair.b, "kitchen", 7, kitchenBehavior, &kitchen_ctx, null, &kitchen_local_ref));

    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "kitchen", 7, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const kitchen_ref = try fetched.requireRef();

    // All three chains register before a single frame moves: the sends ride
    // the answers, not the settled values.
    var make_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &kitchen_ref, "make", 4, null, 0, &make_vow));
    var poked_vow: u64 = 0;
    try expectOk(cd.pancake_host_vow_send(client, make_vow, "poke", 4, null, 0, &poked_vow));
    var poked = CapturedSettle{};
    watches.add(client, poked_vow, &poked);

    var pair_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &kitchen_ref, "pair", 4, null, 0, &pair_vow));
    var second_vow: u64 = 0;
    try expectOk(cd.pancake_host_vow_index(client, pair_vow, 1, &second_vow));
    var second = CapturedSettle{};
    watches.add(client, second_vow, &second);

    var boxed_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &kitchen_ref, "boxed", 5, null, 0, &boxed_vow));
    var unboxed_vow: u64 = 0;
    try expectOk(cd.pancake_host_vow_untag(client, boxed_vow, "box", 3, &unboxed_vow));
    var unboxed = CapturedSettle{};
    watches.add(client, unboxed_vow, &unboxed);

    // vow_get mints against the still-pending list answer: C ABI cannot build
    // a Struct reply, so the projected vow breaks when the source settles.
    var get_vow: u64 = 0;
    try expectOk(cd.pancake_host_vow_get(client, pair_vow, "name", 4, &get_vow));
    var gotten = CapturedSettle{};
    watches.add(client, get_vow, &gotten);

    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(poked.fired);
    try std.testing.expectEqualStrings("poked over the C surface", poked.text[0..poked.text_len]);
    try std.testing.expect(second.fired);
    try std.testing.expectEqual(c.PANCAKE_ARG_INTEGER, second.value.kind);
    try std.testing.expectEqual(@as(i64, 22), second.value.integer);
    try std.testing.expect(unboxed.fired);
    try std.testing.expectEqual(c.PANCAKE_ARG_INTEGER, unboxed.value.kind);
    try std.testing.expectEqual(@as(i64, 7), unboxed.value.integer);
    try std.testing.expect(gotten.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_BREAK, gotten.kind);

    // A NEAR send runs its turn inside the call, so its local vow settles
    // and retires before the caller can touch it: the projection reports the
    // row gone, the same NOT_FOUND a settled wire vow reports.
    const near_widget = widget_local_ref;
    var local_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.b, &near_widget, "poke", 4, null, 0, &local_vow));
    var refused_vow: u64 = 0;
    try std.testing.expectEqual(c.PANCAKE_ERR_NOT_FOUND, cd.pancake_host_vow_index(server, local_vow, 0, &refused_vow));
}

test "libpancake_host: the full three-party handoff through the C surface — one dial action, a routable token" {
    const exporter = try newHost(0x0e);
    const gifter = try newHost(0x06);
    defer _ = cd.pancake_host_release(gifter);
    const recipient = try newHost(0x0c);
    defer _ = cd.pancake_host_release(recipient);
    const hosts = [_]?*cd.PancakeHost{ exporter, gifter, recipient };
    var dials = Dials{};
    var watches = Watches{};

    // The widget is published Host-wide before any connection exists. Fetch
    // lazily projects it on the gifter-facing Port; deposit captures that exact
    // actor in the Vat owned by the Host, and withdrawal later projects it on the
    // recipient-facing Port without consulting the alias again.
    var counter = Counter{};
    FreeFlag.runs = 0;
    try expectOk(cd.pancake_host_publish(exporter, "widget", 6, widgetBehavior, &counter, FreeFlag.cb));

    // Gifter dials the exporter and fetches the widget: the node records the
    // capability's foreign home, which is what the give will name.
    const g_to_e = try openPair(&hosts, gifter, exporter, "127.0.0.1:7001", &dials, &watches);
    var widget = CapturedSettle{};
    var widget_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(g_to_e.a, "widget", 6, &widget_vow));
    watches.add(gifter, widget_vow, &widget);
    try pump(&hosts, &.{g_to_e}, &dials, &watches);
    const widget_token = try widget.requireRef();

    // Recipient dials the gifter and fetches the introducer.
    const r_to_g = try openPair(&hosts, recipient, gifter, "127.0.0.1:7002", &dials, &watches);
    var introducer_ctx = IntroducerCtx{ .widget = widget_token };
    var introducer_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(r_to_g.b, "introducer", 10, introducerBehavior, &introducer_ctx, null, &introducer_local_ref));
    var introducer = CapturedSettle{};
    var introducer_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(r_to_g.a, "introducer", 10, &introducer_vow));
    watches.add(recipient, introducer_vow, &introducer);
    try pump(&hosts, &.{ g_to_e, r_to_g }, &dials, &watches);
    const introducer_ref = try introducer.requireRef();

    // The introduction: the gifter's reply fulfills with a foreign-homed
    // capability, the gifter host originates the give (gift-id entropy
    // answered through its action queue), and the recipient host claims the
    // give and surfaces exactly one DIAL action naming the exporter.
    var introduce_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(r_to_g.a, &introducer_ref, "introduce", 9, null, 0, &introduce_vow));
    var redeemed = CapturedSettle{};
    watches.add(recipient, introduce_vow, &redeemed);
    try pump(&hosts, &.{ g_to_e, r_to_g }, &dials, &watches);

    try std.testing.expectEqual(@as(usize, 1), dials.len);
    const parked = dials.items[0];
    try std.testing.expect(parked.host == recipient);

    // Pending-row dial parts (ticket-only DIAL): this tcp give has no
    // direct-addresses hint.
    try std.testing.expectEqualStrings("tcp", parked.transport[0..parked.transport_len]);
    try std.testing.expectEqualStrings("127.0.0.1:7001", parked.designator[0..parked.designator_len]);
    try std.testing.expectEqual(@as(usize, 0), parked.hint_len);

    // The test is the dial executor: open the recipient's own connection to
    // the exporter, drive it open, and report it back. The withdraw, its
    // settle, and the vow's fulfillment all pump inside the report. The
    // exporter publishes nothing on this session by hand — withdrawal projects
    // the exact deposited target onto this Port.
    var e_accepts_r: ?*cd.PancakeHostSession = null;
    try expectOk(cd.pancake_host_session_open_accepted(exporter, "tcp", 3, "127.0.0.1:7001", 14, null, 0, &e_accepts_r));
    var r_to_e: ?*cd.PancakeHostSession = null;
    try expectOk(cd.pancake_host_session_open_dialed_locator(
        recipient,
        parked.transport[0..parked.transport_len].ptr,
        parked.transport_len,
        parked.designator[0..parked.designator_len].ptr,
        parked.designator_len,
        &r_to_e,
    ));
    const redeem_pair = Pair{ .a = r_to_e, .b = e_accepts_r };
    const all_pairs = [_]Pair{ g_to_e, r_to_g, redeem_pair };
    try pump(&hosts, &all_pairs, &dials, &watches);
    try std.testing.expect(cd.pancake_host_session_is_open(r_to_e) != 0);
    try expectOk(cd.pancake_host_dialed(recipient, parked.ticket, r_to_e));
    try pump(&hosts, &all_pairs, &dials, &watches);

    try std.testing.expect(redeemed.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, redeemed.kind);
    try std.testing.expectEqual(c.PANCAKE_ARG_REFERENCE, redeemed.value.kind);
    const token = redeemed.value.reference;

    // The token routes: a send through it reaches the exporter's widget
    // directly, over the recipient's own connection.
    var poke_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(r_to_g.a, &token, "poke", 4, null, 0, &poke_vow));
    var poked = CapturedSettle{};
    watches.add(recipient, poke_vow, &poked);
    try pump(&hosts, &all_pairs, &dials, &watches);
    try std.testing.expect(poked.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, poked.kind);
    try std.testing.expectEqualStrings("poked over the C surface", poked.text[0..poked.text_len]);
    try std.testing.expectEqual(@as(u32, 1), counter.pokes);

    // A foreign-homed far argument is refused whole: the token lives on the
    // recipient-exporter connection, and the send routes over
    // recipient-gifter.
    var foreign_args = [_]c.PancakeArgument{argRef(token)};
    var foreign_vow: u64 = 0;
    cd.pancake_host_clear_last_error();
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cd.pancake_host_session_send(r_to_g.a, &introducer_ref, "introduce", 9, &foreign_args, foreign_args.len, &foreign_vow));
    var err_buf: [128]u8 = undefined;
    try std.testing.expect(cd.pancake_host_last_error(&err_buf, err_buf.len) > 0);

    // The token releases through the node to its real home: an op:gc-exports
    // rides the recipient-exporter peer, flushed by the pump.
    try expectOk(cd.pancake_host_ref_release(recipient, &token, 1));
    try pump(&hosts, &all_pairs, &dials, &watches);

    // The giftable row owns the shared ctx: its free runs exactly once, at
    // host release, no matter how many Ports projected the actor.
    try std.testing.expectEqual(@as(u32, 0), FreeFlag.runs);
    _ = cd.pancake_host_release(exporter);
    try std.testing.expectEqual(@as(u32, 1), FreeFlag.runs);
}

test "libpancake_host: a failed dial breaks the redeeming vow with the reason" {
    const exporter = try newHost(0x1e);
    defer _ = cd.pancake_host_release(exporter);
    const gifter = try newHost(0x16);
    defer _ = cd.pancake_host_release(gifter);
    const recipient = try newHost(0x1c);
    defer _ = cd.pancake_host_release(recipient);
    const hosts = [_]?*cd.PancakeHost{ exporter, gifter, recipient };
    var dials = Dials{};
    var watches = Watches{};

    const g_to_e = try openPair(&hosts, gifter, exporter, "127.0.0.1:7001", &dials, &watches);
    var widget_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(g_to_e.b, "widget", 6, widgetBehavior, null, null, &widget_local_ref));
    var widget = CapturedSettle{};
    var widget_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(g_to_e.a, "widget", 6, &widget_vow));
    watches.add(gifter, widget_vow, &widget);
    try pump(&hosts, &.{g_to_e}, &dials, &watches);
    const widget_token = try widget.requireRef();

    const r_to_g = try openPair(&hosts, recipient, gifter, "127.0.0.1:7002", &dials, &watches);
    var introducer_ctx = IntroducerCtx{ .widget = widget_token };
    var introducer_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(r_to_g.b, "introducer", 10, introducerBehavior, &introducer_ctx, null, &introducer_local_ref));
    var introducer = CapturedSettle{};
    var introducer_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(r_to_g.a, "introducer", 10, &introducer_vow));
    watches.add(recipient, introducer_vow, &introducer);
    try pump(&hosts, &.{ g_to_e, r_to_g }, &dials, &watches);
    const introducer_ref = try introducer.requireRef();

    var introduce_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(r_to_g.a, &introducer_ref, "introduce", 9, null, 0, &introduce_vow));
    var redeemed = CapturedSettle{};
    watches.add(recipient, introduce_vow, &redeemed);
    try pump(&hosts, &.{ g_to_e, r_to_g }, &dials, &watches);
    try std.testing.expectEqual(@as(usize, 1), dials.len);

    // The exporter is unreachable: the dial's failure breaks the vow, its
    // FAIL completion queued inside the report and drained right after.
    try expectOk(cd.pancake_host_dial_failed(recipient, dials.items[0].ticket, "exporter unreachable", 20));
    _ = try drainActions(&hosts, &dials, &watches);
    try std.testing.expect(redeemed.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_BREAK, redeemed.kind);
    try std.testing.expect(std.mem.indexOf(u8, redeemed.msg[0..redeemed.msg_len], "exporter unreachable") != null);
}

/// The reentry probe's shared state: the behavior below runs inside a served
/// turn and records whether every top-level verb refused and every
/// enqueueing verb succeeded.
const ReentryCtx = struct {
    host: ?*cd.PancakeHost = null,
    conn: ?*cd.PancakeHostSession = null,
    widget_local_ref: c.PancakeReference = .{ .id = 0 },
    watches: *Watches = undefined,
    ran: bool = false,
    all_refused: bool = false,
    enqueued_ok: bool = false,
    nested: CapturedSettle = .{},
};

/// From inside the callback window, every host-driving verb must refuse
/// (INVALID_ARGUMENT, or last-error for the void releases) and every
/// enqueueing verb must succeed, its effects landing at the unwind.
fn reentryBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.PancakeHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.PancakeArgument,
    args_len: usize,
    out_reply: *c.PancakeArgument,
) callconv(.c) i32 {
    _ = .{ turn, verb, verb_len, args, args_len };
    const rc: *ReentryCtx = @ptrCast(@alignCast(ctx.?));
    rc.ran = true;
    const inv = c.PANCAKE_ERR_INVALID_ARGUMENT;
    var ok = true;

    const garbage = "x";
    const borrowed: c.PancakeFrame = .{ .bytes = @constCast(garbage.ptr), .len = garbage.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
    ok = ok and cd.pancake_host_session_feed(rc.conn, &borrowed) == inv;
    ok = ok and cd.pancake_host_session_feed_bytes(rc.conn, garbage.ptr, garbage.len) == inv;
    var mf: c.PancakeManagedFrame = undefined;
    ok = ok and cd.pancake_host_session_take_outbound(rc.conn, &mf) == inv;
    var action: cd.PancakeHostAction = undefined;
    ok = ok and cd.pancake_host_next_action(rc.host, &action) == inv;
    ok = ok and cd.pancake_host_dialed(rc.host, 0, rc.conn) == inv;
    ok = ok and cd.pancake_host_dial_failed(rc.host, 0, "x", 1) == inv;
    ok = ok and cd.pancake_host_provide_gift_id(rc.host, 0, "x", 1) == inv;
    var new_conn: ?*cd.PancakeHostSession = null;
    ok = ok and cd.pancake_host_session_open_dialed_locator(rc.host, "tcp", 3, "d", 1, &new_conn) == inv;
    ok = ok and cd.pancake_host_session_open_accepted(rc.host, "tcp", 3, "d", 1, null, 0, &new_conn) == inv;
    var refused_ref: c.PancakeReference = .{ .id = 0 };
    ok = ok and cd.pancake_host_session_publish(rc.conn, "n", 1, widgetBehavior, null, null, &refused_ref) == inv;
    ok = ok and cd.pancake_host_session_spawn(rc.conn, widgetBehavior, null, null, &refused_ref) == inv;
    ok = ok and cd.pancake_host_publish(rc.host, "n", 1, widgetBehavior, null, null) == inv;
    var refused_vow: u64 = 0;
    ok = ok and cd.pancake_host_session_fetch(rc.conn, "n", 1, &refused_vow) == inv;
    ok = ok and cd.pancake_host_session_enliven(rc.conn, "n", 1, &refused_vow) == inv;
    ok = ok and cd.pancake_host_session_break_far_vows(rc.conn, "x", 1) == inv;
    // The void releases refuse through the last-error slot and keep the
    // handles alive.
    cd.pancake_host_clear_last_error();
    _ = cd.pancake_host_session_release(rc.conn);
    ok = ok and cd.pancake_host_last_error(null, 0) > 0;
    cd.pancake_host_clear_last_error();
    _ = cd.pancake_host_release(rc.host);
    ok = ok and cd.pancake_host_last_error(null, 0) > 0;
    rc.all_refused = ok;

    // The enqueueing verbs: a nested near send whose local vow is still live
    // inside this window, so a projection refuses NotPipelineable (a local
    // vow has no wire answer); the turn settles them at the unwind, and the
    // watch registered here routes the vow's queued completion.
    const near = rc.widget_local_ref;
    var vow: u64 = 0;
    var eok = cd.pancake_host_session_send(rc.conn, &near, "poke", 4, null, 0, &vow) == c.PANCAKE_OK;
    if (eok) rc.watches.add(rc.host, vow, &rc.nested);
    var projected: u64 = 0;
    eok = eok and cd.pancake_host_vow_index(rc.host, vow, 0, &projected) == inv;
    eok = eok and cd.pancake_host_session_tell(rc.conn, &near, "poke", 4, null, 0) == c.PANCAKE_OK;
    eok = eok and cd.pancake_host_session_set_exporter_location(rc.conn, null, 0) == c.PANCAKE_OK;
    rc.enqueued_ok = eok;

    out_reply.* = argStr("probed");
    return c.PANCAKE_OK;
}

test "libpancake_host: inside a callback every top-level verb refuses and every enqueueing verb lands at the unwind" {
    const client = try newHost(0x71);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0x72);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7001", &dials, &watches);

    var counter = Counter{};
    var widget_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_spawn(pair.b, widgetBehavior, &counter, null, &widget_local_ref));
    var rctx = ReentryCtx{ .host = server, .conn = pair.b, .widget_local_ref = widget_local_ref, .watches = &watches };
    var probe_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(pair.b, "probe", 5, reentryBehavior, &rctx, null, &probe_local_ref));

    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "probe", 5, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const probe_ref = try fetched.requireRef();

    var vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &probe_ref, "go", 2, null, 0, &vow));
    var settled = CapturedSettle{};
    watches.add(client, vow, &settled);
    try pump(&hosts, &.{pair}, &dials, &watches);

    try std.testing.expect(rctx.ran);
    try std.testing.expect(rctx.all_refused);
    try std.testing.expect(rctx.enqueued_ok);
    // The probe's own reply reached the caller, so the refusals broke nothing.
    try std.testing.expect(settled.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, settled.kind);
    try std.testing.expectEqualStrings("probed", settled.text[0..settled.text_len]);
    // The nested send and tell both landed at the unwind, and the nested
    // vow's settle fired.
    try std.testing.expect(rctx.nested.fired);
    try std.testing.expectEqualStrings("poked over the C surface", rctx.nested.text[0..rctx.nested.text_len]);
    try std.testing.expectEqual(@as(u32, 2), counter.pokes);
}

/// One direction's staging buffer for the feed_bytes shuttle: the encoded
/// frames awaiting their chunked presentation. The library owns the
/// unconsumed stream tail, so nothing carries over between rounds.
const BytePipe = struct {
    buf: [8192]u8 = undefined,
    len: usize = 0,
};

/// Drain `from`'s encoded frames into `pipe`, then feed them to `to` through
/// pancake_host_session_feed_bytes, presenting at most `chunk` bytes per
/// call so frames split at pathological boundaries, including mid-frame. The
/// library owns the tail, so every presented byte is consumed; the leading
/// empty feed resumes any frames the session held behind its handshake open.
fn shuttleBytes(from: ?*cd.PancakeHostSession, to: ?*cd.PancakeHostSession, pipe: *BytePipe, chunk: usize) !bool {
    try expectOk(cd.pancake_host_session_feed_bytes(to, null, 0));
    var moved = false;
    while (true) {
        var mf: c.PancakeManagedFrame = undefined;
        const rc = cd.pancake_host_session_take_outbound(from, &mf);
        if (rc == c.PANCAKE_ERR_WOULD_BLOCK) break;
        try expectOk(rc);
        defer c.pancake_managed_frame_release(&mf);
        try std.testing.expect(pipe.len + mf.len <= pipe.buf.len);
        @memcpy(pipe.buf[pipe.len..][0..mf.len], mf.bytes.?[0..mf.len]);
        pipe.len += mf.len;
        moved = true;
    }
    var offset: usize = 0;
    while (offset < pipe.len) {
        const n = @min(chunk, pipe.len - offset);
        try expectOk(cd.pancake_host_session_feed_bytes(to, pipe.buf[offset..].ptr, n));
        offset += n;
        moved = true;
    }
    pipe.len = 0;
    return moved;
}

/// `pump`, but every frame crosses as a chunked byte stream. Quiesces after
/// two consecutive no-progress rounds: the leading resume feeds can dispatch
/// session-held frames whose effects surface only on the following round.
fn pumpBytes(hosts: []const ?*cd.PancakeHost, pair: Pair, pipes: *[2]BytePipe, chunk: usize, dials: *Dials, watches: *Watches) !void {
    var rounds: usize = 0;
    var quiet: usize = 0;
    while (rounds < 128) : (rounds += 1) {
        var progressed = false;
        if (try shuttleBytes(pair.a, pair.b, &pipes[0], chunk)) progressed = true;
        if (try shuttleBytes(pair.b, pair.a, &pipes[1], chunk)) progressed = true;
        if (try drainActions(hosts, dials, watches)) progressed = true;
        if (progressed) {
            quiet = 0;
        } else {
            quiet += 1;
            if (quiet == 2) return;
        }
    }
    return error.PumpDidNotQuiesce;
}

test "libpancake_host: feed_bytes delimits a chunked byte stream end to end, both codecs" {
    const codecs = [_]u32{ c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CODEC_CAPNP };
    for (codecs, 0..) |codec, i| {
        const client = try newHostWith(@intCast(0x81 + 2 * i), codec);
        defer _ = cd.pancake_host_release(client);
        const server = try newHostWith(@intCast(0x82 + 2 * i), codec);
        defer _ = cd.pancake_host_release(server);
        var dials = Dials{};
        var watches = Watches{};
        const hosts = [_]?*cd.PancakeHost{ client, server };

        // Seven never divides a frame or a capnp word, so the keyed hellos
        // and every later frame arrive split mid-frame (and, for the
        // word-shaped codec, mid-word and unaligned).
        const chunk: usize = 7;
        var pipes = [_]BytePipe{ .{}, .{} };
        const designator = "127.0.0.1:7004";
        var accepted: ?*cd.PancakeHostSession = null;
        try expectOk(cd.pancake_host_session_open_accepted(server, "tcp", 3, designator.ptr, designator.len, null, 0, &accepted));
        var dialed: ?*cd.PancakeHostSession = null;
        try expectOk(cd.pancake_host_session_open_dialed_locator(client, "tcp", 3, designator.ptr, designator.len, &dialed));
        const pair = Pair{ .a = dialed, .b = accepted };
        try pumpBytes(&hosts, pair, &pipes, chunk, &dials, &watches);
        try std.testing.expect(cd.pancake_host_session_is_open(dialed) != 0);
        try std.testing.expect(cd.pancake_host_session_is_open(accepted) != 0);

        var counter = Counter{};
        var widget_local_ref: c.PancakeReference = .{ .id = 0 };
        try expectOk(cd.pancake_host_session_publish(pair.b, "widget", 6, widgetBehavior, &counter, null, &widget_local_ref));
        var fetched = CapturedSettle{};
        var fetched_vow: u64 = 0;
        try expectOk(cd.pancake_host_session_fetch(pair.a, "widget", 6, &fetched_vow));
        watches.add(client, fetched_vow, &fetched);
        try pumpBytes(&hosts, pair, &pipes, chunk, &dials, &watches);
        const widget_ref = try fetched.requireRef();

        var vow: u64 = 0;
        try expectOk(cd.pancake_host_session_send(pair.a, &widget_ref, "poke", 4, null, 0, &vow));
        var settled = CapturedSettle{};
        watches.add(client, vow, &settled);
        try pumpBytes(&hosts, pair, &pipes, chunk, &dials, &watches);
        try std.testing.expect(settled.fired);
        try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, settled.kind);
        try std.testing.expectEqualStrings("poked over the C surface", settled.text[0..settled.text_len]);
        try std.testing.expectEqual(@as(u32, 1), counter.pokes);
        // Nothing lingers in either inbox: the stream delimited exactly.
        try std.testing.expectEqual(@as(usize, 0), pipes[0].len);
        try std.testing.expectEqual(@as(usize, 0), pipes[1].len);
    }
}

test "libpancake_host: feed_bytes refuses an over-cap frame with the typed FRAME_TOO_LARGE and queues the abort" {
    // The receiver's cap is smaller than any keyed hello, so the partner's
    // first frame trips the cap-during-scan verdict.
    var tiny: ?*cd.PancakeHost = null;
    const tiny_seed = [_]u8{0x91} ** 32;
    try expectOk(cd.pancake_host_new(&tiny_seed, tiny_seed.len, 64, 1, c.PANCAKE_CODEC_SYRUP, 0, &tiny));
    defer _ = cd.pancake_host_release(tiny);
    const dialer = try newHost(0x92);
    defer _ = cd.pancake_host_release(dialer);

    const designator = "127.0.0.1:7005";
    var accepted: ?*cd.PancakeHostSession = null;
    try expectOk(cd.pancake_host_session_open_accepted(tiny, "tcp", 3, designator.ptr, designator.len, null, 0, &accepted));
    var dialed: ?*cd.PancakeHostSession = null;
    try expectOk(cd.pancake_host_session_open_dialed_locator(dialer, "tcp", 3, designator.ptr, designator.len, &dialed));

    var hello: c.PancakeManagedFrame = undefined;
    try expectOk(cd.pancake_host_session_take_outbound(dialed, &hello));
    defer c.pancake_managed_frame_release(&hello);
    try std.testing.expect(hello.len > 64);

    try std.testing.expectEqual(
        c.PANCAKE_ERR_FRAME_TOO_LARGE,
        cd.pancake_host_session_feed_bytes(accepted, hello.bytes, hello.len),
    );

    // The typed cause is retained locally and the loud abort is queued for
    // the partner, exactly the whole-frame feed's failure choreography:
    // deliver the refusing side's queued outbound (its own hello, then the
    // abort) and the partner retains the typed kind.
    var abort_info: c.PancakeLastAbort = undefined;
    try expectOk(cd.pancake_host_session_last_abort(accepted, &abort_info));
    try std.testing.expect(abort_info.has_kind != 0);
    while (true) {
        var out: c.PancakeManagedFrame = undefined;
        const rc = cd.pancake_host_session_take_outbound(accepted, &out);
        if (rc == c.PANCAKE_ERR_WOULD_BLOCK) break;
        try expectOk(rc);
        const borrowed: c.PancakeFrame = .{ .bytes = out.bytes, .len = out.len, .shape = out.shape };
        _ = cd.pancake_host_session_feed(dialed, &borrowed);
        c.pancake_managed_frame_release(&out);
    }
    // An over-cap frame projects the resource-exhaustion abort kind.
    var kind_name: ?[*]const u8 = null;
    var kind_name_len: usize = 0;
    try expectOk(cd.pancake_host_session_partner_abort(dialed, &kind_name, &kind_name_len, null, 0, null));
    try std.testing.expectEqualStrings("ResourceExhausted", kind_name.?[0..kind_name_len]);
}

test "libpancake_host: break_far_vows fires a parked fetch broken, and the exporter location override is accepted" {
    const client = try newHost(0x51);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0x52);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7001", &dials, &watches);

    // Gives whose exporter is this connection would name the override; empty
    // clears it back to the session record. The boundary takes a Syrup
    // ocapn-peer record (not a URI) — the same bytes encode_peer_locator returns.
    const pancake = @import("pancake");
    const override_loc = try pancake.ocapn.model.uri.parsePeer(std.testing.allocator, "ocapn://192.0.2.1%3A7009.tcp");
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, override_loc);
    const override = try pancake.ocapn.engine.encodePeerLocatorRecord(std.testing.allocator, override_loc);
    defer std.testing.allocator.free(override);
    try expectOk(cd.pancake_host_session_set_exporter_location(pair.b, override.ptr, override.len));
    // A URI must fail loud — that was the footgun that spliced into a signed give.
    const uri = "ocapn://192.0.2.1%3A7009.tcp";
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cd.pancake_host_session_set_exporter_location(pair.b, uri.ptr, uri.len));
    try expectOk(cd.pancake_host_session_set_exporter_location(pair.b, null, 0));

    // A fetch whose resolve never arrives: the transport dies, the break
    // queues the vow's FAIL completion inside the call, and the drain routes
    // it with the reason.
    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "widget", 6, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try std.testing.expect(!fetched.fired);
    try expectOk(cd.pancake_host_session_break_far_vows(pair.a, "transport gone", 14));
    _ = try drainActions(&hosts, &dials, &watches);
    try std.testing.expect(fetched.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_BREAK, fetched.kind);
    try std.testing.expectEqualStrings("transport gone", fetched.msg[0..fetched.msg_len]);
}

const NestedEchoCtx = struct { self_ref: c.PancakeReference = .{ .id = 0 } };

/// The inner behavior of the composed-forward regression: before reading its
/// own args it fires a nested enqueueing verb whose marshalling shares the
/// instance's arg scratch, then echoes args[0]. If the nested marshal reset
/// that scratch, the echoed bytes would be the nested verb's payload, not the
/// forwarder's.
fn nestedEchoBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.PancakeHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.PancakeArgument,
    args_len: usize,
    out_reply: *c.PancakeArgument,
) callconv(.c) i32 {
    const ec: *NestedEchoCtx = @ptrCast(@alignCast(ctx.?));
    const v = verb[0..verb_len];
    if (std.mem.eql(u8, v, "noop")) {
        out_reply.* = argBase();
        return c.PANCAKE_OK;
    }
    if (!std.mem.eql(u8, v, "echo")) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    // The nested verb's payload has the exact shape and byte length of the
    // forwarded payload, so a scratch reset would land these bytes exactly
    // where the live args' bytes sit.
    const clobber = [_]c.PancakeArgument{argStr("XXXXXXXXXXXXXXXXXXXX")};
    const self_ref = ec.self_ref;
    if (cd.pancake_host_turn_tell(turn, &self_ref, "noop", 4, &clobber, clobber.len) != c.PANCAKE_OK)
        return c.PANCAKE_ERR_INTERNAL;
    if (args_len != 1 or args.?[0].kind != c.PANCAKE_ARG_STRING) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    out_reply.* = args.?[0];
    return c.PANCAKE_OK;
}

const ForwarderCtx = struct { target_ref: c.PancakeReference };

/// The outer behavior: forwards a fresh payload to the echo object through
/// turn_forward, marshalling that payload through the shared arg scratch.
fn forwarderBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.PancakeHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.PancakeArgument,
    args_len: usize,
    out_reply: *c.PancakeArgument,
) callconv(.c) i32 {
    _ = .{ args, args_len };
    const fc: *ForwarderCtx = @ptrCast(@alignCast(ctx.?));
    if (!std.mem.eql(u8, verb[0..verb_len], "relay")) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    const target = fc.target_ref;
    const payload = [_]c.PancakeArgument{argStr("the payload survives")};
    return cd.pancake_host_turn_forward(turn, &target, "echo", 4, &payload, payload.len, out_reply);
}

test "libpancake_host: a composed forward's inner behavior keeps its args across a nested verb" {
    const client = try newHost(0xa1);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0xa2);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7001", &dials, &watches);

    var echo_ctx = NestedEchoCtx{};
    var echo_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_spawn(pair.b, nestedEchoBehavior, &echo_ctx, null, &echo_local_ref));
    echo_ctx.self_ref = echo_local_ref;
    var fwd_ctx = ForwarderCtx{ .target_ref = echo_local_ref };
    var fwd_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(pair.b, "relay", 5, forwarderBehavior, &fwd_ctx, null, &fwd_local_ref));

    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "relay", 5, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const relay_ref = try fetched.requireRef();

    // The forwarded answer must carry the forwarder's own payload, proving
    // the inner behavior's live args survived its nested tell.
    var vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &relay_ref, "relay", 5, null, 0, &vow));
    var settled = CapturedSettle{};
    watches.add(client, vow, &settled);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(settled.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, settled.kind);
    try std.testing.expectEqualStrings("the payload survives", settled.text[0..settled.text_len]);

    // The sharp edge: a NEAR send runs the forwarder in a local-origin turn,
    // whose turn_forward runs the echo object synchronously with the
    // forwarded args BORROWED from the shared arg scratch — so the inner
    // behavior's nested verb must bump that scratch, not reset it under its
    // own live args. The local vow settles inside the call; its completion
    // waits on the action queue for the watch registered right after.
    const fwd_ref = fwd_local_ref;
    var near_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.b, &fwd_ref, "relay", 5, null, 0, &near_vow));
    var near_settled = CapturedSettle{};
    watches.add(server, near_vow, &near_settled);
    _ = try drainActions(&hosts, &dials, &watches);
    try std.testing.expect(near_settled.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, near_settled.kind);
    try std.testing.expectEqualStrings("the payload survives", near_settled.text[0..near_settled.text_len]);
}

test "libpancake_host: feed_bytes stops at the session-open transition so a coalesced tail waits for post-open setup" {
    const client = try newHost(0xb1);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0xb2);
    defer _ = cd.pancake_host_release(server);

    const designator = "127.0.0.1:7007";
    var accepted: ?*cd.PancakeHostSession = null;
    try expectOk(cd.pancake_host_session_open_accepted(server, "tcp", 3, designator.ptr, designator.len, null, 0, &accepted));
    var dialed: ?*cd.PancakeHostSession = null;
    try expectOk(cd.pancake_host_session_open_dialed_locator(client, "tcp", 3, designator.ptr, designator.len, &dialed));

    // Open the client side first: feed it the server's hello whole.
    var server_hello: c.PancakeManagedFrame = undefined;
    try expectOk(cd.pancake_host_session_take_outbound(accepted, &server_hello));
    const borrowed_hello: c.PancakeFrame = .{ .bytes = server_hello.bytes, .len = server_hello.len, .shape = server_hello.shape };
    try expectOk(cd.pancake_host_session_feed(dialed, &borrowed_hello));
    c.pancake_managed_frame_release(&server_hello);
    try std.testing.expect(cd.pancake_host_session_is_open(dialed) != 0);

    // The client fetches before the server has seen a single byte: its
    // outbound is now [hello][fetch deliver, ...], the coalesced buffer a
    // batching transport hands the server in one read.
    var fetch_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(dialed, "widget", 6, &fetch_vow));
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    var frames: usize = 0;
    while (true) {
        var mf: c.PancakeManagedFrame = undefined;
        const rc = cd.pancake_host_session_take_outbound(dialed, &mf);
        if (rc == c.PANCAKE_ERR_WOULD_BLOCK) break;
        try expectOk(rc);
        defer c.pancake_managed_frame_release(&mf);
        @memcpy(buf[len..][0..mf.len], mf.bytes.?[0..mf.len]);
        len += mf.len;
        frames += 1;
    }
    try std.testing.expect(frames >= 2);

    // One feed of the whole buffer dispatches exactly the hello: the session
    // just opened, and the frames coalesced behind it wait in the session's
    // own tail — the fetch has not answered, because its target is not
    // published yet.
    try expectOk(cd.pancake_host_session_feed_bytes(accepted, &buf, len));
    try std.testing.expect(cd.pancake_host_session_is_open(accepted) != 0);

    // The embedder acts on the fresh session — publish — then resumes the
    // held tail with an empty feed, and the fetch that rode behind the hello
    // answers correctly.
    var counter = Counter{};
    var widget_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(accepted, "widget", 6, widgetBehavior, &counter, null, &widget_local_ref));
    try expectOk(cd.pancake_host_session_feed_bytes(accepted, null, 0));

    var dials = Dials{};
    var watches = Watches{};
    var fetched = CapturedSettle{};
    watches.add(client, fetch_vow, &fetched);
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = Pair{ .a = dialed, .b = accepted };
    try pump(&hosts, &.{pair}, &dials, &watches);
    _ = try fetched.requireRef();
}

test "libpancake_host: keyed-tcp accept signs locator with direct-addresses; empty hint fails" {
    const pancake = @import("pancake");
    const crypto = pancake.foundation.crypto;

    const seed = [_]u8{0x5c} ** 32;
    const designator = crypto.SecretKey.fromSeed(seed).publicKey().toDesignator();
    const hint = "127.0.0.1:9000";

    var host: ?*cd.PancakeHost = null;
    try expectOk(cd.pancake_host_new(&seed, seed.len, frame_cap, 1, c.PANCAKE_CODEC_SYRUP, 0, &host));
    defer _ = cd.pancake_host_release(host);

    // Keyed-tcp requires a direct-addresses hint (TCP has no discovery).
    var refused: ?*cd.PancakeHostSession = null;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cd.pancake_host_session_open_accepted(host, "keyed-tcp", 9, &designator, designator.len, null, 0, &refused),
    );

    var accepted: ?*cd.PancakeHostSession = null;
    try expectOk(cd.pancake_host_session_open_accepted(
        host,
        "keyed-tcp",
        9,
        &designator,
        designator.len,
        hint.ptr,
        hint.len,
        &accepted,
    ));
    defer _ = cd.pancake_host_session_release(accepted);

    // The signed hello carries the hint entry name and the bound address.
    var mf: c.PancakeManagedFrame = undefined;
    try expectOk(cd.pancake_host_session_take_outbound(accepted, &mf));
    defer c.pancake_managed_frame_release(&mf);
    const bytes = mf.bytes.?[0..mf.len];
    try std.testing.expect(std.mem.indexOf(u8, bytes, "direct-addresses") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, hint) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, designator[0..]) != null);
}

// ── Dial / accept planner (pancake_host_plan_dial / _plan_accept) ────────────
//
// The C wrapper over driver_core.planDial / planAccept: the transport dispatch,
// designator validation, host:port resolution, and reachability decision the
// bindings share instead of re-expressing. The pure logic is exhaustively
// tested in test/driver/dial_plan_test.zig; these lock the C marshalling — the
// posture-policy mapping, the borrowed views, and the typed error code.

const key64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn planDialC(
    transport: []const u8,
    designator: []const u8,
    hint: []const u8,
    policy: u32,
    posture_value: u32,
    out: *cd.PancakeDialPlan,
) i32 {
    return cd.pancake_host_plan_dial(
        transport.ptr,
        transport.len,
        designator.ptr,
        designator.len,
        if (hint.len == 0) null else hint.ptr,
        hint.len,
        policy,
        posture_value,
        out,
    );
}

test "plan_dial C: tcp resolves the designator to host:port" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("tcp", "127.0.0.1:9000", "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_SHAPE_HOST_PORT, plan.shape);
    try std.testing.expectEqualStrings("127.0.0.1", plan.host.?[0..plan.host_len]);
    try std.testing.expectEqual(@as(u16, 9000), plan.port);
}

test "plan_dial C: keyed-tcp resolves host:port off the hint, no hint is a typed refusal" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("keyed-tcp", key64, "10.0.0.5:8000", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_SHAPE_HOST_PORT, plan.shape);
    try std.testing.expectEqualStrings("10.0.0.5", plan.host.?[0..plan.host_len]);
    try std.testing.expectEqual(@as(u16, 8000), plan.port);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, planDialC("keyed-tcp", key64, "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
}

test "plan_dial C: iroh redeem picks direct with a hint, configured without" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("iroh", key64, "1.2.3.4:5", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_SHAPE_PEER_ID, plan.shape);
    try std.testing.expectEqual(cd.PANCAKE_DIAL_REACH_DIRECT, plan.reach_kind);
    try std.testing.expectEqualStrings("1.2.3.4:5", plan.addresses.?[0..plan.addresses_len]);
    try expectOk(planDialC("iroh", key64, "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_REACH_CONFIGURED, plan.reach_kind);
}

test "plan_dial C: iroh connect carries the explicit posture, none is a typed refusal" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("iroh", key64, "", cd.PANCAKE_DIAL_POSTURE_EXPLICIT, 2, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_REACH_EXPLICIT, plan.reach_kind);
    try std.testing.expectEqual(@as(u32, 2), plan.reach_value);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, planDialC("iroh", key64, "", cd.PANCAKE_DIAL_POSTURE_EXPLICIT_NONE, 0, &plan));
}

test "plan_dial C: an unknown transport is a typed refusal" {
    var plan: cd.PancakeDialPlan = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, planDialC("x-nope", "whatever", "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
}

test "plan_accept C: tcp signs the accepted address; keyed-tcp signs the key with the address as hint" {
    var plan: cd.PancakeAcceptPlan = undefined;
    try expectOk(cd.pancake_host_plan_accept("tcp", 3, null, 0, "127.0.0.1:5000", 14, &plan));
    try std.testing.expectEqualStrings("127.0.0.1:5000", plan.designator.?[0..plan.designator_len]);
    try std.testing.expectEqual(@as(usize, 0), plan.direct_addresses_hint_len);

    try expectOk(cd.pancake_host_plan_accept("keyed-tcp", 9, key64.ptr, key64.len, "127.0.0.1:6000", 14, &plan));
    try std.testing.expectEqualStrings(key64, plan.designator.?[0..plan.designator_len]);
    try std.testing.expectEqualStrings("127.0.0.1:6000", plan.direct_addresses_hint.?[0..plan.direct_addresses_hint_len]);
}

test "plan_dial C: webrtc produces a signaling shape with any posture" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("webrtc", key64, "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_SHAPE_SIGNALING, plan.shape);
}

test "plan_dial C: webrtc ignores a direct-addresses hint" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("webrtc", key64, "1.2.3.4:5", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_SHAPE_SIGNALING, plan.shape);
}

test "plan_dial C: webrtc non-key designator is a typed refusal" {
    var plan: cd.PancakeDialPlan = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, planDialC("webrtc", "not-a-key", "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
}

test "libpancake_host: host_dialed refuses a session belonging to another host" {
    const dialer = try newHost(0x21);
    defer _ = cd.pancake_host_release(dialer);
    const acceptor = try newHost(0x22);
    defer _ = cd.pancake_host_release(acceptor);
    const stranger = try newHost(0x23);
    defer _ = cd.pancake_host_release(stranger);

    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ dialer, acceptor };
    const pair = try openPair(&hosts, dialer, acceptor, "127.0.0.1:7011", &dials, &watches);
    defer _ = cd.pancake_host_session_release(pair.a);
    defer _ = cd.pancake_host_session_release(pair.b);

    // A ticket is a plain integer and a session is an opaque pointer, so
    // nothing about the pair says they come from the same host. Answering one
    // host's dial with another host's session would seat that connection in a
    // node that never dialed it.
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cd.pancake_host_dialed(stranger, 1, pair.a),
    );

    // The refusal is about the host, not the ticket: the same unknown ticket on
    // the session's own host is the documented no-op success.
    try expectOk(cd.pancake_host_dialed(dialer, 1, pair.a));
}
