//! The room a frame's owner lends the decoder for argument views, so a
//! message's argument tree is parsed once and every later reader walks views
//! instead of wire bytes (ADR-0222, ADR-0231).

const std = @import("std");
const Argument = @import("view.zig").Argument;
const StructEntry = @import("view.zig").StructEntry;

/// Room a frame's owner lends the decoder for the views of one message's
/// argument tree, including lists, sets, tagged values, and struct entries. The
/// decoder fills this room, and validation and the application then walk views
/// instead of bytes (ADR-0222, ADR-0231). The engine lends the room in the
/// frame's head, so the views live and die with the bytes they borrow.
///
/// The room has two ends. A codec that knows a sequence's length before it
/// reads the elements claims contiguous room from the bottom (`claim`). A
/// codec that learns the length only at the closing delimiter pushes each
/// element onto a stack at the top (`reserve`) before reading its children. It
/// settles the closed sequence at the bottom (`settle`), so an open
/// sequence never collides with the sequences nested inside it. A sequence
/// the room cannot hold drops its stack and cached children, then stays
/// wire-backed without allocating more memory. `empty` lends nothing, so every
/// sequence stays wire-backed.
pub const ValueSlab = struct {
    comptime {
        std.debug.assert(@sizeOf(i64) % @alignOf(Argument) == 0);
    }

    bytes: []align(@alignOf(Argument)) u8,
    /// Settled values, counted in bytes.
    used: usize = 0,
    /// The stack floor, filled from the top. The room left is `open - used`.
    open: usize,

    pub const empty: ValueSlab = .{ .bytes = &.{}, .open = 0 };

    pub fn init(bytes: []align(@alignOf(Argument)) u8) ValueSlab {
        const usable = bytes.len - bytes.len % @alignOf(Argument);
        return .{ .bytes = bytes[0..usable], .open = usable };
    }

    fn checkElement(comptime T: type) void {
        if (T != Argument and T != StructEntry) @compileError("slab stores only value views");
        comptime std.debug.assert(@alignOf(T) == @alignOf(Argument));
        comptime std.debug.assert(@sizeOf(T) % @alignOf(Argument) == 0);
    }

    fn region(self: *ValueSlab, comptime T: type, offset: usize, count: usize) []T {
        comptime checkElement(T);
        std.debug.assert(offset <= self.bytes.len);
        std.debug.assert(count <= (self.bytes.len - offset) / @sizeOf(T));
        return @as([*]T, @ptrCast(@alignCast(self.bytes[offset..].ptr)))[0..count];
    }

    pub fn room(self: *const ValueSlab, comptime T: type) usize {
        comptime checkElement(T);
        return (self.open - self.used) / @sizeOf(T);
    }

    /// Contiguous room for values the caller fills in order.
    pub fn claim(self: *ValueSlab, comptime T: type, count: usize) ?[]T {
        if (count > self.room(T)) return null;
        const claimed = self.region(T, self.used, count);
        self.used += count * @sizeOf(T);
        return claimed;
    }

    /// Reserve the parent's slot before decoding a child into the same head.
    /// The caller fills it before settling this collection.
    pub fn reserve(self: *ValueSlab, comptime T: type) ?*T {
        if (self.room(T) == 0) return null;
        self.open -= @sizeOf(T);
        return &self.region(T, self.open, 1)[0];
    }

    /// Pop this collection's pushed values without keeping them.
    pub fn drop(self: *ValueSlab, comptime T: type, count: usize) void {
        comptime checkElement(T);
        self.open += count * @sizeOf(T);
    }

    /// Lend unused head storage for a decoder's integer-run attempt. Until
    /// `finish`, only unused bytes change: refusal leaves both ends intact.
    /// Bounds exclude both settled children and the open parent stack. The
    /// returned words die with the frame. Without this room, a numeric batch
    /// needs per-element views and the Host copies it into its turn arena.
    pub fn beginIntegers(self: *ValueSlab) IntegerWriter {
        return .{ .slab = self, .bytes = self.bytes[self.used..self.open] };
    }

    pub const IntegerWriter = struct {
        slab: *ValueSlab,
        bytes: []u8,
        count: usize = 0,

        pub fn append(self: *IntegerWriter, value: i64) bool {
            if (self.count == self.bytes.len / @sizeOf(i64)) return false;
            std.mem.writeInt(i64, self.bytes[self.count * 8 ..][0..8], value, .little);
            self.count += 1;
            return true;
        }

        /// A nonempty run commits only the bytes its words occupy. The
        /// caller must not use the slab between
        /// beginning this writer and finishing or discarding it.
        pub fn finish(self: *IntegerWriter) ?[]const u8 {
            if (self.count == 0) return null;
            self.slab.used += self.count * @sizeOf(i64);
            return self.bytes[0 .. self.count * @sizeOf(i64)];
        }
    };

    /// Move the last `count` pushed views into a contiguous claim, in the
    /// order they were pushed.
    pub fn settle(self: *ValueSlab, comptime T: type, count: usize) []const T {
        const stacked = self.region(T, self.open, count);
        const claimed = self.region(T, self.used, count);
        if (count * @sizeOf(T) <= self.open - self.used) {
            for (claimed, 0..) |*slot, i| slot.* = stacked[count - 1 - i];
        } else {
            // Mixed-size children can leave the destination partway through
            // a stack element. Reverse first, then move whole values forward.
            reverse(T, stacked);
            std.mem.copyForwards(T, claimed, stacked);
        }
        self.used += count * @sizeOf(T);
        self.open += count * @sizeOf(T);
        return claimed;
    }
};

fn reverse(comptime T: type, run: []T) void {
    var lo: usize = 0;
    var hi = run.len;
    while (lo + 1 < hi) : (lo += 1) {
        hi -= 1;
        const tmp = run[lo];
        run[lo] = run[hi];
        run[hi] = tmp;
    }
}
