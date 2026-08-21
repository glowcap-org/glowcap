//! Actor/Vat failure taxonomy shared by the internal responsibility owners.

const std = @import("std");

pub const Error = error{
    /// A `Ref` named no actor in this vat.
    NoSuchActor,
    /// A near-call (`near` / `$`) was made to a far ref.
    NotNearCallable,
    /// A wire projection was asked to bind a non-local actor.
    NotLocal,
    /// A far send used the bare Vat rather than a session Port.
    NotConnected,
    /// An export position is already authoritative for another actor.
    AlreadyPublished,
    /// A one-shot vow already holds a listener.
    AlreadyListening,
    /// A turn already handed its answer to another outcome.
    AlreadyForwarded,
    /// The session peer refused an outbound operation.
    SendRejected,
    /// Synchronous near-calls exceeded the bounded local stack depth.
    NearCallTooDeep,
    /// Snapshot or restore requires a quiescent Vat.
    NotQuiescent,
    /// A mutable actor offers neither snapshot clone nor persistence.
    NotSnapshottable,
    /// A local vow has already reached its one terminal outcome.
    AlreadySettled,
    /// A local value tree exceeded the model depth/shape contract.
    MalformedView,
    /// Ingress admission exceeded its turn, byte, or chunk limit.
    ResourceExhausted,
    /// Resolver settlement is a top-level event, never part of an actor turn.
    SettleInTurn,
    /// The ingress was not minted by this Vat or has already closed.
    UnknownIngress,
    /// An ingress cannot close while turns remain queued or active.
    IngressBusy,
} || std.mem.Allocator.Error;

/// Cancellation is allocation-free and refuses only an absent or active
/// ingress; queued ownership was reserved at admission.
pub const IngressCancellationError = error{
    UnknownIngress,
    IngressBusy,
};
