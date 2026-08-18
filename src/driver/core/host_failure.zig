//! Stable failure categories for byte-fed Host operations. The sans-I/O Host
//! owns this semantic classification; adapters only project the category into
//! their public error vocabulary.

const std = @import("std");

const engine = @import("engine");

pub const HostFailure = struct {
    kind: Kind,
    cause: anyerror,

    pub const Kind = enum {
        invalid_argument,
        not_found,
        would_block,
        closed,
        session,
        codec,
        frame_too_large,
        internal,
    };

    pub fn fromError(cause: anyerror) HostFailure {
        return .{ .kind = classify(cause), .cause = cause };
    }

    pub fn classify(cause: anyerror) Kind {
        return switch (cause) {
            error.OutOfMemory => .internal,

            error.CapabilityRouteUnavailable,
            error.NoSuchVow,
            error.UnknownCapability,
            error.UnknownPublication,
            => .not_found,

            error.InvalidArgument,
            error.DurableBootstrapUnavailable,
            error.InvalidHostWorkQuantum,
            error.ReservedDurableNamespace,
            error.NotDurableName,
            error.DurableNameCollision,
            error.UnknownTransport,
            error.TransportSemanticsConflict,
            error.TransportAlreadyRegistered,
            error.InvalidTransportName,
            error.ReenteredHost,
            error.WrongThread,
            error.SettleInTurn,
            error.SessionlessVow,
            error.NotALocalVow,
            error.PeerIdentityMismatch,
            error.ForeignSession,
            error.ForeignArgument,
            error.ForeignTurn,
            error.NoAnswer,
            error.ImportKindConflict,
            error.NoUnliftedImportRetain,
            error.InvalidChannelKey,
            error.ChannelKeyConflict,
            error.UnheldIdentity,
            error.MissingDirectAddressesHint,
            error.MissingAdvertisedLocator,
            error.SessionPairExists,
            error.UncallableTarget,
            error.NotPipelineable,
            error.NoSuchActor,
            error.AlreadyListening,
            error.AlreadySettled,
            error.NotLocal,
            error.NotConnected,
            error.AlreadyPublished,
            error.NotNearCallable,
            error.NearCallTooDeep,
            error.NotOcapnUri,
            error.MissingTransport,
            error.EmptyComponent,
            error.MalformedPath,
            error.MalformedHint,
            error.DuplicateHintName,
            error.UnsupportedHintValue,
            error.UriParseError,
            error.InvalidHostPort,
            error.DesignatorNotHostPort,
            error.DesignatorNotPeerKey,
            error.ReachabilityRequired,
            error.SealedSessionBytesOnly,
            => .invalid_argument,

            error.SessionCondemned,
            error.SessionClosing,
            error.HostClosing,
            error.SealedChannelFailed,
            error.PromiseBroken,
            => .closed,

            error.HandshakeIncomplete,
            error.OutboundBackpressure,
            error.SessionOperationLimitReached,
            error.PromisePending,
            => .would_block,

            error.PartnerUnverified,
            error.PeerIdentityUnverified,
            error.HandshakeAlreadyApplied,
            error.SendRejected,
            => .session,

            error.FrameTooLarge => .frame_too_large,

            else => switch (engine.abort_projection.classify(cause).domain) {
                .codec => .codec,
                .session => .session,
                .foreign => .internal,
            },
        };
    }
};
