//! A stored resolution's hold on the imports it names, the retains a
//! forwarded reply introduced for it, and the bounded, preallocated release
//! that leaves when the resolution does.
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

/// What one stored resolution keeps on the import table until it leaves.
/// `holds` is the far imports the value names, one
/// `ImportTable.holdForResolution` each, taken at the store and settled at
/// the drain into the retains callers released meanwhile. `owned` is the
/// retains a forwarded reply introduced with no caller to release them, one
/// `ImportTable.adoptForSession` each, released as they are. A payload's
/// `holds` batch chains its `owned` one, so one slot readies both.
pub const Batch = struct {
    outbox: *Outbox,
    next: ?*Batch = null,
    chained: ?*Batch = null,
    kind: Kind,
    /// One position per mention, then after `settle` the wire release:
    /// `live` entries with a nonzero delta each.
    positions: []u64,
    deltas: []u64,
    live: usize,
    settled: bool = false,
    charge: usize,

    pub const Kind = enum { holds, owned };

    /// Final payload retirement queues an effect without allocating or calling
    /// an engine. The heap outbox remains stable if its Session value moves.
    pub fn ready(self: *Batch) void {
        if (self.chained) |chained| chained.ready();
        if (self.outbox.tail) |tail| tail.next = self else self.outbox.head = self;
        self.outbox.tail = self;
    }

    /// The hold for a value about to be stored, or null for one naming no far
    /// import. Named cost: one cold outbox and one batch plus two exact wire
    /// arrays per stored resolution naming a far import. Live and ready
    /// batches together spend twice max_inbound_answers and the retained-answer
    /// byte budget. Final payload release only links the batch, so a drain
    /// refused for encoding or backpressure retries without losing it.
    pub fn prepareForValue(owner: *session.Session, value: model.Argument) !?*Batch {
        var mentions: usize = 0;
        _ = model.anyReference(&.{value}, &mentions, countFarMention);
        const batch = (try allocate(owner, .holds, mentions)) orelse return null;
        var fill: Fill = .{ .owner = owner, .positions = batch.positions };
        if (model.anyReference(&.{value}, &fill, fillFarMention)) {
            batch.destroy(owner);
            return error.InvalidReference;
        }
        std.debug.assert(fill.next == mentions);
        return batch;
    }

    /// The owned retains of one forwarded reply, or null for one introducing
    /// none. `mentions` repeats a position once per retain.
    pub fn prepare(owner: *session.Session, mentions: []const model.ImportPosition) !?*Batch {
        const batch = (try allocate(owner, .owned, mentions.len)) orelse return null;
        for (mentions, batch.positions, batch.deltas) |mention, *position, *delta| {
            position.* = mention.int();
            delta.* = 1;
        }
        return batch;
    }

    fn allocate(owner: *session.Session, kind: Kind, mentions: usize) !?*Batch {
        if (mentions == 0) return null;
        const arrays = std.math.mul(usize, mentions, 2 * @sizeOf(u64)) catch return error.RetainedAnswerCapExceeded;
        const charge = std.math.add(usize, @sizeOf(Batch), arrays) catch return error.RetainedAnswerCapExceeded;
        const total = std.math.add(usize, owner.retained_sent_answer_bytes, charge) catch return error.RetainedAnswerCapExceeded;
        if (total > owner.limits.max_retained_sent_answer_bytes) return error.RetainedAnswerCapExceeded;
        if (owner.import_release_outbox == null) {
            const outbox = try owner.allocator.create(Outbox);
            outbox.* = .{};
            owner.import_release_outbox = outbox;
        }
        const outbox = owner.import_release_outbox.?;
        // A payload keeps at most two: its hold and a forwarded reply's retains.
        if (outbox.active_batches >= 2 * owner.limits.max_inbound_answers) return error.QueueCapExceeded;
        const batch = try owner.allocator.create(Batch);
        errdefer owner.allocator.destroy(batch);
        const positions = try owner.allocator.alloc(u64, mentions);
        errdefer owner.allocator.free(positions);
        const deltas = try owner.allocator.alloc(u64, mentions);
        batch.* = .{ .outbox = outbox, .kind = kind, .positions = positions, .deltas = deltas, .live = mentions, .charge = charge };
        outbox.active_batches += 1;
        owner.retained_sent_answer_bytes = total;
        return batch;
    }

    fn countFarMention(mentions: *usize, reference: model.Reference) bool {
        if (isHeldFarMention(reference)) mentions.* += 1;
        return false;
    }

    const Fill = struct { owner: *session.Session, positions: []u64, next: usize = 0 };

    /// Records each far mention, stopping at one this session does not hold.
    fn fillFarMention(fill: *Fill, reference: model.Reference) bool {
        if (!isHeldFarMention(reference)) return false;
        if (!fill.owner.holdsImport(reference.far.import_position)) return true;
        fill.positions[fill.next] = reference.far.import_position.int();
        fill.next += 1;
        return false;
    }

    /// The partner bootstrap is permanently addressable and carries no row.
    fn isHeldFarMention(reference: model.Reference) bool {
        return reference == .far and reference.far.import_position.int() != session.bootstrap_position;
    }

    /// Take what the batch keeps: the commit, after every fallible step.
    pub fn take(batch: *Batch, owner: *session.Session) void {
        for (batch.positions) |position| switch (batch.kind) {
            .holds => owner.imports.holdForResolution(.from(position)),
            .owned => owner.imports.adoptForSession(.from(position)),
        };
    }

    /// Give the holds back and keep what they owed: the retains released
    /// while the resolution held each row, zero where another hold remains.
    /// Infallible and idempotent, so a drain refused after it retries the
    /// wire part alone. An owned batch releases what it took.
    pub fn settle(batch: *Batch, owner: *session.Session) void {
        if (batch.settled) return;
        batch.settled = true;
        if (batch.kind == .owned) return;
        var live: usize = 0;
        for (batch.positions) |position| {
            const owed = owner.imports.releaseResolutionHold(.from(position));
            if (owed == 0) continue;
            batch.positions[live] = position;
            batch.deltas[live] = owed;
            live += 1;
        }
        batch.live = live;
    }

    /// The settled release, empty when every row stays held or nothing was
    /// held back. The import table holds back any entry naming a row another
    /// resolution holds by then (`ImportTable.releaseSessionHeld`).
    pub fn release(batch: *const Batch) model.GcExport {
        std.debug.assert(batch.settled);
        return .{ .positions = batch.positions[0..batch.live], .deltas = batch.deltas[0..batch.live] };
    }

    /// Free an uncommitted preparation, an emitted effect, or teardown work.
    pub fn destroy(batch: *Batch, owner: *session.Session) void {
        std.debug.assert(owner.retained_sent_answer_bytes >= batch.charge);
        owner.retained_sent_answer_bytes -= batch.charge;
        std.debug.assert(batch.outbox.active_batches != 0);
        batch.outbox.active_batches -= 1;
        owner.allocator.free(batch.positions);
        owner.allocator.free(batch.deltas);
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
