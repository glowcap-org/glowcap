//! Owned runtime state shared by the onion archive's two C projections.

const std = @import("std");
const net = @import("net");
const c = @import("c_abi_shared");

pub const Profile = struct {
    owner: *Netlayer,
};

pub const Netlayer = struct {
    threaded: std.Io.Threaded,
    resident: net.onion.Resident,
    allocator: std.mem.Allocator,
    /// One block owns every copied configuration string.
    text: []u8,
    /// Tor operations run under this cancellation-and-join owner.
    tasks: net.OperationOwner,
    /// Covers each complete foreign call, including output publication.
    calls: c.ForeignCallBarrier = .{},
    failure_mutex: net.sync.SpinLock = .{},
    terminal_failure: ?net.netlayer.ListenerCloseFailure = null,
    references: std.atomic.Value(usize),

    // The provider projection is stored with the runtime so every callback
    // pointer and context stays valid for the complete package lease.
    provider_profile: Profile,
    provider_profile_abi: c.PancakeTransportProfile,
    provider_table: c.PancakeStreamTransport,
    provider_entry: c.PancakeTransportProviderEntry,
    provider: c.PancakeTransportProvider,

    pub fn io(self: *Netlayer) std.Io {
        return self.threaded.io();
    }

    pub fn noteFailure(self: *Netlayer, later: net.netlayer.ListenerCloseFailure) void {
        self.failure_mutex.lock();
        defer self.failure_mutex.unlock();
        if (self.terminal_failure) |*recorded|
            recorded.noteChain(later)
        else
            self.terminal_failure = later;
    }

    fn recordedFailure(self: *Netlayer) ?net.netlayer.ListenerCloseFailure {
        self.failure_mutex.lock();
        defer self.failure_mutex.unlock();
        return self.terminal_failure;
    }

    pub fn retain(self: *Netlayer) bool {
        var current = self.references.load(.acquire);
        while (current != 0) {
            if (self.references.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |observed| {
                current = observed;
            } else return true;
        }
        return false;
    }

    pub fn shutdown(self: *Netlayer) void {
        _ = self.calls.beginShutdown(self.io());
        self.tasks.shutdown();
    }

    pub fn release(self: *Netlayer) ?net.netlayer.ListenerCloseFailure {
        if (self.references.fetchSub(1, .acq_rel) != 1) return null;
        self.shutdown();
        self.tasks.join();
        self.calls.wait(self.io());
        const failure = self.recordedFailure();
        const allocator = self.allocator;
        self.threaded.deinit();
        allocator.free(self.text);
        allocator.destroy(self);
        return failure;
    }

    /// Provider children retire while an installed package still owns a lease.
    pub fn releaseProviderChild(self: *Netlayer) void {
        const prior = self.references.fetchSub(1, .acq_rel);
        std.debug.assert(prior > 1);
    }
};
