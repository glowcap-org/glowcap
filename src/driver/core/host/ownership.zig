//! Host construction, aggregate destruction, and exclusive-owner transfer.
//!
//! The Host root owns the state layout and supported index. This internal leaf
//! owns the one transaction that creates or retires that whole aggregate. It
//! does not add a runtime owner object or widen `driver.core`'s namespace.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const host_mod = @import("../host.zig");
const capability = @import("../capability.zig");
const sessions = @import("../sessions.zig");
const enliven = @import("../enliven.zig");
const capability_promise = @import("../capability_promise.zig");
const action = @import("action.zig");
const admission = @import("admission.zig");
const host_pump = @import("pump.zig");

const Host = host_mod.Host;
const crypto = foundation.crypto;

/// Why an I/O owner cannot adopt this byte-fed Host. Queued actions are
/// transferable. Live sessions and a popped action are not, because their byte
/// channels or borrowed payload already belong to the current driver.
pub const RuntimeAdoptionError = error{
    ReenteredHost,
    HostClosing,
    HostNotQuiescent,
};

/// Validate transfer from a byte-fed driver to an owning runtime. Queued
/// actions transfer. Live sessions and a popped action retain their current
/// byte-channel or borrowed-payload owner.
pub fn checkRuntimeAdoption(self: *const Host) RuntimeAdoptionError!void {
    if (self.in_callback) return error.ReenteredHost;
    if (self.lifecyclePhase() != .active) return error.HostClosing;
    if (self.sessions.count() != 0 or self.last_action != null or self.retry_last_action)
        return error.HostNotQuiescent;
}

/// Construct one sans-I/O Host. The durable identity seed remains stable while
/// the session root is replaced per process so every session key is distinct.
pub fn init(
    allocator: std.mem.Allocator,
    seed: [crypto.SEED_BYTES]u8,
    session_seed_root: [crypto.SEED_BYTES]u8,
    opts: Host.Options,
) Host.InitError!Host {
    if (opts.host_work_quantum == 0)
        return Host.InitError.InvalidHostWorkQuantum;
    return .{
        .allocator = allocator,
        .node = engine.Node.init(allocator, seed),
        .opts = opts,
        .vat = actors.Vat.init(allocator),
        .capabilities = capability.Registry.init(opts.capability_id_issuer),
        .session_seed_root = session_seed_root,
    };
}

/// Convenience destruction for callers that have no teardown recipient.
pub fn deinit(self: *Host) void {
    _ = deinitOutcome(self);
}

/// Tear down every Host-owned authority. Far vows break before session shells
/// retire so listeners and host-owned enliven bridges receive an outcome. The
/// first ingress-retirement refusal is returned only after the complete sweep.
pub fn deinitOutcome(self: *Host) ?anyerror {
    self.assertOwner();
    std.debug.assert(!self.in_callback);
    var first_failure: ?anyerror = null;
    // Break listeners under the callback latch; nested work only enqueues and
    // every resulting queue row is retired later in this same sweep.
    self.in_callback = true;
    var break_it = self.sessions.valueIterator();
    while (break_it.next()) |session| {
        session.*.served.port.breakFarVows(session.*.served.closeReason("host released"));
        _ = self.capabilities.invalidatePeer(session.*.peer_handle);
        @import("../vows/release.zig").dropSessionRows(self, session.*, session.*.served.closeReason("host released"));
    }
    var free_it = self.sessions.valueIterator();
    while (free_it.next()) |session| {
        self.traceClose(session.*);
        // Drop indexes before freeing their borrowed dialed-designator keys.
        sessions.unindexSession(self, session.*);
        sessions.cancelSessionIngress(self, session.*, session.*.served.closeReason("host released")) catch |err| {
            if (first_failure == null) first_failure = err;
        };
        sessions.freeSessionShell(self, session.*);
    }
    // Actor destructors may consume remote retains. They must see an empty,
    // valid session index and release-only capability rows, never freed shells.
    self.sessions.clearRetainingCapacity();
    // Provisional exporter peers can retain local actor roots, so the Node
    // retires while the Vat those projections name is still alive.
    host_pump.deinitParkedNodeActions(self);
    self.node.deinit();
    self.vat.deinit();
    self.sessions.deinit(self.allocator);
    var publications = self.publications.valueIterator();
    while (publications.next()) |row| self.allocator.free(@constCast(row.name));
    self.publications.deinit(self.allocator);
    self.turn_receipts.deinit(self.allocator);
    self.hellos.deinit(self.allocator);
    self.partner_by_side.deinit(self.allocator);
    self.peer_by_durable.deinit(self.allocator);
    self.dialed_by_target.deinit(self.allocator);
    var transport_it = self.transport_profiles.keyIterator();
    while (transport_it.next()) |transport| {
        if (model.transport.parseKnown(transport.*) == null)
            self.allocator.free(@constCast(transport.*));
    }
    self.transport_profiles.deinit(self.allocator);
    if (self.last_action) |last| action.freeStorage(self.allocator, last);
    for (self.actions.unpopped()) |queued| action.freeStorage(self.allocator, queued);
    self.actions.deinit(self.allocator);
    // Far rows retired through the break above; only never-fired local rows
    // remain after the Vats are gone.
    var vow_it = self.vows.valueIterator();
    while (vow_it.next()) |row| {
        if (row.*.owner == .owning) row.*.owner.owning.release();
        if (row.*.forwarded == .owning) row.*.forwarded.owning.producer.release();
        self.allocator.destroy(row.*);
    }
    self.vows.deinit(self.allocator);
    self.resolver_index.deinit(self.allocator);
    enliven.deinitParkedEnlivens(self);
    self.pending_flush.deinit(self.allocator);
    self.held_releases.deinit(self.allocator);
    self.session_close_timing.deinit(self.allocator);
    capability_promise.deinit(self);
    self.capabilities.deinit(self.allocator);
    // Every session key, ephemeral, and wire salt derived from the root.
    std.crypto.secureZero(u8, &self.session_seed_root);
    return first_failure;
}

/// Destroy after an adapter transfers exclusive terminal ownership to this
/// thread. No Host call may remain in flight or begin afterward.
pub fn deinitAfterOwnershipTransfer(self: *Host) ?anyerror {
    std.debug.assert(!self.in_callback);
    if (comptime admission.tracks_thread_affinity) self.owner_tid = admission.initial_owner_thread_id;
    return deinitOutcome(self);
}

/// Validate terminal ownership transfer without claiming the ordinary driving
/// thread. Release is legal only outside a callback window.
pub fn checkReleaseOwnershipTransfer(self: *const Host) error{ReenteredHost}!void {
    if (self.in_callback) return error.ReenteredHost;
}
