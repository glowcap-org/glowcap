//! Actor message and handler contracts, independent of queue representation.
const std = @import("std");
const model = @import("model");
const Turn = @import("turn.zig").Turn;
const Error = @import("errors.zig").Error;

// Address identity distinguishes error namespaces of separately compiled
// archives. Mutable storage prevents constant merging; its value is unused.
var error_domain: u8 = 0;

/// Callbacks catch errors where their names and ordinals are authoritative.
/// Exact text survives archive composition. Typed near errors are recoverable
/// only within the compilation that produced them.
pub const HandlerFailure = struct {
    name: []const u8,
    domain: *const anyopaque,
    ordinal: u16,

    pub fn fromError(err: anyerror) HandlerFailure {
        return .{ .name = @errorName(err), .domain = &error_domain, .ordinal = @intFromError(err) };
    }
    pub fn localError(self: HandlerFailure) anyerror {
        const local_domain: *const anyopaque = &error_domain;
        if (self.domain != local_domain) return error.ForeignHandlerRefused;
        return @errorFromInt(self.ordinal);
    }
};
pub const HandlerResult = union(enum) {
    returned: model.Argument,
    refused: HandlerFailure,

    pub fn fromResult(result: anyerror!model.Argument) HandlerResult {
        return if (result) |value| .{ .returned = value } else |err| .{ .refused = HandlerFailure.fromError(err) };
    }
};

/// A message to an actor: a verb (method selector) and its arguments. From the
/// handler's side the verb and args are borrowed for the duration of the turn:
/// a handler never frees them, and one that keeps a value past its turn copies
/// it first.
pub const Message = struct {
    verb: []const u8,
    args: []const model.Argument = &.{},

    /// What an argument accessor refuses. A handler returns these like any
    /// other error, and the vat turns a handler error into the partner's
    /// `op:resolve` break, so a malformed call breaks its own answer instead
    /// of reaching the host.
    pub const ArgError = error{ MissingArgument, WrongArgumentType };

    /// The argument at `i`, or `MissingArgument`.
    ///
    /// Arity is the *partner's* choice: `serve` peels the leading symbol as the
    /// verb and hands the rest through, so a deliver carrying only a verb
    /// arrives with no arguments at all. An unchecked index on that is a safety
    /// panic in a safe build and an out-of-bounds read otherwise, which on a
    /// multi-session host takes down every other session with it. The typed
    /// accessors below are shorter to write than the unwrap they replace, so
    /// there is no cheaper wrong path left. `msg.args` is still there for a
    /// handler that has already checked `args.len`.
    pub fn arg(self: Message, i: usize) ArgError!model.Argument {
        if (i >= self.args.len) return error.MissingArgument;
        return self.args[i];
    }

    /// The `bytes` argument at `i`.
    pub fn argBytes(self: Message, i: usize) ArgError![]const u8 {
        return switch (try self.arg(i)) {
            .bytes => |b| b,
            else => error.WrongArgumentType,
        };
    }

    /// The `string` argument at `i`.
    pub fn argString(self: Message, i: usize) ArgError![]const u8 {
        return switch (try self.arg(i)) {
            .string => |s| s,
            else => error.WrongArgumentType,
        };
    }

    /// The `integer` argument at `i`.
    pub fn argInt(self: Message, i: usize) ArgError!i64 {
        return switch (try self.arg(i)) {
            .integer => |n| n,
            else => error.WrongArgumentType,
        };
    }
};

/// An adapter-owned local message. The Vat knows its charge and lifetime, not
/// its value vocabulary. Copy owns the payload in the queue arena. Retire ends
/// external custody before that arena is reclaimed. Failure must leave no
/// external custody behind. `owned_bytes` includes every requested payload byte
/// and any adapter-owned retain metadata, excluding the queue row itself.
pub const OpaqueMessage = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    owned_bytes: usize,

    /// Queue copies can refuse only allocation, shape or bounded resources.
    /// Explicit tags survive separate archives. Zig error ordinals do not.
    pub const CopyFailure = enum(u8) {
        out_of_memory,
        malformed_view,
        resource_exhausted,

        pub fn toError(self: CopyFailure) Error {
            return switch (self) {
                .out_of_memory => error.OutOfMemory,
                .malformed_view => error.MalformedView,
                .resource_exhausted => error.ResourceExhausted,
            };
        }
    };
    pub const CopyResult = union(enum) { copied: OpaqueMessage, refused: CopyFailure };

    pub const VTable = struct {
        /// Stable adapter protocol identity, independent of its archive address.
        /// Zero is untyped. Adapters that inspect ctx declare a nonzero identity
        /// and still validate the actual runtime owner before using authority.
        protocol: [16]u8 = @splat(0),
        /// No Vat reentry during unpublished admission. The Vat refuses
        /// queue/turn mutations until this copy returns. Preserve owned_bytes.
        copy: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) CopyResult,
        retire: *const fn (ctx: *anyopaque, reason: ?[]const u8) void,
    };
};

/// Exactly one queue representation. Opaque payloads never enter a Port or a
/// codec, and only behaviors that explicitly support them receive them.
pub const Delivery = union(enum) {
    message: Message,
    owned: OpaqueMessage,

    pub fn retire(self: *Delivery, reason: ?[]const u8) void {
        const retired = self.*;
        self.* = .{ .message = .{ .verb = "" } };
        switch (retired) {
            .message => {},
            .owned => |body| body.vtable.retire(body.ctx, reason),
        }
    }
};

/// A *hosted* actor: state and behavior the vat does not own, invoked on each
/// deliver (ADR-0071). This is how a non-Zig consumer hosts an actor over the C
/// ABI, it hands the vat an opaque `ctx` and a thunk. The `handle` receives the
/// full `Turn`, so a hosted actor sends and spawns exactly like a Zig actor.
/// Only vat-owned time-travel is out of reach, since the vat cannot clone `ctx`
/// (a vat holding a hosted actor is not snapshottable, `NotSnapshottable`).
pub const HostedActor = struct {
    pub const Result = HandlerResult;
    /// The consumer's state, opaque to the vat, passed back to `handle`/`free`.
    ctx: *anyopaque,
    /// Invoked on each deliver. Returns the reply, borrowed for the turn, the
    /// vat clones it onto the wire or a listener, or an error (settled broken).
    handle: *const fn (ctx: *anyopaque, turn: *Turn, msg: Message) Result,
    /// Optional adapter-local delivery. Ordinary model handlers never receive
    /// opaque payloads through their data-only contract.
    /// Null means success. Refusal names immutable archive-owned failure text.
    /// Produce the name where the handler's Zig error was caught.
    handleOpaque: ?*const fn (ctx: *anyopaque, turn: *Turn, msg: OpaqueMessage) ?[]const u8 = null,
    /// Release `ctx` when the actor's box drops (vat `deinit`, or a failed
    /// spawn). Null when the consumer keeps ownership of `ctx`.
    free: ?*const fn (ctx: *anyopaque) void = null,
};
