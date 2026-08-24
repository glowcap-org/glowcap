//! The sealed byte channel (ADR-0107): `foundation.noise`'s `Noise_XK` state
//! machine driven over a byte stream, with the record framing, the prologue,
//! and the identity payload the record specifies.
//!
//! It lives in `foundation` for the same reason `foundation.Spill` does: both
//! stream tiers need one and neither imports the other. The byte-fed host
//! core boxes one per sealed `HostSession` and runs it inside `Host.feedBytes`
//! and `HostSession.takeTransportOutbound`; the completion-loop tier composes
//! the same machine inside a sealing completion-backend adapter
//! (`net.noise_completion`), which finishes the handshake before the loop
//! ever sees the connection open. One channel type, one authority for channel
//! state per connection, two thin owners.
//!
//! The channel is byte-stream in, byte-stream out. What rides inside the
//! sealed records is exactly the plaintext stream an unsealed byte pipe
//! carries — outer Syrup framing included — so nothing above this layer
//! changes: the owner opens records and hands the plaintext to the same parse
//! it runs today, and seals what the layer above encodes.
//!
//! Wire layout, both directions:
//!
//! - Three handshake messages of fixed size open the channel: 48 bytes
//!   (`-> e, es`), then messages two and three carry the sender's encrypted
//!   32-byte Ed25519 key and 64-byte identity-binding signature. The proof
//!   binds the exact Ed25519 encoding to the authenticated X25519 static,
//!   role, and initial Noise transcript, so the lossy Edwards-to-Montgomery
//!   map is never treated as an identity proof. The fixed payloads need no
//!   additional framing.
//! - After the handshake, length-prefixed sealed records: a two-byte
//!   big-endian ciphertext length, then that many bytes, at most
//!   `foundation.noise.MAX_RECORD_BYTES` including the 16-byte tag. Record
//!   boundaries carry no meaning above this layer; a CapTP frame larger than
//!   one record's plaintext capacity spans several.
//!
//! Failure is refusal: any handshake or record that does not verify retires
//! the channel, wipes its keys, and the owner closes the connection without a
//! CapTP session ever existing (or, after open, without another plaintext
//! byte moving). There is no downgrade to an unsealed session.

const std = @import("std");

const noise = @import("noise.zig");
const crypto = @import("crypto.zig");
const spill = @import("spill.zig");
const frame = @import("frame.zig");
const identity_binding = @import("sealed_identity.zig");
const stream_framing = @import("stream_framing.zig");

/// Fixed wire sizes of the three handshake messages; see the module header.
const identity_proof_bytes: usize = identity_binding.proof_bytes;
pub const msg1_wire_bytes: usize = noise.HandshakeState.MSG1_OVERHEAD;
pub const msg2_wire_bytes: usize = noise.HandshakeState.MSG2_OVERHEAD + identity_proof_bytes;
pub const msg3_wire_bytes: usize = noise.HandshakeState.MSG3_OVERHEAD + identity_proof_bytes;

/// Steady capacity of the record-plaintext scratch, and the retained capacity
/// of the inbound staging after a drain — the byte-fed tier's steady-queue
/// posture. A record larger than this grows the scratch for its own open, and
/// the next record at or under it shrinks the scratch back.
const steady_plain_bytes: usize = 4096;

/// The ways the channel refuses beyond `foundation.noise.NoiseError`. Both
/// are inbound-byte verdicts and both retire the channel.
pub const SealedError = error{
    /// Inbound size arithmetic overflowed. Record bodies are fixed at 16-bit
    /// lengths, so only an impossible caller slice or retained-suffix sum can
    /// reach this refusal.
    InboundOverflow,
    /// An outbound slice's record count and overhead cannot be represented
    /// in `usize`; no allocation or cipher advancement occurred.
    OutboundOverflow,
    /// A handshake identity payload did not prove the exact Ed25519 key,
    /// authenticated X25519 static, role, and initial transcript together.
    IdentityMismatch,
    /// The far end answered a handshake message this side has not sent yet
    /// (its reply is still parked in `pending`). An honest peer cannot see an
    /// unsent message, so the bytes cannot verify and the turn order is
    /// already broken.
    HandshakeOutOfOrder,
};

/// One connection's sealed channel: the handshake while it runs, the two
/// transport ciphers after `open`, the inbound wire staging, and the one
/// pending outbound handshake message. Owned by exactly one shell per tier —
/// a `HostSession`'s nullable boxed pointer on the byte-fed tier, a sealing
/// completion adapter's per-connection state on the loop tier — and freed by
/// `deinit`.
///
/// Cost derivation (the memory rule's ledger points here): the struct is a
/// few hundred bytes and exists only for sealed connections. Normal ingestion
/// parses complete units directly from the owner's borrowed receive buffer and
/// copies only an incomplete unit, bounded by one maximum Noise record. A
/// byte-fed owner may explicitly park the unread suffix of its current chunk
/// across a protocol pause; that allocation is bounded by the owner's read
/// size, exactly like an unsealed stream tail. Completion owners retain their
/// receive-buffer borrow instead and never park a complete unit. `plain` is the
/// scratch one record opens into, at most
/// `foundation.noise.MAX_RECORD_PLAINTEXT_BYTES`, shrunk back to
/// `steady_plain_bytes` by the next small record. Sealing and opening each pay
/// the one AEAD pass per record ADR-0107 names: AEAD cannot encrypt in place
/// across the borrowed-frame boundary the engine relies on, so ciphertext is
/// written beside the plaintext, never over it.
pub const SealedChannel = struct {
    phase: Phase,
    role: noise.Role,
    /// The far end's durable Ed25519 identity: what the dial named, for the
    /// initiator, and null until message three verifies for the responder.
    /// `ingest` hands it out once, in `Event.completed`, and the owner
    /// binds it as the verified channel key.
    remote_identity: ?crypto.PeerKey,
    /// This host's exact Ed25519 identity and its precomputed proof. The
    /// constructor borrows the signing key only long enough to produce this
    /// payload; no Ed25519 secret is retained by the channel.
    local_proof: [identity_proof_bytes]u8,
    /// Initial Noise transcript shared by both sides, retained solely to
    /// verify the far side's role-specific identity proof.
    identity_context: [noise.KEY_BYTES]u8,
    /// The one pending outbound handshake message, drained by `takeWire`.
    /// At most one is ever pending: each side writes its next message only
    /// after consuming the reply to its previous one.
    pending: [msg3_wire_bytes]u8,
    pending_len: usize,
    /// Inbound wire bytes that do not yet form a whole handshake message or
    /// record. Bounded; see the type header.
    staged: spill.Spill,
    /// The scratch one inbound record's plaintext is opened into; the
    /// `Event.plaintext` slice borrows it until `releasePlaintext`. The explicit
    /// acknowledgement lets an owner retry upper-layer admission after memory
    /// pressure without replaying the Noise record or losing its plaintext.
    plain: []u8,
    /// Zero means no outstanding borrow; otherwise plaintext length plus one.
    /// The encoding represents a pending empty record without adding another
    /// machine word to every sealed connection.
    pending_plain_len: usize = 0,

    const Phase = union(enum) {
        handshake: noise.HandshakeState,
        open: noise.TransportKeys,
        failed,
    };

    /// What one `ingest` step produced.
    pub const Event = union(enum) {
        /// Every supplied byte was retained as an incomplete unit and nothing
        /// can move without more input.
        need_input,
        /// One handshake message advanced the transcript but did not complete
        /// it. The owner may continue with the unconsumed input suffix.
        handshake,
        /// The handshake completed on this consume. The owner binds `remote`
        /// as the verified channel key before feeding another byte; for the
        /// initiator a pending message three also awaits `takeWire`.
        completed: crypto.PeerKey,
        /// One record's plaintext, borrowed until `releasePlaintext`.
        plaintext: []const u8,
    };

    /// One prefix-consumption step. `consumed` names exactly how much of the
    /// caller's borrowed slice transferred or advanced; the caller retains the
    /// suffix. This makes coalesced reads independent of record boundaries and
    /// keeps ownership explicit when an upper layer intentionally pauses.
    pub const Ingest = struct {
        consumed: usize,
        event: Event,
    };

    /// Start the dialing side. `identity` is borrowed only while its X25519
    /// static and signed identity payload are derived, `remote` is the exact
    /// responder Ed25519 key named by the dial, and `ephemeral_seed` is fresh
    /// entropy supplied by the embedder. Message one is pending on return.
    pub fn initInitiator(
        identity: *const crypto.SecretKey,
        remote: crypto.PeerKey,
        ephemeral_seed: [crypto.SEED_BYTES]u8,
        transport: []const u8,
    ) (noise.NoiseError || error{ InvalidIdentity, InvalidRemoteKey, InvalidEphemeral })!SealedChannel {
        var local = crypto.x25519FromSecretKey(identity) orelse return error.InvalidIdentity;
        defer std.crypto.secureZero(u8, &local.secret);
        const remote_x = crypto.x25519FromPeerKey(remote) orelse return error.InvalidRemoteKey;
        var ephemeral = crypto.X25519KeyMaterial.fromSecret(ephemeral_seed) orelse return error.InvalidEphemeral;
        defer std.crypto.secureZero(u8, &ephemeral.secret);
        var prologue_buf: [identity_binding.prologue_max_bytes]u8 = undefined;
        const prologue = identity_binding.buildPrologue(&prologue_buf, transport, &remote.toDesignator());
        var handshake = noise.HandshakeState.initInitiator(&local, remote_x, &ephemeral, prologue);
        defer handshake.deinit();
        const identity_context = handshake.initialHandshakeHash();
        var self = SealedChannel{
            .phase = .{ .handshake = handshake },
            .role = .initiator,
            .remote_identity = remote,
            .local_proof = identity_binding.makeProof(identity, .initiator, local.public, identity_context),
            .identity_context = identity_context,
            .pending = undefined,
            .pending_len = 0,
            .staged = .{},
            .plain = &.{},
        };
        errdefer self.phase.handshake.deinit();
        const written = try self.phase.handshake.writeMessage(&.{}, self.pending[0..]);
        std.debug.assert(written.len == msg1_wire_bytes);
        self.pending_len = written.len;
        return self;
    }

    /// Start the answering side. The responder's prologue names its own
    /// designator — the one a dialer must have dialed for the transcripts to
    /// agree — and it learns the initiator's identity from message three.
    pub fn initResponder(
        identity: *const crypto.SecretKey,
        ephemeral_seed: [crypto.SEED_BYTES]u8,
        transport: []const u8,
    ) error{ InvalidIdentity, InvalidEphemeral }!SealedChannel {
        var local = crypto.x25519FromSecretKey(identity) orelse return error.InvalidIdentity;
        defer std.crypto.secureZero(u8, &local.secret);
        var ephemeral = crypto.X25519KeyMaterial.fromSecret(ephemeral_seed) orelse return error.InvalidEphemeral;
        defer std.crypto.secureZero(u8, &ephemeral.secret);
        var prologue_buf: [identity_binding.prologue_max_bytes]u8 = undefined;
        const local_identity = identity.publicKey();
        const prologue = identity_binding.buildPrologue(&prologue_buf, transport, &local_identity.toDesignator());
        var handshake = noise.HandshakeState.initResponder(&local, &ephemeral, prologue);
        defer handshake.deinit();
        const identity_context = handshake.initialHandshakeHash();
        return .{
            .phase = .{ .handshake = handshake },
            .role = .responder,
            .remote_identity = null,
            .local_proof = identity_binding.makeProof(identity, .responder, local.public, identity_context),
            .identity_context = identity_context,
            .pending = undefined,
            .pending_len = 0,
            .staged = .{},
            .plain = &.{},
        };
    }

    /// Whether the handshake has completed and the transport ciphers are
    /// live. A failed channel is not open.
    pub fn isOpen(self: *const SealedChannel) bool {
        return self.phase == .open;
    }

    /// Whether inbound wire bytes or opened plaintext are parked and the
    /// byte-fed owner may still move them without reading from the transport.
    pub fn hasStagedInbound(self: *const SealedChannel) bool {
        return self.pending_plain_len != 0 or self.staged.isActive();
    }

    /// The opened record still lent to the owner, if any. No next record may be
    /// ingested until the owner acknowledges this borrow with
    /// `releasePlaintext`.
    pub fn pendingPlaintext(self: *const SealedChannel) ?[]const u8 {
        if (self.pending_plain_len == 0) return null;
        return self.plain[0 .. self.pending_plain_len - 1];
    }

    /// Acknowledge the current plaintext borrow. The bytes remain allocated but
    /// become invalid to the owner; the next record wipe occurs before reuse.
    pub fn releasePlaintext(self: *SealedChannel) void {
        std.debug.assert(self.pending_plain_len != 0);
        self.pending_plain_len = 0;
    }

    /// Whether a handshake message awaits `takeWire`.
    pub fn hasPendingWire(self: *const SealedChannel) bool {
        return self.pending_len != 0;
    }

    /// Consume at most one handshake message or sealed record from `bytes`.
    /// Complete units are read directly from the borrowed slice. Only a unit
    /// split across calls enters `staged`; allocation pressure consumes no
    /// caller bytes and leaves already-staged bytes retryable.
    pub fn ingest(self: *SealedChannel, gpa: std.mem.Allocator, bytes: []const u8) !Ingest {
        std.debug.assert(self.pending_plain_len == 0);
        return self.ingestInner(gpa, bytes) catch |err| {
            if (err != error.OutOfMemory) self.fail();
            return err;
        };
    }

    fn ingestInner(self: *SealedChannel, gpa: std.mem.Allocator, bytes: []const u8) !Ingest {
        if (self.phase == .failed) return .{ .consumed = 0, .event = .need_input };

        var consumed: usize = 0;
        if (self.staged.isActive()) {
            const header_need = self.unitHeaderLen();
            if (self.staged.len < header_need) {
                const header_remaining = header_need - self.staged.len;
                if (bytes.len < header_remaining) {
                    try self.staged.absorbBytesPrecise(gpa, bytes);
                    return .{ .consumed = bytes.len, .event = .need_input };
                }
            }

            const unit_len = if (self.staged.len >= header_need)
                try self.unitLen(self.staged.bytes())
            else switch (self.phase) {
                .failed => unreachable,
                .handshake => header_need,
                .open => blk: {
                    var header: [noise.RECORD_HEADER_BYTES]u8 = undefined;
                    @memcpy(header[0..self.staged.len], self.staged.bytes());
                    const from_input = header_need - self.staged.len;
                    @memcpy(header[self.staged.len..header_need], bytes[0..from_input]);
                    break :blk try self.unitLen(&header);
                },
            };
            // A parked suffix may hold whole units beyond this one, so the
            // staged prefix can already be at or past `unit_len`; saturate
            // rather than assume the unit still needs caller bytes.
            const take = @min(unit_len -| self.staged.len, bytes.len);

            // A staged unit has already consumed bytes from an earlier call,
            // but none from this one. Reserve every allocation the completed
            // unit can need before committing this call's suffix, so OOM keeps
            // the exact caller slice retryable.
            try self.staged.ensureUnusedCapacityPrecise(gpa, take);
            if (self.staged.len + take >= unit_len) {
                try self.ensurePlainCapacityForUnitLen(gpa, unit_len);
            }
            self.staged.absorbBytesAssumeCapacity(bytes[0..take]);
            consumed = take;
            if (self.staged.len < unit_len)
                return .{ .consumed = consumed, .event = .need_input };
            const event = try self.consumeUnit(gpa, self.staged.bytes()[0..unit_len]);
            self.staged.consume(gpa, unit_len, steady_plain_bytes);
            return .{ .consumed = consumed, .event = event };
        }

        const header_need = self.unitHeaderLen();
        if (bytes.len < header_need) {
            try self.staged.absorbBytesPrecise(gpa, bytes);
            return .{ .consumed = bytes.len, .event = .need_input };
        }
        const unit_len = try self.unitLen(bytes);
        if (bytes.len < unit_len) {
            try self.staged.absorbBytesPrecise(gpa, bytes);
            return .{ .consumed = bytes.len, .event = .need_input };
        }
        return .{
            .consumed = unit_len,
            .event = try self.consumeUnit(gpa, bytes[0..unit_len]),
        };
    }

    fn unitHeaderLen(self: *const SealedChannel) usize {
        return switch (self.phase) {
            .failed => 0,
            .handshake => |hs| switch (hs.stage) {
                0 => msg1_wire_bytes,
                1 => msg2_wire_bytes,
                2 => msg3_wire_bytes,
                else => unreachable,
            },
            .open => noise.RECORD_HEADER_BYTES,
        };
    }

    fn unitLen(self: *const SealedChannel, bytes: []const u8) SealedError!usize {
        const header_len = self.unitHeaderLen();
        std.debug.assert(bytes.len >= header_len);
        return switch (self.phase) {
            .failed => 0,
            .handshake => header_len,
            .open => std.math.add(
                usize,
                header_len,
                noise.recordBodyLen(bytes[0..noise.RECORD_HEADER_BYTES].*),
            ) catch SealedError.InboundOverflow,
        };
    }

    fn consumeUnit(self: *SealedChannel, gpa: std.mem.Allocator, unit: []const u8) !Event {
        switch (self.phase) {
            .failed => return .need_input,
            .handshake => |*hs| {
                var payload: [identity_proof_bytes]u8 = undefined;
                const got = try hs.readMessage(unit, payload[0..]);
                switch (self.role) {
                    .responder => switch (hs.stage) {
                        1 => {
                            // Answer message one at once; message two is the
                            // only message this side writes.
                            if (self.pending_len != 0) return SealedError.HandshakeOutOfOrder;
                            const written = try hs.writeMessage(&self.local_proof, self.pending[0..]);
                            std.debug.assert(written.len == msg2_wire_bytes);
                            self.pending_len = written.len;
                            return .handshake;
                        },
                        3 => {
                            const claimed = try identity_binding.verifyProof(
                                got,
                                .initiator,
                                self.identity_context,
                                hs.remoteStatic() orelse return SealedError.IdentityMismatch,
                                null,
                            );
                            self.remote_identity = claimed;
                            return self.completeHandshake();
                        },
                        else => unreachable,
                    },
                    .initiator => {
                        // Message two proves the exact responder identity the
                        // dial named. Only then answer with our own proof.
                        std.debug.assert(hs.stage == 2);
                        if (self.pending_len != 0) return SealedError.HandshakeOutOfOrder;
                        _ = try identity_binding.verifyProof(
                            got,
                            .responder,
                            self.identity_context,
                            hs.remoteStatic() orelse return SealedError.IdentityMismatch,
                            self.remote_identity,
                        );
                        const written = try hs.writeMessage(&self.local_proof, self.pending[0..]);
                        std.debug.assert(written.len == msg3_wire_bytes);
                        self.pending_len = written.len;
                        return self.completeHandshake();
                    },
                }
            },
            .open => |*keys| {
                const header_len = noise.RECORD_HEADER_BYTES;
                const body_len = noise.recordBodyLen(unit[0..header_len].*);
                const plain_len = body_len -| noise.TAG_BYTES;
                // Reserve the plaintext scratch before touching cipher state,
                // so an allocation failure leaves the record staged and
                // retryable. No borrow is live here — the previous record's
                // plaintext expired when this call began — so a burst-grown
                // scratch may also shrink back to steady for a small record.
                std.crypto.secureZero(u8, self.plain);
                if (plain_len > self.plain.len) {
                    self.plain = try gpa.realloc(self.plain, plain_len);
                } else if (self.plain.len > steady_plain_bytes and plain_len <= steady_plain_bytes) {
                    // A failed shrink is not a failure: the larger scratch
                    // stays valid and the next small record tries again.
                    if (gpa.realloc(self.plain, steady_plain_bytes)) |shrunk| {
                        self.plain = shrunk;
                    } else |_| {}
                }
                const opened = try noise.openRecord(&keys.recv, unit[header_len..][0..body_len], self.plain[0..plain_len]);
                self.pending_plain_len = opened.len + 1;
                return .{ .plaintext = opened };
            },
        }
    }

    fn ensurePlainCapacityForUnitLen(self: *SealedChannel, gpa: std.mem.Allocator, unit_len: usize) !void {
        if (self.phase != .open) return;
        const body_len = unit_len - noise.RECORD_HEADER_BYTES;
        const plain_len = body_len -| noise.TAG_BYTES;
        if (plain_len > self.plain.len) self.plain = try gpa.realloc(self.plain, plain_len);
    }

    /// Retain an unread borrowed suffix across an upper-layer pause. This is a
    /// deliberate ownership transfer for byte-fed hosts; completion adapters
    /// retain the transport's receive-buffer borrow instead. Normal split-unit
    /// ingestion does not call this method.
    pub fn park(self: *SealedChannel, gpa: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len > std.math.maxInt(usize) - self.staged.len) {
            self.fail();
            return SealedError.InboundOverflow;
        }
        try self.staged.absorbBytesPrecise(gpa, bytes);
    }

    fn completeHandshake(self: *SealedChannel) !Event {
        const keys = try self.phase.handshake.split();
        self.phase = .{ .open = keys };
        return .{ .completed = self.remote_identity.? };
    }

    /// Drain the pending handshake message as one owned wire frame the
    /// embedder writes verbatim, or null. Always drained before any sealed
    /// frame, which is what keeps handshake bytes ahead of CapTP bytes.
    pub fn takeWire(self: *SealedChannel, gpa: std.mem.Allocator) std.mem.Allocator.Error!?frame.Frame {
        if (self.pending_len == 0) return null;
        const storage = try gpa.dupe(u8, self.pending[0..self.pending_len]);
        self.pending_len = 0;
        // A byte frame over byte-aligned storage cannot be shape-refused.
        return frame.Frame.initOwned(gpa, storage, .byte, .fromByteUnits(1)) catch unreachable;
    }

    /// Drain the pending handshake message into `out`, the loop-tier sibling
    /// of `takeWire` for an owner that stages ciphertext in a byte queue
    /// rather than moving whole frames. Appends nothing when none is pending.
    pub fn takeWireInto(self: *SealedChannel, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
        if (self.pending_len == 0) return;
        try out.appendSlice(gpa, self.pending[0..self.pending_len]);
        self.pending_len = 0;
    }

    /// Seal one encoded outbound frame into an owned wire frame the embedder
    /// writes verbatim: the outer Syrup prefix as its own small record, then
    /// the frame bytes across as many records as they need, so the plaintext
    /// stream inside the records is exactly the unsealed wire's.
    pub fn sealFrame(self: *SealedChannel, gpa: std.mem.Allocator, frame_bytes: []const u8) !frame.Frame {
        std.debug.assert(self.phase == .open);
        const keys = &self.phase.open;
        var prefix_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
        const prefix = stream_framing.renderPrefix(&prefix_buf, frame_bytes.len);
        const record_overhead = noise.RECORD_HEADER_BYTES + noise.TAG_BYTES;
        const body_records = std.math.divCeil(usize, frame_bytes.len, noise.MAX_RECORD_PLAINTEXT_BYTES) catch unreachable;
        const record_count = std.math.add(usize, 1, body_records) catch
            return SealedError.OutboundOverflow;
        try keys.send.ensureNonceCapacity(record_count);
        const overhead_bytes = std.math.mul(usize, record_count, record_overhead) catch
            return SealedError.OutboundOverflow;
        const framed_bytes = std.math.add(usize, prefix.len, frame_bytes.len) catch
            return SealedError.OutboundOverflow;
        const total = std.math.add(usize, overhead_bytes, framed_bytes) catch
            return SealedError.OutboundOverflow;
        const storage = try gpa.alloc(u8, total);
        errdefer gpa.free(storage);
        var written: usize = 0;
        written += (try noise.sealRecord(&keys.send, prefix, storage[written..])).len;
        var offset: usize = 0;
        while (offset < frame_bytes.len) {
            const take = @min(noise.MAX_RECORD_PLAINTEXT_BYTES, frame_bytes.len - offset);
            written += (try noise.sealRecord(&keys.send, frame_bytes[offset..][0..take], storage[written..])).len;
            offset += take;
        }
        std.debug.assert(written == storage.len);
        return frame.Frame.initOwned(gpa, storage, .byte, .fromByteUnits(1)) catch unreachable;
    }

    /// Seal an opaque chunk of the plaintext stream into records appended to
    /// `out`. The loop tier's outbound arm: what it is handed is already the
    /// framed wire stream (prefixes included), so record boundaries need no
    /// alignment with frame boundaries and none is created. An allocation
    /// refusal appends nothing and advances no cipher state, so the caller
    /// may retry the same bytes.
    pub fn sealBytes(self: *SealedChannel, gpa: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
        std.debug.assert(self.phase == .open);
        if (bytes.len == 0) return;
        const keys = &self.phase.open;
        const record_overhead = noise.RECORD_HEADER_BYTES + noise.TAG_BYTES;
        const records = std.math.divCeil(usize, bytes.len, noise.MAX_RECORD_PLAINTEXT_BYTES) catch unreachable;
        try keys.send.ensureNonceCapacity(records);
        const overhead_bytes = std.math.mul(usize, records, record_overhead) catch
            return SealedError.OutboundOverflow;
        const total = std.math.add(usize, overhead_bytes, bytes.len) catch
            return SealedError.OutboundOverflow;
        try out.ensureUnusedCapacity(gpa, total);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const take = @min(noise.MAX_RECORD_PLAINTEXT_BYTES, bytes.len - offset);
            const dest = out.unusedCapacitySlice();
            const sealed_len = (try noise.sealRecord(&keys.send, bytes[offset..][0..take], dest)).len;
            out.items.len += sealed_len;
            offset += take;
        }
    }

    /// Retire the channel: wipe the handshake or transport keys and drop any
    /// pending handshake message, so nothing can be derived from or written
    /// through it again. Idempotent; staged bytes are freed by `deinit`.
    pub fn fail(self: *SealedChannel) void {
        switch (self.phase) {
            .handshake => |*hs| hs.deinit(),
            .open => |*keys| {
                keys.send.deinit();
                keys.recv.deinit();
            },
            .failed => {},
        }
        self.phase = .failed;
        self.pending_plain_len = 0;
        std.crypto.secureZero(u8, self.pending[0..]);
        self.pending_len = 0;
    }

    /// Free the channel's owned memory, wiping keys first.
    pub fn deinit(self: *SealedChannel, gpa: std.mem.Allocator) void {
        self.fail();
        self.staged.deinit(gpa);
        std.crypto.secureZero(u8, self.plain);
        gpa.free(self.plain);
        self.plain = &.{};
    }
};
