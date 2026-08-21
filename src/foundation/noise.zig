//! The `Noise_XK_25519_ChaChaPoly_BLAKE2s` state machine ADR-0107's sealed
//! channel speaks: handshake, transport ciphers, and the sealed-record
//! framing, over caller buffers.
//!
//! This is the one Noise pattern the design needs, written out directly
//! rather than behind a generic pattern table. `XK` fits because a key
//! designator hands the dialer the responder's static key before the first
//! byte, and because the initiator's identity travels in the third message
//! under ephemeral-derived keys, so a recorded transcript plus a later key
//! compromise reveals nothing about who dialed.
//!
//! Like the rest of `foundation`, it is pure math: no allocation, no I/O, no
//! entropy. An ephemeral key is built from a 32-byte seed the caller supplies,
//! the same door the published test vectors inject through, and it builds for
//! `wasm32` as-is. Key conversion from durable Ed25519 identities lives in
//! `crypto.zig`; everything here works in raw X25519 material.
//!
//! Callers are `foundation.sealed.SealedChannel` (the composition the
//! byte-fed Host boxes per sealed session and the completion-loop sealing
//! adapter embeds) and the cacophony vectors in
//! `test/foundation/noise_test.zig`. Nothing else imports this module.

const std = @import("std");

const crypto = @import("crypto.zig");

const Blake2s = std.crypto.hash.blake2.Blake2s256;
const Hmac = std.crypto.auth.hmac.Hmac(Blake2s);
const Hkdf = std.crypto.kdf.hkdf.Hkdf(Hmac);
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const X25519 = std.crypto.dh.X25519;

/// The protocol name the symmetric state is seeded with, exactly as the Noise
/// specification spells it.
pub const protocol_name = "Noise_XK_25519_ChaChaPoly_BLAKE2s";

/// Width in bytes of an X25519 key, a chaining key, and a BLAKE2s digest.
pub const KEY_BYTES: usize = 32;

/// Width in bytes of the AEAD authentication tag on every sealed payload.
pub const TAG_BYTES: usize = 16;

/// The Noise ceiling on one whole handshake or transport message.
pub const MAX_MESSAGE_BYTES: usize = 65535;

/// A raw X25519 pair, re-exported so a caller holding durable keys converts
/// once in `crypto.zig` and hands the result straight in.
pub const KeyPair = crypto.X25519KeyMaterial;

/// The ways the state machine can refuse. Everything an attacker can reach
/// arrives through `readMessage` or `CipherState.decrypt`, and both fail
/// closed with a typed reason; the rest guard caller arithmetic.
pub const NoiseError = error{
    /// An AEAD tag did not verify. The message was forged, replayed under the
    /// wrong key, or corrupted; the receiving state did not advance.
    DecryptFailed,
    /// An inbound handshake message is shorter than its fixed layout.
    MessageTooShort,
    /// A caller-supplied output buffer cannot hold the result.
    BufferTooSmall,
    /// A payload would push the message past `MAX_MESSAGE_BYTES`.
    PayloadTooLong,
    /// A cipher's 64-bit nonce space is spent; the reserved final nonce never
    /// encrypts. The channel above renegotiates or closes.
    NonceExhausted,
    /// A Diffie-Hellman input mapped to the identity element, so the shared
    /// secret would be worthless. Refusing here is what keeps a low-order
    /// public key from silently zeroing the key schedule.
    IdentityElement,
    /// `split` was asked for transport ciphers before the third message.
    HandshakeNotComplete,
};

/// One direction's transport cipher after `split`, and the payload cipher
/// during the handshake: a ChaCha20-Poly1305 key with a counting nonce.
pub const CipherState = struct {
    k: [KEY_BYTES]u8,
    n: u64,

    /// The final nonce value is reserved by the Noise specification for
    /// `rekey`, so reaching it means the space is spent.
    const reserved_nonce: u64 = std.math.maxInt(u64);

    pub fn init(k: [KEY_BYTES]u8) CipherState {
        return .{ .k = k, .n = 0 };
    }

    /// Seal `plaintext` under the current nonce with `ad` as associated data,
    /// writing ciphertext then tag into `out` and advancing the nonce. Returns
    /// the written slice: `plaintext.len + TAG_BYTES` bytes.
    pub fn encrypt(self: *CipherState, ad: []const u8, plaintext: []const u8, out: []u8) NoiseError![]u8 {
        if (self.n == reserved_nonce) return NoiseError.NonceExhausted;
        const total = std.math.add(usize, plaintext.len, TAG_BYTES) catch
            return NoiseError.PayloadTooLong;
        if (out.len < total) return NoiseError.BufferTooSmall;
        Aead.encrypt(
            out[0..plaintext.len],
            out[plaintext.len..total][0..TAG_BYTES],
            plaintext,
            ad,
            nonceBytes(self.n),
            self.k,
        );
        self.n += 1;
        return out[0..total];
    }

    /// Open `ciphertext` (payload then tag) under the current nonce. The nonce
    /// advances only on success, per the specification, so one forged message
    /// cannot desynchronize the channel it failed to break.
    pub fn decrypt(self: *CipherState, ad: []const u8, ciphertext: []const u8, out: []u8) NoiseError![]u8 {
        if (self.n == reserved_nonce) return NoiseError.NonceExhausted;
        if (ciphertext.len < TAG_BYTES) return NoiseError.MessageTooShort;
        const plain_len = ciphertext.len - TAG_BYTES;
        if (out.len < plain_len) return NoiseError.BufferTooSmall;
        Aead.decrypt(
            out[0..plain_len],
            ciphertext[0..plain_len],
            ciphertext[plain_len..][0..TAG_BYTES].*,
            ad,
            nonceBytes(self.n),
            self.k,
        ) catch return NoiseError.DecryptFailed;
        self.n += 1;
        return out[0..plain_len];
    }

    /// Replace the key with `ENCRYPT(k, 2^64-1, "", zeros)` truncated to the
    /// key width, the specification's `REKEY`. The nonce is not reset; Noise
    /// leaves that to the protocol above, and the sealed channel does not
    /// reset it either.
    pub fn rekey(self: *CipherState) void {
        const zeros = @as([KEY_BYTES]u8, @splat(0));
        var sealed: [KEY_BYTES]u8 = undefined;
        defer std.crypto.secureZero(u8, &sealed);
        var tag: [TAG_BYTES]u8 = undefined;
        Aead.encrypt(&sealed, &tag, &zeros, "", nonceBytes(reserved_nonce), self.k);
        self.k = sealed;
        std.crypto.secureZero(u8, &tag);
    }

    /// Refuse a batch that would reach the nonce reserved for `REKEY` before
    /// its first record is emitted. Batch owners use this to keep an outbound
    /// operation transactional with respect to nonce exhaustion.
    pub fn ensureNonceCapacity(self: *const CipherState, messages: usize) NoiseError!void {
        const remaining = reserved_nonce - self.n;
        if (messages > remaining) return NoiseError.NonceExhausted;
    }

    /// Wipe the key. The owner calls this when the channel closes; the state
    /// is unusable afterwards.
    pub fn deinit(self: *CipherState) void {
        std.crypto.secureZero(u8, &self.k);
        self.n = 0;
    }

    /// The ChaCha20-Poly1305 nonce layout the specification fixes: four zero
    /// bytes then the counter, little-endian.
    fn nonceBytes(n: u64) [Aead.nonce_length]u8 {
        var out = @as([Aead.nonce_length]u8, @splat(0));
        std.mem.writeInt(u64, out[4..12], n, .little);
        return out;
    }
};

/// The two transport ciphers `split` hands back, already oriented by role, and
/// the final handshake hash for channel binding.
pub const TransportKeys = struct {
    /// Seals what this side sends.
    send: CipherState,
    /// Opens what this side receives.
    recv: CipherState,
    /// `h` after the final handshake message: a transcript digest both sides
    /// share, for binding anything above the channel to this exact handshake.
    handshake_hash: [KEY_BYTES]u8,
};

/// Which side of the handshake this state drives.
pub const Role = enum(u8) { initiator, responder };

/// The `XK` handshake, both roles. Build one per connection attempt, drive it
/// with `writeMessage` and `readMessage` in strict alternation (initiator
/// writes first), then call `split` after the third message. Turn order is
/// the caller's contract and asserted, not error-mapped: inbound bytes only
/// ever reach `readMessage`, so a turn violation is a driver bug, never
/// attacker input.
pub const HandshakeState = struct {
    ck: [KEY_BYTES]u8,
    h: [KEY_BYTES]u8,
    cipher: CipherState,
    has_cipher: bool,
    role: Role,
    /// Index of the next handshake message, 0 through 2; 3 means complete,
    /// `retired_stage` means split or wiped, with nothing left to derive from.
    stage: u8,
    s: KeyPair,
    e: KeyPair,
    /// The far side's static: known from the designator before message one
    /// for the initiator, learned inside message three by the responder.
    rs: ?[KEY_BYTES]u8,
    re: ?[KEY_BYTES]u8,

    /// The state after `split` or `deinit`: the working keys are zeroed, so
    /// nothing may derive from this state again.
    const retired_stage: u8 = 4;

    /// Message sizes: `e` in the clear, then the payload sealed.
    pub const MSG1_OVERHEAD: usize = KEY_BYTES + TAG_BYTES;
    /// Same layout as message one.
    pub const MSG2_OVERHEAD: usize = KEY_BYTES + TAG_BYTES;
    /// The initiator's static sealed (key plus tag), then the payload sealed.
    pub const MSG3_OVERHEAD: usize = KEY_BYTES + TAG_BYTES + TAG_BYTES;

    /// Start the dialing side. `local_static` is this peer's converted durable
    /// key, `remote_static` the responder's X25519 public derived from the
    /// designator being dialed, `ephemeral` a fresh pair from caller entropy,
    /// and `prologue` the transport-and-designator binding both sides compute;
    /// a transcript replayed against a different transport or identity
    /// diverges from the first hash.
    pub fn initInitiator(
        local_static: *const KeyPair,
        remote_static: [KEY_BYTES]u8,
        ephemeral: *const KeyPair,
        prologue: []const u8,
    ) HandshakeState {
        var state = base(.initiator, local_static, ephemeral, prologue);
        state.rs = remote_static;
        // XK pre-message: the responder's static is mixed into the transcript
        // before any message, which is what pins the handshake to the key the
        // dialer thinks it is talking to.
        state.mixHash(&remote_static);
        return state;
    }

    /// Start the answering side. The responder needs no remote key up front:
    /// its own static is the pre-message, and the initiator's arrives sealed
    /// in message three.
    pub fn initResponder(
        local_static: *const KeyPair,
        ephemeral: *const KeyPair,
        prologue: []const u8,
    ) HandshakeState {
        var state = base(.responder, local_static, ephemeral, prologue);
        state.mixHash(&local_static.public);
        return state;
    }

    fn base(role: Role, local_static: *const KeyPair, ephemeral: *const KeyPair, prologue: []const u8) HandshakeState {
        var state = HandshakeState{
            .ck = undefined,
            .h = undefined,
            .cipher = undefined,
            .has_cipher = false,
            .role = role,
            .stage = 0,
            .s = local_static.*,
            .e = ephemeral.*,
            .rs = null,
            .re = null,
        };
        // The protocol name is longer than one digest, so the specification
        // hashes it; ck starts equal to h.
        Blake2s.hash(protocol_name, &state.h, .{});
        state.ck = state.h;
        state.mixHash(prologue);
        return state;
    }

    /// True when it is this state's turn to write the next handshake message.
    pub fn myTurn(self: *const HandshakeState) bool {
        if (self.stage > 2) return false;
        const writer: Role = if (self.stage % 2 == 0) .initiator else .responder;
        return writer == self.role;
    }

    /// Produce the next handshake message carrying `payload`, writing into
    /// `out` and returning the written slice. Asserts it is this side's turn.
    pub fn writeMessage(self: *HandshakeState, payload: []const u8, out: []u8) NoiseError![]u8 {
        std.debug.assert(self.myTurn());
        const overhead: usize = switch (self.stage) {
            0 => MSG1_OVERHEAD,
            1 => MSG2_OVERHEAD,
            2 => MSG3_OVERHEAD,
            else => unreachable,
        };
        const total = std.math.add(usize, overhead, payload.len) catch
            return NoiseError.PayloadTooLong;
        if (total > MAX_MESSAGE_BYTES) return NoiseError.PayloadTooLong;
        if (out.len < total) return NoiseError.BufferTooSmall;

        var cursor: usize = 0;
        switch (self.stage) {
            0 => {
                // -> e, es
                out[0..KEY_BYTES].* = self.e.public;
                self.mixHash(&self.e.public);
                cursor = KEY_BYTES;
                try self.mixKeyDh(&self.e, self.rs.?);
            },
            1 => {
                // <- e, ee
                out[0..KEY_BYTES].* = self.e.public;
                self.mixHash(&self.e.public);
                cursor = KEY_BYTES;
                try self.mixKeyDh(&self.e, self.re.?);
            },
            2 => {
                // -> s, se
                const sealed = try self.encryptAndHash(&self.s.public, out[0 .. KEY_BYTES + TAG_BYTES]);
                cursor = sealed.len;
                try self.mixKeyDh(&self.s, self.re.?);
            },
            else => unreachable,
        }
        const sealed_payload = try self.encryptAndHash(payload, out[cursor..total]);
        self.stage += 1;
        return out[0 .. cursor + sealed_payload.len];
    }

    /// Consume the next handshake message, writing the peer's payload into
    /// `out` and returning it. Asserts it is the peer's turn to have written.
    /// On any failure the state has still advanced its transcript hash and
    /// must be discarded; the channel owner closes the connection, which is
    /// the only recovery `XK` defines.
    pub fn readMessage(self: *HandshakeState, message: []const u8, out: []u8) NoiseError![]u8 {
        std.debug.assert(!self.myTurn() and self.stage <= 2);
        const overhead: usize = switch (self.stage) {
            0 => MSG1_OVERHEAD,
            1 => MSG2_OVERHEAD,
            2 => MSG3_OVERHEAD,
            else => unreachable,
        };
        if (message.len < overhead) return NoiseError.MessageTooShort;
        if (message.len > MAX_MESSAGE_BYTES) return NoiseError.PayloadTooLong;
        if (out.len < message.len - overhead) return NoiseError.BufferTooSmall;

        var cursor: usize = 0;
        switch (self.stage) {
            0 => {
                const re = message[0..KEY_BYTES].*;
                self.re = re;
                self.mixHash(&re);
                cursor = KEY_BYTES;
                try self.mixKeyDh(&self.s, re);
            },
            1 => {
                const re = message[0..KEY_BYTES].*;
                self.re = re;
                self.mixHash(&re);
                cursor = KEY_BYTES;
                try self.mixKeyDh(&self.e, re);
            },
            2 => {
                var rs: [KEY_BYTES]u8 = undefined;
                _ = try self.decryptAndHash(message[0 .. KEY_BYTES + TAG_BYTES], &rs);
                self.rs = rs;
                cursor = KEY_BYTES + TAG_BYTES;
                try self.mixKeyDh(&self.e, rs);
            },
            else => unreachable,
        }
        const payload = try self.decryptAndHash(message[cursor..], out);
        self.stage += 1;
        return payload;
    }

    /// The far side's static X25519 key, once learned. The responder reads it
    /// after message three; the initiator holds it from init. It names a
    /// curve point, not a durable identity: the sealed channel verifies a
    /// signed exact Ed25519 identity proof against this value.
    pub fn remoteStatic(self: *const HandshakeState) ?[KEY_BYTES]u8 {
        return self.rs;
    }

    /// The transcript after the protocol name, prologue, and XK responder
    /// pre-message have been mixed, before either ephemeral is sent. The
    /// sealed-channel identity proof binds to this value so it cannot be
    /// replayed under another transport, responder designator, Noise suite,
    /// or responder static.
    pub fn initialHandshakeHash(self: *const HandshakeState) [KEY_BYTES]u8 {
        std.debug.assert(self.stage == 0);
        return self.h;
    }

    /// Finish: derive the two transport ciphers and wipe the handshake's
    /// working state. The chaining key, ephemeral secret, static-secret copy,
    /// and payload cipher are zeroed here, which is the completion-time
    /// cleanup ADR-0107 budgets for; only the returned keys and the transcript
    /// hash survive.
    pub fn split(self: *HandshakeState) NoiseError!TransportKeys {
        if (self.stage <= 2) return NoiseError.HandshakeNotComplete;
        // A second split would derive from the zeroed chaining key; that is a
        // driver bug, not attacker input, so it asserts like turn misuse.
        std.debug.assert(self.stage != retired_stage);
        self.stage = retired_stage;
        var derived: [KEY_BYTES * 2]u8 = undefined;
        var prk = Hkdf.extract(&self.ck, "");
        Hkdf.expand(&derived, "", prk);
        std.crypto.secureZero(u8, &prk);
        var initiator_key: [KEY_BYTES]u8 = derived[0..KEY_BYTES].*;
        defer std.crypto.secureZero(u8, &initiator_key);
        var responder_key: [KEY_BYTES]u8 = derived[KEY_BYTES..].*;
        defer std.crypto.secureZero(u8, &responder_key);
        std.crypto.secureZero(u8, &derived);

        const hash = self.h;
        std.crypto.secureZero(u8, &self.ck);
        std.crypto.secureZero(u8, &self.e.secret);
        std.crypto.secureZero(u8, &self.s.secret);
        if (self.has_cipher) self.cipher.deinit();

        return switch (self.role) {
            .initiator => .{
                .send = CipherState.init(initiator_key),
                .recv = CipherState.init(responder_key),
                .handshake_hash = hash,
            },
            .responder => .{
                .send = CipherState.init(responder_key),
                .recv = CipherState.init(initiator_key),
                .handshake_hash = hash,
            },
        };
    }

    /// Wipe an unfinished handshake, for the connection that dies mid-flight.
    pub fn deinit(self: *HandshakeState) void {
        std.crypto.secureZero(u8, &self.ck);
        std.crypto.secureZero(u8, &self.h);
        std.crypto.secureZero(u8, &self.e.secret);
        std.crypto.secureZero(u8, &self.s.secret);
        if (self.has_cipher) self.cipher.deinit();
        self.stage = retired_stage;
    }

    fn mixHash(self: *HandshakeState, data: []const u8) void {
        var hasher = Blake2s.init(.{});
        hasher.update(&self.h);
        hasher.update(data);
        hasher.final(&self.h);
    }

    /// `MixKey(DH(pair, public))`: run the exchange, fold the shared secret
    /// into the chaining key, and key the payload cipher from the result.
    fn mixKeyDh(self: *HandshakeState, pair: *const KeyPair, public: [KEY_BYTES]u8) NoiseError!void {
        var shared = X25519.scalarmult(pair.secret, public) catch
            return NoiseError.IdentityElement;
        defer std.crypto.secureZero(u8, &shared);
        var derived: [KEY_BYTES * 2]u8 = undefined;
        var prk = Hkdf.extract(&self.ck, &shared);
        Hkdf.expand(&derived, "", prk);
        std.crypto.secureZero(u8, &prk);
        self.ck = derived[0..KEY_BYTES].*;
        if (self.has_cipher) self.cipher.deinit();
        self.cipher = CipherState.init(derived[KEY_BYTES..].*);
        self.has_cipher = true;
        std.crypto.secureZero(u8, &derived);
    }

    fn encryptAndHash(self: *HandshakeState, plaintext: []const u8, out: []u8) NoiseError![]u8 {
        // XK keys the payload cipher before the first payload, so a sealed
        // write always has a cipher; the assert states the pattern fact.
        std.debug.assert(self.has_cipher);
        const sealed = try self.cipher.encrypt(&self.h, plaintext, out);
        self.mixHash(sealed);
        return sealed;
    }

    fn decryptAndHash(self: *HandshakeState, ciphertext: []const u8, out: []u8) NoiseError![]u8 {
        std.debug.assert(self.has_cipher);
        const payload = try self.cipher.decrypt(&self.h, ciphertext, out);
        self.mixHash(ciphertext);
        return payload;
    }
};

/// Sealed-record framing: after the handshake the byte stream carries
/// two-byte big-endian lengths, each followed by that many ciphertext bytes.
pub const RECORD_HEADER_BYTES: usize = 2;

/// The ceiling one record's body may declare, tag included.
pub const MAX_RECORD_BYTES: usize = 65535;

/// The most plaintext one record can carry; a longer frame spans records.
pub const MAX_RECORD_PLAINTEXT_BYTES: usize = MAX_RECORD_BYTES - TAG_BYTES;

/// Seal one record: header, ciphertext, tag, written into `out` as one span.
/// `plaintext` must fit one record; the channel above slices a larger frame.
pub fn sealRecord(cipher: *CipherState, plaintext: []const u8, out: []u8) NoiseError![]u8 {
    if (plaintext.len > MAX_RECORD_PLAINTEXT_BYTES) return NoiseError.PayloadTooLong;
    const body_len = std.math.add(usize, plaintext.len, TAG_BYTES) catch
        return NoiseError.PayloadTooLong;
    const total = std.math.add(usize, RECORD_HEADER_BYTES, body_len) catch
        return NoiseError.PayloadTooLong;
    if (out.len < total) return NoiseError.BufferTooSmall;
    std.mem.writeInt(u16, out[0..RECORD_HEADER_BYTES], @intCast(body_len), .big);
    _ = try cipher.encrypt("", plaintext, out[RECORD_HEADER_BYTES..total]);
    return out[0..total];
}

/// Read a record header: how many body bytes follow it.
pub fn recordBodyLen(header: [RECORD_HEADER_BYTES]u8) usize {
    return std.mem.readInt(u16, &header, .big);
}

/// Open one record body (ciphertext plus tag, header already consumed).
pub fn openRecord(cipher: *CipherState, body: []const u8, out: []u8) NoiseError![]u8 {
    if (body.len > MAX_RECORD_BYTES) return NoiseError.PayloadTooLong;
    return cipher.decrypt("", body, out);
}
