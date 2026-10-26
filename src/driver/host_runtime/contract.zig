//! Public construction and ownership vocabulary for the Zig HostRuntime.
//! Runtime mechanics consume these values. This leaf owns no I/O or state.

const std = @import("std");

const model = @import("model");
const driver_core = @import("driver_core");
const lifecycle = @import("lifecycle.zig");
const dial_retry = @import("../dial_retry.zig");
const OperationFailure = @import("../operation_failure.zig").OperationFailure;

const Budget = driver_core.Budget;
const DialPolicy = dial_retry.DialPolicy;
const DialOutcomeObserver = dial_retry.DialOutcomeObserver;
const Error = driver_core.Error;
const default_frame_cap = (driver_core.Host.Options{}).limits.max_frame_bytes;

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
        profile.wire_framing,
        profile.max_packet_bytes,
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
        /// every live wire retain `frame_cap` bytes. There is no
        /// peer-verification switch. The application tier always verifies.
        ///
        /// Wait budgets have no implicit default because an accidental
        /// infinite wait can strand a process. Callers that
        /// accept no deadline spell `.unbounded` at construction.
        pub const Options = struct {
            frame_cap: usize = default_frame_cap,
            /// The floor of the one read-staging buffer shared by every wire
            /// whose resident copies rather than lends its received bytes.
            wire_buffer_bytes: usize = default_wire_buffer_bytes,
            /// Shared bound for transport connects and CapTP handshakes that
            /// have been admitted but have not yet opened. status-allow: pending state or quoted runtime label
            max_pending_opens: usize = default_max_pending_opens,
            /// The share of `max_pending_opens` that redeem dials a partner's
            /// handoffs induce may hold, so gives naming silent exporters
            /// leave accepts and the application's own dials room. Null is a
            /// quarter of the pool, at least one. Zero or a value above the
            /// pool is refused.
            max_pending_redeem_dials: ?usize = null,
            codec: model.CodecId = model.Preference.default_offer.codec,
            /// Offered CapTP profile. Version and codec negotiate as separate
            /// axes, so callers normally set both but neither implies the other.
            captp_version: model.CaptpVersion = model.Preference.default_offer.captp_version,
            /// Optional CapTP vocabulary negotiated independently per session.
            features: model.FeatureSet = model.Preference.default_offer.features,
            /// Deadline for a dial's transport connect and CapTP handshake,
            /// stamped once when the open starts. Redeem dials share it.
            handshake: Budget,
            /// Wall-clock deadline for externally paced listener construction.
            listener_setup: Budget = .{ .ms = default_listener_setup_ms },
            /// Deadline for blocking answer waits after a session opens.
            settle: Budget,
            /// Recipient only for failures produced after deterministic return
            /// ownership is gone. Explicit close barriers return their failure.
            unhandled_failure: ?FailureObserver = null,
            /// Dial retry policy the pump executes on staged resident dials
            /// (ADR-0030 policy, ADR-0018 execution): a transient fault parks
            /// the row until its interval elapses, then re-issues the dial on
            /// the same session. The defaults are the shared discovery budget.
            dial_retry: DialPolicy = .discovery(),
            /// Optional embedder metric recipient, one report per dial
            /// attempt outcome.
            dial_outcome: ?DialOutcomeObserver = null,
            /// Which face drives the runtime. The blocking face is the
            /// default. A step-driven embedder chooses `.stepped` here, with
            /// its recipients, and the readiness set exists from `init` on.
            drive: lifecycle.DriveOptions = .blocking,
            /// How long the runtime spins before it parks on its residents'
            /// descriptors, reaping each resident on every pass. Zero parks
            /// at once. A spinning runtime holds its CPU for the window and
            /// sees a cross-thread wake or settle only when the window ends
            /// or a resident has a record, so set it on a runtime that owns
            /// a core and wants the round trip's park gone, and bound it by
            /// the reply latency it expects. A caller's wait budget bounds
            /// the window too, and a window past `max_busy_poll_ns` is
            /// refused at adoption.
            busy_poll_ns: u64 = 0,

            /// The redeem-dial share the runtime holds: the caller's value when
            /// it fits the pool, else a quarter of the pool with a floor of one.
            pub fn redeemDialShare(self: Options) error{InvalidBufferConfiguration}!usize {
                const share = self.max_pending_redeem_dials orelse return @max(1, self.max_pending_opens / 4);
                if (share == 0 or share > self.max_pending_opens) return error.InvalidBufferConfiguration;
                return share;
            }
        };

        /// The longest busy-poll window a runtime accepts: a cross-thread
        /// settle or wake waits out the whole window, so a longer one is a
        /// stall and not a latency trade.
        pub const max_busy_poll_ns: u64 = 100 * std.time.ns_per_ms;

        /// Runtime-only controls for adopting an existing byte-fed Host. Core
        /// protocol/frame settings remain owned by that Host.
        pub const AdoptionOptions = struct {
            wire_buffer_bytes: usize = default_wire_buffer_bytes,
            max_pending_opens: usize = default_max_pending_opens,
            /// As `Options.max_pending_redeem_dials`.
            max_pending_redeem_dials: ?usize = null,
            handshake: Budget,
            listener_setup: Budget = .{ .ms = default_listener_setup_ms },
            settle: Budget,
            /// As `Options.busy_poll_ns`.
            busy_poll_ns: u64 = 0,
            /// As `Options.drive`. The loop archive adopts a Host stepped.
            drive: lifecycle.DriveOptions = .blocking,
        };

        pub const ProviderRegistrationError = std.mem.Allocator.Error || Error || driver_core.HostError || error{
            InvalidProviderPackage,
            ReadinessDescriptorConflict,
            ReadinessUnavailable,
            ReadinessUpdateFailed,
        };
        /// Policy selected by the process owner for work already admitted when
        /// an owning close begins.
        pub const PendingWork = driver_core.PendingWork;
        /// Deterministic outcome of the owning close barrier.
        pub const CloseOutcome = driver_core.CloseOutcome;
    };
}
