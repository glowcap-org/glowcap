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
    // A new `model.Message` arm cannot land without its `EventKind` mirror.
    model.assertMirrorsMessageKinds(EventKind);
}

/// Error decoding an inbound frame into the codec-neutral `model.view.Body`: a
/// codec parse failure or a lazy-sequence projection failure.
pub const DecodeError = codec.dispatch.Error || model.view.ProjectError;

/// An application-visible event.
///
/// The event owns the originating wire frame in the session's negotiated codec.
/// Typed access is a borrowed projection over that frame (`view`). Owned
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

/// The row the engine queues per admitted inbound message: the frame, where
/// its parse lives, and the off-wire facts apply recorded. A message is parsed
/// once, at admission, and the parse rides in the frame's head
/// (`Frame.initHeaded`), the same allocation as the bytes it borrows, so the
/// row carries two words naming it (`Parse`) and a warmed session parks
/// nothing for it. The ceiling keeps the row from growing unnoticed: the
/// reference-slot count a deliver carries for its handler took the last
/// eight bytes.
pub const queued_event_struct_budget_bytes = 200;

/// The fewest argument views an inbound frame's head lends the decoder.
/// Four covers a method symbol and three arguments, the common call.
pub const head_argument_views = 4;

/// The most argument views an inbound frame's head lends the decoder, so a
/// frame's head grows with the message it carries and never past this many
/// views, 80 bytes each. A tree with more nodes than the room is parsed into
/// views up to the room and stays wire-backed past it (ADR-0231).
pub const head_views_cap = 128;

/// The wire bytes one lent view answers for. A Syrup integer or short symbol
/// is about this long and a Cap'n Proto argument is at least a word, so a
/// list of them fits its views. A denser list, such as one of booleans, runs
/// out of room and stays wire-backed, which costs time and never memory.
pub const head_view_bytes = 4;

/// The largest block the C allocator hands out from its per-thread cache
/// (glibc serves up to 1032 bytes that way): taking and returning one costs
/// a few dozen instructions, and a larger block walks the allocator's bins.
/// A frame whose whole block fits this class with the floor of views keeps
/// the floor, so the smallest calls pay nothing for the room larger messages
/// earn. The `greet` row's instruction count pins it. Past the class, a block
/// freed and taken again at the same size costs the allocator about as much
/// as a kept block would, so no peer keeps one (ADR-0238).
pub const small_block_bytes = 1024;

/// The longest frame whose block fits `small_block_bytes` with the floor of
/// views in front of it.
pub const small_frame_bytes = small_block_bytes - inbound_head_budget_bytes - head_argument_views * model.view.argument_view_budget_bytes;

/// How many argument views the head of an owned inbound frame of `wire_len`
/// bytes lends: `head_argument_views` up to `small_frame_bytes`, then one
/// per `head_view_bytes` up to `head_views_cap`. The views are transient
/// memory, freed with the frame, so they answer to no per-connection budget,
/// and the cap keeps the head paid on every inbound frame from growing
/// unnoticed.
pub fn headViewsFor(wire_len: usize) usize {
    if (wire_len <= small_frame_bytes) return head_argument_views;
    return @min(wire_len / head_view_bytes, head_views_cap);
}

/// The ceiling on the fixed part of the head every owned inbound frame
/// carries in front of its bytes: the parse slot. The views behind it are
/// bounded by `head_views_cap`.
pub const inbound_head_budget_bytes = 544;

/// What an owned inbound frame carries in front of its bytes
/// (`Frame.initHeaded`): the slot `Parse.store` fills, followed by the views
/// `Head.slabOf` lends the decoder.
pub const Head = struct {
    body: model.view.Body,

    comptime {
        std.debug.assert(@sizeOf(Head) <= inbound_head_budget_bytes);
    }

    /// The room `frame`'s head lends the decoder for its argument tree, or
    /// none for a frame with no head, whose sequences stay wire-backed.
    pub fn slabOf(frame: *const foundation.Frame) model.view.ValueSlab {
        return .init(std.mem.sliceAsBytes(frame.headTail(Head, model.view.Argument)));
    }
};

/// Where an admitted message's parse lives. The engine's own inbound frames
/// carry it in their head (`ownedFrameFromView`), the same allocation as the
/// bytes it borrows. A frame that arrives owned from outside (`Peer.feedOwned`,
/// external storage, a pipelined rewrite the codec encoded) has no head, so
/// its parse is boxed once at admission and released with the row or event.
pub const Parse = union(enum) {
    head: *const model.view.Body,
    boxed: *model.view.Body,
    /// A V1.0 resolver callback: the deliver as it arrived beside the resolve
    /// it means (ADR-0010). Both borrow the frame's bytes. One allocation on
    /// a path only V1.0 sessions take.
    translated: *Translated,

    pub const Translated = struct {
        wire: model.view.Body,
        semantic: model.view.Body,
    };

    /// Keep `decoded`, the parse of `frame`'s own bytes, where `frame` can
    /// carry it.
    pub fn store(allocator: std.mem.Allocator, frame: *foundation.Frame, decoded: model.view.Body) !Parse {
        // The frame was allocated with a slot ahead of its bytes, in the same
        // memory block, so the parse lives and dies with the frame. An event
        // then carries the frame and its parse as one allocation and one
        // pointer. A frame whose bytes belong to someone else has no slot, so
        // its parse is boxed on its own below.
        if (frame.head(Head)) |slot| {
            slot.body = decoded;
            return .{ .head = &slot.body };
        }
        const boxed = try allocator.create(model.view.Body);
        boxed.* = decoded;
        return .{ .boxed = boxed };
    }

    /// Keep `wire` beside the `semantic` body admission translated it to.
    pub fn storeTranslated(allocator: std.mem.Allocator, wire: model.view.Body, semantic: model.view.Body) !Parse {
        const translated = try allocator.create(Translated);
        translated.* = .{ .wire = wire, .semantic = semantic };
        return .{ .translated = translated };
    }

    /// The body the application acts on.
    pub fn body(self: Parse) *const model.view.Body {
        return switch (self) {
            .head => |slot| slot,
            .boxed => |slot| slot,
            .translated => |slot| &slot.semantic,
        };
    }

    /// The body as it arrived, before any translation.
    pub fn wireBody(self: Parse) *const model.view.Body {
        return switch (self) {
            .head => |slot| slot,
            .boxed => |slot| slot,
            .translated => |slot| &slot.wire,
        };
    }

    /// Release what the parse owns. A head parse goes with its frame.
    pub fn deinit(self: Parse, allocator: std.mem.Allocator) void {
        switch (self) {
            .head => {},
            .boxed => |slot| allocator.destroy(slot),
            .translated => |slot| allocator.destroy(slot),
        }
    }
};

pub const Queued = struct {
    frame: foundation.Frame,
    parse: Parse,
    tag: EventKind,
    codec: model.CodecId,
    captp_version: model.CaptpVersion,
    answer_override: AnswerOverride = .none,
    deliver_answer_target: ?session.AnswerTarget = null,
    allocator: std.mem.Allocator,
    introduced_far_imports: ?[]model.ImportPosition = null,
    reference_slots: ?u32 = null,
    resolve_aliases: std.ArrayListUnmanaged(model.AnswerPosition) = .empty,

    /// Surface the row for every reader that drains it.
    pub fn surface(self: Queued) Event {
        return .{
            .frame = self.frame,
            .parse = self.parse,
            .tag = self.tag,
            .codec = self.codec,
            .captp_version = self.captp_version,
            .answer_override = self.answer_override,
            .deliver_answer_target = self.deliver_answer_target,
            .allocator = self.allocator,
            .introduced_far_imports = self.introduced_far_imports,
            .reference_slots = self.reference_slots,
            .resolve_aliases = self.resolve_aliases,
        };
    }

    pub fn deinit(self: *Queued) void {
        self.parse.deinit(self.allocator);
        self.frame.deinit();
        if (self.introduced_far_imports) |positions| self.allocator.free(positions);
        self.resolve_aliases.deinit(self.allocator);
    }
};

/// A surfaced inbound event: the queued row with the parse admission made.
/// Every reader that drains it (the driver, the vat, the GC walk) projects
/// from `parse`, so one message costs one parse in its life. `frame` never
/// moves its heap bytes, so the borrow stays valid for the event's life.
/// Transient: it lives on the drain's stack, not in a queue.
pub const Event = struct {
    frame: foundation.Frame,
    parse: Parse,
    tag: EventKind,
    /// The codec that carried `frame`, the session's negotiated `model.CodecId`.
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
    /// still alive, its own backing arena resets before this event is ever
    /// polled. Null for every non-deliver kind, and for a deliver that
    /// introduced no far reference (the common case: no allocation then).
    /// `driver.core.gc` reads this instead of re-walking the deliver's args
    /// when set. A deliver surfaced by any other path (today only a
    /// drained pipelined call redirected to a local export:
    /// `engine.pipeline.deliverDrainedCallLocally`) leaves this null, and
    /// `gc` falls back to its own walk.
    introduced_far_imports: ?[]model.ImportPosition = null,
    /// For a `.deliver` event this session validated: how many reference and
    /// handoff slots its application arguments hold, at every depth, counted
    /// by the same validate walk. The Vat hands it to the delivery, and a
    /// Host handler whose delivery holds none reads the frame's views with
    /// no lift. Null for every other kind and for a deliver surfaced by any
    /// other path, which the Host lifts as a whole.
    reference_slots: ?u32 = null,
    /// Additional local answers sharing this resolve's one next-profile wire
    /// callback. The originating frame remains single-owner. Consumers project
    /// the same borrowed resolution once per answer.
    resolve_aliases: std.ArrayListUnmanaged(model.AnswerPosition) = .empty,

    pub fn kind(self: Event) EventKind {
        return self.tag;
    }

    pub fn bytes(self: *const Event) []const u8 {
        return self.frame.bytes();
    }

    /// Additional local answers this resolve settles. The primary is available
    /// from `view().resolve.answer`. This slice carries the rest.
    pub fn resolveAliases(self: *const Event) []const model.AnswerPosition {
        return self.resolve_aliases.items;
    }

    /// The frame's parse exactly as it arrived, before off-wire answer
    /// translation. Composition hooks use this to recognize a Node-owned
    /// listener callback even when the semantic event also resolves local
    /// application answers.
    pub fn wireView(self: *const Event) *const model.view.Body {
        return self.parse.wireBody();
    }

    /// The parse the application acts on, borrowed from the event: the frame's
    /// own for most events, the resolve a V1.0 resolver callback translates
    /// to (`Parse.translated`). Admission already read it, so nothing here
    /// can fail.
    pub fn view(self: *const Event) *const model.view.Body {
        return self.parse.body();
    }

    /// The semantic answer an inbound deliver settles. A wire answer remains
    /// wire-shaped. A V1.0 resolver-only deliver carries its session-local
    /// virtual identity here without manufacturing a wire position in `view`.
    pub fn deliverAnswerName(self: *const Event) ?model.AnswerName {
        if (self.tag != .deliver) return null;
        return switch (self.answer_override) {
            .virtual_deliver => |answer| .fromVirtual(answer),
            else => if (self.wireView().deliver.answer) |answer|
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
        return self.view().toOwned(event_allocator);
    }

    pub fn deinit(self: *Event) void {
        self.resolve_aliases.deinit(self.allocator);
        if (self.introduced_far_imports) |imports| self.allocator.free(imports);
        self.parse.deinit(self.allocator);
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
/// partner emits, glowcap's own bare Symbol (mirroring the listener fire), a
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

comptime {
    std.debug.assert(@sizeOf(Queued) <= queued_event_struct_budget_bytes);
}
