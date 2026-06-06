//! Answering "give me the cap behind this swissnum" — our side of bootstrap-fetch
//! (ADR-0006), the half that does no I/O.
//!
//! Two small pure pieces, both wired into the peer's dispatch.
//!
//! First, `pendingBootstrapRequest` spots an inbound `op:deliver` to the bootstrap
//! export (id 0) that carries `['fetch <swissnum>]` and a reply answer. It borrows
//! the swissnum straight out of the decoded view.
//!
//! Then `resolveForSwissnum` builds the answer: a `Fulfill` pointing at our export
//! if we know that swissnum, or a `Break("unknown swissnum")` if we don't. On
//! Goblins V1.0 the outbound `step` quietly rewrites that `Resolve` into a
//! resolver-callback deliver for us, so this half never has to care which profile
//! it's speaking.

const std = @import("std");

const model = @import("../model/mod.zig");
const session_mod = @import("../session/mod.zig");

/// A recognized inbound bootstrap-fetch. `swissnum` borrows the inbound frame
/// (valid while the surfaced event owns it); `answer` is the partner's
/// answer-pos the synthesized `Resolve` keys on.
pub const Request = struct {
    swissnum: []const u8,
    answer: u64,
};

/// Recognize an inbound bootstrap-fetch `op:deliver`, or null if `deliver` is
/// not the canonical fetch shape (target export 0, args `['fetch <bytes>]`,
/// answer present). A malformed-looking fetch returns null — it falls through
/// to ordinary deliver handling rather than becoming a session refusal.
pub fn pendingBootstrapRequest(deliver: model.view.Deliver) model.view.ProjectError!?Request {
    const answer = deliver.answer orelse return null;
    if (referencePosition(deliver.target) != session_mod.BOOTSTRAP_EXPORT_ID) return null;
    if ((try deliver.args.len()) != 2) return null;

    // The method name is a Syrup symbol (`'fetch`).
    const method = switch (try deliver.args.at(0)) {
        .symbol => |symbol| symbol,
        else => return null,
    };
    if (!std.mem.eql(u8, method, "fetch")) return null;

    const swissnum = switch (try deliver.args.at(1)) {
        .bytes => |bytes| bytes,
        else => return null,
    };
    return .{ .swissnum = swissnum, .answer = answer };
}

/// Synthesize the semantic `Resolve` for `request`. Pure and non-allocating:
/// `Fulfill` carries a POD `NearRef`; `Break` carries a *static* reason string.
///
/// Ownership contract — the inverse of `fetch.zig`'s `PreparedFetch.message`:
/// the returned `Message` MUST be enqueued via [`Peer.sendCopying`], which deep-
/// clones it into peer-owned storage. It MUST NOT be routed through `Peer.send`
/// (which takes ownership and later frees the payload): freeing the static break
/// reason — not heap-allocated — would crash. Nothing here is heap-owned, so the
/// caller MUST NOT `freeMessage` it either.
pub fn resolveForSwissnum(session: *const session_mod.Session, request: Request) model.Message {
    if (session.bootstrapLookup(request.swissnum)) |export_id| {
        return .{ .resolve = .{
            .answer = request.answer,
            .resolution = .{ .fulfill = .{ .reference = .{ .near = model.NearRef.object(export_id) } } },
        } };
    }
    return .{ .resolve = .{
        .answer = request.answer,
        .resolution = .{ .break_ = .{ .message = "unknown swissnum" } },
    } };
}

/// The export/import position a reference view names, or null for a promise.
/// Mirrors `engine`'s view-side helper: an inbound deliver to our bootstrap
/// export decodes `<desc:export 0>` to `.near{export_id = 0}`.
fn referencePosition(reference: model.view.Reference) ?u64 {
    return switch (reference) {
        .near => |near| near.export_id,
        .far => |far| far.import_id,
        .promise, .sturdy, .broken => null,
    };
}
