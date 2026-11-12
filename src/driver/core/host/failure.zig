//! Stable failure categories for byte-fed Host operations. The sans-I/O Host
//! owns this semantic classification. Adapters only project the category into
//! their public error vocabulary. It lives with the Host subject that owns it.

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

    /// The category for any failure a Host verb returns. Errors the Host
    /// does not name take the engine's protocol classification, and anything
    /// left is a library fault.
    pub fn classify(cause: anyerror) Kind {
        return named(cause) orelse switch (engine.abort_projection.classify(cause).domain) {
            .codec => .codec,
            .session => .session,
            .foreign => .internal,
        };
    }

    /// The category the Host names for `cause`, or null when the engine owns
    /// it. The driver consults the same table before its own rows
    /// (`driver.OperationFailure.classify`), so each name has one owner.
    pub fn named(cause: anyerror) ?Kind {
        inline for (named_rows) |row| {
            inline for (row.causes) |named_cause| if (cause == named_cause) return row.kind;
        }
        return null;
    }

    pub const Row = struct { kind: Kind, causes: []const anyerror };

    /// Every error the Host names, one row per category.
    /// `test/driver/core_host/failure_taxonomy_test.zig` holds every error a
    /// public Host verb returns to this table or the engine, and
    /// `test/c_abi/driver_loop/failure_taxonomy_test.zig` holds each row to
    /// one C code through the Host and driver archives.
    pub const named_rows = [_]Row{
        .{ .kind = .internal, .causes = &.{
            error.OutOfMemory,
            error.NoSpaceLeft,
            error.CapabilitySpaceExhausted,
            error.ResourceExhausted,
            error.RetainOverflow,
            error.EventServeOutOfMemory,
            error.PreparedSettlementConsumed,
        } },
        .{ .kind = .not_found, .causes = &.{
            error.CapabilityRouteUnavailable,
            error.NoSuchVow,
            error.NoSuchResolver,
            error.UnknownCapability,
            error.UnknownPublication,
            error.UnknownConnection,
            error.UnknownImport,
            error.UnknownIngress,
            error.UnknownPeer,
            error.RouteNotLowerable,
        } },
        .{
            .kind = .invalid_argument,
            .causes = &.{
                error.InvalidArgument,
                error.ReleaseExceedsRetains,
                error.AlreadyForwarded,
                error.ReenteredAdmission,
                error.ForeignWork,
                error.NoPendingWork,
                error.ForeignPublicationLookup,
                error.PublicationLookupInstalled,
                error.NotSnapshottable,
                error.UnsupportedDelivery,
                error.OpaqueHandlerRefused,
                error.ForeignHandlerRefused,
                error.ReservedHintName,
                error.UnknownCodec,
                error.UnparseableId,
                error.UnparseableExporterLocator,
                error.UnsupportedId,
                error.UnsupportedValue,
                error.InvalidLimits,
                error.Overflow,
                error.ReplyCapacity,
                error.OwningReplyRequired,
                error.ValueTooDeep,
                error.BufferTooSmall,
                error.OutboundOverflow,
                error.InvalidAddress,
                error.NoPendingAction,
                error.InvalidHostWorkQuantum,
                error.InvalidSessionLimit,
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
                error.InvalidSwissNumber,
                error.MalformedHint,
                error.InvalidLocator,
                error.MalformedPercentEncoding,
                error.UnsupportedUriComponent,
                error.InvalidTransportSymbol,
                error.EmptyDesignator,
                error.EmptyHintName,
                error.InvalidFalseHints,
                error.TooManyHints,
                error.DuplicateHintName,
                error.UnsupportedHintValue,
                error.UriParseError,
                error.InvalidHostPort,
                error.DesignatorNotHostPort,
                error.DesignatorNotPeerKey,
                error.ReachabilityRequired,
                error.SealedSessionBytesOnly,
                // A precondition the caller owns (release sessions and borrowed
                // actions first, or configure before any send), not a wait.
                error.HostNotQuiescent,
            },
        },
        .{ .kind = .closed, .causes = &.{
            error.SessionCondemned,
            error.SessionClosing,
            error.HostClosing,
            error.SealedChannelFailed,
            error.DecryptFailed,
            error.MessageTooShort,
            error.PayloadTooLong,
            error.NonceExhausted,
            error.IdentityElement,
            error.IdentityMismatch,
            error.HandshakeOutOfOrder,
            error.HandshakeNotComplete,
            error.InboundOverflow,
            error.PromiseBroken,
            error.PromiseNotPending,
            error.CapabilityClosed,
            error.EnlivenmentBroke,
            error.PeerGone,
            error.SessionNotOpen,
            error.VatReleased,
        } },
        .{ .kind = .would_block, .causes = &.{
            error.HandshakeIncomplete,
            error.OutboundBackpressure,
            error.SessionOperationLimitReached,
            error.SessionLimitReached,
            error.PromisePending,
            error.AnswerAlreadyPending,
            error.NotResolved,
            error.FetchCapacity,
            error.LookupCapacity,
            error.ConflictingDialPlan,
            error.Busy,
            error.IngressBusy,
            error.NotQuiescent,
            error.PublicationPending,
            error.ProxyRecipientCapExceeded,
        } },
        .{ .kind = .session, .causes = &.{
            error.PartnerUnverified,
            error.PeerIdentityUnverified,
            error.HandshakeAlreadyApplied,
            error.SendRejected,
            error.SturdyrefsNotNegotiated,
            error.MalformedKey,
            error.MalformedSignature,
            error.InvalidSignature,
        } },
        .{ .kind = .frame_too_large, .causes = &.{
            error.FrameTooLarge,
        } },
    };

    comptime {
        @setEvalBranchQuota(1_000_000);
        var seen: []const anyerror = &.{};
        for (named_rows) |row| for (row.causes) |cause| {
            for (seen) |prior| if (prior == cause) @compileError("the Host failure table names " ++ @errorName(cause) ++ " twice");
            seen = seen ++ &[_]anyerror{cause};
        };
    }
};
