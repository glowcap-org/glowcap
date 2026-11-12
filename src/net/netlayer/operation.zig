//! The borrowed inputs one dial or listen takes: caller buffers, provider
//! options, the dial's origin, and the listener bind configuration.

const foundation = @import("foundation");

/// Caller-owned read/write buffers handed to a dial/accept. `read` sizes the
/// steady per-connection memory, not the largest admissible frame.
pub const Buffers = struct {
    read: []u8,
    write: []u8,
};

/// Borrowed provider-owned configuration for one dial or listener operation.
/// The selected provider validates the exact payload type and must copy any
/// value retained after the starting call returns.
pub const OperationOptions = struct {
    data: ?*const anyopaque = null,
    size: usize = 0,

    pub const inherit: OperationOptions = .{};

    pub fn decode(self: OperationOptions, comptime T: type) error{InvalidOptions}!?*const T {
        const data = self.data orelse {
            if (self.size != 0) return error.InvalidOptions;
            return null;
        };
        if (self.size != @sizeOf(T) or @intFromPtr(data) % @alignOf(T) != 0)
            return error.InvalidOptions;
        return @ptrCast(@alignCast(data));
    }

    pub fn requireInherited(self: OperationOptions) error{InvalidOptions}!void {
        if (self.data != null or self.size != 0) return error.InvalidOptions;
    }
};

/// Where one dial came from, borrowed for the starting call. A handoff dial
/// follows a reference some open session handed over, and the core knows that
/// session. A provider whose connect needs an outside party, as WebRTC
/// signaling does, routes by it. A provider that connects to an address reads
/// nothing here.
pub const DialOrigin = struct {
    /// The designator the introducing session's partner signed in its hello,
    /// as `Host.partnerIdentity` reports it. Null for a dial the application
    /// started itself, for a handoff whose introducing session has closed,
    /// and for a partner that signed no designator.
    introducer: ?[]const u8 = null,

    pub const application: DialOrigin = .{};
};

/// Borrowed configuration for one listener bind.
pub const ListenConfig = struct {
    designator: []const u8,
    identity: ?foundation.crypto.PeerKey = null,
    options: OperationOptions = .inherit,
};
