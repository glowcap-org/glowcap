//! Comparing two model values for structural equality.
//!
//! OCapN never puts an equality marker on the wire. So the way you tell that two
//! references name the same thing is to compare their structure, and that's what
//! this file does. It's the in-memory evidence behind distributed equality
//! (ADR-0012), and the conformance tests assert on the values the session tables
//! hold. Which codec or Syrup profile carried a value doesn't matter: the same
//! two values compare equal either way.
//!
//! The case that really earns its keep is `Reference.far`. Once we hold to
//! one-session-per-peer-pair (that's the `engine.SessionRegistry` invariant),
//! comparing two far refs across sessions comes down to comparing `(import_id,
//! kind)` within a session. The other arms compare field by field, and promise
//! paths and arguments recurse, so the check is total over the whole tree. (The
//! finer question of what equality *means* for container shapes is a separate
//! conformance concern; the structural groundwork is here.)

const std = @import("std");
const model = @import("mod.zig");

/// A ceiling on how deep the recursion will go, so a pathological tree can't
/// blow the stack. In practice we only ever compare trees the session already
/// validated (its `max_nesting_depth` sits far below this) or values we built
/// ourselves, so real data never gets close. A tree deeper than this couldn't
/// have crossed an OCapN network anyway, so calling such a comparison unequal and
/// stopping there is the safe move.
const max_equality_depth: usize = 256;

/// Are these two references structurally equal? Different variants are never
/// equal. Within a variant we go field by field, and that includes the `near` /
/// `far` wire kind (per ADR-0010, a reference carries its wire tag).
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
/// semantic value).
pub fn argumentsEqual(a: model.Argument, b: model.Argument) bool {
    return argumentsEqualDepth(a, b, 0);
}

fn argumentsEqualDepth(a: model.Argument, b: model.Argument, depth: usize) bool {
    if (depth > max_equality_depth) return false;
    return switch (a) {
        .bytes => |x| b == .bytes and std.mem.eql(u8, x, b.bytes),
        .symbol => |x| b == .symbol and std.mem.eql(u8, x, b.symbol),
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .keyword => |x| b == .keyword and std.mem.eql(u8, x, b.keyword),
        .reference => |x| b == .reference and referencesEqual(x, b.reference),
        .@"error" => |x| b == .@"error" and std.mem.eql(u8, x.message, b.@"error".message),
        .handoff => |x| b == .handoff and handoffsEqual(x.*, b.handoff.*),
        .integer => |x| b == .integer and x == b.integer,
        .boolean => |x| b == .boolean and x == b.boolean,
        .float64 => |x| b == .float64 and float64Equal(x, b.float64),
        .void => b == .void,
        .list => |x| b == .list and argumentSlicesEqualDepth(x, b.list, depth + 1),
        .set => |x| b == .set and setsEqualDepth(x, b.set, depth + 1),
        .tagged => |x| b == .tagged and std.mem.eql(u8, x.tag, b.tagged.tag) and
            argumentSlicesEqualDepth(x.value, b.tagged.value, depth + 1),
    };
}

/// Element-wise structural equality on two argument slices (order-sensitive).
pub fn argumentSlicesEqual(a: []const model.Argument, b: []const model.Argument) bool {
    return argumentSlicesEqualDepth(a, b, 0);
}

fn argumentSlicesEqualDepth(a: []const model.Argument, b: []const model.Argument, depth: usize) bool {
    if (depth > max_equality_depth) return false;
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!argumentsEqualDepth(x, y, depth)) return false;
    }
    return true;
}

/// Order-agnostic (multiset) equality for `set` arms. A set is unordered, and the
/// two codecs emit its elements in different orders — Syrup canonical-sorts,
/// Cap'n Proto keeps insertion order — so comparing element-by-element would call
/// equal sets unequal. Instead, two sets are equal when they have the same length
/// and every element appears the same number of times in each. That count check
/// is enough on its own: with equal lengths, if every element of `a` occurs as
/// often in `b`, then `b` has no element `a` lacks. No allocation, O(n^2), which
/// is fine for the small sets that cross the wire.
fn setsEqualDepth(a: []const model.Argument, b: []const model.Argument, depth: usize) bool {
    if (depth > max_equality_depth) return false;
    if (a.len != b.len) return false;
    for (a) |elem| {
        var count_a: usize = 0;
        for (a) |x| {
            if (argumentsEqualDepth(elem, x, depth)) count_a += 1;
        }
        var count_b: usize = 0;
        for (b) |y| {
            if (argumentsEqualDepth(elem, y, depth)) count_b += 1;
        }
        if (count_a != count_b) return false;
    }
    return true;
}

/// Pass-Invariant `Float64` equality (Model.md § Pass Invariant Equality): the
/// `Object.is` axis, *not* IEEE `==`. Two distinctions matter and IEEE `==` gets
/// both wrong: every NaN bit-pattern is Equal to every other NaN (IEEE: never),
/// and `+0.0` is *not* Equal to `-0.0` (IEEE: equal). So NaN is collapsed to a
/// single Equal class and the remaining values compare by raw bits — which keeps
/// the sign-zero distinction the spec requires for round-trip JSON invariance.
fn float64Equal(x: f64, y: f64) bool {
    const x_is_nan = std.math.isNan(x);
    const y_is_nan = std.math.isNan(y);
    if (x_is_nan or y_is_nan) return x_is_nan and y_is_nan;
    return @as(u64, @bitCast(x)) == @as(u64, @bitCast(y));
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
