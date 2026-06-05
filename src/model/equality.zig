//! Structural equality on the codec-neutral [`model`] value tree.
//!
//! This is the in-memory evidence for distributed (Pass Invariant) equality per
//! ADR-0013 § Decision 5: there is no wire field carrying equality; two references that
//! name the same target compare equal here, and the conformance assertions are
//! made on the values the session tables hold. Equality is **codec-neutral**
//! (Invariant 1): the same two values compare equal regardless of which codec or
//! Syrup profile carried them.
//!
//! The load-bearing case is `Reference.far`: cross-session equality reduces to
//! same-session equality on `(import_id, kind)` once one-session-per-peer-pair
//! holds (the [`runtime.SessionRegistry`] invariant). The remaining arms compare
//! structurally; promise paths and arguments recurse so the predicate is total
//! over the value tree (Pass Invariant Equality *semantics* for container shapes
//! is a separate conformance concern, but the structural substrate is here).

const std = @import("std");
const model = @import("mod.zig");

/// Structural equality on two [`model.Reference`] values. Differing variants are
/// never equal; within a variant the comparison is field-wise (the `far` /
/// `near` wire-kind discriminator participates per ADR-0010 § Decision 5).
pub fn referencesEqual(a: model.Reference, b: model.Reference) bool {
    return switch (a) {
        .near => |x| b == .near and x.export_id == b.near.export_id and x.kind == b.near.kind,
        .far => |x| b == .far and x.import_id == b.far.import_id and x.kind == b.far.kind,
        .promise => |x| b == .promise and x.answer_id == b.promise.answer_id and
            pipelinePathsEqual(x.path, b.promise.path),
        .sturdy => |x| b == .sturdy and
            peerLocatorsEqual(x.peer, b.sturdy.peer) and
            std.mem.eql(u8, x.swissnum, b.sturdy.swissnum),
        .broken => |x| b == .broken and std.mem.eql(u8, x.message, b.broken.message),
    };
}

/// Structural equality on two [`model.PeerLocator`] values — the equality axis a
/// `SturdyRef` and a `PeerId` both re-derive (transport, designator, hints).
pub fn peerLocatorsEqual(a: model.PeerLocator, b: model.PeerLocator) bool {
    return std.mem.eql(u8, a.transport, b.transport) and
        std.mem.eql(u8, a.designator, b.designator) and
        hintsEqual(a.hints, b.hints);
}

/// Structural equality on two argument value trees. Recurses through lists,
/// sets, tagged values, and nested references; the `empty_wire_was_false`
/// hint-encoding marker is *not* compared (it is a wire-shape artifact, not a
/// semantic value — Invariant 1).
pub fn argumentsEqual(a: model.Argument, b: model.Argument) bool {
    return switch (a) {
        .bytes => |x| b == .bytes and std.mem.eql(u8, x, b.bytes),
        .symbol => |x| b == .symbol and std.mem.eql(u8, x, b.symbol),
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .keyword => |x| b == .keyword and std.mem.eql(u8, x, b.keyword),
        .reference => |x| b == .reference and referencesEqual(x, b.reference),
        .@"error" => |x| b == .@"error" and std.mem.eql(u8, x.message, b.@"error".message),
        .handoff => |x| b == .handoff and handoffsEqual(x, b.handoff),
        .integer => |x| b == .integer and x == b.integer,
        .boolean => |x| b == .boolean and x == b.boolean,
        .float64 => |x| b == .float64 and x == b.float64,
        .void => b == .void,
        .list => |x| b == .list and argumentSlicesEqual(x, b.list),
        .set => |x| b == .set and argumentSlicesEqual(x, b.set),
        .tagged => |x| b == .tagged and std.mem.eql(u8, x.tag, b.tagged.tag) and
            argumentSlicesEqual(x.value, b.tagged.value),
    };
}

/// Element-wise structural equality on two argument slices (order-sensitive).
pub fn argumentSlicesEqual(a: []const model.Argument, b: []const model.Argument) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!argumentsEqual(x, y)) return false;
    }
    return true;
}

fn pipelinePathsEqual(a: model.PipelinePath, b: model.PipelinePath) bool {
    if (a.ops.len != b.ops.len) return false;
    for (a.ops, b.ops) |x, y| {
        switch (x) {
            .field => |name| if (!(y == .field and std.mem.eql(u8, name, y.field))) return false,
            .call => |args| if (!(y == .call and argumentSlicesEqual(args, y.call))) return false,
        }
    }
    return true;
}

fn hintsEqual(a: model.Hints, b: model.Hints) bool {
    if (a.entries.len != b.entries.len) return false;
    for (a.entries, b.entries) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name)) return false;
        if (!hintValuesEqual(x.value, y.value)) return false;
    }
    return true;
}

fn hintValuesEqual(a: model.HintValue, b: model.HintValue) bool {
    return switch (a) {
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .bytes => |x| b == .bytes and std.mem.eql(u8, x, b.bytes),
        .boolean => |x| b == .boolean and x == b.boolean,
        .integer => |x| b == .integer and x == b.integer,
    };
}

fn handoffsEqual(a: model.Handoff, b: model.Handoff) bool {
    return switch (a) {
        .give => |x| b == .give and giveEqual(x, b.give),
        .receive => |x| b == .receive and
            std.mem.eql(u8, x.receiving_session, b.receive.receiving_session) and
            std.mem.eql(u8, x.receiving_side, b.receive.receiving_side) and
            x.handoff_count == b.receive.handoff_count and
            giveEqual(x.signed_give, b.receive.signed_give) and
            std.mem.eql(u8, x.signature, b.receive.signature),
    };
}

fn giveEqual(a: model.HandoffGive, b: model.HandoffGive) bool {
    return std.mem.eql(u8, a.recipient_key, b.recipient_key) and
        std.mem.eql(u8, a.exporter_location, b.exporter_location) and
        std.mem.eql(u8, a.gifter_exporter_session, b.gifter_exporter_session) and
        std.mem.eql(u8, a.gifter_side, b.gifter_side) and
        std.mem.eql(u8, a.gift_id, b.gift_id) and
        std.mem.eql(u8, a.signature, b.signature);
}
