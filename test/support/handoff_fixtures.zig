//! Handoff fixture vocabulary shared by the codec and oracle tests.
//!
//! Test support (not a production module): the Syrup codec tests and the
//! fixture-parity oracle encode the same `desc:handoff-give` /
//! `desc:handoff-receive` shape, so the byte constants and builders live
//! here once. The free helpers release a handoff the owned decode path
//! materialized; this copy choreography stays in test support per the
//! memory rule.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;

fn repeatedByte(comptime len: usize, byte: u8) [len]u8 {
    return [_]u8{byte} ** len;
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
        .exporter_location = "memory:exporter",
        .gifter_exporter_session = gifter_session[0..],
        .gifter_side = gifter_side[0..],
        .gift_id = gift_id[0..],
        .signature = give_signature[0..],
    };
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

/// Free a handoff whose fields the owned decode path duped onto `allocator`.
pub fn freeHandoff(allocator: std.mem.Allocator, handoff: model.Handoff) void {
    switch (handoff) {
        .give => |g| freeGive(allocator, g),
        .receive => |r| {
            allocator.free(r.receiving_session);
            allocator.free(r.receiving_side);
            freeGive(allocator, r.signed_give);
            allocator.free(r.signature);
        },
    }
}

pub fn freeGive(allocator: std.mem.Allocator, g: model.HandoffGive) void {
    allocator.free(g.recipient_key);
    allocator.free(g.exporter_location);
    allocator.free(g.gifter_exporter_session);
    allocator.free(g.gifter_side);
    allocator.free(g.gift_id);
    allocator.free(g.signature);
    if (g.raw_signed) |raw| allocator.free(raw);
}
