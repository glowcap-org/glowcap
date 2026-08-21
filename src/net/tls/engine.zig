//! Transport-neutral client TLS engine contract.
//!
//! A concrete engine transforms caller-owned ciphertext and plaintext buffers;
//! the driver owns socket I/O and readiness. Ciphertext produced by one step is
//! borrowed until explicitly consumed, so another step cannot overwrite bytes
//! a completion backend still has in flight. A blocked plaintext write likewise
//! pins the exact unconsumed tail across retries.

const std = @import("std");

const foundation = @import("foundation");
const carrier_detail = @import("../carrier_detail.zig");

pub const Phase = enum {
    handshake,
    receive,
    transmit,
    shutdown,
};

pub const Interest = packed struct(u2) {
    read: bool = false,
    write: bool = false,

    pub fn any(self: Interest) bool {
        return self.read or self.write;
    }
};

/// Engine-specific evidence retained without exporting a vendor type.
pub const Detail = carrier_detail.Detail;

pub const Failure = struct {
    phase: Phase,
    chain: foundation.FailureChain,
    detail: Detail = .{},

    pub fn init(phase: Phase, cause: anyerror) Failure {
        return .{ .phase = phase, .chain = .init(cause) };
    }
};

/// Buffers lent for one engine transition. Every slice stays caller-owned.
pub const Exchange = struct {
    ciphertext_in: []const u8 = &.{},
    ciphertext_out: []u8 = &.{},
    plaintext_in: []const u8 = &.{},
    plaintext_out: []u8 = &.{},
};

pub const Transfer = struct {
    ciphertext_consumed: usize = 0,
    ciphertext_produced: usize = 0,
    plaintext_consumed: usize = 0,
    plaintext_produced: usize = 0,

    pub fn any(self: Transfer) bool {
        return self.ciphertext_consumed != 0 or self.ciphertext_produced != 0 or
            self.plaintext_consumed != 0 or self.plaintext_produced != 0;
    }
};

pub const Status = enum {
    progress,
    established,
    clean_close,
};

pub const Step = struct {
    status: Status = .progress,
    interest: Interest = .{},
    transfer: Transfer = .{},
};

pub const Failed = struct {
    failure: Failure,
    /// A fatal TLS transition may still have emitted a peer alert. The caller
    /// drains those ciphertext bytes before destroying the engine.
    transfer: Transfer = .{},
};

pub const RawOutcome = union(enum) {
    stepped: Step,
    failed: Failed,
};

pub const VTable = struct {
    step: *const fn (ctx: *anyopaque, phase: Phase, exchange: Exchange) RawOutcome,
    deinit: *const fn (ctx: *anyopaque) ?foundation.FailureChain,
};

const State = enum {
    handshaking,
    established,
    peer_closed,
    shutdown,
    failed,
};

pub const StepError = error{ OutputPending, EngineContractViolation, Terminal };

/// One owned engine instance. `deinitOutcome` consumes it exactly once.
pub const Client = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    state: State = .handshaking,
    terminal_failure: ?Failure = null,
    pending_ciphertext: []const u8 = &.{},
    retry_ciphertext: ?[]const u8 = null,
    retry_plaintext: ?[]const u8 = null,

    pub fn init(ctx: *anyopaque, vtable: *const VTable) Client {
        return .{ .ctx = ctx, .vtable = vtable };
    }

    /// Advance one TLS phase. Calling while produced ciphertext remains
    /// undrained is retryable local state, not a transport failure.
    pub fn step(self: *Client, phase: Phase, exchange: Exchange) StepError!RawOutcome {
        if (self.pending_ciphertext.len != 0) return error.OutputPending;
        if (self.state == .failed or self.state == .shutdown) return error.Terminal;
        if (!self.phaseAllowed(phase)) return self.failContract(phase);
        if (!validExchange(phase, exchange)) return self.failContract(phase);
        if (!sameTail(self.retry_ciphertext, exchange.ciphertext_in) or
            !sameTail(self.retry_plaintext, exchange.plaintext_in))
            return self.failContract(phase);

        const outcome = self.vtable.step(self.ctx, phase, exchange);
        const transfer = switch (outcome) {
            .stepped => |step_result| step_result.transfer,
            .failed => |failed| failed.transfer,
        };
        if (!validTransfer(phase, exchange, transfer)) return self.failContract(phase);
        self.retry_ciphertext = remaining(exchange.ciphertext_in, transfer.ciphertext_consumed);
        self.retry_plaintext = remaining(exchange.plaintext_in, transfer.plaintext_consumed);
        if (transfer.ciphertext_produced != 0)
            self.pending_ciphertext = exchange.ciphertext_out[0..transfer.ciphertext_produced];

        switch (outcome) {
            .stepped => |step_result| {
                if (!validStep(phase, step_result)) return self.failContract(phase);
                switch (step_result.status) {
                    .progress => {},
                    .established => self.state = .established,
                    .clean_close => self.state = if (phase == .shutdown) .shutdown else .peer_closed,
                }
            },
            .failed => |failed| {
                if (failed.failure.phase != phase or
                    failed.transfer.plaintext_consumed != 0 or
                    failed.transfer.plaintext_produced != 0)
                    return self.failContract(phase);
                self.state = .failed;
                self.terminal_failure = failed.failure;
            },
        }
        return outcome;
    }

    pub fn pendingCiphertext(self: *const Client) []const u8 {
        return self.pending_ciphertext;
    }

    /// Acknowledge bytes the socket owner delivered. Partial completion keeps
    /// the exact remaining tail borrowed and forbids another engine step.
    pub fn consumeCiphertext(self: *Client, count: usize) error{InvalidConsumption}!void {
        if (count > self.pending_ciphertext.len) return error.InvalidConsumption;
        self.pending_ciphertext = self.pending_ciphertext[count..];
    }

    /// Move an unconsumed inbound tail inside driver-owned storage. Engines
    /// borrow input only for `step`; the client performs the overlapping copy
    /// so the contract guard cannot observe an already-mutated source.
    pub fn relocateCiphertext(
        self: *Client,
        phase: Phase,
        destination: []u8,
    ) error{EngineContractViolation}!usize {
        const expected = self.retry_ciphertext orelse return self.failContract(phase);
        if (destination.len < expected.len) return self.failContract(phase);
        std.mem.copyForwards(u8, destination[0..expected.len], expected);
        self.retry_ciphertext = destination[0..expected.len];
        return expected.len;
    }

    /// Admit newly received bytes after an exact retained ciphertext tail.
    /// The old tail must remain the prefix at the same stable address.
    pub fn extendCiphertext(
        self: *Client,
        phase: Phase,
        bytes: []const u8,
    ) error{EngineContractViolation}!void {
        const expected = self.retry_ciphertext orelse return;
        if (bytes.ptr != expected.ptr or bytes.len < expected.len)
            return self.failContract(phase);
        self.retry_ciphertext = bytes;
    }

    /// Claim the terminal engine failure without destroying the client. The
    /// stream owner can therefore project an exact failure once, while the
    /// later destruction barrier remains free to report independent cleanup.
    pub fn takeFailure(self: *Client) ?Failure {
        const failure = self.terminal_failure;
        self.terminal_failure = null;
        return failure;
    }

    /// Consume the engine and combine destruction failure with the first TLS
    /// failure. An implicit destruction failure becomes a shutdown failure;
    /// no callerless result is discarded here.
    pub fn deinitOutcome(self: *Client) ?Failure {
        var result = self.terminal_failure;
        if (self.pending_ciphertext.len != 0)
            noteCleanup(&result, error.TlsCiphertextAbandoned);
        if (self.retry_plaintext != null)
            noteCleanup(&result, error.TlsPlaintextAbandoned);
        if (self.vtable.deinit(self.ctx)) |cleanup| {
            if (result) |*primary| {
                primary.chain.noteChain(cleanup);
            } else {
                result = .{ .phase = .shutdown, .chain = cleanup };
            }
        }
        self.* = undefined;
        return result;
    }

    fn phaseAllowed(self: *const Client, phase: Phase) bool {
        return switch (self.state) {
            .handshaking => phase == .handshake,
            .established => phase == .receive or phase == .transmit or phase == .shutdown,
            .peer_closed => phase == .shutdown,
            .shutdown, .failed => false,
        };
    }

    fn failContract(self: *Client, phase: Phase) error{EngineContractViolation} {
        self.state = .failed;
        self.terminal_failure = .init(phase, error.EngineContractViolation);
        return error.EngineContractViolation;
    }
};

fn noteCleanup(result: *?Failure, cause: anyerror) void {
    if (result.*) |*primary| {
        primary.chain.note(cause);
    } else {
        result.* = .init(.shutdown, cause);
    }
}

fn remaining(bytes: []const u8, consumed: usize) ?[]const u8 {
    if (consumed == bytes.len) return null;
    return bytes[consumed..];
}

fn sameTail(expected: ?[]const u8, actual: []const u8) bool {
    const tail = expected orelse return true;
    return tail.ptr == actual.ptr and tail.len == actual.len;
}

fn validExchange(phase: Phase, exchange: Exchange) bool {
    return switch (phase) {
        .handshake, .shutdown => exchange.plaintext_in.len == 0 and exchange.plaintext_out.len == 0,
        .receive => exchange.plaintext_in.len == 0 and exchange.plaintext_out.len != 0,
        .transmit => exchange.plaintext_out.len == 0 and exchange.plaintext_in.len != 0,
    };
}

fn validTransfer(phase: Phase, exchange: Exchange, transfer: Transfer) bool {
    if (transfer.ciphertext_consumed > exchange.ciphertext_in.len or
        transfer.ciphertext_produced > exchange.ciphertext_out.len or
        transfer.plaintext_consumed > exchange.plaintext_in.len or
        transfer.plaintext_produced > exchange.plaintext_out.len)
        return false;
    if (phase != .transmit and transfer.plaintext_consumed != 0) return false;
    if (phase != .receive and transfer.plaintext_produced != 0) return false;
    return true;
}

fn validStep(phase: Phase, step_result: Step) bool {
    return switch (step_result.status) {
        .progress => step_result.transfer.any() or step_result.interest.any(),
        .established => phase == .handshake,
        .clean_close => phase == .receive or phase == .shutdown,
    };
}
