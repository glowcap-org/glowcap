//! Comparing two model values for structural equality.
//!
//! OCapN never puts an equality marker on the wire. This file compares the
//! in-memory representation that codecs and session tables hold. It does not
//! canonicalize targets that arrived through different sessions or network
//! paths. Which codec carried the same representation does not matter.
//!
//! The case that really earns its keep is `Reference.far`. ADR-0012's
//! session-pair-uniqueness posture means same-session equality is on
//! `(import_position, kind)`. Cross-session uniqueness is Host enrollment
//! (`SessionPairExists` / partner-key index), not a collapse of far-ref
//! comparison across sessions. The other arms compare field by field, and
//! promise paths and arguments recurse, so the check is total over the whole
//! tree. (The finer question of what equality *means* for container shapes is
//! a separate conformance concern; the structural groundwork is here.)

const std = @import("std");
const model = @import("mod.zig");

// The recursion ceiling is `model.max_value_depth`, the one shared value-tree
// depth bound. In practice we only ever compare trees the session already
// validated (its `max_nesting_depth` sits far below it) or values we built
// ourselves, so real data never gets close. A tree deeper than that couldn't
// have crossed an OCapN network anyway, so calling such a comparison unequal and
// stopping there is the safe move.

// One spine. Every comparison and hash below runs over the borrowed
// `model.view.*` shape, and the owned entry points project through
// `view.*.fromOwned` — the same one-spine pattern `owned.zig` uses for its
// clones. There used to be a second, hand-mirrored owned spine here, and the
// divergence between the two is where a codec-dependent union read hid; a
// projection cannot diverge. An owned projection is slice-backed and its hints
// are `.projected`, so the lazy-view failure arms (`MalformedView`, the
// materialize allocation) cannot fire on it; that is what licenses the
// `catch unreachable` in the infallible wrappers below.

/// The infallible owned entry points compare values this process built (test
/// fixtures, session-held rows), so they carry no caller budget: the work is
/// bounded by the caller's own tree. Anything partner-influenced goes through
/// the `*Bounded` forms and charges.
const unbounded_visits = std.math.maxInt(usize);

/// Are these two references structurally equal? Different variants are never
/// equal. Within a variant we go field by field, and that includes the `near` /
/// `far` wire kind (per ADR-0010, a reference carries its wire tag).
pub fn referencesStructurallyEqual(a: model.Reference, b: model.Reference) bool {
    return argumentsEqual(.{ .reference = a }, .{ .reference = b });
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
/// semantic value). Runs over the borrowed spine via `fromOwned`; see the
/// one-spine note at the top of this file.
pub fn argumentsEqual(a: model.Argument, b: model.Argument) bool {
    var budget = CompareBudget.init(unbounded_visits);
    var no_scratch_buf: [0]u8 = .{};
    var no_scratch = std.heap.FixedBufferAllocator.init(&no_scratch_buf);
    return viewArgumentsEqualBounded(
        .fromOwned(&a),
        .fromOwned(&b),
        .{ .scratch = no_scratch.allocator(), .budget = &budget },
    ) catch unreachable;
}

/// The budgeted owned comparison, for owned trees that carry partner
/// influence (a stored relayed resolution, an inbound owned fallback). Same
/// spine as `viewArgumentsEqualBounded`; the projection is just cheaper to
/// build.
pub fn argumentsEqualBounded(
    a: *const model.Argument,
    b: *const model.Argument,
    ctx: CompareCtx,
) CompareError!bool {
    return viewArgumentsEqualBounded(.fromOwned(a), .fromOwned(b), ctx);
}

/// The hash of a float, consistent with `float64Equal`. Every NaN bit pattern
/// is one Equal class, so they all fold to one constant; everything else
/// compares by raw bits and so hashes by raw bits, which keeps `+0.0` and
/// `-0.0` distinct exactly as equality does.
fn float64Hash(x: f64) u64 {
    const nan_class: u64 = 0x7ff8_0000_0000_0001;
    return if (std.math.isNan(x)) nan_class else @bitCast(x);
}

/// Fold a reference into `h`, hashing only the fields
/// `referencesStructurallyEqual`
/// compares. A sturdyref's locator hints are left out because equality leaves
/// them out: two locators differing only in dial advice name the same peer. A
/// promise contributes its answer position.
fn hashReference(h: *std.hash.Wyhash, ref: anytype) void {
    h.update(std.mem.asBytes(&@backingInt(std.meta.activeTag(ref))));
    switch (ref) {
        .near => |x| {
            h.update(std.mem.asBytes(&x.export_position.int()));
            h.update(std.mem.asBytes(&@backingInt(x.kind)));
        },
        .far => |x| {
            h.update(std.mem.asBytes(&x.import_position.int()));
            h.update(std.mem.asBytes(&@backingInt(x.kind)));
        },
        .routed => |x| {
            h.update(std.mem.asBytes(&x.id.int()));
            h.update(std.mem.asBytes(&@backingInt(x.kind)));
        },
        .promise => |x| h.update(std.mem.asBytes(&x.answer_position.int())),
        .sturdy => |x| {
            h.update(x.peer.transport);
            h.update(x.peer.designator);
            h.update(x.swissnum);
        },
        .broken => |x| h.update(x.message),
    }
}

/// Fold a handoff into `h` over fields both `handoffsEqual` and `giveEqual`
/// compare. `raw_signed` is excluded for the same reason equality excludes it:
/// it caches a wire encoding, not identity. The signatures are excluded because
/// the borrowed shape spells one as a union rather than bytes; the gift id and
/// recipient key already separate distinct handoffs, and hashing less than
/// equality compares only ever costs a collision.
fn hashHandoff(h: *std.hash.Wyhash, handoff: anytype) void {
    h.update(std.mem.asBytes(&@backingInt(std.meta.activeTag(handoff))));
    switch (handoff) {
        .give => |give| {
            h.update(give.gift_id);
            h.update(give.recipient_key);
        },
        .receive => |receive| {
            h.update(receive.receiving_session);
            h.update(receive.receiving_side);
            h.update(std.mem.asBytes(&receive.handoff_count));
            h.update(receive.signed_give.gift_id);
            h.update(receive.signed_give.recipient_key);
        },
    }
}

/// Structural hash consistent with `argumentsEqual`: two Equal values always
/// hash equal. It is `viewArgumentHash` over the owned projection, so the two
/// shapes share one hasher and one grouping: distinct values that collide
/// under one entry point collide under the other, which is what lets a fold
/// that grouped by one hasher confirm with either comparison. Process-local
/// grouping only (duplicate detection inside one frame); never a wire
/// artifact.
pub fn argumentHash(arg: model.Argument) u64 {
    // Hashing never compares elements or materializes hints, so the only
    // failure arms are the lazy-view ones an owned projection cannot reach.
    return viewArgumentHash(.fromOwned(&arg)) catch unreachable;
}

/// Structural hash on a borrowed `view.Argument`, consistent with
/// `viewArgumentsEqualBounded`. A caller grouping by hash must still confirm
/// with that comparison on collision. The `set` and `struct` arms combine
/// their children commutatively, because equality on both is order-independent.
/// That also means a partner can search for two distinct values that hash
/// alike, so confirming is bounded work rather than trusted work.
pub fn viewArgumentHash(arg: model.view.Argument) model.view.ProjectError!u64 {
    return viewArgumentHashDepth(arg, 0);
}

fn viewArgumentHashDepth(arg: model.view.Argument, depth: usize) model.view.ProjectError!u64 {
    if (depth > model.max_value_depth) return 0;
    var h = std.hash.Wyhash.init(@backingInt(arg));
    switch (arg) {
        .bytes => |x| h.update(x),
        .symbol => |x| h.update(x),
        .string => |x| h.update(x),
        .keyword => |x| h.update(x),
        .integer => |x| h.update(std.mem.asBytes(&x)),
        .big_integer => |x| {
            h.update(std.mem.asBytes(&x.negative));
            h.update(x.digits);
        },
        .boolean => |x| h.update(std.mem.asBytes(&x)),
        .float64 => |x| h.update(std.mem.asBytes(&float64Hash(x))),
        .reference => |x| hashReference(&h, x),
        .@"error" => |x| h.update(x.message),
        .handoff => |x| hashHandoff(&h, x),
        .void => {},
        .list => |items| {
            var it = items.iterator();
            while (try it.next()) |item| {
                const child = try viewArgumentHashDepth(item, depth + 1);
                h.update(std.mem.asBytes(&child));
            }
        },
        .tagged => |tagged| {
            h.update(tagged.tag);
            var it = tagged.value.iterator();
            while (try it.next()) |item| {
                const child = try viewArgumentHashDepth(item, depth + 1);
                h.update(std.mem.asBytes(&child));
            }
        },
        .set => |items| {
            var sum: u64 = 0;
            var it = items.iterator();
            while (try it.next()) |item| sum +%= try viewArgumentHashDepth(item, depth + 1);
            h.update(std.mem.asBytes(&sum));
        },
        .@"struct" => |entries| {
            var sum: u64 = 0;
            var it = entries.iterator();
            while (try it.next()) |entry| {
                var eh = std.hash.Wyhash.init(0);
                eh.update(entry.key);
                const value_hash = try viewArgumentHashDepth(entry.value, depth + 1);
                eh.update(std.mem.asBytes(&value_hash));
                sum +%= eh.final();
            }
            h.update(std.mem.asBytes(&sum));
        },
    }
    return h.final();
}

/// What a borrowed comparison may fail with: a malformed view, an allocation
/// failure materializing lazy hints, or a partner that asked for more
/// comparison work than one message is allowed to buy.
pub const CompareError = model.view.Error || error{CompareBudgetExhausted};

/// The work one inbound message's comparisons may spend, in element visits.
///
/// Set equality is multiset equality, so comparing two sets of width N costs
/// on the order of N² visits, and struct equality resolves each key by scan.
/// Both are quadratic in an attacker's chosen width. The elements compared are
/// only ever those a hash grouping already found equal-hashed, and the set
/// hash combines children commutatively, so a partner can build two distinct
/// wide sets that hash alike and buy that quadratic with one frame. The budget
/// makes the work bounded rather than the input trusted: every visit charges,
/// and running out refuses loudly instead of answering slowly.
pub const CompareBudget = struct {
    remaining: usize,

    pub fn init(visits: usize) CompareBudget {
        return .{ .remaining = visits };
    }

    fn charge(self: *CompareBudget) error{CompareBudgetExhausted}!void {
        if (self.remaining == 0) return error.CompareBudgetExhausted;
        self.remaining -= 1;
    }
};

/// What a borrowed comparison carries down the tree: `scratch` materializes
/// lazy hint lists for handoff comparison (turn-scratch is the intended
/// owner), and `budget` bounds the total work.
pub const CompareCtx = struct {
    scratch: std.mem.Allocator,
    budget: *CompareBudget,
};

/// Structural equality on two borrowed `view.Argument` trees, bounded by the
/// caller's budget.
pub fn viewArgumentsEqualBounded(
    a: model.view.Argument,
    b: model.view.Argument,
    ctx: CompareCtx,
) CompareError!bool {
    return viewArgumentsEqualDepth(a, b, 0, ctx);
}

fn viewArgumentsEqualDepth(
    a: model.view.Argument,
    b: model.view.Argument,
    depth: usize,
    ctx: CompareCtx,
) CompareError!bool {
    if (depth > model.max_value_depth) return false;
    try ctx.budget.charge();
    const scratch = ctx.scratch;
    return switch (a) {
        .bytes => |x| b == .bytes and std.mem.eql(u8, x, b.bytes),
        .symbol => |x| b == .symbol and std.mem.eql(u8, x, b.symbol),
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .keyword => |x| b == .keyword and std.mem.eql(u8, x, b.keyword),
        .reference => |x| b == .reference and viewReferencesEqual(x, b.reference),
        .@"error" => |x| b == .@"error" and std.mem.eql(u8, x.message, b.@"error".message),
        .handoff => |x| b == .handoff and try viewHandoffsEqual(x, b.handoff, scratch),
        .integer => |x| b == .integer and x == b.integer,
        .boolean => |x| b == .boolean and x == b.boolean,
        .float64 => |x| b == .float64 and float64Equal(x, b.float64),
        .void => b == .void,
        .list => |x| b == .list and try viewArgsEqualDepth(x, b.list, depth + 1, ctx),
        .set => |x| b == .set and try viewSetsEqualDepth(x, b.set, depth + 1, ctx),
        .tagged => |x| b == .tagged and std.mem.eql(u8, x.tag, b.tagged.tag) and
            try viewArgsEqualDepth(x.value, b.tagged.value, depth + 1, ctx),
        .@"struct" => |x| b == .@"struct" and try viewStructsEqualDepth(x, b.@"struct", depth + 1, ctx),
        .big_integer => |x| b == .big_integer and x.negative == b.big_integer.negative and
            std.mem.eql(u8, x.digits, b.big_integer.digits),
    };
}

fn viewReferencesEqual(
    a: model.view.Reference,
    b: model.view.Reference,
) bool {
    return switch (a) {
        .near => |x| b == .near and x.export_position == b.near.export_position and x.kind == b.near.kind,
        .far => |x| b == .far and x.import_position == b.far.import_position and x.kind == b.far.kind,
        .routed => |x| b == .routed and x.id == b.routed.id and x.kind == b.routed.kind,
        .promise => |x| b == .promise and x.answer_position == b.promise.answer_position,
        .sturdy => |x| b == .sturdy and
            std.mem.eql(u8, x.peer.transport, b.sturdy.peer.transport) and
            std.mem.eql(u8, x.peer.designator, b.sturdy.peer.designator) and
            std.mem.eql(u8, x.swissnum, b.sturdy.swissnum),
        .broken => |x| b == .broken and std.mem.eql(u8, x.message, b.broken.message),
    };
}

fn viewArgsEqualDepth(
    a: model.view.Args,
    b: model.view.Args,
    depth: usize,
    ctx: CompareCtx,
) CompareError!bool {
    if (depth > model.max_value_depth) return false;
    const a_len = try a.len();
    const b_len = try b.len();
    if (a_len != b_len) return false;
    var a_it = a.iterator();
    var b_it = b.iterator();
    while (try a_it.next()) |x| {
        const y = (try b_it.next()) orelse return false;
        if (!try viewArgumentsEqualDepth(x, y, depth, ctx)) return false;
    }
    return (try b_it.next()) == null;
}

/// Multiset equality: a set is unordered, so each element's multiplicity must
/// match on both sides. The scan is quadratic in the set's width, which is why
/// every element visit charges the caller's budget.
fn viewSetsEqualDepth(
    a: model.view.Args,
    b: model.view.Args,
    depth: usize,
    ctx: CompareCtx,
) CompareError!bool {
    if (depth > model.max_value_depth) return false;
    const a_len = try a.len();
    const b_len = try b.len();
    if (a_len != b_len) return false;
    var a_it = a.iterator();
    while (try a_it.next()) |elem| {
        var count_a: usize = 0;
        var a_scan = a.iterator();
        while (try a_scan.next()) |x| {
            if (try viewArgumentsEqualDepth(elem, x, depth, ctx)) count_a += 1;
        }
        var count_b: usize = 0;
        var b_scan = b.iterator();
        while (try b_scan.next()) |y| {
            if (try viewArgumentsEqualDepth(elem, y, depth, ctx)) count_b += 1;
        }
        if (count_a != count_b) return false;
    }
    return true;
}

fn viewStructsEqualDepth(
    a: model.view.StructEntries,
    b: model.view.StructEntries,
    depth: usize,
    ctx: CompareCtx,
) CompareError!bool {
    if (depth > model.max_value_depth) return false;
    const a_len = try a.len();
    const b_len = try b.len();
    if (a_len != b_len) return false;
    var a_it = a.iterator();
    while (try a_it.next()) |entry| {
        const other = try findViewEntry(b, entry.key, ctx) orelse return false;
        if (!try viewArgumentsEqualDepth(entry.value, other, depth, ctx)) return false;
    }
    return true;
}

/// Resolves one key by scanning, so a struct comparison is quadratic in entry
/// count for the same reason a set comparison is; each scanned entry charges.
fn findViewEntry(
    entries: model.view.StructEntries,
    key: []const u8,
    ctx: CompareCtx,
) CompareError!?model.view.Argument {
    var it = entries.iterator();
    while (try it.next()) |entry| {
        try ctx.budget.charge();
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

fn viewHandoffsEqual(a: model.view.Handoff, b: model.view.Handoff, scratch: std.mem.Allocator) model.view.Error!bool {
    return switch (a) {
        .give => |x| b == .give and try viewGiveEqual(x, b.give, scratch),
        .receive => |x| b == .receive and
            std.mem.eql(u8, x.receiving_session, b.receive.receiving_session) and
            std.mem.eql(u8, x.receiving_side, b.receive.receiving_side) and
            x.handoff_count == b.receive.handoff_count and
            try viewGiveEqual(x.signed_give, b.receive.signed_give, scratch) and
            x.signature.eql(b.receive.signature),
    };
}

fn viewGiveEqual(a: model.view.HandoffGive, b: model.view.HandoffGive, scratch: std.mem.Allocator) model.view.Error!bool {
    return std.mem.eql(u8, a.recipient_key, b.recipient_key) and
        std.mem.eql(u8, a.exporter.transport, b.exporter.transport) and
        std.mem.eql(u8, a.exporter.designator, b.exporter.designator) and
        try viewHintsEqual(a.exporter.hints, b.exporter.hints, scratch) and
        std.mem.eql(u8, a.gifter_exporter_session, b.gifter_exporter_session) and
        std.mem.eql(u8, a.gifter_side, b.gifter_side) and
        std.mem.eql(u8, a.gift_id, b.gift_id) and
        a.signature.eql(b.signature);
}

fn materializeBorrowedHints(
    hints: model.view.BorrowedHints,
    scratch: std.mem.Allocator,
) model.view.Error!model.Hints {
    return switch (hints) {
        .empty => |wf| .{ .wire_form = wf },
        .projected => |h| h,
        .lazy => |l| try l.list.vtable.materialize(scratch, l.list, l.wire_form),
    };
}

fn viewHintsEqual(
    a: model.view.BorrowedHints,
    b: model.view.BorrowedHints,
    scratch: std.mem.Allocator,
) model.view.Error!bool {
    if (a.wireForm() != b.wireForm()) return false;
    const ah = try materializeBorrowedHints(a, scratch);
    const bh = try materializeBorrowedHints(b, scratch);
    return hintsEqual(ah, bh);
}

/// Element-wise structural equality on two argument slices (order-sensitive).
pub fn argumentSlicesEqual(a: []const model.Argument, b: []const model.Argument) bool {
    return argumentsEqual(.{ .list = a }, .{ .list = b });
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

/// Structural equality on two owned handoffs, over the same spine as the
/// borrowed comparison.
pub fn handoffsEqual(a: model.Handoff, b: model.Handoff) bool {
    var budget = CompareBudget.init(unbounded_visits);
    var no_scratch_buf: [0]u8 = .{};
    var no_scratch = std.heap.FixedBufferAllocator.init(&no_scratch_buf);
    return viewArgumentsEqualBounded(
        .{ .handoff = .fromOwned(&a) },
        .{ .handoff = .fromOwned(&b) },
        .{ .scratch = no_scratch.allocator(), .budget = &budget },
    ) catch unreachable;
}

fn hintsEqual(a: model.Hints, b: model.Hints) bool {
    if (a.wire_form != b.wire_form or a.entries.len != b.entries.len) return false;
    for (a.entries, b.entries) |ae, be| {
        if (!std.mem.eql(u8, ae.name, be.name)) return false;
        if (!hintValuesEqual(ae.value, be.value)) return false;
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
