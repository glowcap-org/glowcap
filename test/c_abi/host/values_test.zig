//! Typed values across the Host ABI: uncommon scalars, big integers, and a
//! nested capability crossing the C surface both directions intact.

const std = @import("std");
const c = @import("c_abi");
const shared = @import("c_abi_shared");
const cd = @import("c_abi_host");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;

test "C integer runs and lists share marshal depth for borrowed and owned values" {
    const Refused = struct {
        fn reference(_: void, _: shared.GlowcapReference) !model.Reference {
            return error.UnexpectedReference;
        }
        fn capability(_: void, _: shared.GlowcapReference) !glowcap.driver.core.Capability {
            return error.UnexpectedReference;
        }
    };
    const words = [_]i64{7};
    const integer = argInt(7);
    var run = argBase();
    run.kind = c.GLOWCAP_ARG_INTEGERS;
    run.bytes = @ptrCast(&words);
    run.bytes_len = @sizeOf(@TypeOf(words));
    var list = argBase();
    list.kind = c.GLOWCAP_ARG_LIST;
    list.items = @ptrCast(&integer);
    list.items_len = 1;
    var empty_run = run;
    empty_run.bytes_len = 0;
    var empty_list = list;
    empty_list.items_len = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    inline for (.{ false, true }) |own_bytes| {
        for ([_]shared.GlowcapArgument{ run, list, empty_run, empty_list }, 0..) |arg, shape| {
            for ([_]usize{ shared.max_marshal_depth - 1, shared.max_marshal_depth }) |depth| {
                const plain = shared.argumentFromCWith(anyerror, {}, Refused.reference, arena.allocator(), arg, depth, own_bytes);
                const host_value = shared.valuesFromCWith(glowcap.driver.core.Value, anyerror, {}, Refused.capability, arena.allocator(), @ptrCast(&arg), 1, depth, own_bytes);
                if (depth == shared.max_marshal_depth and shape < 2) {
                    try std.testing.expectError(error.UnsupportedValue, plain);
                    try std.testing.expectError(error.UnsupportedValue, host_value);
                } else {
                    _ = try plain;
                    _ = try host_value;
                }
            }
        }
    }
}
const stream_framing = glowcap.foundation.stream_framing;

const harness = @import("harness.zig");
const behaviors = @import("behaviors.zig");
const argBase = harness.argBase;
const argInt = harness.argInt;
const argStr = harness.argStr;
const argRef = harness.argRef;
const frame_cap = harness.frame_cap;
const close_cancel = harness.close_cancel;
const close_finish_unbounded = harness.close_finish_unbounded;
const closeFinish = harness.closeFinish;
const expectOk = harness.expectOk;
const hostSeed = harness.hostSeed;
const openDialed = harness.openDialed;
const openAccepted = harness.openAccepted;
const openAcceptedKeyed = harness.openAcceptedKeyed;
const newHostWithProfile = harness.newHostWithProfile;
const newHostWithFeatures = harness.newHostWithFeatures;
const newHostWith = harness.newHostWith;
const newHost = harness.newHost;
const locatorView = harness.locatorView;
const setAdvertisedLocator = harness.setAdvertisedLocator;
const ensureAdvertisedLocator = harness.ensureAdvertisedLocator;
const tcpLocator = harness.tcpLocator;
const Pair = harness.Pair;
const takeOutbound = harness.takeOutbound;
const ParkedDial = harness.ParkedDial;
const Dials = harness.Dials;
const shuttle = harness.shuttle;
const CapturedSettle = harness.CapturedSettle;
const Watches = harness.Watches;
const drainActions = harness.drainActions;
const pump = harness.pump;
const openPair = harness.openPair;
const Counter = behaviors.Counter;
const widgetBehavior = behaviors.widgetBehavior;
const TypedCapture = behaviors.TypedCapture;
const InlineCapabilityCapture = behaviors.InlineCapabilityCapture;
const inlineCapabilityBehavior = behaviors.inlineCapabilityBehavior;
const typedBehavior = behaviors.typedBehavior;
const IntroducerCtx = behaviors.IntroducerCtx;
const introducerBehavior = behaviors.introducerBehavior;
const CaretakerCtx = behaviors.CaretakerCtx;
const caretakerBehavior = behaviors.caretakerBehavior;
const FactoryCtx = behaviors.FactoryCtx;
const factoryBehavior = behaviors.factoryBehavior;
const kitchen_pair_items = behaviors.kitchen_pair_items;
const kitchen_boxed_items = behaviors.kitchen_boxed_items;
const KitchenCtx = behaviors.KitchenCtx;
const kitchenBehavior = behaviors.kitchenBehavior;

test "libglowcap_host: uncommon typed values and a nested capability cross the Host ABI" {
    const client = try newHost(0x37);
    defer _ = cd.glowcap_host_release(client);
    const server = try newHost(0x38);
    defer _ = cd.glowcap_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.GlowcapHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7004", &dials, &watches);
    defer _ = cd.glowcap_host_session_release(pair.a);
    defer _ = cd.glowcap_host_session_release(pair.b);

    var capture = TypedCapture{};
    var local_target: c.GlowcapReference = .{ .id = 0 };
    try expectOk(cd.glowcap_host_session_publish(pair.b, "typed", 5, typedBehavior, &capture, null, &local_target));
    var fetched = CapturedSettle{};
    var fetch_vow: u64 = 0;
    try expectOk(cd.glowcap_host_session_fetch(pair.a, "typed", 5, &fetch_vow));
    watches.add(client, fetch_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const target = try fetched.requireRef();

    // A local client actor nested inside Tagged proves the complete value walk
    // lowers references while preserving uncommon pass-by-copy arms.
    var nested: c.GlowcapReference = .{ .id = 0 };
    try expectOk(cd.glowcap_host_session_spawn(pair.a, widgetBehavior, null, null, &nested));
    const set_items = [_]c.GlowcapArgument{ argInt(1), argInt(2) };
    var set = argBase();
    set.kind = c.GLOWCAP_ARG_SET;
    set.items = set_items[0..].ptr;
    set.items_len = set_items.len;
    const tagged_items = [_]c.GlowcapArgument{argRef(nested)};
    var tagged = argBase();
    tagged.kind = c.GLOWCAP_ARG_TAGGED;
    tagged.bytes = "Point";
    tagged.bytes_len = 5;
    tagged.items = tagged_items[0..].ptr;
    tagged.items_len = tagged_items.len;
    var keyword = argBase();
    keyword.kind = c.GLOWCAP_ARG_KEYWORD;
    keyword.bytes = "color";
    keyword.bytes_len = 5;
    const digits = "1267650600228229401496703205376";
    var big = argBase();
    big.kind = c.GLOWCAP_ARG_BIG_INTEGER;
    big.boolean = 1;
    big.bytes = digits;
    big.bytes_len = digits.len;
    const struct_items = [_]c.GlowcapArgument{
        argStr("name"),
        argStr("widget"),
        argStr("target"),
        argRef(nested),
    };
    var structured = argBase();
    structured.kind = c.GLOWCAP_ARG_STRUCT;
    structured.items = struct_items[0..].ptr;
    structured.items_len = struct_items.len;
    var error_value = argBase();
    error_value.kind = c.GLOWCAP_ARG_ERROR;
    error_value.bytes = "typed failure value";
    error_value.bytes_len = "typed failure value".len;
    const words = [_]i64{ 7, -8, 9 };
    var integers = argBase();
    integers.kind = c.GLOWCAP_ARG_INTEGERS;
    integers.bytes = @ptrCast(&words);
    integers.bytes_len = @sizeOf(@TypeOf(words));
    const args = [_]c.GlowcapArgument{ set, tagged, keyword, big, structured, error_value, integers };

    var send_vow: u64 = 0;
    try expectOk(cd.glowcap_host_session_send(pair.a, &target, "typed", 5, args[0..].ptr, args.len, &send_vow));
    var settled = CapturedSettle{};
    watches.add(client, send_vow, &settled);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(capture.seen);
    try std.testing.expect(capture.nested_ref.id != 0);
    try std.testing.expectEqual(c.GLOWCAP_RESOLUTION_FULFILL, settled.kind);
    try std.testing.expectEqual(c.GLOWCAP_ARG_ERROR, settled.value.kind);
    try std.testing.expectEqualStrings("typed failure value", settled.text[0..settled.text_len]);
    // Tagged and Struct each carried the same capability once. Return both
    // application observations under their one Host identity.
    try expectOk(cd.glowcap_host_ref_release(server, &capture.nested_ref, 2));

    // A noncanonical bignum that fits i64 is rejected before any call queues.
    var small = argBase();
    small.kind = c.GLOWCAP_ARG_BIG_INTEGER;
    small.bytes = "7";
    small.bytes_len = 1;
    var refused_vow: u64 = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_UNSUPPORTED_VALUE,
        cd.glowcap_host_session_send(pair.a, &target, "typed", 5, @ptrCast(&small), 1, &refused_vow),
    );

    // A run of integers is whole words: a ragged length is refused before
    // any call queues.
    var ragged = integers;
    ragged.bytes_len -= 1;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_UNSUPPORTED_VALUE,
        cd.glowcap_host_session_send(pair.a, &target, "typed", 5, @ptrCast(&ragged), 1, &refused_vow),
    );
    // The C contract is eight-byte alignment even on a target whose native
    // i64 alignment is smaller. Neither a byte nor half-word offset is valid.
    var storage: [16]u8 align(8) = @splat(0);
    for ([_]usize{ 1, 4 }) |offset| {
        var unaligned = integers;
        unaligned.bytes = storage[offset..].ptr;
        unaligned.bytes_len = 8;
        try std.testing.expectEqual(c.GLOWCAP_ERR_UNSUPPORTED_VALUE, cd.glowcap_host_session_send(
            pair.a,
            &target,
            "typed",
            5,
            @ptrCast(&unaligned),
            1,
            &refused_vow,
        ));
    }

    // Struct is a strict alternating String-key/value sequence. Reject every
    // contradictory shape before the call becomes visible.
    var malformed = argBase();
    malformed.kind = c.GLOWCAP_ARG_STRUCT;
    malformed.items = struct_items[0..].ptr;
    malformed.items_len = 3;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_UNSUPPORTED_VALUE,
        cd.glowcap_host_session_send(pair.a, &target, "typed", 5, @ptrCast(&malformed), 1, &refused_vow),
    );
    const non_string_key = [_]c.GlowcapArgument{ argInt(1), argInt(2) };
    malformed.items = non_string_key[0..].ptr;
    malformed.items_len = non_string_key.len;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_UNSUPPORTED_VALUE,
        cd.glowcap_host_session_send(pair.a, &target, "typed", 5, @ptrCast(&malformed), 1, &refused_vow),
    );
    const duplicate_fields = [_]c.GlowcapArgument{
        argStr("same"), argInt(1), argStr("same"), argInt(2),
    };
    malformed.items = duplicate_fields[0..].ptr;
    malformed.items_len = duplicate_fields.len;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_UNSUPPORTED_VALUE,
        cd.glowcap_host_session_send(pair.a, &target, "typed", 5, @ptrCast(&malformed), 1, &refused_vow),
    );
    var outbound: c.GlowcapManagedFrame = undefined;
    try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, takeOutbound(pair.a, &outbound));

    try expectOk(cd.glowcap_host_ref_release(client, &nested, 1));
    try expectOk(cd.glowcap_host_ref_release(client, &target, 1));
}
