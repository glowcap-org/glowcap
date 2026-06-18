//! Asking the partner's `<bootstrap>` for the cap behind a swissnum — our side of
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
//! answer (PreSpec), and an `op:deliver` to the resolver export carrying
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
    answer_position: u64,
    resolver_export: u64,
};

/// How a fetch settles. Owned: `fulfilled` carries a cloned reference, `broken`
/// a duplicated reason — both outlive the transient inbound message the matcher
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
/// carries `resolve_me_desc = Near(promise(resolver))` (the resolver-callback
/// notification form spec-strict partners prefer); earlier profiles omit it (the
/// field has no pre-V1.0 wire encoding).
///
/// Atomic on failure: the heap allocations run first (unwound by errdefer), and
/// the session-state allocations run last — `allocateExport` (the only fallible
/// one) after every heap allocation, then the infallible `allocateOutboundAnswer`
/// — so an `error` leaves the session's export table and answer counter exactly
/// as they were. A failed prepare never burns an export slot or an answer id.
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

    const resolver_export = try session.allocateExport();
    const answer_position = session.allocateOutboundAnswer();

    const resolve_me_desc: ?model.Reference = if (session.needsV1_0Translation())
        .{ .near = model.NearRef.promise(resolver_export) }
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
    resolver_export: u64,
    answer_position: u64,
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
            // partner-named import id collides with the resolver id is unrelated
            // traffic, not a settlement.
            const target_export = deliver.target.exportPosition() orelse return .{ .unrelated = msg };
            if (target_export != resolver_export) return .{ .unrelated = msg };
            const outcome = try decodeResolverCallback(allocator, deliver.args);
            model.freeMessage(allocator, msg);
            return .{ .settled = outcome };
        },
        else => return .{ .unrelated = msg },
    }
}

fn resolutionToOutcome(allocator: std.mem.Allocator, resolution: model.Resolution) !FetchOutcome {
    return switch (resolution) {
        .fulfill => |arg| switch (arg) {
            .reference => |reference| .{ .fulfilled = try model.cloneReference(allocator, reference) },
            else => .malformed,
        },
        .@"break" => |err| .{ .broken = try allocator.dupe(u8, err.message) },
    };
}

fn decodeResolverCallback(allocator: std.mem.Allocator, args: []const model.Argument) !FetchOutcome {
    if (args.len != 2 or args[0] != .symbol) return .malformed;
    const tag = args[0].symbol;
    if (std.mem.eql(u8, tag, "fulfill")) {
        return switch (args[1]) {
            .reference => |reference| .{ .fulfilled = try model.cloneReference(allocator, reference) },
            else => .malformed,
        };
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
