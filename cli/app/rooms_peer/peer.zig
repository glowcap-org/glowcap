//! Peer daemon: CapTP/iroh room presence loop for `pancake app rooms-peer`.
const std = @import("std");
const pancake = @import("pancake");
const iroh = @import("iroh");
const rooms_profile = @import("rooms_profile");
const signals = @import("../../operability/signals.zig");
const identity_mod = @import("../../operability/identity.zig");
const log = @import("../../operability/log.zig");
const common = @import("common.zig");
const harness = @import("harness.zig");
const phase_mod = @import("phase.zig");
const Flags = @import("flags.zig").Flags;

const Io = common.Io;
const Allocator = common.Allocator;
const model = common.model;
const actors = common.actors;
const driver = common.driver;
const net = common.net;
const Host = common.Host;
const HostSession = common.HostSession;
const Hosting = driver.core.Hosting;
const HostTurn = driver.core.HostTurn;
const Value = driver.core.Value;
const Capability = driver.core.Capability;
const RoomsBackend = common.RoomsBackend;
const RoomsLoop = common.RoomsLoop;
const RoomsBridge = common.RoomsBridge;
const frame_cap = common.frame_cap;
const timer_ms = common.timer_ms;
const redial_cooldown_wakes = common.redial_cooldown_wakes;
const dial_timeout_ms = common.dial_timeout_ms;
const max_nick = common.max_nick;
const max_dm_inboxes = common.max_dm_inboxes;
const emitStdout = common.emitStdout;
const emitStdoutFmt = common.emitStdoutFmt;

const pathIn = harness.pathIn;
const readFile = harness.readFile;
const overwriteFile = harness.overwriteFile;
const removeFile = harness.removeFile;
const recordInbox = harness.recordInbox;
const writeState = harness.writeState;
const scanInbox = harness.scanInbox;
const markReplied = harness.markReplied;
const compactOutboxRemainder = harness.compactOutboxRemainder;
const lockLeaf = harness.lockLeaf;
const OutboxLine = harness.OutboxLine;
const OutboxLineFate = harness.OutboxLineFate;
const loadOutboxOffset = harness.loadOutboxOffset;
const clampOutboxOffset = harness.clampOutboxOffset;
const advanceInboxWatermark = harness.advanceInboxWatermark;

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
const PeerState = struct {
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
    /// incremented when `maintain` executes an abandon, reset in
    /// `subscribeRoom`, and written into state.json for the supervisor.
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

    fn stopRequested() bool {
        return signals.stopRequested();
    }

    fn writeStateNow(self: *PeerState, status: []const u8) void {
        writeState(self.io, self.gpa, self.dir, status, self.nick, self.room_name, self.locator_str, self.isRegistered(), self.join_attempts);
    }

    /// The live room session, across every phase arm that holds one.
    fn phaseSession(self: *const PeerState) ?*HostSession {
        return self.phase.session();
    }

    fn isRegistered(self: *const PeerState) bool {
        return self.phase.isRegistered();
    }

    fn clearDmTables(self: *PeerState) void {
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

    fn clearBackChannels(self: *PeerState) void {
        var it = self.dm_back.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            _ = self.host.capabilities.release(e.value_ptr.*, 1) catch {};
        }
        self.dm_back.clearRetainingCapacity();
    }

    fn clearRoomWire(self: *PeerState) void {
        self.phase = .{ .down = .{ .cooldown = 0 } };
        self.clearDmTables();
    }

    /// Schedule a join-path recovery. Vow callbacks may run under the host latch,
    /// so we only move to `.abandoning` here; `maintain` closes the slot and
    /// redials outside it. No-op in any phase but `.joining`, so a stale
    /// callback after teardown or after a successful join cannot clobber.
    fn requestAbandonJoin(self: *PeerState) void {
        if (phase_mod.requestAbandon(&self.phase)) self.writeStateNow("reconnecting");
    }

    fn deinitTables(self: *PeerState) void {
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

/// The room calls `notify(from, text, ...)` back on this exported inbox. A
/// presence line carries a string kind at args[2]; a plain chat line does not.
/// We record only chat lines from another member.
const RoomInbox = struct {
    state: *PeerState,

    pub fn handle(self: *RoomInbox, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "notify")) return error.NoSuchMethod;
        const from = if (msg.args.len > 0 and msg.args[0] == .string) msg.args[0].string else "";
        const text = if (msg.args.len > 1 and msg.args[1] == .string) msg.args[1].string else "";
        const is_presence = msg.args.len >= 3 and msg.args[2] == .string;
        if (!is_presence and from.len > 0 and !std.mem.eql(u8, from, "room") and !std.mem.eql(u8, from, self.state.nick)) {
            recordInbox(self.state.io, self.state.gpa, self.state.dir, "msg", "room", from, text, "") catch {};
        }
        return .{ .void = {} };
    }
};

/// One peer's inbox: partners call `dm(text, reply?)` after redeeming an
/// introduce. `peer` is the nick the directory minted this inbox for, which is
/// why the message need not name its sender. When `reply` is present it is the
/// ADR-0088 back-channel: answer on that capability (same arriving connection)
/// instead of introducing the partner, so a browser that never listens still
/// gets our DMs. Value-shaped (`Hosting`) so the reply lifts to an opaque Host
/// capability rather than a turn-local wire import.
const DmInbox = struct {
    state: *PeerState,
    peer: []const u8,
    swiss: []const u8,

    pub fn handle(self: *DmInbox, ht: *HostTurn, verb: []const u8, args: []const Value) !Value {
        _ = ht;
        if (!std.mem.eql(u8, verb, "dm")) return error.NoSuchMethod;
        const text = if (args.len > 0 and args[0] == .string) args[0].string else "";
        if (args.len > 1 and args[1] == .capability) {
            rememberDmBack(self.state, self.peer, args[1].capability);
        }
        if (text.len > 0) {
            recordInbox(self.state.io, self.state.gpa, self.state.dir, "msg", "dm", self.peer, text, self.peer) catch {};
        }
        return .void;
    }

    pub fn deinit(self: *DmInbox, _: std.mem.Allocator) void {
        self.state.gpa.free(self.peer);
        self.state.gpa.free(self.swiss);
    }
};

/// The name of the inbox published for `peer`, minting and registering one the
/// first time; null only if the host refused the registration. The name is
/// unguessable because a guessable one would let anyone fetch the inbox by name
/// on a connection they opened themselves.
fn inboxNameFor(state: *PeerState, peer: []const u8) ?[]const u8 {
    if (state.dm_inbox_names.get(peer)) |name| return name;
    if (peer.len > max_nick) {
        log.err(state.io, "refusing a dm inbox for a nick over {d} bytes", .{max_nick});
        return null;
    }
    if (state.dm_inbox_names.count() >= max_dm_inboxes) {
        log.err(state.io, "already holding {d} dm inboxes; refusing one for \"{s}\"", .{ max_dm_inboxes, peer });
        return null;
    }

    var raw: [16]u8 = undefined;
    state.io.randomSecure(&raw) catch return null;
    const swiss = std.fmt.allocPrint(state.gpa, "dm-{s}-{s}", .{ peer, std.fmt.bytesToHex(raw, .lower) }) catch return null;
    const owned_peer = state.gpa.dupe(u8, peer) catch {
        state.gpa.free(swiss);
        return null;
    };
    // The map borrows the actor-owned bytes; the actor and publication live for
    // the Host's life.
    state.dm_inbox_names.put(state.gpa, owned_peer, swiss) catch {
        state.gpa.free(owned_peer);
        state.gpa.free(swiss);
        return null;
    };
    _ = state.host.publishGiftable(swiss, Hosting(DmInbox), .{ .inner = .{ .state = state, .peer = owned_peer, .swiss = swiss } }) catch |err| {
        log.err(state.io, "publishing a dm inbox for \"{s}\" failed: {s}", .{ peer, @errorName(err) });
        std.debug.assert(state.dm_inbox_names.remove(owned_peer));
        // `publishGiftable` consumes the behavior state on every outcome;
        // DmInbox.deinit owns both allocations after the call begins.
        return null;
    };
    return swiss;
}

/// Cache `reply` as the outbound DM back-channel to `peer` (ADR-0088).
/// A live route is not displaced — a second inbound while the first still works
/// must not drop the working cap (release the new lift instead). Clears any
/// introduce-failure cooldown so the outbox can drain immediately.
fn rememberDmBack(state: *PeerState, peer: []const u8, reply: Capability) void {
    if (state.dm_back.getPtr(peer)) |held| {
        if (state.host.capabilities.resolve(held.*) != null) {
            _ = state.host.capabilities.release(reply, 1) catch {};
            if (state.failed_introduces.fetchRemove(peer)) |kv| state.gpa.free(kv.key);
            return;
        }
        _ = state.host.capabilities.release(held.*, 1) catch {};
        held.* = reply;
        if (state.failed_introduces.fetchRemove(peer)) |kv| state.gpa.free(kv.key);
        return;
    }
    const key = state.gpa.dupe(u8, peer) catch {
        _ = state.host.capabilities.release(reply, 1) catch {};
        return;
    };
    state.dm_back.put(state.gpa, key, reply) catch {
        state.gpa.free(key);
        _ = state.host.capabilities.release(reply, 1) catch {};
        return;
    };
    if (state.failed_introduces.fetchRemove(peer)) |kv| state.gpa.free(kv.key);
}

/// Queue a directory inbox offer for `peer`. Safe under the host callback
/// latch: `publishGiftable` and `tell` refuse `ReenteredHost`, so the real
/// work runs from `drainPendingInboxOffers` in `maintain`.
fn scheduleInboxOffer(state: *PeerState, peer: []const u8) void {
    if (peer.len > max_nick) return;
    phase_mod.schedulePendingOffer(state.gpa, &state.pending_inbox_offers, peer, max_dm_inboxes);
}

/// Offer the directory an inbox for `peer`, the answer to its `mintInboxFor`.
///
/// Call only outside the host callback latch. This uses `tell`, so nothing
/// waits on an answer the directory does not send. A refusal is therefore
/// invisible here, and the cost of one is that the peer stays unreachable
/// until the directory asks again. It does ask again on their next `introduce`,
/// since it only asks when it has no inbox filed. Returns whether the offer was
/// admitted to the Host.
fn offerInboxFor(state: *PeerState, peer: []const u8) bool {
    if (state.phase != .joined) return false;
    const session = state.phase.joined.session;
    const directory = state.phase.joined.directory;
    const swiss = inboxNameFor(state, peer) orelse return false;
    const position = state.host.publishedPosition(session, swiss) catch |err| {
        log.err(state.io, "reading the dm inbox position failed: {s}", .{@errorName(err)});
        return false;
    } orelse {
        log.err(state.io, "the dm inbox for \"{s}\" holds no position on the room session", .{peer});
        return false;
    };
    state.host.tell(session, directory, .{
        .verb = "offerInbox",
        .args = &.{
            .{ .string = peer },
            .{ .reference = .{ .near = model.NearRef.object(position) } },
        },
    }) catch |err| {
        log.err(state.io, "offerInbox for \"{s}\" failed: {s}", .{ peer, @errorName(err) });
        return false;
    };
    _ = flushBridge(state, .host);
    return true;
}

/// Drain `pending_inbox_offers` outside the callback latch. Keeps a nick until
/// `offerInboxFor` succeeds so a transient tell failure retries next wake.
fn drainPendingInboxOffers(state: *PeerState) void {
    phase_mod.drainPendingOffers(state.gpa, &state.pending_inbox_offers, state, offerInboxFor);
}

/// The directory's channel to this member: `notify("registered", nick)` once the
/// name is granted, `notify("mintInboxFor", peer)` when someone wants to reach us
/// and has no inbox yet, and `notify("introducible", peer)` when a peer we were
/// refused has offered us one.
const RegInbox = struct {
    state: *PeerState,

    pub fn handle(self: *RegInbox, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "notify")) return error.NoSuchMethod;
        const kind = if (msg.args.len > 0 and msg.args[0] == .string) msg.args[0].string else "";
        const peer = if (msg.args.len > 1 and msg.args[1] == .string) msg.args[1].string else "";
        if (std.mem.eql(u8, kind, "registered")) {
            // Outside `.joined` this no-ops: a late notify after teardown must
            // not write status "joined" with the wire down.
            if (phase_mod.noteRegistered(&self.state.phase)) {
                self.state.writeStateNow("joined");
            }
        } else if (std.mem.eql(u8, kind, "mintInboxFor") and peer.len > 0) {
            // Queue only: publishGiftable/tell refuse ReenteredHost under this latch.
            scheduleInboxOffer(self.state, peer);
        } else if (std.mem.eql(u8, kind, "introducible") and peer.len > 0) {
            // Our introduce to them was refused because they had minted us no
            // inbox; they have now. Drop the refusal cooldown so the next wake
            // retries rather than waiting it out.
            if (self.state.failed_introduces.fetchRemove(peer)) |kv| self.state.gpa.free(kv.key);
        }
        return .{ .void = {} };
    }
};

fn refOf(resolution: actors.Resolution) ?model.Reference {
    return switch (resolution) {
        .fulfilled => |value| if (value == .reference) value.reference else null,
        .broken, .give => null,
    };
}

/// Bridge `on_open`: a session opened. Only the app-dial leg while we are
/// `.dialing` is the room session — accepted DM partners and redeem legs open
/// through here too and must not fetch "directory" or touch the phase. Fetch
/// the directory; the enter/open/subscribe chain runs from the settle
/// callbacks.
fn onOpen(ctx: ?*anyopaque, bridge: *RoomsBridge, slot: *RoomsBridge.Slot) anyerror!void {
    _ = bridge;
    const state: *PeerState = @ptrCast(@alignCast(ctx.?));
    if (state.phase != .dialing or slot.leg != .app_dial) return;
    state.phase = .{ .joining = .{ .session = slot.session } };
    state.writeStateNow("joining");
    const vow = state.host.fetch(slot.session, "directory") catch |err| {
        log.err(state.io, "directory fetch failed: {s}", .{@errorName(err)});
        state.requestAbandonJoin();
        return;
    };
    state.host.vowOn(vow, .{ .ctx = state, .func = onDirectory }) catch |err| {
        log.err(state.io, "directory vowOn failed: {s}", .{@errorName(err)});
        state.requestAbandonJoin();
        return;
    };
}

fn onDirectory(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *PeerState = @ptrCast(@alignCast(ctx.?));
    if (state.phase != .joining) return;
    const directory = refOf(resolution) orelse {
        log.err(state.io, "directory fetch did not fulfill", .{});
        state.requestAbandonJoin();
        return;
    };
    state.phase.joining.directory = directory;
    // The wire stays strict: `enter` breaks if the room is absent, `open` breaks
    // if the name is taken. Try enter, fall back to open, then enter once more on
    // a creation race — the same leniency the blocking client applies.
    sendDirectoryVerb(state, "enter", onEntered);
}

fn onEntered(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *PeerState = @ptrCast(@alignCast(ctx.?));
    if (state.phase != .joining) return;
    if (refOf(resolution)) |room| {
        subscribeRoom(state, room);
    } else {
        sendDirectoryVerb(state, "open", onOpened);
    }
}

fn onOpened(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *PeerState = @ptrCast(@alignCast(ctx.?));
    if (state.phase != .joining) return;
    if (refOf(resolution)) |room| {
        subscribeRoom(state, room);
    } else {
        sendDirectoryVerb(state, "enter", onEnteredAgain);
    }
}

fn onEnteredAgain(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *PeerState = @ptrCast(@alignCast(ctx.?));
    if (state.phase != .joining) return;
    if (refOf(resolution)) |room| {
        subscribeRoom(state, room);
    } else {
        log.err(state.io, "could not enter or open room \"{s}\"", .{state.room_name});
        state.requestAbandonJoin();
    }
}

/// Eventual-send a directory verb naming the room, and wait on its answer.
fn sendDirectoryVerb(state: *PeerState, verb: []const u8, cb: *const fn (?*anyopaque, actors.Resolution) void) void {
    if (state.phase != .joining) return;
    const joining = state.phase.joining;
    const directory = joining.directory orelse return;
    const session = joining.session;
    const vow = state.host.send(session, directory, .{
        .verb = verb,
        .args = &.{.{ .string = state.room_name }},
    }) catch |err| {
        log.err(state.io, "{s} send failed: {s}", .{ verb, @errorName(err) });
        state.requestAbandonJoin();
        return;
    };
    state.host.vowOn(vow, .{ .ctx = state, .func = cb }) catch |err| {
        log.err(state.io, "{s} vowOn failed: {s}", .{ verb, @errorName(err) });
        state.requestAbandonJoin();
        return;
    };
    _ = flushBridge(state, .host);
}

/// Spawn our room inbox, hand it to the room in `subscribe`, register for
/// introductions, and mark joined.
fn subscribeRoom(state: *PeerState, room: model.Reference) void {
    if (state.phase != .joining) return;
    const joining = state.phase.joining;
    const session = joining.session;
    // The chain guarantees a directory (onDirectory set it before any verb
    // could settle); fail toward a redial rather than crash if that breaks.
    const directory = joining.directory orelse {
        state.requestAbandonJoin();
        return;
    };
    const inbox = session.served.spawn(&session.host.vat, RoomInbox, .{ .state = state }) catch |err| {
        log.err(state.io, "inbox spawn failed: {s}", .{@errorName(err)});
        state.requestAbandonJoin();
        return;
    };
    _ = state.host.send(session, room, .{
        .verb = "subscribe",
        .args = &.{ .{ .string = state.nick }, inbox.arg() },
    }) catch |err| {
        log.err(state.io, "subscribe failed: {s}", .{@errorName(err)});
        state.requestAbandonJoin();
        return;
    };
    _ = flushBridge(state, .host);
    state.phase = .{ .joined = .{
        .session = session,
        .directory = directory,
        .room = room,
        .reg = .{ .pending = redial_cooldown_wakes },
    } };
    state.join_attempts = 0;
    g_ever_joined = true;
    state.writeStateNow("joined");
    registerWithDirectory(state);
}

/// Offer this peer for introduce: directory fetches `dm` on this session, then
/// `notify("registered", …)` on our register inbox.
fn registerWithDirectory(state: *PeerState) void {
    if (state.phase != .joined) return;
    const joined = state.phase.joined;
    if (joined.reg != .pending or state.member_locator.len == 0) return;
    const session = joined.session;
    const directory = joined.directory;
    const actor = state.reg_inbox_actor orelse actor: {
        const fresh = state.host.vat.spawn(RegInbox, .{ .state = state }) catch |err| {
            log.err(state.io, "register inbox spawn failed: {s}", .{@errorName(err)});
            return;
        };
        state.reg_inbox_actor = fresh;
        break :actor fresh;
    };
    const inbox = session.served.port.projectActor(&state.host.vat, actor) catch |err| {
        log.err(state.io, "register inbox projection failed: {s}", .{@errorName(err)});
        return;
    };
    _ = state.host.send(session, directory, .{
        .verb = "register",
        .args = &.{
            .{ .string = state.nick },
            .{ .string = state.member_locator },
            .{ .reference = .{ .near = inbox } },
        },
    }) catch |err| {
        log.err(state.io, "register failed: {s}", .{@errorName(err)});
        return;
    };
    _ = flushBridge(state, .host);
}

/// Loop `on_close`: bridge refuse handling, then clear room wire state only when
/// the room session itself drops (accepted DM redeem sessions must not tear
/// presence down).
fn onClose(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, report: net.completion.CloseReport) void {
    const bridge: *RoomsBridge = @ptrCast(@alignCast(ctx.?));
    const pending_app_dial = conn_ctx == null and bridge.pendingAppDial(slot);
    RoomsBridge.onClose(ctx, slot, conn_ctx, report);
    const state: *PeerState = @ptrCast(@alignCast(bridge.on_open_ctx.?));
    if (conn_ctx) |raw| {
        const shell: *RoomsBridge.Slot = @ptrCast(@alignCast(raw));
        if (state.phaseSession()) |room_session| {
            // `.abandoning` is covered too: a remote close racing the abandon
            // tick lands `.down` cleanly instead of stranding the phase.
            if (shell.session == room_session) state.clearRoomWire();
            return;
        }
        // App-dial leg torn down before session open (handshake never
        // completed): the dial is dead, so carry the countdown into `.down`
        // exactly like a refused connect.
        if (shell.leg == .app_dial) phase_mod.connectRefused(&state.phase);
        return;
    }
    // Refused connect (no shell was ever built): resume redial pacing with the
    // countdown carried, `.dialing{cd}` becoming `.down{cd}`.
    if (!report.opened or pending_app_dial) phase_mod.connectRefused(&state.phase);
}

// --- outbox -----------------------------------------------------------------

const IntroCtx = struct {
    state: *PeerState,
    peer: []u8,
};

fn onIntroduced(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const ic: *IntroCtx = @ptrCast(@alignCast(ctx.?));
    const state = ic.state;
    const peer = ic.peer;
    defer {
        state.gpa.free(peer);
        state.gpa.destroy(ic);
    }
    // Room wire may have been cleared while introduce was in flight.
    if (state.phase != .joined) return;
    if (state.pending_introduces.fetchRemove(peer)) |kv| state.gpa.free(kv.key);
    if (refOf(resolution)) |dm| {
        const cloned = model.cloneReference(state.gpa, dm) catch {
            log.err(state.io, "introduce \"{s}\": clone failed", .{peer});
            rememberFailedIntroduce(state, peer);
            return;
        };
        const key = state.gpa.dupe(u8, peer) catch {
            model.freeReference(state.gpa, cloned);
            rememberFailedIntroduce(state, peer);
            return;
        };
        if (state.dm_caps.fetchRemove(key)) |old| {
            state.gpa.free(old.key);
            model.freeReference(state.gpa, old.value);
        }
        state.dm_caps.put(state.gpa, key, cloned) catch {
            state.gpa.free(key);
            model.freeReference(state.gpa, cloned);
            rememberFailedIntroduce(state, peer);
        };
        return;
    }
    // Host-tier vows should auto-redeem gives before the listener fires; name
    // the settle arm so a redeem miss is distinguishable from a directory refuse.
    switch (resolution) {
        .fulfilled => |value| log.err(state.io, "introduce \"{s}\" broke: fulfilled non-ref ({s})", .{ peer, @tagName(value) }),
        .broken => |reason| log.err(state.io, "introduce \"{s}\" broke: {s}", .{ peer, reason }),
        .give => |g| log.err(state.io, "introduce \"{s}\" settled as unredeemed give (exporter={s})", .{ peer, g.exporter_locator_uri }),
    }
    rememberFailedIntroduce(state, peer);
}

fn rememberFailedIntroduce(state: *PeerState, peer: []const u8) void {
    if (state.failed_introduces.getPtr(peer)) |cooldown| {
        cooldown.* = redial_cooldown_wakes;
        return;
    }
    const key = state.gpa.dupe(u8, peer) catch return;
    state.failed_introduces.put(state.gpa, key, redial_cooldown_wakes) catch state.gpa.free(key);
}

/// How many wakes an unsettled `introduce` is waited on before the peer is
/// moved to the refusal cooldown. A directory that answers at all answers
/// within a wake or two; one that never answers must not pin the outbox.
const introduce_wait_wakes: u32 = 13;

/// Age every refusal, and forget the ones whose wait is over. Called once per
/// maintained wake, before the outbox drain reads them, so a peer who has come
/// back is retried on the same wake rather than the next one.
fn tickFailedIntroduces(state: *PeerState) void {
    _ = phase_mod.expireCooldowns(state.gpa, &state.failed_introduces);
}

/// Age every in-flight introduce, and give up on the ones whose wait is over.
/// A settle that arrives later finds no pending row and is ignored, which is
/// the same thing that happens when the room wire is cleared under it.
fn tickPendingIntroduces(state: *PeerState) void {
    var expired: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = state.pending_introduces.iterator();
    while (it.next()) |entry| {
        if (!phase_mod.tickCooldown(entry.value_ptr)) continue;
        if (n == expired.len) break;
        expired[n] = entry.key_ptr.*;
        n += 1;
    }
    for (expired[0..n]) |key| {
        log.err(state.io, "introduce \"{s}\" never settled", .{key});
        if (state.pending_introduces.fetchRemove(key)) |old| {
            rememberFailedIntroduce(state, old.key);
            state.gpa.free(old.key);
        }
    }
}

fn startIntroduce(state: *PeerState, peer: []const u8) void {
    if (state.phase != .joined) return;
    if (state.pending_introduces.contains(peer) or state.failed_introduces.contains(peer)) return;
    const directory = state.phase.joined.directory;
    const session = state.phase.joined.session;
    // Map key and IntroCtx peer are separate owned copies so clearRoomWire can
    // free the map without racing the settle callback's free of ic.peer.
    const map_key = state.gpa.dupe(u8, peer) catch return;
    const ctx_peer = state.gpa.dupe(u8, peer) catch {
        state.gpa.free(map_key);
        return;
    };
    state.pending_introduces.put(state.gpa, map_key, introduce_wait_wakes) catch {
        state.gpa.free(map_key);
        state.gpa.free(ctx_peer);
        return;
    };
    const ic = state.gpa.create(IntroCtx) catch {
        if (state.pending_introduces.fetchRemove(peer)) |kv| state.gpa.free(kv.key);
        state.gpa.free(ctx_peer);
        return;
    };
    ic.* = .{ .state = state, .peer = ctx_peer };
    const vow = state.host.send(session, directory, .{
        .verb = "introduce",
        .args = &.{.{ .string = peer }},
    }) catch |err| {
        log.err(state.io, "introduce send failed: {s}", .{@errorName(err)});
        if (state.pending_introduces.fetchRemove(peer)) |kv| state.gpa.free(kv.key);
        state.gpa.free(ctx_peer);
        state.gpa.destroy(ic);
        return;
    };
    state.host.vowOn(vow, .{ .ctx = ic, .func = onIntroduced }) catch |err| {
        log.err(state.io, "introduce vowOn failed: {s}", .{@errorName(err)});
        if (state.pending_introduces.fetchRemove(peer)) |kv| state.gpa.free(kv.key);
        state.gpa.free(ctx_peer);
        state.gpa.destroy(ic);
        return;
    };
    _ = flushBridge(state, .host);
}

fn evictDmCap(state: *PeerState, peer: []const u8) void {
    if (state.dm_caps.fetchRemove(peer)) |kv| {
        state.gpa.free(kv.key);
        model.freeReference(state.gpa, kv.value);
    }
}

fn evictDmBack(state: *PeerState, peer: []const u8) void {
    if (state.dm_back.fetchRemove(peer)) |kv| {
        state.gpa.free(kv.key);
        _ = state.host.capabilities.release(kv.value, 1) catch {};
    }
}

/// Drain outbox lines past `g_offset`. A blocked DM is held in the remainder
/// so it is not dropped; later room posts and sendable DMs still send. Fail
/// closed: a line leaves the remainder only after tell + drainActions both
/// succeed. A failed post keeps that line and everything after it.
fn drainOutbox(state: *PeerState) void {
    if (state.phase != .joined) return;
    const room = state.phase.joined.room;
    const session = state.phase.joined.session;
    const lock = lockLeaf(state.io, state.dir, "outbox.jsonl") catch return;
    defer lock.unlock();
    const contents = readFile(state.io, state.gpa, state.dir, "outbox.jsonl") catch return;
    defer state.gpa.free(contents);
    g_offset = clampOutboxOffset(g_offset, contents.len);
    if (contents.len <= g_offset) return;

    const remainder = contents[g_offset..];
    const Drain = struct {
        state: *PeerState,
        session: *HostSession,
        room: model.Reference,

        fn decide(self: @This(), parsed: OutboxLine) OutboxLineFate {
            if (parsed.is_dm) return dmOutboxFate(self.state, self.session, parsed);
            return roomOutboxFate(self.state, self.session, self.room, parsed);
        }
    };
    const kept = compactOutboxRemainder(
        state.gpa,
        remainder,
        Drain{ .state = state, .session = session, .room = room },
        Drain.decide,
    ) catch return;
    defer state.gpa.free(kept);
    if (std.mem.eql(u8, kept, remainder)) return;

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(state.gpa);
    list.appendSlice(state.gpa, contents[0..g_offset]) catch return;
    list.appendSlice(state.gpa, kept) catch return;
    overwriteFile(state.io, state.dir, "outbox.jsonl", list.items) catch {
        log.err(state.io, "outbox compact write failed; holding remainder", .{});
    };
}

fn dmOutboxFate(state: *PeerState, session: *HostSession, parsed: OutboxLine) OutboxLineFate {
    if (parsed.peer.len == 0) {
        log.err(state.io, "dm outbox line missing peer", .{});
        return .drop;
    }
    const msg: actors.Message = .{
        .verb = "dm",
        .args = &.{.{ .string = parsed.text }},
    };
    // Prefer ADR-0088 back-channel, then introduce result, over the
    // introduce-failure cooldown: a live route must not sit blocked
    // behind a stale refuse. The reply cap lives on the partner's
    // direct session — tellCapability routes there. Lowering it onto
    // the room session is UnknownCapability.
    if (state.dm_back.get(parsed.peer)) |back| {
        if (state.host.tellCapability(session, back, msg)) |_| {
            if (!flushBridge(state, .dm)) return .stop;
            recordInbox(state.io, state.gpa, state.dir, "sent", "dm", state.nick, parsed.text, parsed.peer) catch {};
            return .drop;
        } else |err| {
            log.err(state.io, "dm back-channel tell failed: {s}", .{@errorName(err)});
            evictDmBack(state, parsed.peer);
        }
    }
    if (state.dm_caps.get(parsed.peer)) |dm| {
        if (state.host.tell(session, dm, msg)) |_| {
            if (!flushBridge(state, .dm)) return .stop;
            recordInbox(state.io, state.gpa, state.dir, "sent", "dm", state.nick, parsed.text, parsed.peer) catch {};
            return .drop;
        } else |err| {
            log.err(state.io, "dm tell failed: {s}", .{@errorName(err)});
            evictDmCap(state, parsed.peer);
        }
    }
    if (state.failed_introduces.contains(parsed.peer) or state.pending_introduces.contains(parsed.peer)) {
        return .hold;
    }
    startIntroduce(state, parsed.peer);
    return .hold;
}

fn roomOutboxFate(state: *PeerState, session: *HostSession, room: model.Reference, parsed: OutboxLine) OutboxLineFate {
    state.host.tell(session, room, .{ .verb = "post", .args = &.{.{ .string = parsed.text }} }) catch |err| {
        log.err(state.io, "post failed: {s}", .{@errorName(err)});
        return .stop;
    };
    if (!flushBridge(state, .post)) return .stop;
    recordInbox(state.io, state.gpa, state.dir, "sent", "room", state.nick, parsed.text, "") catch {};
    return .drop;
}

/// Why `flushBridge` was called — outbox paths fail closed on `ReenteredHost`.
const FlushKind = enum {
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
fn flushBridge(state: *PeerState, kind: FlushKind) bool {
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

// --- loop maintenance -------------------------------------------------------

fn maintain(state: *PeerState) void {
    switch (state.phase) {
        // Join failed under a live session: close the slot so we are not stuck
        // open-but-unjoined with no redial. This arm clears PeerState before
        // any deferred onClose lands, so a late close finds `.down` and no-ops
        // instead of racing a half-cleared state. The redial then waits out
        // the ordinary cooldown: a room that keeps refusing the join backs off
        // like a down room, it does not become a per-tick dial storm.
        .abandoning => |session| {
            state.bridge.closeConn(session.peer_id);
            state.clearRoomWire();
            state.phase = .{ .down = .{ .cooldown = redial_cooldown_wakes } };
            state.join_attempts += 1;
        },
        // Back off between redials so a down room is retried steadily, not
        // thrashed every wake tick.
        .down => |*down| {
            if (!phase_mod.tickCooldown(&down.cooldown)) return;
            if (PeerState.stopRequested()) return;
            state.bridge.dialOutboundReserved(state.room_locator) catch |err| {
                log.err(state.io, "redial failed: {s}", .{@errorName(err)});
                state.writeStateNow("reconnecting");
                state.phase = .{ .down = .{ .cooldown = redial_cooldown_wakes } };
                return;
            };
            state.writeStateNow("reconnecting");
            state.phase = .{ .dialing = .{ .cooldown = redial_cooldown_wakes } };
        },
        // Connect in flight: keep the countdown running so a refused connect
        // resumes pacing in `.down` (onClose carries it over). Direct legs
        // share this completion loop and need no second pump.
        .dialing => |*dialing| {
            _ = phase_mod.tickCooldown(&dialing.cooldown);
        },
        .joining => |*joining| {
            if (phase_mod.joinDeadlineFires(joining, common.join_deadline_wakes)) {
                log.err(state.io, "join did not complete within the deadline; abandoning", .{});
                state.requestAbandonJoin();
                return;
            }
            // Always flush outside the callback latch so join-path
            // ReenteredHost deferrals (subscribe/register) still armOutbound.
            _ = flushBridge(state, .maintain);
        },
        .joined => |*joined| {
            switch (joined.reg) {
                .pending => |*cooldown| {
                    if (phase_mod.tickCooldown(cooldown)) {
                        registerWithDirectory(state);
                        // Re-arm the retry countdown; the phase cannot have
                        // left `.joined` inside registerWithDirectory, but
                        // re-check rather than write through a stale capture.
                        if (state.phase == .joined and state.phase.joined.reg == .pending) {
                            state.phase.joined.reg = .{ .pending = redial_cooldown_wakes };
                        }
                    }
                },
                .registered => {},
            }
            tickPendingIntroduces(state);
            tickFailedIntroduces(state);
            drainPendingInboxOffers(state);
            drainOutbox(state);
            _ = flushBridge(state, .maintain);
        },
    }
}

/// Sleep up to `total_ms`, waking promptly on a stop. A `Threaded` sleep
/// swallows the SIGTERM `EINTR` and re-waits, so one long sleep is signal-deaf;
/// chunking it at the tick cadence lets the supervisor observe the shared stop
/// latch during a reconnect backoff instead of parking past `stop`'s SIGTERM grace.
fn sleepUntilStop(io: Io, total_ms: i64) void {
    var slept: i64 = 0;
    while (slept < total_ms and !PeerState.stopRequested()) {
        const chunk = @min(@as(i64, @intCast(timer_ms)), total_ms - slept);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(chunk), .real) catch {};
        slept += chunk;
    }
}

// --- peer daemon entry ------------------------------------------------------

/// Treat current inbox scrollback as already answered without stuffing
/// replied.json (which caps and can resurface ancient ids after restart).
fn seedRepliedBacklog(io: Io, gpa: Allocator, dir: []const u8, nick: []const u8) void {
    _ = nick;
    advanceInboxWatermark(io, gpa, dir);
}

pub fn runPeer(init: std.process.Init, flags: Flags) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (init.environ_map.get("ROOMS_PEER_SUPERVISED") == null) {
        log.err(io, "`peer` is the internal daemon — start it with: pancake app rooms-peer start --dir <DIR> --nick <NICK>", .{});
        return error.Unsupervised;
    }
    if (flags.dir.len == 0 or flags.nick.len == 0 or flags.locator.len == 0) return error.MissingFlags;

    // Detach into our own session so a reaped launcher shell cannot SIGHUP us.
    _ = std.os.linux.setsid();
    signals.install();

    Io.Dir.cwd().createDirPath(io, flags.dir) catch {};
    var pid_buf: [24]u8 = undefined;
    const pid_text = std.fmt.bufPrint(&pid_buf, "{d}\n", .{std.os.linux.getpid()}) catch "0\n";
    overwriteFile(io, flags.dir, "peer.pid", pid_text) catch {};
    // Mark the existing scrollback answered once, so a restart never re-answers
    // lines from before we joined.
    seedRepliedBacklog(io, gpa, flags.dir, flags.nick);

    // Honor the persisted already-sent mark; the drain compacts only past it.
    // Never seed to EOF: that skipped undrained lines written while the peer
    // was down or wedged before tell.
    const outbox_bytes = readFile(io, gpa, flags.dir, "outbox.jsonl") catch try gpa.dupe(u8, "");
    defer gpa.free(outbox_bytes);
    g_offset = clampOutboxOffset(loadOutboxOffset(io, gpa, flags.dir), outbox_bytes.len);

    // Supervisor. Keep a functional iroh stack up until a stop signal. A
    // connection drop is recovered inside runStack (maintain redials in place); a
    // fatal loop error — the endpoint or backend itself failing — returns out of
    // runStack, and we build a fresh stack and reconnect. Each rebuild re-resolves
    // an `http(s)://…/locator` bootstrap so a reminted room node id is followed
    // instead of hammering a dead `ocapn://`. Back off when the environment stays
    // broken, and snap back to a fast retry once a stack has actually joined.
    // Only a stop signal ends the daemon.
    var backoff_ms: i64 = 500;
    defer signals.requestStop();
    while (!PeerState.stopRequested()) {
        g_ever_joined = false;
        const dial_target = common.resolveLocator(io, gpa, flags.locator) catch |err| {
            log.err(io, "locator resolve failed: {s}; retrying", .{@errorName(err)});
            writeState(io, gpa, flags.dir, "reconnecting", flags.nick, flags.room, flags.locator, false, 0);
            sleepUntilStop(io, backoff_ms);
            backoff_ms = @min(backoff_ms * 2, 30_000);
            continue;
        };
        defer gpa.free(dial_target);
        const loc = model.uri.parsePeer(gpa, dial_target) catch |err| {
            log.err(io, "locator parse failed: {s}; retrying", .{@errorName(err)});
            writeState(io, gpa, flags.dir, "reconnecting", flags.nick, flags.room, flags.locator, false, 0);
            sleepUntilStop(io, backoff_ms);
            backoff_ms = @min(backoff_ms * 2, 30_000);
            continue;
        };
        defer model.freePeerLocator(gpa, loc);
        if (!std.mem.eql(u8, loc.transport, model.transport.iroh)) {
            log.err(io, "locator is not iroh; refusing", .{});
            return error.NotIroh;
        }
        const hint = net.netlayer.directAddrHint(loc.hints) orelse "";
        const reachability: iroh.Reachability = if (hint.len > 0) .direct else .discovery;
        const rendezvous_url = common.resolveRendezvousUrl(io, gpa, init.environ_map.get("PANCAKE_RENDEZVOUS"), flags.locator) catch |err| {
            log.err(io, "rendezvous URL refused: {s}", .{@errorName(err)});
            return err;
        };
        defer if (rendezvous_url) |u| gpa.free(u);
        runStack(io, gpa, flags, loc, reachability, dial_target, rendezvous_url) catch |err| {
            log.err(io, "iroh stack failed: {s}; rebuilding", .{@errorName(err)});
        };
        if (PeerState.stopRequested()) break;
        writeState(io, gpa, flags.dir, "reconnecting", flags.nick, flags.room, dial_target, false, 0);
        sleepUntilStop(io, backoff_ms);
        backoff_ms = if (g_ever_joined) 500 else @min(backoff_ms * 2, 30_000);
    }

    writeState(io, gpa, flags.dir, "closed", flags.nick, flags.room, flags.locator, false, 0);
    removeFile(io, flags.dir, "peer.pid");
}

/// Resolve the CapTP Host seed: `--identity PATH`, else `DIR/identity` (minted
/// if missing), so presence is stable across restart under the same harness dir.
fn hostSeed(io: Io, dir: []const u8, identity_flag: []const u8) ![32]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path: []const u8 = if (identity_flag.len > 0)
        identity_flag
    else
        try std.fmt.bufPrint(&path_buf, "{s}/identity", .{dir});
    const secret = try identity_mod.loadOrMint(io, path);
    return secret.seed();
}

/// Wait until the endpoint reports at least one direct address (Direct posture
/// register URIs need them), or until `budget_ms` elapses.
fn waitDirectAddrs(io: Io, resident: *iroh.Resident, out: []u8, budget_ms: i64) []const u8 {
    var slept: i64 = 0;
    while (slept <= budget_ms) {
        if (resident.directAddrs(out)) |addrs| {
            if (addrs.len > 0) return addrs;
        } else |_| {}
        if (slept == budget_ms) break;
        const chunk = @min(@as(i64, 50), budget_ms - slept);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(chunk), .real) catch {};
        slept += chunk;
    }
    return "";
}

/// Build a fresh iroh stack (endpoint, host, bridge, completion loop), dial the
/// room, and run the loop. Returns normally when a stop is requested, or returns
/// the error when the loop fails fatally so the supervisor can rebuild. A
/// per-connection drop is recovered here without a rebuild: `on_close` nulls the
/// session and `maintain` redials it.
fn runStack(
    io: Io,
    gpa: Allocator,
    flags: Flags,
    loc: model.PeerLocator,
    reachability: iroh.Reachability,
    dial_target: []const u8,
    rendezvous_url: ?[]const u8,
) !void {
    // Key unification: the CapTP Host and the iroh endpoint share one seed so
    // accepted hellos (redeem dials) sign the dialed node id.
    const seed = try hostSeed(io, flags.dir, flags.identity);
    var resident = try iroh.Resident.init(io, &seed, .{
        .reachability = reachability,
        .connect_timeout_ms = dial_timeout_ms,
    });
    defer resident.deinit() catch |err| log.err(io, "iroh teardown failed: {s}", .{@errorName(err)});

    var id_buf: [iroh.node_id_len]u8 = undefined;
    const node_id = resident.nodeId(&id_buf);
    if (node_id.len == 0) {
        log.err(io, "iroh endpoint has no node id", .{});
        return error.NoNodeId;
    }

    // Direct demos stamp address hints on the registered locator so a redeem
    // dial reaches the member without Discovery. Discovery peers advertise a
    // bare node id — the same shape `serve.ts` uses for browser DM members — so
    // redeem uses Discovery rather than private container/LAN binds the public
    // recipient cannot reach.
    var addrs_buf: [512]u8 = undefined;
    const addrs: []const u8 = if (reachability == .direct)
        waitDirectAddrs(io, &resident, &addrs_buf, 5_000)
    else
        "";
    if (reachability == .direct and addrs.len == 0) {
        log.err(io, "iroh endpoint has no direct addresses (needed for DM register)", .{});
        return error.NoDirectAddrs;
    }

    var hint_entry: [1]model.HintEntry = undefined;
    const member_hints = model.Hints.forDirectAddresses(addrs, &hint_entry);
    const member_locator = try model.uri.writePeer(gpa, .{
        .transport = iroh.transport_name,
        .designator = node_id,
        .hints = member_hints,
    });
    defer gpa.free(member_locator);

    // The room's profile, not the interop floor: this peer only ever talks to
    // other pancake peers, and the directory it dials offers the same pair.
    var session_root: [32]u8 = undefined;
    io.randomSecure(&session_root) catch return error.HandshakeEntropyFailed;
    var host = try Host.init(gpa, seed, session_root, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = actors.Vat.max_batch_local_turns,
        .codec = rooms_profile.codec,
        .captp_version = rooms_profile.captp_version,
    });
    defer host.deinit();

    var loop: RoomsLoop = undefined;
    var state = PeerState{
        .io = io,
        .gpa = gpa,
        .host = &host,
        .bridge = undefined,
        .dir = flags.dir,
        .nick = flags.nick,
        .room_name = flags.room,
        .locator_str = dial_target,
        .member_locator = member_locator,
        .room_locator = loc,
    };
    defer state.deinitTables();
    // No per-session publish hook: an inbox belongs to one named peer, and the
    // host's giftable registry already puts each on every connection, including
    // the ones a redeem opens later.
    var bridge = RoomsBridge.init(gpa, &host, io, &loop, .{
        .on_open = onOpen,
        .on_open_ctx = &state,
    });
    defer bridge.deinit();
    state.bridge = &bridge;
    if (rendezvous_url == null) {
        log.err(io, "no keyed-relay rendezvous configured (set PANCAKE_RENDEZVOUS or pass an http://host:port/locator); browser DM introduce will fail", .{});
    }

    const read_buffer_bytes: u32 = @intCast(@min(frame_cap, 16 * 1024));
    const platform = if (rendezvous_url) |url| blk: {
        var entropy_seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        try io.randomSecure(&entropy_seed);
        break :blk try net.KeyedRelayBackend.initWithRelay(
            gpa,
            common.completion_queue_entries,
            common.read_buffers,
            read_buffer_bytes,
            .{ .url = url, .entropy_seed = entropy_seed },
        );
    } else try net.KeyedRelayBackend.init(
        gpa,
        common.completion_queue_entries,
        common.read_buffers,
        read_buffer_bytes,
    );
    const backend = try RoomsBackend.initBoundWithPlatform(gpa, &resident, platform, common.read_buffers, read_buffer_bytes);
    // This peer interposes its own close hook (DM lifecycle bookkeeping), so
    // it overrides the bridge's spliced `on_close` after `hookOptions`.
    var loop_options = RoomsBridge.hookOptions(.{
        .max_conns = common.max_sessions,
        .reserved_dial_conns = common.reserved_room_sessions,
        .listen = 0,
    });
    loop_options.on_close = onClose;
    loop = try RoomsLoop.initWithBackend(gpa, backend, RoomsBridge.makePeer, @ptrCast(&bridge), loop_options);
    defer loop.deinit();

    // Advertise the same locator hellos will claim. After ADR-0109, introduce
    // gifts embed the exporter's signed hello location — not the directory
    // `register` URI — so an empty attach here made every redeem dial hintless
    // (InvalidAddress / iroh DNS spam) even when `member_locator` already
    // carried direct-addresses. Discovery posture leaves `addrs` empty on
    // purpose; Direct must publish the addrs already collected above.
    try bridge.attach(model.transport.Known.iroh.metadata(), node_id, addrs);

    state.phase = .{ .dialing = .{ .cooldown = 0 } };
    bridge.dialOutboundReserved(loc) catch |err| {
        log.err(io, "dial failed: {s}", .{@errorName(err)});
        state.phase = .{ .down = .{ .cooldown = 0 } };
    };

    // The flag deliberately remains false: `runUntil`'s wall-clock deadline is
    // the maintenance timer. One bounded reactor wait replaces the former
    // sleep task, which set a flag but could not wake this poll.
    var maintain_due = std.atomic.Value(bool).init(false);
    while (!PeerState.stopRequested()) {
        loop.runUntil(&maintain_due, timer_ms) catch |err| switch (err) {
            error.Timeout => {},
            else => {
                loop.closeAndDrain() catch {};
                return err;
            },
        };
        maintain(&state);
    }
    loop.closeAndDrain() catch {};
}
