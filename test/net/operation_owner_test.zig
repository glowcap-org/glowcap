const std = @import("std");
const pancake = @import("pancake");

const net = pancake.net;

test "cancelable operation interrupts blocking I/O before retirement" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var owner: net.OperationOwner = undefined;
    try owner.init(io);
    defer owner.join();

    const Attempt = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        retired: *std.atomic.Value(bool),
        operation: net.CancelableOperation = undefined,

        fn run(self: *@This()) std.Io.Cancelable!void {
            try std.Io.sleep(self.io, std.Io.Duration.fromSeconds(30), .real);
        }

        fn retire(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.retired.store(true, .release);
            self.allocator.destroy(self);
        }
    };

    var retired = std.atomic.Value(bool).init(false);
    const attempt = try allocator.create(Attempt);
    attempt.* = .{ .allocator = allocator, .io = io, .retired = &retired };
    try owner.startCancelable(&attempt.operation, Attempt.run, .{attempt}, attempt, Attempt.retire);

    const started = std.Io.Clock.now(.real, io);
    owner.cancel(&attempt.operation);
    owner.shutdown();
    owner.join();
    const elapsed = started.durationTo(std.Io.Clock.now(.real, io));

    try std.testing.expect(retired.load(.acquire));
    try std.testing.expect(elapsed.nanoseconds < std.Io.Duration.fromSeconds(2).nanoseconds);
}
