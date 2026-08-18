//! Public construction and ownership vocabulary for the native HostRuntime.
//! Runtime mechanics consume these values; this leaf owns no I/O or state.

const std = @import("std");

const model = @import("model");
const driver_core = @import("driver_core");
const OperationFailure = @import("../operation_failure.zig").OperationFailure;

const Budget = driver_core.Budget;
const Error = driver_core.Error;

/// Canonicalize a provider's portable locator claim at the driver authority
/// that composes transport realization with Host semantics. Extensions retain
/// their declared metadata after symbol validation.
pub fn canonicalProviderProfile(profile: model.transport.Metadata) !model.transport.Metadata {
    if (model.transport.parseKnown(profile.symbol) == null) {
        model.transport.validateSymbol(profile.symbol) catch return error.InvalidTransportName;
        return profile;
    }
    return model.transport.metadataFromClaim(
        profile.symbol,
        profile.designator_scheme,
        profile.sealed_channel,
    ) catch |err| switch (err) {
        error.InvalidTransportSymbol => error.InvalidTransportName,
        error.TransportSemanticsConflict => error.TransportSemanticsConflict,
    };
}

pub fn Vocabulary(
    comptime default_wire_buffer_bytes: usize,
    comptime default_max_pending_opens: usize,
    comptime default_listener_setup_ms: i64,
) type {
    return struct {
        pub const FailureObserver = struct {
            ctx: *anyopaque,
            report: *const fn (ctx: *anyopaque, failure: OperationFailure) void,
        };

        /// Options for the owning HostRuntime and its connect/listen views.
        /// Protocol admission and steady-state transport staging are separate:
        /// a large frame may assemble once in bounded spill without making
        /// every live wire retain `frame_cap` bytes. There is deliberately no
        /// peer-verification switch; the application tier always verifies.
        ///
        /// Wait budgets have no implicit default because an accidental
        /// infinite wait can strand a process. Callers that intentionally
        /// accept no deadline spell `.unbounded` at construction.
        pub const Options = struct {
            frame_cap: usize = 1 << 16,
            /// Bytes retained for each stream read/write buffer and each
            /// multiplexed resident read-staging buffer.
            wire_buffer_bytes: usize = default_wire_buffer_bytes,
            /// Shared bound for transport connects and CapTP handshakes that
            /// have been admitted but have not yet opened.
            max_pending_opens: usize = default_max_pending_opens,
            codec: model.CodecId = model.Preference.baseline.codec,
            /// Offered CapTP profile. Version and codec negotiate as separate
            /// axes, so callers normally set both but neither implies the other.
            captp_version: model.CaptpVersion = model.Preference.baseline.captp_version,
            /// Per-read deadline during the keyed handshake and redeem dial.
            handshake: Budget,
            /// Wall-clock deadline for externally paced listener construction.
            listener_setup: Budget = .{ .ms = default_listener_setup_ms },
            /// Deadline for blocking answer waits after a session opens.
            settle: Budget,
            /// Recipient only for failures produced after deterministic return
            /// ownership is gone. Explicit close barriers return their failure.
            unhandled_failure: ?FailureObserver = null,
        };

        /// Runtime-only controls for adopting an existing byte-fed Host. Core
        /// protocol/frame settings remain owned by that Host.
        pub const AdoptionOptions = struct {
            wire_buffer_bytes: usize = default_wire_buffer_bytes,
            max_pending_opens: usize = default_max_pending_opens,
            handshake: Budget,
            listener_setup: Budget = .{ .ms = default_listener_setup_ms },
            settle: Budget,
        };

        pub const ProviderRegistrationError = std.mem.Allocator.Error || Error || driver_core.HostError || error{
            InvalidProviderPackage,
            ReadinessDescriptorConflict,
            ReadinessUnavailable,
            ReadinessUpdateFailed,
        };
        pub const InitError = ProviderRegistrationError || driver_core.HostInitError;
        pub const AdoptionInitError = ProviderRegistrationError || driver_core.Host.RuntimeAdoptionError;
        /// Policy selected by the process owner for work already admitted when
        /// an owning close begins.
        pub const PendingWork = driver_core.PendingWork;
        /// Deterministic outcome of the owning close barrier.
        pub const CloseOutcome = driver_core.CloseOutcome;
    };
}
