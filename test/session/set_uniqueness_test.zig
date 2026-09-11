//! Duplicate set elements and struct keys refused pre-commit on every walk
//! shape — inbound on both codecs' spines, outbound before encode — and the
//! comparison bound refusing a wide equal-hashed pair instead of grinding
//! through it.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const syrup = glowcap.ocapn.codec.syrup;
const capnp = glowcap.ocapn.codec.capnp;

const harness = @import("session_harness.zig");
const startSessionMessage = harness.startSessionMessage;
const startSessionMessageWithKey = harness.startSessionMessageWithKey;

test "an inbound set carrying two Equal elements is refused on both walk shapes" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(7));

    // Owned walk: the duplicate is refused in validate, before apply mutates.
    var dup_elements = [_]model.Argument{ .{ .integer = 4 }, .{ .string = "mid" }, .{ .integer = 4 } };
    var dup_args = [_]model.Argument{.{ .set = &dup_elements }};
    const dup_deliver = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &dup_args,
        .answer = null,
    } };
    try std.testing.expectError(session.Error.DuplicateSetElement, s.recordRecv(dup_deliver));

    // Borrowed walk: the view projection of the same message is refused
    // identically, so neither dispatch path admits what the other refuses.
    try std.testing.expectError(session.Error.DuplicateSetElement, s.recordRecvView(model.view.Body.fromOwned(&dup_deliver)));

    // Two inner sets spelling one member in different element order are Equal
    // (set equality is order-independent), so the outer set still carries a
    // duplicate — this pins the hash's commutative combine to the equality it
    // serves.
    var inner_a = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 } };
    var inner_b = [_]model.Argument{ .{ .integer = 2 }, .{ .integer = 1 } };
    var nested_elements = [_]model.Argument{ .{ .set = &inner_a }, .{ .set = &inner_b } };
    var nested_args = [_]model.Argument{.{ .set = &nested_elements }};
    try std.testing.expectError(session.Error.DuplicateSetElement, s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &nested_args,
        .answer = null,
    } }));

    // Distinct elements are admitted.
    var ok_elements = [_]model.Argument{ .{ .integer = 4 }, .{ .integer = 5 } };
    var ok_args = [_]model.Argument{.{ .set = &ok_elements }};
    try s.recordRecv(.{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &ok_args,
        .answer = null,
    } });
}

test "a Cap'n Proto set with duplicate elements is refused on the session inbound spine" {
    // Cap'n Proto decode admits sets without uniqueness (unlike Syrup). The
    // session walk is the codec-neutral backstop. Craft the untrusted frame by
    // encoding a list of two Equal integers (legal), then flipping that
    // argument's ArgKind discriminant to set — the same patch pattern as the
    // duplicate-key struct cases in `test/codec/capnp_test.zig`.
    const allocator = std.testing.allocator;
    const ArgKind = capnp.shared.ArgKind;

    const dup = [_]model.Argument{ .{ .integer = 4 }, .{ .integer = 4 } };
    const list_args = [_]model.Argument{.{ .list = &dup }};
    var list_frame = try capnp.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &list_args,
        .answer = null,
        .resolve_me_desc = null,
    } });
    defer list_frame.deinit();

    const buf = try allocator.dupe(u8, list_frame.bytes());
    defer allocator.free(buf);
    const words = std.mem.bytesAsSlice(u64, buf);
    // One bare list ArgKind on this frame: the outer deliver argument's data
    // word (no flag bits). Cap'n Proto list *pointers* can also put 8 in the
    // truncated low 16 bits, so match the whole word.
    var flipped: usize = 0;
    for (words) |*w| {
        if (w.* == @backingInt(ArgKind.list)) {
            w.* = @backingInt(ArgKind.set);
            flipped += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), flipped);
    const view = glowcap.foundation.FrameView{ .bytes = buf, .shape = .word };

    // Decode admits the set (no uniqueness at Cap'n Proto parse).
    const body = try capnp.decodeBody(view);
    try std.testing.expect(body == .deliver);
    const arg0 = try body.deliver.args.at(0);
    try std.testing.expect(arg0 == .set);
    try std.testing.expectEqual(@as(usize, 2), try arg0.set.len());

    // Session refuse on the same borrowed path Peer.recvBorrowed uses after
    // decode — DuplicateSetElement, not a codec MalformedFrame.
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerExport(.from(7));
    try std.testing.expectError(session.Error.DuplicateSetElement, s.recordRecvView(body));
}

test "a wide equal-hashed set pair is refused by the comparison bound, not ground through" {
    const allocator = std.testing.allocator;

    // Two spellings of one wide set: the same members, in opposite order. Set
    // equality is multiset equality, so confirming this pair costs work
    // quadratic in the width, and the commutative set hash puts the pair in
    // one hash run so the fold actually confirms it. That is the shape a
    // partner buys with a single frame, and the elements here are distinct, so
    // the inner folds themselves spend nothing.
    const wide = 256;
    var forward: [wide]model.Argument = undefined;
    var backward: [wide]model.Argument = undefined;
    for (0..wide) |i| {
        forward[i] = .{ .integer = @intCast(i) };
        backward[i] = .{ .integer = @intCast(wide - 1 - i) };
    }
    var outer = [_]model.Argument{ .{ .set = &forward }, .{ .set = &backward } };
    var args = [_]model.Argument{.{ .set = &outer }};
    const deliver = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &args,
        .answer = null,
    } };

    // Under the default bound the work stops early and loud.
    var bounded = session.Session.init(allocator);
    defer bounded.deinit();
    try bounded.registerExport(.from(7));
    try std.testing.expectError(
        session.Error.CompareBudgetExhausted,
        bounded.recordRecvView(model.view.Body.fromOwned(&deliver)),
    );

    // Given room to finish, the same pair really is Equal: the bound refuses a
    // frame this session would otherwise have refused anyway, only sooner. So
    // the early refusal is the budget doing its job, not a wrong comparison.
    var generous = session.Session.initWith(allocator, .{ .limits = .{ .max_compare_visits = 1 << 24 } });
    defer generous.deinit();
    try generous.registerExport(.from(7));
    try std.testing.expectError(
        session.Error.DuplicateSetElement,
        generous.recordRecvView(model.view.Body.fromOwned(&deliver)),
    );

    // A narrow pair stays under the bound, so the budget cannot false-fire on
    // the ordinary duplicate refusal this fold exists for.
    var narrow_a = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 } };
    var narrow_b = [_]model.Argument{ .{ .integer = 2 }, .{ .integer = 1 } };
    var narrow_outer = [_]model.Argument{ .{ .set = &narrow_a }, .{ .set = &narrow_b } };
    var narrow_args = [_]model.Argument{.{ .set = &narrow_outer }};
    const narrow_deliver = model.Message{ .deliver = .{
        .target = .{ .near = .{ .export_position = .from(7) } },
        .args = &narrow_args,
        .answer = null,
    } };
    var narrow = session.Session.init(allocator);
    defer narrow.deinit();
    try narrow.registerExport(.from(7));
    try std.testing.expectError(
        session.Error.DuplicateSetElement,
        narrow.recordRecvView(model.view.Body.fromOwned(&narrow_deliver)),
    );
}

test "a sent duplicate set element or struct key is refused pre-commit, not at encode" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(7));

    // The encoders refuse both duplicates too (ADR-0003), but an encode-time
    // refusal fires in `step`, after send-side export accounting committed wire-delta
    // retains for a frame that never ships. `validateSend` refuses first, so
    // nothing commits: no outbound answer row is minted for the refused sends.
    var dup_elements = [_]model.Argument{ .{ .integer = 4 }, .{ .string = "mid" }, .{ .integer = 4 } };
    var dup_args = [_]model.Argument{.{ .set = &dup_elements }};
    try std.testing.expectError(session.Error.DuplicateSetElement, s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &dup_args,
        .answer = .from(41),
    } }));
    try std.testing.expect(s.outboundAnswer(.from(41)) == null);

    var dup_entries = [_]model.StructEntry{
        .{ .key = "alpha", .value = .{ .integer = 1 } },
        .{ .key = "alpha", .value = .{ .integer = 2 } },
    };
    var struct_args = [_]model.Argument{.{ .@"struct" = &dup_entries }};
    try std.testing.expectError(session.Error.DuplicateStructKey, s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &struct_args,
        .answer = .from(42),
    } }));
    try std.testing.expect(s.outboundAnswer(.from(42)) == null);

    // Distinct keys and elements still send.
    var ok_entries = [_]model.StructEntry{
        .{ .key = "alpha", .value = .{ .integer = 1 } },
        .{ .key = "beta", .value = .{ .integer = 2 } },
    };
    var ok_args = [_]model.Argument{.{ .@"struct" = &ok_entries }};
    try s.recordSend(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &ok_args,
        .answer = .from(43),
    } });
    try std.testing.expect(s.outboundAnswer(.from(43)) != null);
}
