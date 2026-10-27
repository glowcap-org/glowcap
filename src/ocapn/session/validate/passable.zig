//! Passable argument and reference validation.
//!
//! This module owns the one recursive walk shared by owned `model.*` values
//! and borrowed `model.view.*` projections. It validates reference roles,
//! nesting, handoff arguments, and set/struct uniqueness while recording every
//! introduced import for apply. It reads session authority but never mutates
//! it. Only the caller-owned `IntroducedImports` turn record changes.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const session = @import("../mod.zig");
const locator_vocabulary = @import("locator_vocabulary.zig");
const set_uniqueness = @import("set_uniqueness.zig");

const Session = session.Session;
const Error = session.Error;
const RecvViewError = session.RecvViewError;
const bootstrap_position = session.bootstrap_position;

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
/// repeats it). `seen` records those distinct fresh rows. `mentions` records
/// every non-bootstrap far mention, repeats included, each is one wire-delta
/// retain apply must take, and supports the cold exact-overflow check. A
/// message with a few mentions allocates nothing: each record holds its first
/// rows in place and spills to the record's allocator only past that. The
/// record spine backs it with the per-turn `recv_scratch` arena (no deinit,
/// the turn reset reclaims it). A validation-only caller backs it with the
/// gpa and pairs it with `deinit`.
pub const IntroducedImports = struct {
    allocator: std.mem.Allocator,
    /// Distinct fresh rows for import-cap and capacity preparation. Already
    /// held rows stay off this table, preserving the steady-state allocation
    /// budget. Exact overflow counting is a cold prepare branch. The
    /// positions are the peer's words.
    seen: foundation.inline_rows.Table(model.ImportPosition, void, 4, .wire),
    mentions: foundation.inline_rows.List(model.ImportPosition, 4),
    /// Index in `mentions` owned by the answer's inline V1.0 resolver link,
    /// not by the surfaced application arguments. Stateless event GC excludes
    /// this retain. Settlement releases it beside the resolver callback.
    resolver_mention_index: ?usize,
    /// Promise-shaped far mentions that require the next profile's one private
    /// shortening subscription. Repeats are retained here. The session table
    /// deduplicates by live import identity when the engine schedules them.
    promise_mentions: foundation.inline_rows.List(model.ImportPosition, 2),
    /// What is left of this message's equality-comparison allowance, spent by
    /// the set-uniqueness fold. It rides the per-turn record rather than the
    /// session because it is turn state: one record is built per recv entry
    /// point and threaded down the same walk that reaches the fold, so the
    /// bound is per message (a frame's many sets share one allowance) at no
    /// per-session footprint cost. Refilled by `init`, which every turn calls.
    compare_budget: model.equality.CompareBudget,
    /// How many reference and handoff slots the walked arguments hold, at
    /// every depth. A deliver event carries it out so a Host handler whose
    /// delivery holds none reads the frame's views without a lift.
    reference_slots: u32,

    /// Fill `self` in place: one record per turn, whose inline rows stay
    /// unwritten until a mention lands.
    pub fn init(self: *IntroducedImports, allocator: std.mem.Allocator, s: *const Session) void {
        self.allocator = allocator;
        self.seen.initKeyed(s.wire_hash_multiplier);
        self.mentions.init();
        self.resolver_mention_index = null;
        self.promise_mentions.init();
        self.compare_budget = .init(s.limits.max_compare_visits);
        self.reference_slots = 0;
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
        const prior_len = self.mentions.count();
        try self.noteIntroduction(s, far.import_position);
        if (self.mentions.count() != prior_len)
            self.resolver_mention_index = prior_len;
    }

    /// Copy only application-argument imports for the surfaced event's
    /// stateless GC pass. The resolver retain remains answer-owned.
    pub fn dupeArgumentMentions(
        self: *const IntroducedImports,
        allocator: std.mem.Allocator,
    ) !?[]model.ImportPosition {
        const count = self.mentions.count() - @intFromBool(self.resolver_mention_index != null);
        if (count == 0) return null;
        const result = try allocator.alloc(model.ImportPosition, count);
        var out: usize = 0;
        for (self.mentions.items(), 0..) |position, index| {
            if (index == self.resolver_mention_index) continue;
            result[out] = position;
            out += 1;
        }
        std.debug.assert(out == count);
        return result;
    }

    fn noteIntroduction(self: *IntroducedImports, s: *Session, import_position: model.ImportPosition) RecvViewError!void {
        if (import_position.int() == bootstrap_position) return;
        try self.mentions.append(self.allocator, import_position);
        if (s.imports.contains(import_position)) return;
        const gop = try self.seen.getOrPut(self.allocator, import_position);
        if (gop.found_existing) return;
        if (s.imports.len() + self.seen.count() > s.limits.max_imports) {
            return error.ImportCapExceeded;
        }
    }
};

/// Whose message the one reference validator is looking at. A `near` names one
/// of our exports on both paths, but the admission rule differs by direction:
/// our own send needs only a live row (a reserved export may marshal, that
/// first marshal is what grants it), while a partner may only name an export
/// it holds a wire reference to. A reserved-but-ungranted position is refused
/// with the same `InvalidReference` as a nonexistent one, so a partner probing
/// positions cannot learn that a reservation exists (ADR-0027).
pub const Perspective = enum { sent, received };

/// Which message carries the reference. A `desc:answer` names a question its
/// sender asked, in a call and in a resolution alike: the position is the
/// asker's, and CapTP has no form for the receiving side to name an answer
/// back (upstream issue 168). A resolution this session sends admits none,
/// because a pipelined call on the settled answer would need a chain target
/// stored here while the named question lives at the partner, and a promise
/// travels as its projection instead. On send, the carrier also decides the `near` rule: a call's
/// arguments name exports this session already holds, while a resolution's
/// payload may export an object for the first time (`retainSentExportRef`
/// mints its row through `validateExportPositionForMarshal`, so the position
/// must still be a name in this session's own range).
///
/// That exemption stops at the `near` arm. A `far` names the partner's export
/// on *this* session and nowhere else, so one this session does not hold names
/// nothing here: the fulfill would put `<desc:export N>` on the wire for an
/// export this partner never made. Nothing downstream recovers it. A partner
/// that numbers its exports from zero, as Goblins does, is liable to hold a
/// live and unrelated object at that number, so the reference designates the
/// wrong capability instead of failing. A partner that does not holds nothing
/// there and refuses the whole session. The far arm of the call rule is what
/// closes it, the import-side twin of the export-range admission above.
pub const Carrier = enum { call, resolution };

/// How the one reference validator treats a `far`. A `broken` is always
/// acceptable, a `promise` follows `Carrier`, and a `sturdy` always requires
/// the negotiated sturdyref feature, so beyond the `near` perspective rule,
/// the `far` arm is the only other axis a position varies on.
pub const FarPolicy = enum {
    /// The `far` names an import we must already hold: a deliver/listen target,
    /// a projection receiver, or any reference we put on the wire ourselves.
    /// The bootstrap import (0) is implicitly held (ADR-0002). An unheld `far`
    /// here names a capability that does not exist for this session.
    held_import,
    /// The `far` is a fresh introduction, the partner handing us a new
    /// `<desc:import-object>` in argument or fulfill-payload position, accepted
    /// here and installed in apply. Every `u64` is valid. Node-local routes use
    /// the distinct `Reference.routed` arm.
    introduction,
};

/// Validate the descriptor role shared by `op:deliver` and `op:listen`
/// targets, not merely the authority behind its integer. On send, a target is
/// one of the partner's exports (`far` -> wire `desc:export`) or an answer we
/// allocated (`promise` -> wire `desc:answer`). On receive those roles flip to
/// one of our granted exports (`near`) or an answer the partner allocated
/// (`promise`). A live answer is a row still present in the matching table,
/// pending or settled. `op:gc-answers` is what ends its addressability.
///
/// `anytype` keeps this one rule shared by owned and borrowed inbound paths.
pub fn validateDeliverOrListenTarget(
    self: *Session,
    reference: anytype,
    comptime perspective: Perspective,
) ReferenceError(@TypeOf(reference))!void {
    switch (perspective) {
        .sent => switch (reference) {
            .far => try validateReference(self, reference, .sent, .held_import, .call),
            .promise => |promise| try validatePromiseReference(self, promise, .sent, .call),
            else => return error.InvalidReference,
        },
        .received => switch (reference) {
            .near => try validateReference(self, reference, .received, .held_import, .call),
            .promise => |promise| try validatePromiseReference(self, promise, .received, .call),
            else => return error.InvalidReference,
        },
    }
}

/// Validate `op:listen`'s notification destination in its own descriptor role.
/// We send one of our exports (`near` -> wire `desc:import-*`). A partner sends
/// one of its exports as a fresh import (`far`, decoded from `desc:import-*`).
/// Targets and listener destinations are both references, but they are not
/// interchangeable protocol positions.
pub fn validateListenListener(
    self: *Session,
    reference: anytype,
    comptime perspective: Perspective,
) ReferenceError(@TypeOf(reference))!void {
    switch (perspective) {
        .sent => switch (reference) {
            .near => try validateReference(self, reference, .sent, .held_import, .call),
            else => return error.InvalidReference,
        },
        .received => switch (reference) {
            .far => try validateReference(self, reference, .received, .introduction, .call),
            else => return error.InvalidReference,
        },
    }
}

/// The one reference-position validator. Post perspective-flip (ADR-0006) a
/// decoded `near` names one of our exports. The `near` arm varies by
/// `perspective` and the `far` arm by `far_policy`. Dual-shape over the
/// borrowed view reference and the owned `model.Reference`, like the argument
/// walkers that call it.
pub fn validateReference(
    self: *Session,
    reference: anytype,
    comptime perspective: Perspective,
    comptime far_policy: FarPolicy,
    comptime carrier: Carrier,
) ReferenceError(@TypeOf(reference))!void {
    return switch (reference) {
        .routed => Error.InvalidReference,
        .near => |near| validateNearReference(self, near, perspective),
        .far => |far| validateFarReference(self, far, far_policy),
        .promise => |promise| validatePromiseReference(self, promise, perspective, carrier),
        .broken => {},
        .sturdy => |sturdy| validateSturdyReference(self, sturdy),
    };
}

/// A `desc:answer` names a live question its sender asked, wherever the
/// descriptor sits: as a target or inside an argument or payload tree, a sent
/// one is in `outbound_answers` and a received one in `inbound_answers`. The
/// position is a promise only while that row lives (CapTP `desc:answer`), and
/// an unknown one would alias the next question asked at that position. A
/// sent resolution admits none (`Carrier`).
fn validatePromiseReference(
    self: *Session,
    promise: anytype,
    comptime perspective: Perspective,
    comptime carrier: Carrier,
) Error!void {
    if (perspective == .sent and carrier == .resolution) return error.InvalidReference;
    const live = switch (perspective) {
        .sent => self.outbound_answers.contains(promise.answer_position),
        .received => self.inbound_answers.contains(.fromWire(promise.answer_position)),
    };
    if (!live) return error.InvalidReference;
}

fn validateNearReference(self: *Session, near: model.NearRef, comptime perspective: Perspective) Error!void {
    switch (perspective) {
        .sent => if (!self.exports.contains(near.export_position)) return error.InvalidReference,
        .received => if (near.export_position.int() != bootstrap_position and
            self.exports.wireHeld(near.export_position) == 0)
            return error.InvalidReference,
    }
}

fn validateFarReference(self: *Session, far: model.FarRef, comptime far_policy: FarPolicy) Error!void {
    switch (far_policy) {
        .held_import => if (!self.holdsImport(far.import_position)) return error.InvalidReference,
        .introduction => {},
    }
}

fn validateSturdyReference(self: *Session, sturdy: anytype) ReferenceError(@TypeOf(sturdy))!void {
    if (!self.features.sturdyref) return error.FeatureNotNegotiated;
    const value = if (comptime @TypeOf(sturdy) == model.view.LazySturdyRef)
        try sturdy.project()
    else if (comptime @typeInfo(@TypeOf(sturdy)) == .pointer)
        sturdy.*
    else
        sturdy;
    try locator_vocabulary.requireNegotiated(self, value.peer);
}

/// The error set a reference validator returns for one reference shape. A
/// borrowed view may fail to project its lazy sturdyref, so it carries
/// `ProjectError`; an owned reference is already parsed and never does, and
/// its callers keep the plain session error set.
pub fn ReferenceError(comptime T: type) type {
    return if (T == model.view.Reference or T == model.view.LazySturdyRef)
        Error || model.view.ProjectError
    else
        Error;
}

pub fn validateInboundArguments(
    self: *Session,
    args: anytype,
    depth: usize,
    introduced: *IntroducedImports,
    comptime carrier: Carrier,
) RecvViewError!void {
    if (depth > self.limits.max_nesting_depth) return error.NestingTooDeep;
    if (comptime @TypeOf(args) == model.view.Args) {
        // A word run holds integers only, bounded by the codec that read
        // it, so there is no element here to visit.
        if (args.wordRun() != null) return;
        // Forward cursor: one linear pass over the borrowed list region, no
        // per-element `at(i)` re-scan from the start and no `len()` pre-walk.
        var it = args.iterator();
        while (try it.nextRef()) |arg| try validateInboundArgument(self, arg, depth, introduced, carrier);
    } else {
        for (args) |*arg| try validateInboundArgument(self, arg, depth, introduced, carrier);
    }
}

pub inline fn validateInboundArgument(
    self: *Session,
    arg: anytype,
    depth: usize,
    introduced: *IntroducedImports,
    comptime carrier: Carrier,
) RecvViewError!void {
    switch (arg.*) {
        .reference => |reference| {
            try validateReference(self, reference, .received, .introduction, carrier);
            if (reference == .far) try introduced.noteFar(self, reference.far);
            introduced.reference_slots += 1;
        },
        .list => |items| try validateInboundArguments(self, items, depth + 1, introduced, carrier),
        .set => |items| {
            try validateInboundArguments(self, items, depth + 1, introduced, carrier);
            const scratch = self.recv_scratch.allocator();
            if (comptime @TypeOf(items) == model.view.Args) {
                try set_uniqueness.checkBorrowed(scratch, items, &introduced.compare_budget);
            } else {
                try set_uniqueness.checkOwned(scratch, items, &introduced.compare_budget);
            }
        },
        .tagged => |tagged| try validateInboundArguments(self, tagged.value, depth + 1, introduced, carrier),
        .@"struct" => |entries| try validateInboundStructEntries(self, entries, depth + 1, introduced, carrier),
        // Exhaustive: a new Argument arm must decide here whether it
        // can carry a reference. The struct arm above was once missed behind an
        // `else`, which let a struct-wrapped reference dodge this walk entirely.
        .handoff => |handoff| {
            try validateInboundHandoffArgument(
                self,
                if (comptime @TypeOf(handoff) == model.view.LazyHandoff) try handoff.project() else handoff,
            );
            introduced.reference_slots += 1;
        },
        .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error" => {},
    }
}

/// Refuse a send-side struct carrying two entries with the same key, the
/// validate-time twin of the codecs' canonical-order refusals (ADR-0001).
/// Sorts a shallow copy of the borrowed key slices so a repeat is an adjacent
/// pair. Small structs stay on the stack, a spill is freed here. Dual-shape:
/// `entries` is an owned slice or a borrowed `model.view.StructEntries`,
/// whose walk and `len` must agree or the struct is `MalformedView`.
pub fn checkSentStructKeyUniqueness(
    scratch: std.mem.Allocator,
    entries: anytype,
) (error{ OutOfMemory, DuplicateStructKey } || model.view.ProjectError)!void {
    const borrowed = comptime @TypeOf(entries) == model.view.StructEntries;
    const count = if (borrowed) try entries.len() else entries.len;
    if (count < 2) return;
    var stack_keys: [inline_uniqueness_stack_cap][]const u8 = undefined;
    const spilled = count > inline_uniqueness_stack_cap;
    const keys: [][]const u8 = if (spilled)
        try scratch.alloc([]const u8, count)
    else
        stack_keys[0..count];
    defer if (spilled) scratch.free(keys);
    if (borrowed) {
        var it = entries.iterator();
        var filled: usize = 0;
        while (try it.nextRef()) |entry| : (filled += 1) {
            if (filled == count) return error.MalformedView;
            keys[filled] = entry.key;
        }
        if (filled != count) return error.MalformedView;
    } else {
        for (entries, 0..) |entry, i| keys[i] = entry.key;
    }
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
/// one. Walk every entry's value like a list element. Dual-shape like its
/// callers: the borrowed `model.view.StructEntries` walks its lazy cursor,
/// the owned slice walks directly.
fn validateInboundStructEntries(
    self: *Session,
    entries: anytype,
    depth: usize,
    introduced: *IntroducedImports,
    comptime carrier: Carrier,
) RecvViewError!void {
    if (depth > self.limits.max_nesting_depth) return error.NestingTooDeep;
    if (comptime @TypeOf(entries) == model.view.StructEntries) {
        var it = entries.iterator();
        while (try it.nextRef()) |entry| try validateInboundArgument(self, &entry.value, depth, introduced, carrier);
    } else {
        for (entries) |*entry| try validateInboundArgument(self, &entry.value, depth, introduced, carrier);
    }
}

/// Handoff certificates enter CapTP as nested passable values, not as their
/// own operation. Enforce the negotiated gate and structural floor at that
/// real entry point for both borrowed and owned argument trees.
fn validateHandoffArgument(self: *const Session, handoff: anytype) Error!void {
    if (!self.features.handoff) return error.FeatureNotNegotiated;
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
    if (captp_version == .next and gift_id.len != model.handoff_gift_id_bytes) {
        return error.MalformedMessage;
    }
}

/// A give is addressed to the local key of the session on which it arrived.
/// Check that claim in session authority before Host can project its locator or
/// queue a dial. A receive embeds the same give on a different session, so it
/// does not take this Receiver-side check.
fn validateInboundHandoffArgument(self: *const Session, handoff: anytype) Error!void {
    try validateHandoffArgument(self, handoff);
    const value = if (comptime @typeInfo(@TypeOf(handoff)) == .pointer)
        handoff.*
    else
        handoff;
    switch (value) {
        .give => |give| {
            const local_key = self.localSessionKey() orelse return error.InvalidHandoffSession;
            if (!std.mem.eql(u8, give.recipient_key, local_key)) return error.InvalidGift;
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
            const partner_key = self.partnerSessionKey() orelse return error.InvalidHandoffSession;
            if (!std.mem.eql(u8, give.recipient_key, partner_key)) return error.InvalidGift;
        },
        .receive => {},
    }
}

/// Certify every argument an outbound inventory returns to, after lowering
/// and shortening rewrote the tree's references in place: each reference per
/// `ref_check`, each handoff's certificate, and each set's element
/// uniqueness. The walk that took the inventory certified depth, struct keys,
/// and bytes, which no later pass changes. `carrier` is comptime, so the
/// reference branch folds away per call site. The uniqueness fold allocates
/// bounded scratch (gpa, stack-first), so the pass carries the allocator
/// errors the pure reference checks do not.
pub const SendArgError = Error || std.mem.Allocator.Error;

pub fn certifySent(
    self: *Session,
    inventory: session.Inventory,
    root: ?*const model.Argument,
    comptime carrier: Carrier,
) SendArgError!void {
    for (inventory.slots) |slot| try certifySentArgument(self, slot.read(root).*, carrier);
}

fn certifySentArgument(self: *Session, arg: model.Argument, comptime carrier: Carrier) SendArgError!void {
    switch (arg) {
        .reference => |reference| switch (carrier) {
            .call => try validateReference(self, reference, .sent, .held_import, .call),
            // Only the `near` arm is exempt; see `Carrier`.
            .resolution => switch (reference) {
                .near => |near| try self.validateExportPositionForMarshal(near.export_position),
                else => try validateReference(self, reference, .sent, .held_import, .resolution),
            },
        },
        .set => |items| {
            // A duplicate set element refuses here, pre-commit, symmetric with
            // the inbound fold. The encoders refuse byte-equal duplicates too
            // (ADR-0001), but only at encode time in `step`, after
            // send-side export accounting committed wire-delta retains for a frame
            // that never ships, the same all-or-nothing breach the depth
            // bound closes. This fold runs after shortening, which can fold
            // two distinct promises onto one target, and is at least as strict
            // as encode: model-Equal-but-byte-distinct forms (two NaN bit
            // patterns) refuse only here, as they would inbound. No
            // message-wide budget brackets a send, so each fold mints its own
            // allowance, per set rather than per message, which still bounds
            // the one partner-influenced caller (`validateSentResolutionValue`
            // on a proxied fulfillment) at the same rate the inbound fold charges.
            var compare_budget = model.equality.CompareBudget.init(self.limits.max_compare_visits);
            try set_uniqueness.checkOwned(self.allocator, items, &compare_budget);
        },
        .handoff => |handoff| try validateOutboundHandoffArgument(self, handoff.*),
        // The inventory lists exactly these three arms, and the Node's
        // projection turns a reference into a handoff, never into another arm.
        else => unreachable,
    }
}
