//! Reading a message without copying it, straight off the wire bytes.
//!
//! On every receive, a codec lays a borrowed `Body` over the decoded frame
//! instead of building the whole owned `model.Message` tree. This view is the one
//! shape both codecs produce, and it's the only message shape the engine looks
//! at; the engine never touches a codec's private view types. You build the
//! owned tree (`Body.toOwned`) only when you actually need a message to outlive
//! its frame.
//!
//! ## Lifetimes, and how the lists work
//!
//! Scalar fields and slices point right into the frame's bytes. (On the
//! owned-fallback path they point into an owned `model.Message` instead.) The
//! three open-ended sequences, `Args`, `PositionList`, and `PipelinePath`, need a
//! little more machinery. Each carries a small piece of borrowed state plus a
//! tiny table of `len` and `at` functions the codec hands it. That's what lets
//! the view walk a list lazily without allocating a box per list, and it's also
//! why this file never imports `codec`: the codec owns the parsing, the view just
//! dispatches into it. On the owned-fallback path the backing is simply a slice.
//!
//! Nested containers (`Argument.list`, `.set`, `.tagged`) are themselves `Args`,
//! so the whole tree stays borrowed and allocation-free right up until you call
//! `toOwned`.

const std = @import("std");
const model = @import("mod.zig");

/// What you get when reading a borrowed element out of wire bytes goes wrong.
/// Only the codec-backed lists can produce this; the slice-backed fallback never
/// fails. The codec's finer-grained errors all collapse to `MalformedView` here.
/// The codec still fails loudly, and the engine turns that into a typed
/// `op:abort`.
pub const ProjectError = error{MalformedView};

/// A hard ceiling on how deep `toOwned` will build. The session sets its own,
/// lower inbound cap (`SessionLimits.max_nesting_depth`) and validates before it
/// materializes anything, so real wire data never reaches this. This is the
/// model-layer backstop for the case where someone calls `toOwned` on a borrowed
/// view that skipped session validation: a pathologically nested tree fails with
/// `MalformedView` rather than overflowing the stack.
pub const max_owned_depth: usize = 256;

/// Materialization failure: a projection failure ([`ProjectError`]) or an
/// allocation failure while building the owned tree.
pub const Error = ProjectError || std.mem.Allocator.Error;

// ── Lazy sequences ───────────────────────────────────────────────────────────

/// A borrowed sequence of `Argument` values.
///
/// It's backed one of two ways: by a plain `slice` of owned arguments (the
/// fallback path), or by a small codec-supplied table that reads them straight
/// off the wire. Either way you only ever see `len` and `at`; which backing it
/// is stays hidden.
pub const Args = struct {
    inner: Inner,

    const Inner = union(enum) {
        slice: []const model.Argument,
        backed: Backed,
    };

    /// Codec-private cursor borrowing wire memory. `bytes` is the codec's view
    /// of the list region; `w0`/`w1`/`w2` are codec-interpreted scalars (e.g.
    /// a word offset, element stride, and element count).
    pub const Ctx = struct {
        bytes: []const u8 = &.{},
        w0: u64 = 0,
        w1: u64 = 0,
        w2: u64 = 0,
    };

    pub const VTable = struct {
        len: *const fn (Ctx) ProjectError!usize,
        at: *const fn (Ctx, usize) ProjectError!Argument,
        /// Forward cursor: read the element at the codec-interpreted `cursor`,
        /// advance `cursor` past it, and return it; return `null` at the end.
        /// The single forward walk replaces a loop of `at(i)`, which on a
        /// byte-framed codec re-scans from the start each call (O(n^2)).
        next: *const fn (Ctx, *u64) ProjectError!?Argument,
    };

    pub const Backed = struct {
        ctx: Ctx,
        vtable: *const VTable,
    };

    /// Forward-only walk over an [`Args`] sequence. One linear pass, no
    /// per-element re-scan and no `len()` pre-walk — the shape the session's
    /// hot validate/install paths use.
    pub const Iterator = struct {
        inner: union(enum) {
            slice: struct { items: []const model.Argument, index: usize },
            backed: struct { backed: Backed, cursor: u64 },
        },

        pub fn next(self: *Iterator) ProjectError!?Argument {
            switch (self.inner) {
                .slice => |*s| {
                    if (s.index >= s.items.len) return null;
                    const out = Argument.fromOwned(&s.items[s.index]);
                    s.index += 1;
                    return out;
                },
                .backed => |*b| return b.backed.vtable.next(b.backed.ctx, &b.cursor),
            }
        }
    };

    pub fn empty() Args {
        return .{ .inner = .{ .slice = &.{} } };
    }

    pub fn fromOwnedSlice(slice: []const model.Argument) Args {
        return .{ .inner = .{ .slice = slice } };
    }

    pub fn fromBacking(ctx: Ctx, vtable: *const VTable) Args {
        return .{ .inner = .{ .backed = .{ .ctx = ctx, .vtable = vtable } } };
    }

    pub fn len(self: Args) ProjectError!usize {
        return switch (self.inner) {
            .slice => |s| s.len,
            .backed => |b| b.vtable.len(b.ctx),
        };
    }

    pub fn at(self: Args, index: usize) ProjectError!Argument {
        return switch (self.inner) {
            .slice => |s| Argument.fromOwned(&s[index]),
            .backed => |b| b.vtable.at(b.ctx, index),
        };
    }

    pub fn iterator(self: Args) Iterator {
        return switch (self.inner) {
            .slice => |s| .{ .inner = .{ .slice = .{ .items = s, .index = 0 } } },
            .backed => |b| .{ .inner = .{ .backed = .{ .backed = b, .cursor = 0 } } },
        };
    }

    pub fn toOwnedSlice(self: Args, allocator: std.mem.Allocator) Error![]model.Argument {
        return self.toOwnedSliceDepth(allocator, 0);
    }

    fn toOwnedSliceDepth(self: Args, allocator: std.mem.Allocator, depth: usize) Error![]model.Argument {
        if (depth > max_owned_depth) return error.MalformedView;
        const count = try self.len();
        const out = try allocator.alloc(model.Argument, count);
        errdefer allocator.free(out);
        var initialized: usize = 0;
        errdefer for (out[0..initialized]) |arg| model.freeArgument(allocator, arg);
        var it = self.iterator();
        while (try it.next()) |arg| {
            if (initialized >= count) return error.MalformedView;
            out[initialized] = try arg.toOwnedDepth(allocator, depth);
            initialized += 1;
        }
        if (initialized != count) return error.MalformedView;
        return out;
    }
};

/// Borrowed sequence of positive integers (export-pos, answer-pos, or
/// wire-delta values). Same backing-dispatch shape as [`Args`].
pub const PositionList = struct {
    inner: Inner,

    const Inner = union(enum) {
        slice: []const u64,
        backed: Backed,
    };

    pub const Ctx = Args.Ctx;

    pub const VTable = struct {
        len: *const fn (Ctx) ProjectError!usize,
        at: *const fn (Ctx, usize) ProjectError!u64,
        next: *const fn (Ctx, *u64) ProjectError!?u64,
    };

    pub const Backed = struct {
        ctx: Ctx,
        vtable: *const VTable,
    };

    pub const Iterator = struct {
        inner: union(enum) {
            slice: struct { items: []const u64, index: usize },
            backed: struct { backed: Backed, cursor: u64 },
        },

        pub fn next(self: *Iterator) ProjectError!?u64 {
            switch (self.inner) {
                .slice => |*s| {
                    if (s.index >= s.items.len) return null;
                    const out = s.items[s.index];
                    s.index += 1;
                    return out;
                },
                .backed => |*b| return b.backed.vtable.next(b.backed.ctx, &b.cursor),
            }
        }
    };

    pub fn empty() PositionList {
        return .{ .inner = .{ .slice = &.{} } };
    }

    pub fn fromOwnedSlice(slice: []const u64) PositionList {
        return .{ .inner = .{ .slice = slice } };
    }

    pub fn fromBacking(ctx: Ctx, vtable: *const VTable) PositionList {
        return .{ .inner = .{ .backed = .{ .ctx = ctx, .vtable = vtable } } };
    }

    pub fn len(self: PositionList) ProjectError!usize {
        return switch (self.inner) {
            .slice => |s| s.len,
            .backed => |b| b.vtable.len(b.ctx),
        };
    }

    pub fn at(self: PositionList, index: usize) ProjectError!u64 {
        return switch (self.inner) {
            .slice => |s| s[index],
            .backed => |b| b.vtable.at(b.ctx, index),
        };
    }

    pub fn iterator(self: PositionList) Iterator {
        return switch (self.inner) {
            .slice => |s| .{ .inner = .{ .slice = .{ .items = s, .index = 0 } } },
            .backed => |b| .{ .inner = .{ .backed = .{ .backed = b, .cursor = 0 } } },
        };
    }

    pub fn toOwnedSlice(self: PositionList, allocator: std.mem.Allocator) Error![]u64 {
        const count = try self.len();
        const out = try allocator.alloc(u64, count);
        errdefer allocator.free(out);
        var initialized: usize = 0;
        var it = self.iterator();
        while (try it.next()) |value| {
            if (initialized >= count) return error.MalformedView;
            out[initialized] = value;
            initialized += 1;
        }
        if (initialized != count) return error.MalformedView;
        return out;
    }
};

/// Borrowed sequence of [`PipelineOp`] values (a promise pipeline path).
pub const PipelinePath = struct {
    inner: Inner,

    const Inner = union(enum) {
        slice: []const model.PipelineOp,
        backed: Backed,
    };

    pub const Ctx = Args.Ctx;

    pub const VTable = struct {
        len: *const fn (Ctx) ProjectError!usize,
        at: *const fn (Ctx, usize) ProjectError!PipelineOp,
        next: *const fn (Ctx, *u64) ProjectError!?PipelineOp,
    };

    pub const Backed = struct {
        ctx: Ctx,
        vtable: *const VTable,
    };

    pub const Iterator = struct {
        inner: union(enum) {
            slice: struct { items: []const model.PipelineOp, index: usize },
            backed: struct { backed: Backed, cursor: u64 },
        },

        pub fn next(self: *Iterator) ProjectError!?PipelineOp {
            switch (self.inner) {
                .slice => |*s| {
                    if (s.index >= s.items.len) return null;
                    const out = PipelineOp.fromOwned(&s.items[s.index]);
                    s.index += 1;
                    return out;
                },
                .backed => |*b| return b.backed.vtable.next(b.backed.ctx, &b.cursor),
            }
        }
    };

    pub fn empty() PipelinePath {
        return .{ .inner = .{ .slice = &.{} } };
    }

    pub fn fromOwnedSlice(slice: []const model.PipelineOp) PipelinePath {
        return .{ .inner = .{ .slice = slice } };
    }

    pub fn fromBacking(ctx: Ctx, vtable: *const VTable) PipelinePath {
        return .{ .inner = .{ .backed = .{ .ctx = ctx, .vtable = vtable } } };
    }

    pub fn len(self: PipelinePath) ProjectError!usize {
        return switch (self.inner) {
            .slice => |s| s.len,
            .backed => |b| b.vtable.len(b.ctx),
        };
    }

    pub fn at(self: PipelinePath, index: usize) ProjectError!PipelineOp {
        return switch (self.inner) {
            .slice => |s| PipelineOp.fromOwned(&s[index]),
            .backed => |b| b.vtable.at(b.ctx, index),
        };
    }

    pub fn iterator(self: PipelinePath) Iterator {
        return switch (self.inner) {
            .slice => |s| .{ .inner = .{ .slice = .{ .items = s, .index = 0 } } },
            .backed => |b| .{ .inner = .{ .backed = .{ .backed = b, .cursor = 0 } } },
        };
    }

    pub fn toOwned(self: PipelinePath, allocator: std.mem.Allocator) Error!model.PipelinePath {
        const count = try self.len();
        if (count == 0) return .{};
        const ops = try allocator.alloc(model.PipelineOp, count);
        errdefer allocator.free(ops);
        var initialized: usize = 0;
        errdefer for (ops[0..initialized]) |op| freePipelineOp(allocator, op);
        var it = self.iterator();
        while (try it.next()) |op| {
            if (initialized >= count) return error.MalformedView;
            ops[initialized] = try op.toOwned(allocator);
            initialized += 1;
        }
        if (initialized != count) return error.MalformedView;
        return .{ .ops = ops };
    }
};

fn freePipelineOp(allocator: std.mem.Allocator, op: model.PipelineOp) void {
    switch (op) {
        .field => |field| allocator.free(field),
        .call => |args| model.freeArgumentSlice(allocator, args),
    }
}

// ── Value views ──────────────────────────────────────────────────────────────

/// Borrowed mirror of [`model.Error`]. Named `ErrorValue` so it does not
/// collide with this module's [`Error`] error set.
pub const ErrorValue = struct {
    message: []const u8,

    pub fn fromOwned(owned: *const model.Error) ErrorValue {
        return .{ .message = owned.message };
    }

    pub fn toOwned(self: ErrorValue, allocator: std.mem.Allocator) Error!model.Error {
        return .{ .message = try allocator.dupe(u8, self.message) };
    }
};

/// Borrowed mirror of [`model.PeerLocator`]. `hints` is carried by value
/// (the wire path only produces the empty-map / empty-false shapes).
pub const PeerLocatorView = struct {
    transport: []const u8,
    designator: []const u8,
    hints: model.Hints = .{},

    pub fn fromOwned(owned: *const model.PeerLocator) PeerLocatorView {
        return .{ .transport = owned.transport, .designator = owned.designator, .hints = owned.hints };
    }

    pub fn toOwned(self: PeerLocatorView, allocator: std.mem.Allocator) Error!model.PeerLocator {
        const transport = try allocator.dupe(u8, self.transport);
        errdefer allocator.free(transport);
        const designator = try allocator.dupe(u8, self.designator);
        errdefer allocator.free(designator);
        const hints = try model.cloneHints(allocator, self.hints);
        return .{ .transport = transport, .designator = designator, .hints = hints };
    }
};

/// Borrowed mirror of [`model.SturdyRef`].
pub const SturdyRef = struct {
    peer: PeerLocatorView,
    swissnum: []const u8,
};

/// Borrowed mirror of [`model.PromiseRef`].
pub const PromiseRef = struct {
    answer_id: u64,
    path: PipelinePath = PipelinePath.empty(),
};

/// Borrowed mirror of [`model.Reference`]. `near` / `far` carry POD ids by
/// value; `sturdy` / `broken` borrow wire bytes; `promise` carries a lazy path.
pub const Reference = union(enum) {
    near: model.NearRef,
    far: model.FarRef,
    promise: PromiseRef,
    sturdy: SturdyRef,
    broken: ErrorValue,

    pub fn fromOwned(owned: *const model.Reference) Reference {
        return switch (owned.*) {
            .near => |near| .{ .near = near },
            .far => |far| .{ .far = far },
            .promise => |promise| .{ .promise = .{
                .answer_id = promise.answer_id,
                .path = PipelinePath.fromOwnedSlice(promise.path.ops),
            } },
            .sturdy => |sturdy| .{ .sturdy = .{
                .peer = PeerLocatorView.fromOwned(&sturdy.peer),
                .swissnum = sturdy.swissnum,
            } },
            .broken => |broken| .{ .broken = .{ .message = broken.message } },
        };
    }

    pub fn toOwned(self: Reference, allocator: std.mem.Allocator) Error!model.Reference {
        return switch (self) {
            .near => |near| .{ .near = near },
            .far => |far| .{ .far = far },
            .promise => |promise| .{ .promise = .{
                .answer_id = promise.answer_id,
                .path = try promise.path.toOwned(allocator),
            } },
            .sturdy => |sturdy| blk: {
                const peer = try sturdy.peer.toOwned(allocator);
                errdefer model.freePeerLocator(allocator, peer);
                const swissnum = try allocator.dupe(u8, sturdy.swissnum);
                break :blk .{ .sturdy = .{ .peer = peer, .swissnum = swissnum } };
            },
            .broken => |broken| .{ .broken = .{ .message = try allocator.dupe(u8, broken.message) } },
        };
    }
};

/// Borrowed mirror of [`model.Argument`] — full fidelity (all fourteen arms).
/// Nested containers are lazy [`Args`], so the tree stays borrowed with no
/// per-node allocation until [`toOwned`](Argument.toOwned).
pub const Argument = union(enum) {
    bytes: []const u8,
    symbol: []const u8,
    reference: Reference,
    @"error": ErrorValue,
    handoff: Handoff,
    string: []const u8,
    integer: i64,
    boolean: bool,
    list: Args,
    void: void,
    float64: f64,
    set: Args,
    tagged: Tagged,
    keyword: []const u8,

    pub const Tagged = struct {
        tag: []const u8,
        value: Args,
    };

    pub fn fromOwned(owned: *const model.Argument) Argument {
        return switch (owned.*) {
            .bytes => |bytes| .{ .bytes = bytes },
            .symbol => |symbol| .{ .symbol = symbol },
            .reference => |*reference| .{ .reference = Reference.fromOwned(reference) },
            .@"error" => |err| .{ .@"error" = .{ .message = err.message } },
            .handoff => |handoff| .{ .handoff = Handoff.fromOwned(handoff) },
            .string => |string| .{ .string = string },
            .integer => |integer| .{ .integer = integer },
            .boolean => |boolean| .{ .boolean = boolean },
            .list => |items| .{ .list = Args.fromOwnedSlice(items) },
            .void => .{ .void = {} },
            .float64 => |float64| .{ .float64 = float64 },
            .set => |items| .{ .set = Args.fromOwnedSlice(items) },
            .tagged => |tagged| .{ .tagged = .{ .tag = tagged.tag, .value = Args.fromOwnedSlice(tagged.value) } },
            .keyword => |keyword| .{ .keyword = keyword },
        };
    }

    pub fn toOwned(self: Argument, allocator: std.mem.Allocator) Error!model.Argument {
        return self.toOwnedDepth(allocator, 0);
    }

    fn toOwnedDepth(self: Argument, allocator: std.mem.Allocator, depth: usize) Error!model.Argument {
        return switch (self) {
            .bytes => |bytes| .{ .bytes = try allocator.dupe(u8, bytes) },
            .symbol => |symbol| .{ .symbol = try allocator.dupe(u8, symbol) },
            .reference => |reference| .{ .reference = try reference.toOwned(allocator) },
            .@"error" => |err| .{ .@"error" = try err.toOwned(allocator) },
            .handoff => |handoff| blk: {
                const boxed = try allocator.create(model.Handoff);
                errdefer allocator.destroy(boxed);
                boxed.* = try handoff.toOwned(allocator);
                break :blk .{ .handoff = boxed };
            },
            .string => |string| .{ .string = try allocator.dupe(u8, string) },
            .integer => |integer| .{ .integer = integer },
            .boolean => |boolean| .{ .boolean = boolean },
            .list => |items| .{ .list = try items.toOwnedSliceDepth(allocator, depth + 1) },
            .void => .{ .void = {} },
            .float64 => |float64| .{ .float64 = float64 },
            .set => |items| .{ .set = try items.toOwnedSliceDepth(allocator, depth + 1) },
            .tagged => |tagged| blk: {
                const tag = try allocator.dupe(u8, tagged.tag);
                errdefer allocator.free(tag);
                const value = try tagged.value.toOwnedSliceDepth(allocator, depth + 1);
                break :blk .{ .tagged = .{ .tag = tag, .value = value } };
            },
            .keyword => |keyword| .{ .keyword = try allocator.dupe(u8, keyword) },
        };
    }
};

/// Borrowed mirror of [`model.PipelineOp`].
pub const PipelineOp = union(enum) {
    field: []const u8,
    call: Args,

    pub fn fromOwned(owned: *const model.PipelineOp) PipelineOp {
        return switch (owned.*) {
            .field => |field| .{ .field = field },
            .call => |args| .{ .call = Args.fromOwnedSlice(args) },
        };
    }

    pub fn toOwned(self: PipelineOp, allocator: std.mem.Allocator) Error!model.PipelineOp {
        return switch (self) {
            .field => |field| .{ .field = try allocator.dupe(u8, field) },
            .call => |args| .{ .call = try args.toOwnedSlice(allocator) },
        };
    }
};

/// Borrowed mirror of [`model.Resolution`].
pub const Resolution = union(enum) {
    fulfill: Argument,
    break_: ErrorValue,

    pub fn fromOwned(owned: *const model.Resolution) Resolution {
        return switch (owned.*) {
            .fulfill => |*arg| .{ .fulfill = Argument.fromOwned(arg) },
            .break_ => |err| .{ .break_ = .{ .message = err.message } },
        };
    }

    pub fn toOwned(self: Resolution, allocator: std.mem.Allocator) Error!model.Resolution {
        return switch (self) {
            .fulfill => |arg| .{ .fulfill = try arg.toOwned(allocator) },
            .break_ => |err| .{ .break_ = try err.toOwned(allocator) },
        };
    }
};

/// A handoff's exporter location, in whichever shape its codec carried it.
///
/// `model.HandoffGive.exporter_location` is a single `[]const u8`, but the two
/// codecs disagree on its wire shape: Cap'n Proto carries opaque bytes (`raw`);
/// Syrup carries a structured `<ocapn-peer …>` locator it joins to
/// `"transport:designator"`. The join allocates, so it cannot be borrowed —
/// the `locator` arm keeps the borrowed components and defers the join to
/// [`toOwned`]. The owned-fallback path always uses `raw` (the owned field is
/// already in its final shape).
pub const ExporterLocation = union(enum) {
    raw: []const u8,
    locator: struct { transport: []const u8, designator: []const u8 },

    pub fn toOwned(self: ExporterLocation, allocator: std.mem.Allocator) Error![]u8 {
        return switch (self) {
            .raw => |bytes| allocator.dupe(u8, bytes),
            .locator => |loc| blk: {
                const out = try allocator.alloc(u8, loc.transport.len + 1 + loc.designator.len);
                @memcpy(out[0..loc.transport.len], loc.transport);
                out[loc.transport.len] = ':';
                @memcpy(out[loc.transport.len + 1 ..], loc.designator);
                break :blk out;
            },
        };
    }
};

/// A handoff signature, in whichever shape its codec carried it.
///
/// `model.HandoffGive.signature` is a single 64-byte `[]const u8`, but Syrup
/// carries it as two non-contiguous 32-byte halves (`r` / `s`) inside an
/// `<sig-val …>` record. The concatenation allocates, so it cannot be
/// borrowed — the `halves` arm keeps the borrowed halves and defers the join
/// to [`toOwned`]. Cap'n Proto carries the 64 bytes contiguously (`raw`).
pub const Signature = union(enum) {
    raw: []const u8,
    halves: struct { r: []const u8, s: []const u8 },

    pub fn toOwned(self: Signature, allocator: std.mem.Allocator) Error![]u8 {
        return switch (self) {
            .raw => |bytes| allocator.dupe(u8, bytes),
            .halves => |h| blk: {
                const out = try allocator.alloc(u8, h.r.len + h.s.len);
                @memcpy(out[0..h.r.len], h.r);
                @memcpy(out[h.r.len..], h.s);
                break :blk out;
            },
        };
    }
};

/// Borrowed mirror of [`model.HandoffGive`]. Fields borrow wire bytes; the
/// `exporter_location` and `signature` joins are deferred to [`toOwned`]
/// (see [`ExporterLocation`] / [`Signature`]).
pub const HandoffGive = struct {
    recipient_key: []const u8,
    exporter_location: ExporterLocation,
    gifter_exporter_session: []const u8,
    gifter_side: []const u8,
    gift_id: []const u8,
    signature: Signature,

    pub fn fromOwned(owned: *const model.HandoffGive) HandoffGive {
        return .{
            .recipient_key = owned.recipient_key,
            .exporter_location = .{ .raw = owned.exporter_location },
            .gifter_exporter_session = owned.gifter_exporter_session,
            .gifter_side = owned.gifter_side,
            .gift_id = owned.gift_id,
            .signature = .{ .raw = owned.signature },
        };
    }

    pub fn toOwned(self: HandoffGive, allocator: std.mem.Allocator) Error!model.HandoffGive {
        const recipient_key = try allocator.dupe(u8, self.recipient_key);
        errdefer allocator.free(recipient_key);
        const exporter_location = try self.exporter_location.toOwned(allocator);
        errdefer allocator.free(exporter_location);
        const gifter_exporter_session = try allocator.dupe(u8, self.gifter_exporter_session);
        errdefer allocator.free(gifter_exporter_session);
        const gifter_side = try allocator.dupe(u8, self.gifter_side);
        errdefer allocator.free(gifter_side);
        const gift_id = try allocator.dupe(u8, self.gift_id);
        errdefer allocator.free(gift_id);
        const signature = try self.signature.toOwned(allocator);
        return .{
            .recipient_key = recipient_key,
            .exporter_location = exporter_location,
            .gifter_exporter_session = gifter_exporter_session,
            .gifter_side = gifter_side,
            .gift_id = gift_id,
            .signature = signature,
        };
    }
};

/// Borrowed mirror of [`model.HandoffReceive`].
pub const HandoffReceive = struct {
    receiving_session: []const u8,
    receiving_side: []const u8,
    handoff_count: u64,
    signed_give: HandoffGive,
    signature: Signature,
};

/// Borrowed mirror of [`model.Handoff`].
pub const Handoff = union(enum) {
    give: HandoffGive,
    receive: HandoffReceive,

    pub fn fromOwned(owned: *const model.Handoff) Handoff {
        return switch (owned.*) {
            .give => |*give| .{ .give = HandoffGive.fromOwned(give) },
            .receive => |*receive| .{ .receive = .{
                .receiving_session = receive.receiving_session,
                .receiving_side = receive.receiving_side,
                .handoff_count = receive.handoff_count,
                .signed_give = HandoffGive.fromOwned(&receive.signed_give),
                .signature = .{ .raw = receive.signature },
            } },
        };
    }

    pub fn toOwned(self: Handoff, allocator: std.mem.Allocator) Error!model.Handoff {
        return switch (self) {
            .give => |give| .{ .give = try give.toOwned(allocator) },
            .receive => |receive| blk: {
                const receiving_session = try allocator.dupe(u8, receive.receiving_session);
                errdefer allocator.free(receiving_session);
                const receiving_side = try allocator.dupe(u8, receive.receiving_side);
                errdefer allocator.free(receiving_side);
                const signed_give = try receive.signed_give.toOwned(allocator);
                errdefer model.owned.freeHandoffGive(allocator, signed_give);
                const signature = try receive.signature.toOwned(allocator);
                break :blk .{ .receive = .{
                    .receiving_session = receiving_session,
                    .receiving_side = receiving_side,
                    .handoff_count = receive.handoff_count,
                    .signed_give = signed_give,
                    .signature = signature,
                } };
            },
        };
    }
};

// ── Per-variant message views ────────────────────────────────────────────────

pub const Deliver = struct {
    target: Reference,
    args: Args,
    answer: ?u64 = null,
    resolve_me_desc: ?Reference = null,
};

pub const Resolve = struct {
    answer: u64,
    resolution: Resolution,
};

pub const Listen = struct {
    target: Reference,
    listener: Reference,
    wants_partial: bool,
};

pub const Get = struct {
    receiver: Reference,
    field: []const u8,
    answer: u64,
};

pub const Index = struct {
    receiver: Reference,
    index: i64,
    answer: u64,
};

pub const GcExport = struct {
    positions: PositionList,
    deltas: PositionList,
};

pub const GcAnswer = struct {
    positions: PositionList,
};

pub const Abort = struct {
    kind: model.AbortKind,
    message: []const u8,
};

pub const StartSession = struct {
    captp_version: model.CaptpVersion,
    session_pubkey: []const u8,
    acceptable_location: PeerLocatorView,
    acceptable_location_sig: Signature,
};

// ── Body sum type ────────────────────────────────────────────────────────────

/// Borrowed codec-neutral body of a CapTP [`model.Message`].
///
/// Produced by a codec's `decodeView` (the wire path) or by [`fromOwned`] (the
/// owned-fallback path). Materialize with [`toOwned`].
pub const Body = union(enum) {
    deliver: Deliver,
    resolve: Resolve,
    gc_export: GcExport,
    gc_answer: GcAnswer,
    handoff: Handoff,
    start_session: StartSession,
    abort: Abort,
    listen: Listen,
    get: Get,
    index: Index,

    /// Project a borrowed body from an owned [`model.Message`]. Infallible; the
    /// borrowed fields point into `owned` for its lifetime.
    pub fn fromOwned(owned: *const model.Message) Body {
        return switch (owned.*) {
            .deliver => |*deliver| .{ .deliver = .{
                .target = Reference.fromOwned(&deliver.target),
                .args = Args.fromOwnedSlice(deliver.args),
                .answer = deliver.answer,
                .resolve_me_desc = if (deliver.resolve_me_desc) |*r| Reference.fromOwned(r) else null,
            } },
            .resolve => |*resolve| .{ .resolve = .{
                .answer = resolve.answer,
                .resolution = Resolution.fromOwned(&resolve.resolution),
            } },
            .gc_export => |*gc| .{ .gc_export = .{
                .positions = PositionList.fromOwnedSlice(gc.positions),
                .deltas = PositionList.fromOwnedSlice(gc.deltas),
            } },
            .gc_answer => |*gc| .{ .gc_answer = .{
                .positions = PositionList.fromOwnedSlice(gc.positions),
            } },
            .handoff => |*handoff| .{ .handoff = Handoff.fromOwned(handoff) },
            .start_session => |*ss| .{ .start_session = .{
                .captp_version = ss.captp_version,
                .session_pubkey = ss.session_pubkey.bytes,
                .acceptable_location = PeerLocatorView.fromOwned(&ss.acceptable_location),
                .acceptable_location_sig = .{ .raw = ss.acceptable_location_sig.bytes },
            } },
            .abort => |*abort| .{ .abort = .{ .kind = abort.kind, .message = abort.message } },
            .listen => |*listen| .{ .listen = .{
                .target = Reference.fromOwned(&listen.target),
                .listener = Reference.fromOwned(&listen.listener),
                .wants_partial = listen.wants_partial,
            } },
            .get => |*get| .{ .get = .{
                .receiver = Reference.fromOwned(&get.receiver),
                .field = get.field,
                .answer = get.answer,
            } },
            .index => |*index| .{ .index = .{
                .receiver = Reference.fromOwned(&index.receiver),
                .index = index.index,
                .answer = index.answer,
            } },
        };
    }

    /// Materialize the owned [`model.Message`]. The only allocating path;
    /// builds the full owned tree with fail-loud cleanup on partial failure.
    pub fn toOwned(self: Body, allocator: std.mem.Allocator) Error!model.Message {
        return switch (self) {
            .deliver => |deliver| try deliverToOwned(allocator, deliver),
            .resolve => |resolve| .{ .resolve = .{
                .answer = resolve.answer,
                .resolution = try resolve.resolution.toOwned(allocator),
            } },
            .gc_export => |gc| blk: {
                const positions = try gc.positions.toOwnedSlice(allocator);
                errdefer allocator.free(positions);
                const deltas = try gc.deltas.toOwnedSlice(allocator);
                break :blk .{ .gc_export = .{ .positions = positions, .deltas = deltas } };
            },
            .gc_answer => |gc| .{ .gc_answer = .{ .positions = try gc.positions.toOwnedSlice(allocator) } },
            .handoff => |handoff| .{ .handoff = try handoff.toOwned(allocator) },
            .start_session => |ss| blk: {
                const session_pubkey = try allocator.dupe(u8, ss.session_pubkey);
                errdefer allocator.free(session_pubkey);
                const acceptable_location = try ss.acceptable_location.toOwned(allocator);
                errdefer model.freePeerLocator(allocator, acceptable_location);
                const sig = try ss.acceptable_location_sig.toOwned(allocator);
                break :blk .{ .start_session = .{
                    .captp_version = ss.captp_version,
                    .session_pubkey = .{ .bytes = session_pubkey },
                    .acceptable_location = acceptable_location,
                    .acceptable_location_sig = .{ .bytes = sig },
                } };
            },
            .abort => |abort| .{ .abort = .{ .kind = abort.kind, .message = try allocator.dupe(u8, abort.message) } },
            .listen => |listen| blk: {
                const target = try listen.target.toOwned(allocator);
                errdefer model.freeReference(allocator, target);
                const listener = try listen.listener.toOwned(allocator);
                break :blk .{ .listen = .{ .target = target, .listener = listener, .wants_partial = listen.wants_partial } };
            },
            .get => |get| blk: {
                const receiver = try get.receiver.toOwned(allocator);
                errdefer model.freeReference(allocator, receiver);
                const field = try allocator.dupe(u8, get.field);
                break :blk .{ .get = .{ .receiver = receiver, .field = field, .answer = get.answer } };
            },
            .index => |index| .{ .index = .{
                .receiver = try index.receiver.toOwned(allocator),
                .index = index.index,
                .answer = index.answer,
            } },
        };
    }

    /// Discriminant tag, mirroring [`model.Message`]'s union tags.
    pub fn kind(self: Body) std.meta.Tag(Body) {
        return std.meta.activeTag(self);
    }
};

fn deliverToOwned(allocator: std.mem.Allocator, deliver: Deliver) Error!model.Message {
    const target = try deliver.target.toOwned(allocator);
    errdefer model.freeReference(allocator, target);
    const resolve_me_desc = if (deliver.resolve_me_desc) |r| try r.toOwned(allocator) else null;
    errdefer if (resolve_me_desc) |r| model.freeReference(allocator, r);
    const args = try deliver.args.toOwnedSlice(allocator);
    return .{ .deliver = .{
        .target = target,
        .args = args,
        .answer = deliver.answer,
        .resolve_me_desc = resolve_me_desc,
    } };
}
