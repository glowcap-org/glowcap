//! Bootstrap-fetch sync primitives — the no-I/O half of "ask the partner's
//! `<bootstrap>` for the cap behind this swissnum" (CapTP § `op:deliver`).
//!
//! The full flow has three pieces; only the sync halves live in the core:
//!
//! 1. **Prepare** ([`prepareFetchSwissnum`]): allocate the resolver export +
//!    outbound answer and build the canonical bootstrap-fetch `op:deliver`.
//! 2. **Drive the wire loop** (an adapter's job, not here): send the message,
//!    then feed each inbound message to the matcher.
//! 3. **Match** ([`tryMatchFetchOutcome`]): decide whether an inbound message
//!    settles the fetch, or is unrelated traffic the caller should buffer.
//!
//! The matcher recognizes both spec-permitted settlement forms: an `op:resolve`
//! keyed on the answer (PreSpec) and an `op:deliver` to the resolver export
//! carrying `[fulfill|break, <Reference|Error>]` (V1.0 / Goblins-style).

const std = @import("std");

const model = @import("../model/mod.zig");
const session_mod = @import("../session/mod.zig");

/// Sync bookkeeping from [`prepareFetchSwissnum`]: the adapter sends `message`,
/// then passes every received message plus `answer_id` + `resolver_export` to
/// [`tryMatchFetchOutcome`]. `message` is owned by the caller (move it into
/// `Peer.send`).
pub const PreparedFetch = struct {
    message: model.Message,
    answer_id: u64,
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
/// field has no pre-V1.0 wire encoding). On failure every allocation is released.
pub fn prepareFetchSwissnum(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    swissnum: []const u8,
) !PreparedFetch {
    const resolver_export = try session.allocateExport();
    const answer_id = session.allocateOutboundAnswer();

    const fetch_symbol = try allocator.dupe(u8, "fetch");
    errdefer allocator.free(fetch_symbol);
    const swiss = try allocator.dupe(u8, swissnum);
    errdefer allocator.free(swiss);

    const args = try allocator.alloc(model.Argument, 2);
    args[0] = .{ .symbol = fetch_symbol };
    args[1] = .{ .bytes = swiss };

    const resolve_me_desc: ?model.Reference = if (session.wire_profile.isGoblinsV1_0())
        .{ .near = model.NearRef.promise(resolver_export) }
    else
        null;

    return .{
        .message = .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(session_mod.BOOTSTRAP_EXPORT_ID) },
            .args = args,
            .answer = answer_id,
            .resolve_me_desc = resolve_me_desc,
        } },
        .answer_id = answer_id,
        .resolver_export = resolver_export,
    };
}

/// Decide whether `msg` (owned) settles the fetch identified by
/// `(answer_id, resolver_export)`. A settling message is consumed and its
/// payload extracted into an owned [`FetchOutcome`]; an unrelated message is
/// handed back unchanged for the caller to re-own.
pub fn tryMatchFetchOutcome(
    allocator: std.mem.Allocator,
    resolver_export: u64,
    answer_id: u64,
    msg: model.Message,
) !FetchMatch {
    switch (msg) {
        .resolve => |resolve| {
            if (resolve.answer != answer_id) return .{ .unrelated = msg };
            const outcome = try resolutionToOutcome(allocator, resolve.resolution);
            model.freeMessage(allocator, msg);
            return .{ .settled = outcome };
        },
        .deliver => |deliver| {
            if (referencePosition(deliver.target) != resolver_export) return .{ .unrelated = msg };
            const outcome = try decodeResolverCallback(allocator, deliver.args);
            model.freeMessage(allocator, msg);
            return .{ .settled = outcome };
        },
        else => return .{ .unrelated = msg },
    }
}

/// The export/import position a reference names, or null for a pipeline promise.
fn referencePosition(reference: model.Reference) ?u64 {
    return switch (reference) {
        .near => |near| near.export_id,
        .far => |far| far.import_id,
        else => null,
    };
}

fn resolutionToOutcome(allocator: std.mem.Allocator, resolution: model.Resolution) !FetchOutcome {
    return switch (resolution) {
        .fulfill => |arg| switch (arg) {
            .reference => |reference| .{ .fulfilled = try model.cloneReference(allocator, reference) },
            else => .malformed,
        },
        .break_ => |err| .{ .broken = try allocator.dupe(u8, err.message) },
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
        return switch (args[1]) {
            .@"error" => |err| .{ .broken = try allocator.dupe(u8, err.message) },
            else => .malformed,
        };
    }
    return .malformed;
}
