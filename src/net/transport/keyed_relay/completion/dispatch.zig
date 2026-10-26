//! Wrapped-platform completion dispatch for the keyed-relay adapter.
//!
//! This is the transition router between platform operations and the bounded
//! upgrade, receive, send, and terminal-lifecycle subjects. It owns no second
//! queue or protocol policy.

const std = @import("std");

const completion = @import("../../../completion/loop.zig");
const carrier_failure = @import("../../../carrier_failure.zig");
const protocol = @import("../../../websocket.zig").client_protocol;
const buffers = @import("buffers.zig");
const route = @import("../route.zig");
const upgrade_request = @import("../upgrade_request.zig");

pub fn Machine(
    comptime Backend: type,
    comptime Types: type,
    comptime Access: type,
) type {
    return struct {
        const RelayConn = Types.RelayConn;
        const PlatformBufferDisposition = Types.PlatformBufferDisposition;

        pub fn dispatch(backend: *Backend, comp: completion.Completion) !void {
            const id = Access.internalId(comp.user_data);
            const c = backend.conns.get(id) orelse {
                if (comp.borrowed.active()) backend.platform.recycleBorrowed(comp);
                return;
            };
            // Every live completion retires one operation this adapter
            // admitted. Tolerating zero hides ownership drift across fd reuse.
            const op = Access.internalOp(comp.user_data);
            var borrow_transferred = false;
            defer if (op != .recv and comp.borrowed.active() and !borrow_transferred)
                backend.platform.recycleBorrowed(comp);
            if (op == .close) {
                std.debug.assert(c.inner_close == .in_flight);
            } else {
                c.pending.retire(op);
            }
            switch (op) {
                .connect => borrow_transferred = try onConnect(backend, c, comp),
                .recv => try onRecv(backend, c, comp),
                .send => borrow_transferred = try onSend(backend, c, comp),
                .close => {
                    if (comp.result < 0) {
                        c.close.failure = comp.failure orelse error.CloseFailed;
                        if (Access.isSecure(backend, c))
                            Access.securePlatformFailed(
                                backend,
                                c,
                                .shutdown,
                                comp,
                                error.CloseFailed,
                            );
                    }
                    c.inner_close = if (comp.result < 0) .failed else .closed;
                    Access.maybeFinish(backend, c);
                },
            }
            if (backend.conns.get(id)) |still_live| Access.maybeFinish(backend, still_live);
        }

        fn onRecv(backend: *Backend, c: *RelayConn, comp: completion.Completion) !void {
            if (comp.recv_no_buffer) {
                // Closing needs no replacement read. The retired operation can
                // still be the final edge after wrapped close completion.
                if (c.state != .closing and
                    c.external_recv_ud != null and
                    !backend.recv_retries.contains(c))
                {
                    backend.recv_retries.push(&backend.conns, c);
                }
                return;
            }

            var disposition: PlatformBufferDisposition = .recycle;
            defer if (comp.borrowed.active() and disposition == .recycle)
                backend.platform.recycleBorrowed(comp);
            if (comp.result < 0) {
                const phase = phaseFor(c, .recv);
                const cause = comp.failure orelse error.ReadFailed;
                if (Access.isSecure(backend, c)) {
                    Access.securePlatformFailed(backend, c, phase, comp, error.ReadFailed);
                } else if (c.external_recv_ud) |ud| {
                    if (comp.borrowed.failureChain() != null) {
                        var borrowed = comp.borrowed;
                        if (borrowed.carrierPhase() == null)
                            borrowed = borrowed.withPhase(phase);
                        backend.ready.appendAssumeCapacity(.{
                            .user_data = ud,
                            .result = -1,
                            .failure = comp.failure,
                            .borrowed = borrowed,
                        });
                        c.external_recv_ud = null;
                        disposition = .lent_to_caller;
                    }
                }
                Access.endWith(backend, c, -1, phase, cause);
            } else if (comp.result == 0) {
                if (Access.isSecure(backend, c))
                    Access.secureEof(backend, c)
                else
                    Access.end(backend, c, if (c.state == .open) 0 else -1);
            } else if (comp.borrowed.recvBytes()) |bytes| {
                if (Access.isSecure(backend, c)) {
                    try Access.secureReceive(backend, c, bytes);
                } else if (c.state == .open and
                    c.external_recv_ud != null and
                    buffers.rawBytes(c).len == 0)
                {
                    disposition = try Access.receivePlatform(backend, c, comp, bytes);
                } else if (c.state != .closing) {
                    // A canceled caller seat does not cancel a platform-owned
                    // recv. Preserve its bytes before recycling that buffer.
                    try buffers.appendRaw(backend, c, bytes);
                    try onBytes(backend, c);
                }
            } else {
                Access.fail(backend, c);
            }
        }

        fn onSend(backend: *Backend, c: *RelayConn, comp: completion.Completion) !bool {
            if (Access.isSecure(backend, c)) {
                if (comp.result <= 0) {
                    const phase = phaseFor(c, .send);
                    const cause = comp.failure orelse error.WriteFailed;
                    Access.securePlatformFailed(backend, c, phase, comp, error.WriteFailed);
                    Access.endWith(backend, c, -1, phase, cause);
                    return false;
                }
                try Access.secureSent(backend, c, comp.result);
                return false;
            }
            if (comp.result <= 0) {
                const phase = phaseFor(c, .send);
                const transferred = Access.refuseExternalBorrowed(backend, c, comp, phase);
                if (c.state == .closing) {
                    c.close.failure = comp.failure orelse error.WriteFailed;
                    Access.beginPlatformClose(backend, c);
                } else {
                    Access.endWith(
                        backend,
                        c,
                        -1,
                        phase,
                        comp.failure orelse error.WriteFailed,
                    );
                }
                return transferred;
            }

            c.ws_out_off += @intCast(comp.result);
            if (c.state == .closing) {
                if (!c.close.wire.hasSent() or c.ws_out_off == c.ws_out.items.len) {
                    buffers.clearSend(backend, c);
                    Access.advanceClose(backend, c);
                } else {
                    Access.driveSend(backend, c) catch Access.beginPlatformClose(backend, c);
                }
                return false;
            }
            if (c.ws_out_off == c.ws_out.items.len) {
                try finishWebSocketSend(backend, c);
            }
            if (c.state != .closing) try Access.driveSend(backend, c);
            if (c.state == .open and c.ws_out.items.len == 0)
                try Access.receiveBuffered(backend, c);
            return false;
        }

        pub fn finishWebSocketSend(backend: *Backend, c: *RelayConn) !void {
            const completed_kind = c.ws_send_kind;
            if (completed_kind == .upgrade) {
                // Upgrade scratch is deployment-sized, not a connection
                // memory floor, so release it as soon as the request lands.
                c.ws_out.deinit(backend.allocator);
                c.ws_out = .empty;
                c.ws_send_kind = .none;
            } else {
                buffers.clearSend(backend, c);
            }
            c.ws_out_off = 0;
            switch (completed_kind) {
                .upgrade => {
                    c.state = .reading_upgrade;
                    try Access.armPlatformRecv(backend, c);
                },
                .application => {
                    if (c.external_send_remainder.len == 0) {
                        Access.completeSend(backend, c);
                    } else {
                        try Access.serviceBuffered(backend, c);
                        try Access.stageSend(backend, c);
                    }
                },
                .control => {
                    try Access.serviceBuffered(backend, c);
                    try Access.stageSend(backend, c);
                },
                .none => unreachable,
            }
        }

        fn onConnect(backend: *Backend, c: *RelayConn, comp: completion.Completion) !bool {
            if (c.state == .closing) return false;
            if (comp.result < 0) {
                const cause = comp.failure orelse error.ConnectFailed;
                var transferred = false;
                if (Access.isSecure(backend, c)) {
                    Access.securePlatformFailed(backend, c, .connect, comp, error.ConnectFailed);
                } else if (c.external_connect_ud) |ud| {
                    if (comp.borrowed.failureChain() != null) {
                        var borrowed = comp.borrowed;
                        if (borrowed.carrierPhase() == null)
                            borrowed = borrowed.withPhase(.connect);
                        backend.ready.appendAssumeCapacity(.{
                            .user_data = ud,
                            .result = -1,
                            .failure = comp.failure,
                            .borrowed = borrowed,
                        });
                        c.external_connect_ud = null;
                        transferred = true;
                    }
                }
                Access.endWith(backend, c, -1, .connect, cause);
                return transferred;
            }
            try connected(backend, c);
            return false;
        }

        /// Continue one relay after the bounded address race has transferred
        /// its sole winning descriptor and joined every loser.
        pub fn connected(backend: *Backend, c: *RelayConn) !void {
            if (Access.isSecure(backend, c)) {
                c.state = .tls_handshake;
                try Access.driveSecure(backend, c);
            } else {
                c.state = .sending_upgrade;
                try Access.driveSend(backend, c);
            }
        }

        pub fn buildUpgrade(
            backend: *Backend,
            c: *RelayConn,
            relay_url: anytype,
            leg: route.Leg,
            designator: []const u8,
        ) !void {
            const relay = if (backend.relay) |*relay| relay else return error.NoRendezvousConfigured;
            var key_bytes: [16]u8 = undefined;
            relay.rng.random().bytes(&key_bytes);
            var key_b64: [24]u8 = undefined;
            _ = std.base64.standard.Encoder.encode(&key_b64, &key_bytes);
            protocol.acceptKey(&c.expected_accept, &key_b64);
            const request = relay_url.openRequest(leg, designator);
            const upgrade = upgrade_request.formatter(request, &key_b64);
            buffers.clearSend(backend, c);
            try c.ws_out.ensureTotalCapacityPrecise(
                backend.allocator,
                std.fmt.count("{f}", .{upgrade}),
            );
            try c.ws_out.print(backend.allocator, "{f}", .{upgrade});
            c.ws_send_kind = .upgrade;
        }

        pub fn onBytes(backend: *Backend, c: *RelayConn) !void {
            switch (c.state) {
                .reading_upgrade => try consumeUpgrade(backend, c),
                .open => try Access.receiveBuffered(backend, c),
                .parked => try Access.serviceParked(backend, c),
                .closing, .connecting, .tls_handshake, .sending_upgrade => {},
            }
        }

        pub fn failurePhase(c: *const RelayConn, comp: completion.Completion) carrier_failure.Phase {
            return phaseFor(c, Access.internalOp(comp.user_data));
        }

        fn consumeUpgrade(backend: *Backend, c: *RelayConn) !void {
            const raw = buffers.rawBytes(c);
            const marker = "\r\n\r\n";
            const marker_end = buffers.upgradeMarkerEnd(c.upgrade_buf.items, raw, marker) orelse {
                if (raw.len > protocol.max_upgrade_response_bytes -| c.upgrade_buf.items.len)
                    return Access.failWith(
                        backend,
                        c,
                        .websocket_upgrade,
                        error.UpgradeResponseTooLarge,
                    );
                try buffers.appendUpgrade(backend, c, raw);
                buffers.clearRaw(backend, c);
                try Access.armPlatformRecv(backend, c);
                return;
            };
            if (marker_end > protocol.max_upgrade_response_bytes -| c.upgrade_buf.items.len)
                return Access.failWith(
                    backend,
                    c,
                    .websocket_upgrade,
                    error.UpgradeResponseTooLarge,
                );
            try buffers.appendUpgrade(backend, c, raw[0..marker_end]);
            buffers.dropRaw(backend, c, marker_end);
            const header_end = c.upgrade_buf.items.len - marker.len;
            if (!protocol.validUpgradeResponse(c.upgrade_buf.items[0..header_end], &c.expected_accept))
                return Access.failWith(
                    backend,
                    c,
                    .websocket_upgrade,
                    error.InvalidWebSocketUpgrade,
                );
            c.upgrade_buf.deinit(backend.allocator);
            c.upgrade_buf = .empty;
            if (Access.isRegistrationLeg(backend, c.id)) {
                c.state = .parked;
                return Access.serviceParked(backend, c);
            }
            if (c.external_connect_ud != null)
                try backend.ready.ensureUnusedCapacity(backend.allocator, 1);
            c.state = .open;
            if (c.external_connect_ud) |ud| {
                backend.ready.appendAssumeCapacity(.{ .user_data = ud, .result = 0 });
                c.external_connect_ud = null;
            }
            try Access.receiveBuffered(backend, c);
        }

        fn phaseFor(c: *const RelayConn, op: Types.InternalOp) carrier_failure.Phase {
            return switch (op) {
                .connect => .connect,
                .close => .shutdown,
                .recv => if (c.state == .reading_upgrade)
                    .websocket_upgrade
                else
                    .receive,
                .send => if (c.state == .sending_upgrade)
                    .websocket_upgrade
                else if (c.state == .closing)
                    .shutdown
                else
                    .transmit,
            };
        }
    };
}
