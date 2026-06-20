//! Structural equality over codec-neutral `model.Message` values.
//!
//! Test support (not a production module): the view round-trip test and the
//! cross-codec equivalence harness both need to ask "are these two decoded
//! messages the same meaning?", independent of which codec or entry point
//! produced them. Leans on the production `model.*Equal` helpers for the leaf
//! comparisons (references, arguments, locators).

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;

/// True when `a` and `b` are the same message arm carrying equal contents.
pub fn messagesEqual(a: model.Message, b: model.Message) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .deliver => |x| blk: {
            const y = b.deliver;
            if (!model.referencesEqual(x.target, y.target)) break :blk false;
            if (x.answer != y.answer) break :blk false;
            if ((x.resolve_me_desc == null) != (y.resolve_me_desc == null)) break :blk false;
            if (x.resolve_me_desc) |xr| {
                if (!model.referencesEqual(xr, y.resolve_me_desc.?)) break :blk false;
            }
            break :blk argumentSlicesEqual(x.args, y.args);
        },
        .resolve => |x| resolutionsEqual(x.resolution, b.resolve.resolution) and x.answer == b.resolve.answer,
        .gc_export => |x| std.mem.eql(u64, x.positions, b.gc_export.positions) and std.mem.eql(u64, x.deltas, b.gc_export.deltas),
        .gc_answer => |x| std.mem.eql(u64, x.positions, b.gc_answer.positions),
        .abort => |x| x.kind == b.abort.kind and std.mem.eql(u8, x.message, b.abort.message),
        .listen => |x| model.referencesEqual(x.target, b.listen.target) and
            model.referencesEqual(x.listener, b.listen.listener) and x.wants_partial == b.listen.wants_partial,
        .get => |x| model.referencesEqual(x.receiver, b.get.receiver) and
            std.mem.eql(u8, x.field, b.get.field) and x.answer == b.get.answer,
        .index => |x| model.referencesEqual(x.receiver, b.index.receiver) and
            x.index == b.index.index and x.answer == b.index.answer,
        .untag => |x| model.referencesEqual(x.receiver, b.untag.receiver) and
            std.mem.eql(u8, x.tag, b.untag.tag) and x.answer == b.untag.answer,
        .start_session => |x| blk: {
            const y = b.start_session;
            break :blk x.captp_version == y.captp_version and
                std.mem.eql(u8, x.session_pubkey.bytes, y.session_pubkey.bytes) and
                model.peerLocatorsEqual(x.acceptable_location, y.acceptable_location) and
                std.mem.eql(u8, x.acceptable_location_sig.bytes, y.acceptable_location_sig.bytes);
        },
        .handoff => |x| handoffsEqual(x, b.handoff),
    };
}

fn argumentSlicesEqual(a: []const model.Argument, b: []const model.Argument) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!model.argumentsEqual(x, y)) return false;
    return true;
}

fn resolutionsEqual(a: model.Resolution, b: model.Resolution) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .fulfill => |x| model.argumentsEqual(x, b.fulfill),
        .@"break" => |x| std.mem.eql(u8, x.message, b.@"break".message),
    };
}

fn givesEqual(a: model.HandoffGive, b: model.HandoffGive) bool {
    return std.mem.eql(u8, a.recipient_key, b.recipient_key) and
        std.mem.eql(u8, a.exporter_location, b.exporter_location) and
        std.mem.eql(u8, a.gifter_exporter_session, b.gifter_exporter_session) and
        std.mem.eql(u8, a.gifter_side, b.gifter_side) and
        std.mem.eql(u8, a.gift_id, b.gift_id) and
        std.mem.eql(u8, a.signature, b.signature);
}

fn handoffsEqual(a: model.Handoff, b: model.Handoff) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .give => |x| givesEqual(x, b.give),
        .receive => |x| givesEqual(x.signed_give, b.receive.signed_give) and
            x.handoff_count == b.receive.handoff_count and
            std.mem.eql(u8, x.receiving_session, b.receive.receiving_session) and
            std.mem.eql(u8, x.receiving_side, b.receive.receiving_side) and
            std.mem.eql(u8, x.signature, b.receive.signature),
    };
}
