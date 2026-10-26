//! Target for the TLS transform's ciphertext window in `test/net/fuzz_test.zig`.
//! The engine is the fuzzer: each step's status, interest, and transfer are
//! drawn bytes, so the search reaches every honest and dishonest engine answer
//! against every commit geometry a transport could present.
//!
//! Asserted: buffered ciphertext never exceeds `record_bytes`, a destination
//! never reaches past the window, a commit or consumption past what was
//! offered is refused with the window unmoved, a step that reports consuming
//! more than was buffered is refused `EngineContractViolation`, and every
//! refusal leaves exactly one typed failure in the phase it was refused in.
//! It does not reach a real engine's record parsing, which
//! `net/tls_engine_test.zig` owns. Validated by removing the commit bound in
//! `Transform.commitCiphertext`: the replayed corpus then reads past the window.

const std = @import("std");
const glowcap = @import("glowcap");

const tls = glowcap.net.tls.engine;
const transform = glowcap.net.tls.transform;
const record_bytes = transform.record_bytes;

/// The engine the fuzzer scripts one step at a time.
const Scripted = struct {
    next: tls.RawOutcome = .{ .stepped = .{} },

    fn client(self: *Scripted) tls.Client {
        return .init(self, &vtable);
    }

    fn step(raw: *anyopaque, _: tls.Phase, _: tls.Exchange) tls.RawOutcome {
        const self: *Scripted = @ptrCast(@alignCast(raw));
        return self.next;
    }

    fn deinit(_: *anyopaque) ?glowcap.foundation.FailureChain {
        return null;
    }

    const vtable: tls.VTable = .{ .step = step, .deinit = deinit };
};

const max_steps = 48;
const plaintext_room = 64;

pub fn window(_: void, smith: *std.testing.Smith) anyerror!void {
    var engine = Scripted{};
    var state = transform.Transform.init(engine.client());
    var phase: tls.Phase = .handshake;
    var plaintext_out: [plaintext_room]u8 = undefined;
    var steps: usize = 0;
    while (steps < max_steps and !smith.eos()) : (steps += 1) {
        const buffered = state.bufferedCiphertext();
        try std.testing.expect(buffered <= record_bytes);
        switch (smith.valueRangeAtMost(u8, 0, 2)) {
            0 => {
                const destination = state.ciphertextDestination(phase) catch return refused(&state, phase);
                try std.testing.expect(destination.len != 0);
                try std.testing.expect(destination.len <= record_bytes - state.bufferedCiphertext());
                const count: usize = smith.valueRangeAtMost(u32, 0, @intCast(destination.len + 1));
                state.commitCiphertext(phase, count) catch {
                    try std.testing.expectEqual(buffered, state.bufferedCiphertext());
                    return refused(&state, phase);
                };
                try std.testing.expectEqual(buffered + count, state.bufferedCiphertext());
            },
            1 => {
                const pending = state.pendingCiphertext().len;
                const consumed: usize = smith.valueRangeAtMost(u32, 0, @intCast(buffered + 1));
                const produced: usize = smith.valueRangeAtMost(u32, 0, @intCast(record_bytes + 1));
                engine.next = outcome(smith, phase, consumed, produced);
                const out = if (phase == .receive) plaintext_out[0..] else plaintext_out[0..0];
                const result = state.step(phase, &.{}, out) catch {
                    const failure = state.deinitOutcome() orelse return error.FailureLost;
                    try std.testing.expectEqual(phase, failure.phase);
                    if (pending == 0 and consumed > buffered)
                        try std.testing.expectEqualStrings("EngineContractViolation", failure.chain.primaryName());
                    return;
                };
                try std.testing.expect(consumed <= buffered);
                try std.testing.expectEqual(buffered - consumed, state.bufferedCiphertext());
                if (result.status == .established) phase = .receive;
            },
            else => {
                const pending = state.pendingCiphertext().len;
                const count: usize = smith.valueRangeAtMost(u32, 0, @intCast(pending + 1));
                state.consumeCiphertext(phase, count) catch {
                    try std.testing.expectEqual(pending, state.pendingCiphertext().len);
                    return refused(&state, phase);
                };
                try std.testing.expectEqual(pending - count, state.pendingCiphertext().len);
            },
        }
    }
    _ = state.deinitOutcome();
}

fn outcome(smith: *std.testing.Smith, phase: tls.Phase, consumed: usize, produced: usize) tls.RawOutcome {
    const transfer: tls.Transfer = .{
        .ciphertext_consumed = consumed,
        .ciphertext_produced = produced,
        .plaintext_produced = if (phase == .receive) smith.valueRangeAtMost(u32, 0, @intCast(plaintext_room + 1)) else 0,
    };
    if (smith.valueRangeAtMost(u8, 0, 7) == 0)
        return .{ .failed = .{ .failure = .init(phase, error.ScriptedEngineFailure), .transfer = transfer } };
    return .{ .stepped = .{
        .status = smith.value(tls.Status),
        .interest = .{ .read = smith.value(bool), .write = smith.value(bool) },
        .transfer = transfer,
    } };
}

/// A refusal leaves exactly one failure, in the phase it was refused in.
fn refused(state: *transform.Transform, phase: tls.Phase) anyerror!void {
    const failure = state.deinitOutcome() orelse return error.FailureLost;
    try std.testing.expectEqual(phase, failure.phase);
}

/// One turn of the script, as the ordinary suite replays it: one byte that
/// continues the loop, then eight little-endian bytes per drawn value.
fn turn(comptime draws: []const u64) []const u8 {
    comptime {
        var bytes: [1 + 8 * draws.len]u8 = undefined;
        bytes[0] = 0;
        for (draws, 0..) |draw, i| std.mem.writeInt(u64, bytes[1 + 8 * i ..][0..8], draw, .little);
        const frozen = bytes;
        return &frozen;
    }
}

/// The byte that ends a script.
const end = &[_]u8{1};

// Draw order per op: `0` commit draws the count, `1` step draws consumed,
// produced, plaintext produced (receive phase only), a selector that fails the
// step when zero, then status and the two interest bits, and `2` consume
// draws the count.
const commit_16 = turn(&.{ 0, 16 });
const step_consume_16 = turn(&.{ 1, 16, 0, 1, 0, 1, 0 });
const step_established = turn(&.{ 1, 0, 0, 1, 1, 1, 0 });

/// Scripts the suite replays: an honest commit and step, a handshake that
/// completes and a receive step that produces plaintext, a step that reports
/// more consumed than was buffered, a commit one byte past the window, and a
/// consumption past the pending output.
pub const corpus = [_][]const u8{
    commit_16 ++ step_consume_16 ++ end,
    commit_16 ++ step_established ++ turn(&.{ 1, 16, 0, 8, 1, 0, 1, 0 }) ++ end,
    turn(&.{ 1, 1, 0, 1, 0, 1, 0 }) ++ end,
    turn(&.{ 0, record_bytes + 1 }) ++ turn(&.{ 0, 0 }) ++ end,
    turn(&.{ 2, 1 }) ++ end,
};
