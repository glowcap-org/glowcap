//! Admission, completion, cancellation, and readiness-backed retirement for
//! one relay dial. Cancellation never joins on the driver thread. The worker
//! publishes a tombstone, and the request-id readiness edge owns the
//! cleanup claim.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const net = @import("net");

pub fn Machine(
    comptime Runtime: type,
    comptime DialState: type,
    comptime Reactor: type,
    comptime profileForTransport: anytype,
) type {
    return struct {
        pub fn findLocked(runtime: *Runtime, request_id: u64) ?*DialState {
            for (runtime.jobs.items) |job| if (job.request_id == request_id) return job;
            return null;
        }

        pub fn complete(runtime: *Runtime, job: *DialState, failure: net.netlayer.DialFailure) void {
            runtime.mutex.lock();
            defer runtime.mutex.unlock();
            if (runtime.stopping.load(.acquire) or job.stop_requested.load(.acquire)) return;
            job.state = .failed;
            job.failure = failure;
            runtime.signalReady();
        }

        pub fn start(runtime: *Runtime, request_id: u64, locator: model.PeerLocator) !void {
            const profile = profileForTransport(locator.transport) orelse return error.InvalidAddress;
            const owned_locator = try model.clonePeerLocator(runtime.allocator, locator);
            errdefer model.freePeerLocator(runtime.allocator, owned_locator);
            const job = try runtime.allocator.create(DialState);
            errdefer runtime.allocator.destroy(job);
            job.* = .{
                .runtime = runtime,
                .request_id = @intCast(request_id),
                .profile = profile,
                .locator = owned_locator,
            };

            runtime.mutex.lock();
            defer runtime.mutex.unlock();
            if (runtime.stopping.load(.acquire) or findLocked(runtime, job.request_id) != null)
                return error.ConnectionLost;
            try runtime.jobs.append(runtime.allocator, job);
            errdefer _ = runtime.jobs.pop();
            runtime.tasks.startCancelable(
                &job.operation,
                DialState.run,
                .{job},
                job,
                DialState.retire,
            ) catch |err| return switch (err) {
                error.Closing => error.ConnectionLost,
                error.ConcurrencyUnavailable => error.OutOfMemory,
            };
        }

        pub fn retire(runtime: *Runtime, job: *DialState) void {
            runtime.mutex.lock();
            if (job.retirement == .publish_cancel and !runtime.stopping.load(.acquire)) {
                if (job.conn) |conn| {
                    conn.closeAndRetain();
                    if (conn.claimFailure()) |cleanup| job.noteCleanup(cleanup);
                    std.debug.assert(runtime.by_id.remove(conn.id));
                    for (runtime.connections.items, 0..) |candidate, index| if (candidate == conn) {
                        std.debug.assert(runtime.connections.swapRemove(index) == conn);
                        break;
                    };
                    runtime.allocator.destroy(conn);
                    job.conn = null;
                }
                job.state = .cancelled;
                job.retired = true;
                job.announced = false;
                runtime.mutex.unlock();
                runtime.signalReady();
                return;
            }
            if (runtime.stopping.load(.acquire))
                if (job.cleanup) |cleanup| runtime.noteCleanupFailure(cleanup);
            Reactor.detachJobLocked(runtime, job);
            runtime.mutex.unlock();
            Reactor.destroyDial(runtime, job);
        }

        pub fn finish(runtime: *Runtime, request_id: u64) net.MultiplexedDialRawFinishOutcome {
            runtime.mutex.lock();
            const job = findLocked(runtime, request_id) orelse {
                runtime.mutex.unlock();
                return .{ .failed = .init(error.ConnectionLost) };
            };
            switch (job.state) {
                .running => {
                    job.stop_requested.store(true, .release);
                    Reactor.detachJobLocked(runtime, job);
                    runtime.mutex.unlock();
                    _ = runtime.tasks.cancel(&job.operation);
                    runtime.signalControl();
                    return .{ .failed = .init(error.ConnectionLost) };
                },
                .failed => {
                    const failure = job.failure orelse net.netlayer.DialFailure.init(error.ConnectionLost);
                    Reactor.detachJobLocked(runtime, job);
                    runtime.mutex.unlock();
                    _ = runtime.tasks.reap(&job.operation);
                    return .{ .failed = failure };
                },
                .succeeded => {
                    const conn = job.conn orelse {
                        Reactor.detachJobLocked(runtime, job);
                        runtime.mutex.unlock();
                        _ = runtime.tasks.reap(&job.operation);
                        return .{ .failed = .init(error.ConnectionLost) };
                    };
                    const id = conn.id;
                    Reactor.detachJobLocked(runtime, job);
                    runtime.mutex.unlock();
                    _ = runtime.tasks.reap(&job.operation);
                    return .{ .connected = id };
                },
                .cancelled => {
                    const cleanup = job.cleanup;
                    Reactor.detachJobLocked(runtime, job);
                    runtime.mutex.unlock();
                    Reactor.destroyDial(runtime, job);
                    return .{ .failed = .fromChain(
                        error.ConnectionLost,
                        cleanup orelse .init(error.ConnectionLost),
                    ) };
                },
            }
        }

        pub fn cancel(runtime: *Runtime, request_id: u64) ?foundation.FailureChain {
            runtime.mutex.lock();
            const job = findLocked(runtime, request_id) orelse {
                runtime.mutex.unlock();
                return null;
            };
            if (job.retired) {
                const cleanup = job.cleanup;
                Reactor.detachJobLocked(runtime, job);
                runtime.mutex.unlock();
                Reactor.destroyDial(runtime, job);
                return cleanup;
            }
            if (job.retirement == .publish_cancel) {
                runtime.mutex.unlock();
                return null;
            }
            job.stop_requested.store(true, .release);
            job.retirement = .publish_cancel;
            runtime.mutex.unlock();
            _ = runtime.tasks.cancel(&job.operation);
            runtime.signalControl();
            return null;
        }
    };
}
