//! Completion driver for the transport-neutral TLS transform.
//!
//! The transform owns TLS transitions and fixed record storage. This driver
//! owns only completion mechanics: one platform send/receive at a time,
//! direct plaintext production into the WebSocket input spill, and the exact
//! point at which a logical WebSocket send is complete. It allocates one
//! secure-only state object per WSS connection and no thread or payload queue.
//! Refused submissions use allocation-free intrusive retry links.

const std = @import("std");

const completion = @import("../../../completion/contract.zig");
const carrier_failure = @import("../../../carrier_failure.zig");
const engine = @import("../../../tls/engine.zig");
const buffers = @import("buffers.zig");

const plaintext_chunk_bytes: usize = 2048;
const max_drive_steps: usize = 32;
const send_retry_batch: usize = 256;

pub fn Machine(
    comptime Backend: type,
    comptime Types: type,
    comptime Access: type,
) type {
    return struct {
        const RelayConn = Types.RelayConn;
        const TlsState = Types.TlsState;

        pub fn has(backend: *const Backend, c: *const RelayConn) bool {
            return backend.secure.contains(c.id);
        }

        pub fn borrowFailure(backend: *Backend, c: *RelayConn) ?completion.Borrowed {
            const secure = backend.secure.get(c.id) orelse return null;
            const failure = if (secure.failure) |*value| value else return null;
            secure.failure_borrows +|= 1;
            return .carrierFailure(failure, Access.failureToken(c.id));
        }

        pub fn recycleFailure(backend: *Backend, id: Types.ConnId) void {
            const secure = backend.secure.get(id) orelse return;
            std.debug.assert(secure.failure_borrows != 0);
            secure.failure_borrows -= 1;
        }

        pub fn hasBorrowedFailure(backend: *const Backend, c: *const RelayConn) bool {
            const secure = backend.secure.get(c.id) orelse return false;
            return secure.failure_borrows != 0;
        }

        /// Reserve secure storage before any platform or TLS operation is
        /// admitted. The later engine-open outcome is therefore infallibly
        /// adopted into an already-owned connection transaction.
        pub fn prepare(backend: *Backend, c: *RelayConn) !void {
            std.debug.assert(!has(backend, c));
            try backend.secure.ensureUnusedCapacity(backend.allocator, 1);
            const secure = try backend.allocator.create(TlsState);
            errdefer backend.allocator.destroy(secure);
            secure.* = .{ .id = c.id };
            backend.secure.putAssumeCapacity(c.id, secure);
        }

        pub fn adoptClient(backend: *Backend, c: *RelayConn, client: engine.Client) void {
            const secure = backend.secure.get(c.id) orelse unreachable;
            std.debug.assert(secure.lifecycle == .pending);
            secure.lifecycle = .{ .active = .init(client) };
        }

        /// Engine-open refusal has no client to retire. The dial transaction
        /// owns the returned failure. This state only records that its
        /// pre-reserved storage no longer carries a live engine. status-allow: lifecycle transition
        pub fn abandonPending(backend: *Backend, c: *RelayConn) void {
            const secure = backend.secure.get(c.id) orelse unreachable;
            std.debug.assert(secure.lifecycle == .pending);
            secure.lifecycle = .retired;
        }

        /// Retire a client that never reached connection admission. The dial
        /// transaction receives the exact TLS cleanup outcome and attaches it
        /// behind its connect/resolve/cancellation primary.
        pub fn retireDial(backend: *Backend, c: *RelayConn) ?carrier_failure.Failure {
            const secure = backend.secure.get(c.id) orelse return null;
            const failure = secure.deinit();
            secure.* = .{ .id = c.id, .lifecycle = .retired, .failure = failure };
            return failure;
        }

        /// Retry only ciphertext sends the platform refused before admission.
        /// The secure-state links make this O(owed work), allocation-free, and
        /// bounded per loop turn. The TLS engine keeps the exact output slice.
        pub fn retryPendingSends(backend: *Backend) void {
            const attempts = @min(backend.tls_send_retries.count, send_retry_batch);
            for (0..attempts) |_| {
                const secure = backend.tls_send_retries.pop(&backend.secure) orelse unreachable;
                const c = backend.conns.get(secure.id) orelse unreachable;
                drive(backend, c);
            }
        }

        /// Drive through a terminal outcome. Once TLS consumes plaintext or
        /// emits ciphertext, a later adapter refusal cannot be returned as if
        /// the caller still owned an untouched transaction. It settles through
        /// the already-reserved operation completion instead.
        pub fn drive(backend: *Backend, c: *RelayConn) void {
            driveInner(backend, c) catch |err| {
                const secure = backend.secure.get(c.id) orelse return;
                fail(backend, c, currentPhase(c, secure), err);
            };
        }

        fn driveInner(backend: *Backend, c: *RelayConn) !void {
            const secure = backend.secure.get(c.id) orelse return;
            var steps: usize = 0;
            while (steps < max_drive_steps) : (steps += 1) {
                const transform = secure.activeTransform();
                if (transform.pendingCiphertext().len != 0) {
                    if (!c.pending.get(.send)) {
                        backend.platform.submitSend(
                            Access.sendUserData(c.id),
                            c.inner_fd,
                            transform.pendingCiphertext(),
                        ) catch {
                            if (!backend.tls_send_retries.contains(secure))
                                backend.tls_send_retries.push(&backend.secure, secure);
                            return;
                        };
                        c.pending.arm(.send);
                    }
                    return;
                }
                if (c.pending.get(.send)) return;

                if (secure.shutting_down) {
                    if (secure.shutdown_complete) {
                        retire(backend, c);
                        Access.beginPlatformClose(backend, c);
                        return;
                    }
                    const transition = transform.step(.shutdown, &.{}, &.{}) catch {
                        fail(backend, c, .shutdown, error.TlsShutdownFailed);
                        return;
                    };
                    secure.interest = transition.interest;
                    if (transition.status == .clean_close) {
                        secure.shutdown_complete = true;
                        // A clean terminal transition may also produce the
                        // final close-notify record. The loop-top owns its
                        // submission; `sent` consumes it and re-enters here
                        // to retire the now-empty terminal transform.
                        if (transform.pendingCiphertext().len != 0) continue;
                        retire(backend, c);
                        Access.beginPlatformClose(backend, c);
                        return;
                    }
                    if (!transition.transfer.any()) return armForInterest(backend, c, secure.interest);
                    continue;
                }

                if (c.state == .tls_handshake) {
                    const transition = transform.step(.handshake, &.{}, &.{}) catch {
                        fail(backend, c, .handshake, error.TlsHandshakeFailed);
                        return;
                    };
                    secure.interest = transition.interest;
                    if (transition.status == .established) {
                        c.state = .sending_upgrade;
                        continue;
                    }
                    if (!transition.transfer.any()) return armForInterest(backend, c, secure.interest);
                    continue;
                }

                if (c.ws_out_off != c.ws_out.items.len) {
                    const transition = transform.step(
                        .transmit,
                        c.ws_out.items[c.ws_out_off..],
                        &.{},
                    ) catch {
                        fail(backend, c, .transmit, error.TlsTransmitFailed);
                        return;
                    };
                    secure.interest = transition.interest;
                    c.ws_out_off += transition.transfer.plaintext_consumed;
                    if (c.ws_out_off == c.ws_out.items.len and
                        transform.pendingCiphertext().len == 0)
                    {
                        try Access.finishWebSocketSend(backend, c);
                        if (!has(backend, c)) return;
                        if (c.state == .closing) return Access.advanceClose(backend, c);
                    }
                    if (!transition.transfer.any()) return armForInterest(backend, c, secure.interest);
                    continue;
                }

                if (c.ws_send_kind != .none) {
                    try Access.finishWebSocketSend(backend, c);
                    if (!has(backend, c)) return;
                    if (c.state == .closing) return Access.advanceClose(backend, c);
                    continue;
                }

                if (transform.bufferedCiphertext() != 0) {
                    const destination = buffers.rawDestination(
                        backend,
                        c,
                        plaintext_chunk_bytes,
                    ) catch {
                        fail(backend, c, .receive, error.OutOfMemory);
                        return;
                    };
                    const transition = transform.step(
                        .receive,
                        &.{},
                        destination,
                    ) catch {
                        fail(backend, c, .receive, error.TlsReceiveFailed);
                        return;
                    };
                    secure.interest = transition.interest;
                    buffers.commitRaw(c, transition.transfer.plaintext_produced);
                    if (transition.transfer.plaintext_produced != 0) {
                        try Access.onPlaintext(backend, c);
                        if (!has(backend, c) or c.state == .closing) return;
                    }
                    if (transition.status == .clean_close) {
                        retire(backend, c);
                        Access.end(backend, c, 0);
                        return;
                    }
                    if (!transition.transfer.any()) return armForInterest(backend, c, secure.interest);
                    continue;
                }

                return armForInterest(backend, c, secure.interest);
            }
            fail(backend, c, currentPhase(c, secure), error.TlsNoProgress);
        }

        pub fn receive(
            backend: *Backend,
            c: *RelayConn,
            bytes: []const u8,
        ) !void {
            const secure = backend.secure.get(c.id) orelse return error.TlsStateMissing;
            const transform = secure.activeTransform();
            var remaining = bytes;
            while (remaining.len != 0) {
                const phase = currentPhase(c, secure);
                const destination = transform.ciphertextDestination(phase) catch {
                    fail(backend, c, phase, error.TlsReceiveFailed);
                    return;
                };
                if (destination.len == 0) {
                    drive(backend, c);
                    if (!has(backend, c) or c.state == .closing) return;
                    continue;
                }
                const count = @min(destination.len, remaining.len);
                @memcpy(destination[0..count], remaining[0..count]);
                transform.commitCiphertext(phase, count) catch {
                    fail(backend, c, phase, error.TlsReceiveFailed);
                    return;
                };
                remaining = remaining[count..];
                drive(backend, c);
                if (!has(backend, c) or c.state == .closing) return;
            }
            drive(backend, c);
        }

        pub fn sent(backend: *Backend, c: *RelayConn, result: i32) !void {
            const secure = backend.secure.get(c.id) orelse return error.TlsStateMissing;
            if (result <= 0) {
                fail(backend, c, currentPhase(c, secure), error.TlsTransmitFailed);
                return;
            }
            secure.activeTransform().consumeCiphertext(
                currentPhase(c, secure),
                @intCast(result),
            ) catch {
                fail(backend, c, currentPhase(c, secure), error.TlsTransmitFailed);
                return;
            };
            drive(backend, c);
        }

        pub fn transportEof(backend: *Backend, c: *RelayConn) void {
            const secure = backend.secure.get(c.id) orelse return Access.end(backend, c, 0);
            const phase = currentPhase(c, secure);
            secure.activeTransform().noteTransportEof(phase);
            fail(backend, c, phase, error.TlsTruncated);
        }

        /// Adopt a wrapped transport failure before destroying the TLS
        /// client. This preserves the socket cause as primary and attaches
        /// any engine/destructor refusal behind it.
        pub fn platformFailed(
            backend: *Backend,
            c: *RelayConn,
            phase: carrier_failure.Phase,
            comp: completion.Completion,
            fallback: anyerror,
        ) void {
            const failure = if (comp.borrowed.carrierFailureValue()) |exact|
                exact.*
            else if (comp.borrowed.failureChain()) |chain|
                carrier_failure.Failure{ .phase = phase, .chain = chain.* }
            else
                carrier_failure.Failure.init(phase, comp.failure orelse fallback);
            retainPlatformFailure(backend, c, failure);
        }

        pub fn retainPlatformFailure(
            backend: *Backend,
            c: *RelayConn,
            failure: carrier_failure.Failure,
        ) void {
            const secure = backend.secure.get(c.id) orelse return;
            if (secure.failure) |*primary|
                primary.chain.noteChain(failure.chain)
            else
                secure.failure = failure;
            if (secure.lifecycle != .retired) {
                const exact = secure.deinit() orelse unreachable;
                secure.* = .{ .id = c.id, .lifecycle = .retired, .failure = exact };
            }
        }

        pub fn beginShutdown(backend: *Backend, c: *RelayConn) void {
            const secure = backend.secure.get(c.id) orelse return Access.beginPlatformClose(backend, c);
            secure.shutting_down = true;
            drive(backend, c);
        }

        /// Complete secure destruction before the external close result is
        /// published, retaining any engine refusal in stable state until the
        /// borrowed failure completion is recycled.
        pub fn prepareClose(
            backend: *Backend,
            c: *RelayConn,
            platform_failed: bool,
        ) bool {
            const secure = backend.secure.get(c.id) orelse return platform_failed;
            if (secure.lifecycle != .retired) {
                const failure = secure.deinit();
                secure.* = .{ .id = c.id, .lifecycle = .retired, .failure = failure };
            }
            if (platform_failed) {
                if (secure.failure == null)
                    secure.failure = .init(.shutdown, error.CloseFailed);
            }
            return secure.failure != null;
        }

        fn armForInterest(
            backend: *Backend,
            c: *RelayConn,
            interest: engine.Interest,
        ) !void {
            if (interest.read and !c.pending.get(.recv)) try Access.armPlatformRecv(backend, c);
        }

        fn currentPhase(c: *const RelayConn, secure: *const TlsState) engine.Phase {
            if (secure.shutting_down) return .shutdown;
            if (c.state == .tls_handshake) return .handshake;
            if (c.ws_send_kind != .none or c.ws_out_off != c.ws_out.items.len)
                return .transmit;
            return .receive;
        }

        fn fail(
            backend: *Backend,
            c: *RelayConn,
            phase: engine.Phase,
            fallback: anyerror,
        ) void {
            const was_closing = c.state == .closing;
            if (backend.secure.get(c.id)) |secure| {
                const exact = switch (secure.lifecycle) {
                    .active => secure.fail(phase, fallback),
                    .pending => TlsState.fromTlsFailure(engine.Failure.init(phase, fallback)),
                    .retired => secure.failure orelse
                        TlsState.fromTlsFailure(engine.Failure.init(phase, fallback)),
                };
                secure.* = .{
                    .id = c.id,
                    .lifecycle = .retired,
                    .failure = exact,
                };
            }
            Access.end(backend, c, -1);
            if (was_closing) Access.beginPlatformClose(backend, c);
        }

        fn retire(backend: *Backend, c: *RelayConn) void {
            const secure = backend.secure.get(c.id) orelse return;
            const failure = secure.deinit();
            secure.* = .{ .id = c.id, .lifecycle = .retired, .failure = failure };
        }

        /// Retire secure state at the connection's final owner. A failure is
        /// returned so the completion adapter can project it before freeing
        /// the only storage that carries its exact chain.
        pub fn destroy(backend: *Backend, c: *RelayConn) void {
            std.debug.assert(!hasBorrowedFailure(backend, c));
            if (backend.secure.get(c.id)) |secure|
                backend.tls_send_retries.removeIfQueued(&backend.secure, secure);
            const kv = backend.secure.fetchRemove(c.id) orelse return;
            const secure = kv.value;
            // `prepareClose` or the terminal operation borrowed this failure
            // before destruction. `deinit` here only consumes stable storage.
            _ = secure.deinit();
            backend.allocator.destroy(secure);
        }
    };
}
