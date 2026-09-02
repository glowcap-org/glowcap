//! Handoff fixture vocabulary shared by the codec and oracle tests.
//!
//! Test support (not a production module): the Syrup codec tests and the
//! fixture-parity oracle encode the same `desc:handoff-give` /
//! `desc:handoff-receive` shape, so the byte constants and builders live
//! here once. Owned decode paths free through `model.freeHandoff`.

const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;

fn repeatedByte(comptime len: usize, byte: u8) [len]u8 {
    return @as([len]u8, @splat(byte));
}

pub const recipient_key = repeatedByte(32, 0x42);
pub const gifter_session = repeatedByte(32, 0xcc);
pub const gifter_side = repeatedByte(32, 0x11);
pub const gift_id = repeatedByte(32, 0x01);
pub const give_signature = repeatedByte(64, 0xaa);
pub const receiving_session = repeatedByte(32, 0xdd);
pub const receiving_side = repeatedByte(32, 0x22);
pub const receive_signature = repeatedByte(64, 0xbb);

pub fn give() model.HandoffGive {
    return .{
        .recipient_key = recipient_key[0..],
        .exporter = .{ .transport = "memory", .designator = "exporter" },
        .gifter_exporter_session = gifter_session[0..],
        .gifter_side = gifter_side[0..],
        .gift_id = gift_id[0..],
        .signature = give_signature[0..],
    };
}

/// The side name an exporter derives from `recipient_key`.
///
/// The byte constants above are wire-shape fixtures: a codec only has to
/// round-trip whatever bytes it is handed, so `receiving_side` there is an
/// arbitrary constant, and the checked-in Syrup corpus was encoded from it. An
/// *authority* test goes through the exporter's check, which compares a receive
/// against this derivation rather than against its own words, so it builds its
/// receive with `receiveFromRecipient` instead.
pub const recipient_side = blk: {
    @setEvalBranchQuota(100_000);
    break :blk glowcap.ocapn.engine.handoff_recipient.sideName(recipient_key[0..]) catch unreachable;
};

/// `receive`, but naming the side the exporter will derive. For tests that
/// exercise the gift registry rather than the codec.
pub fn receiveFromRecipient() model.HandoffReceive {
    var value = receive();
    value.receiving_side = recipient_side[0..];
    return value;
}

pub fn receive() model.HandoffReceive {
    return .{
        .receiving_session = receiving_session[0..],
        .receiving_side = receiving_side[0..],
        .handoff_count = 1,
        .signed_give = give(),
        .signature = receive_signature[0..],
    };
}
