//! The contract a foreign stream provider meets to run on a completion loop.
//!
//! A provider owns its connections, their bytes, and one readiness
//! descriptor per pending dial, listener, or connection. Every verb returns
//! at once: a dial or listen that cannot finish yet hands back an attempt and
//! the descriptor that turns readable when it can, and reads and writes
//! report would-block until the connection's descriptor is ready. The
//! adapter in `completion.zig` waits on those descriptors through its
//! platform backend and never reads or closes them itself.
//!
//! `c_abi/driver/provider_registry/stream_completion.zig` implements this
//! contract over a C `GlowcapStreamTransport` table (ADR-0024).

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const completion = @import("../../completion/loop.zig");
const netlayer = @import("../../netlayer.zig");

/// The durable key of the Host a provider listener serves.
pub const PeerKey = foundation.crypto.PeerKey;

/// A provider-owned handle and the descriptor that reports its readiness.
pub const Handle = struct {
    ptr: *anyopaque,
    fd: i32,
};

/// A dial or listen that has started.
pub const Started = union(enum) {
    /// Finished at once.
    ready: Handle,
    /// Call the matching finish verb once `fd` turns readable.
    pending: Handle,
    failed: anyerror,
};

/// A dial, listen, or accept that has finished.
pub const Finished = union(enum) {
    ready: Handle,
    failed: anyerror,
};

/// Provider implementors are unknown at this declaration, so the listener
/// locator verbs keep `anyerror` return sets.
pub const VTable = struct {
    start_connect: *const fn (ctx: *anyopaque, locator: model.PeerLocator) Started,
    /// Consumes `attempt` on every return.
    finish_connect: *const fn (ctx: *anyopaque, attempt: *anyopaque) Finished,
    cancel_connect: *const fn (ctx: *anyopaque, attempt: *anyopaque) void,
    /// Null when the provider cannot listen. The listener verbs below are then
    /// null too. `identity` is the durable key of the Host the listener
    /// serves, which a key-designated profile publishes.
    listen: ?*const fn (ctx: *anyopaque, designator: []const u8, identity: ?PeerKey) Started = null,
    finish_listen: ?*const fn (ctx: *anyopaque, attempt: *anyopaque) Finished = null,
    cancel_listen: ?*const fn (ctx: *anyopaque, attempt: *anyopaque) void = null,
    /// Called after the listener's descriptor turns readable.
    accept: ?*const fn (ctx: *anyopaque, listener: *anyopaque) Finished = null,
    listener_close: ?*const fn (ctx: *anyopaque, listener: *anyopaque) void = null,
    /// The listener's dialable locator, owned by `allocator`.
    listener_locator: ?*const fn (ctx: *anyopaque, listener: *anyopaque, allocator: std.mem.Allocator) anyerror!model.PeerLocator = null,
    /// Validate a locator the listener may advertise instead, returning its
    /// canonical form owned by `allocator`. Null accepts only the listener's
    /// own transport and designator.
    listener_canonicalize: ?*const fn (ctx: *anyopaque, listener: *anyopaque, allocator: std.mem.Allocator, candidate: model.PeerLocator) anyerror!model.PeerLocator = null,
    /// Query or copy the opaque state that restores the listener's address.
    /// Null means the provider keeps none.
    listener_restoration_state: ?*const fn (ctx: *anyopaque, listener: *anyopaque, out: []u8) netlayer.ListenerRestorationOutcome = null,
    try_read: *const fn (ctx: *anyopaque, conn: *anyopaque, buf: []u8) completion.TryRead,
    try_write: *const fn (ctx: *anyopaque, conn: *anyopaque, bytes: []const u8) completion.TryWrite,
    /// Claim the structured failure behind a refused read or write on
    /// `conn`, once. Null when the provider keeps none.
    conn_take_failure: ?*const fn (ctx: *anyopaque, conn: *anyopaque) ?foundation.FailureChain = null,
    /// Releases `conn` and its descriptor. A teardown failure is the
    /// provider's to record. Nothing waits on it here.
    conn_close: *const fn (ctx: *anyopaque, conn: *anyopaque) void,
};

/// One foreign provider serving one transport symbol.
pub const Provider = struct {
    transport: []const u8,
    ctx: *anyopaque,
    vtable: *const VTable,
};
