//! The SOCKS5 conversation an onion dial runs over its inner connection
//! before the leg opens: the greeting, the connect request, and the reply.
//! The backend routes each record of a handshake state here. The leg opens
//! only once the whole reply, its bound-address tail included, is consumed.

const completion = @import("../../../completion/loop.zig");
const socks5 = @import("../socks5.zig");

pub fn Handshake(comptime Self: type, comptime Types: type) type {
    return struct {
        const Conn = Types.Conn;
        const Identity = Types.Identity;

        /// Account `result` bytes of the greeting and read its reply once
        /// the whole greeting is out.
        pub fn greetingSent(self: *Self, c: *Conn, result: i32) void {
            const remaining = socks5.greeting.len - c.handshake_send_offset;
            if (result > remaining) return fail(self, c);
            c.handshake_send_offset += @intCast(result);
            if (c.handshake_send_offset != socks5.greeting.len) return submit(self, c);
            c.handshake_send_offset = 0;
            c.state = .greeting_recv;
            self.armRecv(c);
        }

        /// Account `result` bytes of the connect request and read the reply
        /// head once the whole request is out.
        pub fn requestSent(self: *Self, c: *Conn, result: i32) void {
            const remaining = c.request.len - c.handshake_send_offset;
            if (result > remaining) return fail(self, c);
            c.handshake_send_offset += @intCast(result);
            if (c.handshake_send_offset != c.request.len) return submit(self, c);
            c.handshake_send_offset = 0;
            c.state = .reply_recv;
            c.reply_len = 0;
            c.reply_expected = socks5.connect_reply_head_len;
            self.armRecv(c);
        }

        /// Take one chunk of the greeting reply, which must not run past it,
        /// and send the connect request once the reply checks.
        pub fn greetingReceived(self: *Self, c: *Conn, comp: completion.Completion, bytes: []const u8) void {
            const need = socks5.greeting_reply_len - c.greeting_reply_len;
            const take = @min(need, bytes.len);
            @memcpy(c.greeting_reply[c.greeting_reply_len..][0..take], bytes[0..take]);
            c.greeting_reply_len += @intCast(take);
            if (take != bytes.len) {
                self.inner.recycleBorrowed(comp);
                Self.Leg.failWith(self, &self.inner, c, .connect, socks5.Error.ProtocolViolation);
                return;
            }
            self.inner.recycleBorrowed(comp);
            if (c.greeting_reply_len != socks5.greeting_reply_len) {
                self.armRecv(c);
                return;
            }
            socks5.checkGreetingReply(&c.greeting_reply) catch |err| {
                Self.Leg.failWith(self, &self.inner, c, .connect, err);
                return;
            };
            c.state = .request_send;
            submit(self, c);
        }

        /// Apply one received chunk to the SOCKS reply this leg is waiting
        /// on. The accumulation is the state module's. This owns only what
        /// each verdict costs: the borrowed chunk, the leg's fate, and the
        /// caller's connect seat.
        pub fn consumeReply(self: *Self, c: *Conn, comp: completion.Completion) void {
            const bytes = comp.borrowed.recvBytes().?;
            switch (c.accumulateReply(bytes)) {
                .refused => |cause| {
                    self.inner.recycleBorrowed(comp);
                    Self.Leg.failWith(self, &self.inner, c, .connect, cause);
                },
                .need_more => {
                    self.inner.recycleBorrowed(comp);
                    self.armRecv(c);
                },
                .complete => |consumed| {
                    // Anything past the reply is application data that arrived
                    // coalesced behind it; retain the chunk so the first
                    // receive seat lends it before another read is armed.
                    if (consumed < bytes.len) {
                        c.held_recv = comp;
                        c.held_offset = @intCast(consumed);
                    } else self.inner.recycleBorrowed(comp);
                    c.state = .open;
                    if (c.external_connect_ud) |ud| {
                        self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = 0 });
                        c.external_connect_ud = null;
                    }
                },
            }
        }

        /// Send what remains of the greeting or the connect request.
        pub fn submit(self: *Self, c: *Conn) void {
            const whole: []const u8 = if (c.state == .greeting_send) &socks5.greeting else &c.request;
            const bytes = whole[c.handshake_send_offset..];
            self.inner.submitSend(Identity.userData(.send, c.id), c.inner_fd, bytes) catch {
                self.retries.oweSubmission(&self.conns, c, .send);
                return;
            };
            c.pending.arm(.send);
        }

        fn fail(self: *Self, c: *Conn) void {
            Self.Leg.fail(self, &self.inner, c);
        }
    };
}
