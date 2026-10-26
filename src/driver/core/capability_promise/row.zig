//! The state contract for one Host-owned capability promise: a signed give
//! redeemed inline, or a partner's pending answer passed as an argument
//! (ADR-0068).
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
    origin: Origin,
    state: State = .pending,
    abandoned: bool = false,
    projections: std.ArrayListUnmanaged(Projection) = .empty,
    operations: std.ArrayListUnmanaged(PendingOperation) = .empty,
    operation_head: usize = 0,

    /// What the promise stands for, and which session's close ends it.
    pub const Origin = union(enum) {
        /// The session whose signed give created this promise. Its session
        /// key is the recipient identity accepted by the exporter. Closing
        /// that session therefore ends redemption authority even when another
        /// session has already pipelined through this Host identity.
        inline_give: engine.PeerHandle,
        /// The session whose pending answer this promise stands for. The row
        /// holds one retain on the answer payload until the answer settles,
        /// so the stored resolution outlives the partner's GC of the position.
        answer: Answer,

        pub const Answer = struct {
            peer_handle: engine.PeerHandle,
            target: engine.AnswerTarget,
            /// The retained payload, or null once the row settled and gave
            /// the retain back. The payload's `host_promise` names this row
            /// while it is held, so the same answer lifts to one promise.
            payload: ?*engine.AnswerPayload,
        };

        pub fn peer(self: Origin) engine.PeerHandle {
            return switch (self) {
                .inline_give => |peer_handle| peer_handle,
                .answer => |answer| answer.peer_handle,
            };
        }
    };

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
            retained_capabilities: []capability.Ref,
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

    /// A resolution to data rather than to a capability. The value is owned
    /// by its arena, and every capability inside it holds a Host retain the
    /// row releases with the value.
    pub const SettledData = struct {
        arena: std.heap.ArenaAllocator,
        value: value_mod.Value,
    };

    pub const State = union(enum) {
        pending,
        /// The settled capability is lifted and held while projections and
        /// queued operations are still being finished, so a parked settle
        /// resumes without lifting twice.
        settling: Host.CapabilityLift,
        /// The settled data is owned and held while projections and queued
        /// operations are still being finished.
        settling_data: SettledData,
        fulfilled: capability.Ref,
        /// Settled to data. A send to the promise breaks with the reason a
        /// message to a non-object gets, and a listen fulfills with the data.
        fulfilled_data: SettledData,
        broken: Failure,

        /// Whether the promise still accepts queued operations and routes
        /// through its origin session: it is unsettled, or settled and still
        /// finishing what was queued.
        pub fn isPending(self: State) bool {
            return switch (self) {
                .pending, .settling, .settling_data => true,
                .fulfilled, .fulfilled_data, .broken => false,
            };
        }
    };

    pub const Failure = @import("../host/failure_text.zig");
};
