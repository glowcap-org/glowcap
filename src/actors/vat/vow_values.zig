//! The values a send and its vow carry: the `Ref` a send targets, the `Vow`
//! it returns, the reservations that make listener and resolver installation
//! infallible, and the `Resolution` a listener receives. `mod.zig` re-exports
//! each one.

const std = @import("std");
const model = @import("model");
const engine = @import("engine");

/// A reference a `Port` can eventual-send to, wherever the object lives.
pub const Ref = union(enum) {
    /// An actor in this vat. `near` and `send` run its turns here.
    local: u64,
    /// A partner-hosted object the Port's peer holds as an import. `Port.send`
    /// routes to it as an `op:deliver`. `near` and bare `Vat.send` refuse it.
    far: model.FarRef,
};

/// A handle to the eventual result of a send, the vow of E/Goblins:
/// unsettled until the turn runs or the partner resolves, observed with
/// `Vat.on` for local vows or `Port.on` for far vows.
pub const Vow = union(enum) {
    /// Result of a local send. Settled by `Vat.drive`. A resolver vow
    /// (`Vat.spawnVow`, ADR-0014) shares this arm and namespace and is
    /// settled by `Vat.fulfillVow` / `Vat.breakVow` instead.
    local: u64,
    /// Result of a far send: the question the partner resolves, by identity.
    /// The session reuses a released answer position, so the vow carries the
    /// stamp of the row it names and a stale vow observes nothing.
    far: engine.OutboundAnswerTarget,
};

/// Which settlement namespace a freshly minted vow will occupy. Exposed so
/// adapters can reserve the matching one-shot listener slot before they commit
/// the send that creates the vow. The reservation makes listener installation
/// infallible after that semantic commit.
pub const VowLocation = std.meta.Tag(Vow);

/// Capacity for one future listener in exactly one settlement namespace.
/// Obtained from `Port.reserveListener` and consumed by `Port.onReserved`.
pub const ListenerReservation = struct {
    location: VowLocation,
};

/// A resolver pair (ADR-0014): the vow is the read side, the resolver id is
/// the settle authority, and neither confers the other. The resolver id lives
/// in the minting vat's namespace and dies with it.
pub const ResolverPair = struct {
    vow: Vow,
    resolver: u64,
};

/// Capacity for one resolver pair in both Vat indexes, and the ids the pair
/// will take. The pair does not exist until `spawnReservedVow` consumes this
/// reservation, so an adapter can reserve its own rows first and make the
/// cross-layer commit allocation-free.
pub const ResolverPairReservation = struct { vow: u64, resolver: u64 };

/// How a vow settled. The carried value (`fulfilled` argument or `broken`
/// message) is borrowed only for the duration of the listener call. A listener
/// that retains it copies first.
pub const Resolution = union(enum) {
    fulfilled: model.Argument,
    broken: engine.Broken,
    /// The vow fulfilled with a three-party introduction: a signed
    /// `desc:handoff-give` the holder redeems (dial the exporter, withdraw)
    /// before the capability is usable. A host tier claims and redeems every
    /// give itself, so this arm surfaces only below it, on the
    /// single-session surfaces. Like `fulfilled`, the payload is borrowed
    /// for the listener call.
    give: Give,
};

/// How a vow settled with no introduction: `Resolution` minus `give`. A
/// resolver settle, a queued turn's completion, and the settlement a host
/// tier feeds `Port.settleFar` all carry one, because the executor above the
/// vat redeems every give before the vat sees it, and only the wire resolve
/// arm of `Port.serve` widens it. The payload is borrowed for the listener
/// call, exactly as `Resolution`'s is.
pub const Outcome = union(enum) {
    fulfilled: model.Argument,
    broken: engine.Broken,

    pub fn resolution(self: Outcome) Resolution {
        return switch (self) {
            .fulfilled => |value| .{ .fulfilled = value },
            .broken => |reason| .{ .broken = reason },
        };
    }
};

/// A projected three-party introduction, built where the wire event is still
/// in hand so the verbatim signed envelope survives (a decoded argument alone
/// cannot recover it).
pub const Give = struct {
    /// The verbatim signed `desc:handoff-give` envelope, relayed unaltered to
    /// the exporter inside the recipient's `desc:handoff-receive`.
    give_bytes: []const u8,
    /// The give's exporter location as a dialable `ocapn://…` URI, or empty
    /// when the location is not dialable.
    exporter_locator_uri: []const u8,
    /// The recipient session key the give is addressed to. The withdraw must
    /// sign with its secret half.
    recipient_key: []const u8,
};

/// A one-shot vow listener: `func(ctx, resolution)` fires when the vow
/// settles. `ctx` is the caller's opaque state (or null).
pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, resolution: Resolution) void,
};
