const std = @import("std");

const glowcap = @import("glowcap");
const net = glowcap.net;

pub fn close(listener: net.netlayer.Listener) void {
    std.testing.expect(listener.close() == null) catch unreachable;
}

pub fn deinit(result: *net.netlayer.ListenResult) void {
    std.testing.expect(result.deinit() == null) catch unreachable;
}

/// Test-side blocking drive for the production `ListenResult` state machine.
pub fn listenBlocking(
    layer: net.netlayer.Netlayer,
    allocator: std.mem.Allocator,
    config: net.netlayer.ListenConfig,
) !net.netlayer.Listener {
    var result = switch (layer.listen(allocator, config)) {
        .admitted => |result| result,
        .failed => |failure| return failure.cause,
    };
    switch (result) {
        .ready => |listener| return listener,
        .pending => |*attempt| {
            var pollfds: [1]std.posix.pollfd = undefined;
            const ready = try net.waitAnyReadable(
                &.{},
                &pollfds,
                -1,
                &.{attempt.readinessFd()},
            );
            std.debug.assert(ready.? == 0);
            return switch (attempt.finish(allocator)) {
                .ready => |listener| listener,
                .failed => |failure| return failure.cause,
            };
        },
    }
}
