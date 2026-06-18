//! Application-visible engine events.
//!
//! Events own the retained frame and project it through the negotiated codec on
//! demand. They are surface types, not dispatch authority.

const std = @import("std");

const codec = @import("codec");
const foundation = @import("foundation");
const model = @import("model");

pub const StepOutcome = enum {
    idle,
    progress,
};

pub const EventKind = enum {
    deliver,
    resolve,
    gc_export,
    gc_answer,
    handoff,
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
pub const Event = struct {
    frame: foundation.Frame,
    tag: EventKind,
    /// The codec that carried `frame` — the session's negotiated `model.CodecId`.
    codec: model.CodecId,
    /// Off-wire answer-id for a Goblins V1.0 resolver-callback (ADR-0010). Set
    /// only when `tag == .resolve` and the frame is a translated deliver.
    resolve_answer: ?u64 = null,
    /// Off-wire answer-id for an ordinary inbound deliver that carried a
    /// `resolve_me_desc` but no wire answer-position (the Goblins V1.0
    /// resolver-only call pattern). The session allocated a virtual inbound
    /// answer and installed the partner's resolver against it; the surfaced
    /// deliver must carry that virtual answer so the application's reply routes
    /// back through the resolver callback rather than dropping silently. Set
    /// only when `tag == .deliver`.
    deliver_answer: ?u64 = null,

    pub fn kind(self: Event) EventKind {
        return self.tag;
    }

    pub fn bytes(self: *const Event) []const u8 {
        return self.frame.bytes();
    }

    /// Borrowed typed projection over the retained frame. No allocation, no copy.
    pub fn view(self: *const Event) DecodeError!model.view.Body {
        const wire = try codec.dispatch.decodeBody(self.codec, self.frame.view());
        if (self.resolve_answer) |answer| {
            return .{ .resolve = .{
                .answer = answer,
                .resolution = try resolutionFromResolverCallback(wire.deliver.args),
            } };
        }
        if (self.deliver_answer) |answer| {
            var deliver = wire.deliver;
            deliver.answer = answer;
            return .{ .deliver = deliver };
        }
        return wire;
    }

    /// Materialize an owned codec-neutral message from the retained frame. Only
    /// when the caller needs ownership independent of this event's frame. The
    /// V1.0 resolver-callback translation `view` applies is applied here too:
    /// a `resolve_answer` event materializes the semantic `.resolve`, never the
    /// raw callback `.deliver`, so the two projections cannot disagree.
    pub fn decodeOwned(self: *const Event, event_allocator: std.mem.Allocator) !model.Message {
        const body = try codec.dispatch.decodeBody(self.codec, self.frame.view());
        if (self.resolve_answer) |answer| {
            const resolution = try resolutionFromResolverCallback(body.deliver.args);
            return .{ .resolve = .{
                .answer = answer,
                .resolution = try resolution.toOwned(event_allocator),
            } };
        }
        if (self.deliver_answer) |answer| {
            var deliver = body.deliver;
            deliver.answer = answer;
            return (model.view.Body{ .deliver = deliver }).toOwned(event_allocator);
        }
        return body.toOwned(event_allocator);
    }

    pub fn deinit(self: *Event) void {
        self.frame.deinit();
    }
};

/// Project a V1.0 resolver-callback deliver's args (`['fulfill, payload]` or
/// `['break, payload]`) into a borrowed `model.view.Resolution` over the frame.
pub fn resolutionFromResolverCallback(
    args: model.view.Args,
) model.view.ProjectError!model.view.Resolution {
    const tag_arg = try args.at(0);
    const payload = try args.at(1);
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
/// partner emits — pancake's own bare Symbol (mirroring the listener fire), a
/// PreSpec `<error>` record, text, or a Goblins exception record such as
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
