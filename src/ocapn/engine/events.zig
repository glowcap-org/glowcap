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
    release_pipeline_export,
};

comptime {
    // Every wire kind remains in order; the final arm is a private effect.
    const wire_fields = @typeInfo(model.Message).@"union".field_names;
    const event_fields = @typeInfo(EventKind).@"enum".field_names;
    std.debug.assert(event_fields.len == wire_fields.len + 1);
    for (wire_fields, event_fields[0..wire_fields.len]) |wire, event|
        std.debug.assert(std.mem.eql(u8, wire, event));
}

/// Error decoding an inbound frame into the codec-neutral `model.view.Body`: a
/// codec parse failure or a lazy-sequence projection failure.
pub const DecodeError = codec.dispatch.Error || model.view.ProjectError;

pub const AnswerOverride = union(enum) {
    none,
    /// The outbound answer a `.resolve` event settles, by identity, so a
    /// position the session reuses after release never settles the new
    /// question. A wire `op:resolve` names it directly. A deliver to one of
    /// our resolver exports reaches it through the export: a V1.0 resolver
    /// callback (ADR-0006) or the listener export an outbound `op:listen`
    /// nominated (ADR-0003).
    resolve: session.OutboundAnswerTarget,
    /// Resolver-only deliver carrying its virtual inbound answer
    /// (`Event.kind() == .deliver`).
    virtual_deliver: model.VirtualAnswer,
};

/// The row the engine queues per admitted inbound message: the frame, where
/// its parse lives, and the off-wire facts apply recorded. A message is parsed
/// once, at admission, and the parse rides in the frame's head
/// (`Frame.initHeaded`), the same allocation as the bytes it borrows, so the
/// row carries two words naming it (`Parse`) and a warmed session parks
/// nothing for it. The ceiling keeps the row from growing unnoticed. Its
/// reply identity is one discriminated deliver/resolve authority; the private
/// retirement arm shares wire storage and adds no per-event allocation.
pub const event_struct_budget_bytes = 208;

/// The fewest argument views an inbound frame's head lends the decoder.
/// Four covers a method symbol and three arguments, the common call.
pub const head_argument_views = 4;

/// The most argument views an inbound frame's head lends the decoder, so a
/// frame's head grows with the message it carries and never past this many
/// views, 80 bytes each. A tree with more nodes than the room is parsed into
/// views up to the room and stays wire-backed past it (ADR-0063).
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
/// as a kept block would, so no peer keeps one (ADR-0063).
pub const small_block_bytes = 1024;

/// The longest frame whose block fits `small_block_bytes` with the budgeted
/// head and floor of views. Keep the budget slack: shrinking a type must not
/// delay the larger slab that typed argument batches need.
pub const small_frame_bytes = small_block_bytes - (foundation.Frame.headedBlockLen(
    Head,
    model.view.Argument,
    head_argument_views,
    0,
    .byte,
) catch unreachable) - (inbound_head_budget_bytes - @sizeOf(Head)) -
    head_argument_views * (model.view.argument_view_budget_bytes - @sizeOf(model.view.Argument));

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
/// (`Frame.initHeaded`): the slot `Parse.decode` fills, followed by the
/// views its decoder's slab lends (`Head.slabOf` is that room).
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
pub const Parse = struct {
    /// The body the application acts on.
    semantic: *model.view.Body,
    owner: Owner,

    /// What holds the body. A V1.0 resolver callback is a translation: the
    /// deliver as it arrived beside the resolve it means (ADR-0006). Both
    /// borrow the frame's bytes. One allocation on a path only V1.0
    /// sessions take.
    pub const Owner = enum { head, boxed, translated };

    pub const Translated = struct {
        wire: model.view.Body,
        semantic: model.view.Body,
    };

    /// Decode `frame`'s own bytes once, where the parse will live. The
    /// engine's frames are allocated with a slot ahead of their bytes, in
    /// the same memory block, so the decoder writes the body there, its
    /// argument list into the views behind it, and the parse
    /// lives and dies with the frame: an event carries both as one
    /// allocation and one pointer. A frame whose bytes belong to someone
    /// else has no slot. It is decoded on the stack, so a refused frame
    /// allocates nothing, and only an admitted parse is boxed.
    pub fn decode(
        allocator: std.mem.Allocator,
        frame: *const foundation.Frame,
        codec_id: model.CodecId,
        profile: model.CaptpVersion,
    ) !Parse {
        if (frame.headed(Head, model.view.Argument)) |slot| {
            var slab: model.view.ValueSlab = .init(std.mem.sliceAsBytes(slot.tail));
            try codec.dispatch.decodeBodyInto(codec_id, profile, frame.view(), &slab, &slot.head.body);
            return .{ .semantic = &slot.head.body, .owner = .head };
        }
        var slab: model.view.ValueSlab = .init(&.{});
        var decoded: model.view.Body = undefined;
        try codec.dispatch.decodeBodyInto(codec_id, profile, frame.view(), &slab, &decoded);
        const boxed = try allocator.create(model.view.Body);
        boxed.* = decoded;
        return .{ .semantic = boxed, .owner = .boxed };
    }

    /// Keep a copy of `wire` beside the `semantic` body admission translated
    /// it to.
    pub fn storeTranslated(allocator: std.mem.Allocator, wire: *const model.view.Body, semantic: model.view.Body) !Parse {
        const translated = try allocator.create(Translated);
        translated.* = .{ .wire = wire.*, .semantic = semantic };
        return .{ .semantic = &translated.semantic, .owner = .translated };
    }

    /// The body the application acts on.
    pub fn body(self: Parse) *const model.view.Body {
        return self.semantic;
    }

    /// The body as it arrived, before any translation.
    pub fn wireBody(self: Parse) *const model.view.Body {
        return switch (self.owner) {
            .head, .boxed => self.semantic,
            .translated => &self.translation().wire,
        };
    }

    fn translation(self: Parse) *Translated {
        return @fieldParentPtr("semantic", self.semantic);
    }

    /// Release what the parse owns. A head parse goes with its frame.
    pub fn deinit(self: Parse, allocator: std.mem.Allocator) void {
        switch (self.owner) {
            .head => {},
            .boxed => allocator.destroy(self.semantic),
            .translated => allocator.destroy(self.translation()),
        }
    }
};

/// An application-visible event: a wire observation with its admitted parse,
/// or an off-wire composition effect. A wire observation owns its frame in the
/// negotiated codec. Typed access is a borrowed projection over that frame
/// (`view`), and owned materialization (`decodeOwned`) happens only when the
/// caller asks. Every reader that drains it (the driver, the vat, the GC
/// walk) projects from `parse`, so one message costs one parse in its life.
/// `frame` never moves its heap bytes, so the borrow stays valid for the
/// event's life.
pub const Event = struct {
    payload: Payload,

    /// The codec that carried `frame`, the session's negotiated `model.CodecId`.
    codec: model.CodecId,
    /// The CapTP profile that admitted `frame`. Event projection must use the
    /// same profile as dispatch or a valid next frame can be reinterpreted as
    /// V1.0 when the application later reads it.
    captp_version: model.CaptpVersion,
    /// One event's reply identity. Deliver and resolve authorities never
    /// coexist. A virtual name without a captured stamp is diagnostic only;
    /// it cannot authorize a reply, just as an unstamped wire name cannot.
    answer: Answer = .none,
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
    /// when set. Pipelined replay preserves the original record even if
    /// shortening rewrote the arguments. Synthetic calls without an admission
    /// record leave this null, and `gc` falls back to its own walk.
    introduced_far_imports: ?[]model.ImportPosition = null,
    /// For a `.deliver` event this session validated: how many reference and
    /// handoff slots its application arguments hold, at every depth, counted
    /// by the same validate walk. The Vat hands it to the delivery, and a
    /// Host handler whose delivery holds none reads the frame's views with
    /// no lift. Pipelined replay preserves this count. Null for other kinds
    /// and synthetic delivers without an admission record.
    reference_slots: ?u32 = null,
    /// Additional local answers sharing this resolve's one next-profile wire
    /// callback. The originating frame remains single-owner. Consumers project
    /// the same borrowed resolution once per answer.
    resolve_aliases: std.ArrayListUnmanaged(session.OutboundAnswerTarget) = .empty,

    /// Wire observations and private composition effects share one FIFO, so
    /// retirement cannot overtake a delivery already accepted for an export.
    pub const Retirement = struct { near: model.NearRef, target: u64 };
    pub const Wire = struct { frame: foundation.Frame, parse: Parse };
    pub const Answer = union(enum) {
        none,
        deliver: session.AnswerTarget,
        resolve: session.OutboundAnswerTarget,
        virtual_deliver: model.VirtualAnswer,
    };
    pub const Payload = union(EventKind) {
        deliver: Wire,
        resolve: Wire,
        gc_export: Wire,
        gc_answer: Wire,
        start_session: Wire,
        abort: Wire,
        listen: Wire,
        get: Wire,
        index: Wire,
        untag: Wire,
        release_pipeline_export: Retirement,

        pub fn message(event_kind: EventKind, frame: foundation.Frame, parse: Parse) Payload {
            return switch (event_kind) {
                .release_pipeline_export => unreachable,
                inline else => |wire_kind| @unionInit(Payload, @tagName(wire_kind), .{ .frame = frame, .parse = parse }),
            };
        }

        fn wire(self: *const Payload) *const Wire {
            return switch (self.*) {
                .release_pipeline_export => unreachable,
                inline else => |*value| value,
            };
        }
    };

    pub fn kind(self: Event) EventKind {
        return std.meta.activeTag(self.payload);
    }

    pub fn bytes(self: *const Event) []const u8 {
        return self.payload.wire().frame.bytes();
    }

    /// The question a `.resolve` event settles, by identity.
    pub fn resolveTarget(self: *const Event) session.OutboundAnswerTarget {
        std.debug.assert(self.kind() == .resolve);
        return self.answer.resolve;
    }

    /// Outbound answers settled by the same resolution as `resolveTarget`:
    /// local aliases converged onto one partner promise (ADR-0003).
    pub fn resolveAliases(self: *const Event) []const session.OutboundAnswerTarget {
        return self.resolve_aliases.items;
    }

    /// The frame's parse exactly as it arrived, before off-wire answer
    /// translation. Composition hooks use this to recognize a Node-owned
    /// listener callback even when the semantic event also resolves local
    /// application answers.
    pub fn wireView(self: *const Event) *const model.view.Body {
        return self.payload.wire().parse.wireBody();
    }

    /// The parse the application acts on, borrowed from the event: the frame's
    /// own for most events, the resolve a V1.0 resolver callback translates
    /// to (`Parse.translated`). Admission already read it, so nothing here
    /// can fail.
    pub fn view(self: *const Event) *const model.view.Body {
        return self.payload.wire().parse.body();
    }

    /// The semantic answer an inbound deliver settles. A wire answer remains
    /// wire-shaped. A V1.0 resolver-only deliver carries its session-local
    /// virtual identity here without manufacturing a wire position in `view`.
    pub fn deliverAnswerName(self: *const Event) ?model.AnswerName {
        if (self.kind() != .deliver) return null;
        return switch (self.answer) {
            .deliver => |target| target.name,
            .virtual_deliver => |virtual| .fromVirtual(virtual),
            else => if (self.wireView().deliver.answer) |answer|
                .fromWire(answer)
            else
                null,
        };
    }

    pub fn deliverAnswerTarget(self: *const Event) ?session.AnswerTarget {
        if (self.kind() != .deliver) return null;
        return if (self.answer == .deliver) self.answer.deliver else null;
    }

    /// Materialize an owned codec-neutral message from the retained frame. Only
    /// when the caller needs ownership independent of this event's frame. It is
    /// `view` materialized, structurally: the borrowed projection (with its
    /// V1.0 resolver-callback translation) is built once
    /// and owned once, so the two projections cannot disagree.
    pub fn decodeOwned(self: *const Event, event_allocator: std.mem.Allocator) !model.Message {
        return self.view().toOwned(event_allocator);
    }

    /// Inline, because a drain loop frees the row it just popped and the
    /// call site knows which optional members that row holds.
    pub inline fn deinit(self: *Event) void {
        self.resolve_aliases.deinit(self.allocator);
        if (self.introduced_far_imports) |imports| self.allocator.free(imports);
        switch (self.payload) {
            .release_pipeline_export => {},
            inline else => |*wire| {
                wire.parse.deinit(self.allocator);
                wire.frame.deinit();
            },
        }
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
    // The shape is exactly the tag and its payload. A third argument is one
    // the settlement never validates or introduces, so it is refused rather
    // than carried unread past the authority checks on the payload.
    if ((try it.next()) != null) return error.MalformedView;
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
    std.debug.assert(@sizeOf(Event) <= event_struct_budget_bytes);
}
