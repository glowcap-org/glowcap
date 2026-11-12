//! The one provider listener an external completion backend serves.
//!
//! A provider listen either finishes at once or hands back an attempt whose
//! descriptor turns readable when setup can finish. Accepts park until the
//! listener is live, and a caller that must know when setup ends asks with
//! `submitReady`, which completes once the listener is live or has failed.

const std = @import("std");

const model = @import("model");
const completion = @import("../../completion/loop.zig");
const netlayer = @import("../../netlayer.zig");
const provider_mod = @import("provider.zig");

pub fn Machine(comptime Backend: type) type {
    return struct {
        const Fd = Backend.Fd;
        const Op = Backend.Op;
        const Identity = Backend.Identity;
        const Provider = provider_mod.Provider;

        pub fn open(backend: *Backend, serve: anytype) !Fd {
            if (backend.listener != null) return error.AddressInUse;
            const provider = try backend.providerFor(serve.transport);
            const listen = provider.vtable.listen orelse return error.OperationUnsupported;
            switch (listen(provider.ctx, serve.designator, serve.identity)) {
                .ready => |handle| backend.listener = .{ .provider = provider, .phase = .{ .listening = handle.ptr }, .fd = handle.fd },
                .pending => |handle| {
                    backend.listener = .{ .provider = provider, .phase = .{ .starting = handle.ptr }, .fd = handle.fd };
                    armPoll(backend) catch |err| {
                        provider.vtable.cancel_listen.?(provider.ctx, handle.ptr);
                        backend.listener = null;
                        return err;
                    };
                },
                .failed => |err| return err,
            }
            return Backend.listen_fd;
        }

        /// Whether the served listener is still finishing its setup. A
        /// wrapped backend's listener answers through the backend itself.
        pub fn pending(backend: *const Backend, fd: Fd) bool {
            if (fd != Backend.listen_fd) return backend.platform.listenerPending(fd);
            const row = backend.listener orelse return false;
            return row.phase == .starting;
        }

        /// Complete `user_data` once the listener is live (result 0) or its
        /// setup failed.
        pub fn submitReady(backend: *Backend, user_data: u64, fd: Fd) !void {
            if (fd != Backend.listen_fd) {
                // The seat exists only for a backend that reports pending
                // listeners; a plain platform never does.
                if (comptime !@hasDecl(@FieldType(Backend, "platform"), "submitListenReady"))
                    return error.ListenerClosed;
                return backend.platform.submitListenReady(user_data, fd);
            }
            const row = &(backend.listener orelse return error.ListenerClosed);
            if (row.closing) return error.ListenerClosed;
            if (row.ready_ud != null) return error.AlreadyAccepting;
            try backend.ready.reserve(backend.allocator, 1);
            if (row.phase == .listening) return backend.ready.appendReserved(.{ .user_data = user_data, .result = 0 });
            row.ready_ud = user_data;
        }

        pub fn submitAccept(backend: *Backend, user_data: u64) !void {
            const row = &(backend.listener orelse return error.ListenerClosed);
            if (row.closing) return error.ListenerClosed;
            if (row.accept_ud != null) return error.AlreadyAccepting;
            try backend.ready.reserve(backend.allocator, 1);
            errdefer backend.ready.release(1);
            if (row.phase == .listening and !row.poll) try armPoll(backend);
            row.accept_ud = user_data;
        }

        /// The served listener's dialable locator, owned by `allocator`.
        pub fn locator(backend: *Backend, allocator: std.mem.Allocator) !model.PeerLocator {
            const row, const listener = try live(backend);
            const locate = row.provider.vtable.listener_locator orelse return error.OperationUnsupported;
            return locate(row.provider.ctx, listener, allocator);
        }

        /// The served listener's canonical form of `candidate`, owned by
        /// `allocator`. Null when the provider defers to its own locator.
        pub fn canonicalize(backend: *Backend, allocator: std.mem.Allocator, candidate: model.PeerLocator) !?model.PeerLocator {
            const row, const listener = try live(backend);
            const check = row.provider.vtable.listener_canonicalize orelse return null;
            return try check(row.provider.ctx, listener, allocator, candidate);
        }

        pub fn restorationState(backend: *Backend, out: []u8) netlayer.ListenerRestorationOutcome {
            const row, const listener = live(backend) catch |err| return .{ .failed = .init(err) };
            const restore = row.provider.vtable.listener_restoration_state orelse return .unsupported;
            return restore(row.provider.ctx, listener, out);
        }

        fn live(backend: *Backend) !struct { *Backend.ListenerRow, *anyopaque } {
            const row = &(backend.listener orelse return error.ListenerClosed);
            return switch (row.phase) {
                .listening => |listener| .{ row, listener },
                .starting => error.ListenerPending,
            };
        }

        fn armPoll(backend: *Backend) !void {
            const row = &backend.listener.?;
            try backend.platform.submitPoll(Identity.userData(.start_poll, 0), row.fd, .readable);
            row.poll = true;
        }

        pub fn dispatch(backend: *Backend, op: Op, comp: completion.Completion) void {
            const row = &backend.listener.?;
            switch (op) {
                .cancel => row.cancels -= 1,
                .start_poll => row.poll = false,
                .read_poll, .write_poll => unreachable,
            }
            if (row.closing) return maybeFinish(backend);
            if (op != .start_poll) return;
            if (comp.result < 0) return failSetup(backend, comp.failure orelse error.ReadinessFailed);
            switch (row.phase) {
                .starting => |attempt| switch (row.provider.vtable.finish_listen.?(row.provider.ctx, attempt)) {
                    .ready => |handle| {
                        row.phase = .{ .listening = handle.ptr };
                        row.fd = handle.fd;
                        if (row.ready_ud) |ud| {
                            row.ready_ud = null;
                            backend.ready.appendReserved(.{ .user_data = ud, .result = 0 });
                        }
                    },
                    .failed => |err| {
                        // The attempt is consumed, so the listener is gone;
                        // whoever waits learns why.
                        failSetup(backend, err);
                        backend.listener = null;
                        return;
                    },
                },
                .listening => |listener| if (row.accept_ud) |ud| {
                    row.accept_ud = null;
                    switch (row.provider.vtable.accept.?(row.provider.ctx, listener)) {
                        .ready => |handle| bindAccepted(backend, ud, row.provider, handle),
                        .failed => |err| backend.ready.appendReserved(.{ .user_data = ud, .result = -1, .failure = err }),
                    }
                },
            }
            if (backend.listener) |*row_live| {
                const waiting = row_live.accept_ud != null or (row_live.phase == .starting and row_live.ready_ud != null);
                if (waiting and !row_live.poll) armPoll(backend) catch |err| failSetup(backend, err);
            }
        }

        fn bindAccepted(backend: *Backend, ud: u64, provider: *const Provider, handle: provider_mod.Handle) void {
            const fd = backend.reserveFd() catch |err| return refuseAccepted(backend, ud, provider, handle, err);
            backend.conns.ensureUnusedCapacity(1) catch |err| return refuseAccepted(backend, ud, provider, handle, err);
            backend.conns.putAssumeCapacity(fd, Backend.openEntry(provider, handle));
            backend.ready.appendReserved(.{ .user_data = ud, .result = 0, .accepted_fd = fd });
        }

        fn refuseAccepted(backend: *Backend, ud: u64, provider: *const Provider, handle: provider_mod.Handle, err: anyerror) void {
            provider.vtable.conn_close(provider.ctx, handle.ptr);
            backend.ready.appendReserved(.{ .user_data = ud, .result = -1, .failure = err });
        }

        /// Fail every waiter: a parked accept and a setup wait.
        fn failSetup(backend: *Backend, err: anyerror) void {
            const row = &(backend.listener orelse return);
            if (row.accept_ud) |ud| backend.ready.appendReserved(.{ .user_data = ud, .result = -1, .failure = err });
            if (row.ready_ud) |ud| backend.ready.appendReserved(.{ .user_data = ud, .result = -1, .failure = err });
            row.accept_ud = null;
            row.ready_ud = null;
        }

        pub fn close(backend: *Backend, user_data: u64) !void {
            try backend.ready.reserve(backend.allocator, 1);
            const row = &(backend.listener orelse {
                backend.ready.appendReserved(.{ .user_data = user_data, .result = 0 });
                return;
            });
            if (row.closing) {
                backend.ready.release(1);
                return error.AlreadyClosing;
            }
            failSetup(backend, error.Canceled);
            row.close_ud = user_data;
            beginClose(backend);
        }

        /// Release a listener the caller no longer waits on.
        pub fn release(backend: *Backend) void {
            const row = &(backend.listener orelse return);
            std.debug.assert(row.accept_ud == null);
            failSetup(backend, error.Canceled);
            if (!row.closing) beginClose(backend);
        }

        fn beginClose(backend: *Backend) void {
            const row = &backend.listener.?;
            row.closing = true;
            if (row.poll) backend.cancelPoll(&row.cancels, Identity.userData(.start_poll, 0), row.fd);
            maybeFinish(backend);
        }

        fn maybeFinish(backend: *Backend) void {
            const row = backend.listener.?;
            if (row.poll or row.cancels != 0) return;
            switch (row.phase) {
                .starting => |attempt| row.provider.vtable.cancel_listen.?(row.provider.ctx, attempt),
                .listening => |listener| row.provider.vtable.listener_close.?(row.provider.ctx, listener),
            }
            backend.listener = null;
            if (row.close_ud) |ud| backend.ready.appendReserved(.{ .user_data = ud, .result = 0 });
        }
    };
}
