//! Completion-neutral storage and transition driver for one TLS client.
//!
//! Pollable sockets and completion backends own different I/O mechanics, but
//! the TLS engine has one buffer contract: an unconsumed ciphertext tail stays
//! at a stable address, produced ciphertext stays borrowed until the transport
//! acknowledges it, and the exact engine failure precedes cleanup failures.
//! This type owns those facts so no I/O projection can implement a subtly
//! different TLS state machine.

const foundation = @import("foundation");
const engine = @import("engine.zig");

/// TLS 1.3's maximum record plus expansion. Fixed per active secure channel.
/// Neither transport projection grows a partner-controlled ciphertext queue.
pub const record_bytes = 18 * 1024;

pub const Transform = struct {
    client: engine.Client,
    local_failure: ?engine.Failure = null,
    cipher_start: usize = 0,
    cipher_end: usize = 0,
    cipher_read: [record_bytes]u8 = undefined,
    cipher_write: [record_bytes]u8 = undefined,

    pub fn init(client: engine.Client) Transform {
        return .{ .client = client };
    }

    /// Advance one TLS transition over driver-owned buffers. Plaintext remains
    /// borrowed for this call. Produced ciphertext remains borrowed from this
    /// transform until `consumeCiphertext` acknowledges transport progress.
    pub fn step(
        self: *Transform,
        phase: engine.Phase,
        plaintext_in: []const u8,
        plaintext_out: []u8,
    ) error{TlsFailed}!engine.Step {
        const outcome = self.client.step(phase, .{
            .ciphertext_in = self.cipher_read[self.cipher_start..self.cipher_end],
            .ciphertext_out = &self.cipher_write,
            .plaintext_in = plaintext_in,
            .plaintext_out = plaintext_out,
        }) catch |err| {
            self.note(phase, err);
            return error.TlsFailed;
        };
        const transfer = switch (outcome) {
            .stepped => |result| result.transfer,
            .failed => |failed| failed.transfer,
        };
        self.cipher_start += transfer.ciphertext_consumed;
        if (self.cipher_start == self.cipher_end) {
            self.cipher_start = 0;
            self.cipher_end = 0;
        }
        return switch (outcome) {
            .stepped => |result| result,
            // The engine retains the exact failure. Do not replace it with the
            // transport-facing classification returned by this method.
            .failed => error.TlsFailed,
        };
    }

    pub fn pendingCiphertext(self: *const Transform) []const u8 {
        return self.client.pendingCiphertext();
    }

    pub fn bufferedCiphertext(self: *const Transform) usize {
        return self.cipher_end - self.cipher_start;
    }

    pub fn consumeCiphertext(
        self: *Transform,
        phase: engine.Phase,
        count: usize,
    ) error{TlsFailed}!void {
        self.client.consumeCiphertext(count) catch |err| {
            self.note(phase, err);
            return error.TlsFailed;
        };
    }

    /// Storage for the next transport receive. The returned slice stays valid
    /// until `commitCiphertext` or destruction. No engine call may intervene.
    pub fn ciphertextDestination(
        self: *Transform,
        phase: engine.Phase,
    ) error{TlsFailed}![]u8 {
        if (self.cipher_end == self.cipher_read.len and self.cipher_start != 0) {
            const unread_len = self.client.relocateCiphertext(
                phase,
                &self.cipher_read,
            ) catch |err| {
                self.note(phase, err);
                return error.TlsFailed;
            };
            self.cipher_start = 0;
            self.cipher_end = unread_len;
        }
        if (self.cipher_end == self.cipher_read.len) {
            self.note(phase, error.TlsCiphertextLimit);
            return error.TlsFailed;
        }
        return self.cipher_read[self.cipher_end..];
    }

    /// Admit the prefix the transport filled into the last destination.
    pub fn commitCiphertext(
        self: *Transform,
        phase: engine.Phase,
        count: usize,
    ) error{TlsFailed}!void {
        if (count > self.cipher_read.len - self.cipher_end) {
            self.note(phase, error.EngineContractViolation);
            return error.TlsFailed;
        }
        self.cipher_end += count;
        self.client.extendCiphertext(
            phase,
            self.cipher_read[self.cipher_start..self.cipher_end],
        ) catch |err| {
            self.note(phase, err);
            return error.TlsFailed;
        };
    }

    /// A transport EOF before the engine's authenticated close is truncation,
    /// regardless of which I/O projection observed it.
    pub fn noteTransportEof(self: *Transform, phase: engine.Phase) void {
        self.note(phase, error.TlsTruncated);
    }

    pub fn note(self: *Transform, phase: engine.Phase, cause: anyerror) void {
        foundation.latchFailure(&self.local_failure, .init(phase, cause));
    }

    pub fn takeFailure(self: *Transform) ?engine.Failure {
        var failure = self.local_failure;
        self.local_failure = null;
        if (self.client.takeFailure()) |engine_failure| {
            if (failure) |*primary|
                primary.chain.noteChain(engine_failure.chain)
            else
                failure = engine_failure;
        }
        return failure;
    }

    /// Consume the engine once and attach its destruction refusal behind the
    /// first transition/transport failure. No callerless failure is discarded.
    pub fn deinitOutcome(self: *Transform) ?engine.Failure {
        var failure = self.takeFailure();
        if (self.client.deinitOutcome()) |cleanup| {
            if (failure) |*primary|
                primary.chain.noteChain(cleanup.chain)
            else
                failure = cleanup;
        }
        self.* = undefined;
        return failure;
    }
};
