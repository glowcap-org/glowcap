//! The three position spaces a session keys on.
//!
//! Exports, imports, and answers each live in their own `u64` space, and on the
//! wire they collide: export position 5, import position 5, and answer 5 name
//! three unrelated slots in three different tables. The wire integers are the
//! same width and the same bytes, so a bare `u64` lets one be passed where
//! another is meant, and because the spaces overlap, the bug is a silent
//! mis-route, never a panic. The classic trap is keying an export-indexed map on
//! a partner-named import position: a coincidental collision then
//! misclassifies an ordinary deliver as a resolver callback.
//!
//! These newtypes make the distinction a compile-time fact. They are zero-cost
//! (`enum(u64)`, so a typed position is one machine word, the same as the wire
//! integer), distinct (you cannot pass an `ImportPosition` where an
//! `ExportPosition` is wanted), and hashable (an `AutoHashMap` keys on them
//! directly). Cross the
//! `u64` wire/ABI boundary with `from` on the way in and `int` on the way out.
//! The conversion is the visible seam where a raw wire integer becomes a typed
//! position, and there is nowhere else it can silently change identity.
//!
//! Scope: scalar position fields carry these types end to end (model, codec, session,
//! engine, view). The gc bulk position vectors stay `[]const u64`, they share
//! the borrowed view's `PositionList` machinery with raw refcount deltas, are
//! validated as one batch, and are decremented against a single table the
//! message arm already names, so a typed element would buy no safety the arm
//! does not already give.

/// A position in this peer's local export space, an object or promise this peer
/// hosts and a partner may import. `op:deliver` to a `desc:export` names one.
pub const ExportPosition = enum(u64) {
    _,

    pub fn from(n: u64) ExportPosition {
        return @fromBackingInt(@intCast(n));
    }

    pub fn int(self: ExportPosition) u64 {
        return @backingInt(self);
    }

    /// Re-tag this position as another space's, preserving the wire integer.
    /// The wire reuses one integer across the three spaces (see the module
    /// header): a `desc:export` that doubles as the resolver for an answer, a
    /// `.near` that names the answer it settles. This is the one explicit seam
    /// for that deliberate reuse, and, unlike `from`/`int`, it crosses no
    /// wire/ABI boundary, so a reader sees a kind change, not a round-trip.
    pub fn reinterpret(self: ExportPosition, comptime To: type) To {
        return To.from(self.int());
    }
};

/// A position in the import space, a partner's export this peer holds a proxy
/// for. `desc:import-object` / `desc:import-promise` name one.
pub const ImportPosition = enum(u64) {
    _,

    pub fn from(n: u64) ImportPosition {
        return @fromBackingInt(@intCast(n));
    }

    pub fn int(self: ImportPosition) u64 {
        return @backingInt(self);
    }

    /// Re-tag across position spaces. See `ExportPosition.reinterpret`.
    pub fn reinterpret(self: ImportPosition, comptime To: type) To {
        return To.from(self.int());
    }
};

/// A node-local route identity for a capability whose wire name belongs to a
/// particular session (ADR-0069). It is a different type from
/// `ImportPosition`: every `u64` remains a valid partner-selected import, while
/// a routed capability can never be mistaken for one or reach a codec without
/// an explicit lowering step.
pub const CapabilityRouteId = enum(u64) {
    _,

    pub fn from(n: u64) CapabilityRouteId {
        return @fromBackingInt(@intCast(n));
    }

    pub fn int(self: CapabilityRouteId) u64 {
        return @backingInt(self);
    }
};

/// A position in the answer space, the eventual result of a delivery, named by
/// the `answer` field of `op:deliver`/`op:resolve` and by `desc:answer`.
pub const AnswerPosition = enum(u64) {
    _,

    pub fn from(n: u64) AnswerPosition {
        return @fromBackingInt(@intCast(n));
    }

    pub fn int(self: AnswerPosition) u64 {
        return @backingInt(self);
    }

    /// Re-tag across position spaces. See `ExportPosition.reinterpret`.
    pub fn reinterpret(self: AnswerPosition, comptime To: type) To {
        return To.from(self.int());
    }
};

/// An answer synthesized for a V1.0 resolver-only call (ADR-0010). It is a
/// separate namespace from partner-selected wire answers, not a reserved band
/// within their `u64` space.
pub const VirtualAnswer = enum(u64) {
    _,

    pub fn from(n: u64) VirtualAnswer {
        return @fromBackingInt(@intCast(n));
    }

    pub fn int(self: VirtualAnswer) u64 {
        return @backingInt(self);
    }
};

/// The authoritative name of an inbound answer: either the partner's wire
/// position or a resolver-only answer synthesized by this session. Callers
/// construct the arm from provenance. No integer classification can confuse
/// the two independent namespaces.
pub const AnswerName = union(enum) {
    wire: AnswerPosition,
    virtual: VirtualAnswer,

    pub fn fromWire(position: AnswerPosition) AnswerName {
        return .{ .wire = position };
    }

    pub fn fromVirtual(answer: VirtualAnswer) AnswerName {
        return .{ .virtual = answer };
    }
};
