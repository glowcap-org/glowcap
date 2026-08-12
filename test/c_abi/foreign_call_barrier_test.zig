const std = @import("std");

const c = @import("c_abi_shared");

test "connection release waits for admitted foreign operations" {
    const FakeStream = struct {
        io: std.Io,
        shutdown_called: *std.Io.Semaphore,
        deinitialized: *std.atomic.Value(bool),

        pub fn shutdown(self: *@This()) void {
            self.shutdown_called.post(self.io);
        }

        pub fn deinit(self: *@This()) void {
            self.deinitialized.store(true, .release);
        }
    };
    const Payload = struct {
        stream: FakeStream,
        operations: c.ForeignCallBarrier,
        directions: c.ConnDirectionGates,
        read_buf: []u8,
        write_buf: []u8,
        allocator: std.mem.Allocator,
    };
    const lifecycle = c.ConnLifecycle(Payload);
    const Operation = struct {
        payload: *Payload,
        entered: *std.Io.Semaphore,
        leave: *std.Io.Semaphore,

        fn run(self: @This()) void {
            std.debug.assert(self.payload.operations.acquire(self.payload.stream.io));
            self.entered.post(self.payload.stream.io);
            self.leave.waitUncancelable(self.payload.stream.io);
            self.payload.operations.release(self.payload.stream.io);
        }
    };

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var shutdown_called: std.Io.Semaphore = .{ .permits = 0 };
    var deinitialized: std.atomic.Value(bool) = .init(false);
    const payload = lifecycle.begin(std.testing.allocator, 1).?;
    payload.stream = .{
        .io = io,
        .shutdown_called = &shutdown_called,
        .deinitialized = &deinitialized,
    };

    var entered: std.Io.Semaphore = .{ .permits = 0 };
    var leave: std.Io.Semaphore = .{ .permits = 0 };
    var operation = try io.concurrent(Operation.run, .{Operation{
        .payload = payload,
        .entered = &entered,
        .leave = &leave,
    }});
    entered.waitUncancelable(io);

    var destroy = try io.concurrent(lifecycle.destroy, .{payload});
    shutdown_called.waitUncancelable(io);
    try std.testing.expect(!deinitialized.load(.acquire));
    try std.testing.expect(!payload.operations.acquire(io));

    leave.post(io);
    operation.await(io);
    destroy.await(io);
    try std.testing.expect(deinitialized.load(.acquire));
}

test "connection direction gates serialize peers and preserve full duplex" {
    const GateTask = struct {
        io: std.Io,
        gate: *std.Io.Mutex,
        attempted: *std.Io.Semaphore,
        entered: *std.Io.Semaphore,
        leave: *std.Io.Semaphore,

        fn run(self: @This()) void {
            self.attempted.post(self.io);
            self.gate.lockUncancelable(self.io);
            defer self.gate.unlock(self.io);
            self.entered.post(self.io);
            self.leave.waitUncancelable(self.io);
        }
    };

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var gates: c.ConnDirectionGates = .{};
    var attempted: std.Io.Semaphore = .{ .permits = 0 };
    var first_entered: std.Io.Semaphore = .{ .permits = 0 };
    var second_entered: std.Io.Semaphore = .{ .permits = 0 };
    var write_entered: std.Io.Semaphore = .{ .permits = 0 };
    var first_leave: std.Io.Semaphore = .{ .permits = 0 };
    var second_leave: std.Io.Semaphore = .{ .permits = 0 };
    var write_leave: std.Io.Semaphore = .{ .permits = 0 };

    var first_read = try io.concurrent(GateTask.run, .{GateTask{
        .io = io,
        .gate = &gates.read,
        .attempted = &attempted,
        .entered = &first_entered,
        .leave = &first_leave,
    }});
    attempted.waitUncancelable(io);
    first_entered.waitUncancelable(io);

    var second_read = try io.concurrent(GateTask.run, .{GateTask{
        .io = io,
        .gate = &gates.read,
        .attempted = &attempted,
        .entered = &second_entered,
        .leave = &second_leave,
    }});
    attempted.waitUncancelable(io);

    var write = try io.concurrent(GateTask.run, .{GateTask{
        .io = io,
        .gate = &gates.write,
        .attempted = &attempted,
        .entered = &write_entered,
        .leave = &write_leave,
    }});
    attempted.waitUncancelable(io);
    // The writer enters while the first reader still owns the read gate; the
    // second reader cannot enter until that first reader leaves.
    write_entered.waitUncancelable(io);
    write_leave.post(io);
    write.await(io);

    first_leave.post(io);
    first_read.await(io);
    second_entered.waitUncancelable(io);
    second_leave.post(io);
    second_read.await(io);
}
