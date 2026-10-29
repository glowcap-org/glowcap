//! Behaviors and captures the host suite publishes: the poke-counting widget,
//! typed and inline-capability captures, the introducer, caretaker, factory,
//! and kitchen, shared by every file in this directory.

const std = @import("std");

// The shared C-ABI vocabulary (frame/argument types, codes, managed-frame
// release) is reused from the ocapn archive by layout; the byte-fed host
// family is `libglowcap_host`.
const c = @import("c_abi");
const cd = @import("c_abi_host");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const stream_framing = glowcap.foundation.stream_framing;
const harness = @import("harness.zig");
const argInt = harness.argInt;
const argStr = harness.argStr;
const argRef = harness.argRef;
const argBase = harness.argBase;

// ── Behaviors and captures ───────────────────────────────────────────────────

pub const Counter = struct { pokes: u32 = 0 };

/// The served object: counts pokes and replies with a fixed string.
pub fn widgetBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.GlowcapHostTurn,
    selector: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const c.GlowcapArgument,
    args_len: usize,
    out_reply: *c.GlowcapArgument,
) callconv(.c) i32 {
    const verb = selector orelse return @import("c_abi_shared").GLOWCAP_ERR_BROKEN;
    _ = .{ turn, args, args_len };
    if (!std.mem.eql(u8, verb[0..verb_len], "poke")) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (ctx) |p| {
        const counter: *Counter = @ptrCast(@alignCast(p));
        counter.pokes += 1;
    }
    out_reply.* = argStr("poked over the C surface");
    return c.GLOWCAP_OK;
}

pub const TypedCapture = struct {
    seen: bool = false,
    nested_ref: c.GlowcapReference = .{ .id = 0 },
};

pub const InlineCapabilityCapture = struct {
    seen: bool = false,
    refs: [2]c.GlowcapReference = .{ .{ .id = 0 }, .{ .id = 0 } },
};

pub fn inlineCapabilityBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.GlowcapHostTurn,
    selector: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const c.GlowcapArgument,
    args_len: usize,
    out_reply: *c.GlowcapArgument,
) callconv(.c) i32 {
    const verb = selector orelse return @import("c_abi_shared").GLOWCAP_ERR_BROKEN;
    _ = turn;
    if (!std.mem.eql(u8, verb[0..verb_len], "accept") or args_len != 2)
        return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    const values = args orelse return c.GLOWCAP_ERR_NULL_POINTER;
    const tagged = values[0];
    const structured = values[1];
    if (tagged.kind != c.GLOWCAP_ARG_TAGGED or tagged.items == null or tagged.items_len != 1)
        return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (tagged.items.?[0].kind != c.GLOWCAP_ARG_REFERENCE)
        return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (structured.kind != c.GLOWCAP_ARG_STRUCT or structured.items == null or structured.items_len != 2)
        return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (structured.items.?[0].kind != c.GLOWCAP_ARG_STRING or
        structured.items.?[1].kind != c.GLOWCAP_ARG_REFERENCE)
        return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    const capture: *InlineCapabilityCapture = @ptrCast(@alignCast(ctx.?));
    capture.seen = true;
    capture.refs = .{
        tagged.items.?[0].reference,
        structured.items.?[1].reference,
    };
    out_reply.* = argStr("inline capabilities arrived");
    return c.GLOWCAP_OK;
}

pub fn typedBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.GlowcapHostTurn,
    selector: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const c.GlowcapArgument,
    args_len: usize,
    out_reply: *c.GlowcapArgument,
) callconv(.c) i32 {
    const verb = selector orelse return @import("c_abi_shared").GLOWCAP_ERR_BROKEN;
    _ = turn;
    if (!std.mem.eql(u8, verb[0..verb_len], "typed") or args_len != 7) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    const values = args orelse return c.GLOWCAP_ERR_NULL_POINTER;
    const set = values[0];
    const tagged = values[1];
    const keyword = values[2];
    const big = values[3];
    const structured = values[4];
    const error_value = values[5];
    const integers = values[6];
    if (set.kind != c.GLOWCAP_ARG_SET or set.items_len != 2 or set.items == null) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (set.items.?[0].kind != c.GLOWCAP_ARG_INTEGER or set.items.?[0].integer != 1) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (set.items.?[1].kind != c.GLOWCAP_ARG_INTEGER or set.items.?[1].integer != 2) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (tagged.kind != c.GLOWCAP_ARG_TAGGED or tagged.bytes == null or tagged.items == null or tagged.items_len != 1) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (!std.mem.eql(u8, tagged.bytes.?[0..tagged.bytes_len], "Point")) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (tagged.items.?[0].kind != c.GLOWCAP_ARG_REFERENCE or tagged.items.?[0].reference.id == 0) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (keyword.kind != c.GLOWCAP_ARG_KEYWORD or keyword.bytes == null) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (!std.mem.eql(u8, keyword.bytes.?[0..keyword.bytes_len], "color")) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (big.kind != c.GLOWCAP_ARG_BIG_INTEGER or big.boolean != 1 or big.bytes == null) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (!std.mem.eql(u8, big.bytes.?[0..big.bytes_len], "1267650600228229401496703205376")) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (structured.kind != c.GLOWCAP_ARG_STRUCT or structured.items == null or structured.items_len != 4) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    const fields = structured.items.?;
    if (fields[0].kind != c.GLOWCAP_ARG_STRING or !std.mem.eql(u8, fields[0].bytes.?[0..fields[0].bytes_len], "name")) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (fields[1].kind != c.GLOWCAP_ARG_STRING or !std.mem.eql(u8, fields[1].bytes.?[0..fields[1].bytes_len], "widget")) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (fields[2].kind != c.GLOWCAP_ARG_STRING or !std.mem.eql(u8, fields[2].bytes.?[0..fields[2].bytes_len], "target")) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (fields[3].kind != c.GLOWCAP_ARG_REFERENCE or fields[3].reference.id != tagged.items.?[0].reference.id) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (error_value.kind != c.GLOWCAP_ARG_ERROR or error_value.bytes == null or
        !std.mem.eql(u8, error_value.bytes.?[0..error_value.bytes_len], "typed failure value"))
        return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    // A run of integers lent by the sender arrives as the list it means.
    if (integers.kind != c.GLOWCAP_ARG_LIST or integers.items_len != 3 or integers.items == null) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    for (integers.items.?[0..3], [_]i64{ 7, -8, 9 }) |item, word| {
        if (item.kind != c.GLOWCAP_ARG_INTEGER or item.integer != word) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    const capture: *TypedCapture = @ptrCast(@alignCast(ctx.?));
    capture.seen = true;
    capture.nested_ref = tagged.items.?[0].reference;
    out_reply.* = error_value;
    return c.GLOWCAP_OK;
}

pub const IntroducerCtx = struct { widget: c.GlowcapReference };

/// The gifter's introducer: replies with the foreign capability it fetched.
/// The host's own origination turns that reply into a signed give.
pub fn introducerBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.GlowcapHostTurn,
    selector: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const c.GlowcapArgument,
    args_len: usize,
    out_reply: *c.GlowcapArgument,
) callconv(.c) i32 {
    const verb = selector orelse return @import("c_abi_shared").GLOWCAP_ERR_BROKEN;
    _ = .{ turn, args, args_len };
    if (!std.mem.eql(u8, verb[0..verb_len], "introduce")) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    const ic: *IntroducerCtx = @ptrCast(@alignCast(ctx.?));
    out_reply.* = argRef(ic.widget);
    return c.GLOWCAP_OK;
}

pub const CaretakerCtx = struct { target_ref: c.GlowcapReference };

/// A forwarding proxy: "poke" forwards this turn's call (and answer) to the
/// wrapped local object. "kick" pokes it twice through the turn's own send and
/// tell verbs and replies void itself.
pub fn caretakerBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.GlowcapHostTurn,
    selector: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const c.GlowcapArgument,
    args_len: usize,
    out_reply: *c.GlowcapArgument,
) callconv(.c) i32 {
    const verb = selector orelse return @import("c_abi_shared").GLOWCAP_ERR_BROKEN;
    const cc: *CaretakerCtx = @ptrCast(@alignCast(ctx.?));
    const target = cc.target_ref;
    if (std.mem.eql(u8, verb[0..verb_len], "poke")) {
        return cd.glowcap_host_turn_forward(turn, &target, verb, verb_len, args, args_len, out_reply);
    }
    if (std.mem.eql(u8, verb[0..verb_len], "kick")) {
        var vow: u64 = 0;
        if (cd.glowcap_host_turn_send(turn, &target, "poke", 4, null, 0, &vow) != c.GLOWCAP_OK) return c.GLOWCAP_ERR_INTERNAL;
        if (cd.glowcap_host_turn_tell(turn, &target, "poke", 4, null, 0) != c.GLOWCAP_OK) return c.GLOWCAP_ERR_INTERNAL;
        out_reply.* = argBase();
        return c.GLOWCAP_OK;
    }
    return c.GLOWCAP_ERR_INVALID_ARGUMENT;
}

/// `relay(target)`: forward `poke` to the capability the caller passed, so a
/// promise passed as a capability is exercised by the receiving side.
pub fn relayBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.GlowcapHostTurn,
    selector: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const c.GlowcapArgument,
    args_len: usize,
    out_reply: *c.GlowcapArgument,
) callconv(.c) i32 {
    const verb = selector orelse return @import("c_abi_shared").GLOWCAP_ERR_BROKEN;
    _ = ctx;
    if (!std.mem.eql(u8, verb[0..verb_len], "relay") or args_len != 1) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    const values = args orelse return c.GLOWCAP_ERR_NULL_POINTER;
    if (values[0].kind != c.GLOWCAP_ARG_REFERENCE) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    const target = values[0].reference;
    return cd.glowcap_host_turn_forward(turn, &target, "poke", 4, null, 0, out_reply);
}

pub const FactoryCtx = struct {
    counter: *Counter,
    expected_session: ?*cd.GlowcapHostSession,
    saw_expected_session: bool = false,
};

/// A served factory: "make" spawns a fresh widget mid-turn (the turn-time
/// spawn) and replies with its NEAR reference. "deny" refuses with a
/// caller-supplied diagnostic through turn_break instead of a bare non-OK.
pub fn factoryBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.GlowcapHostTurn,
    selector: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const c.GlowcapArgument,
    args_len: usize,
    out_reply: *c.GlowcapArgument,
) callconv(.c) i32 {
    const verb = selector orelse return @import("c_abi_shared").GLOWCAP_ERR_BROKEN;
    _ = .{ args, args_len };
    const factory: *FactoryCtx = @ptrCast(@alignCast(ctx.?));
    var ingress: ?*cd.GlowcapHostSession = null;
    if (cd.glowcap_host_turn_session(turn, &ingress) != c.GLOWCAP_OK or ingress != factory.expected_session)
        return c.GLOWCAP_ERR_INTERNAL;
    factory.saw_expected_session = true;
    if (std.mem.eql(u8, verb[0..verb_len], "make")) {
        var spawned_ref: c.GlowcapReference = .{ .id = 0 };
        if (cd.glowcap_host_turn_spawn(turn, widgetBehavior, factory.counter, null, &spawned_ref) != c.GLOWCAP_OK)
            return c.GLOWCAP_ERR_INTERNAL;
        out_reply.* = argRef(spawned_ref);
        return c.GLOWCAP_OK;
    }
    if (std.mem.eql(u8, verb[0..verb_len], "deny")) {
        if (cd.glowcap_host_turn_break(turn, "Attenuated", 10) != c.GLOWCAP_OK)
            return c.GLOWCAP_ERR_INTERNAL;
        return c.GLOWCAP_OK;
    }
    return c.GLOWCAP_ERR_INVALID_ARGUMENT;
}

const kitchen_pair_items = [_]c.GlowcapArgument{ argInt(11), argInt(22) };

const kitchen_boxed_items = [_]c.GlowcapArgument{argInt(7)};

pub const KitchenCtx = struct { widget_local_ref: c.GlowcapReference };

/// The pipelining fixture: "make" replies with a capability to the widget,
/// "pair" with a two-element list, "boxed" with a single-value Tagged.
pub fn kitchenBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.GlowcapHostTurn,
    selector: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const c.GlowcapArgument,
    args_len: usize,
    out_reply: *c.GlowcapArgument,
) callconv(.c) i32 {
    const verb = selector orelse return @import("c_abi_shared").GLOWCAP_ERR_BROKEN;
    _ = .{ turn, args, args_len };
    const kc: *KitchenCtx = @ptrCast(@alignCast(ctx.?));
    const v = verb[0..verb_len];
    if (std.mem.eql(u8, v, "make")) {
        out_reply.* = argRef(kc.widget_local_ref);
        return c.GLOWCAP_OK;
    }
    if (std.mem.eql(u8, v, "pair")) {
        var reply = argBase();
        reply.kind = c.GLOWCAP_ARG_LIST;
        reply.items = &kitchen_pair_items;
        reply.items_len = kitchen_pair_items.len;
        out_reply.* = reply;
        return c.GLOWCAP_OK;
    }
    if (std.mem.eql(u8, v, "boxed")) {
        var reply = argBase();
        reply.kind = c.GLOWCAP_ARG_TAGGED;
        reply.bytes = "box";
        reply.bytes_len = 3;
        reply.items = &kitchen_boxed_items;
        reply.items_len = kitchen_boxed_items.len;
        out_reply.* = reply;
        return c.GLOWCAP_OK;
    }
    return c.GLOWCAP_ERR_INVALID_ARGUMENT;
}
