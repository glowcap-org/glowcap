//! The lazy sequence behind a borrowed `Args`, `StructEntries`, or
//! `PositionList` (`view.zig`). One generic carries four backings: a slice of
//! owned elements on the owned-fallback path, a codec-supplied table that
//! reads elements straight out of the frame, a slab of projected views
//! (ADR-0222), and a run of little-endian words lent by the frame or caller
//! (ADR-0243). A reader walks any of them with one `len`, `at`, and
//! iterator contract, and never allocates a box per list.

const std = @import("std");
const builtin = @import("builtin");

const model = @import("mod.zig");
const view = @import("view.zig");

const ProjectError = view.ProjectError;
const Error = view.Error;

// ── Lazy sequences ───────────────────────────────────────────────────────────

/// Codec-private cursor borrowing wire memory, shared by every lazy sequence.
/// `bytes` is the codec's view of the list region. `w0`/`w1`/`w2` are
/// codec-interpreted scalars (e.g. a word offset, element stride, and element
/// count). One shared type, so a codec can build a cursor once and hand it to
/// `Args` or `PositionList` alike.
pub const SequenceCtx = struct {
    bytes: []const u8 = &.{},
    w0: u64 = 0,
    w1: u64 = 0,
    w2: u64 = 0,
};

/// The slice-or-vtable backing machinery behind `Args`, `StructEntries`,
/// and `PositionList`. One comptime generic, instantiated for each shape.
///
/// A sequence is backed one of four ways: by a plain `slice` of owned
/// elements (the fallback path), by `views` a decoder already parsed once
/// (ADR-0222), by a `run` of little-endian words lent by the frame or caller
/// (ADR-0243), or by a small codec-supplied table that reads them straight
/// off the wire. Either way you only ever see `len`, `at`, and `iterator`,
/// which backing it is stays hidden.
///
/// `OwnedElem` is the owned model element. `ViewElem` is its borrowed
/// projection. When the two are the same type (the POD `u64` positions), the
/// projection is the identity and materializing allocates nothing per element.
/// `Run` names the element a word of a run spells (`Elem`) and how a view
/// reads it (`view`), or null for a shape that has no run form.
pub fn LazySequence(comptime OwnedElem: type, comptime ViewElem: type, comptime Run: ?type) type {
    return struct {
        inner: Inner,

        const Self = @This();

        const Inner = union(enum) {
            slice: []const OwnedElem,
            views: []const ViewElem,
            /// Lent little-endian 64-bit words, one per element.
            run: []const u8,
            backed: Backed,
        };

        const word_bytes = @sizeOf(u64);
        /// What a word of a run reads as, or `void` for a shape with no run.
        pub const RunElem = if (Run) |R| R.Elem else void;
        /// What `nextRef` lends, the element type a walk over any sequence
        /// with this contract reads.
        pub const Elem = ViewElem;

        pub const Ctx = SequenceCtx;

        /// An iterator position belonging to this immutable sequence. Save it
        /// before `next` to revisit that member without scanning the prefix.
        /// Tokens must come from this sequence. They are not element indices.
        pub const Checkpoint = enum(u64) { _ };

        pub const VTable = struct {
            len: *const fn (Ctx) ProjectError!usize,
            at: *const fn (Ctx, usize) ProjectError!ViewElem,
            /// Forward cursor: write the element at the codec-interpreted
            /// `cursor` into `out`, advance `cursor` past it, and return true.
            /// Return false at the end, leaving `out` untouched. The backing
            /// writes where the walk reads, so a projected element is built
            /// once and copied nowhere. Prefer this single forward walk to a
            /// loop of `at(i)`, which on a byte-framed codec re-scans from the
            /// start each call (O(n^2)).
            next: *const fn (Ctx, *u64, *ViewElem) ProjectError!bool,
            /// The context of the sequence that starts `skip` elements in,
            /// so `from` on a codec-backed sequence costs the codec's cursor
            /// arithmetic (O(1) on a stride-addressed list, one scan of the
            /// skipped prefix on a byte-framed one) and never a copy. A
            /// `skip` past the end is `MalformedView`.
            tail: *const fn (Ctx, usize) ProjectError!Ctx,
        };

        const Backed = struct {
            ctx: Ctx,
            vtable: *const VTable,
        };

        /// Forward-only walk over the sequence. One linear pass, no
        /// per-element re-scan and no `len()` pre-walk, the shape the
        /// session's hot validate/install paths use.
        pub const Iterator = struct {
            inner: union(enum) {
                slice: struct { items: []const OwnedElem, index: usize },
                views: struct { items: []const ViewElem, index: usize },
                run: struct { words: []const u8, index: usize },
                backed: struct { backed: Backed, cursor: u64 },
            },
            /// Room for the element `nextRef` projects on a backing that does
            /// not hold views in memory.
            room: ViewElem = undefined,

            /// The next element, borrowed: on the `views` backing a pointer
            /// into the slab, on every other backing a pointer into the
            /// iterator's own room. It stays valid until the next call on
            /// this iterator, so a walk that reads each element where it
            /// stands copies nothing. `next` copies the element out for a
            /// reader that keeps it past the walk.
            pub inline fn nextRef(self: *Iterator) ProjectError!?*const ViewElem {
                switch (self.inner) {
                    .slice => |*s| {
                        if (s.index >= s.items.len) return null;
                        self.room = project(&s.items[s.index]);
                        s.index += 1;
                        return &self.room;
                    },
                    .views => |*v| {
                        if (v.index >= v.items.len) return null;
                        defer v.index += 1;
                        return &v.items[v.index];
                    },
                    .run => |*r| {
                        if (r.index >= runLen(r.words)) return null;
                        self.room = runElem(r.words, r.index);
                        r.index += 1;
                        return &self.room;
                    },
                    .backed => |*b| {
                        if (!try b.backed.vtable.next(b.backed.ctx, &b.cursor, &self.room)) return null;
                        return &self.room;
                    },
                }
            }

            pub fn checkpoint(self: *const Iterator) Checkpoint {
                return @fromBackingInt(@intCast(switch (self.inner) {
                    .slice => |s| s.index,
                    .views => |v| v.index,
                    .run => |r| r.index,
                    .backed => |b| b.cursor,
                }));
            }

            pub fn next(self: *Iterator) ProjectError!?ViewElem {
                switch (self.inner) {
                    .slice => |*s| {
                        if (s.index >= s.items.len) return null;
                        const out = project(&s.items[s.index]);
                        s.index += 1;
                        return out;
                    },
                    .views => |*v| {
                        if (v.index >= v.items.len) return null;
                        const out = v.items[v.index];
                        v.index += 1;
                        return out;
                    },
                    .run => |*r| {
                        if (r.index >= runLen(r.words)) return null;
                        const out = runElem(r.words, r.index);
                        r.index += 1;
                        return out;
                    },
                    .backed => |*b| {
                        var out: ViewElem = undefined;
                        if (!try b.backed.vtable.next(b.backed.ctx, &b.cursor, &out)) return null;
                        return out;
                    },
                }
            }
        };

        /// Borrow the view projection of one owned element (the identity for
        /// POD elements).
        fn project(elem: *const OwnedElem) ViewElem {
            return if (comptime OwnedElem == ViewElem) elem.* else ViewElem.fromOwned(elem);
        }

        fn runLen(words: []const u8) usize {
            return words.len / word_bytes;
        }

        /// Element `index` of a run: its little-endian word, read where it
        /// lies. `index` is below `runLen`.
        fn runElem(words: []const u8, index: usize) ViewElem {
            if (Run) |R| {
                return R.view(std.mem.readInt(R.Elem, words[index * word_bytes ..][0..word_bytes], .little));
            } else {
                // Only `fromRun` builds a run, and it refuses a shape without one.
                unreachable;
            }
        }

        /// Materialize one viewed element into its owned form at `depth`.
        fn materialize(allocator: std.mem.Allocator, elem: *const ViewElem, depth: usize) Error!OwnedElem {
            if (comptime OwnedElem == ViewElem) {
                return elem.*;
            } else {
                return elem.toOwnedDepth(allocator, depth);
            }
        }

        /// Release one owned element on the partial-failure unwind.
        fn freeOwned(allocator: std.mem.Allocator, elem: OwnedElem) void {
            if (comptime OwnedElem == model.Argument) {
                model.freeArgument(allocator, elem);
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

        /// Back the sequence with views a decoder parsed once. Each reader
        /// then walks the views, and the wire bytes are never read again.
        /// `views` must outlive the sequence, as the frame head it lives in
        /// does (`ValueSlab`).
        pub fn fromViews(views: []const ViewElem) Self {
            return .{ .inner = .{ .views = views } };
        }

        /// Back the sequence with a run of little-endian words lying in the
        /// frame, one element each (`words.len` is a multiple of eight). A
        /// reader walks the words in place, and a host that reads such words
        /// as they lie gets them as a typed slice (`typedRun`).
        pub fn fromRun(words: []const u8) Self {
            std.debug.assert(Run != null); // only a shape with a run form is backed by one
            std.debug.assert(words.len % word_bytes == 0);
            return .{ .inner = .{ .run = words } };
        }

        /// The words a codec backed the sequence with (`fromRun`), or null
        /// for any other backing. Every element of a run is the one leaf
        /// kind `Run` names, so a walker that only cares which kinds a
        /// sequence holds can stop here.
        pub fn wordRun(self: Self) ?[]const u8 {
            return switch (self.inner) {
                .run => |words| words,
                else => null,
            };
        }

        /// The run as typed elements read in place: non-null only when the
        /// host reads little-endian words as they lie (its byte order is
        /// little-endian and the run is word-aligned, which a word-shaped
        /// frame guarantees). Otherwise a reader walks the elements or copies
        /// them, as `driver.Args.integers` does.
        pub fn typedRun(self: Self) ?[]const RunElem {
            if (Run == null) return null;
            const words = self.wordRun() orelse return null;
            if (comptime builtin.cpu.arch.endian() != .little) return null;
            if (!std.mem.isAligned(@intFromPtr(words.ptr), @alignOf(RunElem))) return null;
            const aligned: []align(@alignOf(RunElem)) const u8 = @alignCast(words);
            return std.mem.bytesAsSlice(RunElem, aligned);
        }

        pub fn fromBacking(ctx: Ctx, vtable: *const VTable) Self {
            // Decoding a frame does not parse the list. The view keeps its
            // byte region and the codec's table of readers, and elements are
            // parsed when a consumer walks them. The codec also keeps the
            // element count from its first walk in the context, so `len` reads
            // it back and does not walk the bytes again.
            return .{ .inner = .{ .backed = .{ .ctx = ctx, .vtable = vtable } } };
        }

        /// The views a decoder parsed into a slab (`fromViews`), which live
        /// where the slab does and not in the wire bytes, or null for a
        /// sequence that walks something else.
        pub fn backingViews(self: Self) ?[]const ViewElem {
            return switch (self.inner) {
                .views => |views| views,
                else => null,
            };
        }

        pub fn len(self: Self) ProjectError!usize {
            return switch (self.inner) {
                .slice => |s| s.len,
                .views => |v| v.len,
                .run => |words| runLen(words),
                .backed => |b| b.vtable.len(b.ctx),
            };
        }

        /// Whether the sequence carries no elements. The borrowed twin of the
        /// owned record's `isEmpty`, so a dual-shape walker can ask either.
        pub fn isEmpty(self: Self) ProjectError!bool {
            return (try self.len()) == 0;
        }

        pub fn at(self: Self, index: usize) ProjectError!ViewElem {
            return switch (self.inner) {
                .slice => |s| if (index < s.len) project(&s[index]) else error.MalformedView,
                .views => |v| if (index < v.len) v[index] else error.MalformedView,
                .run => |words| if (index < runLen(words)) runElem(words, index) else error.MalformedView,
                .backed => |b| b.vtable.at(b.ctx, index),
            };
        }

        /// Project one member saved by this sequence's iterator. End positions
        /// are refused. Replaying a codec-backed member costs its projection,
        /// which can scan a nested value, but never the preceding members.
        pub fn atCheckpoint(self: Self, checkpoint: Checkpoint) ProjectError!ViewElem {
            const position = @backingInt(checkpoint);
            const index = std.math.cast(usize, position) orelse return error.MalformedView;
            return switch (self.inner) {
                .slice => |s| if (index < s.len) project(&s[index]) else error.MalformedView,
                .views => |v| if (index < v.len) v[index] else error.MalformedView,
                .run => |words| if (index < runLen(words)) runElem(words, index) else error.MalformedView,
                .backed => |b| blk: {
                    var cursor = position;
                    var out: ViewElem = undefined;
                    if (!try b.vtable.next(b.ctx, &cursor, &out)) return error.MalformedView;
                    break :blk out;
                },
            };
        }

        /// The sequence from element `start` on. The Vat peels a deliver's
        /// leading verb this way, so a handler's arguments are a sequence
        /// of their own and the one behind it is never read twice. A slice
        /// or view backing reslices, and a codec backing asks the codec.
        /// The owned slice this sequence lends, when an owner built it from
        /// one (`fromOwnedSlice`), so a caller that needs owned elements for
        /// the same bounded call reads them in place instead of copying.
        pub fn ownedSlice(self: Self) ?[]const OwnedElem {
            return switch (self.inner) {
                .slice => |s| s,
                .views, .run, .backed => null,
            };
        }

        pub fn from(self: Self, start: usize) ProjectError!Self {
            return switch (self.inner) {
                .slice => |s| if (start <= s.len) fromOwnedSlice(s[start..]) else error.MalformedView,
                .views => |v| if (start <= v.len) fromViews(v[start..]) else error.MalformedView,
                .run => |words| if (start <= runLen(words)) fromRun(words[start * word_bytes ..]) else error.MalformedView,
                .backed => |b| .{ .inner = .{ .backed = .{ .ctx = try b.vtable.tail(b.ctx, start), .vtable = b.vtable } } },
            };
        }

        pub fn iterator(self: Self) Iterator {
            return switch (self.inner) {
                .slice => |s| .{ .inner = .{ .slice = .{ .items = s, .index = 0 } } },
                .views => |v| .{ .inner = .{ .views = .{ .items = v, .index = 0 } } },
                .run => |words| .{ .inner = .{ .run = .{ .words = words, .index = 0 } } },
                .backed => |b| .{ .inner = .{ .backed = .{ .backed = b, .cursor = 0 } } },
            };
        }

        pub fn toOwnedSlice(self: Self, allocator: std.mem.Allocator) Error![]OwnedElem {
            return self.toOwnedSliceDepth(allocator, 0);
        }

        pub fn toOwnedSliceDepth(self: Self, allocator: std.mem.Allocator, depth: usize) Error![]OwnedElem {
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
            while (try it.nextRef()) |elem| {
                if (initialized >= count) return error.MalformedView;
                out[initialized] = try materialize(allocator, elem, depth);
                initialized += 1;
            }
            if (initialized != count) return error.MalformedView;
            return out;
        }
    };
}

/// An owned slice walked with the contract a lazy sequence offers: `len` and
/// a forward iterator whose `nextRef` lends each element in place. A writer
/// that takes any such sequence serves an owned tree and a borrowed one from
/// one source, and the owned walk pays no projection.
pub fn OwnedSlice(comptime Element: type) type {
    return struct {
        items: []const Element,

        const Self = @This();

        pub const Elem = Element;
        pub const Checkpoint = enum(usize) { _ };

        pub const Iterator = struct {
            items: []const Element,
            index: usize = 0,

            pub fn checkpoint(self: *const Iterator) Checkpoint {
                return @fromBackingInt(self.index);
            }

            pub inline fn nextRef(self: *Iterator) error{}!?*const Element {
                if (self.index >= self.items.len) return null;
                defer self.index += 1;
                return &self.items[self.index];
            }
        };

        pub fn len(self: Self) error{}!usize {
            return self.items.len;
        }

        pub fn atCheckpoint(self: Self, position: Checkpoint) ProjectError!Element {
            const index = @backingInt(position);
            if (index >= self.items.len) return error.MalformedView;
            return self.items[index];
        }

        pub fn iterator(self: Self) Iterator {
            return .{ .items = self.items };
        }
    };
}

/// The sequence form of either source: a slice becomes an `OwnedSlice`, and a
/// lazy sequence is returned as it is.
pub fn Sequence(comptime Items: type) type {
    return switch (@typeInfo(Items)) {
        .pointer => |pointer| OwnedSlice(pointer.child),
        else => Items,
    };
}

pub fn sequenceOf(items: anytype) Sequence(@TypeOf(items)) {
    return if (comptime @typeInfo(@TypeOf(items)) == .pointer) .{ .items = items } else items;
}
