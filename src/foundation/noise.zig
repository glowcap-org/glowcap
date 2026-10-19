//! The `Noise_XK_25519_ChaChaPoly_BLAKE2s` state machine ADR-0041's sealed
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
//! `crypto.zig`. Everything here works in raw X25519 material.
//!
//! Callers are `foundation.sealed.SealedChannel` (the composition the
//! byte-fed Host boxes per sealed session) and the cacophony vectors in
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
pub const key_bytes: usize = 32;

/// Width in bytes of the AEAD authentication tag on every sealed payload.
pub const tag_bytes: usize = 16;

/// The Noise ceiling on one whole handshake or transport message: a 16-bit
/// length.
pub const max_message_bytes: usize = std.math.maxInt(u16);

/// A raw X25519 pair, re-exported so a caller holding durable keys converts
/// once in `crypto.zig` and hands the result straight in.
pub const KeyPair = crypto.X25519KeyMaterial;

/// The ways the state machine can refuse. Everything inbound bytes can reach
/// arrives through `readMessage` or `CipherState.decrypt`, and both fail
/// closed with a typed reason. The rest guard caller arithmetic.
pub const NoiseError = error{
    /// An AEAD tag did not verify. The message was forged, replayed under the
    /// wrong key, or corrupted. The receiving state did not advance.
    DecryptFailed,
    /// An inbound handshake message is shorter than its fixed layout.
    MessageTooShort,
    /// A caller-supplied output buffer cannot hold the result.
    BufferTooSmall,
    /// A payload would push the message past `max_message_bytes`.
    PayloadTooLong,
    /// A cipher's 64-bit nonce space is spent. The reserved final nonce never
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
    k: [key_bytes]u8,
    n: u64,

    /// The final nonce value is reserved by the Noise specification for
    /// `rekey`, so reaching it means the space is spent.
    const reserved_nonce: u64 = std.math.maxInt(u64);

    pub fn init(k: [key_bytes]u8) CipherState {
        return .{ .k = k, .n = 0 };
    }

    /// Seal `plaintext` under the current nonce with `ad` as associated data,
    /// writing ciphertext then tag into `out` and advancing the nonce. Returns
    /// the written slice: `plaintext.len + tag_bytes` bytes.
    pub fn encrypt(self: *CipherState, ad: []const u8, plaintext: []const u8, out: []u8) NoiseError![]u8 {
        if (self.n == reserved_nonce) return NoiseError.NonceExhausted;
        const total = std.math.add(usize, plaintext.len, tag_bytes) catch
            return NoiseError.PayloadTooLong;
        if (out.len < total) return NoiseError.BufferTooSmall;
        Aead.encrypt(
            out[0..plaintext.len],
            out[plaintext.len..total][0..tag_bytes],
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
        if (ciphertext.len < tag_bytes) return NoiseError.MessageTooShort;
        const plain_len = ciphertext.len - tag_bytes;
        if (out.len < plain_len) return NoiseError.BufferTooSmall;
        Aead.decrypt(
            out[0..plain_len],
            ciphertext[0..plain_len],
            ciphertext[plain_len..][0..tag_bytes].*,
            ad,
            nonceBytes(self.n),
            self.k,
        ) catch return NoiseError.DecryptFailed;
        self.n += 1;
        return out[0..plain_len];
    }

    /// Replace the key with `ENCRYPT(k, 2^64-1, "", zeros)` truncated to the
    /// key width, the specification's `REKEY`. The nonce is not reset. Noise
    /// leaves that to the protocol above, and the sealed channel does not
    /// reset it either.
    pub fn rekey(self: *CipherState) void {
        const zeros = @as([key_bytes]u8, @splat(0));
        var sealed: [key_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &sealed);
        var tag: [tag_bytes]u8 = undefined;
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

    /// Wipe the key. The owner calls this when the channel closes. The state
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
    handshake_hash: [key_bytes]u8,
};

/// Which side of the handshake this state drives.
pub const Role = enum(u8) { initiator, responder };

/// The `XK` handshake, both roles. Build one per connection attempt, drive it
/// with `writeMessage` and `readMessage` in strict alternation (initiator
/// writes first), then call `split` after the third message. Turn order is
/// the caller's contract and asserted, not error-mapped: inbound bytes only
/// ever reach `readMessage`, so a turn violation is a driver bug, never
/// peer input.
pub const HandshakeState = struct {
    ck: [key_bytes]u8,
    h: [key_bytes]u8,
    /// The payload cipher, keyed by the first `mixKeyDh` and rekeyed by each
    /// later one. Null until then.
    cipher: ?CipherState,
    role: Role,
    stage: Stage,
    s: KeyPair,
    e: KeyPair,
    /// The far side's static: known from the designator before message one
    /// for the initiator, learned inside message three by the responder.
    rs: ?[key_bytes]u8,
    re: ?[key_bytes]u8,

    /// Where the handshake stands: the next message to write or read, or
    /// that nothing is left to derive from.
    pub const Stage = enum(u8) {
        message_one,
        message_two,
        message_three,
        complete,
        /// After `split` or `deinit`: the working keys are zeroed, so nothing
        /// may derive from this state again.
        retired,

        /// The side that writes this stage's message.
        fn writer(self: Stage) Role {
            return switch (self) {
                .message_one, .message_three => .initiator,
                .message_two => .responder,
                .complete, .retired => unreachable,
            };
        }

        fn overhead(self: Stage) usize {
            return switch (self) {
                .message_one => msg1_overhead,
                .message_two => msg2_overhead,
                .message_three => msg3_overhead,
                .complete, .retired => unreachable,
            };
        }

        fn next(self: Stage) Stage {
            return switch (self) {
                .message_one => .message_two,
                .message_two => .message_three,
                .message_three => .complete,
                .complete, .retired => unreachable,
            };
        }
    };

    /// Message sizes: `e` in the clear, then the payload sealed.
    pub const msg1_overhead: usize = key_bytes + tag_bytes;
    /// Same layout as message one.
    pub const msg2_overhead: usize = key_bytes + tag_bytes;
    /// The initiator's static sealed (key plus tag), then the payload sealed.
    pub const msg3_overhead: usize = key_bytes + tag_bytes + tag_bytes;

    /// Start the dialing side. `local_static` is this peer's converted durable
    /// key, `remote_static` the responder's X25519 public derived from the
    /// designator being dialed, `ephemeral` a fresh pair from caller entropy,
    /// and `prologue` the transport-and-designator binding both sides compute.
    /// A transcript replayed against a different transport or identity
    /// diverges from the first hash.
    pub fn initInitiator(
        local_static: *const KeyPair,
        remote_static: [key_bytes]u8,
        ephemeral: *const KeyPair,
        prologue: []const u8,
    ) HandshakeState {
        var state = base(.initiator, local_static, ephemeral, prologue);
        state.rs = remote_static;
        // XK pre-message: the responder's static is mixed into the transcript
        // before any message, and that mix pins the handshake to the key the
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
            .cipher = null,
            .role = role,
            .stage = .message_one,
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
        return switch (self.stage) {
            .complete, .retired => false,
            else => |stage| stage.writer() == self.role,
        };
    }

    /// Produce the next handshake message carrying `payload`, writing into
    /// `out` and returning the written slice. Asserts it is this side's turn.
    pub fn writeMessage(self: *HandshakeState, payload: []const u8, out: []u8) NoiseError![]u8 {
        std.debug.assert(self.myTurn());
        const total = std.math.add(usize, self.stage.overhead(), payload.len) catch
            return NoiseError.PayloadTooLong;
        if (total > max_message_bytes) return NoiseError.PayloadTooLong;
        if (out.len < total) return NoiseError.BufferTooSmall;

        var cursor: usize = 0;
        switch (self.stage) {
            .message_one => {
                // -> e, es
                out[0..key_bytes].* = self.e.public;
                self.mixHash(&self.e.public);
                cursor = key_bytes;
                try self.mixKeyDh(&self.e, self.rs.?);
            },
            .message_two => {
                // <- e, ee
                out[0..key_bytes].* = self.e.public;
                self.mixHash(&self.e.public);
                cursor = key_bytes;
                try self.mixKeyDh(&self.e, self.re.?);
            },
            .message_three => {
                // -> s, se
                const sealed = try self.encryptAndHash(&self.s.public, out[0 .. key_bytes + tag_bytes]);
                cursor = sealed.len;
                try self.mixKeyDh(&self.s, self.re.?);
            },
            .complete, .retired => unreachable,
        }
        const sealed_payload = try self.encryptAndHash(payload, out[cursor..total]);
        self.stage = self.stage.next();
        return out[0 .. cursor + sealed_payload.len];
    }

    /// Consume the next handshake message, writing the peer's payload into
    /// `out` and returning it. Asserts it is the peer's turn to have written.
    /// On any failure the state has still advanced its transcript hash and
    /// must be discarded. The channel owner closes the connection, which is
    /// the only recovery `XK` defines.
    pub fn readMessage(self: *HandshakeState, message: []const u8, out: []u8) NoiseError![]u8 {
        std.debug.assert(!self.myTurn());
        const overhead = self.stage.overhead();
        if (message.len < overhead) return NoiseError.MessageTooShort;
        if (message.len > max_message_bytes) return NoiseError.PayloadTooLong;
        if (out.len < message.len - overhead) return NoiseError.BufferTooSmall;

        var cursor: usize = 0;
        switch (self.stage) {
            .message_one => {
                const re = message[0..key_bytes].*;
                self.re = re;
                self.mixHash(&re);
                cursor = key_bytes;
                try self.mixKeyDh(&self.s, re);
            },
            .message_two => {
                const re = message[0..key_bytes].*;
                self.re = re;
                self.mixHash(&re);
                cursor = key_bytes;
                try self.mixKeyDh(&self.e, re);
            },
            .message_three => {
                var rs: [key_bytes]u8 = undefined;
                _ = try self.decryptAndHash(message[0 .. key_bytes + tag_bytes], &rs);
                self.rs = rs;
                cursor = key_bytes + tag_bytes;
                try self.mixKeyDh(&self.e, rs);
            },
            .complete, .retired => unreachable,
        }
        const payload = try self.decryptAndHash(message[cursor..], out);
        self.stage = self.stage.next();
        return payload;
    }

    /// The far side's static X25519 key, once learned. The responder reads it
    /// after message three. The initiator holds it from init. It names a
    /// curve point, not a durable identity: the sealed channel verifies a
    /// signed exact Ed25519 identity proof against this value.
    pub fn remoteStatic(self: *const HandshakeState) ?[key_bytes]u8 {
        return self.rs;
    }

    /// The transcript after the protocol name, prologue, and XK responder
    /// pre-message have been mixed, before either ephemeral is sent. The
    /// sealed-channel identity proof binds to this value so it cannot be
    /// replayed under another transport, responder designator, Noise suite,
    /// or responder static.
    pub fn initialHandshakeHash(self: *const HandshakeState) [key_bytes]u8 {
        std.debug.assert(self.stage == .message_one);
        return self.h;
    }

    /// Finish: derive the two transport ciphers and wipe the handshake's
    /// working state. The chaining key, ephemeral secret, static-secret copy,
    /// and payload cipher are zeroed here, which is the completion-time
    /// cleanup ADR-0041 budgets for. Only the returned keys and the transcript
    /// hash survive.
    pub fn split(self: *HandshakeState) NoiseError!TransportKeys {
        switch (self.stage) {
            .complete => {},
            // A second split would derive from the zeroed chaining key; that
            // is a driver bug, not peer input, so it asserts like turn misuse.
            .retired => unreachable,
            else => return NoiseError.HandshakeNotComplete,
        }
        self.stage = .retired;
        var derived: [key_bytes * 2]u8 = undefined;
        var prk = Hkdf.extract(&self.ck, "");
        Hkdf.expand(&derived, "", prk);
        std.crypto.secureZero(u8, &prk);
        var initiator_key: [key_bytes]u8 = derived[0..key_bytes].*;
        defer std.crypto.secureZero(u8, &initiator_key);
        var responder_key: [key_bytes]u8 = derived[key_bytes..].*;
        defer std.crypto.secureZero(u8, &responder_key);
        std.crypto.secureZero(u8, &derived);

        const hash = self.h;
        std.crypto.secureZero(u8, &self.ck);
        std.crypto.secureZero(u8, &self.e.secret);
        std.crypto.secureZero(u8, &self.s.secret);
        if (self.cipher) |*cipher| cipher.deinit();

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
        if (self.cipher) |*cipher| cipher.deinit();
        self.stage = .retired;
    }

    fn mixHash(self: *HandshakeState, data: []const u8) void {
        var hasher = Blake2s.init(.{});
        hasher.update(&self.h);
        hasher.update(data);
        hasher.final(&self.h);
    }

    /// `MixKey(DH(pair, public))`: run the exchange, fold the shared secret
    /// into the chaining key, and key the payload cipher from the result.
    fn mixKeyDh(self: *HandshakeState, pair: *const KeyPair, public: [key_bytes]u8) NoiseError!void {
        var shared = X25519.scalarmult(pair.secret, public) catch
            return NoiseError.IdentityElement;
        defer std.crypto.secureZero(u8, &shared);
        var derived: [key_bytes * 2]u8 = undefined;
        var prk = Hkdf.extract(&self.ck, &shared);
        Hkdf.expand(&derived, "", prk);
        std.crypto.secureZero(u8, &prk);
        self.ck = derived[0..key_bytes].*;
        if (self.cipher) |*cipher| cipher.deinit();
        self.cipher = CipherState.init(derived[key_bytes..].*);
        std.crypto.secureZero(u8, &derived);
    }

    fn encryptAndHash(self: *HandshakeState, plaintext: []const u8, out: []u8) NoiseError![]u8 {
        // XK keys the payload cipher before the first payload, so a sealed
        // write always has a cipher.
        const sealed = try self.cipher.?.encrypt(&self.h, plaintext, out);
        self.mixHash(sealed);
        return sealed;
    }

    fn decryptAndHash(self: *HandshakeState, ciphertext: []const u8, out: []u8) NoiseError![]u8 {
        const payload = try self.cipher.?.decrypt(&self.h, ciphertext, out);
        self.mixHash(ciphertext);
        return payload;
    }
};

/// Sealed-record framing: after the handshake the byte stream carries
/// two-byte big-endian lengths, each followed by that many ciphertext bytes.
pub const record_header_bytes: usize = 2;

/// The ceiling one record's body may declare, tag included: the header's
/// 16-bit length.
pub const max_record_bytes: usize = std.math.maxInt(u16);

/// The most plaintext one record can carry. A longer frame spans records.
pub const max_record_plaintext_bytes: usize = max_record_bytes - tag_bytes;

/// Seal one record: header, ciphertext, tag, written into `out` as one span.
/// `plaintext` must fit one record. The channel above slices a larger frame.
pub fn sealRecord(cipher: *CipherState, plaintext: []const u8, out: []u8) NoiseError![]u8 {
    if (plaintext.len > max_record_plaintext_bytes) return NoiseError.PayloadTooLong;
    const body_len = std.math.add(usize, plaintext.len, tag_bytes) catch
        return NoiseError.PayloadTooLong;
    const total = std.math.add(usize, record_header_bytes, body_len) catch
        return NoiseError.PayloadTooLong;
    if (out.len < total) return NoiseError.BufferTooSmall;
    std.mem.writeInt(u16, out[0..record_header_bytes], @intCast(body_len), .big);
    _ = try cipher.encrypt("", plaintext, out[record_header_bytes..total]);
    return out[0..total];
}

/// Read a record header: how many body bytes follow it.
pub fn recordBodyLen(header: [record_header_bytes]u8) usize {
    return std.mem.readInt(u16, &header, .big);
}

/// Open one record body (ciphertext plus tag, header already consumed).
pub fn openRecord(cipher: *CipherState, body: []const u8, out: []u8) NoiseError![]u8 {
    if (body.len > max_record_bytes) return NoiseError.PayloadTooLong;
    return cipher.decrypt("", body, out);
}
