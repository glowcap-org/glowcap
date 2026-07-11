//! Comptime C-ABI loopback harness: the shared pumpStep / serveOnce / fetchOnce
//! spine for transport endpoint proofs. Consumers keep only transport-specific
//! listen/connect setup and instantiate `Harness(Transport)`.

const std = @import("std");
const pancake = @import("pancake");

const c = @import("c_abi");
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const fetch_pump = @import("fetch_pump.zig");

pub const frame_cap = 4096;

pub const Step = enum { received, closed };

/// Unsigned-handshake peer for boundary proofs; keyed verification lives in
/// `pairing_test`.
pub fn stubNegotiatingPeer(allocator: std.mem.Allocator) engine.Peer {
    return engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
}

pub fn Harness(comptime Transport: type) type {
    return struct {
        pub fn pumpStep(peer: *engine.Peer, conn: Transport.Conn) !Step {
            while ((try peer.step()) != .idle) {}
            while (peer.takeOutbound()) |frame_value| {
                var frame = frame_value;
                defer frame.deinit();
                const bytes = frame.bytes();
                var cf: c.PancakeFrame = .{
                    .bytes = bytes.ptr,
                    .len = bytes.len,
                    .shape = c.PANCAKE_FRAME_SHAPE_BYTE,
                };
                if (Transport.writeFrame(conn, &cf) != c.PANCAKE_OK) return error.WriteFailed;
            }

            var mf: c.PancakeManagedFrame = undefined;
            const rc = Transport.readFrame(conn, &mf);
            if (rc == c.PANCAKE_ERR_CLOSED) return .closed;
            if (rc != c.PANCAKE_OK) return error.ReadFailed;
            defer c.pancake_managed_frame_release(&mf);

            const bytes = (mf.bytes orelse return error.NullFrame)[0..mf.len];
            switch (try peer.recvStreamPrefix(bytes)) {
                .consumed => return .received,
                .incomplete => return error.PartialFrameFromEndpoint,
            }
        }

        pub const ServerArgs = struct {
            listener: Transport.Listener,
            allocator: std.mem.Allocator,
            start_session: model.Message,
            result: anyerror!void = {},
        };

        pub fn serveThread(args: *ServerArgs) void {
            args.result = serveOnce(args);
        }

        pub fn serveOnce(args: *ServerArgs) !void {
            var peer = stubNegotiatingPeer(args.allocator);
            defer peer.deinit();
            peer.session_state.limits.max_frame_bytes = frame_cap;
            _ = try peer.registerBootstrapCap("thermostat");

            var conn: ?Transport.Conn = null;
            if (Transport.accept(args.listener, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn) != c.PANCAKE_OK)
                return error.AcceptFailed;
            const conn_ptr = conn orelse return error.AcceptNull;
            defer Transport.releaseConn(conn_ptr);

            try peer.sendCopying(args.start_session);
            while ((try pumpStep(&peer, conn_ptr)) != .closed) {}
        }

        pub fn fetchOnce(
            conn: Transport.Conn,
            allocator: std.mem.Allocator,
            start_session: model.Message,
        ) !void {
            var peer = stubNegotiatingPeer(allocator);
            defer peer.deinit();
            peer.session_state.limits.max_frame_bytes = frame_cap;

            try peer.sendCopying(start_session);
            while (!fetch_pump.isOpen(&peer)) {
                if ((try pumpStep(&peer, conn)) == .closed) return error.ClosedDuringHandshake;
            }
            fetch_pump.drainEvents(&peer);

            const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &peer.session_state, "thermostat");
            try peer.send(prepared.message);

            var settled = false;
            while (!settled) {
                const step = try pumpStep(&peer, conn);
                while (peer.pollEvent()) |event_value| {
                    var event = event_value;
                    defer event.deinit();
                    if (try fetch_pump.matchFetchEvent(
                        allocator,
                        prepared.resolver_export,
                        prepared.answer_position,
                        &event,
                    )) |reference| {
                        model.freeReference(allocator, reference);
                        settled = true;
                    }
                }
                if (step == .closed) break;
            }

            try std.testing.expect(settled);
        }
    };
}
