//! Bounded Tor-control publication transaction for the completion backend.
//!
//! Listener construction must finish authentication and ADD_ONION before it
//! publishes the listener. This module owns that synchronous setup exchange,
//! including timeout cancellation, completion draining, and borrowed receive
//! retirement. The live SOCKS connection machine remains in the backend.

const std = @import("std");

const clock = @import("../../../clock.zig");
const completion = @import("../../../completion/loop.zig");
const onion_control = @import("../control.zig");
const socks5 = @import("../socks5.zig");
const onion_session = @import("../session.zig");

/// A published service: its id, and the key that restores it. Tor returns the
/// key only for a service it minted; a restored service keeps the key it was
/// given.
pub const Published = struct {
    service_id: [socks5.service_id_len]u8,
    key: [onion_session.service_key_cap]u8,
    key_len: usize,
};

/// Bind the setup transaction to one completion backend shape. Capturing the
/// adapter vocabulary once keeps every stage on the same namespace and
/// dispatch function without restating a parallel generic contract.
pub fn Transaction(
    comptime Backend: type,
    comptime Inner: type,
    comptime Namespace: type,
    comptime Types: type,
    comptime dispatch_internal: anytype,
) type {
    return struct {
        pub fn publish(
            backend: *Backend,
            target: Inner.ConnectTarget,
            port: u16,
            config: Types.ConfigType,
        ) !Published {
            const fd = try backend.inner.startDial(Types.setup_connect_ud, target);
            backend.control_fd = fd;
            errdefer {
                if (backend.control_fd != null) {
                    backend.inner.closeFd(fd);
                    backend.control_fd = null;
                }
            }
            const deadline_ms = clock.nowMonotonicMs() + config.setup_timeout_ms;
            const comp = try waitSetup(backend, fd, Types.setup_connect_ud, deadline_ms);
            if (comp.result < 0) return error.ControlConnectionLost;

            var reader: SetupReader = .{ .backend = backend, .fd = fd, .deadline_ms = deadline_ms };
            defer reader.deinit();
            var request: [onion_control.max_line_bytes]u8 = undefined;
            const auth = try onion_control.writeAuthenticate(&request, config.auth);
            try setupSend(backend, fd, auth, deadline_ms);
            try setupOk(&reader);

            var forward_buf: [32]u8 = undefined;
            const forward = try std.fmt.bufPrint(&forward_buf, "127.0.0.1:{d}", .{port});
            const add = if (config.service_key.len == 0)
                try onion_control.writeAddOnionNew(&request, .{ .address = forward })
            else
                try onion_control.writeAddOnionRestore(&request, config.service_key, .{ .address = forward });
            try setupSend(backend, fd, add, deadline_ms);

            var published: Published = .{ .service_id = undefined, .key = undefined, .key_len = 0 };
            if (config.service_key.len > published.key.len) return error.ControlProtocolViolation;
            @memcpy(published.key[0..config.service_key.len], config.service_key);
            published.key_len = config.service_key.len;
            var have_id = false;
            var lines: usize = 0;
            while (true) {
                lines += 1;
                if (lines > 64) return error.ControlReplyTooLong;
                const line = try reader.nextLine();
                const reply = onion_control.parseLine(line) catch return error.ControlProtocolViolation;
                if (!reply.isOk()) return error.ControlRefused;
                if (reply.field()) |field| if (std.mem.eql(u8, field.key, "ServiceID")) {
                    if (field.value.len != socks5.service_id_len) return error.ControlProtocolViolation;
                    socks5.checkServiceId(field.value) catch return error.ControlProtocolViolation;
                    @memcpy(&published.service_id, field.value);
                    have_id = true;
                } else if (std.mem.eql(u8, field.key, "PrivateKey")) {
                    if (field.value.len > published.key.len) return error.ControlProtocolViolation;
                    @memcpy(published.key[0..field.value.len], field.value);
                    published.key_len = field.value.len;
                };
                if (reply.continuation == .end) break;
            }
            if (!have_id) return error.ControlProtocolViolation;
            return published;
        }

        fn waitSetup(
            backend: *Backend,
            fd: Inner.Fd,
            wanted: u64,
            deadline_ms: i64,
        ) !completion.Completion {
            var out: [8]completion.Completion = undefined;
            while (true) {
                const remaining = deadline_ms - clock.nowMonotonicMs();
                if (remaining <= 0) {
                    try abortSetup(backend, fd, wanted);
                    return error.ControlSetupTimedOut;
                }
                const timeout_ms: i32 = @intCast(@min(remaining, std.math.maxInt(i32)));
                const n = try backend.inner.poll(&out, timeout_ms);
                try backend.ready.ensureUnusedCapacity(backend.allocator, n * 4);
                var found: ?completion.Completion = null;
                for (out[0..n]) |comp| {
                    if (comp.user_data == wanted and found == null) {
                        found = comp;
                    } else if (Namespace.ownsUserData(comp.user_data) and Types.Identity.id(comp.user_data) != 0) {
                        try dispatch_internal(backend, comp);
                    } else if (!Namespace.ownsUserData(comp.user_data)) {
                        backend.ready.appendAssumeCapacity(comp);
                    } else {
                        if (comp.borrowed.active()) backend.inner.recycleBorrowed(comp);
                        return error.UnexpectedControlCompletion;
                    }
                }
                if (found) |comp| return comp;
            }
        }

        /// A timed-out setup operation still owns an inner completion seat.
        /// Close the control handle and drain both records before returning to
        /// normal polling, where an id-zero setup completion would be invalid.
        fn abortSetup(backend: *Backend, fd: Inner.Fd, wanted: u64) !void {
            backend.inner.shutdownFd(fd);
            var close_submitted = false;
            var wanted_done = false;
            var close_done = false;
            var close_failed = false;
            var out: [8]completion.Completion = undefined;

            while (!wanted_done or (close_submitted and !close_done)) {
                if (!close_submitted) {
                    backend.inner.submitClose(Types.setup_close_ud, fd) catch {
                        const n = try backend.inner.poll(&out, 1);
                        try harvestSetupAbort(
                            backend,
                            out[0..n],
                            wanted,
                            &wanted_done,
                            &close_done,
                            &close_failed,
                        );
                        if (wanted_done) break;
                        continue;
                    };
                    close_submitted = true;
                }
                const n = try backend.inner.poll(&out, -1);
                try harvestSetupAbort(
                    backend,
                    out[0..n],
                    wanted,
                    &wanted_done,
                    &close_done,
                    &close_failed,
                );
            }

            if (!close_submitted or close_failed) backend.inner.closeFd(fd);
            backend.control_fd = null;
        }

        fn harvestSetupAbort(
            backend: *Backend,
            completions: []const completion.Completion,
            wanted: u64,
            wanted_done: *bool,
            close_done: *bool,
            close_failed: *bool,
        ) !void {
            try backend.ready.ensureUnusedCapacity(backend.allocator, completions.len * 4);
            for (completions) |comp| {
                if (comp.user_data == wanted and !wanted_done.*) {
                    wanted_done.* = true;
                    if (comp.borrowed.active()) backend.inner.recycleBorrowed(comp);
                } else if (comp.user_data == Types.setup_close_ud and !close_done.*) {
                    close_done.* = true;
                    close_failed.* = comp.result < 0;
                    if (comp.borrowed.active()) backend.inner.recycleBorrowed(comp);
                } else if (Namespace.ownsUserData(comp.user_data) and Types.Identity.id(comp.user_data) != 0) {
                    try dispatch_internal(backend, comp);
                } else if (!Namespace.ownsUserData(comp.user_data)) {
                    backend.ready.appendAssumeCapacity(comp);
                } else {
                    if (comp.borrowed.active()) backend.inner.recycleBorrowed(comp);
                    return error.UnexpectedControlCompletion;
                }
            }
        }

        fn setupSend(
            backend: *Backend,
            fd: Inner.Fd,
            bytes: []const u8,
            deadline_ms: i64,
        ) !void {
            var offset: usize = 0;
            while (offset < bytes.len) {
                try backend.inner.submitSend(Types.setup_send_ud, fd, bytes[offset..]);
                const comp = try waitSetup(backend, fd, Types.setup_send_ud, deadline_ms);
                if (comp.result <= 0) return error.ControlConnectionLost;
                const sent: usize = @intCast(comp.result);
                if (sent > bytes.len - offset) return error.ControlProtocolViolation;
                offset += sent;
            }
        }

        fn setupOk(reader: *SetupReader) !void {
            var lines: usize = 0;
            while (true) {
                lines += 1;
                if (lines > 64) return error.ControlReplyTooLong;
                const line = try reader.nextLine();
                const reply = onion_control.parseLine(line) catch return error.ControlProtocolViolation;
                if (!reply.isOk()) return error.ControlRefused;
                if (reply.continuation == .end) return;
            }
        }

        const SetupReader = struct {
            backend: *Backend,
            fd: Inner.Fd,
            deadline_ms: i64,
            held: ?completion.Completion = null,
            offset: usize = 0,
            line: [onion_control.max_line_bytes]u8 = undefined,
            line_len: usize = 0,

            fn deinit(self: *@This()) void {
                self.releaseHeld();
            }

            fn nextLine(self: *@This()) ![]const u8 {
                while (true) {
                    if (self.held) |held| {
                        const bytes = held.borrowed.recvBytes().?;
                        const available = bytes[self.offset..];
                        if (std.mem.indexOfScalar(u8, available, '\n')) |newline| {
                            const fragment = available[0..newline];
                            self.offset += newline + 1;
                            if (self.line_len == 0) return onion_control.trimLineEnding(fragment);
                            try self.append(fragment);
                            const line_len = self.line_len;
                            self.line_len = 0;
                            if (self.offset == bytes.len) self.releaseHeld();
                            return onion_control.trimLineEnding(self.line[0..line_len]);
                        }
                        try self.append(available);
                        self.releaseHeld();
                        continue;
                    }

                    try self.backend.inner.submitRecv(Types.setup_recv_ud, self.fd);
                    const comp = try waitSetup(self.backend, self.fd, Types.setup_recv_ud, self.deadline_ms);
                    if (comp.result <= 0 or comp.borrowed.recvBytes() == null) {
                        if (comp.borrowed.active()) self.backend.inner.recycleBorrowed(comp);
                        return error.ControlConnectionLost;
                    }
                    const bytes = comp.borrowed.recvBytes().?;
                    if (@as(usize, @intCast(comp.result)) != bytes.len) {
                        self.backend.inner.recycleBorrowed(comp);
                        return error.ControlProtocolViolation;
                    }
                    self.held = comp;
                    self.offset = 0;
                }
            }

            fn append(self: *@This(), bytes: []const u8) !void {
                if (bytes.len > self.line.len - self.line_len) return error.ControlReplyTooLong;
                @memcpy(self.line[self.line_len..][0..bytes.len], bytes);
                self.line_len += bytes.len;
            }

            fn releaseHeld(self: *@This()) void {
                const held = self.held orelse return;
                self.held = null;
                self.offset = 0;
                self.backend.inner.recycleBorrowed(held);
            }
        };
    };
}
