//! Bounded, preallocated import-release effects owned by stored reply values.
const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");

pub const Outbox = struct {
    head: ?*Batch = null,
    tail: ?*Batch = null,
    active_batches: usize = 0,

    pub fn removeHead(self: *Outbox, owner: *session.Session) void {
        const batch = self.head orelse unreachable;
        self.head = batch.next;
        if (self.head == null) self.tail = null;
        batch.destroy(owner);
    }

    /// Live payloads queue their batches before lifecycle invokes this walk.
    pub fn deinit(self: *Outbox, owner: *session.Session) void {
        while (self.head != null) self.removeHead(owner);
        std.debug.assert(self.active_batches == 0);
        owner.allocator.destroy(self);
        owner.import_release_outbox = null;
    }
};

pub const Batch = struct {
    outbox: *Outbox,
    next: ?*Batch = null,
    release: model.GcExport,
    charge: usize,

    /// Final payload retirement queues an effect without allocating or calling
    /// an engine. The heap outbox remains stable if its Session value moves.
    pub fn ready(self: *Batch) void {
        if (self.outbox.tail) |tail| tail.next = self else self.outbox.head = self;
        self.outbox.tail = self;
    }

    /// Named cost: one cold outbox and one batch plus two exact wire arrays per
    /// capability-bearing forwarded result; value-only results allocate none.
    /// The batch adopts the callback's existing wire retains, never another copy.
    /// Live and ready batches together spend max_inbound_answers and the existing
    /// retained-answer byte budget. Final payload release only links the batch;
    /// encoding/backpressure can retry the effect without losing its ownership.
    pub fn prepare(owner: *session.Session, mentions: []const model.ImportPosition) !?*Batch {
        if (mentions.len == 0) return null;
        const charge = std.math.add(usize, @sizeOf(Batch), std.math.mul(usize, mentions.len, 2 * @sizeOf(u64)) catch return error.RetainedAnswerCapExceeded) catch return error.RetainedAnswerCapExceeded;
        const total = std.math.add(usize, owner.retained_sent_answer_bytes, charge) catch return error.RetainedAnswerCapExceeded;
        if (total > owner.limits.max_retained_sent_answer_bytes) return error.RetainedAnswerCapExceeded;
        if (owner.import_release_outbox == null) {
            const outbox = try owner.allocator.create(Outbox);
            outbox.* = .{};
            owner.import_release_outbox = outbox;
        }
        const outbox = owner.import_release_outbox.?;
        if (outbox.active_batches >= owner.limits.max_inbound_answers) return error.QueueCapExceeded;
        const batch = try owner.allocator.create(Batch);
        errdefer owner.allocator.destroy(batch);
        const message = (try messageForMentions(owner.allocator, mentions)).?;
        batch.* = .{ .outbox = outbox, .release = message.gc_export, .charge = charge };
        outbox.active_batches += 1;
        owner.retained_sent_answer_bytes = total;
        return batch;
    }

    pub fn adopt(batch: *Batch, owner: *session.Session) void {
        for (batch.release.positions) |position| owner.adoptImportRetain(.from(position));
    }

    /// Free an uncommitted preparation, an emitted effect, or teardown work.
    pub fn destroy(batch: *Batch, owner: *session.Session) void {
        std.debug.assert(owner.retained_sent_answer_bytes >= batch.charge);
        owner.retained_sent_answer_bytes -= batch.charge;
        std.debug.assert(batch.outbox.active_batches != 0);
        batch.outbox.active_batches -= 1;
        owner.allocator.free(batch.release.positions);
        owner.allocator.free(batch.release.deltas);
        owner.allocator.destroy(batch);
    }

    /// The shared exact wire arrays for an admitted import mention record. The
    /// caller owns the resulting message and reserves its outbound seat separately.
    pub fn messageForMentions(allocator: std.mem.Allocator, mentions: []const model.ImportPosition) !?model.Message {
        if (mentions.len == 0) return null;
        const positions = try allocator.alloc(u64, mentions.len);
        errdefer allocator.free(positions);
        const deltas = try allocator.alloc(u64, mentions.len);
        for (mentions, positions, deltas) |mention, *position, *delta| {
            position.* = mention.int();
            delta.* = 1;
        }
        return .{ .gc_export = .{ .positions = positions, .deltas = deltas } };
    }
};
