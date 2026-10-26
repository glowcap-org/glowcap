//! Stable failure categories for Zig driver operations. The I/O-owning
//! driver classifies failures. Observers project the category into their
//! public error vocabulary without reinterpreting Zig error names.

const foundation = @import("foundation");
const net = @import("net");

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

    pub fn classify(cause: anyerror) Kind {
        return switch (cause) {
            error.OutOfMemory,
            error.IdentifierExhausted,
            => .internal,

            error.InvalidArgument,
            error.InvalidOptions,
            error.InvalidProviderPackage,
            error.ProviderContract,
            error.ProviderConfigurationConflict,
            error.UnknownTransport,
            error.TransportSemanticsConflict,
            error.TransportAlreadyRegistered,
            error.InvalidTransportName,
            error.InvalidAddress,
            error.DesignatorUnavailable,
            error.ListenerAlreadyActive,
            error.ListenerProfileInUse,
            error.ReadinessDescriptorConflict,
            error.ReadinessUnavailable,
            error.MissingAdvertisedLocator,
            error.HostNotQuiescent,
            error.ReenteredHost,
            error.WrongThread,
            error.SessionNotOwned,
            error.SessionAlreadyOwned,
            error.InvalidBufferConfiguration,
            error.BusyPollWindowTooLong,
            error.InvalidHostWorkQuantum,
            error.InvalidSessionLimit,
            => .invalid_argument,

            error.PendingOpenLimitReached,
            error.SessionLimitReached,
            error.WouldBlock,
            error.SessionOperationLimitReached,
            => .would_block,

            error.HandshakeTimedOut,
            error.WaitTimedOut,
            error.CloseTimedOut,
            error.ListenerSetupTimedOut,
            => .timeout,

            error.ConnectionClosed,
            error.SessionCondemned,
            error.SessionClosing,
            error.HostClosing,
            error.Canceled,
            => .closed,

            error.ProtocolAbort,
            => .session,
            error.TruncatedFrame,
            error.MalformedFrame,
            => .malformed,
            error.FrameTooLarge => .frame_too_large,

            error.ConnectionLost => .io,

            // Provider error sets are open to the driver. Errors not minted by
            // the driver itself therefore remain transport/I/O diagnostics.
            else => .io,
        };
    }
};
