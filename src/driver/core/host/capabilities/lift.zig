//! Host value lifting: the complete transaction that turns one bounded
//! argument tree into application Values and commits or rolls back every
//! capability observation. A failed lift of a consumed tree (`partner`,
//! `queued`) retires every occurrence through exact wire GC. A failed lift of
//! a tree the caller keeps (`borrowed`) undoes only its own claims. The walk
//! reads borrowed views (`model.view.Argument`), so a wire deliver lifts
//! straight off the frame's bytes, and an owned value projects into a view at
//! the door at no cost.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const actors = @import("actors");

const host_mod = @import("../../host.zig");
const value_mod = @import("../../value.zig");
const host_pump = @import("../pump.zig");
const identity = @import("identity.zig");
const receipt_list = @import("receipt_list.zig");
const capability_promise = @import("../../capability_promise.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const CapabilityLift = identity.CapabilityLift;

/// How many receipts one transaction holds on the stack before its list
/// spills into the transaction's allocator.
const inline_capacity = 8;

/// Who owns the tree a lift reads, which decides the refusal's name and what a
/// failed lift owes. Every caller states it from where its input came from.
///
/// - `partner`: a wire occurrence the lift consumes. Its depth refusal is
///   `NestingTooDeep`, and a failure retires every observation, completed or
///   not, through exact wire GC.
/// - `queued`: a local message the Vat queue owns and consumed at admission,
///   which measured its depth then. Its failure retires the same way, and a
///   depth refusal here is `ValueTooDeep`.
/// - `borrowed`: a value a live caller keeps (a near call's arguments or
///   reply). A depth refusal is `ValueTooDeep`, a failure undoes only this
///   lift's own claims and leaves every other reference with the caller, and an
///   inline give is refused, because its Node acceptance cannot be undone.
pub const Input = enum {
    partner,
    queued,
    borrowed,

    /// What a turn's arguments are, from the turn's actual origin.
    pub fn ofTurn(turn: *const actors.Turn) Input {
        return switch (turn.origin) {
            .served => .partner,
            .eventual => .queued,
            .local => .borrowed,
        };
    }
};

const DepthError = error{ NestingTooDeep, ValueTooDeep };

/// The depth of the items of a container at `depth`, or the input's depth
/// refusal when `model.mayHoldItems` refuses them.
inline fn itemsDepth(input: Input, depth: usize) DepthError!usize {
    if (!model.mayHoldItems(depth)) return if (input == .partner) error.NestingTooDeep else error.ValueTooDeep;
    return depth + 1;
}

/// One lift transaction's receipts. The transaction owns the allocator a spill
/// grows in: the caller's arena for a lift whose values it keeps, the Host's
/// allocator for a lift that owns its result, so one list never mixes the two.
pub const CapabilityLiftReceipts = struct {
    list: receipt_list.ReceiptList(CapabilityLift, inline_capacity) = .{},
    reference_count: usize = 0,
    allocator: std.mem.Allocator,

    /// A position a nested walk can undo back to.
    const Mark = struct { len: usize, reference_count: usize };

    fn init(allocator: std.mem.Allocator) CapabilityLiftReceipts {
        return .{ .allocator = allocator };
    }

    pub fn ensureOne(self: *CapabilityLiftReceipts) !void {
        return self.list.ensureOne(self.allocator);
    }

    pub fn mark(self: *const CapabilityLiftReceipts) Mark {
        return .{ .len = self.list.len, .reference_count = self.reference_count };
    }

    /// Undo every receipt after `at`, newest first, and forget them. The room
    /// reserved before the mark stays reserved.
    pub fn undoFrom(self: *CapabilityLiftReceipts, host: *Host, at: Mark) void {
        undoCapabilityLifts(host, self.items()[at.len..]);
        self.list.truncate(at.len);
        self.reference_count = at.reference_count;
    }

    fn appendAssumeCapacity(
        self: *CapabilityLiftReceipts,
        lift: CapabilityLift,
        source: enum { reference, inline_give },
    ) void {
        self.list.appendAssumeCapacity(lift);
        if (source == .reference) self.reference_count += 1;
    }

    fn items(self: *const CapabilityLiftReceipts) []const CapabilityLift {
        return self.list.items();
    }

    fn deinit(self: *CapabilityLiftReceipts) void {
        self.list.deinit(self.allocator);
    }
};

/// What the owner of a tree owes a nested lift, from the lift's `Input`. A
/// borrowed tree carries its transaction's receipts, so the settled data an
/// answer reference reads joins that one transaction and an outer refusal
/// undoes it exactly. The other two commit what they lift on their own.
pub const Custody = union(enum) {
    partner,
    queued,
    borrowed: *CapabilityLiftReceipts,

    pub fn input(self: Custody) Input {
        return switch (self) {
            .partner => .partner,
            .queued => .queued,
            .borrowed => .borrowed,
        };
    }

    fn of(in: Input, lifts: *CapabilityLiftReceipts) Custody {
        return switch (in) {
            .partner => .partner,
            .queued => .queued,
            .borrowed => .{ .borrowed = lifts },
        };
    }
};

const commitCapabilityLifts = identity.commitCapabilityLifts;

fn undoCapabilityLifts(self: *Host, lifts: []const CapabilityLift) void {
    var i = lifts.len;
    while (i != 0) {
        i -= 1;
        identity.undoCapabilityLift(self, lifts[i]);
    }
}

fn rollbackCapabilityLifts(self: *Host, lifts: []const CapabilityLift) void {
    var i = lifts.len;
    while (i != 0) {
        i -= 1;
        identity.rollbackCapabilityLift(self, lifts[i]);
    }
}

fn discardUnprojectedArgumentReferences(
    self: *Host,
    session: *HostSession,
    arg: model.view.Argument,
    skip: *usize,
    depth: usize,
) (DepthError || error{MalformedView})!void {
    switch (arg) {
        .reference => |reference| {
            if (skip.* != 0)
                skip.* -= 1
            else
                identity.discardCapabilityObservation(self, session, reference);
        },
        .list, .set => |items| try discardUnprojectedSequence(self, session, items, skip, try itemsDepth(.partner, depth)),
        .tagged => |tagged| try discardUnprojectedSequence(self, session, tagged.value, skip, try itemsDepth(.partner, depth)),
        .@"struct" => |entries| {
            const items_depth = try itemsDepth(.partner, depth);
            var it = entries.iterator();
            while (try it.next()) |entry|
                try discardUnprojectedArgumentReferences(self, session, entry.value, skip, items_depth);
        },
        else => {},
    }
}

fn discardUnprojectedSequence(
    self: *Host,
    session: *HostSession,
    items: model.view.Args,
    skip: *usize,
    depth: usize,
) (DepthError || error{MalformedView})!void {
    var it = items.iterator();
    while (try it.next()) |item|
        try discardUnprojectedArgumentReferences(self, session, item, skip, depth);
}

fn failValuesProjection(
    self: *Host,
    session: *HostSession,
    args: model.view.Args,
    lifts: *const CapabilityLiftReceipts,
    input: Input,
) void {
    const items = lifts.items();
    // A live caller keeps every reference this lift did not claim, so only the
    // claims unwind. No route is consumed, nothing is sent, and the unvisited
    // tree is never walked.
    if (input == .borrowed) return undoCapabilityLifts(self, items);
    // Redeemed routes become consumed facts before their exact Host retains
    // roll back. A failed application projection is terminal for this wire
    // occurrence; it is never made retryable by leaving a route half-owned.
    commitCapabilityLifts(self, items);
    rollbackCapabilityLifts(self, items);

    // Only `.reference` observations correspond to positions in this walk.
    // Inline gives have rollback receipts too, but counting them here would
    // skip a later reference and strand invisible wire authority.
    var skip = lifts.reference_count;
    discardUnprojectedSequence(self, session, args, &skip, 0) catch {
        // An overdeep or unprojectable source cannot be enumerated safely
        // under the same bounds. Completed observations above are already
        // retired; condemn the source so terminal session teardown remains
        // the last owner of any unvisited wire retains.
        host_pump.condemnAndClose(
            self,
            session,
            .resource_exhausted,
            "failed capability projection cleanup",
        );
        return;
    };
    std.debug.assert(skip == 0);
}

fn failValueProjection(
    self: *Host,
    session: *HostSession,
    arg: model.view.Argument,
    lifts: *const CapabilityLiftReceipts,
    input: Input,
) void {
    failValuesProjection(self, session, .fromViews(&.{arg}), lifts, input);
}

/// Retire an unexposed borrowed value without materializing its representation.
/// This uses the same bounded reference walk and terminal cleanup as a failed
/// projection. The caller retains no reference from the value afterward.
pub fn discardValueObservation(self: *Host, session: *HostSession, arg: model.Argument) void {
    const lifts = CapabilityLiftReceipts.init(self.allocator);
    failValueProjection(self, session, .fromOwned(&arg), &lifts, .partner);
}

const ByteOwnership = enum {
    borrowed,
    owned,

    fn materialize(comptime self: ByteOwnership, arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
        return if (self == .owned) try arena.dupe(u8, bytes) else bytes;
    }
};

/// Materialize one turn-borrowed wire value for an owner that outlives the
/// turn. One walk copies bytes/spines and acquires canonical capability retains.
/// `input` is `.partner` or `.queued` here: the value is consumed, so a refusal
/// retires every observation through wire GC. A borrowed tree owns nothing yet,
/// and the settled data its answer references read joins its transaction
/// through `ownNested`.
pub fn ownValue(self: *Host, session: *HostSession, arena: std.mem.Allocator, arg: model.Argument, input: Input) !value_mod.Value {
    var lifts = CapabilityLiftReceipts.init(self.allocator);
    // Receipt spill is temporary; the action arena retains only its Value.
    defer lifts.deinit();
    var value: value_mod.Value = undefined;
    const view = model.view.Argument.fromOwned(&arg);
    liftValueInner(self, session, arena, view, &lifts, 0, .owned, input, &value) catch |err| {
        failValueProjection(self, session, view, &lifts, input);
        return err;
    };
    commitCapabilityLifts(self, lifts.items());
    return value;
}

/// Own a borrowed tree's settled data inside the caller's transaction: the
/// value's bytes are copied into `arena`, and every capability inside it
/// appends to `lifts` instead of committing. The caller marks `lifts` first
/// and undoes back to the mark on any failure, here or later in the lift, so
/// the data's claims leave with the lift that made them.
pub fn ownNested(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    arg: model.Argument,
    lifts: *CapabilityLiftReceipts,
) LiftError!value_mod.Value {
    var value: value_mod.Value = undefined;
    try liftValueInner(self, session, arena, .fromOwned(&arg), lifts, 0, .owned, .borrowed, &value);
    return value;
}

/// Lift one reference the partner delivered. A promise received as an
/// argument names a question this side still owes an answer to, and an
/// export of ours that serves no actor names the local promise a projection
/// stands for: each is a capability promise that settles with the answer
/// (ADR-0068). Every other reference lifts as the capability it names.
pub fn liftReference(self: *Host, session: *HostSession, reference: model.view.Reference, custody: Custody) LiftError!Host.CapabilityLift {
    return switch (reference) {
        .promise => |promise| capability_promise.liftAnswer(self, session, promise.answer_position, custody),
        .near => |near| if (near.kind == .promise)
            capability_promise.liftNearPromise(self, session, near.export_position, custody)
        else
            identity.liftCapabilityTracked(self, session, .{ .near = near }) catch |err| switch (err) {
                // V1.0 near references carry no promise kind on the wire.
                error.NoSuchActor => capability_promise.liftNearPromise(self, session, near.export_position, custody),
                else => err,
            },
        else => identity.liftCapabilityTracked(self, session, try identity.callableReference(reference)),
    };
}

/// Everything the value lift walk can refuse. The walk is recursive, so its
/// set is spelled from the non-recursive steps it takes. An answer reference
/// lifts through `capability_promise.liftAnswer`, which owns the answer's
/// data through this walk again, so its refusals are spelled here too.
pub const LiftError = error{ NestingTooDeep, ValueTooDeep, MalformedView, UnsupportedValue } ||
    error{ LiftedAnswerCapExceeded, CapabilitySpaceExhausted, InvalidReference, UnexpectedMessage, QueueCapExceeded, RetainOverflow } ||
    std.mem.Allocator.Error ||
    model.view.ProjectError ||
    foundation.error_sets.Of(CapabilityLiftReceipts.ensureOne) ||
    foundation.error_sets.Of(identity.callableReference) ||
    foundation.error_sets.Of(identity.liftCapabilityTracked) ||
    foundation.error_sets.Of(capability_promise.liftInlineGive);

/// Writes the lifted value into `out` so each arm lands in place: a result
/// returned through an error union is copied out of it by the caller, and a
/// value is wide enough for that copy to be a call.
fn liftValueInner(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    arg: model.view.Argument,
    lifts: *CapabilityLiftReceipts,
    depth: usize,
    comptime bytes: ByteOwnership,
    input: Input,
    out: *value_mod.Value,
) LiftError!void {
    out.* = switch (arg) {
        .bytes => |v| .{ .bytes = try bytes.materialize(arena, v) },
        .symbol => |v| .{ .symbol = try bytes.materialize(arena, v) },
        .reference => |reference| blk: {
            try lifts.ensureOne();
            const lifted = try liftReference(self, session, reference, .of(input, lifts));
            lifts.appendAssumeCapacity(lifted, .reference);
            break :blk .{ .capability = lifted.ref };
        },
        .@"error" => |reason| .{ .@"error" = .{ .message = try bytes.materialize(arena, reason.message) } },
        .string => |v| .{ .string = try bytes.materialize(arena, v) },
        .integer => |v| .{ .integer = v },
        .boolean => |v| .{ .boolean = v },
        .list => |items| .{ .list = try liftValuesInner(self, session, arena, items, lifts, try itemsDepth(input, depth), bytes, input) },
        .void => .{ .void = {} },
        .float64 => |v| .{ .float64 = v },
        .set => |items| .{ .set = try liftValuesInner(self, session, arena, items, lifts, try itemsDepth(input, depth), bytes, input) },
        .tagged => |tagged| .{ .tagged = .{
            .tag = try bytes.materialize(arena, tagged.tag),
            .value = try liftValuesInner(self, session, arena, tagged.value, lifts, try itemsDepth(input, depth), bytes, input),
        } },
        .keyword => |v| .{ .keyword = try bytes.materialize(arena, v) },
        .big_integer => |v| .{ .big_integer = .{ .negative = v.negative, .digits = try bytes.materialize(arena, v.digits) } },
        .@"struct" => |entries| blk: {
            const items_depth = try itemsDepth(input, depth);
            const lifted = try arena.alloc(value_mod.Value.StructEntry, try entries.len());
            var filled: usize = 0;
            var it = entries.iterator();
            while (try it.next()) |entry| : (filled += 1) {
                if (filled >= lifted.len) return error.MalformedView;
                lifted[filled].key = try bytes.materialize(arena, entry.key);
                try liftValueInner(self, session, arena, entry.value, lifts, items_depth, bytes, input, &lifted[filled].value);
            }
            if (filled != lifted.len) return error.MalformedView;
            break :blk .{ .@"struct" = lifted };
        },
        .handoff => |handoff| switch (try handoff.project()) {
            .give => |give| blk: {
                // Accepting a give starts a redemption on the Node (a queued
                // failure, a dial, or a withdraw on the wire) that nothing can
                // call back, so a caller who keeps its input cannot lend one.
                if (input == .borrowed) return error.UnsupportedValue;
                try lifts.ensureOne();
                const lifted = try capability_promise.liftInlineGive(self, session, give);
                lifts.appendAssumeCapacity(lifted, .inline_give);
                break :blk .{ .capability = lifted.ref };
            },
            // A receive is an exporter bootstrap request, never an
            // application Passable value.
            .receive => return error.UnsupportedValue,
        },
    };
}

fn liftValuesInner(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    args: model.view.Args,
    lifts: *CapabilityLiftReceipts,
    depth: usize,
    comptime bytes: ByteOwnership,
    input: Input,
) LiftError![]value_mod.Value {
    const out = try arena.alloc(value_mod.Value, try args.len());
    var filled: usize = 0;
    var it = args.iterator();
    while (try it.next()) |arg| : (filled += 1) {
        if (filled >= out.len) return error.MalformedView;
        try liftValueInner(self, session, arena, arg, lifts, depth, bytes, input, &out[filled]);
    }
    if (filled != out.len) return error.MalformedView;
    return out;
}

/// Lift one wire-shaped argument into the Host's `Value`: every
/// reference becomes an opaque Host capability through the canonical identity
/// owner. Spine containers are allocated in `arena`. Leaf bytes stay borrowed.
/// A failure is one transaction whose cleanup follows `input`: a consumed
/// input retires completed and unvisited observations, and a borrowed one
/// undoes only this lift's claims (see `Input`).
pub fn liftValue(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    arg: model.Argument,
    input: Input,
) LiftError!value_mod.Value {
    return liftView(self, session, arena, .fromOwned(&arg), input);
}

/// `liftValue` over one borrowed view, read where it lies.
pub fn liftView(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    view: model.view.Argument,
    input: Input,
) LiftError!value_mod.Value {
    var lifts = CapabilityLiftReceipts.init(arena);
    var value: value_mod.Value = undefined;
    liftValueInner(self, session, arena, view, &lifts, 0, .borrowed, input, &value) catch |err| {
        failValueProjection(self, session, view, &lifts, input);
        return err;
    };
    commitCapabilityLifts(self, lifts.items());
    return value;
}

fn projectedValueType(comptime project: anytype) type {
    const return_type = @typeInfo(@TypeOf(project)).@"fn".return_type.?;
    return @typeInfo(return_type).error_union.payload;
}

/// Lift and project one application-facing value as one transaction. The
/// callback owns representation only. On any failure this Host cleans up as
/// `input` says: a consumed input rolls back completed lifts and retires every
/// reference observation not exposed, a borrowed one undoes this lift's claims.
pub fn projectValue(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    arg: model.Argument,
    context: anytype,
    comptime project: anytype,
    input: Input,
) (LiftError || foundation.error_sets.Of(project))!projectedValueType(project) {
    var lifts = CapabilityLiftReceipts.init(arena);
    var value: value_mod.Value = undefined;
    const view = model.view.Argument.fromOwned(&arg);
    liftValueInner(self, session, arena, view, &lifts, 0, .borrowed, input, &value) catch |err| {
        failValueProjection(self, session, view, &lifts, input);
        return err;
    };
    const projected = project(context, value) catch |err| {
        failValueProjection(self, session, view, &lifts, input);
        return err;
    };
    commitCapabilityLifts(self, lifts.items());
    return projected;
}

/// `projectValue` over a whole argument list under one capability
/// transaction. A failure anywhere cleans up as `input` says.
pub fn projectValues(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    args: model.view.Args,
    context: anytype,
    comptime project: anytype,
    input: Input,
) (LiftError || foundation.error_sets.Of(project))!projectedValueType(project) {
    var lifts = CapabilityLiftReceipts.init(arena);
    const values = liftValuesInner(self, session, arena, args, &lifts, 0, .borrowed, input) catch |err| {
        failValuesProjection(self, session, args, &lifts, input);
        return err;
    };
    const projected = project(context, values) catch |err| {
        failValuesProjection(self, session, args, &lifts, input);
        return err;
    };
    commitCapabilityLifts(self, lifts.items());
    return projected;
}

/// `liftValue` over a whole argument list, under one receipts scope: a
/// failure anywhere cleans up as `input` says. The
/// views are read where they lie, so a delivered frame's leaves reach the
/// handler's values with no copy between the wire and the application.
pub fn liftValues(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    args: model.view.Args,
    input: Input,
) LiftError![]value_mod.Value {
    var lifts = CapabilityLiftReceipts.init(arena);
    const values = liftValuesInner(self, session, arena, args, &lifts, 0, .borrowed, input) catch |err| {
        failValuesProjection(self, session, args, &lifts, input);
        return err;
    };
    commitCapabilityLifts(self, lifts.items());
    return values;
}
