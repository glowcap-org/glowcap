//! Structural equality over codec-neutral `model.Message` values.
//!
//! Test support (not a production module): the view round-trip test and the
//! cross-codec equivalence harness both need to ask "are these two decoded
//! messages the same meaning?", independent of which codec or entry point
//! produced them. Leans on the production `model.*Equal` helpers for leaf
//! comparisons (references, arguments, argument slices, locators, handoffs).

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;

/// True when `a` and `b` are the same message arm carrying equal contents.
pub fn messagesEqual(a: model.Message, b: model.Message) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .deliver => |x| blk: {
            const y = b.deliver;
            if (!model.referencesStructurallyEqual(x.target, y.target)) break :blk false;
            if (x.answer != y.answer) break :blk false;
            if ((x.resolve_me_desc == null) != (y.resolve_me_desc == null)) break :blk false;
            if (x.resolve_me_desc) |xr| {
                if (!model.referencesStructurallyEqual(xr, y.resolve_me_desc.?)) break :blk false;
            }
            break :blk model.equality.argumentSlicesEqual(x.args, y.args);
        },
        .resolve => |x| resolutionsEqual(x.resolution, b.resolve.resolution) and x.answer == b.resolve.answer,
        .gc_export => |x| std.mem.eql(u64, x.positions, b.gc_export.positions) and std.mem.eql(u64, x.deltas, b.gc_export.deltas),
        .gc_answer => |x| std.mem.eql(u64, x.positions, b.gc_answer.positions),
        .abort => |x| x.kind == b.abort.kind and std.mem.eql(u8, x.message, b.abort.message),
        .listen => |x| model.referencesStructurallyEqual(x.target, b.listen.target) and
            model.referencesStructurallyEqual(x.listener, b.listen.listener) and x.mode == b.listen.mode,
        .get => |x| model.referencesStructurallyEqual(x.receiver, b.get.receiver) and
            std.mem.eql(u8, x.field, b.get.field) and x.answer == b.get.answer,
        .index => |x| model.referencesStructurallyEqual(x.receiver, b.index.receiver) and
            x.index.eql(b.index.index) and x.answer == b.index.answer,
        .untag => |x| model.referencesStructurallyEqual(x.receiver, b.untag.receiver) and
            std.mem.eql(u8, x.tag, b.untag.tag) and x.answer == b.untag.answer,
        .start_session => |x| blk: {
            const y = b.start_session;
            break :blk x.captp_version == y.captp_version and
                std.mem.eql(u8, x.session_pubkey.bytes, y.session_pubkey.bytes) and
                model.peerLocatorsEqual(x.acceptable_location, y.acceptable_location) and
                std.mem.eql(u8, x.acceptable_location_sig.bytes, y.acceptable_location_sig.bytes);
        },
    };
}

fn resolutionsEqual(a: model.Resolution, b: model.Resolution) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .fulfill => |x| model.argumentsEqual(x, b.fulfill),
        .@"break" => |x| std.mem.eql(u8, x.message, b.@"break".message),
    };
}
