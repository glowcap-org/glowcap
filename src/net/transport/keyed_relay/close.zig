//! Bounded receive-side progress for a WebSocket close handshake.

const protocol = @import("../../websocket.zig").client_protocol;
const multiplexed_resident = @import("../../multiplexed_resident.zig");

pub const ReadProgress = enum { closed, wait_read, wait_write, failed };

/// Discard application data that was already in flight when this endpoint
/// sent Close, while still validating frames and answering control traffic.
/// One call performs at most one socket fill. Resident buffers bound work and
/// memory even when a peer keeps transmitting during shutdown.
pub fn drainAfterLocalClose(rs: anytype) ReadProgress {
    const r = rs.source.reader;
    var filled = false;
    while (true) {
        if (rs.read_closed) return .closed;
        if (rs.remaining > 0) {
            const available = r.buffered();
            if (available.len == 0) {
                if (filled) return .wait_read;
                filled = true;
                switch (rs.source.tryFill() catch {
                    rs.noteSourceFailure(error.ReadFailed);
                    return .failed;
                }) {
                    .progress => continue,
                    .would_block => return .wait_read,
                    .closed => {
                        rs.noteFailure(error.Truncated);
                        return .failed;
                    },
                }
            }
            const n: usize = @intCast(@min(@as(u64, available.len), rs.remaining));
            r.toss(n);
            rs.remaining -= n;
            continue;
        }

        const buffered = r.buffered();
        const parsed = (protocol.parseHeaderBytes(buffered) catch |err| {
            rs.noteFrameFailure(err);
            return .failed;
        }) orelse {
            if (filled) return .wait_read;
            filled = true;
            switch (rs.source.tryFill() catch {
                rs.noteSourceFailure(error.ReadFailed);
                return .failed;
            }) {
                .progress => continue,
                .would_block => return .wait_read,
                .closed => {
                    if (r.bufferedLen() != 0) rs.noteFailure(error.Truncated);
                    rs.read_closed = r.bufferedLen() == 0;
                    return if (rs.read_closed) .closed else .failed;
                },
            }
        };
        const body_len = protocol.controlPayloadLen(parsed.frame);
        if (buffered.len < parsed.header_len + body_len) {
            if (filled) return .wait_read;
            filled = true;
            switch (rs.source.tryFill() catch {
                rs.noteSourceFailure(error.ReadFailed);
                return .failed;
            }) {
                .progress => continue,
                .would_block => return .wait_read,
                .closed => {
                    rs.noteFailure(error.Truncated);
                    return .failed;
                },
            }
        }
        r.toss(parsed.header_len);
        const body = r.buffered()[0..body_len];
        const step = rs.applyFrame(parsed.frame, body, .staged) catch |err| {
            rs.noteFrameFailure(err);
            return .failed;
        };
        r.toss(body_len);
        if (rs.source.hasPendingWrite()) {
            const flush_result = rs.tryFlushPending();
            if (flush_result == multiplexed_resident.would_block) return .wait_write;
            if (flush_result < 0) return .failed;
        }
        if (step == .closed) return .closed;
    }
}
