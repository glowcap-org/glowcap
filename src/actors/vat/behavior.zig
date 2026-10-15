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
/// A reply borrows the active turn in either representation. `returned`
/// carries model containers and `viewed` lends a sequence backing. A near
/// call materializes views into the turn arena. A served reply remains a
/// view through interception and is copied once into the retained answer.
pub const HandlerResult = union(enum) {
    returned: model.Argument,
    viewed: model.view.Argument,
    refused: HandlerFailure,

    pub fn fromResult(result: anyerror!model.Argument) HandlerResult {
        return if (result) |value| .{ .returned = value } else |err| .{ .refused = HandlerFailure.fromError(err) };
    }
};

/// A message a caller sends: a verb (method selector) and the arguments it
/// owns. `send`, `tell`, `near`, and `forward` borrow both only for the call.
/// The local arm clones them into the queue and the far arm encodes them
/// onto the wire before the call returns.
pub const Message = struct {
    verb: []const u8,
    args: []const model.Argument = &.{},

    /// This message as a handler reads it. The owned arguments project into
    /// views in place, so a near call hands the handler the caller's storage.
    pub fn delivery(self: Message) Delivery {
        return .{ .verb = self.verb, .args = .fromOwnedSlice(self.args) };
    }
};

/// A message as a handler receives it: the verb and its arguments as views,
/// borrowed for the duration of the turn. A wire deliver's views read the
/// frame's bytes where they lie, and a local call's views project the
/// caller's owned arguments, so no path copies a value a handler never reads.
/// A handler never frees them, and one that keeps a value past its turn
/// copies it first (`Argument.toOwned`).
pub const Delivery = struct {
    verb: []const u8,
    args: model.view.Args = .fromOwnedSlice(&.{}),
    /// How many reference and handoff slots `args` holds at every depth,
    /// when session validation counted them for a wire deliver, or null
    /// when nothing counted (a near call, a forward). The Host reads zero
    /// as leave to hand its handler the views as they are.
    reference_slots: ?u32 = null,

    /// What an argument accessor refuses. A handler returns these like any
    /// other error, and the vat turns a handler error into the partner's
    /// `op:resolve` break, so a malformed call breaks its own answer instead
    /// of reaching the host. `MalformedView` is a codec-backed element that
    /// did not project, which session validation makes unreachable on a
    /// wire deliver.
    pub const ArgError = error{ MissingArgument, WrongArgumentType, MalformedView };

    /// The argument at `i`, or `MissingArgument`.
    ///
    /// Arity is the *partner's* choice: `serve` peels the leading symbol as the
    /// verb and hands the rest through, so a deliver carrying only a verb
    /// arrives with no arguments at all. The typed accessors below are shorter
    /// to write than the match they replace, so there is no cheaper wrong path
    /// left. `args` is still there for a handler that walks them all.
    pub fn arg(self: Delivery, i: usize) ArgError!model.view.Argument {
        const count = self.args.len() catch return error.MalformedView;
        if (i >= count) return error.MissingArgument;
        return self.args.at(i) catch error.MalformedView;
    }

    /// The `bytes` argument at `i`.
    pub fn argBytes(self: Delivery, i: usize) ArgError![]const u8 {
        return switch (try self.arg(i)) {
            .bytes => |b| b,
            else => error.WrongArgumentType,
        };
    }

    /// The `string` argument at `i`.
    pub fn argString(self: Delivery, i: usize) ArgError![]const u8 {
        return switch (try self.arg(i)) {
            .string => |s| s,
            else => error.WrongArgumentType,
        };
    }

    /// The `integer` argument at `i`.
    pub fn argInt(self: Delivery, i: usize) ArgError!i64 {
        return switch (try self.arg(i)) {
            .integer => |n| n,
            else => error.WrongArgumentType,
        };
    }

    /// The send shape of this delivery, borrowed for one call. A delivery
    /// built over an owned slice lends that slice as is, so a forward of
    /// owned arguments copies nothing. A delivery over views materializes
    /// them into `allocator`, the one copy a forwarded wire deliver pays when
    /// it leaves the turn the views belong to.
    pub fn toMessage(self: Delivery, allocator: std.mem.Allocator) model.view.Error!Message {
        if (self.args.ownedSlice()) |args| return .{ .verb = self.verb, .args = args };
        return .{ .verb = self.verb, .args = try self.args.toOwnedSlice(allocator) };
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
pub const Queued = union(enum) {
    message: Message,
    owned: OpaqueMessage,

    pub fn retire(self: *Queued, reason: ?[]const u8) void {
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
    handle: *const fn (ctx: *anyopaque, turn: *Turn, msg: Delivery) Result,
    /// Optional adapter-local delivery. Ordinary model handlers never receive
    /// opaque payloads through their data-only contract.
    /// Null means success. Refusal names immutable archive-owned failure text.
    /// Produce the name where the handler's Zig error was caught.
    handleOpaque: ?*const fn (ctx: *anyopaque, turn: *Turn, msg: OpaqueMessage) ?[]const u8 = null,
    /// Release `ctx` when the actor's box drops (vat `deinit`, or a failed
    /// spawn). Null when the consumer keeps ownership of `ctx`.
    free: ?*const fn (ctx: *anyopaque) void = null,
};
