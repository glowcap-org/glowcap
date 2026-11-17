//! Reading a message without copying it, straight off the wire bytes.
//!
//! On every receive, a codec lays a borrowed `Body` over the decoded frame
//! instead of building the whole owned `model.Message` tree. This view is the one
//! shape both codecs produce, and it's the only message shape the engine looks
//! at. The engine never touches a codec's private view types. You build the
//! owned tree (`Body.toOwned`) only when you need a message to outlive
//! its frame.
//!
//! ## Lifetimes, and how the lists work
//!
//! Scalar fields and slices point right into the frame's bytes. (On the
//! owned-fallback path they point into an owned `model.Message` instead.) The
//! open-ended `Args`, `StructEntries`, and `PositionList` sequences need a
//! little more machinery, and all three get it from one `LazySequence` generic
//! (`view_sequence.zig`). Each carries a small piece of borrowed state plus a
//! tiny table of `len` and `at` functions the codec hands it. That's what lets
//! the view walk a list lazily without allocating a box per list, and it's also
//! why the view never imports `codec`: the codec owns the parsing and the view
//! dispatches into it. On the owned-fallback path the backing is a slice. A
//! list of integers or positions that lies on the wire as a run of
//! little-endian words is read in place (`fromRun`), one word per element.
//!
//! Nested containers (`Argument.list`, `.set`, `.tagged`) are themselves `Args`,
//! so the whole tree stays borrowed and allocation-free right up until you call
//! `toOwned`.
//!
//! A signed handoff envelope or a sturdyref is wide once parsed and rare on the
//! wire, so `Argument.handoff` and `Reference.sturdy` are `Lazy` records: the
//! codec hands the view the record's bytes, and `project` parses them when a
//! consumer reads the record.

const std = @import("std");
const model = @import("mod.zig");
const records = @import("view_records.zig");
const sequence = @import("view_sequence.zig");
const body_types = @import("view_body.zig").Types(
    Reference,
    Resolution,
    Args,
    PositionList,
    PeerLocator,
    records.StartSession,
    Error,
);

/// What you get when reading a borrowed element out of wire bytes goes wrong:
/// a codec-backed list met malformed wire bytes, or `at` was asked for an index
/// past the end of either backing. The codec's finer-grained errors all collapse
/// to `MalformedView` here. The codec still fails loudly, and the engine turns
/// that into a typed `op:abort`.
pub const ProjectError = error{MalformedView};

/// Materialization failure: a projection failure (`ProjectError`) or an
/// allocation failure while building the owned tree.
pub const Error = ProjectError || std.mem.Allocator.Error;

const Author = sequence.Author;
const TreeError = sequence.TreeError;
const TreeResult = sequence.TreeResult;

/// A word of an integer run is one `integer` argument.
const IntegerRun = struct {
    pub const Elem = i64;
    pub fn view(elem: i64) Argument {
        return .{ .integer = elem };
    }
};

/// A word of a position run is the position itself.
const PositionRun = struct {
    pub const Elem = u64;
    pub fn view(elem: u64) u64 {
        return elem;
    }
};

/// A borrowed sequence of `Argument` values.
pub const Args = sequence.LazySequence(model.Argument, Argument, IntegerRun);

pub const ValueSlab = @import("view_slab.zig").ValueSlab;

/// One byte leaf of a materialized tree: a duplicate when `copied`, the
/// view's own slice when `lent`.
fn leaf(allocator: std.mem.Allocator, bytes: []const u8, comptime leaves: Leaves) std.mem.Allocator.Error![]const u8 {
    return switch (leaves) {
        .copied => try allocator.dupe(u8, bytes),
        .lent => bytes,
    };
}

/// A borrowed sequence of `StructEntry` pairs, the lazy backing of an OCapN
/// `Argument.@"struct"`. One cursor walks (key, value) pairs off the wire, the
/// same shape `Args` walks single values, so a struct projects with no per-entry
/// allocation until `Argument.toOwned`.
pub const StructEntries = sequence.LazySequence(model.StructEntry, StructEntry, null);

/// Borrowed mirror of `model.StructEntry`: a String key and a borrowed value.
pub const StructEntry = struct {
    key: []const u8,
    value: Argument,

    pub fn fromOwned(owned: *const model.StructEntry) StructEntry {
        return .{ .key = owned.key, .value = Argument.fromOwned(&owned.value) };
    }

    /// The entry's owned form at `depth`, its key and its value's byte leaves
    /// treated as `leaves` says.
    pub fn toTreeDepth(self: *const StructEntry, allocator: std.mem.Allocator, depth: usize, comptime leaves: Leaves, comptime author: Author) TreeResult(author)!model.StructEntry {
        const key = try leaf(allocator, self.key, leaves);
        errdefer if (leaves == .copied) allocator.free(key);
        return .{ .key = key, .value = try self.value.toTreeDepth(allocator, depth, leaves, author) };
    }
};

/// Borrowed sequence of positive integers (export-pos, answer-pos, or
/// wire-delta values).
pub const PositionList = sequence.LazySequence(u64, u64, PositionRun);

/// A borrowed record that is parsed only when it is read.
///
/// A view arm costs what the hot path reads. The signed handoff envelope and
/// the sturdyref are each a few hundred borrowed bytes wide once parsed, and
/// a deliver carries one in a gift exchange, never in an ordinary call. Kept
/// inline they would set the size of every `Argument`, and with it the cost of
/// every argument copy, list walk, and zeroed optional on the receive path. So
/// the codec hands the view the record's byte region and a projector, the way
/// it hands `Args` a list region, and the consumer that reads the record pays
/// for the parse. On the owned-fallback path the backing is the owned record
/// and the projection is its borrowed mirror.
pub fn Lazy(comptime Owned: type, comptime View: type) type {
    return struct {
        inner: union(enum) {
            owned: *const Owned,
            backed: Backed,
        },

        const Self = @This();

        pub const Ctx = sequence.SequenceCtx;

        /// Parse the record out of `Ctx`. A codec reports a malformed record
        /// as `MalformedView`, the verdict a malformed list element gets.
        pub const Project = *const fn (Ctx) ProjectError!View;

        const Backed = struct {
            ctx: Ctx,
            project: Project,
        };

        pub fn fromOwned(owned: *const Owned) Self {
            return .{ .inner = .{ .owned = owned } };
        }

        pub fn fromBacking(ctx: Ctx, projector: Project) Self {
            // Decoding a frame does not parse this record. The view keeps only
            // the record's byte region and the function that can parse it. The
            // parse runs when a consumer calls `project`, so a message whose
            // record nobody reads never pays for it. This is correct because
            // the frame's bytes outlive the view and do not change meanwhile.
            return .{ .inner = .{ .backed = .{ .ctx = ctx, .project = projector } } };
        }

        pub fn project(self: Self) ProjectError!View {
            return switch (self.inner) {
                .owned => |owned| View.fromOwned(owned),
                .backed => |backed| backed.project(backed.ctx),
            };
        }
    };
}

pub const LazySturdyRef = Lazy(model.SturdyRef, SturdyRef);
pub const LazyHandoff = Lazy(model.Handoff, Handoff);

/// The borrowed sturdyref behind either source an argument writer reads: an
/// owned (boxed) record projects, and a lazy one parses.
pub fn borrowSturdy(source: anytype) ProjectError!SturdyRef {
    if (comptime @typeInfo(@TypeOf(source)) == .pointer) return SturdyRef.fromOwned(source);
    return source.project();
}

/// The borrowed handoff behind either source, as `borrowSturdy`.
pub fn borrowHandoff(source: anytype) ProjectError!Handoff {
    if (comptime @typeInfo(@TypeOf(source)) == .pointer) return Handoff.fromOwned(source);
    return source.project();
}

pub const Leaves = sequence.Leaves;
pub const OwnedSlice = sequence.OwnedSlice;
pub const sequenceOf = sequence.sequenceOf;

/// The widest an `Argument` may be. Every argument the receive path copies,
/// zeroes, or returns by value pays this size, so a new arm that would widen
/// it is a lazy record (`Lazy`) or a boxed one, never an inline struct.
pub const argument_view_budget_bytes = 80;

comptime {
    if (@sizeOf(Argument) > argument_view_budget_bytes) @compileError(std.fmt.comptimePrint(
        "model.view.Argument is {d} bytes, over its {d}-byte budget: project the new arm lazily",
        .{ @sizeOf(Argument), argument_view_budget_bytes },
    ));
}

// ── Value views ──────────────────────────────────────────────────────────────

pub const BreakReason = records.BreakReason;
pub const PeerLocator = records.PeerLocator;
pub const HintList = records.HintList;
pub const BorrowedHints = records.BorrowedHints;

/// Borrowed mirror of `model.SturdyRef`.
pub const SturdyRef = struct {
    peer: PeerLocator,
    swissnum: []const u8,

    pub fn fromOwned(owned: *const model.SturdyRef) SturdyRef {
        return .{ .peer = PeerLocator.fromOwned(&owned.peer), .swissnum = owned.swissnum };
    }
};

/// Borrowed mirror of `model.PromiseRef`.
pub const PromiseRef = struct {
    answer_position: model.AnswerPosition,
};

/// Borrowed mirror of `model.Reference`. `near` / `far` carry POD ids by
/// value. `broken` borrows wire bytes, and `sturdy` is projected when read.
pub const Reference = union(enum) {
    near: model.NearRef,
    far: model.FarRef,
    /// Borrowed projection of a node-local route. Codecs never decode this arm.
    /// It exists so copying an application-owned value before Node lowering
    /// preserves the explicit namespace without inventing a wire position.
    routed: model.RoutedRef,
    promise: PromiseRef,
    sturdy: LazySturdyRef,
    broken: BreakReason,

    /// The raw wire position this reference names: a near export's
    /// `export_position` or a far import's `import_position`, collapsed to the
    /// one `u64` integer space they share on the wire. Null for a reference that
    /// names no wire position (routed / promise / sturdy / broken). Prefer `exportPosition`
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
    /// partner-named import position. A resolver-export lookup must use this, never
    /// `position`: keying an export-indexed map on a `.far` import position (the same
    /// integer space) would let a coincidental collision misclassify an ordinary
    /// deliver as a resolver callback.
    pub fn exportPosition(self: Reference) ?model.ExportPosition {
        return switch (self) {
            .near => |near| near.export_position,
            else => null,
        };
    }

    pub fn fromOwned(owned: *const model.Reference) Reference {
        return switch (owned.*) {
            .near => |near| .{ .near = near },
            .far => |far| .{ .far = far },
            .routed => |routed| .{ .routed = routed },
            .promise => |promise| .{ .promise = .{ .answer_position = promise.answer_position } },
            .sturdy => |sturdy| .{ .sturdy = .fromOwned(sturdy) },
            .broken => |broken| .{ .broken = .{ .message = broken.message } },
        };
    }

    pub fn toOwned(self: Reference, allocator: std.mem.Allocator) Error!model.Reference {
        return switch (self) {
            .near => |near| .{ .near = near },
            .far => |far| .{ .far = far },
            .routed => |routed| .{ .routed = routed },
            .promise => |promise| .{ .promise = .{ .answer_position = promise.answer_position } },
            .sturdy => |lazy| blk: {
                const sturdy = try lazy.project();
                const peer = try sturdy.peer.toOwned(allocator);
                errdefer model.freePeerLocator(allocator, peer);
                const swissnum = try allocator.dupe(u8, sturdy.swissnum);
                errdefer allocator.free(swissnum);
                const box = try allocator.create(model.SturdyRef);
                box.* = .{ .peer = peer, .swissnum = swissnum };
                break :blk .{ .sturdy = box };
            },
            .broken => |broken| .{ .broken = .{ .message = try allocator.dupe(u8, broken.message) } },
        };
    }
};

/// The depth of the items of a container at `depth`, or the refusal `author`
/// names when the ceiling forbids them (`Author`).
inline fn itemsDepth(comptime author: Author, depth: usize) TreeResult(author)!usize {
    if (!model.mayHoldItems(depth)) return switch (author) {
        .partner => error.MalformedView,
        .local => error.ValueTooDeep,
    };
    return depth + 1;
}

/// Borrowed mirror of `model.Argument`, carrying every arm.
/// Nested containers are lazy `Args`, so the tree stays borrowed with no
/// per-node allocation until `Argument.toOwned`.
pub const Argument = union(enum) {
    bytes: []const u8,
    symbol: []const u8,
    reference: Reference,
    @"error": BreakReason,
    handoff: LazyHandoff,
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
            .handoff => |handoff| .{ .handoff = .fromOwned(handoff) },
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

    pub fn toOwned(self: *const Argument, allocator: std.mem.Allocator) Error!model.Argument {
        return self.toTreeDepth(allocator, 0, .copied, .partner);
    }

    /// Whether this tree names an answer position, the borrowed twin of
    /// `argumentSliceNamesAnswer`. The receive validator bounded the depth.
    pub fn namesAnswer(self: Argument) ProjectError!bool {
        switch (self) {
            .reference => |reference| return reference == .promise,
            .list, .set => |items| return argsNameAnswer(items),
            .tagged => |tagged| return argsNameAnswer(tagged.value),
            .@"struct" => |entries| {
                var it = entries.iterator();
                while (try it.next()) |entry| if (try entry.value.namesAnswer()) return true;
                return false;
            },
            else => return false,
        }
    }

    /// The tree this view reads, built by the one materializing walk. Its
    /// spines come from `allocator`, and `leaves` says whether its byte leaves
    /// are duplicates or the view's own slices (`Leaves`). A reference or a
    /// handoff takes its owned conversion in both modes, bytes included, so a
    /// lent tree's allocator is an arena that reclaims them with the spines.
    pub fn toTreeDepth(self: *const Argument, allocator: std.mem.Allocator, depth: usize, comptime leaves: Leaves, comptime author: Author) TreeResult(author)!model.Argument {
        return switch (self.*) {
            .bytes => |bytes| .{ .bytes = try leaf(allocator, bytes, leaves) },
            .symbol => |symbol| .{ .symbol = try leaf(allocator, symbol, leaves) },
            .reference => |reference| .{ .reference = try reference.toOwned(allocator) },
            .@"error" => |err| .{ .@"error" = .{ .message = try leaf(allocator, err.message, leaves) } },
            .handoff => |handoff| blk: {
                const boxed = try allocator.create(model.Handoff);
                errdefer allocator.destroy(boxed);
                boxed.* = try (try handoff.project()).toOwned(allocator);
                break :blk .{ .handoff = boxed };
            },
            .string => |string| .{ .string = try leaf(allocator, string, leaves) },
            .integer => |integer| .{ .integer = integer },
            .boolean => |boolean| .{ .boolean = boolean },
            .list => |items| .{ .list = try items.toSliceDepth(allocator, try itemsDepth(author, depth), leaves, author) },
            .void => .{ .void = {} },
            .float64 => |float64| .{ .float64 = float64 },
            .set => |items| .{ .set = try items.toSliceDepth(allocator, try itemsDepth(author, depth), leaves, author) },
            .tagged => |tagged| blk: {
                const tag = try leaf(allocator, tagged.tag, leaves);
                errdefer if (leaves == .copied) allocator.free(tag);
                const value = try tagged.value.toSliceDepth(allocator, try itemsDepth(author, depth), leaves, author);
                break :blk .{ .tagged = .{ .tag = tag, .value = value } };
            },
            .keyword => |keyword| .{ .keyword = try leaf(allocator, keyword, leaves) },
            .@"struct" => |entries| .{ .@"struct" = try entries.toSliceDepth(allocator, try itemsDepth(author, depth), leaves, author) },
            .big_integer => |big| .{ .big_integer = .{
                .negative = big.negative,
                .digits = try leaf(allocator, big.digits, leaves),
            } },
        };
    }
};

fn argsNameAnswer(items: Args) ProjectError!bool {
    var it = items.iterator();
    while (try it.next()) |item| if (try item.namesAnswer()) return true;
    return false;
}

/// Borrowed mirror of `model.Resolution`.
pub const Resolution = union(enum) {
    fulfill: Argument,
    @"break": BreakReason,

    /// Whether a fulfillment names an answer position anywhere in its tree.
    pub fn namesAnswer(self: Resolution) ProjectError!bool {
        return switch (self) {
            .fulfill => |arg| arg.namesAnswer(),
            .@"break" => false,
        };
    }

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

pub const Signature = records.Signature;
pub const HandoffGive = records.HandoffGive;
pub const HandoffReceive = records.HandoffReceive;
pub const Handoff = records.Handoff;

// ── Per-variant message views ────────────────────────────────────────────────

pub const Deliver = body_types.Deliver;
pub const Resolve = body_types.Resolve;
pub const Listen = body_types.Listen;
pub const Get = body_types.Get;
pub const Index = body_types.Index;
pub const Untag = body_types.Untag;
pub const GcExport = body_types.GcExport;
pub const GcAnswer = body_types.GcAnswer;
pub const Abort = body_types.Abort;
pub const StartSession = body_types.StartSession;
pub const Body = body_types.Body;
