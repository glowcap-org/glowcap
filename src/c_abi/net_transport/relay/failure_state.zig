//! Relay runtime failure ownership.
//!
//! Reactor faults are terminal immediately. Operation teardown stays on its
//! request/listener/connection tombstone until readiness lets the driver claim
//! it; this state retains only cleanup whose operation recipient disappeared
//! because the whole runtime is already releasing. Both classes share one
//! observation-ordered release outcome without letting cleanup alone fail-stop
//! otherwise live connections.

const std = @import("std");

const foundation = @import("foundation");
const net = @import("net");

pub const State = struct {
    mutex: net.sync.SpinLock = .{},
    outcome: ?foundation.FailureChain = null,
    terminal: ?foundation.FailureChain = null,
    terminal_present: std.atomic.Value(bool) = .init(false),

    pub fn noteTerminal(self: *State, later: foundation.FailureChain) void {
        self.mutex.lock();
        append(&self.outcome, later);
        append(&self.terminal, later);
        self.mutex.unlock();
        self.terminal_present.store(true, .release);
    }

    pub fn noteCleanup(self: *State, later: foundation.FailureChain) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        append(&self.outcome, later);
    }

    pub fn hasTerminal(self: *const State) bool {
        return self.terminal_present.load(.acquire);
    }

    pub fn terminalFailure(self: *State) ?foundation.FailureChain {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.terminal;
    }

    pub fn releaseOutcome(self: *State) ?foundation.FailureChain {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.outcome;
    }

    fn append(slot: *?foundation.FailureChain, later: foundation.FailureChain) void {
        if (slot.*) |*first| first.noteChain(later) else slot.* = later;
    }
};
