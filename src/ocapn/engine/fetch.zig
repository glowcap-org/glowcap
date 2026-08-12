//! Asking the partner's `<bootstrap>` for the cap behind a swissnum, our side of
//! bootstrap-fetch (CapTP `op:deliver`), the half that does no I/O.
//!
//! The whole flow is three steps, and the core only owns the two that don't touch
//! the wire.
//!
//! First, `prepareFetchSwissnum` sets things up: it allocates the resolver export
//! and the outbound answer, and builds the bootstrap-fetch `op:deliver`. Then
//! comes the wire loop, which is the adapter's job, not ours: send the message,
//! and hand each reply to the matcher. Finally, `tryMatchFetchOutcome` looks at an
//! inbound message and decides whether it settles our fetch, or is just unrelated
//! traffic the caller should buffer as unrelated.
//!
//! The matcher accepts both forms the spec allows: an `op:resolve` keyed on the
//! answer (next), and an `op:deliver` to the resolver export carrying
//! `[fulfill|break, <Reference|Error>]` (the V1.0 / Goblins style).

const std = @import("std");

const model = @import("model");
const session_mod = @import("session");
const events = @import("events.zig");

/// Sync bookkeeping from `prepareFetchSwissnum`: the adapter sends `message`,
/// then passes every received message plus `answer_position` + `resolver_export` to
/// `tryMatchFetchOutcome`. `message` is owned by the caller (move it into
/// `Peer.send`).
pub const PreparedFetch = struct {
    message: model.Message,
    answer_position: model.AnswerPosition,
    /// V1.0's inline resolver export. Next mints its listener export when the
    /// answered operation is enqueued, so preparing a fetch reserves no export.
    resolver_export: ?model.ExportPosition,
};

/// How a fetch settles. Owned: `fulfilled` carries a cloned reference, `broken`
/// a duplicated reason, both outlive the transient inbound message the matcher
/// consumes. The caller releases them (`model.freeReference` / `allocator.free`).
pub const FetchOutcome = union(enum) {
    fulfilled: model.Reference,
    broken: []const u8,
    /// The settling message reached the fetch but wasn't the canonical
    /// `[fulfill|break, <Reference|Error>]` shape.
    malformed,
};

/// The result of matching one inbound message against a pending fetch.
pub const FetchMatch = union(enum) {
    settled: FetchOutcome,
    /// Unrelated to the fetch; ownership of the message returns to the caller to
    /// buffer for its next `recv`.
    unrelated: model.Message,
};

/// Allocate the resolver export + outbound answer and build the wire-canonical
/// `op:deliver target=<bootstrap> args=[fetch <swissnum>]`. On V1.0 the message
/// carries `resolve_me_desc = Near(object(resolver))` (the resolver-callback
/// notification form spec-strict partners prefer); earlier profiles omit it (the
/// field has no pre-V1.0 wire encoding).
///
/// Atomic on failure: the heap allocations run first (unwound by errdefer), the
/// fallible session-state steps next (`allocateExport` unwound by errdefer, then
/// the bootstrap-import retain), and the infallible `allocateOutboundAnswer`
/// last, so an `error` leaves the session's export table, import table, and
/// answer counter exactly as they were. A failed prepare never burns an export
/// slot or an answer position.
pub fn prepareFetchSwissnum(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    swissnum: []const u8,
) !PreparedFetch {
    const fetch_symbol = try allocator.dupe(u8, "fetch");
    errdefer allocator.free(fetch_symbol);
    const swiss = try allocator.dupe(u8, swissnum);
    errdefer allocator.free(swiss);

    const args = try allocator.alloc(model.Argument, 2);
    errdefer allocator.free(args);
    args[0] = .{ .symbol = fetch_symbol };
    args[1] = .{ .bytes = swiss };

    // V1.0's resolve-me-desc is a resolver object, not the promise that object
    // settles. Mint the authoritative object slot before projecting its wire
    // mention (ADR-0080).
    const resolver_export: ?model.ExportPosition = if (session.needsV1_0Translation())
        try session.allocateExport()
    else
        null;
    errdefer if (resolver_export) |position| session.releaseUnsharedExport(position);
    // The deliver targets the partner's bootstrap export, our well-known
    // import 0. Track it here, where the fetch shape lives, so no caller
    // carries a pre-fetch registration ritual of its own.
    try session.registerImport(model.ImportPosition.from(session_mod.BOOTSTRAP_POSITION));
    const answer_position = session.allocateOutboundAnswer();

    // Project the mention from the authoritative slot rather than hand-typing
    // the kind: the row was minted as a local object, so it renders as
    // `desc:import-object` by construction (ADR-0080).
    const resolve_me_desc: ?model.Reference = if (session.needsV1_0Translation())
        session_mod.slot.toReference(session.exportSlot(resolver_export.?).?)
    else
        null;

    return .{
        .message = .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(session_mod.BOOTSTRAP_POSITION) },
            .args = args,
            .answer = answer_position,
            .resolve_me_desc = resolve_me_desc,
        } },
        .answer_position = answer_position,
        .resolver_export = resolver_export,
    };
}

/// Decide whether `msg` (owned) settles the fetch identified by
/// `(answer_position, resolver_export)`. A settling message is consumed and its
/// payload extracted into an owned `FetchOutcome`; an unrelated message is
/// handed back unchanged for the caller to re-own.
pub fn tryMatchFetchOutcome(
    allocator: std.mem.Allocator,
    resolver_export: ?model.ExportPosition,
    answer_position: model.AnswerPosition,
    msg: model.Message,
) !FetchMatch {
    switch (msg) {
        .resolve => |resolve| {
            if (resolve.answer != answer_position) return .{ .unrelated = msg };
            const outcome = try resolutionToOutcome(allocator, resolve.resolution);
            model.freeMessage(allocator, msg);
            return .{ .settled = outcome };
        },
        .deliver => |deliver| {
            // The resolver is one of *our* exports, so only a `.near` target can
            // settle the fetch (`exportPosition`); a `.far` deliver whose
            // partner-named import position collides with the resolver position is unrelated
            // traffic, not a settlement.
            const expected = resolver_export orelse return .{ .unrelated = msg };
            const target_export = deliver.target.exportPosition() orelse return .{ .unrelated = msg };
            if (target_export != expected) return .{ .unrelated = msg };
            const outcome = try decodeResolverCallback(allocator, deliver.args);
            model.freeMessage(allocator, msg);
            return .{ .settled = outcome };
        },
        else => return .{ .unrelated = msg },
    }
}

/// A fulfilled fetch settles to exactly one reference; any other fulfill
/// argument shape is malformed. Both settlement decoders below reach the same
/// verdict from their own break handling, so the fulfill arm lives here once.
fn fulfilledReferenceOutcome(allocator: std.mem.Allocator, arg: model.Argument) !FetchOutcome {
    return switch (arg) {
        .reference => |reference| .{ .fulfilled = try model.cloneReference(allocator, reference) },
        else => .malformed,
    };
}

fn resolutionToOutcome(allocator: std.mem.Allocator, resolution: model.Resolution) !FetchOutcome {
    return switch (resolution) {
        .fulfill => |arg| try fulfilledReferenceOutcome(allocator, arg),
        .@"break" => |err| .{ .broken = try allocator.dupe(u8, err.message) },
    };
}

fn decodeResolverCallback(allocator: std.mem.Allocator, args: []const model.Argument) !FetchOutcome {
    if (args.len != 2 or args[0] != .symbol) return .malformed;
    const tag = args[0].symbol;
    if (std.mem.eql(u8, tag, "fulfill")) {
        return fulfilledReferenceOutcome(allocator, args[1]);
    }
    if (std.mem.eql(u8, tag, "break")) {
        // The accepted break-reason shapes live in one table
        // (`events.breakReasonFromPayload`), shared with the resolver-callback
        // view projection; a shape with no usable text is malformed here.
        const message = events.breakReasonFromPayload(args[1]) orelse return .malformed;
        return .{ .broken = try allocator.dupe(u8, message) };
    }
    return .malformed;
}
