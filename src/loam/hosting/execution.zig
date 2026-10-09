//! Private execution observes one target-admission fact and one owning result.
//! It neither records an effect receipt nor infers whether the effect applied.
const std = @import("std");
const driver = @import("driver_core");

pub const Execution = opaque {
    pub const Failure = @FieldType(driver.Host.Call.Result, "failed");
    pub const Result = union(enum) {
        pending,
        ready: driver.Value,
        /// No target call crossed Host admission.
        unsent: Failure,
        /// Target admission occurred; only the application can resolve effect
        /// application. A broken reply or closed connection is insufficient.
        unknown: Failure,
    };

    /// Caller result storage has the same bound as Host.Call. The shared
    /// dispatch metadata is a separate Host allocation, alive across observer
    /// cancellation until endpoint and operation custody retire.
    pub fn sizeBound(reply_bytes: usize) !usize {
        return driver.Host.Call.sizeBound(reply_bytes);
    }

    pub fn metadataBytes() usize {
        return @sizeOf(Dispatch);
    }

    pub fn result(self: *const Execution) Result {
        const state: *const Dispatch = @ptrCast(@alignCast(self));
        return switch (state.call.?.result()) {
            .pending => .pending,
            .ready => |value| .{ .ready = value },
            .failed => |failure| if (state.admitted) .{ .unknown = failure } else .{ .unsent = failure },
        };
    }

    /// Detach the observer, not an admitted effect or its receipt. Call before
    /// destroying Host or the caller allocator; bytes and capabilities borrow
    /// this observer until release.
    pub fn deinit(self: *Execution) void {
        const state: *Dispatch = @ptrCast(@alignCast(self));
        state.call.?.deinit();
        state.call = null;
        state.release();
    }
};

/// One stable allocation shared by observer, internal endpoint and admitted
/// operation. Restarts only replace preparation; admission is monotonic.
pub const Dispatch = struct {
    host: *driver.Host,
    refs: usize = 1,
    call: ?*driver.Host.Call = null,
    admitted: bool = false,

    pub fn create(host: *driver.Host) !*Dispatch {
        const self = try host.allocator.create(Dispatch);
        self.* = .{ .host = host };
        return self;
    }

    pub fn retain(self: *Dispatch) void {
        std.debug.assert(self.refs != std.math.maxInt(usize));
        self.refs += 1;
    }

    pub fn release(self: *Dispatch) void {
        std.debug.assert(self.refs != 0);
        self.refs -= 1;
        if (self.refs != 0) return;
        std.debug.assert(self.call == null);
        self.host.allocator.destroy(self);
    }

    pub fn handle(self: *Dispatch) *Execution {
        return @ptrCast(self);
    }
};
