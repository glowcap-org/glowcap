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
//! little more machinery, and all three get it from one `LazySequence` generic.
//! Each carries a small piece of borrowed state plus a
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
const records = @import("view_records.zig");

/// What you get when reading a borrowed element out of wire bytes goes wrong:
/// a codec-backed list met malformed wire bytes, or `at` was asked for an index
/// past the end of either backing. The codec's finer-grained errors all collapse
/// to `MalformedView` here. The codec still fails loudly, and the engine turns
/// that into a typed `op:abort`.
pub const ProjectError = error{MalformedView};

/// Materialization failure: a projection failure (`ProjectError`) or an
/// allocation failure while building the owned tree.
pub const Error = ProjectError || std.mem.Allocator.Error;

// ── Lazy sequences ───────────────────────────────────────────────────────────

/// Codec-private cursor borrowing wire memory, shared by every lazy sequence.
/// `bytes` is the codec's view of the list region; `w0`/`w1`/`w2` are
/// codec-interpreted scalars (e.g. a word offset, element stride, and element
/// count). One shared type, so a codec can build a cursor once and hand it to
/// `Args`, `PositionList`, or `PipelinePath` alike.
const SequenceCtx = struct {
    bytes: []const u8 = &.{},
    w0: u64 = 0,
    w1: u64 = 0,
    w2: u64 = 0,
};

/// The slice-or-vtable backing machinery behind `Args`, `PositionList`,
/// and `PipelinePath`. One comptime generic, instantiated three times.
///
/// A sequence is backed one of two ways: by a plain `slice` of owned elements
/// (the fallback path), or by a small codec-supplied table that reads them
/// straight off the wire. Either way you only ever see `len`, `at`, and
/// `iterator`; which backing it is stays hidden.
///
/// `OwnedElem` is the owned model element; `ViewElem` is its borrowed
/// projection. When the two are the same type (the POD `u64` positions), the
/// projection is the identity and materializing allocates nothing per element.
fn LazySequence(comptime OwnedElem: type, comptime ViewElem: type) type {
    return struct {
        inner: Inner,

        const Self = @This();

        const Inner = union(enum) {
            slice: []const OwnedElem,
            backed: Backed,
        };

        pub const Ctx = SequenceCtx;

        pub const VTable = struct {
            len: *const fn (Ctx) ProjectError!usize,
            at: *const fn (Ctx, usize) ProjectError!ViewElem,
            /// Forward cursor: read the element at the codec-interpreted `cursor`,
            /// advance `cursor` past it, and return it; return `null` at the end.
            /// The single forward walk replaces a loop of `at(i)`, which on a
            /// byte-framed codec re-scans from the start each call (O(n^2)).
            next: *const fn (Ctx, *u64) ProjectError!?ViewElem,
        };

        pub const Backed = struct {
            ctx: Ctx,
            vtable: *const VTable,
        };

        /// Forward-only walk over the sequence. One linear pass, no
        /// per-element re-scan and no `len()` pre-walk, the shape the
        /// session's hot validate/install paths use.
        pub const Iterator = struct {
            inner: union(enum) {
                slice: struct { items: []const OwnedElem, index: usize },
                backed: struct { backed: Backed, cursor: u64 },
            },

            pub fn next(self: *Iterator) ProjectError!?ViewElem {
                switch (self.inner) {
                    .slice => |*s| {
                        if (s.index >= s.items.len) return null;
                        const out = project(&s.items[s.index]);
                        s.index += 1;
                        return out;
                    },
                    .backed => |*b| return b.backed.vtable.next(b.backed.ctx, &b.cursor),
                }
            }
        };

        /// Borrow the view projection of one owned element (the identity for
        /// POD elements).
        fn project(elem: *const OwnedElem) ViewElem {
            return if (comptime OwnedElem == ViewElem) elem.* else ViewElem.fromOwned(elem);
        }

        /// Materialize one viewed element into its owned form at `depth`.
        fn materialize(allocator: std.mem.Allocator, elem: ViewElem, depth: usize) Error!OwnedElem {
            if (comptime OwnedElem == ViewElem) {
                return elem;
            } else {
                return elem.toOwnedDepth(allocator, depth);
            }
        }

        /// Release one owned element on the partial-failure unwind.
        fn freeOwned(allocator: std.mem.Allocator, elem: OwnedElem) void {
            if (comptime OwnedElem == model.Argument) {
                model.freeArgument(allocator, elem);
            } else if (comptime OwnedElem == model.PipelineOp) {
                model.owned.freePipelineOp(allocator, elem);
            } else if (comptime OwnedElem == model.StructEntry) {
                model.freeArgument(allocator, elem.value);
                allocator.free(elem.key);
            } else if (comptime OwnedElem != u64) {
                // POD elements (u64 positions) own nothing. Any new element
                // type must declare its release arm above, a silent
                // fall-through would leak every element on the unwind path.
                @compileError("LazySequence.freeOwned has no release arm for " ++ @typeName(OwnedElem));
            }
        }

        pub fn empty() Self {
            return .{ .inner = .{ .slice = &.{} } };
        }

        pub fn fromOwnedSlice(slice: []const OwnedElem) Self {
            return .{ .inner = .{ .slice = slice } };
        }

        pub fn fromBacking(ctx: Ctx, vtable: *const VTable) Self {
            return .{ .inner = .{ .backed = .{ .ctx = ctx, .vtable = vtable } } };
        }

        pub fn len(self: Self) ProjectError!usize {
            return switch (self.inner) {
                .slice => |s| s.len,
                .backed => |b| b.vtable.len(b.ctx),
            };
        }

        pub fn at(self: Self, index: usize) ProjectError!ViewElem {
            return switch (self.inner) {
                .slice => |s| if (index < s.len) project(&s[index]) else error.MalformedView,
                .backed => |b| b.vtable.at(b.ctx, index),
            };
        }

        pub fn iterator(self: Self) Iterator {
            return switch (self.inner) {
                .slice => |s| .{ .inner = .{ .slice = .{ .items = s, .index = 0 } } },
                .backed => |b| .{ .inner = .{ .backed = .{ .backed = b, .cursor = 0 } } },
            };
        }

        pub fn toOwnedSlice(self: Self, allocator: std.mem.Allocator) Error![]OwnedElem {
            return self.toOwnedSliceDepth(allocator, 0);
        }

        fn toOwnedSliceDepth(self: Self, allocator: std.mem.Allocator, depth: usize) Error![]OwnedElem {
            // The session sets its own, lower inbound cap
            // (`SessionLimits.max_nesting_depth`) and validates before it
            // materializes anything, so real wire data never reaches this. The
            // shared ceiling is the model-layer backstop for a borrowed view
            // that skipped session validation: a pathologically nested tree
            // fails with `MalformedView` rather than overflowing the stack.
            if (depth > model.max_value_depth) return error.MalformedView;
            const count = try self.len();
            const out = try allocator.alloc(OwnedElem, count);
            errdefer allocator.free(out);
            var initialized: usize = 0;
            errdefer for (out[0..initialized]) |elem| freeOwned(allocator, elem);
            var it = self.iterator();
            while (try it.next()) |elem| {
                if (initialized >= count) return error.MalformedView;
                out[initialized] = try materialize(allocator, elem, depth);
                initialized += 1;
            }
            if (initialized != count) return error.MalformedView;
            return out;
        }
    };
}

/// A borrowed sequence of `Argument` values.
pub const Args = LazySequence(model.Argument, Argument);

/// A borrowed sequence of `StructEntry` pairs, the lazy backing of an OCapN
/// `Argument.@"struct"`. One cursor walks (key, value) pairs off the wire, the
/// same shape `Args` walks single values, so a struct projects with no per-entry
/// allocation until `Argument.toOwned`.
pub const StructEntries = LazySequence(model.StructEntry, StructEntry);

/// Borrowed mirror of `model.StructEntry`: a String key and a borrowed value.
pub const StructEntry = struct {
    key: []const u8,
    value: Argument,

    pub fn fromOwned(owned: *const model.StructEntry) StructEntry {
        return .{ .key = owned.key, .value = Argument.fromOwned(&owned.value) };
    }

    pub fn toOwnedDepth(self: StructEntry, allocator: std.mem.Allocator, depth: usize) Error!model.StructEntry {
        const key = try allocator.dupe(u8, self.key);
        errdefer allocator.free(key);
        return .{ .key = key, .value = try self.value.toOwnedDepth(allocator, depth) };
    }
};

/// Borrowed sequence of positive integers (export-pos, answer-pos, or
/// wire-delta values).
pub const PositionList = LazySequence(u64, u64);

/// Borrowed sequence of `PipelineOp` values (a promise pipeline path).
pub const PipelinePath = LazySequence(model.PipelineOp, PipelineOp);

/// Materialize the owned `model.PipelinePath` record from a borrowed path.
/// The record wrapping is pipeline-path-specific (an empty path collapses to
/// the shared empty record without touching the allocator), so it lives here
/// beside the alias; the generic sequence materializes plain slices only.
fn pipelinePathToOwned(path: PipelinePath, allocator: std.mem.Allocator, depth: usize) Error!model.PipelinePath {
    const ops = try path.toOwnedSliceDepth(allocator, depth);
    if (ops.len == 0) {
        allocator.free(ops);
        return .{};
    }
    return .{ .ops = ops };
}

// ── Value views ──────────────────────────────────────────────────────────────

pub const BreakReason = records.BreakReason;
pub const PeerLocator = records.PeerLocator;

/// Borrowed mirror of `model.SturdyRef`.
pub const SturdyRef = struct {
    peer: PeerLocator,
    swissnum: []const u8,
};

/// Borrowed mirror of `model.PromiseRef`.
pub const PromiseRef = struct {
    answer_position: model.AnswerId,
    path: PipelinePath = PipelinePath.empty(),
};

/// Borrowed mirror of `model.Reference`. `near` / `far` carry POD ids by
/// value; `sturdy` / `broken` borrow wire bytes; `promise` carries a lazy path.
pub const Reference = union(enum) {
    near: model.NearRef,
    far: model.FarRef,
    promise: PromiseRef,
    sturdy: SturdyRef,
    broken: BreakReason,

    /// The raw wire position this reference names: a near export's
    /// `export_position` or a far import's `import_position`, collapsed to the
    /// one `u64` integer space they share on the wire. Null for a reference that
    /// names no position (promise / sturdy / broken). Prefer `exportPosition`
    /// when you mean "the local export this names."
    pub fn position(self: Reference) ?u64 {
        return switch (self) {
            .near => |near| near.export_position.int(),
            .far => |far| far.import_position.int(),
            else => null,
        };
    }

    /// The local export position this reference names, but only when it is a
    /// `.near` export this peer hosts, typed, so it cannot be mistaken for a
    /// partner-named import id. A resolver-export lookup must use this, never
    /// `position`: keying an export-indexed map on a `.far` import id (the same
    /// integer space) would let a coincidental collision misclassify an ordinary
    /// deliver as a resolver callback.
    pub fn exportPosition(self: Reference) ?model.ExportId {
        return switch (self) {
            .near => |near| near.export_position,
            else => null,
        };
    }

    pub fn fromOwned(owned: *const model.Reference) Reference {
        return switch (owned.*) {
            .near => |near| .{ .near = near },
            .far => |far| .{ .far = far },
            .promise => |promise| .{ .promise = .{
                .answer_position = promise.answer_position,
                .path = PipelinePath.fromOwnedSlice(promise.path.ops),
            } },
            .sturdy => |sturdy| .{ .sturdy = .{
                .peer = PeerLocator.fromOwned(&sturdy.peer),
                .swissnum = sturdy.swissnum,
            } },
            .broken => |broken| .{ .broken = .{ .message = broken.message } },
        };
    }

    pub fn toOwned(self: Reference, allocator: std.mem.Allocator) Error!model.Reference {
        return self.toOwnedDepth(allocator, 0);
    }

    fn toOwnedDepth(self: Reference, allocator: std.mem.Allocator, depth: usize) Error!model.Reference {
        return switch (self) {
            .near => |near| .{ .near = near },
            .far => |far| .{ .far = far },
            .promise => |promise| .{ .promise = .{
                .answer_position = promise.answer_position,
                .path = try pipelinePathToOwned(promise.path, allocator, depth),
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

/// Borrowed mirror of `model.Argument`, carrying every arm.
/// Nested containers are lazy `Args`, so the tree stays borrowed with no
/// per-node allocation until `Argument.toOwned`.
pub const Argument = union(enum) {
    bytes: []const u8,
    symbol: []const u8,
    reference: Reference,
    @"error": BreakReason,
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
    @"struct": StructEntries,
    /// Borrows the canonical decimal digits straight from the wire.
    big_integer: model.BigInteger,

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
            .@"struct" => |entries| .{ .@"struct" = StructEntries.fromOwnedSlice(entries) },
            .big_integer => |big| .{ .big_integer = big },
        };
    }

    pub fn toOwned(self: Argument, allocator: std.mem.Allocator) Error!model.Argument {
        return self.toOwnedDepth(allocator, 0);
    }

    fn toOwnedDepth(self: Argument, allocator: std.mem.Allocator, depth: usize) Error!model.Argument {
        return switch (self) {
            .bytes => |bytes| .{ .bytes = try allocator.dupe(u8, bytes) },
            .symbol => |symbol| .{ .symbol = try allocator.dupe(u8, symbol) },
            .reference => |reference| .{ .reference = try reference.toOwnedDepth(allocator, depth) },
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
            .@"struct" => |entries| .{ .@"struct" = try entries.toOwnedSliceDepth(allocator, depth + 1) },
            .big_integer => |big| .{ .big_integer = .{
                .negative = big.negative,
                .digits = try allocator.dupe(u8, big.digits),
            } },
        };
    }
};

/// Borrowed mirror of `model.PipelineOp`.
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
        return self.toOwnedDepth(allocator, 0);
    }

    fn toOwnedDepth(self: PipelineOp, allocator: std.mem.Allocator, depth: usize) Error!model.PipelineOp {
        return switch (self) {
            .field => |field| .{ .field = try allocator.dupe(u8, field) },
            // A call op's args are one nesting level deeper, increment rather than
            // reset, so a promise→call→promise→call… tree is bounded by
            // `model.max_value_depth` like list/set/tagged nesting. Resetting to 0
            // here (the old `toOwnedSlice`) let such a tree recurse off the stack.
            .call => |args| .{ .call = try args.toOwnedSliceDepth(allocator, depth + 1) },
        };
    }
};

/// Borrowed mirror of `model.Resolution`.
pub const Resolution = union(enum) {
    fulfill: Argument,
    @"break": BreakReason,

    pub fn fromOwned(owned: *const model.Resolution) Resolution {
        return switch (owned.*) {
            .fulfill => |*arg| .{ .fulfill = Argument.fromOwned(arg) },
            .@"break" => |err| .{ .@"break" = .{ .message = err.message } },
        };
    }

    pub fn toOwned(self: Resolution, allocator: std.mem.Allocator) Error!model.Resolution {
        return switch (self) {
            .fulfill => |arg| .{ .fulfill = try arg.toOwned(allocator) },
            .@"break" => |err| .{ .@"break" = try err.toOwned(allocator) },
        };
    }
};

pub const ExporterLocation = records.ExporterLocation;
pub const Signature = records.Signature;
pub const HandoffGive = records.HandoffGive;
pub const HandoffReceive = records.HandoffReceive;
pub const Handoff = records.Handoff;

// ── Per-variant message views ────────────────────────────────────────────────

pub const Deliver = struct {
    target: Reference,
    args: Args,
    answer: ?model.AnswerId = null,
    resolve_me_desc: ?Reference = null,
};

pub const Resolve = struct {
    answer: model.AnswerId,
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
    answer: model.AnswerId,
};

pub const Index = struct {
    receiver: Reference,
    index: i64,
    answer: model.AnswerId,
};

pub const Untag = struct {
    receiver: Reference,
    tag: []const u8,
    answer: model.AnswerId,
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

pub const StartSession = records.StartSession;

// ── Body sum type ────────────────────────────────────────────────────────────

/// Borrowed codec-neutral body of a CapTP `model.Message`.
///
/// Produced by a codec's `decodeBody` (the wire path) or by `fromOwned` (the
/// owned-fallback path). Materialize with `toOwned`.
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
    untag: Untag,

    /// Project a borrowed body from an owned `model.Message`. Infallible; the
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
                .acceptable_location = PeerLocator.fromOwned(&ss.acceptable_location),
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
            .untag => |*untag| .{ .untag = .{
                .receiver = Reference.fromOwned(&untag.receiver),
                .tag = untag.tag,
                .answer = untag.answer,
            } },
        };
    }

    /// Materialize the owned `model.Message`. The only allocating path;
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
            .untag => |untag| blk: {
                const receiver = try untag.receiver.toOwned(allocator);
                errdefer model.freeReference(allocator, receiver);
                const tag = try allocator.dupe(u8, untag.tag);
                break :blk .{ .untag = .{ .receiver = receiver, .tag = tag, .answer = untag.answer } };
            },
        };
    }

    /// Discriminant tag, mirroring `model.Message`'s union tags.
    pub fn kind(self: Body) std.meta.Tag(Body) {
        return std.meta.activeTag(self);
    }
};

comptime {
    // The borrowed body mirrors `model.Message` arm-for-arm. The codecs' kind
    // dispatch (`syrup.shared.messageOp`) and `eventKindFromBody` both lean on
    // that one-to-one shape, so bind it at compile time.
    model.assertMirrorsMessageKinds(Body);
}

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
