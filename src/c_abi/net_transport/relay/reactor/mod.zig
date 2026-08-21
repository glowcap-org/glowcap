//! Poll reactor and terminal cleanup for the native relay provider runtime.
//!
//! The runtime owns its tables and wake channels. This module owns the one
//! reactor thread's polling, readiness projection, and removal transactions.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const net = @import("net");

pub fn Machine(
    comptime Runtime: type,
    comptime DialState: type,
    comptime ListenerSetup: type,
    comptime ListenerState: type,
    comptime ConnState: type,
    comptime ev_accept: u32,
    comptime ev_closed: u32,
    comptime ev_listen: u32,
) type {
    return struct {
        pub fn destroyDial(runtime: *Runtime, job: *DialState) void {
            model.freePeerLocator(runtime.allocator, job.locator);
            runtime.allocator.destroy(job);
        }

        pub fn detachJobLocked(runtime: *Runtime, job: *DialState) void {
            for (runtime.jobs.items, 0..) |candidate, i| {
                if (candidate == job) {
                    const removed = runtime.jobs.swapRemove(i);
                    std.debug.assert(removed == job);
                    return;
                }
            }
        }

        fn closeListenerLocked(listener: *ListenerState) ?net.netlayer.ListenerCloseFailure {
            listener.io_mutex.lock();
            defer listener.io_mutex.unlock();
            if (listener.closed.swap(true, .acq_rel)) return listener.claimFailure();
            if (listener.raw.takeFailure()) |failure| listener.noteFailure(failure);
            var failure = listener.claimFailure();
            if (listener.raw.close()) |cleanup| {
                if (failure) |*primary| primary.noteChain(cleanup) else failure = cleanup;
            }
            return failure;
        }

        pub fn destroyListener(
            runtime: *Runtime,
            listener: *ListenerState,
        ) ?net.netlayer.ListenerCloseFailure {
            const failure = closeListenerLocked(listener);
            model.freePeerLocator(runtime.allocator, listener.locator);
            runtime.allocator.destroy(listener);
            return failure;
        }

        pub fn destroyListenerSetup(
            runtime: *Runtime,
            setup: *ListenerSetup,
        ) ?net.netlayer.ListenerCloseFailure {
            const failure = if (setup.listener) |listener|
                destroyListener(runtime, listener)
            else if (setup.raw) |raw|
                raw.close()
            else
                setup.failure;
            setup.raw = null;
            setup.listener = null;
            runtime.allocator.destroy(setup);
            return failure;
        }

        pub fn main(runtime: *Runtime) void {
            while (!runtime.stopping.load(.acquire)) {
                if (runtime.hasTerminalFailure()) {
                    failRuntime(runtime);
                    return;
                }
                if (!rebuildPollSet(runtime)) {
                    failRuntime(runtime);
                    return;
                }
                // The wake is the fast path. Bounded polling is the recovery
                // path that lets a latched wake fault terminalize and join.
                _ = net.poll.wait(runtime.pollfds.items, 100) catch {
                    failRuntime(runtime);
                    return;
                };
                if (runtime.stopping.load(.acquire)) return;
                for (runtime.pollfds.items, runtime.subjects.items) |pollfd, subject| {
                    const revents = pollfd.revents;
                    if (revents == 0) continue;
                    switch (subject) {
                        .wake => runtime.control_wake.drain() catch {
                            runtime.noteFailure(error.WakeDrainFailed);
                            failRuntime(runtime);
                            return;
                        },
                        .listener_setup => |setup| listenerSetup(runtime, setup, revents),
                        .listener => |listener| listenerReady(runtime, listener, revents),
                        .connection => |conn| connectionReady(runtime, conn, revents),
                    }
                }
                reapReleasedConnections(runtime);
                reapStoppedListener(runtime);
                reapCancelledListenerSetup(runtime);
            }
        }

        fn rebuildPollSet(runtime: *Runtime) bool {
            runtime.mutex.lock();
            defer runtime.mutex.unlock();
            runtime.pollfds.clearRetainingCapacity();
            runtime.subjects.clearRetainingCapacity();
            const listener_count: usize = switch (runtime.listener) {
                .active => |listener| @intFromBool(!listener.stopped.load(.acquire)),
                .starting => |setup| @intFromBool(setup.state == .running),
                .empty => 0,
            };
            const wanted = @as(usize, 1) + listener_count + runtime.connections.items.len;
            runtime.pollfds.ensureTotalCapacity(runtime.allocator, wanted) catch return false;
            runtime.subjects.ensureTotalCapacity(runtime.allocator, wanted) catch return false;
            runtime.pollfds.appendAssumeCapacity(.{
                .fd = runtime.control_wake.read,
                .events = std.posix.POLL.IN,
                .revents = 0,
            });
            runtime.subjects.appendAssumeCapacity(.wake);
            switch (runtime.listener) {
                .starting => |setup| if (setup.state == .running) {
                    const fd = setup.raw.?.readinessFd();
                    if (fd >= 0) {
                        runtime.pollfds.appendAssumeCapacity(.{
                            .fd = fd,
                            .events = std.posix.POLL.IN,
                            .revents = 0,
                        });
                        runtime.subjects.appendAssumeCapacity(.{ .listener_setup = setup });
                    }
                },
                .active => |listener| if (!listener.stopped.load(.acquire)) {
                    const fd = listener.raw.readinessFd();
                    if (fd >= 0) {
                        runtime.pollfds.appendAssumeCapacity(.{
                            .fd = fd,
                            .events = std.posix.POLL.IN,
                            .revents = 0,
                        });
                        runtime.subjects.appendAssumeCapacity(.{ .listener = listener });
                    }
                },
                .empty => {},
            }
            for (runtime.connections.items) |conn| {
                conn.io_mutex.lock();
                const releasing = conn.release_requested.load(.acquire);
                const events = if (releasing)
                    conn.releasePollEventsLocked()
                else
                    std.posix.POLL.IN |
                        if (!conn.raw_closed and conn.raw.hasPendingWrite())
                            @as(c_short, std.posix.POLL.OUT)
                        else
                            0;
                const fd = if (conn.raw_closed) -1 else conn.raw.readinessFd();
                conn.io_mutex.unlock();
                if (fd < 0) continue;
                runtime.pollfds.appendAssumeCapacity(.{
                    .fd = fd,
                    .events = events,
                    .revents = 0,
                });
                runtime.subjects.appendAssumeCapacity(.{ .connection = conn });
            }
            return true;
        }

        fn failListenerSetup(
            runtime: *Runtime,
            setup: *ListenerSetup,
            failure: net.netlayer.ListenFailure,
        ) void {
            runtime.mutex.lock();
            const current = switch (runtime.listener) {
                .starting => |value| value == setup and setup.state == .running,
                .empty, .active => false,
            };
            if (current) {
                setup.state = .failed;
                setup.failure = failure;
            }
            runtime.mutex.unlock();
            if (current) runtime.signalReady();
        }

        fn listenerSetup(runtime: *Runtime, setup: *ListenerSetup, revents: c_short) void {
            if (revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) {
                failListenerSetup(
                    runtime,
                    setup,
                    setup.raw.?.takeFailure() orelse .init(error.ConnectionLost),
                );
                return;
            }
            const established = setup.raw.?.waitEstablished(0) catch |err| {
                failListenerSetup(runtime, setup, setup.raw.?.takeFailure() orelse .init(err));
                return;
            };
            if (!established) return;
            const locator = setup.raw.?.localLocator(runtime.allocator) catch |err| {
                failListenerSetup(runtime, setup, .init(err));
                return;
            };
            const listener = runtime.allocator.create(ListenerState) catch {
                model.freePeerLocator(runtime.allocator, locator);
                failListenerSetup(runtime, setup, .init(error.OutOfMemory));
                return;
            };

            runtime.mutex.lock();
            const current = switch (runtime.listener) {
                .starting => |value| value == setup and setup.state == .running,
                .empty, .active => false,
            };
            if (current) {
                listener.* = .{
                    .runtime = runtime,
                    .raw = setup.raw.?,
                    .locator = locator,
                    .route_id = setup.route_id,
                };
                setup.listener = listener;
                setup.raw = null;
                setup.state = .succeeded;
            }
            runtime.mutex.unlock();
            if (!current) {
                runtime.allocator.destroy(listener);
                model.freePeerLocator(runtime.allocator, locator);
                return;
            }
            runtime.signalReady();
        }

        fn listenerReady(runtime: *Runtime, listener: *ListenerState, revents: c_short) void {
            if (listener.stopped.load(.acquire)) return;
            const bad = revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0;
            listener.io_mutex.lock();
            defer listener.io_mutex.unlock();
            if (listener.closed.load(.acquire)) return;
            const acceptable = listener.raw.waitAcceptable(0) catch |err| {
                // Readiness is the only recipient for this active-listener
                // failure. Treating it as not-ready would strand the listener.
                listener.noteFailure(listener.raw.takeFailure() orelse .init(err));
                listener.failed.store(true, .release);
                _ = listener.events.fetchOr(ev_accept, .acq_rel);
                runtime.signalReady();
                return;
            };
            if (bad) {
                listener.noteFailure(listener.raw.takeFailure() orelse .init(error.ConnectionLost));
                listener.failed.store(true, .release);
            }
            if (!bad and !acceptable) return;
            _ = listener.events.fetchOr(ev_accept, .acq_rel);
            runtime.signalReady();
        }

        fn connectionReady(runtime: *Runtime, conn: *ConnState, revents: c_short) void {
            if (conn.closed.load(.acquire) or conn.release_requested.load(.acquire)) return;
            conn.io_mutex.lock();
            defer conn.io_mutex.unlock();
            if (conn.reactLocked(revents)) runtime.signalReady();
        }

        /// The first conn_close only requests retirement. Keep the tombstone
        /// until its EV_CLOSED recipient claims the joined close outcome.
        fn reapReleasedConnections(runtime: *Runtime) void {
            runtime.mutex.lock();
            defer runtime.mutex.unlock();
            var published = false;
            for (runtime.connections.items) |conn| {
                if (!conn.release_requested.load(.acquire) or
                    conn.release_complete.load(.acquire)) continue;
                if (conn.advanceRelease(runtime.io)) {
                    conn.release_complete.store(true, .release);
                    _ = conn.events.fetchOr(ev_closed, .acq_rel);
                    published = true;
                }
            }
            if (published) runtime.signalReady();
        }

        fn reapStoppedListener(runtime: *Runtime) void {
            runtime.mutex.lock();
            defer runtime.mutex.unlock();
            switch (runtime.listener) {
                .active => |listener| if (listener.stopped.load(.acquire) and
                    !listener.retired.load(.acquire))
                {
                    if (closeListenerLocked(listener)) |failure| listener.noteFailure(failure);
                    listener.retired.store(true, .release);
                    _ = listener.events.fetchOr(ev_listen, .acq_rel);
                    runtime.signalReady();
                },
                .empty, .starting => {},
            }
        }

        fn reapCancelledListenerSetup(runtime: *Runtime) void {
            runtime.mutex.lock();
            const setup: ?*ListenerSetup = switch (runtime.listener) {
                .starting => |value| if (value.state == .cancelled) value else null,
                .empty, .active => null,
            };
            runtime.mutex.unlock();
            if (setup) |value| {
                var failure = value.failure;
                if (value.listener) |listener| {
                    if (destroyListener(runtime, listener)) |cleanup| {
                        if (failure) |*first| first.noteChain(cleanup) else failure = cleanup;
                    }
                    value.listener = null;
                } else if (value.raw) |raw| {
                    if (raw.close()) |cleanup| {
                        if (failure) |*first| first.noteChain(cleanup) else failure = cleanup;
                    }
                    value.raw = null;
                }
                runtime.mutex.lock();
                value.failure = failure;
                value.state = .retired;
                value.announced = false;
                runtime.mutex.unlock();
                runtime.signalReady();
            }
        }

        pub fn failRuntime(runtime: *Runtime) void {
            const terminal = runtime.recordedFailure() orelse
                foundation.FailureChain.init(error.ConnectionLost);
            runtime.mutex.lock();
            defer runtime.mutex.unlock();
            switch (runtime.listener) {
                .starting => |setup| if (setup.state == .running) {
                    setup.state = .failed;
                    setup.failure = terminal;
                },
                .active => |listener| {
                    listener.noteFailure(terminal);
                    listener.failed.store(true, .release);
                    _ = listener.events.fetchOr(ev_accept, .acq_rel);
                },
                .empty => {},
            }
            for (runtime.jobs.items) |job| {
                if (job.state == .running) {
                    job.stop_requested.store(true, .release);
                    job.state = .failed;
                    job.failure = .fromChain(error.ConnectionLost, terminal);
                }
            }
            for (runtime.connections.items) |conn| {
                conn.noteFailure(terminal);
                conn.closed.store(true, .release);
                _ = conn.events.fetchOr(ev_closed, .acq_rel);
            }
            runtime.signalReady();
        }
    };
}
