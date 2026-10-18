//! One atomic word admits an engine's users and holds its fences. The
//! blocking engines embed it: a close or a maintenance reservation refuses
//! new users, and an uncertain commit fences every user until recovery
//! reads a consistent store.
const std = @import("std");

pub const Admission = struct {
    word: std.atomic.Value(usize) = .init(0),
    const closing: usize = @as(usize, 1) << (@bitSizeOf(usize) - 1);
    const maintenance = closing >> 1;
    const reopen_required = maintenance >> 1;
    /// The user count below the lowest fence bit.
    const count_mask = reopen_required - 1;

    /// Stop new users for good. Busy while a user or maintenance holds the
    /// engine, and the stop stays set for the retry.
    pub fn close(self: *Admission) error{Busy}!void {
        if (self.word.fetchOr(closing, .acq_rel) & ~(closing | reopen_required) != 0) return error.Busy;
    }

    /// Stop new users without a verdict, under a maintenance reservation
    /// that replaces the environment.
    pub fn stop(self: *Admission) void {
        _ = self.word.fetchOr(closing, .acq_rel);
    }

    /// Reserve the engine for work no user may overlap.
    pub fn beginMaintenance(self: *Admission) error{ ReopenRequired, Closed, Busy }!void {
        if (self.word.cmpxchgStrong(0, maintenance, .acq_rel, .acquire)) |current| {
            if (current & reopen_required != 0) return error.ReopenRequired;
            return if (current & closing != 0) error.Closed else error.Busy;
        }
    }

    pub fn endMaintenance(self: *Admission) void {
        // A concurrent close can set its fence while maintenance is in flight.
        const previous = self.word.fetchAnd(~maintenance, .release);
        std.debug.assert(previous & maintenance != 0);
    }

    /// Reserve the engine for recovery, fenced or not, and report whether it
    /// was fenced. `endMaintenance` ends the reservation and `recovered`
    /// lifts the fence.
    pub fn beginRecovery(self: *Admission) error{ Closed, Busy }!bool {
        const fenced = self.word.load(.acquire) & reopen_required;
        if (self.word.cmpxchgStrong(fenced, fenced | maintenance | reopen_required, .acq_rel, .acquire)) |current| {
            return if (current & closing != 0) error.Closed else error.Busy;
        }
        return fenced != 0;
    }

    pub fn recovered(self: *Admission) void {
        _ = self.word.fetchAnd(~reopen_required, .release);
    }

    /// Refuse ordinary work until recovery or close.
    pub fn fence(self: *Admission) void {
        _ = self.word.fetchOr(reopen_required, .acq_rel);
    }

    /// What a writer checks after taking its slot: the previous writer may
    /// have fenced between this user's retain and its release of the slot.
    pub fn checkOpen(self: *const Admission) error{ ReopenRequired, Closed }!void {
        const current = self.word.load(.acquire);
        if (current & reopen_required != 0) return error.ReopenRequired;
        if (current & closing != 0) return error.Closed;
    }

    pub fn retain(self: *Admission) error{ ReopenRequired, Closed, Busy }!void {
        var current = self.word.load(.acquire);
        while (true) {
            if (current & reopen_required != 0) return error.ReopenRequired;
            if (current & closing != 0) return error.Closed;
            if (current & maintenance != 0 or current == count_mask) return error.Busy;
            current = self.word.cmpxchgWeak(current, current + 1, .acq_rel, .acquire) orelse return;
        }
    }

    pub fn release(self: *Admission) void {
        const previous = self.word.fetchSub(1, .release);
        std.debug.assert(previous & count_mask != 0);
    }
};
