//! Typed, bounded retention for failures that have no remaining return
//! recipient (ADR-0115).
//!
//! This module owns no global state. A Journal lives behind an explicit
//! Context, Host, or driver owner shared by the producers that report into it.

const std = @import("std");

const SpinLock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinLock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinLock) void {
        self.inner.unlock();
    }
};

pub const Layer = enum(u32) {
    core = 0,
    driver = 1,
    transport = 2,
    binding = 3,
    application_observer = 4,
};

pub const ScopeKind = enum(u32) {
    process = 0,
    context = 1,
    host = 2,
    session = 3,
    listener = 4,
    transport = 5,
    operation = 6,
};

pub const truncated_operation: u32 = 1 << 0;
pub const truncated_primary_name: u32 = 1 << 1;
pub const truncated_primary_message: u32 = 1 << 2;
pub const truncated_secondary_name: u32 = 1 << 3;
pub const truncated_secondary_message: u32 = 1 << 4;

/// Borrowed input at the failure boundary. `primary_result` and
/// `secondary_result` use the stable C result family when the cause has one,
/// and zero otherwise. Text fields are UTF-8. Recording copies the largest
/// bounded prefix of each field that ends at a code-point boundary.
pub const Input = struct {
    layer: Layer,
    operation: []const u8,
    scope_kind: ScopeKind,
    scope_id: u64 = 0,
    operation_id: u64 = 0,
    primary_result: i32 = 0,
    primary_name: []const u8,
    primary_message: []const u8 = &.{},
    secondary_result: i32 = 0,
    secondary_name: []const u8 = &.{},
    secondary_message: []const u8 = &.{},
    secondary_count: u32 = 0,
};

/// One claimed failure. Every byte view points into the caller-owned buffer
/// passed to `Journal.pop` and remains valid as long as that buffer does.
pub const Claim = struct {
    sequence: u64,
    dropped_before: u64,
    layer: Layer,
    scope_kind: ScopeKind,
    scope_id: u64,
    operation_id: u64,
    primary_result: i32,
    secondary_result: i32,
    secondary_count: u32,
    flags: u32,
    operation: []const u8,
    primary_name: []const u8,
    primary_message: []const u8,
    secondary_name: []const u8,
    secondary_message: []const u8,
};

const Field = enum { operation, primary_name, primary_message, secondary_name, secondary_message };
const field_count = @typeInfo(Field).@"enum".field_names.len;

const Slot = struct {
    sequence: u64 = 0,
    dropped_before: u64 = 0,
    layer: Layer = .core,
    scope_kind: ScopeKind = .process,
    scope_id: u64 = 0,
    operation_id: u64 = 0,
    primary_result: i32 = 0,
    secondary_result: i32 = 0,
    secondary_count: u32 = 0,
    flags: u32 = 0,
    lengths: [field_count]usize = @splat(0),
    payload_len: usize = 0,
};

/// A fixed-capacity, thread-safe journal. Initialization pays exactly two
/// allocations: one slot array and one fixed payload window per slot.
/// Recording never allocates. Saturation drops the oldest record and transfers
/// its gap count to the new head, so the consumer always sees discontinuity
/// before the first surviving record rather than inferring a complete history.
pub const Journal = struct {
    slots: []Slot,
    payload: []u8,
    payload_cap: usize,
    head: usize = 0,
    len: usize = 0,
    next_sequence: u64 = 1,
    mutex: SpinLock = .{},

    pub const InitError = error{ SizeOverflow, OutOfMemory };

    pub fn init(allocator: std.mem.Allocator, capacity: usize, payload_cap: usize) InitError!Journal {
        if (capacity == 0 or payload_cap == 0) return error.SizeOverflow;
        const payload_bytes = std.math.mul(usize, capacity, payload_cap) catch return error.SizeOverflow;
        const slots = try allocator.alloc(Slot, capacity);
        errdefer allocator.free(slots);
        const payload = try allocator.alloc(u8, payload_bytes);
        return .{ .slots = slots, .payload = payload, .payload_cap = payload_cap };
    }

    pub fn deinit(self: *Journal, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        allocator.free(self.slots);
        self.* = undefined;
    }

    fn window(self: *Journal, index: usize) []u8 {
        const start = index * self.payload_cap;
        return self.payload[start .. start + self.payload_cap];
    }

    fn flagFor(field: Field) u32 {
        return switch (field) {
            .operation => truncated_operation,
            .primary_name => truncated_primary_name,
            .primary_message => truncated_primary_message,
            .secondary_name => truncated_secondary_name,
            .secondary_message => truncated_secondary_message,
        };
    }

    fn boundedUtf8Len(source: []const u8, room: usize) usize {
        var len = @min(room, source.len);
        if (len == source.len) return len;
        while (len > 0 and source[len] & 0xc0 == 0x80) len -= 1;
        return len;
    }

    pub fn record(self: *Journal, input: Input) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var dropped_before: u64 = 0;
        if (self.len == self.slots.len) {
            const dropped = self.slots[self.head].dropped_before +| 1;
            self.head = (self.head + 1) % self.slots.len;
            self.len -= 1;
            // With a one-slot journal there is no surviving prefix to carry
            // the gap, so the record about to be written must carry it.
            if (self.len == 0) {
                dropped_before = dropped;
            } else {
                self.slots[self.head].dropped_before +|= dropped;
            }
        }

        const index = (self.head + self.len) % self.slots.len;
        const sequence = self.next_sequence;
        self.next_sequence +|= 1;
        var slot: Slot = .{
            .sequence = sequence,
            .dropped_before = dropped_before,
            .layer = input.layer,
            .scope_kind = input.scope_kind,
            .scope_id = input.scope_id,
            .operation_id = input.operation_id,
            .primary_result = input.primary_result,
            .secondary_result = input.secondary_result,
            .secondary_count = input.secondary_count,
        };
        const fields = [_][]const u8{
            input.operation,
            input.primary_name,
            input.primary_message,
            input.secondary_name,
            input.secondary_message,
        };
        const buf = self.window(index);
        for (fields, 0..) |source, field_index| {
            const room = buf.len - slot.payload_len;
            const copied = boundedUtf8Len(source, room);
            @memcpy(buf[slot.payload_len .. slot.payload_len + copied], source[0..copied]);
            slot.lengths[field_index] = copied;
            slot.payload_len += copied;
            if (copied != source.len) slot.flags |= flagFor(@fromBackingInt(@intCast(field_index)));
        }
        self.slots[index] = slot;
        self.len += 1;
    }

    pub fn nextPayloadLen(self: *Journal) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == 0) return null;
        return self.slots[self.head].payload_len;
    }

    /// Claim the oldest record into `out`. Returns `false` without consuming
    /// when the journal is empty. `error.BufferTooSmall` also leaves the record
    /// untouched, so a caller may size and retry without a race losing it.
    pub fn pop(self: *Journal, out: *Claim, caller_payload: []u8, required: *usize) error{BufferTooSmall}!bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == 0) {
            required.* = 0;
            return false;
        }
        const slot = self.slots[self.head];
        required.* = slot.payload_len;
        if (caller_payload.len < slot.payload_len) return error.BufferTooSmall;
        const source = self.window(self.head)[0..slot.payload_len];
        @memcpy(caller_payload[0..slot.payload_len], source);
        var cursor: usize = 0;
        const views: [field_count][]const u8 = blk: {
            var result: [field_count][]const u8 = undefined;
            for (slot.lengths, 0..) |field_len, index| {
                result[index] = caller_payload[cursor .. cursor + field_len];
                cursor += field_len;
            }
            break :blk result;
        };
        out.* = .{
            .sequence = slot.sequence,
            .dropped_before = slot.dropped_before,
            .layer = slot.layer,
            .scope_kind = slot.scope_kind,
            .scope_id = slot.scope_id,
            .operation_id = slot.operation_id,
            .primary_result = slot.primary_result,
            .secondary_result = slot.secondary_result,
            .secondary_count = slot.secondary_count,
            .flags = slot.flags,
            .operation = views[@backingInt(Field.operation)],
            .primary_name = views[@backingInt(Field.primary_name)],
            .primary_message = views[@backingInt(Field.primary_message)],
            .secondary_name = views[@backingInt(Field.secondary_name)],
            .secondary_message = views[@backingInt(Field.secondary_message)],
        };
        self.head = (self.head + 1) % self.slots.len;
        self.len -= 1;
        return true;
    }
};
