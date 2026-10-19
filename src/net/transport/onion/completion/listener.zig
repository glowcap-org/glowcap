//! Listeners for the completion-backed onion adapter.
//!
//! A plain listener is the inner backend's own and passes through untouched.
//! An onion listener binds an inner listener, then publishes that exact bound
//! endpoint as a Tor onion service over one control connection. The control
//! connection stays open for the listener's lifetime, which is Tor's
//! undetached-service lifetime rule, so closing the listener withdraws the
//! service. One backend publishes one service.
//!
//! The publish conversation is a pending setup (ADR-0018): `open` binds the
//! inner listener and starts the control dial, and the conversation advances
//! one stage per completion on the adapter's own poll turns. It never blocks
//! the loop. `pending` reports an unfinished setup, `submitReady` completes
//! the runtime's listen-ready seat when the service exists or the setup has
//! failed, and the deadline is enforced on every turn the adapter sees.
//!
//! The row's state is exactly three bits of life: a running `setup`, a
//! terminal `failed` cause, and the runtime seat `ready_ud` still owed its
//! completion. A settled withdrawn row leaves the seat delivered and clears.

const std = @import("std");
const clock = @import("../../../clock.zig");
const completion = @import("../../../completion/loop.zig");
const onion_control = @import("../control.zig");
const onion_session = @import("../session.zig");
const socks5 = @import("../socks5.zig");
const state_mod = @import("state.zig");

pub fn Machine(comptime Backend: type, comptime Inner: type, comptime Types: type) type {
    return struct {
        pub const ServiceId = [socks5.service_id_len]u8;
        const Identity = Types.Identity;

        /// A published service: its id, and the key that restores it. Tor
        /// returns the key only for a service it minted; a restored service
        /// keeps the key it was given.
        pub const Published = struct {
            service_id: [socks5.service_id_len]u8,
            key: [onion_session.service_key_cap]u8,
            key_len: usize,
        };

        /// `onion` names the inner listener the service forwards to.
        pub const Target = union(enum) {
            platform: Inner.ListenTarget,
            onion: Inner.ListenTarget,
        };

        pub const Address = union(enum) {
            platform: Inner.ListenerAddress,
            onion: ServiceId,
        };

        /// One stage of the pending publish conversation.
        pub const Stage = enum { connecting, auth_send, auth_recv, publish_send, publish_recv };

        /// The pending setup's own state.
        pub const Setup = struct {
            stage: Stage = .connecting,
            deadline_ms: i64,
            /// The bound endpoint the service forwards to, read off the inner
            /// listener at `open`.
            forward_port: u16,
            /// The outbound control line (AUTHENTICATE or ADD_ONION) and its
            /// send progress. Tor may take one line across several sends.
            request: [onion_control.max_line_bytes]u8 = undefined,
            request_len: usize = 0,
            request_offset: usize = 0,
            /// A submission the pool or queue refused, re-armed on a later
            /// turn.
            submit_owed: bool = false,
            /// A received chunk still being read, and the reply line it is
            /// assembling across chunks.
            held: ?completion.Completion = null,
            held_offset: usize = 0,
            line: [onion_control.max_line_bytes]u8 = undefined,
            line_len: usize = 0,
            lines_seen: usize = 0,
            /// The reply harvest, in Tor's reply-line order.
            published: Published = .{ .service_id = undefined, .key = undefined, .key_len = 0 },
            have_id: bool = false,
        };

        /// The published listener. Its service is set only once the setup's
        /// conversation has published it, and `failed` names the terminal
        /// cause of a setup that never will.
        pub const State = struct {
            fd: ?Inner.Fd = null,
            service: Published = undefined,
            setup: ?Setup = null,
            failed: ?anyerror = null,
            ready_ud: ?u64 = null,
        };

        fn config(backend: *Backend) Types.ConfigType {
            return backend.config.?;
        }

        fn controlFd(backend: *const Backend) Inner.Fd {
            return backend.control_fd.?;
        }

        /// Bind the listener and start the publish conversation. Returns the
        /// inner descriptor at once; the service follows asynchronously.
        pub fn open(backend: *Backend, target: Target) !Inner.Fd {
            const inner_target = switch (target) {
                .platform => |platform_target| return backend.inner.openListener(platform_target),
                .onion => |onion_target| onion_target,
            };
            // A withdrawn row that still owes its seat is still open from the
            // seat's view; replacing it would leave that wait unanswered.
            if (backend.listener.fd != null or backend.listener.ready_ud != null) return error.ListenerAlreadyOpen;
            const cfg = config(backend);
            const control_target = cfg.control orelse return error.OnionControlNotConfigured;
            if (cfg.service_key.len > onion_session.service_key_cap) return error.ControlProtocolViolation;
            const fd = try backend.inner.openListener(inner_target);
            errdefer backend.inner.closeFd(fd);
            const bound = Inner.listenerPort(try backend.inner.listenerAddress(fd)) orelse
                return error.ListenerNotForwardable;
            var setup: Setup = .{ .deadline_ms = clock.nowMonotonicMs() + cfg.setup_timeout_ms, .forward_port = bound };
            @memcpy(setup.published.key[0..cfg.service_key.len], cfg.service_key);
            setup.published.key_len = cfg.service_key.len;
            backend.control_fd = try backend.inner.startDial(Types.setup_connect_ud, control_target);
            backend.control_ops += 1;
            backend.listener = .{ .fd = fd, .setup = setup };
            return fd;
        }

        /// Whether the served listener is still finishing its publish setup.
        pub fn pending(backend: *const Backend, fd: Inner.Fd) bool {
            if (!owns(backend, fd)) return false;
            return backend.listener.setup != null;
        }

        /// Complete `user_data` once the service exists (result 0) or the
        /// setup has terminally failed. A settled failure answers with its
        /// stored cause, so a late seat still learns the truth.
        pub fn submitReady(backend: *Backend, user_data: u64, fd: Inner.Fd) !void {
            if (!owns(backend, fd)) return error.ListenerClosed;
            const row = &backend.listener;
            if (row.failed) |cause| {
                try backend.ready.append(backend.allocator, .{
                    .user_data = user_data,
                    .result = -1,
                    .failure = cause,
                });
                return;
            }
            if (row.setup != null) {
                if (row.ready_ud != null) return error.AlreadyAccepting;
                row.ready_ud = user_data;
                return;
            }
            try backend.ready.append(backend.allocator, .{ .user_data = user_data, .result = 0 });
        }

        pub fn owns(backend: *const Backend, fd: Inner.Fd) bool {
            return backend.listener.fd == fd;
        }

        pub fn address(backend: *Backend, fd: Inner.Fd) !Address {
            if (owns(backend, fd)) {
                if (backend.listener.setup != null) return error.ControlSetupPending;
                if (backend.listener.failed) |cause| return cause;
                return .{ .onion = backend.listener.service.service_id };
            }
            return .{ .platform = try backend.inner.listenerAddress(fd) };
        }

        /// The key that restores the published service on `fd`. Null while
        /// the setup runs or failed, and for a platform listener.
        pub fn serviceKey(backend: *const Backend, fd: Inner.Fd) ?[]const u8 {
            if (!owns(backend, fd)) return null;
            if (backend.listener.setup != null or backend.listener.failed != null) return null;
            return backend.listener.service.key[0..backend.listener.service.key_len];
        }

        pub fn port(value: Address) ?u16 {
            return switch (value) {
                .platform => |platform_address| Inner.listenerPort(platform_address),
                .onion => null,
            };
        }

        /// Close the published listener. The service goes with its control
        /// connection. A setup still running loses its seat with it, and the
        /// seat completes failed on the next turn so no wait hangs.
        pub fn submitClose(backend: *Backend, user_data: u64, fd: Inner.Fd) !void {
            std.debug.assert(owns(backend, fd));
            try backend.inner.submitClose(user_data, fd);
            withdraw(backend);
        }

        pub fn close(backend: *Backend, fd: Inner.Fd) void {
            std.debug.assert(owns(backend, fd));
            withdraw(backend);
            backend.inner.closeFd(fd);
        }

        /// Drop the listener and its service. A running setup ends with its
        /// runtime seat completing failed, now or on the next turn when the
        /// queue has no room; the control connection closes asynchronously
        /// so its in-flight operations complete and drain. Once the service
        /// exists the connection is idle and closes at once.
        fn withdraw(backend: *Backend) void {
            if (backend.listener.setup) |*setup| {
                if (setup.held) |held| backend.inner.recycleBorrowed(held);
                backend.listener.setup = null;
                backend.listener.failed = error.ListenerClosed;
                if (backend.control_fd) |fd| closeControl(backend, fd);
                backend.listener.fd = null;
                return deliver(backend);
            }
            if (backend.control_fd) |fd| backend.inner.closeFd(fd);
            backend.control_fd = null;
            backend.listener = .{};
        }

        /// Advance the pending setup by one completion. Completions that name
        /// no live setup are late records of a withdrawn one, or the control
        /// connection's own close, and carry no consequence.
        pub fn advance(backend: *Backend, comp: completion.Completion) void {
            backend.control_ops -= 1;
            const op = Identity.op(comp.user_data);
            if (backend.listener.fd == null) return drop(backend, comp);
            const row = &backend.listener;
            const setup = &(row.setup orelse return drop(backend, comp));
            if (op == .close) return drop(backend, comp);
            if (clock.nowMonotonicMs() >= setup.deadline_ms) {
                // The deadline may pass during the inner wait that produced
                // this record, so a borrowed receive still returns here.
                drop(backend, comp);
                return fail(backend, error.ControlSetupTimedOut);
            }
            const stage = setup.stage;
            switch (stage) {
                .connecting => {
                    if (op != .connect) return drop(backend, comp);
                    if (comp.result < 0) return fail(backend, error.ControlConnectionLost);
                    const auth = onion_control.writeAuthenticate(&setup.request, config(backend).auth) catch
                        return fail(backend, error.ControlProtocolViolation);
                    setup.request_len = auth.len;
                    setup.request_offset = 0;
                    setup.stage = .auth_send;
                    armSend(backend, setup);
                },
                .auth_send, .publish_send => {
                    if (op != .send) return drop(backend, comp);
                    if (comp.result <= 0) return fail(backend, error.ControlConnectionLost);
                    const sent: usize = @intCast(comp.result);
                    if (sent > setup.request_len - setup.request_offset)
                        return fail(backend, error.ControlProtocolViolation);
                    setup.request_offset += sent;
                    if (setup.request_offset != setup.request_len) return armSend(backend, setup);
                    setup.stage = if (stage == .auth_send) .auth_recv else .publish_recv;
                    setup.lines_seen = 0;
                    setup.line_len = 0;
                    setup.submit_owed = false;
                    armRecv(backend, setup);
                },
                .auth_recv, .publish_recv => {
                    if (op != .recv) return drop(backend, comp);
                    if (comp.recv_no_buffer) {
                        setup.submit_owed = true;
                        return;
                    }
                    if (comp.result < 0 or comp.borrowed.recvBytes() == null) {
                        if (comp.borrowed.active()) backend.inner.recycleBorrowed(comp);
                        return fail(backend, error.ControlConnectionLost);
                    }
                    if (comp.result == 0) {
                        if (comp.borrowed.active()) backend.inner.recycleBorrowed(comp);
                        return fail(backend, error.ControlConnectionLost);
                    }
                    const bytes = comp.borrowed.recvBytes().?;
                    if (@as(usize, @intCast(comp.result)) != bytes.len) {
                        backend.inner.recycleBorrowed(comp);
                        return fail(backend, error.ControlProtocolViolation);
                    }
                    feed(backend, setup, comp);
                },
            }
        }

        /// Turn the setup once with no completion in hand: enforce the
        /// deadline, retry an owed submission, and deliver a completed seat.
        /// The adapter's poll calls this every turn.
        pub fn pump(backend: *Backend) void {
            if (backend.listener.fd != null) {
                if (backend.listener.setup) |*setup| {
                    if (clock.nowMonotonicMs() >= setup.deadline_ms) return fail(backend, error.ControlSetupTimedOut);
                    if (setup.submit_owed) rearm(backend, setup);
                }
            }
            deliver(backend);
        }

        fn rearm(backend: *Backend, setup: *Setup) void {
            setup.submit_owed = false;
            switch (setup.stage) {
                .connecting => {},
                .auth_send, .publish_send => armSend(backend, setup),
                .auth_recv, .publish_recv => armRecv(backend, setup),
            }
        }

        fn armSend(backend: *Backend, setup: *Setup) void {
            if (backend.inner.submitSend(
                Types.setup_send_ud,
                controlFd(backend),
                setup.request[setup.request_offset..setup.request_len],
            )) |_| {
                backend.control_ops += 1;
            } else |_| setup.submit_owed = true;
        }

        fn armRecv(backend: *Backend, setup: *Setup) void {
            if (backend.inner.submitRecv(Types.setup_recv_ud, controlFd(backend))) |_| {
                backend.control_ops += 1;
            } else |_| setup.submit_owed = true;
        }

        /// Fold one received chunk into the reply, line by line. A line ends
        /// at `\n` and may span chunks; the held borrow returns when its
        /// chunk is spent. Every consumed line either advances the stage or
        /// ends the setup, and any terminal step ends this walk.
        fn feed(backend: *Backend, setup: *Setup, comp: completion.Completion) void {
            setup.held = comp;
            setup.held_offset = 0;
            while (setup.held != null) {
                const held_bytes = setup.held.?.borrowed.recvBytes().?;
                const available = held_bytes[setup.held_offset..];
                const newline = std.mem.indexOfScalar(u8, available, '\n') orelse {
                    appendFragment(backend, setup, available);
                    if (backend.listener.setup == null) return;
                    backend.inner.recycleBorrowed(setup.held.?);
                    setup.held = null;
                    setup.held_offset = 0;
                    // The chunk is spent and the line is still short: ask
                    // for the next one, or the conversation stalls.
                    armRecv(backend, setup);
                    return;
                };
                const fragment = available[0..newline];
                setup.held_offset += newline + 1;
                const line = if (setup.line_len == 0)
                    onion_control.trimLineEnding(fragment)
                else blk: {
                    appendFragment(backend, setup, fragment);
                    if (backend.listener.setup == null) return;
                    const assembled = setup.line[0..setup.line_len];
                    setup.line_len = 0;
                    break :blk onion_control.trimLineEnding(assembled);
                };
                consumeLine(backend, setup, line);
                if (backend.listener.setup == null) return;
                if (setup.held_offset == held_bytes.len) {
                    backend.inner.recycleBorrowed(setup.held.?);
                    setup.held = null;
                    setup.held_offset = 0;
                }
            }
            // The chunk is spent with the reply still short: ask for the
            // next one. A stage that just left the reply never re-arms here.
            if (backend.listener.setup != null) switch (setup.stage) {
                .auth_recv, .publish_recv => armRecv(backend, setup),
                else => {},
            };
        }

        fn appendFragment(backend: *Backend, setup: *Setup, bytes: []const u8) void {
            if (bytes.len > setup.line.len - setup.line_len) return fail(backend, error.ControlReplyTooLong);
            @memcpy(setup.line[setup.line_len..][0..bytes.len], bytes);
            setup.line_len += bytes.len;
        }

        /// One complete reply line. Authentication expects only success
        /// lines; publication harvests the service id and key. A terminal
        /// line ends the setup either way, clearing it before return.
        fn consumeLine(backend: *Backend, setup: *Setup, line: []const u8) void {
            setup.lines_seen += 1;
            if (setup.lines_seen > 64) return fail(backend, error.ControlReplyTooLong);
            const reply = onion_control.parseLine(line) catch
                return fail(backend, error.ControlProtocolViolation);
            if (!reply.isOk()) return fail(backend, error.ControlRefused);
            switch (setup.stage) {
                .auth_recv => {
                    if (reply.continuation != .end) return;
                    var forward_buf: [32]u8 = undefined;
                    const forward = std.fmt.bufPrint(&forward_buf, "127.0.0.1:{d}", .{setup.forward_port}) catch
                        return fail(backend, error.ControlProtocolViolation);
                    const add = (if (config(backend).service_key.len == 0)
                        onion_control.writeAddOnionNew(&setup.request, .{ .address = forward })
                    else
                        onion_control.writeAddOnionRestore(&setup.request, config(backend).service_key, .{ .address = forward })) catch return fail(backend, error.ControlProtocolViolation);
                    setup.request_len = add.len;
                    setup.request_offset = 0;
                    setup.stage = .publish_send;
                    armSend(backend, setup);
                },
                .publish_recv => {
                    if (reply.field()) |field| {
                        if (std.mem.eql(u8, field.key, "ServiceID")) {
                            if (field.value.len != socks5.service_id_len)
                                return fail(backend, error.ControlProtocolViolation);
                            socks5.checkServiceId(field.value) catch
                                return fail(backend, error.ControlProtocolViolation);
                            @memcpy(&setup.published.service_id, field.value);
                            setup.have_id = true;
                        } else if (std.mem.eql(u8, field.key, "PrivateKey")) {
                            if (field.value.len > setup.published.key.len)
                                return fail(backend, error.ControlProtocolViolation);
                            @memcpy(setup.published.key[0..field.value.len], field.value);
                            setup.published.key_len = field.value.len;
                        }
                    }
                    if (reply.continuation != .end) return;
                    if (!setup.have_id) return fail(backend, error.ControlProtocolViolation);
                    complete(backend);
                },
                else => return fail(backend, error.ControlProtocolViolation),
            }
        }

        /// The service exists. The transient setup state dies here and the
        /// runtime's seat completes with the service, now or on the next
        /// turn when the queue has no room yet.
        fn complete(backend: *Backend) void {
            const row = &backend.listener;
            if (row.setup) |*setup| {
                if (setup.held) |held| backend.inner.recycleBorrowed(held);
                row.service = setup.published;
                row.setup = null;
            }
            if (row.ready_ud) |ud| {
                // tolerant: no queue room this turn; the seat and the row
                // wait, and the adapter's bounded turn cadence delivers on
                // the next one.
                backend.ready.append(backend.allocator, .{ .user_data = ud, .result = 0 }) catch return;
                row.ready_ud = null;
            }
        }

        /// The setup failed. The control connection closes asynchronously so
        /// its in-flight operations drain; the cause waits on the row until
        /// the runtime's seat completes.
        fn fail(backend: *Backend, cause: anyerror) void {
            const row = &backend.listener;
            if (row.setup) |*setup| {
                if (setup.held) |held| backend.inner.recycleBorrowed(held);
                row.setup = null;
            }
            row.failed = cause;
            if (backend.control_fd) |fd| closeControl(backend, fd);
            deliver(backend);
        }

        /// Close the control connection asynchronously so its in-flight
        /// operations complete and drain. A refused close submission closes
        /// it in place and owes no record.
        fn closeControl(backend: *Backend, fd: Inner.Fd) void {
            backend.control_fd = null;
            if (backend.inner.submitClose(Types.setup_close_ud, fd)) |_| {
                backend.control_ops += 1;
            } else |_| backend.inner.closeFd(fd);
        }

        /// Deliver any owed seat: a published service's success or a failed
        /// setup's cause. A withdrawn listener's row, fully settled, clears
        /// here. This runs on every poll, so an empty row is left alone: the
        /// row holds two line buffers, and resetting it zeroes them.
        fn deliver(backend: *Backend) void {
            const row = &backend.listener;
            // A seat waits while the conversation runs; only a settled row
            // has an outcome to deliver.
            if (row.setup != null) return;
            if (row.ready_ud) |ud| {
                const completion_record: completion.Completion = if (row.failed) |cause|
                    .{ .user_data = ud, .result = -1, .failure = cause }
                else
                    .{ .user_data = ud, .result = 0 };
                // tolerant: no queue room this turn; the seat, its outcome,
                // and the row wait for the adapter's next bounded turn.
                backend.ready.append(backend.allocator, completion_record) catch return;
                row.ready_ud = null;
            }
            if (row.failed != null and row.fd == null and row.setup == null and row.ready_ud == null) backend.listener = .{};
        }

        fn drop(backend: *Backend, comp: completion.Completion) void {
            if (comp.borrowed.active()) backend.inner.recycleBorrowed(comp);
        }
    };
}
