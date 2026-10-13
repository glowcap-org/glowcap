//! Fixed storage work slots between an attachment and the application's backend.
const core = @import("loam_core");
const Attachment = @import("attachment.zig").Attachment;

/// Moves an attachment's storage work through slots the application owns.
/// The worker borrows its slot memory and owns no backend and no thread.
/// `next`, `complete`, and `release` run on the attachment's owner. `run`
/// reads only its slot and the backend, so it may run on another thread
/// between `next` and `complete` when the owner joins it before completing
/// (`bench/loam/worker_pool.zig` drives four slots that way). `drive` needs
/// one free slot. The C attachment reserves `cache_slots + 1`. The recovery
/// exclusion counts only this worker's slots, so an attachment uses one worker
/// at a time.
pub const Worker = struct {
    pub const Request = union(enum) { read: core.Read, write: core.Batch, lookup: core.NameLookup, recover: core.Batch };
    pub const Result = union(enum) { read: core.ReadResult, write: core.Outcome, lookup: core.NameResult, recover: core.Resolution, failed: anyerror };

    /// One submitted request and its result. A slot borrows the request's
    /// buffers from the Store until `Worker.release` frees it.
    pub const Slot = struct {
        active: bool = false,
        request: Request = undefined,
        result: ?Result = null,
        completed: bool = false,
    };

    slots: []Slot,
    active: usize = 0,

    pub fn init(slots: []Slot) Worker {
        for (slots) |*slot| slot.* = .{};
        return .{ .slots = slots };
    }

    /// Take the next request into a free slot, or return null when the
    /// attachment has none. Recovery is taken when forced or when the
    /// attachment's own write is uncertain, and only while no other slot is
    /// active. Until recovery resolves, every request is the recovery batch,
    /// so ordinary work waits. A full worker is `error.Busy`.
    pub fn next(self: *Worker, attachment: *Attachment, force_recovery: bool) !?*Slot {
        try attachment.topLevel();
        const recovery = force_recovery or attachment.awaitsRecovery();
        if (recovery and self.active != 0) return error.Busy;
        const slot = for (self.slots) |*slot| {
            if (!slot.active) break slot;
        } else return error.Busy;
        const request: Request = if (recovery)
            .{ .recover = try attachment.recoveryBatch() }
        else if (try attachment.nextWork()) |work| switch (work) {
            .read => |value| .{ .read = value },
            .write => |value| .{ .write = value },
            .lookup => |value| .{ .lookup = value },
        } else return null;
        slot.* = .{ .active = true, .request = request };
        self.active += 1;
        return slot;
    }

    /// Execute a taken slot against `backend`, which answers `read`, `commit`,
    /// `lookup`, and `recover` as `Volatile` and `Lmdb` do. A recovery failure
    /// becomes the slot's `.failed` result for `complete` to return.
    pub fn run(slot: *Slot, backend: anytype) !void {
        if (!slot.active or slot.completed or slot.result != null) return error.StaleCompletion;
        slot.result = switch (slot.request) {
            .read => |request| .{ .read = backend.read(request) },
            .write => |batch| .{ .write = backend.commit(batch) },
            .lookup => |request| .{ .lookup = backend.lookup(request) },
            .recover => |batch| if (backend.recover(batch)) |resolution| .{ .recover = resolution } else |err| .{ .failed = err },
        };
    }

    /// Install a run slot's result through `completeRead`, `completeWrite`,
    /// `completeLookup`, or `resolve`. The slot is consumed even when the
    /// attachment refuses the result, so a second completion is stale.
    pub fn complete(self: *Worker, slot: *Slot, attachment: *Attachment) !void {
        if (!self.holds(slot) or !slot.active or slot.completed) return error.StaleCompletion;
        try attachment.topLevel();
        const result = slot.result orelse return error.WorkerNotRetired;
        slot.completed = true;
        switch (result) {
            .read => |value| try attachment.completeRead(slot.request.read.ticket, value),
            .write => |value| try attachment.completeWrite(slot.request.write.ticket, value),
            .lookup => |value| try attachment.completeLookup(slot.request.lookup.ticket, value),
            .recover => |value| try attachment.resolve(slot.request.recover.ticket, value),
            .failed => |err| return err,
        }
    }

    /// Free a completed slot and its borrow of the request. A slot that has not
    /// completed is `error.Busy`.
    pub fn release(self: *Worker, slot: *Slot) !void {
        if (!self.holds(slot) or !slot.active) return error.StaleCompletion;
        if (!slot.completed) return error.Busy;
        self.active -= 1;
        slot.* = .{};
    }

    /// Run every request the attachment has on this thread until `next`
    /// returns null.
    pub fn drive(self: *Worker, attachment: *Attachment, backend: anytype) !void {
        while (try self.next(attachment, false)) |slot| {
            run(slot, backend) catch unreachable; // `next` just filled this slot.
            const installed = self.complete(slot, attachment);
            // `next` passed the top-level check on this stack, so `complete` consumed the slot.
            self.release(slot) catch unreachable;
            try installed;
        }
    }

    /// The position of `slot` in this worker's slot memory, or null when the
    /// slot belongs to another worker.
    pub fn indexOf(self: *const Worker, slot: *const Slot) ?usize {
        const first = @intFromPtr(self.slots.ptr);
        const at = @intFromPtr(slot);
        if (at < first or at >= first + self.slots.len * @sizeOf(Slot)) return null;
        return (at - first) / @sizeOf(Slot);
    }

    fn holds(self: *const Worker, slot: *const Slot) bool {
        return self.indexOf(slot) != null;
    }
};
