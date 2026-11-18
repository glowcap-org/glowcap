//! The dial side of `net.completion_resident`: starting a connect through the
//! transport policy, finishing it into an admitted connection, and canceling
//! one the runtime no longer wants.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const netlayer = @import("../netlayer.zig");
const resident_mod = @import("../multiplexed_resident.zig");
const completions = @import("completions.zig");
const userData = completions.userData;

pub fn Machine(comptime Self: type, comptime Policy: type) type {
    return struct {
        fn of(ctx: *anyopaque) *Self {
            return @ptrCast(@alignCast(ctx));
        }

        pub fn startConnect(
            ctx: *anyopaque,
            request_id: usize,
            locator: model.PeerLocator,
            options: netlayer.OperationOptions,
            _: netlayer.DialOrigin,
        ) resident_mod.RawDialStartOutcome {
            const self = of(ctx);
            defer self.pump();
            options.requireInherited() catch |err| return .{ .failed = .init(err) };
            const target = Policy.resolve(locator) catch |err| return .{ .failed = dialFailure(err) };
            self.dials.ensureUnusedCapacity(self.allocator, 1) catch |err| return .{ .failed = .init(err) };
            const fd = self.backend.startDial(userData(.connect, request_id), target) catch |err|
                return .{ .failed = dialFailure(err) };
            self.dials.putAssumeCapacity(request_id, .{ .fd = fd, .state = .connecting });
            return .admitted;
        }

        /// Keeps the exact cause in the chain and classifies it on the
        /// closed retry axis. A cause outside that axis is a lost connection,
        /// except an unroutable locator and a provider that broke its contract
        /// or lacks the verb, which no retry repairs.
        fn dialFailure(err: anyerror) netlayer.DialFailure {
            const classification: netlayer.DialError = switch (err) {
                error.InvalidAddress,
                error.InvalidOptions,
                error.WouldBlock,
                error.ConnectionRefused,
                error.NetworkUnreachable,
                error.TimedOut,
                error.ConnectionLost,
                error.SocketConfigurationFailed,
                error.WakeNudgeFailed,
                error.OutOfMemory,
                => |known| known,
                error.UnknownTransport, error.AddressNotAvailable => error.InvalidAddress,
                error.ProviderContract, error.OperationUnsupported => error.InvalidOptions,
                else => error.ConnectionLost,
            };
            return .fromChain(classification, .init(err));
        }

        pub fn finishConnect(ctx: *anyopaque, request_id: usize) resident_mod.RawDialFinishOutcome {
            const self = of(ctx);
            defer self.pump();
            const dial = self.dials.fetchRemove(request_id) orelse
                return .{ .failed = .init(error.InvalidOptions) };
            switch (dial.value.state) {
                .connected => {},
                .failed => |err| {
                    self.backend.closeFd(dial.value.fd);
                    var failure = dialFailure(err);
                    if (self.dial_failures.fetchRemove(request_id)) |kept| failure.chain = kept.value;
                    return .{ .failed = failure };
                },
                .connecting, .cancelling, .cancelled => {
                    self.latch(error.ProviderContract);
                    return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
                },
            }
            const id = self.adopt(dial.value.fd) catch |err| {
                self.backend.closeFd(dial.value.fd);
                return .{ .failed = .init(err) };
            };
            return .{ .connected = id };
        }

        pub fn cancelConnect(ctx: *anyopaque, request_id: usize) ?foundation.FailureChain {
            const self = of(ctx);
            defer self.pump();
            const dial = self.dials.getPtr(request_id) orelse return null;
            switch (dial.state) {
                .cancelled => {
                    std.debug.assert(self.dials.remove(request_id));
                    return null;
                },
                .cancelling => return null,
                .connected, .failed => {
                    self.backend.closeFd(dial.fd);
                    std.debug.assert(self.dials.remove(request_id));
                    // idempotent: only a failed dial kept a chain.
                    _ = self.dial_failures.remove(request_id);
                    return null;
                },
                .connecting => {
                    dial.state = .cancelling;
                    // A queued connect holds the socket, so closing the
                    // descriptor alone leaves it connecting until the kernel
                    // gives up. Shutting it down retires the connect now.
                    self.backend.shutdownFd(dial.fd);
                    self.backend.submitClose(userData(.dial_close, request_id), dial.fd) catch |err| {
                        self.backend.closeFd(dial.fd);
                        return .init(err);
                    };
                    dial.inflight += 1;
                    return null;
                },
            }
        }
    };
}
