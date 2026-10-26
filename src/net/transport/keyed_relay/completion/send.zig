//! Bounded masked sends for the completion-backed relay carrier.
//!
//! One application write may become several WebSocket messages, but it keeps
//! one borrowed caller buffer and settles through one external completion.

const std = @import("std");

const completion = @import("../../../completion/contract.zig");
const protocol = @import("../../../websocket.zig").client_protocol;
const carrier_failure = @import("../../../carrier_failure.zig");

pub fn Machine(
    comptime Backend: type,
    comptime Types: type,
    comptime Access: type,
    comptime max_header_len: usize,
) type {
    return struct {
        const RelayConn = Types.RelayConn;
        const WsSendKind = Types.WsSendKind;

        pub fn submit(backend: *Backend, user_data: u64, fd: anytype, bytes: []const u8) !void {
            if (Access.idFromFd(fd)) |id| {
                const c = backend.conns.get(id) orelse return error.ConnectionLost;
                if (c.state != .open or c.close.wire != .open) return error.ConnectionLost;
                if (c.external_send_ud != null) return error.AlreadyWriting;
                const send_len = std.math.cast(i32, bytes.len) orelse return error.WriteTooLarge;
                if (bytes.len == 0) {
                    try backend.ready.ensureUnusedCapacity(backend.allocator, 1);
                    backend.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
                    return;
                }
                // A TLS transition can fail while admitting this write and
                // must then settle both this send and an already-owned receive
                // seat without allocating after the terminal transition.
                if (Access.isSecure(backend, c))
                    try backend.ready.ensureUnusedCapacity(backend.allocator, 2);
                c.external_send_ud = user_data;
                c.external_send_len = send_len;
                c.external_send_remainder = bytes;
                errdefer clearExternal(c);
                if (c.pending.get(.send)) {
                    // Only a control reply can own this seat: another
                    // application send would already hold external_send_ud.
                    std.debug.assert(c.ws_send_kind == .control);
                    return;
                }
                try stageExternalChunk(backend, c);
                return;
            }
            try backend.platform.submitSend(user_data, fd, bytes);
        }

        pub fn stageExternalChunk(backend: *Backend, c: *RelayConn) !void {
            if (c.external_send_ud == null or
                c.pending.get(.send) or
                c.state != .open or
                c.close.wire != .open) return;
            std.debug.assert(c.external_send_remainder.len != 0);
            const payload_limit = backend.send_staging_bytes - max_header_len;
            const take = @min(c.external_send_remainder.len, payload_limit);
            try queueAndDrive(
                backend,
                c,
                .application,
                .binary,
                c.external_send_remainder[0..take],
            );
            c.external_send_remainder = c.external_send_remainder[take..];
        }

        pub fn completeExternal(backend: *Backend, c: *RelayConn) void {
            const user_data = c.external_send_ud orelse return;
            backend.ready.appendAssumeCapacity(.{
                .user_data = user_data,
                .result = c.external_send_len,
            });
            clearExternal(c);
        }

        fn clearExternal(c: *RelayConn) void {
            c.external_send_ud = null;
            c.external_send_len = 0;
            c.external_send_remainder = &.{};
        }

        pub fn queueFrame(
            backend: *Backend,
            c: *RelayConn,
            kind: WsSendKind,
            opcode: protocol.OutgoingOpcode,
            bytes: []const u8,
        ) !void {
            std.debug.assert(kind == .application or kind == .control);
            std.debug.assert(c.ws_send_kind == .none and c.ws_out.items.len == 0);
            const relay = if (backend.relay) |*relay| relay else return error.NoRendezvousConfigured;
            var header: [max_header_len]u8 = undefined;
            const prefix = try protocol.writeFrameHeader(&header, opcode, bytes.len, @splat(0));
            const frame_len = try std.math.add(usize, prefix.len, bytes.len);
            if (frame_len > backend.send_staging_bytes) return error.SendStagingTooSmall;
            try c.ws_out.ensureTotalCapacityPrecise(backend.allocator, frame_len);
            // Entropy is consumed only after every fallible size and capacity
            // check, so rollback never copies or rewinds CSPRNG state.
            var mask: [4]u8 = undefined;
            relay.rng.random().bytes(&mask);
            @memcpy(header[prefix.len - mask.len .. prefix.len], &mask);
            c.ws_out.appendSliceAssumeCapacity(prefix);
            const start = c.ws_out.items.len;
            c.ws_out.appendSliceAssumeCapacity(bytes);
            for (c.ws_out.items[start..], 0..) |*b, i| b.* ^= mask[i % 4];
            c.ws_send_kind = kind;
            if (opcode == .close) c.close.wire.markSent();
        }

        pub fn queueAndDrive(
            backend: *Backend,
            c: *RelayConn,
            kind: WsSendKind,
            opcode: protocol.OutgoingOpcode,
            bytes: []const u8,
        ) !void {
            const old_close_handshake = c.close.wire;
            errdefer {
                Access.clearWsOut(backend, c);
                c.close.wire = old_close_handshake;
            }
            try queueFrame(backend, c, kind, opcode, bytes);
            try drive(backend, c);
        }

        pub fn drive(backend: *Backend, c: *RelayConn) !void {
            if (Access.isSecure(backend, c)) return Access.driveSecure(backend, c);
            // Closing admits no new wrapped send after platform close is
            // queued; an integer descriptor may otherwise already be reused.
            if (c.pending.get(.send) or c.ws_out_off == c.ws_out.items.len) return;
            try backend.platform.submitSend(
                Access.sendUserData(c.id),
                c.inner_fd,
                c.ws_out.items[c.ws_out_off..],
            );
            c.pending.arm(.send);
        }

        pub fn refuseExternal(backend: *Backend, c: *RelayConn) void {
            refuseExternalWith(backend, c, null, .transmit);
        }

        pub fn refuseExternalWith(
            backend: *Backend,
            c: *RelayConn,
            cause: ?anyerror,
            phase: carrier_failure.Phase,
        ) void {
            if (c.external_send_ud) |ud| {
                var borrowed = Access.borrowCarrierFailure(backend, c);
                if (cause != null and borrowed.carrierPhase() == null)
                    borrowed = borrowed.withPhase(phase);
                backend.ready.appendAssumeCapacity(.{
                    .user_data = ud,
                    .result = -1,
                    .failure = cause,
                    .borrowed = borrowed,
                });
                clearExternal(c);
            }
        }

        /// Transfer a wrapped backend's retained failure directly to the
        /// failing public send. The caller later returns the original borrow
        /// through this adapter, so no chain copy or failure-side allocation
        /// is needed for the clear carrier.
        pub fn refuseExternalBorrowed(
            backend: *Backend,
            c: *RelayConn,
            comp: completion.Completion,
            phase: carrier_failure.Phase,
        ) bool {
            const ud = c.external_send_ud orelse return false;
            if (comp.borrowed.failureChain() == null) return false;
            var borrowed = comp.borrowed;
            if (borrowed.carrierPhase() == null) borrowed = borrowed.withPhase(phase);
            backend.ready.appendAssumeCapacity(.{
                .user_data = ud,
                .result = -1,
                .failure = comp.failure,
                .borrowed = borrowed,
            });
            clearExternal(c);
            return true;
        }
    };
}
