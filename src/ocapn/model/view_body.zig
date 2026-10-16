//! Borrowed CapTP message variants and their owned projection transaction.
//!
//! Value and sequence views stay in `view.zig`. This leaf owns the message
//! sum, the arm-for-arm model assertion, and the failure-atomic materialization
//! of one complete body.

const std = @import("std");
const model = @import("mod.zig");

pub fn Types(
    comptime Reference: type,
    comptime Resolution: type,
    comptime Args: type,
    comptime PositionList: type,
    comptime PeerLocator: type,
    comptime StartSessionView: type,
    comptime MaterializeError: type,
) type {
    return struct {
        pub const Deliver = struct {
            target: Reference,
            args: Args,
            answer: ?model.AnswerPosition = null,
            resolve_me_desc: ?Reference = null,
            listen_mode: model.ListenMode = .shortening_or_settling,
        };

        pub const Resolve = struct {
            answer: model.AnswerPosition,
            resolution: Resolution,
        };

        pub const Listen = struct {
            target: Reference,
            listener: Reference,
            mode: model.ListenMode,
        };

        pub const Get = struct {
            receiver: Reference,
            field: []const u8,
            answer: model.AnswerPosition,
        };

        pub const Index = struct {
            receiver: Reference,
            index: model.Integer,
            answer: model.AnswerPosition,
        };

        pub const Untag = struct {
            receiver: Reference,
            tag: []const u8,
            answer: model.AnswerPosition,
        };

        pub const GcExport = struct {
            positions: PositionList,
            deltas: PositionList,
        };

        pub const GcAnswer = struct {
            positions: PositionList,
        };

        pub const Abort = struct {
            kind: model.AbortKind,
            message: []const u8,
        };

        pub const StartSession = StartSessionView;

        /// Borrowed codec-neutral body of a CapTP `model.Message`.
        ///
        /// Produced by a codec's `decodeBody` (the wire path) or by `fromOwned`
        /// (the owned-fallback path). Materialize with `toOwned`.
        pub const Body = union(enum) {
            deliver: Deliver,
            resolve: Resolve,
            gc_export: GcExport,
            gc_answer: GcAnswer,
            start_session: StartSession,
            abort: Abort,
            listen: Listen,
            get: Get,
            index: Index,
            untag: Untag,

            /// Project a borrowed body from an owned `model.Message`.
            pub fn fromOwned(owned: *const model.Message) Body {
                return switch (owned.*) {
                    .deliver => |*deliver| .{ .deliver = .{
                        .target = Reference.fromOwned(&deliver.target),
                        .args = Args.fromOwnedSlice(deliver.args),
                        .answer = deliver.answer,
                        .listen_mode = deliver.listen_mode,
                        .resolve_me_desc = if (deliver.resolve_me_desc) |*r| Reference.fromOwned(r) else null,
                    } },
                    .resolve => |*resolve| .{ .resolve = .{
                        .answer = resolve.answer,
                        .resolution = Resolution.fromOwned(&resolve.resolution),
                    } },
                    .gc_export => |*gc| .{ .gc_export = .{
                        .positions = PositionList.fromOwnedSlice(gc.positions),
                        .deltas = PositionList.fromOwnedSlice(gc.deltas),
                    } },
                    .gc_answer => |*gc| .{ .gc_answer = .{
                        .positions = PositionList.fromOwnedSlice(gc.positions),
                    } },
                    .start_session => |*ss| .{ .start_session = .{
                        .captp_version = ss.captp_version,
                        .session_pubkey = ss.session_pubkey.bytes,
                        .acceptable_location = PeerLocator.fromOwned(&ss.acceptable_location),
                        .acceptable_location_sig = .{ .raw = ss.acceptable_location_sig.bytes },
                    } },
                    .abort => |*abort| .{ .abort = .{ .kind = abort.kind, .message = abort.message } },
                    .listen => |*listen| .{ .listen = .{
                        .target = Reference.fromOwned(&listen.target),
                        .listener = Reference.fromOwned(&listen.listener),
                        .mode = listen.mode,
                    } },
                    .get => |*get| .{ .get = .{
                        .receiver = Reference.fromOwned(&get.receiver),
                        .field = get.field,
                        .answer = get.answer,
                    } },
                    .index => |*index| .{ .index = .{
                        .receiver = Reference.fromOwned(&index.receiver),
                        .index = index.index,
                        .answer = index.answer,
                    } },
                    .untag => |*untag| .{ .untag = .{
                        .receiver = Reference.fromOwned(&untag.receiver),
                        .tag = untag.tag,
                        .answer = untag.answer,
                    } },
                };
            }

            /// Materialize one complete owned message. Every partially owned
            /// reference, key, and sequence is released on refusal.
            pub fn toOwned(self: Body, allocator: std.mem.Allocator) MaterializeError!model.Message {
                return switch (self) {
                    .deliver => |deliver| try deliverToOwned(allocator, deliver),
                    .resolve => |resolve| .{ .resolve = .{
                        .answer = resolve.answer,
                        .resolution = try resolve.resolution.toOwned(allocator),
                    } },
                    .gc_export => |gc| blk: {
                        const positions = try gc.positions.toOwnedSlice(allocator);
                        errdefer allocator.free(positions);
                        const deltas = try gc.deltas.toOwnedSlice(allocator);
                        break :blk .{ .gc_export = .{ .positions = positions, .deltas = deltas } };
                    },
                    .gc_answer => |gc| .{ .gc_answer = .{ .positions = try gc.positions.toOwnedSlice(allocator) } },
                    .start_session => |ss| blk: {
                        const session_pubkey = try allocator.dupe(u8, ss.session_pubkey);
                        errdefer allocator.free(session_pubkey);
                        const acceptable_location = try ss.acceptable_location.toOwned(allocator);
                        errdefer model.freePeerLocator(allocator, acceptable_location);
                        const sig = try ss.acceptable_location_sig.toOwned(allocator);
                        break :blk .{ .start_session = .{
                            .captp_version = ss.captp_version,
                            .session_pubkey = .{ .bytes = session_pubkey },
                            .acceptable_location = acceptable_location,
                            .acceptable_location_sig = .{ .bytes = sig },
                        } };
                    },
                    .abort => |abort| .{ .abort = .{
                        .kind = abort.kind,
                        .message = try allocator.dupe(u8, abort.message),
                    } },
                    .listen => |listen| blk: {
                        const target = try listen.target.toOwned(allocator);
                        errdefer model.freeReference(allocator, target);
                        const listener = try listen.listener.toOwned(allocator);
                        break :blk .{ .listen = .{ .target = target, .listener = listener, .mode = listen.mode } };
                    },
                    .get => |get| blk: {
                        const receiver = try get.receiver.toOwned(allocator);
                        errdefer model.freeReference(allocator, receiver);
                        const field = try allocator.dupe(u8, get.field);
                        break :blk .{ .get = .{ .receiver = receiver, .field = field, .answer = get.answer } };
                    },
                    .index => |index| blk: {
                        const receiver = try index.receiver.toOwned(allocator);
                        errdefer model.freeReference(allocator, receiver);
                        const owned_index: model.Integer = switch (index.index) {
                            .integer => |value| .{ .integer = value },
                            .big_integer => |big| .{ .big_integer = .{
                                .negative = big.negative,
                                .digits = try allocator.dupe(u8, big.digits),
                            } },
                        };
                        break :blk .{ .index = .{
                            .receiver = receiver,
                            .index = owned_index,
                            .answer = index.answer,
                        } };
                    },
                    .untag => |untag| blk: {
                        const receiver = try untag.receiver.toOwned(allocator);
                        errdefer model.freeReference(allocator, receiver);
                        const tag = try allocator.dupe(u8, untag.tag);
                        break :blk .{ .untag = .{ .receiver = receiver, .tag = tag, .answer = untag.answer } };
                    },
                };
            }
        };

        comptime {
            model.assertMirrorsMessageKinds(Body);
        }

        fn deliverToOwned(allocator: std.mem.Allocator, deliver: Deliver) MaterializeError!model.Message {
            const target = try deliver.target.toOwned(allocator);
            errdefer model.freeReference(allocator, target);
            const resolve_me_desc = if (deliver.resolve_me_desc) |r| try r.toOwned(allocator) else null;
            errdefer if (resolve_me_desc) |r| model.freeReference(allocator, r);
            const args = try deliver.args.toOwnedSlice(allocator);
            return .{ .deliver = .{
                .target = target,
                .args = args,
                .answer = deliver.answer,
                .listen_mode = deliver.listen_mode,
                .resolve_me_desc = resolve_me_desc,
            } };
        }
    };
}
