//! C projection of one native relay multiplexed runtime.
//!
//! The runtime owns scheduling, connections, listeners, and retained failures.
//! This module owns only caller-view validation and the fixed C callback table;
//! it translates each runtime outcome exactly once and retains no policy or
//! mutable state of its own.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const c = @import("c_abi_shared");
const failure_projection = @import("../failure/projection.zig");

const multiplexed = c.multiplexed_transport;
const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_WOULD_BLOCK = c.PANCAKE_ERR_WOULD_BLOCK;
const PANCAKE_ERR_CLOSED = c.PANCAKE_ERR_CLOSED;
const PANCAKE_ERR_IO = c.PANCAKE_ERR_IO;

const EV_ACCEPT = multiplexed.PANCAKE_MULTIPLEXED_EV_ACCEPT;
const EV_CONNECT = multiplexed.PANCAKE_MULTIPLEXED_EV_CONNECT;
const EV_LISTEN = multiplexed.PANCAKE_MULTIPLEXED_EV_LISTEN;

pub fn Projection(
    comptime Runtime: type,
    comptime Listener: type,
    comptime Connection: type,
    comptime fail_runtime: *const fn (*Runtime) void,
) type {
    return struct {
        pub fn transport(runtime: *Runtime) c.PancakeMultiplexedTransport {
            return .{
                .abi_version = multiplexed.PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION,
                .struct_size = @sizeOf(c.PancakeMultiplexedTransport),
                .ctx = runtime,
                .readiness_fd = readinessFd,
                .drain_ready = drainReady,
                .start_connect = startConnect,
                .finish_connect = finishConnect,
                .cancel_connect = cancelConnect,
                .listen = listen,
                .finish_listen = finishListen,
                .cancel_listen = cancelListen,
                .listener_locator = listenerLocator,
                .listener_advertise = listenerAdvertise,
                .finish_accept = finishAccept,
                .stop_listen = stopListen,
                .try_read = tryRead,
                .try_write = tryWrite,
                .conn_close = connClose,
                .conn_take_failure = connTakeFailure,
                .conn_remote_key = connRemoteKey,
            };
        }

        fn runtimeFrom(ctx: ?*anyopaque) *Runtime {
            return @ptrCast(@alignCast(ctx.?));
        }

        fn listenerFrom(value: ?*anyopaque) *Listener {
            return @ptrCast(@alignCast(value.?));
        }

        fn readinessFd(ctx: ?*anyopaque) callconv(.c) i32 {
            return runtimeFrom(ctx).ready_wake.read;
        }

        fn drainReady(
            ctx: ?*anyopaque,
            out: ?[*]c.PancakeMultiplexedReadyEvent,
            cap: usize,
            out_count: ?*usize,
            out_failure: ?*c.PancakeProviderFailure,
        ) callconv(.c) i32 {
            const runtime = runtimeFrom(ctx);
            const count_slot = out_count orelse return c.transport_provider.failProvider(
                out_failure,
                PANCAKE_ERR_NULL_POINTER,
                error.NullPointer,
            );
            const output = out orelse if (cap == 0) null else return c.transport_provider.failProvider(
                out_failure,
                PANCAKE_ERR_NULL_POINTER,
                error.NullPointer,
            );
            runtime.ready_wake.drain() catch {
                runtime.noteFailure(error.WakeDrainFailed);
                fail_runtime(runtime);
                return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, error.WakeDrainFailed);
            };
            runtime.mutex.lock();
            defer runtime.mutex.unlock();
            var total: usize = 0;

            switch (runtime.listener) {
                .starting => |setup| if (setup.state != .running and setup.state != .cancelled and
                    !setup.announced and total < cap)
                {
                    setup.announced = true;
                    output.?[total] = .{ .subject = setup.route_id, .events = EV_LISTEN };
                    total += 1;
                },
                .active => |listener| if (total < cap) {
                    const events = listener.events.fetchAnd(0, .acq_rel);
                    if (events != 0) {
                        output.?[total] = .{ .subject = listener.route_id, .events = events };
                        total += 1;
                    }
                },
                .empty => {},
            }
            for (runtime.jobs.items) |job| {
                if (total == cap) break;
                if (job.state == .running or job.announced) continue;
                job.announced = true;
                output.?[total] = .{ .subject = job.request_id, .events = EV_CONNECT };
                total += 1;
            }
            for (runtime.connections.items) |conn| {
                if (total == cap) break;
                const events = conn.events.fetchAnd(0, .acq_rel);
                if (events == 0) continue;
                output.?[total] = .{ .subject = conn.id, .events = events };
                total += 1;
            }
            if (hasReadyLocked(runtime)) runtime.signalReady();
            if (total != 0) runtime.signalControl();
            count_slot.* = total;
            return PANCAKE_OK;
        }

        fn hasReadyLocked(runtime: *Runtime) bool {
            switch (runtime.listener) {
                .starting => |setup| if (setup.state != .running and setup.state != .cancelled and !setup.announced)
                    return true,
                .active => |listener| if (listener.events.load(.acquire) != 0) return true,
                .empty => {},
            }
            for (runtime.jobs.items) |job| {
                if (job.state != .running and !job.announced) return true;
            }
            for (runtime.connections.items) |conn| {
                if (conn.events.load(.acquire) != 0) return true;
            }
            return false;
        }

        fn startConnect(
            ctx: ?*anyopaque,
            request_id: u64,
            locator_view: ?*const c.PancakeLocatorView,
            options: ?*const c.PancakeTransportOperationOptions,
            out_failure: ?*c.PancakeProviderFailure,
        ) callconv(.c) i32 {
            if (!c.transport_provider.operationOptionsAreInherited(options))
                return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidOptions);
            const runtime = runtimeFrom(ctx);
            const view = locator_view orelse return c.transport_provider.failProvider(
                out_failure,
                PANCAKE_ERR_NULL_POINTER,
                error.NullPointer,
            );
            var hint_stack: [c.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
            var borrowed = c.locator_adapter.BorrowedLocator.init(runtime.allocator, view, &hint_stack) catch |err| {
                const code = c.locatorAdapterErrorCode(err);
                return c.transport_provider.failProvider(out_failure, code, err);
            };
            defer borrowed.deinit(runtime.allocator);
            runtime.startDial(request_id, borrowed.value) catch |err| {
                const code = failure_projection.dial(err);
                return c.transport_provider.failProvider(out_failure, code, err);
            };
            runtime.signalControl();
            return PANCAKE_OK;
        }

        fn finishConnect(
            ctx: ?*anyopaque,
            request_id: u64,
            out_conn: ?*u64,
            out_failure: ?*c.PancakeProviderFailure,
        ) callconv(.c) i32 {
            const runtime = runtimeFrom(ctx);
            const slot = out_conn orelse {
                const cleanup = runtime.cancelDial(request_id);
                var failure = foundation.FailureChain.init(error.NullPointer);
                if (cleanup) |later| failure.noteChain(later);
                return c.transport_provider.failProviderChain(
                    out_failure,
                    PANCAKE_ERR_NULL_POINTER,
                    failure,
                    failure_projection.release,
                );
            };
            const id = switch (runtime.finishDial(request_id)) {
                .connected => |connected| connected,
                .failed => |failure| return failure_projection.failDial(out_failure, failure),
            };
            slot.* = id;
            return PANCAKE_OK;
        }

        fn cancelConnect(ctx: ?*anyopaque, request_id: u64, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
            if (runtimeFrom(ctx).cancelDial(request_id)) |failure|
                return c.transport_provider.failProviderChain(
                    out_failure,
                    PANCAKE_ERR_IO,
                    failure,
                    failure_projection.release,
                );
            return PANCAKE_OK;
        }

        fn listen(
            ctx: ?*anyopaque,
            route_id: u64,
            transport_name: ?[*]const u8,
            transport_len: usize,
            requested_designator: ?[*]const u8,
            requested_designator_len: usize,
            options: ?*const c.PancakeTransportOperationOptions,
            out_result: ?*c.PancakeListenResult,
            out_failure: ?*c.PancakeProviderFailure,
        ) callconv(.c) i32 {
            if (!c.transport_provider.operationOptionsAreInherited(options))
                return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidOptions);
            const runtime = runtimeFrom(ctx);
            const result = out_result orelse
                return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
            const transport_bytes = c.sliceFromC(transport_name, transport_len) catch
                return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
            const requested = c.sliceFromC(requested_designator, requested_designator_len) catch
                return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
            const listener = switch (runtime.listen(route_id, transport_bytes, requested)) {
                .admitted => |admitted| admitted,
                .failed => |failure| {
                    const code = failure_projection.listen(failure.cause);
                    return c.transport_provider.failProviderChain(
                        out_failure,
                        code,
                        failure,
                        failure_projection.listen,
                    );
                },
            };
            result.* = switch (listener) {
                .ready => |value| .{
                    .state = c.PANCAKE_LISTEN_READY,
                    .listener = value,
                    .attempt = null,
                    .readiness_fd = -1,
                },
                .pending => .{
                    .state = c.PANCAKE_LISTEN_PENDING,
                    .listener = null,
                    .attempt = null,
                    .readiness_fd = -1,
                },
            };
            return PANCAKE_OK;
        }

        fn finishListen(
            ctx: ?*anyopaque,
            route_id: u64,
            out_listener: ?*?*anyopaque,
            out_failure: ?*c.PancakeProviderFailure,
        ) callconv(.c) i32 {
            const runtime = runtimeFrom(ctx);
            const slot = out_listener orelse {
                const cleanup = runtime.cancelListen(route_id);
                var failure = foundation.FailureChain.init(error.NullPointer);
                if (cleanup) |later| failure.noteChain(later);
                return c.transport_provider.failProviderChain(
                    out_failure,
                    PANCAKE_ERR_NULL_POINTER,
                    failure,
                    failure_projection.release,
                );
            };
            const listener = switch (runtime.finishListen(route_id)) {
                .listener => |listener| listener,
                .failed => |failure| {
                    const code = failure_projection.listen(failure.cause);
                    return c.transport_provider.failProviderChain(
                        out_failure,
                        code,
                        failure,
                        failure_projection.listen,
                    );
                },
            };
            slot.* = listener;
            return PANCAKE_OK;
        }

        fn cancelListen(ctx: ?*anyopaque, route_id: u64, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
            if (runtimeFrom(ctx).cancelListen(route_id)) |failure|
                return c.transport_provider.failProviderChain(
                    out_failure,
                    PANCAKE_ERR_IO,
                    failure,
                    failure_projection.release,
                );
            return PANCAKE_OK;
        }

        fn listenerLocator(
            ctx: ?*anyopaque,
            sink_ctx: ?*anyopaque,
            sink: c.PancakeLocatorSinkFn,
            out_failure: ?*c.PancakeProviderFailure,
        ) callconv(.c) i32 {
            const listener = listenerFrom(ctx);
            if (listener.stopped.load(.acquire))
                return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
            var hints: [c.locator_adapter.inline_hint_capacity]c.PancakeLocatorHintView = undefined;
            var projection = c.locator_adapter.Projection.init(listener.runtime.allocator, listener.locator, &hints) catch |err|
                return c.transport_provider.failProvider(out_failure, c.locatorAdapterErrorCode(err), err);
            defer projection.deinit(listener.runtime.allocator);
            return sink(sink_ctx, &projection.view);
        }

        fn listenerAdvertise(
            ctx: ?*anyopaque,
            locator_view: ?*const c.PancakeLocatorView,
            sink_ctx: ?*anyopaque,
            sink: c.PancakeLocatorSinkFn,
            out_failure: ?*c.PancakeProviderFailure,
        ) callconv(.c) i32 {
            const listener = listenerFrom(ctx);
            if (listener.stopped.load(.acquire))
                return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
            const view = locator_view orelse
                return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
            var hints: [c.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
            var borrowed = c.locator_adapter.BorrowedLocator.init(listener.runtime.allocator, view, &hints) catch |err|
                return c.transport_provider.failProvider(out_failure, c.locatorAdapterErrorCode(err), err);
            defer borrowed.deinit(listener.runtime.allocator);
            listener.io_mutex.lock();
            defer listener.io_mutex.unlock();
            const canonical = listener.raw.canonicalizeLocator(listener.runtime.allocator, borrowed.value) catch |err|
                return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, err);
            defer model.freePeerLocator(listener.runtime.allocator, canonical);
            var canonical_hints: [c.locator_adapter.inline_hint_capacity]c.PancakeLocatorHintView = undefined;
            var projection = c.locator_adapter.Projection.init(listener.runtime.allocator, canonical, &canonical_hints) catch |err|
                return c.transport_provider.failProvider(out_failure, c.locatorAdapterErrorCode(err), err);
            defer projection.deinit(listener.runtime.allocator);
            return sink(sink_ctx, &projection.view);
        }

        fn finishAccept(
            listener_raw: ?*anyopaque,
            out_conn: ?*u64,
            out_failure: ?*c.PancakeProviderFailure,
        ) callconv(.c) i32 {
            const listener = listenerFrom(listener_raw);
            const slot = out_conn orelse
                return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
            if (listener.stopped.load(.acquire))
                return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
            listener.io_mutex.lock();
            defer listener.io_mutex.unlock();
            if (listener.failed.load(.acquire)) {
                if (listener.raw.takeFailure()) |failure| listener.noteFailure(failure);
                const failure = listener.claimFailure() orelse foundation.FailureChain.init(error.ConnectionLost);
                return c.transport_provider.failProviderChain(out_failure, PANCAKE_ERR_IO, failure, failure_projection.release);
            }
            const acceptable = listener.raw.waitAcceptable(0) catch |err| {
                const failure = listener.raw.takeFailure() orelse foundation.FailureChain.init(err);
                return c.transport_provider.failProviderChain(out_failure, PANCAKE_ERR_IO, failure, failure_projection.release);
            };
            if (!acceptable) return PANCAKE_ERR_WOULD_BLOCK;
            var raw = listener.raw.accept(listener.runtime.allocator) catch |err| {
                const failure = listener.raw.takeFailure() orelse foundation.FailureChain.init(err);
                return c.transport_provider.failProviderChain(out_failure, PANCAKE_ERR_IO, failure, failure_projection.release);
            };
            const conn = listener.runtime.allocator.create(Connection) catch |err| {
                var failure = foundation.FailureChain.init(err);
                if (raw.close()) |cleanup| failure.noteChain(cleanup);
                return c.transport_provider.failProviderChain(
                    out_failure,
                    PANCAKE_ERR_INTERNAL,
                    failure,
                    failure_projection.release,
                );
            };
            conn.* = .{ .id = 0, .raw = raw };
            listener.runtime.mutex.lock();
            defer listener.runtime.mutex.unlock();
            const id = listener.runtime.addConnectionLocked(conn) catch |err| {
                var failure = foundation.FailureChain.init(err);
                if (conn.raw.close()) |cleanup| failure.noteChain(cleanup);
                listener.runtime.allocator.destroy(conn);
                const code: i32 = if (err == error.OutOfMemory) PANCAKE_ERR_INTERNAL else PANCAKE_ERR_CLOSED;
                return c.transport_provider.failProviderChain(
                    out_failure,
                    code,
                    failure,
                    failure_projection.release,
                );
            };
            slot.* = id;
            listener.runtime.signalControl();
            return PANCAKE_OK;
        }

        fn stopListen(listener_raw: ?*anyopaque, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
            const listener = listenerFrom(listener_raw);
            return switch (listener.runtime.stopListen(listener)) {
                .complete => PANCAKE_OK,
                .pending => PANCAKE_ERR_WOULD_BLOCK,
                .failed => |failure| c.transport_provider.failProviderChain(
                    out_failure,
                    PANCAKE_ERR_IO,
                    failure,
                    failure_projection.release,
                ),
            };
        }

        fn tryRead(ctx: ?*anyopaque, conn_id: u64, buf: ?[*]u8, cap: usize) callconv(.c) isize {
            const runtime = runtimeFrom(ctx);
            const dest = buf orelse return -1;
            runtime.mutex.lock();
            const state = runtime.findConnectionLocked(conn_id) orelse {
                runtime.mutex.unlock();
                return -1;
            };
            state.io_mutex.lock();
            runtime.mutex.unlock();
            defer state.io_mutex.unlock();
            // A HUP publishes READABLE|CLOSED. Reads remain legal until
            // explicit release drains the final bytes and observes clean EOF.
            if (state.raw_closed or state.release_requested.load(.acquire)) return -1;
            const got = state.raw.tryRead(dest[0..cap]);
            if (got < 0 and got != c.multiplexed_transport.PANCAKE_MULTIPLEXED_WOULD_BLOCK) state.noteFailure(
                state.raw.takeFailure() orelse foundation.FailureChain.init(error.ConnectionLost),
            );
            return got;
        }

        fn tryWrite(ctx: ?*anyopaque, conn_id: u64, bytes: ?[*]const u8, len: usize) callconv(.c) isize {
            const runtime = runtimeFrom(ctx);
            const source = bytes orelse return -1;
            runtime.mutex.lock();
            const state = runtime.findConnectionLocked(conn_id) orelse {
                runtime.mutex.unlock();
                return -1;
            };
            state.io_mutex.lock();
            runtime.mutex.unlock();
            defer state.io_mutex.unlock();
            if (state.raw_closed or state.closed.load(.acquire) or
                state.release_requested.load(.acquire)) return -1;
            const wrote = state.raw.tryWrite(source[0..len]);
            if (wrote < 0 and wrote != c.multiplexed_transport.PANCAKE_MULTIPLEXED_WOULD_BLOCK) state.noteFailure(
                state.raw.takeFailure() orelse foundation.FailureChain.init(error.ConnectionLost),
            );
            if (state.raw.hasPendingWrite()) runtime.signalControl();
            return wrote;
        }

        fn connTakeFailure(
            ctx: ?*anyopaque,
            conn_id: u64,
            out_failure: ?*c.PancakeProviderFailure,
        ) callconv(.c) void {
            const slot = out_failure orelse return;
            slot.* = std.mem.zeroes(c.PancakeProviderFailure);
            const runtime = runtimeFrom(ctx);
            runtime.mutex.lock();
            const state = runtime.findConnectionLocked(conn_id) orelse {
                runtime.mutex.unlock();
                return;
            };
            state.io_mutex.lock();
            runtime.mutex.unlock();
            defer state.io_mutex.unlock();
            if (state.raw.takeFailure()) |failure| state.noteFailure(failure);
            const failure = state.claimFailure() orelse return;
            c.transport_provider.setProviderFailureChain(
                slot,
                PANCAKE_ERR_IO,
                failure,
                failure_projection.release,
            );
        }

        fn connClose(
            ctx: ?*anyopaque,
            conn_id: u64,
            out_failure: ?*c.PancakeProviderFailure,
        ) callconv(.c) i32 {
            const runtime = runtimeFrom(ctx);
            runtime.mutex.lock();
            const state = runtime.findConnectionLocked(conn_id) orelse {
                runtime.mutex.unlock();
                return PANCAKE_OK;
            };
            if (state.release_complete.load(.acquire)) {
                const failure = state.claimFailure();
                std.debug.assert(runtime.by_id.remove(conn_id));
                for (runtime.connections.items, 0..) |candidate, index| if (candidate == state) {
                    std.debug.assert(runtime.connections.swapRemove(index) == state);
                    break;
                };
                runtime.mutex.unlock();
                runtime.allocator.destroy(state);
                if (failure) |reported|
                    return c.transport_provider.failProviderChain(
                        out_failure,
                        PANCAKE_ERR_IO,
                        reported,
                        failure_projection.release,
                    );
                return PANCAKE_OK;
            }
            if (state.release_requested.swap(true, .acq_rel)) {
                runtime.mutex.unlock();
                return PANCAKE_ERR_WOULD_BLOCK;
            }
            _ = state.events.fetchAnd(0, .acq_rel);
            runtime.mutex.unlock();
            runtime.signalControl();
            return PANCAKE_ERR_WOULD_BLOCK;
        }

        fn connRemoteKey(_: ?*anyopaque, _: u64, _: ?[*]u8) callconv(.c) i32 {
            // A relay authenticates neither endpoint. Noise, when selected,
            // is a Host channel; its verified key does not belong to this ABI.
            return 0;
        }
    };
}
