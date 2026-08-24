//! The state contract for one Host-owned inline-give capability promise.
//!
//! `host.zig` stores these rows while `capability_promise.zig` drives their
//! lifecycle. Keeping the row vocabulary here makes that shared contract
//! explicit without making the Host storage owner depend on the lifecycle
//! implementation's private operations.

const std = @import("std");

const engine = @import("engine");
const model = @import("model");

const capability = @import("../capability.zig");
const host_mod = @import("../host.zig");
const value_mod = @import("../value.zig");

const Host = host_mod.Host;

pub const Row = struct {
    /// The session whose signed give created this promise. Its session key is
    /// the recipient identity accepted by the exporter; closing that session
    /// therefore ends redemption authority even when another session has
    /// already pipelined through this Host identity.
    introducing_peer: engine.PeerHandle,
    state: State = .pending,
    abandoned: bool = false,
    projections: std.ArrayListUnmanaged(Projection) = .empty,
    operations: std.ArrayListUnmanaged(PendingOperation) = .empty,
    operation_head: usize = 0,

    pub const Projection = struct {
        peer_handle: engine.PeerHandle,
        export_position: model.ExportPosition,
        answer_target: engine.AnswerTarget,
    };

    pub const PendingOperation = struct {
        source_peer: engine.PeerHandle,
        result_vow: ?u64,
        stage: union(enum) {
            queued,
            dispatched: engine.PeerHandle,
        } = .queued,
        action: Action,

        pub const Action = union(enum) {
            send: OwnedMessage,
            tell: OwnedMessage,
            listen,
        };

        pub const OwnedMessage = struct {
            arena: std.heap.ArenaAllocator,
            verb: []const u8,
            values: []const value_mod.Value,
            retained_capabilities: []Host.StagedCapabilityRetain,
            release_head: usize = 0,
        };

        pub fn deinit(self: *PendingOperation) void {
            switch (self.action) {
                .send, .tell => |*message| {
                    std.debug.assert(message.release_head == message.retained_capabilities.len);
                    message.arena.deinit();
                },
                .listen => {},
            }
        }
    };

    pub const State = union(enum) {
        pending,
        settling: Host.CapabilityLift,
        fulfilled: capability.Ref,
        broken: Failure,
    };

    /// A handoff failure must survive the Node action that carried it without
    /// allocating at the terminal edge. The message is diagnostic text, not
    /// protocol data; retain a bounded UTF-8 prefix and keep the state typed.
    pub const Failure = struct {
        bytes: [256]u8 = undefined,
        len: u16 = 0,

        pub fn init(text: []const u8) Failure {
            var failure: Failure = .{};
            const limit = @min(text.len, failure.bytes.len);
            var end = limit;
            while (end != 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
            @memcpy(failure.bytes[0..end], text[0..end]);
            failure.len = @intCast(end);
            return failure;
        }

        pub fn message(self: *const Failure) []const u8 {
            return self.bytes[0..self.len];
        }
    };
};
