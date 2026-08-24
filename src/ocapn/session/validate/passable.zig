//! Passable argument and reference validation.
//!
//! This module owns the one recursive walk shared by owned `model.*` values
//! and borrowed `model.view.*` projections. It validates reference roles,
//! nesting, handoff arguments, and set/struct uniqueness while recording every
//! introduced import for apply. It reads session authority but never mutates
//! it; only the caller-owned `IntroducedImports` turn record changes.

const std = @import("std");
const model = @import("model");
const session = @import("../mod.zig");
const locator_vocabulary = @import("locator_vocabulary.zig");

const Session = session.Session;
const Error = session.Error;
const RecvViewError = session.RecvViewError;
const SessionLimits = session.SessionLimits;
const BOOTSTRAP_POSITION = session.BOOTSTRAP_POSITION;

const inline_uniqueness_stack_cap = 8;

// The session validates two inbound representations: an owned `model.*`
// message and a borrowed `model.view.*` projection. Both Argument unions
// share arm names, so one set of `anytype` walkers serves both and keeps
// owned/borrowed validation in lockstep.

/// The record the inbound argument walk hands to apply: every far mention the
/// message introduces, plus the distinct-new tally the import cap is enforced
/// against. One walk serves both consumers, so an inbound deliver/resolve's
/// argument bytes are walked once here and never re-walked by apply
/// (`applyRecvShared` consumes `mentions` instead of traversing the borrowed
/// view again).
///
/// The import cap must hold at *validate* time: apply commits the answer row
/// before it installs imports, so an `ImportCapExceeded` first discovered in
/// apply would break the all-or-nothing contract in `apply.zig`. The walk
/// counts prospective installs against `SessionLimits.max_imports` with the
/// same rules `registerImport` applies (bootstrap excluded, already-held ids
/// are refcount refreshes, one new id counts once however often the message
/// repeats it). `seen` records those distinct fresh rows; `mentions` records
/// every non-bootstrap far mention — repeats included, each is one wire-delta
/// retain apply must take — and supports the cold exact-overflow check. Lazy: a
/// message that carries no far reference never allocates. The record spine
/// backs it with the per-turn `recv_scratch` arena (no deinit; the turn reset
/// reclaims it); a validation-only caller backs it with the gpa and pairs it
/// with `deinit`.
pub const IntroducedImports = struct {
    allocator: std.mem.Allocator,
    /// Distinct fresh rows for import-cap and capacity preparation. Already
    /// held rows stay off this map, preserving the steady-state allocation
    /// budget; exact overflow counting is a cold prepare branch.
    seen: std.AutoHashMapUnmanaged(model.ImportPosition, void) = .empty,
    mentions: std.ArrayListUnmanaged(model.ImportPosition) = .empty,
    /// Index in `mentions` owned by the answer's inline V1.0 resolver link,
    /// not by the surfaced application arguments. Stateless event GC excludes
    /// this retain; settlement releases it beside the resolver callback.
    resolver_mention_index: ?usize = null,
    /// Promise-shaped far mentions that require the next profile's one private
    /// shortening subscription. Repeats are retained here; the session table
    /// deduplicates by live import identity when the engine schedules them.
    promise_mentions: std.ArrayListUnmanaged(model.ImportPosition) = .empty,
    /// What is left of this message's equality-comparison allowance, spent by
    /// the set-uniqueness fold. It rides the per-turn record rather than the
    /// session because it is turn state: one record is built per recv entry
    /// point and threaded down the same walk that reaches the fold, so the
    /// bound is per message (a frame's many sets share one allowance) at no
    /// per-session footprint cost. Refilled by `init`, which every turn calls.
    compare_budget: model.equality.CompareBudget,

    pub fn init(allocator: std.mem.Allocator, limits: SessionLimits) IntroducedImports {
        return .{
            .allocator = allocator,
            .compare_budget = .init(limits.max_compare_visits),
        };
    }

    pub fn deinit(self: *IntroducedImports) void {
        self.seen.deinit(self.allocator);
        self.mentions.deinit(self.allocator);
        self.promise_mentions.deinit(self.allocator);
    }

    fn noteFar(self: *IntroducedImports, s: *Session, far: model.FarRef) RecvViewError!void {
        try self.noteIntroduction(s, far.import_position);
        if (far.kind == .promise) try self.promise_mentions.append(self.allocator, far.import_position);
    }

    /// Record a resolver descriptor as one introduced import without treating
    /// a promise-shaped resolver as a promise value that needs shortening.
    pub fn noteResolver(self: *IntroducedImports, s: *Session, far: model.FarRef) RecvViewError!void {
        std.debug.assert(self.resolver_mention_index == null);
        const prior_len = self.mentions.items.len;
        try self.noteIntroduction(s, far.import_position);
        if (self.mentions.items.len != prior_len)
            self.resolver_mention_index = prior_len;
    }

    /// Copy only application-argument imports for the surfaced event's
    /// stateless GC pass. The resolver retain remains answer-owned.
    pub fn dupeArgumentMentions(
        self: *const IntroducedImports,
        allocator: std.mem.Allocator,
    ) !?[]model.ImportPosition {
        const count = self.mentions.items.len - @intFromBool(self.resolver_mention_index != null);
        if (count == 0) return null;
        const result = try allocator.alloc(model.ImportPosition, count);
        var out: usize = 0;
        for (self.mentions.items, 0..) |position, index| {
            if (index == self.resolver_mention_index) continue;
            result[out] = position;
            out += 1;
        }
        std.debug.assert(out == count);
        return result;
    }

    fn noteIntroduction(self: *IntroducedImports, s: *Session, import_position: model.ImportPosition) RecvViewError!void {
        if (import_position.int() == BOOTSTRAP_POSITION) return;
        try self.mentions.append(self.allocator, import_position);
        if (s.imports.contains(import_position)) return;
        const gop = try self.seen.getOrPut(self.allocator, import_position);
        if (gop.found_existing) return;
        if (s.imports.len() + self.seen.count() > s.limits.max_imports) {
            return Error.ImportCapExceeded;
        }
    }
};

/// Whose message the one reference validator is looking at. A `near` names one
/// of our exports on both paths, but the admission rule differs by direction:
/// our own send needs only a live row (a reserved export may marshal — that
/// first marshal is what grants it), while a partner may only name an export
/// it holds a wire reference to. A reserved-but-ungranted position is refused
/// with the same `InvalidReference` as a nonexistent one, so a partner probing
/// positions cannot learn that a reservation exists (ADR-0074).
pub const Perspective = enum { sent, received };

/// How the one reference validator treats a `far`. Everything else about a
/// reference is position-independent — `promise`/`broken` are always
/// acceptable, and a `sturdy` always requires the negotiated sturdyref
/// feature — so beyond the `near` perspective rule, the `far` arm is the only
/// axis a position varies on.
pub const FarPolicy = enum {
    /// The `far` names an import we must already hold: a deliver/listen target,
    /// a projection receiver, or any reference we put on the wire ourselves.
    /// The bootstrap import (0) is implicitly held (ADR-0006). An unheld `far`
    /// here names a capability that does not exist for this session.
    held_import,
    /// The `far` is a fresh introduction — the partner handing us a new
    /// `<desc:import-object>` in argument or fulfill-payload position — accepted
    /// here and installed in apply. Every `u64` is valid; node-local routes use
    /// the distinct `Reference.routed` arm.
    introduction,
};

/// Validate the descriptor role shared by `op:deliver` and `op:listen`
/// targets, not merely the authority behind its integer. On send, a target is
/// one of the partner's exports (`far` -> wire `desc:export`) or an answer we
/// allocated (`promise` -> wire `desc:answer`). On receive those roles flip to
/// one of our granted exports (`near`) or an answer the partner allocated
/// (`promise`). A live answer is a row still present in the matching table,
/// pending or settled; `op:gc-answers` is what ends its addressability.
///
/// `anytype` keeps this one rule shared by owned and borrowed inbound paths.
pub fn validateDeliverOrListenTarget(
    self: *Session,
    reference: anytype,
    comptime perspective: Perspective,
) Error!void {
    switch (perspective) {
        .sent => switch (reference) {
            .far => try validateReference(self, reference, .sent, .held_import),
            .promise => |promise| {
                if (!self.outbound_answers.contains(promise.answer_position)) {
                    return Error.InvalidReference;
                }
            },
            else => return Error.InvalidReference,
        },
        .received => switch (reference) {
            .near => try validateReference(self, reference, .received, .held_import),
            .promise => |promise| {
                if (!self.inbound_answers.contains(.fromWire(promise.answer_position))) {
                    return Error.InvalidReference;
                }
            },
            else => return Error.InvalidReference,
        },
    }
}

/// Validate `op:listen`'s notification destination in its own descriptor role.
/// We send one of our exports (`near` -> wire `desc:import-*`); a partner sends
/// one of its exports as a fresh import (`far`, decoded from `desc:import-*`).
/// Targets and listener destinations are both references, but they are not
/// interchangeable protocol positions.
pub fn validateListenListener(
    self: *Session,
    reference: anytype,
    comptime perspective: Perspective,
) Error!void {
    switch (perspective) {
        .sent => switch (reference) {
            .near => try validateReference(self, reference, .sent, .held_import),
            else => return Error.InvalidReference,
        },
        .received => switch (reference) {
            .far => try validateReference(self, reference, .received, .introduction),
            else => return Error.InvalidReference,
        },
    }
}

/// The one reference-position validator. Post perspective-flip (ADR-0010) a
/// decoded `near` names one of our exports; the `near` arm varies by
/// `perspective` and the `far` arm by `far_policy`. Dual-shape over the
/// borrowed view reference and the owned `model.Reference`, like the argument
/// walkers that call it.
pub fn validateReference(
    self: *Session,
    reference: anytype,
    comptime perspective: Perspective,
    comptime far_policy: FarPolicy,
) Error!void {
    return switch (reference) {
        .routed => Error.InvalidReference,
        .near => |near| validateNearReference(self, near, perspective),
        .far => |far| validateFarReference(self, far, far_policy),
        .promise, .broken => {},
        .sturdy => |sturdy| validateSturdyReference(self, sturdy),
    };
}

fn validateNearReference(self: *Session, near: model.NearRef, comptime perspective: Perspective) Error!void {
    switch (perspective) {
        .sent => if (!self.exports.contains(near.export_position)) return Error.InvalidReference,
        .received => if (near.export_position.int() != BOOTSTRAP_POSITION and
            self.exports.wireHeld(near.export_position) == 0)
            return Error.InvalidReference,
    }
}

fn validateFarReference(self: *Session, far: model.FarRef, comptime far_policy: FarPolicy) Error!void {
    switch (far_policy) {
        .held_import => if (!self.holdsImport(far.import_position)) return Error.InvalidReference,
        .introduction => {},
    }
}

fn validateSturdyReference(self: *Session, sturdy: anytype) Error!void {
    if (!self.features.sturdyref) return Error.FeatureNotNegotiated;
    const value = if (comptime @typeInfo(@TypeOf(sturdy)) == .pointer)
        sturdy.*
    else
        sturdy;
    try locator_vocabulary.requireNegotiated(self, value.peer);
}

pub fn validateInboundArguments(
    self: *Session,
    args: anytype,
    depth: usize,
    introduced: *IntroducedImports,
) RecvViewError!void {
    if (depth > self.limits.max_nesting_depth) return Error.NestingTooDeep;
    if (comptime @TypeOf(args) == model.view.Args) {
        // Forward cursor: one linear pass over the borrowed list region, no
        // per-element `at(i)` re-scan from the start and no `len()` pre-walk.
        var it = args.iterator();
        while (try it.next()) |arg| try validateInboundArgument(self, arg, depth, introduced);
    } else {
        for (args) |arg| try validateInboundArgument(self, arg, depth, introduced);
    }
}

pub fn validateInboundArgument(
    self: *Session,
    arg: anytype,
    depth: usize,
    introduced: *IntroducedImports,
) RecvViewError!void {
    switch (arg) {
        .reference => |reference| {
            try validateReference(self, reference, .received, .introduction);
            if (reference == .far) try introduced.noteFar(self, reference.far);
        },
        .list => |items| try validateInboundArguments(self, items, depth + 1, introduced),
        .set => |items| {
            try validateInboundArguments(self, items, depth + 1, introduced);
            try checkInboundSetUniqueness(self, items, introduced);
        },
        .tagged => |tagged| try validateInboundArguments(self, tagged.value, depth + 1, introduced),
        .@"struct" => |entries| try validateInboundStructEntries(self, entries, depth + 1, introduced),
        // Exhaustive on purpose: a new Argument arm must decide here whether it
        // can carry a reference. The struct arm above was once missed behind an
        // `else`, which let a struct-wrapped reference dodge this walk entirely.
        .handoff => |handoff| try validateInboundHandoffArgument(self, handoff),
        .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error" => {},
    }
}

/// A set admits each member once: two Equal elements are two wire encodings of
/// one set, so an inbound duplicate is refused (`DuplicateSetElement`) instead
/// of admitted. The Syrup decoder already refuses this at the byte layer
/// (strictly ascending encoded elements), so in practice this fold is the
/// backstop that holds the same invariant for Cap'n Proto — whose pointer wire
/// form cannot prove uniqueness for free — and for any future codec. It runs
/// on the shared walk, so both the borrowed view path and the owned fallback
/// enforce it identically. Borrowed elements are hashed/compared as views
/// (`viewArgumentHash` / `viewArgumentsEqualBounded`) — scratch holds only the view
/// handles and hash rows, never a `toOwned` materialization. The owned
/// fallback projects through the same spine (`argumentsEqualBounded`) and
/// charges the same per-message budget, so the two arms cannot drift in
/// semantics or in cost. A hash group is confirmed before refusing,
/// so a collision never causes a false refusal. Confirming is not free: two
/// sets compare as multisets, so an equal-hashed pair of width N costs on the
/// order of N² element visits, and the commutative set hash lets a partner
/// build that pair deliberately. Every visit therefore charges the session's
/// per-message budget (`SessionLimits.max_compare_visits`), which refuses
/// loudly rather than grinding. The nesting depth of every element was already
/// bounded by the surrounding walk.
fn checkInboundSetUniqueness(
    self: *Session,
    items: anytype,
    introduced: *IntroducedImports,
) RecvViewError!void {
    const arena = self.recv_scratch.allocator();
    if (comptime @TypeOf(items) == model.view.Args) {
        // Cap'n Proto reads this off the list header; Syrup walks the region to
        // count it. Either way the walk below must agree with it, and the two
        // answers come from different files, so the loop checks rather than
        // trusts.
        const count = try items.len();
        if (count < 2) return;
        // Small sets stay on the stack so the common deliver path never grows
        // `recv_scratch` past its retain limit (a per-turn arena grow would
        // break the flat scratch budget in deliver_set_scratch_budget_test).
        var stack_elements: [inline_uniqueness_stack_cap]model.view.Argument = undefined;
        var stack_rows: [inline_uniqueness_stack_cap]SetHashRow = undefined;
        const elements: []model.view.Argument = if (count <= inline_uniqueness_stack_cap)
            stack_elements[0..count]
        else
            try arena.alloc(model.view.Argument, count);
        const rows: []SetHashRow = if (count <= inline_uniqueness_stack_cap)
            stack_rows[0..count]
        else
            try arena.alloc(SetHashRow, count);
        var it = items.iterator();
        var i: usize = 0;
        while (try it.next()) |element| : (i += 1) {
            // A walk that outruns the count would write past `elements`, and
            // the small arm is a stack array. A walk that falls short would
            // leave rows undefined for the sort to order and then index
            // `elements` by. `model.view`'s own `toOwnedSliceDepth` guards
            // both directions; this fold is the one place that did not.
            if (i >= elements.len) return Error.MalformedMessage;
            elements[i] = element;
            rows[i] = .{ .hash = try model.equality.viewArgumentHash(element), .index = i };
        }
        if (i != elements.len) return Error.MalformedMessage;
        std.mem.sort(SetHashRow, rows, {}, SetHashRow.lessThan);
        var run_start: usize = 0;
        for (rows, 0..) |row, ri| {
            if (row.hash != rows[run_start].hash) run_start = ri;
            for (rows[run_start..ri]) |prior| {
                if (try model.equality.viewArgumentsEqualBounded(
                    elements[prior.index],
                    elements[row.index],
                    .{ .scratch = arena, .budget = &introduced.compare_budget },
                )) {
                    return Error.DuplicateSetElement;
                }
            }
        }
        return;
    }
    // Same per-message allowance as the borrowed arm above: whichever arm a
    // message's sets take, one budget bounds the whole message's confirms.
    try checkOwnedSetUniqueness(arena, items, &introduced.compare_budget);
}

/// One hash row of the set-uniqueness fold: sort by hash so Equal elements
/// land adjacent, confirm with a real compare before refusing.
const SetHashRow = struct {
    hash: u64,
    index: usize,
    fn lessThan(_: void, a: @This(), b: @This()) bool {
        return a.hash < b.hash;
    }
};

/// The owned-slice arm of the set-uniqueness fold, shared by the inbound
/// owned fallback above and the send-side walk (`validateArgument`). The
/// inbound path hands the recv arena (rows die in the turn reset); the send
/// path hands the session gpa (no recv turn brackets a send), so small sets
/// stay on the stack and a spilled row slice is freed here precisely.
/// Confirming charges `budget` per element visit exactly as the borrowed fold
/// does — both folds run the one comparison spine — so a partner-influenced
/// owned tree (a stored relayed resolution) buys bounded work, not trusted
/// work.
fn checkOwnedSetUniqueness(
    scratch: std.mem.Allocator,
    elements: []const model.Argument,
    budget: *model.equality.CompareBudget,
) error{ OutOfMemory, DuplicateSetElement, CompareBudgetExhausted }!void {
    if (elements.len < 2) return;
    var stack_rows: [inline_uniqueness_stack_cap]SetHashRow = undefined;
    const spilled = elements.len > inline_uniqueness_stack_cap;
    const rows: []SetHashRow = if (spilled)
        try scratch.alloc(SetHashRow, elements.len)
    else
        stack_rows[0..elements.len];
    defer if (spilled) scratch.free(rows);
    for (elements, 0..) |element, idx| {
        rows[idx] = .{ .hash = model.equality.argumentHash(element), .index = idx };
    }
    std.mem.sort(SetHashRow, rows, {}, SetHashRow.lessThan);
    var run_start: usize = 0;
    for (rows, 0..) |row, ri| {
        if (row.hash != rows[run_start].hash) run_start = ri;
        for (rows[run_start..ri]) |prior| {
            const equal = model.equality.argumentsEqualBounded(
                &elements[prior.index],
                &elements[row.index],
                .{ .scratch = scratch, .budget = budget },
            ) catch |err| switch (err) {
                // An owned tree projects slice-backed with `.projected`
                // hints, so the lazy-view failure arm cannot fire on it.
                error.MalformedView => unreachable,
                error.OutOfMemory => return error.OutOfMemory,
                error.CompareBudgetExhausted => return error.CompareBudgetExhausted,
            };
            if (equal) return error.DuplicateSetElement;
        }
    }
}

/// Refuse a send-side struct carrying two entries with the same key, the
/// validate-time twin of the codecs' canonical-order refusals (ADR-0003).
/// Sorts a shallow copy of the borrowed key slices so a repeat is an adjacent
/// pair; small structs stay on the stack, a spill is freed here precisely.
fn checkSentStructKeyUniqueness(
    scratch: std.mem.Allocator,
    entries: []const model.StructEntry,
) error{ OutOfMemory, DuplicateStructKey }!void {
    if (entries.len < 2) return;
    var stack_keys: [inline_uniqueness_stack_cap][]const u8 = undefined;
    const spilled = entries.len > inline_uniqueness_stack_cap;
    const keys: [][]const u8 = if (spilled)
        try scratch.alloc([]const u8, entries.len)
    else
        stack_keys[0..entries.len];
    defer if (spilled) scratch.free(keys);
    for (entries, 0..) |entry, i| keys[i] = entry.key;
    std.mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    for (keys[1..], 0..) |key, i| {
        if (std.mem.eql(u8, keys[i], key)) return error.DuplicateStructKey;
    }
}

/// Struct entries carry full argument values, so a reference can arrive inside
/// one; walk every entry's value like a list element. Dual-shape like its
/// callers: the borrowed `model.view.StructEntries` walks its lazy cursor,
/// the owned slice walks directly.
fn validateInboundStructEntries(
    self: *Session,
    entries: anytype,
    depth: usize,
    introduced: *IntroducedImports,
) RecvViewError!void {
    if (depth > self.limits.max_nesting_depth) return Error.NestingTooDeep;
    if (comptime @TypeOf(entries) == model.view.StructEntries) {
        var it = entries.iterator();
        while (try it.next()) |entry| try validateInboundArgument(self, entry.value, depth, introduced);
    } else {
        for (entries) |entry| try validateInboundArgument(self, entry.value, depth, introduced);
    }
}

/// Handoff certificates enter CapTP as nested passable values, not as their
/// own operation. Enforce the negotiated gate and structural floor at that
/// real entry point for both borrowed and owned argument trees.
fn validateHandoffArgument(self: *const Session, handoff: anytype) Error!void {
    if (!self.features.handoff) return Error.FeatureNotNegotiated;
    const value = if (comptime @typeInfo(@TypeOf(handoff)) == .pointer)
        handoff.*
    else
        handoff;
    try session.validateHandoffWellFormed(value);
    const give = switch (value) {
        .give => |give| give,
        .receive => |receive| receive.signed_give,
    };
    try validateHandoffGiftId(self.captp_version, give.gift_id);
    try locator_vocabulary.requireNegotiated(self, give.exporter);
}

/// Validate the profile-specific gift-id domain used by every nested handoff
/// argument and by bootstrap admission before it retains an id.
pub fn validateHandoffGiftId(captp_version: model.CaptpVersion, gift_id: []const u8) Error!void {
    if (captp_version == .next and gift_id.len != model.HANDOFF_GIFT_ID_BYTES) {
        return Error.MalformedMessage;
    }
}

/// A give is addressed to the local key of the session on which it arrived.
/// Check that claim in session authority before Host can project its locator or
/// queue a dial. A receive embeds the same give on a different session, so it
/// deliberately does not take this Receiver-side check.
fn validateInboundHandoffArgument(self: *const Session, handoff: anytype) Error!void {
    try validateHandoffArgument(self, handoff);
    const value = if (comptime @typeInfo(@TypeOf(handoff)) == .pointer)
        handoff.*
    else
        handoff;
    switch (value) {
        .give => |give| {
            const local_key = self.localSessionKey() orelse return Error.InvalidHandoffSession;
            if (!std.mem.eql(u8, give.recipient_key, local_key)) return Error.InvalidGift;
        },
        .receive => {},
    }
}

/// A give leaves on the session whose partner is its recipient. Validate that
/// address before retaining any arguments or answer state. A receive embeds a
/// give minted on another session, so its recipient key is not this partner's.
fn validateOutboundHandoffArgument(self: *const Session, handoff: model.Handoff) Error!void {
    try validateHandoffArgument(self, handoff);
    switch (handoff) {
        .give => |give| {
            const partner_key = self.partnerSessionKey() orelse return Error.InvalidHandoffSession;
            if (!std.mem.eql(u8, give.recipient_key, partner_key)) return Error.InvalidGift;
        },
        .receive => {},
    }
}

/// How the send-side walker treats a leaf `reference`. Both send paths hold
/// every reference to the same rule, and differ on exactly one arm.
///
/// A deliver's arguments must each name something this session already holds
/// (`.held`). A resolve's fulfill payload exempts the `near` arm
/// (`.near_may_be_first_export`), because resolving an answer with a `.near`
/// is how the application exports that object for the first time: there is no
/// export row yet, and `retainSentExportRef` mints one, admitting the position
/// through `admitExportPositionForMarshal` so it must still be a name in this
/// session's own range.
///
/// The exemption stops at that arm. A `far` names the partner's export on
/// *this* session and nowhere else, so one this session does not hold names
/// nothing here: the fulfill would put `<desc:export N>` on the wire for an
/// export this partner never made. Nothing downstream recovers it. A partner
/// that numbers its exports from zero, as Goblins does, is liable to hold a
/// live and unrelated object at that number, so the reference designates the
/// wrong capability instead of failing; a partner that does not holds nothing
/// there and refuses the whole session. The far arm of the deliver path's
/// rule is what closes it, and it is the import-side twin of the export-range
/// admission `retainSentExportRef` already performs for the `near` arm above.
pub const SendRefCheck = enum { held, near_may_be_first_export };

/// Validate a send-side argument tree: bound the nesting past
/// `max_nesting_depth`, and check each leaf reference per `ref_check`. The
/// depth bound is the twin of the apply-side `retainSentExportArgs` cap: on
/// both send paths a too-deep locally-built message would otherwise pass
/// validation and then trip `NestingTooDeep` mid-walk in send-side export accounting,
/// over-retaining every shallow export mention before the refusal and
/// breaching apply's all-or-nothing contract. One walk, one depth threshold,
/// so the cap cannot drift between the deliver and resolve paths. `ref_check`
/// is comptime, so the reference branch folds away per call site.
/// Send-side argument validation allocates bounded scratch for the set /
/// struct-key uniqueness folds (gpa, stack-first), so the walk carries the
/// allocator errors the pure reference checks do not.
pub const SendArgError = Error || std.mem.Allocator.Error;

pub fn validateArguments(self: *Session, args: []const model.Argument, depth: usize, comptime ref_check: SendRefCheck) SendArgError!void {
    if (depth > self.limits.max_nesting_depth) return Error.NestingTooDeep;
    for (args) |arg| {
        try validateArgument(self, arg, depth, ref_check);
    }
}

pub fn validateArgument(self: *Session, arg: model.Argument, depth: usize, comptime ref_check: SendRefCheck) SendArgError!void {
    switch (arg) {
        .reference => |reference| switch (ref_check) {
            .held => try validateReference(self, reference, .sent, .held_import),
            // Only the `near` arm is exempt; see `SendRefCheck`.
            .near_may_be_first_export => switch (reference) {
                .near => |near| try self.validateExportPositionForMarshal(near.export_position),
                else => try validateReference(self, reference, .sent, .held_import),
            },
        },
        .list => |items| try validateArguments(self, items, depth + 1, ref_check),
        .set => |items| {
            try validateArguments(self, items, depth + 1, ref_check);
            // A duplicate set element refuses here, pre-commit, symmetric with
            // the inbound fold. The encoders refuse byte-equal duplicates too
            // (ADR-0003), but only at encode time in `step`, after
            // send-side export accounting committed wire-delta retains for a frame
            // that never ships, the same all-or-nothing breach the depth
            // bound above closes. This fold is at least as strict as encode:
            // model-Equal-but-byte-distinct forms (two NaN bit patterns)
            // refuse only here, exactly as they would inbound. No message-wide
            // budget brackets a send, so each fold mints its own allowance —
            // per set rather than per message, which still bounds the one
            // partner-influenced caller (`validateStoredResolution`, a relayed
            // fulfillment) at the same rate the inbound fold charges.
            var compare_budget = model.equality.CompareBudget.init(self.limits.max_compare_visits);
            try checkOwnedSetUniqueness(self.allocator, items, &compare_budget);
        },
        .tagged => |tagged| try validateArguments(self, tagged.value, depth + 1, ref_check),
        .@"struct" => |entries| {
            if (depth + 1 > self.limits.max_nesting_depth) return Error.NestingTooDeep;
            for (entries) |entry| try validateArgument(self, entry.value, depth + 1, ref_check);
            // Duplicate struct keys share the set arm's contract: refuse
            // pre-commit, not at encode.
            try checkSentStructKeyUniqueness(self.allocator, entries);
        },
        // Exhaustive on purpose, see `validateInboundArgument`.
        .handoff => |handoff| try validateOutboundHandoffArgument(self, handoff.*),
        .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error" => {},
    }
}
