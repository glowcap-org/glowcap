//! Stable failure categories for Zig driver operations. The I/O-owning
//! driver classifies failures. Observers project the category into their
//! public error vocabulary without reinterpreting Zig error names.

const foundation = @import("foundation");
const net = @import("net");

pub const OperationFailure = struct {
    kind: Kind,
    cause: anyerror,
    /// Optional archive-crossing name for `cause`. The bytes must remain
    /// valid for the failure owner's lifetime. Ordinary Zig failures use the
    /// error set's static name and leave this null.
    cause_name: ?[]const u8 = null,
    secondary_cause: ?anyerror = null,
    secondary_cause_name: ?[]const u8 = null,
    secondary_kind: ?Kind = null,
    secondary_count: u16 = 0,
    /// Neutral carrier phase, when the selected transport supplied one.
    /// Lifecycle identity stays with the operation/event that owns this value.
    carrier_phase: ?net.carrier_failure.Phase = null,
    carrier_detail: net.carrier_failure.Detail = .{},

    pub const Kind = enum {
        invalid_argument,
        would_block,
        timeout,
        closed,
        session,
        malformed,
        frame_too_large,
        internal,
        io,
    };

    pub fn fromError(cause: anyerror) OperationFailure {
        return .{ .kind = classify(cause), .cause = cause };
    }

    pub fn fromChain(failure: foundation.FailureChain) OperationFailure {
        return .{
            .kind = if (failure.classification) |classification| fromClassification(classification) else classify(failure.cause),
            .cause = failure.cause,
            .cause_name = failure.cause_name,
            .secondary_cause = failure.secondary_cause,
            .secondary_cause_name = failure.secondary_cause_name,
            .secondary_kind = if (failure.secondary_classification) |classification| fromClassification(classification) else null,
            .secondary_count = failure.secondary_count,
        };
    }

    pub fn fromDialFailure(failure: net.netlayer.DialFailure) OperationFailure {
        var projected = fromChain(failure.chain);
        projected.kind = classify(failure.classification);
        projected.carrier_phase = failure.carrier_phase;
        projected.carrier_detail = failure.carrier_detail;
        return projected;
    }

    pub fn fromAcceptFailure(failure: net.netlayer.AcceptFailure) OperationFailure {
        var projected = fromChain(failure.chain);
        projected.kind = classify(failure.classification);
        projected.carrier_phase = failure.carrier_phase;
        projected.carrier_detail = failure.carrier_detail;
        return projected;
    }

    /// Return the neutral failure value behind this driver projection. This is
    /// used when an adapter must attach a later driver-owned cleanup outcome to
    /// the provider chain that triggered it. It does not reinterpret either
    /// cause or ordering.
    pub fn toChain(self: OperationFailure) foundation.FailureChain {
        return .{
            .cause = self.cause,
            .cause_name = self.cause_name,
            .classification = toClassification(self.kind),
            .secondary_cause = self.secondary_cause,
            .secondary_cause_name = self.secondary_cause_name,
            .secondary_classification = if (self.secondary_kind) |kind| toClassification(kind) else null,
            .secondary_count = self.secondary_count,
        };
    }

    pub fn primaryName(self: OperationFailure) []const u8 {
        return self.cause_name orelse @errorName(self.cause);
    }

    pub fn secondaryName(self: OperationFailure) ?[]const u8 {
        const cause = self.secondary_cause orelse return null;
        return self.secondary_cause_name orelse @errorName(cause);
    }

    pub fn namePrimary(self: *OperationFailure, name: []const u8) void {
        self.cause_name = name;
    }

    pub fn note(self: *OperationFailure, consequence: anyerror) void {
        if (self.secondary_cause == null) {
            self.secondary_cause = consequence;
            self.secondary_kind = classify(consequence);
        }
        self.secondary_count +|= 1;
    }

    pub fn noteNamed(self: *OperationFailure, consequence: anyerror, name: []const u8) void {
        if (self.secondary_cause == null) {
            self.secondary_cause = consequence;
            self.secondary_cause_name = name;
            self.secondary_kind = classify(consequence);
        }
        self.secondary_count +|= 1;
    }

    pub fn noteChain(self: *OperationFailure, later: foundation.FailureChain) void {
        if (later.classification) |classification| {
            if (self.secondary_cause == null) {
                self.secondary_cause = later.cause;
                self.secondary_cause_name = later.cause_name;
                self.secondary_kind = fromClassification(classification);
            }
            self.secondary_count +|= 1;
        } else if (later.cause_name) |name|
            self.noteNamed(later.cause, name)
        else
            self.note(later.cause);
        self.secondary_count +|= later.secondary_count;
    }

    pub fn noteFailure(self: *OperationFailure, later: OperationFailure) void {
        if (self.secondary_cause == null) {
            self.secondary_cause = later.cause;
            self.secondary_cause_name = later.cause_name;
            self.secondary_kind = later.kind;
        }
        self.secondary_count +|= 1;
        self.secondary_count +|= later.secondary_count;
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
            => .invalid_argument,

            error.PendingOpenLimitReached,
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
            error.OutboundAnswerSpaceExhausted,
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

    pub fn fromClassification(classification: foundation.FailureClassification) Kind {
        return switch (classification) {
            .invalid_argument => .invalid_argument,
            .would_block => .would_block,
            .timeout => .timeout,
            .closed => .closed,
            .session => .session,
            .malformed => .malformed,
            .frame_too_large => .frame_too_large,
            .internal => .internal,
            .io => .io,
        };
    }

    fn toClassification(kind: Kind) foundation.FailureClassification {
        return switch (kind) {
            .invalid_argument => .invalid_argument,
            .would_block => .would_block,
            .timeout => .timeout,
            .closed => .closed,
            .session => .session,
            .malformed => .malformed,
            .frame_too_large => .frame_too_large,
            .internal => .internal,
            .io => .io,
        };
    }
};
