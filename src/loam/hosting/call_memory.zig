//! Retained input and restartable scratch share one physical call allowance.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Positive allocation demand, including worst-case placement padding. Owners
/// compose their demand before deriving a physical block allowance.
pub const AllocationBound = struct {
    bytes: usize = 0,
    allocations: usize = 0,

    pub fn include(self: *AllocationBound, length: usize, alignment: usize, count: usize) !void {
        if (length == 0 or count == 0) return;
        try self.includeTotal(try std.math.mul(usize, length, count), alignment, count);
    }

    /// An aggregate byte allowance split among at most count positive requests.
    /// Payload/page owners know the sum without requiring every slice to fill it.
    pub fn includeTotal(self: *AllocationBound, length: usize, alignment: usize, count: usize) !void {
        if (length == 0 or count == 0) return;
        std.debug.assert(std.math.isPowerOfTwo(alignment));
        const requests = @min(length, count);
        const padded = try std.math.add(usize, length, try std.math.mul(usize, alignment - 1, requests));
        const bytes = try std.math.add(usize, self.bytes, padded);
        const allocations = try std.math.add(usize, self.allocations, requests);
        self.* = .{ .bytes = bytes, .allocations = allocations };
    }

    pub fn merge(self: *AllocationBound, other: AllocationBound) !void {
        const bytes = try std.math.add(usize, self.bytes, other.bytes);
        const allocations = try std.math.add(usize, self.allocations, other.allocations);
        self.* = .{ .bytes = bytes, .allocations = allocations };
    }

    /// Fresh append-only inventories retain each intermediate spine when
    /// in-place growth is unavailable. The standard library owns growth policy.
    pub fn includeArrayGrowth(self: *AllocationBound, comptime Item: type, count: usize) !void {
        var growth: AllocationBound = .{};
        var capacity: usize = 0;
        while (capacity < count) {
            capacity = std.ArrayList(Item).growCapacity(try std.math.add(usize, capacity, 1));
            try growth.include(try std.math.mul(usize, capacity, @sizeOf(Item)), @alignOf(Item), 1);
        }
        try self.merge(growth);
    }

    /// A failed tail fit implies old block length < header + used + demand.
    /// Doubling therefore bounds each new block by twice that sum. Summed used
    /// bytes and new demands are each bounded by bytes; headers by allocations.
    /// Clamping, freeing and shrinking only reduce this conservative bound.
    pub fn physicalBytes(self: AllocationBound) !usize {
        const payload = try std.math.mul(usize, self.bytes, 4);
        const headers = try std.math.mul(usize, self.allocations, 2 * @sizeOf(Arena.Block));
        return std.math.add(usize, payload, headers);
    }
};

pub const Memory = struct {
    backing: Backing,
    input: Arena,
    working: Arena,

    /// Initialize at the operation's final address. Input must outlive inbound
    /// frames and every preparation restart; working storage ends only after
    /// borrowed callbacks, reads and preparation retire. The arenas acquire
    /// incremental fixed blocks, charged with headers, alignment and growth slack.
    /// This replaces the eager ceiling-sized buffer without another payload copy.
    /// The existing whole-call reservation still owns admission and fairness.
    pub fn init(self: *Memory, allocator: Allocator, limit: usize) void {
        self.backing = .{ .child = allocator, .limit = limit };
        self.input = .{ .backing = &self.backing };
        self.working = .{ .backing = &self.backing };
    }

    pub fn resetWorking(self: *Memory) void {
        self.working.deinit();
    }

    /// Synchronous temporary allocations share the same physical allowance,
    /// but retire independently of retained inputs and working borrows. Keep
    /// the returned scope at a stable local address until its deinit.
    pub fn scratch(self: *Memory) Arena {
        return .{ .backing = &self.backing };
    }

    pub fn deinit(self: *Memory) void {
        self.working.deinit();
        self.input.deinit();
        std.debug.assert(self.backing.used == 0);
    }
};

/// Fixed blocks preserve every borrow until reset. The standard fixed-buffer
/// allocator owns placement and in-place resizing inside each block. Growth
/// prefers doubling, capped by the remaining physical allowance: a standard
/// arena's unconstrained spare-capacity request can otherwise refuse a working
/// set that fits. Allocation examines only the latest block; reset walks the
/// chain. Existing blocks never move.
pub const Arena = struct {
    backing: *Backing,
    head: ?*Block = null,
    const Block = struct {
        next: ?*Block,
        length: usize,
        fixed: std.heap.FixedBufferAllocator,
    };

    pub fn allocator(self: *Arena) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    pub fn deinit(self: *Arena) void {
        while (self.head) |block| {
            const bytes = @as([*]u8, @ptrCast(block))[0..block.length];
            self.head = block.next;
            self.backing.release(bytes, .of(Block), @returnAddress());
        }
    }

    pub fn queryCapacity(self: *const Arena) usize {
        var capacity: usize = 0;
        var next = self.head;
        while (next) |block| : (next = block.next) capacity += block.fixed.buffer.len;
        return capacity;
    }

    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Arena = @ptrCast(@alignCast(context));
        const payload = std.math.add(usize, len, alignment.toByteUnits() - 1) catch return null;
        const minimum = std.math.add(usize, @sizeOf(Block), payload) catch return null;
        if (self.head) |block| {
            if (len <= block.fixed.buffer.len - block.fixed.end_index) {
                if (block.fixed.allocator().rawAlloc(len, alignment, ret_addr)) |ptr| return ptr;
            }
        }
        const available = self.backing.limit - self.backing.used;
        if (minimum > available) return null;
        const preferred = if (self.head) |block| block.length *| 2 else minimum;
        const length = @min(available, @max(minimum, preferred));
        const bytes = self.backing.acquire(length, .of(Block), ret_addr) orelse return null;
        const block: *Block = @ptrCast(@alignCast(bytes));
        block.* = .{ .next = self.head, .length = length, .fixed = .init(bytes[@sizeOf(Block)..length]) };
        // The checked minimum leaves enough room for the requested alignment.
        const result = block.fixed.allocator().rawAlloc(len, alignment, ret_addr) orelse {
            self.backing.release(bytes[0..length], .of(Block), ret_addr);
            return null;
        };
        self.head = block;
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Arena = @ptrCast(@alignCast(context));
        if (self.head) |block| if (block.fixed.ownsSlice(memory)) {
            // Check growth before delegating to the fixed-buffer arithmetic.
            if (new_len > memory.len and new_len - memory.len > block.fixed.buffer.len - block.fixed.end_index) return false;
            return block.fixed.allocator().rawResize(memory, alignment, new_len, ret_addr);
        };
        return new_len <= memory.len;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return if (resize(context, memory, alignment, new_len, ret_addr)) memory.ptr else null;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *Arena = @ptrCast(@alignCast(context));
        if (self.head) |block| if (block.fixed.ownsSlice(memory)) block.fixed.allocator().rawFree(memory, alignment, ret_addr);
    }
};

/// One Host-thread owner charges both arenas' complete backing blocks.
pub const Backing = struct {
    child: Allocator,
    limit: usize,
    used: usize = 0,

    fn acquire(self: *Backing, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        std.debug.assert(self.used <= self.limit);
        if (len > self.limit - self.used) return null;
        const result = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.used += len;
        return result;
    }

    fn release(self: *Backing, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        std.debug.assert(memory.len <= self.used);
        self.child.rawFree(memory, alignment, ret_addr);
        self.used -= memory.len;
    }
};
