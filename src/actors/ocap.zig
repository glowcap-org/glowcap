//! Object-capability forwarding proxies on the actor layer: a *caretaker* (a
//! revocable forwarder) and an *attenuator* (a verb-allow-list forwarder).
//!
//! Both are forwarding proxies built on `Turn.forward`, so they wrap any
//! reference the holder has, local *or* far. That is the point: handing a
//! partner an attenuated or revocable view of a capability you imported over the
//! wire is the core move of capability networking, and these make the two
//! commonest shapes one call (ADR-0016). They compose, put a caretaker over an
//! attenuator's proxy for a revocable, read-only view, because each is just an
//! actor whose handle forwards (or refuses) and whose proxy is an ordinary
//! `Ref` you delegate like any other.
//!
//! Refusals are typed breaks: a revoked caretaker breaks every call with
//! `Revoked`, an attenuator breaks an out-of-list verb with `Attenuated`. Over
//! the wire those surface to the partner as a broken answer. In-process they
//! propagate from `near`. The refused authority is *unrepresentable*, not
//! permission-checked after the fact, an attenuated reference cannot express a
//! verb it does not forward.

const std = @import("std");
const model = @import("model");
const boxed = @import("vat/boxed.zig");
const vat_mod = @import("vat/mod.zig");

const Vat = vat_mod.Vat;
const Ref = vat_mod.Ref;
const Turn = vat_mod.Turn;
const Delivery = vat_mod.Delivery;

pub const Error = error{
    /// A call reached a caretaker whose authority was revoked.
    Revoked,
    /// A call named a verb the attenuator does not forward.
    Attenuated,
};

/// A caretaker: a forwarding proxy you can switch off. Hand `proxy` to a
/// partner. Keep the `Caretaker` and call `revoke` to sever it. Until revoked
/// the proxy forwards every call to its target (local or far). After, every call
/// through `proxy` breaks with `Revoked`. The flag is the proxy actor's own
/// state, so a vat holding a caretaker is not snapshottable: revocation is
/// authority, and a rewound heap must not quietly restore it.
pub const Caretaker = struct {
    /// The reference to delegate. Forwards to the target until revoked.
    proxy: Ref,

    /// Sever the proxy: subsequent calls through it break with `Revoked`.
    /// Idempotent, and a proxy row the vat already dropped has nothing to
    /// sever.
    pub fn revoke(self: Caretaker, vat: *Vat) void {
        const cell = vat.actors.getPtr(self.proxy.local) orelse return;
        std.debug.assert(cell.box.kind == boxed.StateBox.Kind.of(CaretakerActor));
        // A clone-less mutable box is never shared with a snapshot.
        std.debug.assert(cell.box.refs == 1);
        const state: *CaretakerActor = @ptrCast(@alignCast(cell.box.ptr));
        state.live = false;
    }
};

const CaretakerActor = struct {
    target: Ref,
    live: bool = true,

    pub fn handle(self: *CaretakerActor, turn: *Turn, msg: Delivery) !model.Argument {
        if (!self.live) return error.Revoked;
        return turn.forward(self.target, msg);
    }
};

const AttenuatorActor = struct {
    target: Ref,
    /// The forwarded verbs, owned: each is a copy, freed in `deinit`.
    allowed: []const []const u8,

    pub fn handle(self: *AttenuatorActor, turn: *Turn, msg: Delivery) !model.Argument {
        for (self.allowed) |verb| {
            if (msg.is(verb)) return turn.forward(self.target, msg);
        }
        return error.Attenuated;
    }

    pub fn deinit(self: *AttenuatorActor, allocator: std.mem.Allocator) void {
        for (self.allowed) |verb| allocator.free(verb);
        allocator.free(self.allowed);
    }
};

/// Spawn a caretaker over `target`: a revocable forwarding view. Returns the
/// proxy to delegate and the lever to revoke it. The proxy forwards to `target`
/// (which may be a far reference), so this hands out a revocable view of a
/// capability the holder need not own locally.
pub fn caretaker(vat: *Vat, target: Ref) !Caretaker {
    return .{ .proxy = try vat.spawn(CaretakerActor, .{ .target = target }) };
}

/// Spawn an attenuator over `target`: a forwarder that passes only the verbs in
/// `allowed` and breaks every other call with `Attenuated`. `allowed` is copied,
/// so the caller's slice need not outlive this call. Returns the proxy to
/// delegate. `target` may be far, so this hands out a narrowed view of an
/// imported capability.
pub fn attenuate(vat: *Vat, target: Ref, allowed: []const []const u8) !Ref {
    const owned = try vat.allocator.alloc([]const u8, allowed.len);
    for (allowed, 0..) |verb, i| {
        owned[i] = vat.allocator.dupe(u8, verb) catch |e| {
            for (owned[0..i]) |done| vat.allocator.free(done);
            vat.allocator.free(owned);
            return e;
        };
    }
    // Ownership of `owned` and its verbs transfers to the actor, which frees
    // them in `deinit`; `spawn` reclaims them through that same `deinit` if it
    // fails (makeBox contract).
    return vat.spawn(AttenuatorActor, .{ .target = target, .allowed = owned });
}
