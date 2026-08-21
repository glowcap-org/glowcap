//! One cancelable native relay dial owned by the multiplexed runtime.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const net = @import("net");

pub fn State(
    comptime Runtime: type,
    comptime Profile: type,
    comptime ConnState: type,
) type {
    return struct {
        const Self = @This();

        runtime: *Runtime,
        request_id: u64,
        profile: Profile,
        locator: model.PeerLocator,
        state: Status = .running,
        failure: ?net.netlayer.DialFailure = null,
        conn: ?*ConnState = null,
        announced: bool = false,
        stop_requested: std.atomic.Value(bool) = .init(false),
        operation: net.CancelableOperation = undefined,
        retirement: Retirement = .normal,
        retired: bool = false,
        cleanup: ?foundation.FailureChain = null,

        pub const Status = enum { running, succeeded, failed, cancelled };
        pub const Retirement = enum { normal, publish_cancel };

        pub fn noteCleanup(job: *Self, later: foundation.FailureChain) void {
            if (job.cleanup) |*first| first.noteChain(later) else job.cleanup = later;
        }

        pub fn run(job: *Self) std.Io.Cancelable!void {
            const runtime = job.runtime;
            const raw = switch (runtime.resident(job.profile).dialRawOutcomeCancelable(
                job.locator,
                &job.stop_requested,
            )) {
                .connected => |connected| connected,
                .failed => |failure| {
                    runtime.completeDial(job, failure);
                    return;
                },
            };
            var owned_raw = true;
            defer if (owned_raw) {
                var discarded = raw;
                if (discarded.close()) |failure| job.noteCleanup(failure);
            };

            runtime.mutex.lock();
            defer runtime.mutex.unlock();
            if (runtime.stopping.load(.acquire) or job.stop_requested.load(.acquire)) return;

            const conn = runtime.allocator.create(ConnState) catch |err| {
                var failure = net.netlayer.DialFailure.init(err);
                var discarded = raw;
                if (discarded.close()) |cleanup| failure.chain.noteChain(cleanup);
                owned_raw = false;
                job.state = .failed;
                job.failure = failure;
                runtime.signalReady();
                return;
            };
            conn.* = .{ .id = 0, .raw = raw };
            owned_raw = false;
            if (runtime.addConnectionLocked(conn)) |_| {
                job.conn = conn;
                job.state = .succeeded;
                runtime.signalControl();
                runtime.signalReady();
                return;
            } else |err| {
                var failure = net.netlayer.DialFailure.init(if (err == error.OutOfMemory)
                    error.OutOfMemory
                else
                    error.ConnectionLost);
                if (conn.raw.close()) |cleanup| failure.chain.noteChain(cleanup);
                runtime.allocator.destroy(conn);
                job.state = .failed;
                job.failure = failure;
                runtime.signalReady();
            }
        }

        pub fn retire(raw: *anyopaque) void {
            const job: *Self = @ptrCast(@alignCast(raw));
            job.runtime.retireDialJob(job);
        }
    };
}
