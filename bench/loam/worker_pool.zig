//! `capacity` persistent worker threads, each running `hosting.Worker.run` on its
//! slot. Posting lends one request, completion returns its buffer custody.
//! Store/Host installation stays on the owner.
const std = @import("std");
const w = @import("workload.zig");
const Work = w.hosting.Work;
const Worker = w.hosting.Worker;
const Future = @TypeOf(@as(std.Io, undefined).concurrent(execute, .{@as(*Slot, undefined)}) catch unreachable);
pub const capacity = 4;

const Slot = struct {
    io: std.Io = undefined,
    db: *w.Lmdb = undefined,
    work: Worker.Slot = .{},
    posted: std.Io.Event = .unset,
    completed: std.Io.Event = .unset,
    stop: std.atomic.Value(bool) = .init(false),
    gate: ?*std.atomic.Value(bool) = null,
    collection: bool = false,
    busy: bool = false,
    future: ?Future = null,
};

fn execute(slot: *Slot) void {
    while (true) {
        slot.posted.waitUncancelable(slot.io);
        slot.posted.reset();
        if (slot.stop.load(.acquire)) return;
        // Calibration alone holds workers; measured workloads never delay I/O.
        if (slot.gate) |gate| while (!gate.load(.acquire)) std.atomic.spinLoopHint();
        Worker.run(&slot.work, slot.db) catch unreachable; // `submit` posts only a fresh slot.
        // No request/buffer access after this release. The worker can now wait
        // for another post while the owner installs or retires this result.
        slot.completed.set(slot.io);
    }
}

pub const Pool = struct {
    io: std.Io,
    slots: [capacity]Slot = @splat(.{}),
    started: bool = false,
    active: usize = 0,
    peak: usize = 0,
    saturation_turns: usize = 0,

    // Construct workers before lending any Store requests. Partial startup
    // joins every created worker; refusal cannot strand a borrowed buffer.
    pub fn start(self: *Pool) !void {
        std.debug.assert(!self.started);
        errdefer self.stop();
        for (&self.slots) |*slot| {
            slot.io = self.io;
            slot.stop.store(false, .monotonic);
            slot.posted.reset();
            slot.completed.reset();
            slot.future = try self.io.concurrent(execute, .{slot});
        }
        self.started = true;
    }

    pub fn submit(self: *Pool, workload: anytype, work: Work, collection: bool, gate: ?*std.atomic.Value(bool)) !void {
        if (!self.started) return error.ExecutorStopped;
        const slot = for (&self.slots) |*slot| {
            if (!slot.busy) break slot;
        } else return error.ExecutorFull;
        slot.db = workload.db;
        slot.work = .{ .active = true, .request = switch (work) {
            .read => |request| .{ .read = request },
            .lookup => |request| .{ .lookup = request },
            .write => |batch| .{ .write = batch },
        } };
        slot.collection = collection;
        slot.gate = gate;
        slot.completed.reset();
        slot.busy = true;
        self.active += 1;
        self.peak = @max(self.peak, self.active);
        slot.posted.set(self.io);
    }

    pub fn poll(self: *Pool, workload: anytype) !void {
        for (&self.slots) |*slot| {
            if (!slot.busy or !slot.completed.isSet()) continue;
            slot.busy = false;
            self.active -= 1;
            try install(workload, slot);
        }
    }

    pub fn turn(self: *Pool, workload: anytype) !void {
        // Every slot may run a read at once, so the engine must admit them all.
        if (capacity > workload.db.readerCapacity()) return error.ReaderCapacity;
        try self.poll(workload);
        _ = try workload.host.vat.driveIngressBudgeted(.local, 128);
        try workload.attachment.advance();
        while (self.active < capacity) {
            const work = try workload.attachment.nextWork() orelse break;
            try self.submit(workload, work, false, null);
        }
        if (self.active == capacity) self.saturation_turns += 1;
    }

    // Await worker completion before freeing borrowed memory, including on
    // errors. Calibration opens its gate before reaching this deferred drain.
    pub fn drain(self: *Pool, workload: anytype) void {
        for (&self.slots) |*slot| if (slot.busy) slot.completed.waitUncancelable(self.io);
        // tolerant: poll retires a slot before its install can fail, so the loop always ends, and a failed install loses one worker result in a teardown that discards the workload.
        while (self.active != 0) self.poll(workload) catch {};
    }

    pub fn stop(self: *Pool) void {
        std.debug.assert(self.active == 0);
        for (&self.slots) |*slot| if (slot.future != null) {
            slot.stop.store(true, .release);
            slot.posted.set(self.io);
        };
        for (&self.slots) |*slot| if (slot.future) |*future| {
            future.await(self.io);
            slot.future = null;
        };
        self.started = false;
    }
};

fn install(workload: anytype, slot: *Slot) !void {
    const result = slot.work.result.?;
    switch (slot.work.request) {
        .read => |request| {
            workload.reads += 1;
            try workload.attachment.completeRead(request.ticket, result.read);
        },
        .lookup => |request| try workload.attachment.completeLookup(request.ticket, result.lookup),
        .write => |batch| {
            if (slot.collection) try workload.store.completeWrite(batch.ticket, result.write) else try workload.attachment.completeWrite(batch.ticket, result.write);
            if (result.write != .committed) return error.CommitFailed;
            workload.writes += 1;
        },
        .recover => unreachable, // `submit` never posts recovery.
    }
}
