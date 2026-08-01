//! The three position spaces a session keys on.
//!
//! Exports, imports, and answers each live in their own `u64` space, and on the
//! wire they collide: export position 5, import position 5, and answer 5 name
//! three unrelated slots in three different tables. The wire integers are the
//! same width and the same bytes, so a bare `u64` lets one be passed where
//! another is meant — and because the spaces overlap, the bug is a silent
//! mis-route, never a panic. The classic trap is keying an export-indexed map on
//! a partner-named import position: a coincidental collision then
//! misclassifies an ordinary deliver as a resolver callback.
//!
//! These newtypes make the distinction a compile-time fact. They are zero-cost
//! (`enum(u64)`, so a typed position is one machine word, the same as the wire
//! integer), distinct (you cannot pass an `ImportPosition` where an
//! `ExportPosition` is wanted), and hashable (an `AutoHashMap` keys on them
//! directly). Cross the
//! `u64` wire/ABI boundary with `from` on the way in and `int` on the way out;
//! the conversion is the visible seam where a raw wire integer becomes a typed
//! position, and there is nowhere else it can silently change identity.
//!
//! Scope: scalar position fields carry these types end to end (model, codec, session,
//! engine, view). The gc bulk position vectors stay `[]const u64` — they share
//! the borrowed view's `PositionList` machinery with raw refcount deltas, are
//! validated as one batch, and are decremented against a single table the
//! message arm already names, so a typed element would buy no safety the arm
//! does not already give.

/// A position in this peer's local export space, an object or promise this peer
/// hosts and a partner may import. `op:deliver` to a `desc:export` names one.
pub const ExportPosition = enum(u64) {
    _,

    pub fn from(n: u64) ExportPosition {
        return @enumFromInt(n);
    }

    pub fn int(self: ExportPosition) u64 {
        return @intFromEnum(self);
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
        return @enumFromInt(n);
    }

    pub fn int(self: ImportPosition) u64 {
        return @intFromEnum(self);
    }

    /// Re-tag across position spaces. See `ExportPosition.reinterpret`.
    pub fn reinterpret(self: ImportPosition, comptime To: type) To {
        return To.from(self.int());
    }
};

/// The base of the reserved band inside the import space (ADR-0069). At and
/// above this, an id is one this node minted for a capability reached through
/// a redeemed handoff; below it, the partner named it on the wire.
///
/// It lives here, beside the space it partitions, rather than with the first
/// layer that needed it. Both `session` and `engine` hold ids from this band,
/// and `session` cannot import `engine`, so neither of them can own the
/// boundary the other reads.
pub const REDEEMED_TOKEN_BASE: u64 = 1 << 60;

/// An id this node minted above `REDEEMED_TOKEN_BASE` for a capability reached
/// through a redeemed handoff (ADR-0069). It routes to the session that
/// exported the capability, not to the one that named it.
pub const RedeemedToken = enum(u64) {
    _,

    pub fn int(self: RedeemedToken) u64 {
        return @intFromEnum(self);
    }

    /// The wire spelling, for the one place a token is lowered onto a session
    /// that can name it. Named rather than `int()` so the sites that put a
    /// token near the wire are greppable.
    pub fn wirePosition(self: RedeemedToken) ImportPosition {
        return ImportPosition.from(self.int());
    }
};

/// What an id in the import space names: a position the partner chose, or a
/// token this node minted.
///
/// The distinction decides where a message routes, so it is the type's job
/// rather than each reader's. `classify` is the only way to hold one, which
/// means a consumer cannot forget to ask; the switch is exhaustive, so the
/// compiler asks at every site; and a band carved later becomes a compile
/// error rather than a silent fallthrough (ADR-0091).
pub const ImportName = union(enum) {
    wire: ImportPosition,
    token: RedeemedToken,

    /// The single seam. An integer becomes a name here or nowhere.
    pub fn classify(id: u64) ImportName {
        return if (id >= REDEEMED_TOKEN_BASE)
            .{ .token = @enumFromInt(id) }
        else
            .{ .wire = ImportPosition.from(id) };
    }

    /// Classify the import an arbitrary reference names, or null when it names
    /// no import at all (a near, a promise, a sturdyref).
    pub fn of(reference: anytype) ?ImportName {
        return switch (reference) {
            .far => |far| classify(far.import_position.int()),
            else => null,
        };
    }

    pub fn int(self: ImportName) u64 {
        return switch (self) {
            .wire => |w| w.int(),
            .token => |t| t.int(),
        };
    }
};

/// A position in the answer space, the eventual result of a delivery, named by
/// the `answer` field of `op:deliver`/`op:resolve` and by `desc:answer`.
pub const AnswerPosition = enum(u64) {
    _,

    pub fn from(n: u64) AnswerPosition {
        return @enumFromInt(n);
    }

    pub fn int(self: AnswerPosition) u64 {
        return @intFromEnum(self);
    }

    /// Re-tag across position spaces. See `ExportPosition.reinterpret`.
    pub fn reinterpret(self: AnswerPosition, comptime To: type) To {
        return To.from(self.int());
    }
};
