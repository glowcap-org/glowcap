//! Stable failure categories for Zig driver operations. The I/O-owning
//! driver classifies failures. Observers project the category into their
//! public error vocabulary without reinterpreting Zig error names.

const foundation = @import("foundation");
const net = @import("net");
const engine = @import("engine");
const HostFailure = @import("driver_core").HostFailure;

/// A `foundation.FailureChain` whose primary cause is always classified,
/// with the carrier phase the selected transport named, when it named one.
/// The same shape as `net.netlayer.DialFailure`, one tier up.
pub const OperationFailure = struct {
    /// The retained causes. `classification` is set on every value this
    /// file builds, and so is the first consequence's when this file noted
    /// it. A chain adopted by `fromChain` keeps its own consequence
    /// classification, which may be absent.
    chain: foundation.FailureChain,
    /// Neutral carrier phase, when the selected transport supplied one.
    /// Lifecycle identity stays with the operation/event that owns this value.
    carrier_phase: ?net.carrier_failure.Phase = null,
    carrier_detail: net.carrier_failure.Detail = .{},

    pub const Kind = foundation.FailureClassification;

    pub fn fromError(cause: anyerror) OperationFailure {
        return .{ .chain = classified(.init(cause)) };
    }

    pub fn fromChain(failure: foundation.FailureChain) OperationFailure {
        return .{ .chain = classified(failure) };
    }

    pub fn fromDialFailure(failure: net.netlayer.DialFailure) OperationFailure {
        return fromTransportFailure(failure);
    }

    pub fn fromAcceptFailure(failure: net.netlayer.AcceptFailure) OperationFailure {
        return fromTransportFailure(failure);
    }

    /// A transport failure's chain, classified by the transport's own
    /// classification, with its carrier phase.
    fn fromTransportFailure(failure: anytype) OperationFailure {
        var chain = failure.chain;
        chain.classification = classify(failure.classification);
        return .{ .chain = chain, .carrier_phase = failure.carrier_phase, .carrier_detail = failure.carrier_detail };
    }

    /// Only the transport registry can name an absent dialer. Diagnostic names
    /// and cleanup consequences never change the primary route classification.
    pub fn routeFailure(self: OperationFailure) engine.RouteFailure {
        return foundation.break_cause.namedRouteFailure(self.chain.cause) orelse .peer_unreachable;
    }

    /// The typed local cause a caller outside Zig can read, or none when the
    /// registry named nothing. Unlike `routeFailure`, an unnamed failure claims
    /// no route outcome.
    pub fn namedCause(self: OperationFailure) foundation.break_cause.BreakCause {
        const route = foundation.break_cause.namedRouteFailure(self.chain.cause) orelse return .{};
        return route.cause();
    }

    pub fn kind(self: OperationFailure) Kind {
        return self.chain.classification orelse classify(self.chain.cause);
    }

    pub fn note(self: *OperationFailure, consequence: anyerror) void {
        self.chain.noteChain(classified(.init(consequence)));
    }

    pub fn noteNamed(self: *OperationFailure, consequence: anyerror, name: []const u8) void {
        self.chain.noteChain(classified(.initNamed(consequence, name)));
    }

    pub fn noteChain(self: *OperationFailure, later: foundation.FailureChain) void {
        self.chain.noteChain(classified(later));
    }

    pub fn noteFailure(self: *OperationFailure, later: OperationFailure) void {
        self.chain.noteChain(later.chain);
    }

    /// `chain` with its primary cause classified, by `classify` when the
    /// chain carried none.
    fn classified(chain: foundation.FailureChain) foundation.FailureChain {
        var out = chain;
        if (out.classification == null) out.classification = classify(out.cause);
        return out;
    }

    /// The category for `cause`. A name the Host table lists takes the Host's
    /// category (`driver_core.HostFailure.named_rows`), so one error reads
    /// the same through the Host and driver fronts. The driver's own rows
    /// name only what the Host does not, and anything left is a transport
    /// diagnostic, because provider error sets are open to the driver.
    pub fn classify(cause: anyerror) Kind {
        if (HostFailure.named(cause)) |host_kind| return fromHost(host_kind);
        inline for (driver_rows) |row| {
            inline for (row.causes) |driver_cause| if (cause == driver_cause) return row.kind;
        }
        return .io;
    }

    /// A Host category in the driver vocabulary. The Host table names no
    /// codec failure (the engine owns those), and the C taxonomy test holds
    /// every Host row to one C code through both fronts.
    fn fromHost(host_kind: HostFailure.Kind) Kind {
        return switch (host_kind) {
            .invalid_argument => .invalid_argument,
            .not_found => .not_found,
            .would_block => .would_block,
            .closed => .closed,
            .session => .session,
            .codec => .malformed,
            .frame_too_large => .frame_too_large,
            .internal => .internal,
        };
    }

    const Row = struct { kind: Kind, causes: []const anyerror };

    /// The errors the driver names and the Host does not.
    const driver_rows = [_]Row{
        .{ .kind = .internal, .causes = &.{error.IdentifierExhausted} },
        .{ .kind = .invalid_argument, .causes = &.{
            error.InvalidOptions,
            error.InvalidProviderPackage,
            error.ProviderContract,
            error.ProviderConfigurationConflict,
            error.DesignatorUnavailable,
            error.ListenerAlreadyActive,
            error.ListenerProfileInUse,
            error.ReadinessDescriptorConflict,
            error.ReadinessUnavailable,
            error.SessionNotOwned,
            error.SessionAlreadyOwned,
            error.InvalidBufferConfiguration,
            error.BusyPollWindowTooLong,
        } },
        .{ .kind = .would_block, .causes = &.{
            error.PendingOpenLimitReached,
            error.WouldBlock,
        } },
        .{ .kind = .timeout, .causes = &.{
            error.HandshakeTimedOut,
            error.WaitTimedOut,
            error.CloseTimedOut,
            error.ListenerSetupTimedOut,
        } },
        .{ .kind = .closed, .causes = &.{
            error.ConnectionClosed,
            error.Canceled,
        } },
        .{ .kind = .session, .causes = &.{error.ProtocolAbort} },
        .{ .kind = .malformed, .causes = &.{
            error.TruncatedFrame,
            error.MalformedFrame,
        } },
        .{ .kind = .io, .causes = &.{error.ConnectionLost} },
    };

    comptime {
        // One owner per name: a driver row the Host table also lists would
        // never be read.
        @setEvalBranchQuota(1_000_000);
        for (driver_rows) |row| for (row.causes) |cause| {
            if (HostFailure.named(cause) != null) @compileError("the Host failure table owns " ++ @errorName(cause));
        };
    }
};
