//! Application-visible engine events.
//!
//! Events own the retained frame and project it through the negotiated codec on
//! demand. They are surface types, not dispatch authority.

const std = @import("std");

const codec = @import("codec");
const foundation = @import("foundation");
const model = @import("model");
const session = @import("session");

pub const StepOutcome = enum {
    idle,
    progress,
};

pub const EventKind = enum {
    deliver,
    resolve,
    gc_export,
    gc_answer,
    start_session,
    abort,
    listen,
    get,
    index,
    untag,
};

comptime {
    // A new `model.Message` arm cannot land without its `EventKind` mirror; the
    // C `PANCAKE_EVENT_*` block is forced in turn by `eventKindToC`'s exhaustive
    // switch over this enum.
    model.assertMirrorsMessageKinds(EventKind);
}

/// Error decoding an inbound frame into the codec-neutral `model.view.Body`: a
/// codec parse failure or a lazy-sequence projection failure.
pub const DecodeError = codec.dispatch.Error || model.view.ProjectError;

/// An application-visible event.
///
/// The event owns the originating wire frame in the session's negotiated codec.
/// Typed access is a borrowed projection over that frame (`view`); owned
/// materialization (`decodeOwned`) happens only when the caller asks.
pub const AnswerOverride = union(enum) {
    none,
    /// A deliver to one of our resolver exports, surfaced as a semantic
    /// resolve on the answer that export settles (`Event.tag == .resolve`).
    /// Either mint reaches it: a V1.0 resolver callback (ADR-0010) or the
    /// listener export an outbound `op:listen` nominated (ADR-0095).
    resolver_callback: model.AnswerPosition,
    /// Resolver-only deliver carrying its virtual inbound answer
    /// (`Event.tag == .deliver`).
    virtual_deliver: model.VirtualAnswer,
};

pub const Event = struct {
    frame: foundation.Frame,
    tag: EventKind,
    /// The codec that carried `frame` — the session's negotiated `model.CodecId`.
    codec: model.CodecId,
    /// The CapTP profile that admitted `frame`. Event projection must use the
    /// same profile as dispatch or a valid next frame can be reinterpreted as
    /// V1.0 when the application later reads it.
    captp_version: model.CaptpVersion,
    /// Off-wire answer translation when the wire frame alone cannot say
    /// (ADR-0010). A sum, not two optionals: illegal combinations (both set,
    /// or set under the wrong tag) are unrepresentable.
    answer_override: AnswerOverride = .none,
    /// Stable identity of the answer this deliver may settle. Captured after
    /// Session admission and carried independently from the reusable wire
    /// position, so deferred application work cannot answer a later question.
    deliver_answer_target: ?session.AnswerTarget = null,
    /// The allocator that owns `introduced_far_imports`, when set. Every
    /// `Event` the engine surfaces carries the same peer-lifetime allocator
    /// here regardless of whether that field is populated, so `deinit` has
    /// one place to free it from.
    allocator: std.mem.Allocator,
    /// For a `.deliver` event: the far import positions the session's
    /// validate walk introduced in this deliver's application arguments,
    /// excluding an answer-owned V1.0 resolver descriptor (threaded through
    /// `session.validateInboundDeliverView`), captured while that record was
    /// still alive — its own backing arena resets before this event is ever
    /// polled. Null for every non-deliver kind, and for a deliver that
    /// introduced no far reference (the common case: no allocation then).
    /// `driver.core.gc` reads this instead of re-walking the deliver's args
    /// when set. A deliver surfaced by any other path — today, only a
    /// drained pipelined call redirected to a local export
    /// (`engine.pipeline.deliverDrainedCallLocally`) — leaves this null, and
    /// `gc` falls back to its own walk.
    introduced_far_imports: ?[]model.ImportPosition = null,
    /// Additional local answers sharing this resolve's one next-profile wire
    /// callback. The originating frame remains single-owner; consumers project
    /// the same borrowed resolution once per answer.
    resolve_aliases: std.ArrayListUnmanaged(model.AnswerPosition) = .empty,

    pub fn kind(self: Event) EventKind {
        return self.tag;
    }

    pub fn bytes(self: *const Event) []const u8 {
        return self.frame.bytes();
    }

    /// Additional local answers this resolve settles. The primary is available
    /// from `view().resolve.answer`; this slice carries the rest.
    pub fn resolveAliases(self: *const Event) []const model.AnswerPosition {
        return self.resolve_aliases.items;
    }

    /// Decode the frame exactly as it arrived, before off-wire answer
    /// translation. Composition hooks use this to recognize a Node-owned
    /// listener callback even when the semantic event also resolves local
    /// application answers.
    pub fn wireView(self: *const Event) DecodeError!model.view.Body {
        return codec.dispatch.decodeBodyForProfile(self.codec, self.captp_version, self.frame.view());
    }

    /// Borrowed typed projection over the retained frame. No allocation, no copy.
    pub fn view(self: *const Event) DecodeError!model.view.Body {
        const wire = try self.wireView();
        return switch (self.answer_override) {
            .none => wire,
            .resolver_callback => |answer| .{ .resolve = .{
                .answer = answer,
                .resolution = try resolutionFromResolverCallback(wire.deliver.args),
            } },
            .virtual_deliver => wire,
        };
    }

    /// The semantic answer an inbound deliver settles. A wire answer remains
    /// wire-shaped; a V1.0 resolver-only deliver carries its session-local
    /// virtual identity here without manufacturing a wire position in `view`.
    pub fn deliverAnswerName(self: *const Event) DecodeError!?model.AnswerName {
        if (self.tag != .deliver) return null;
        return switch (self.answer_override) {
            .virtual_deliver => |answer| .fromVirtual(answer),
            else => if ((try self.wireView()).deliver.answer) |answer|
                .fromWire(answer)
            else
                null,
        };
    }

    pub fn deliverAnswerTarget(self: *const Event) ?session.AnswerTarget {
        if (self.tag != .deliver) return null;
        return self.deliver_answer_target;
    }

    /// Materialize an owned codec-neutral message from the retained frame. Only
    /// when the caller needs ownership independent of this event's frame. It is
    /// `view` materialized, structurally: the borrowed projection (with its
    /// V1.0 resolver-callback translation) is built once
    /// and owned once, so the two projections cannot disagree.
    pub fn decodeOwned(self: *const Event, event_allocator: std.mem.Allocator) !model.Message {
        return (try self.view()).toOwned(event_allocator);
    }

    pub fn deinit(self: *Event) void {
        self.resolve_aliases.deinit(self.allocator);
        if (self.introduced_far_imports) |imports| self.allocator.free(imports);
        self.frame.deinit();
    }
};

/// Project a V1.0 resolver-callback deliver's args (`['fulfill, payload]` or
/// `['break, payload]`) into a borrowed `model.view.Resolution` over the frame.
pub fn resolutionFromResolverCallback(
    args: model.view.Args,
) model.view.ProjectError!model.view.Resolution {
    var it = args.iterator();
    const tag_arg = (try it.next()) orelse return error.MalformedView;
    const payload = (try it.next()) orelse return error.MalformedView;
    const tag_symbol = switch (tag_arg) {
        .symbol => |symbol| symbol,
        else => return error.MalformedView,
    };
    if (std.mem.eql(u8, tag_symbol, "fulfill")) {
        return .{ .fulfill = payload };
    }
    if (std.mem.eql(u8, tag_symbol, "break")) {
        return .{ .@"break" = .{
            .message = breakReasonFromPayload(payload) orelse "remote promise broken",
        } };
    }
    return error.MalformedView;
}

/// The one break-payload shape table: the reason text a break payload carries,
/// or null when the shape has no usable text. Accepts every shape a live
/// partner emits, pancake's own bare Symbol (mirroring the listener fire), a
/// next `<error>` record, text, or a Goblins exception record such as
/// `<exn:fail:mystery>`, whose tag is the only reason it carries. `anytype`
/// over the borrowed `model.view.Argument` and the owned `model.Argument`, the
/// same dual-shape pattern as the session's validate walkers, so the borrowed
/// (resolver-callback view) and owned (`engine.fetch`) consumers cannot drift.
pub fn breakReasonFromPayload(payload: anytype) ?[]const u8 {
    return switch (payload) {
        .@"error" => |err| err.message,
        .string, .symbol, .keyword => |text| text,
        .tagged => |tagged| tagged.tag,
        else => null,
    };
}
