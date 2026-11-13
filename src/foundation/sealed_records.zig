//! Outbound record sealing for ADR-0041's Noise channel: sizing a run of
//! plaintext spans as sealed records, then sealing them through the send
//! cipher. Each span fills whole records on its own boundary, so the
//! plaintext inside the records is exactly the unsealed stream.
//! `sealed.zig` owns the channel phase and calls these only while it is open.

const std = @import("std");

const noise = @import("noise.zig");

/// The record count and wire bytes that sealing a run of spans produces.
pub const Plan = struct { records: usize, bytes: usize };

/// The ways sizing refuses beyond a nonce verdict.
pub const PlanError = error{OutboundOverflow};

/// Size `spans` as sealed records and confirm `send` has a nonce for each.
/// Refuses before any cipher state advances.
pub fn plan(send: *const noise.CipherState, spans: []const []const u8) (noise.NoiseError || PlanError)!Plan {
    const record_overhead = noise.record_header_bytes + noise.tag_bytes;
    var result: Plan = .{ .records = 0, .bytes = 0 };
    for (spans) |span| {
        const count = @divCeil(span.len, noise.max_record_plaintext_bytes);
        result.records = std.math.add(usize, result.records, count) catch
            return error.OutboundOverflow;
        result.bytes = std.math.add(usize, result.bytes, span.len) catch
            return error.OutboundOverflow;
    }
    const overhead = std.math.mul(usize, result.records, record_overhead) catch
        return error.OutboundOverflow;
    result.bytes = std.math.add(usize, result.bytes, overhead) catch
        return error.OutboundOverflow;
    try send.ensureNonceCapacity(result.records);
    return result;
}

/// Seal `spans` into `out`, which `plan` sized, and return the bytes written.
pub fn sealSpans(send: *noise.CipherState, spans: []const []const u8, out: []u8) noise.NoiseError!usize {
    var written: usize = 0;
    for (spans) |span| {
        var offset: usize = 0;
        while (offset < span.len) {
            const take = @min(noise.max_record_plaintext_bytes, span.len - offset);
            written += (try noise.sealRecord(send, span[offset..][0..take], out[written..])).len;
            offset += take;
        }
    }
    return written;
}
