//! Peer daemon live state: the loop/inbox shared tables, process-scope
//! outbox offset, and the bridge flush that join and outbox both call.

const std = @import("std");
const signals = @import("../../operability/signals.zig");
const log = @import("../../operability/log.zig");
const common = @import("common.zig");
const harness = @import("harness.zig");
const phase_mod = @import("phase.zig");

const Io = common.Io;
const Allocator = common.Allocator;
const model = common.model;
const actors = common.actors;
const Host = common.Host;
const HostSession = common.HostSession;
const Capability = common.driver.core.Capability;
const RoomsBridge = common.RoomsBridge;
const redial_cooldown_wakes = common.redial_cooldown_wakes;
const writeState = harness.writeState;

// These outlive an iroh-stack rebuild: the supervisor tears the per-attempt
// stack (and its PeerState) down on a fatal loop error and builds a fresh one, so
// the outbox drain offset and the "did we ever join this attempt" signal live at
// process scope.
pub var g_offset: usize = 0;
pub var g_ever_joined: bool = false;

// --- the peer daemon --------------------------------------------------------

/// Everything the loop thread and the inbox actor share. The
/// wire-facing fields are touched only on the loop-owner thread — inside a
/// serve/vow callback or between two `runUntil` returns — so they need no
/// synchronization. The stop latch lives in `operability/signals`; a bounded
/// loop deadline observes it without a helper thread.
pub const PeerState = struct {
    io: Io,
    gpa: Allocator,
    host: *Host,
    bridge: *RoomsBridge,

    dir: []const u8,
    nick: []const u8,
    room_name: []const u8,
    locator_str: []const u8,
    /// This peer's dialable `ocapn://…iroh` URI for directory `register`.
    member_locator: []const u8,
    room_locator: model.PeerLocator,

    /// Room-session lifecycle (`phase.zig`): exactly one arm live at a time,
    /// carrying that arm's payload (session, directory/room refs, countdowns).
    /// The DM tables below stay orthogonal, cleared on wire teardown.
    phase: phase_mod.Phase = .{ .down = .{ .cooldown = 0 } },
    /// Abandoned joins since the last successful subscribe (or stack start):
    /// incremented when `maintain` executes an abandon, reset only after the
    /// subscribe vow fulfills, and written into state.json for the supervisor.
    join_attempts: u32 = 0,

    /// Cached DM caps from `directory.introduce(nick)` (owned refs + keys).
    /// Cleared when the room wire drops — introductions are room-scoped.
    dm_caps: std.StringHashMapUnmanaged(model.Reference) = .{},
    /// ADR-0088 reply back-channels: opaque Host capabilities from an inbound
    /// `dm(text, reply)`. These ride the partner's direct session, not the
    /// room wire, so they survive a room reconnect. Released on process exit
    /// or when a tell finds them dead.
    dm_back: std.StringHashMapUnmanaged(Capability) = .{},
    /// Nicks with an introduce in flight, and how many wakes are left before
    /// the wait is abandoned (owned keys). A directory that accepts
    /// `introduce` and never settles the vow would otherwise hold its entry
    /// for the session's life. The outbox holds that peer's DM lines and still
    /// drains later room posts and sendable DMs. Expiry demotes to the refusal
    /// cooldown rather than retrying at once, so an unresponsive directory is
    /// not hammered.
    pending_introduces: std.StringHashMapUnmanaged(u32) = .{},
    /// Nicks whose introduce broke, and how many wakes to wait before trying
    /// again (owned keys). The outbox holds their DM lines so nothing is
    /// dropped while the cooldown runs; later room posts still send.
    ///
    /// A countdown rather than a verdict: a refusal names something that was
    /// never there, so no object's death can clear it. One event clears it early:
    /// `notify("introducible", peer)` says that peer has now offered us an inbox.
    /// Everything else waits out the clock, because a peer who was
    /// briefly offline must not stay unreachable for the life of a healthy
    /// session.
    failed_introduces: std.StringHashMapUnmanaged(u32) = .{},
    /// The published name of the inbox offered for each peer, by nick. Key and
    /// value are both borrowed from the `DmInboxRow` the host owns, so this map
    /// frees neither. It outlives a room-session teardown because the giftable
    /// does, so a re-registration re-offers that inbox instead of minting a
    /// second one under a name nothing can withdraw.
    ///
    /// Nothing unpublishes a giftable, so each row costs one Host alias and one
    /// actor for the life of the process, plus a lazy export on each Port that
    /// discovers or receives it. The peer asking is the one who chose the nick.
    /// `max_dm_inboxes` bounds the count and `max_nick` the length;
    /// `inboxNameFor` refuses past either.
    dm_inbox_names: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Nicks whose `mintInboxFor` arrived under the host callback latch.
    /// `publishGiftable` and `tell` both refuse `ReenteredHost`, so the offer
    /// cannot run inside `RegInbox.handle`; `maintain` drains this set outside
    /// the latch. Owned keys; cleared with the other room-scoped DM tables.
    pending_inbox_offers: std.StringHashMapUnmanaged(void) = .{},
    /// One Host-vat registration callback, projected canonically onto each
    /// room Port. Registration retries resend this actor instead of minting an
    /// unbounded callback actor every time a directory stays silent.
    reg_inbox_actor: ?actors.Ref = null,

    pub fn stopRequested() bool {
        return signals.stopRequested();
    }

    pub fn writeStateNow(self: *PeerState, status: []const u8) void {
        writeState(self.io, self.gpa, self.dir, status, self.nick, self.room_name, self.locator_str, self.isRegistered(), self.join_attempts);
    }

    /// The live room session, across every phase arm that holds one.
    pub fn phaseSession(self: *const PeerState) ?*HostSession {
        return self.phase.session();
    }

    pub fn isRegistered(self: *const PeerState) bool {
        return self.phase.isRegistered();
    }

    pub fn clearDmTables(self: *PeerState) void {
        var cap_it = self.dm_caps.iterator();
        while (cap_it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            model.freeReference(self.gpa, e.value_ptr.*);
        }
        self.dm_caps.clearRetainingCapacity();
        var pend_it = self.pending_introduces.keyIterator();
        while (pend_it.next()) |k| self.gpa.free(k.*);
        self.pending_introduces.clearRetainingCapacity();
        var fail_it = self.failed_introduces.keyIterator();
        while (fail_it.next()) |k| self.gpa.free(k.*);
        self.failed_introduces.clearRetainingCapacity();
        var offer_it = self.pending_inbox_offers.keyIterator();
        while (offer_it.next()) |k| self.gpa.free(k.*);
        self.pending_inbox_offers.clearRetainingCapacity();
        // dm_back intentionally kept: room wire loss is not partner-session loss.
    }

    pub fn clearBackChannels(self: *PeerState) void {
        var it = self.dm_back.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            _ = self.host.capabilities.release(e.value_ptr.*, 1) catch {};
        }
        self.dm_back.clearRetainingCapacity();
    }

    pub fn clearRoomWire(self: *PeerState) void {
        self.phase = .{ .down = .{ .cooldown = 0 } };
        self.clearDmTables();
    }

    /// Schedule a join-path recovery. Vow callbacks may run under the host latch,
    /// so we only move to `.abandoning` here; `maintain` closes the slot and
    /// redials outside it. No-op in any phase but `.joining`, so a stale
    /// callback after teardown or after a successful join cannot clobber.
    pub fn requestAbandonJoin(self: *PeerState) void {
        if (phase_mod.requestAbandon(&self.phase)) self.writeStateNow("reconnecting");
    }

    pub fn deinitTables(self: *PeerState) void {
        self.clearDmTables();
        self.clearBackChannels();
        self.dm_inbox_names.deinit(self.gpa);
        self.dm_caps.deinit(self.gpa);
        self.dm_back.deinit(self.gpa);
        self.pending_introduces.deinit(self.gpa);
        self.failed_introduces.deinit(self.gpa);
        self.pending_inbox_offers.deinit(self.gpa);
    }
};

pub fn refOf(resolution: actors.Resolution) ?model.Reference {
    return switch (resolution) {
        .fulfilled => |value| if (value == .reference) value.reference else null,
        .broken, .give => null,
    };
}

/// Why `flushBridge` was called — outbox paths fail closed on `ReenteredHost`.
pub const FlushKind = enum {
    post,
    dm,
    host,
    maintain,

    fn label(self: FlushKind) []const u8 {
        return switch (self) {
            .post => "post",
            .dm => "dm",
            .host => "host",
            .maintain => "maintain",
        };
    }

    fn isOutbox(self: FlushKind) bool {
        return self == .post or self == .dm;
    }
};

/// Arm bridge outbound for queued HostActions (flush/close/dial).
///
/// `ReenteredHost` means we are inside a host callback latch: actions stay
/// queued. That is NOT success for outbox posts — `dirtyThenPump` only queues
/// a flush; without a later `drainActions` the bridge never `armOutbound`s and
/// the room never sees the line (the "Bueller" silence). Outbox callers must
/// get `false` and retry; join-path callers may continue and rely on `maintain`
/// always flushing outside the latch.
pub fn flushBridge(state: *PeerState, kind: FlushKind) bool {
    state.bridge.drainActions() catch |err| {
        if (err == error.ReenteredHost) {
            if (kind.isOutbox()) {
                log.err(state.io, "{s} drainActions deferred: ReenteredHost (will retry)", .{kind.label()});
                return false;
            }
            return true;
        }
        log.err(state.io, "{s} drainActions failed: {s}", .{ kind.label(), @errorName(err) });
        return false;
    };
    return true;
}
