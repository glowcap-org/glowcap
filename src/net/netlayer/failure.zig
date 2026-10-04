//! Structured transport failures and scalar-callback adapters.
//!
//! Runtime owners keep the structured outcomes. Scalar adapters exist only at
//! native vtable declarations whose implementation has no richer cause chain.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const connection = @import("../connection.zig");
const carrier_failure = @import("../carrier_failure.zig");
const support = @import("../netlayer_support.zig");

const Buffers = support.Buffers;
const Connection = connection.Connection;

pub const RestorationStateError = error{ProviderFailure};

/// The closed retry-classification axis. Exact transport identity lives in
/// `DialFailure.chain`; policy never depends on private error names.
pub const DialError = error{
    InvalidAddress,
    InvalidOptions,
    WouldBlock,
    ConnectionRefused,
    NetworkUnreachable,
    TimedOut,
    ConnectionLost,
    SocketConfigurationFailed,
    WakeNudgeFailed,
} || std.mem.Allocator.Error;

pub const DialFailure = struct {
    classification: DialError,
    chain: foundation.FailureChain,
    /// Carrier acquisition phase when the selected transport can name it.
    /// Generic transports leave this null; policy never depends on it.
    carrier_phase: ?carrier_failure.Phase = null,
    carrier_detail: carrier_failure.Detail = .{},

    pub fn init(cause: DialError) DialFailure {
        return .{ .classification = cause, .chain = .init(cause) };
    }

    pub fn fromChain(classification: DialError, chain: foundation.FailureChain) DialFailure {
        return .{ .classification = classification, .chain = chain };
    }

    pub fn fromCarrier(classification: DialError, failure: carrier_failure.Failure) DialFailure {
        return .{
            .classification = classification,
            .chain = failure.chain,
            .carrier_phase = failure.phase,
            .carrier_detail = failure.detail,
        };
    }
};

pub fn RawConnectionDialOutcome(comptime RawConnection: type) type {
    return union(enum) {
        connected: RawConnection,
        failed: DialFailure,
    };
}

pub const ListenError = error{ InvalidAddress, InvalidOptions, BindFailed } || std.mem.Allocator.Error;
pub const AcceptError = error{
    ConnectionLost,
    SocketConfigurationFailed,
    WakeNudgeFailed,
    WakeDrainFailed,
} || std.mem.Allocator.Error;

pub const AcceptFailure = struct {
    classification: AcceptError,
    chain: foundation.FailureChain,
    carrier_phase: ?carrier_failure.Phase = null,
    carrier_detail: carrier_failure.Detail = .{},

    pub fn init(classification: AcceptError) AcceptFailure {
        return .{ .classification = classification, .chain = .init(classification) };
    }

    pub fn fromChain(classification: AcceptError, chain: foundation.FailureChain) AcceptFailure {
        return .{ .classification = classification, .chain = chain };
    }

    pub fn fromCarrier(classification: AcceptError, failure: carrier_failure.Failure) AcceptFailure {
        return .{
            .classification = classification,
            .chain = failure.chain,
            .carrier_phase = failure.phase,
            .carrier_detail = failure.detail,
        };
    }
};

pub const AcceptOutcome = union(enum) {
    accepted: Connection,
    failed: AcceptFailure,
};

pub const AcceptReadinessOutcome = union(enum) {
    ready: bool,
    failed: AcceptFailure,
};

pub const ListenerCloseFailure = foundation.FailureChain;
pub const ListenFailure = foundation.FailureChain;

pub const ListenerLocatorOutcome = union(enum) {
    locator: model.PeerLocator,
    failed: ListenFailure,
};

pub const ListenerRestorationOutcome = union(enum) {
    unsupported,
    size: usize,
    failed: ListenFailure,
};

pub fn projectListenError(value: ListenFailure) ListenError {
    if (value.cause == error.OutOfMemory or value.classification == .internal)
        return error.OutOfMemory;
    if (value.cause == error.InvalidOptions) return error.InvalidOptions;
    if (value.cause == error.BindFailed) return error.BindFailed;
    return error.InvalidAddress;
}

pub fn adaptBlockingDial(comptime callback: fn (
    *anyopaque,
    *engine.Peer,
    model.PeerLocator,
    Buffers,
    support.OperationOptions,
) DialError!Connection) *const fn (
    *anyopaque,
    *engine.Peer,
    model.PeerLocator,
    Buffers,
    support.OperationOptions,
) DialOutcome {
    return struct {
        fn call(
            ctx: *anyopaque,
            peer: *engine.Peer,
            locator: model.PeerLocator,
            bufs: Buffers,
            options: support.OperationOptions,
        ) DialOutcome {
            return .{ .connected = callback(ctx, peer, locator, bufs, options) catch |err|
                return .{ .failed = .init(err) } };
        }
    }.call;
}

pub const DialOutcome = union(enum) {
    connected: Connection,
    failed: DialFailure,
};

pub fn adaptAccept(comptime callback: fn (*anyopaque, *engine.Peer, Buffers) AcceptError!Connection) *const fn (*anyopaque, *engine.Peer, Buffers) AcceptOutcome {
    return struct {
        fn call(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) AcceptOutcome {
            return .{ .accepted = callback(ctx, peer, bufs) catch |err|
                return .{ .failed = .init(err) } };
        }
    }.call;
}

pub fn adaptAcceptReadiness(comptime callback: fn (*anyopaque, i32) AcceptError!bool) *const fn (*anyopaque, i32) AcceptReadinessOutcome {
    return struct {
        fn call(ctx: *anyopaque, timeout_ms: i32) AcceptReadinessOutcome {
            return .{ .ready = callback(ctx, timeout_ms) catch |err|
                return .{ .failed = .init(err) } };
        }
    }.call;
}

pub fn adaptListenerLocator(comptime callback: fn (*anyopaque, std.mem.Allocator) ListenError!model.PeerLocator) *const fn (*anyopaque, std.mem.Allocator) ListenerLocatorOutcome {
    return struct {
        fn call(ctx: *anyopaque, allocator: std.mem.Allocator) ListenerLocatorOutcome {
            return .{ .locator = callback(ctx, allocator) catch |err|
                return .{ .failed = .init(err) } };
        }
    }.call;
}

pub fn adaptListenerCanonicalize(comptime callback: fn (*anyopaque, std.mem.Allocator, model.PeerLocator) ListenError!model.PeerLocator) *const fn (*anyopaque, std.mem.Allocator, model.PeerLocator) ListenerLocatorOutcome {
    return struct {
        fn call(ctx: *anyopaque, allocator: std.mem.Allocator, locator: model.PeerLocator) ListenerLocatorOutcome {
            return .{ .locator = callback(ctx, allocator, locator) catch |err|
                return .{ .failed = .init(err) } };
        }
    }.call;
}

pub fn adaptRestorationState(comptime callback: fn (*anyopaque, []u8) RestorationStateError!usize) *const fn (*anyopaque, []u8) ListenerRestorationOutcome {
    return struct {
        fn call(ctx: *anyopaque, out: []u8) ListenerRestorationOutcome {
            return .{ .size = callback(ctx, out) catch |err|
                return .{ .failed = .init(err) } };
        }
    }.call;
}
