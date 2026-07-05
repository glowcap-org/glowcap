//! Comparing two model values for structural equality.
//!
//! OCapN never puts an equality marker on the wire. So the way you tell that two
//! references name the same thing is to compare their structure, and that's what
//! this file does. It's the in-memory evidence behind distributed equality
//! (ADR-0012), and the conformance tests assert on the values the session tables
//! hold. Which codec or Syrup profile carried a value doesn't matter: the same
//! two values compare equal either way.
//!
//! The case that really earns its keep is `Reference.far`. Once a host holds to
//! one session per peer pair (ADR-0012's session-pair-uniqueness posture),
//! comparing two far refs across sessions comes down to comparing `(import_position,
//! kind)` within a session. The other arms compare field by field, and promise
//! paths and arguments recurse, so the check is total over the whole tree. (The
//! finer question of what equality *means* for container shapes is a separate
//! conformance concern; the structural groundwork is here.)

const std = @import("std");
const model = @import("mod.zig");

// The recursion ceiling is `model.max_value_depth`, the one shared value-tree
// depth bound. In practice we only ever compare trees the session already
// validated (its `max_nesting_depth` sits far below it) or values we built
// ourselves, so real data never gets close. A tree deeper than that couldn't
// have crossed an OCapN network anyway, so calling such a comparison unequal and
// stopping there is the safe move.

/// Are these two references structurally equal? Different variants are never
/// equal. Within a variant we go field by field, and that includes the `near` /
/// `far` wire kind (per ADR-0010, a reference carries its wire tag).
pub fn referencesEqual(a: model.Reference, b: model.Reference) bool {
    return referencesEqualDepth(a, b, 0);
}

fn referencesEqualDepth(a: model.Reference, b: model.Reference, depth: usize) bool {
    if (depth > model.max_value_depth) return false;
    return switch (a) {
        .near => |x| b == .near and x.export_position == b.near.export_position and x.kind == b.near.kind,
        .far => |x| b == .far and x.import_position == b.far.import_position and x.kind == b.far.kind,
        .promise => |x| b == .promise and x.answer_position == b.promise.answer_position and
            pipelinePathsEqualDepth(x.path, b.promise.path, depth),
        .sturdy => |x| b == .sturdy and
            peerLocatorsEqual(x.peer, b.sturdy.peer) and
            std.mem.eql(u8, x.swissnum, b.sturdy.swissnum),
        .broken => |x| b == .broken and std.mem.eql(u8, x.message, b.broken.message),
    };
}

/// Locator identity on two `model.PeerLocator` values, the equality axis a
/// `SturdyRef` and a `PeerId` both re-derive. Per OCapN `Locators.md`, the
/// designator and the transport are the only pieces that need to match: two
/// locators that differ only in hints name the same peer, because hints are
/// connection advice, not identity.
pub fn peerLocatorsEqual(a: model.PeerLocator, b: model.PeerLocator) bool {
    return std.mem.eql(u8, a.transport, b.transport) and
        std.mem.eql(u8, a.designator, b.designator);
}

/// Structural equality on two argument value trees. Recurses through lists,
/// sets, tagged values, and nested references; the `Hints.wire_form`
/// hint-encoding marker is *not* compared (it is a wire-shape artifact, not a
/// semantic value).
pub fn argumentsEqual(a: model.Argument, b: model.Argument) bool {
    return argumentsEqualDepth(a, b, 0);
}

fn argumentsEqualDepth(a: model.Argument, b: model.Argument, depth: usize) bool {
    if (depth > model.max_value_depth) return false;
    return switch (a) {
        .bytes => |x| b == .bytes and std.mem.eql(u8, x, b.bytes),
        .symbol => |x| b == .symbol and std.mem.eql(u8, x, b.symbol),
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .keyword => |x| b == .keyword and std.mem.eql(u8, x, b.keyword),
        .reference => |x| b == .reference and referencesEqualDepth(x, b.reference, depth),
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
        .@"struct" => |x| b == .@"struct" and structsEqualDepth(x, b.@"struct", depth + 1),
        // Canonical decimal digits (no leading zero, magnitude outside i64, both
        // enforced at decode) make bytewise comparison arithmetic equality, and
        // keep a big arm from ever spelling the same value as an `integer` arm.
        .big_integer => |x| b == .big_integer and x.negative == b.big_integer.negative and
            std.mem.eql(u8, x.digits, b.big_integer.digits),
    };
}

/// Order-independent equality for an OCapN Struct (Model.md § Struct). The wire
/// order of entries does not matter, and the two codecs may emit a different key
/// order, so two structs are Equal when they have the same length and every key in
/// one is present in the other with an Equal value. Keys are Strings, compared by
/// bytes; values recurse. No allocation, O(n*m) over the entry count, which is
/// fine for the small structs that cross the wire. Duplicate keys are refused at
/// decode, so a single-direction key scan suffices: with equal lengths and unique
/// keys, if every key of `a` matches one in `b`, `b` has no key `a` lacks.
fn structsEqualDepth(a: []const model.StructEntry, b: []const model.StructEntry, depth: usize) bool {
    if (depth > model.max_value_depth) return false;
    if (a.len != b.len) return false;
    for (a) |entry| {
        const other = findEntry(b, entry.key) orelse return false;
        if (!argumentsEqualDepth(entry.value, other, depth)) return false;
    }
    return true;
}

fn findEntry(entries: []const model.StructEntry, key: []const u8) ?model.Argument {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

/// Element-wise structural equality on two argument slices (order-sensitive).
pub fn argumentSlicesEqual(a: []const model.Argument, b: []const model.Argument) bool {
    return argumentSlicesEqualDepth(a, b, 0);
}

fn argumentSlicesEqualDepth(a: []const model.Argument, b: []const model.Argument, depth: usize) bool {
    if (depth > model.max_value_depth) return false;
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!argumentsEqualDepth(x, y, depth)) return false;
    }
    return true;
}

/// Order-agnostic (multiset) equality for `set` arms. A set is unordered: both
/// of pancake's encoders emit elements in canonical order, but a foreign encoder
/// may order them freely, so comparing element-by-element would call equal sets
/// unequal. Instead, two sets are equal when they have the same length
/// and every element appears the same number of times in each. That count check
/// is enough on its own: with equal lengths, if every element of `a` occurs as
/// often in `b`, then `b` has no element `a` lacks. No allocation, O(n^2), which
/// is fine for the small sets that cross the wire.
fn setsEqualDepth(a: []const model.Argument, b: []const model.Argument, depth: usize) bool {
    if (depth > model.max_value_depth) return false;
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
/// single Equal class and the remaining values compare by raw bits, which keeps
/// the sign-zero distinction the spec requires for round-trip JSON invariance.
fn float64Equal(x: f64, y: f64) bool {
    const x_is_nan = std.math.isNan(x);
    const y_is_nan = std.math.isNan(y);
    if (x_is_nan or y_is_nan) return x_is_nan and y_is_nan;
    return @as(u64, @bitCast(x)) == @as(u64, @bitCast(y));
}

/// Threads the caller's depth through the promise-path cycle: a `call` step's
/// arguments are one nesting level deeper, and those arguments can hold
/// promise references whose paths recurse back here. Restarting the counter
/// anywhere on this cycle would let an alternating promise/call tree recurse
/// past `model.max_value_depth` and off the native stack.
fn pipelinePathsEqualDepth(a: model.PipelinePath, b: model.PipelinePath, depth: usize) bool {
    if (depth > model.max_value_depth) return false;
    if (a.ops.len != b.ops.len) return false;
    for (a.ops, b.ops) |x, y| {
        switch (x) {
            .field => |name| if (!(y == .field and std.mem.eql(u8, name, y.field))) return false,
            .call => |args| if (!(y == .call and argumentSlicesEqualDepth(args, y.call, depth + 1))) return false,
        }
    }
    return true;
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

/// `raw_signed` is deliberately not compared: it caches the wire encoding the
/// signature was produced over, so it is an encoding artifact, not part of the
/// give's semantic identity.
fn giveEqual(a: model.HandoffGive, b: model.HandoffGive) bool {
    return std.mem.eql(u8, a.recipient_key, b.recipient_key) and
        std.mem.eql(u8, a.exporter_location, b.exporter_location) and
        std.mem.eql(u8, a.gifter_exporter_session, b.gifter_exporter_session) and
        std.mem.eql(u8, a.gifter_side, b.gifter_side) and
        std.mem.eql(u8, a.gift_id, b.gift_id) and
        std.mem.eql(u8, a.signature, b.signature);
}
