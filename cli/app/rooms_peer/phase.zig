//! Room-session lifecycle for the `glowcap app rooms-peer` daemon: one union
//! for the phases the peer walks (down, dialing, joining, abandoning, joined)
//! and the pure transition helpers `maintain` and the vow callbacks share.
//! Wire calls (dial, close, flush, state.json writes) stay in `peer.zig`; this
//! module owns only the guards, the tick arithmetic, and the status
//! projection, so the transitions are testable without a wire.

const std = @import("std");
const common = @import("common.zig");

const model = common.model;
const HostSession = common.HostSession;

/// Where the room session is in its life. Exactly one arm is live at a time;
/// the DM tables (`dm_caps` / `pending_introduces` / `failed_introduces`) stay
/// orthogonal `PeerState` fields, cleared on wire teardown. `directory` and
/// `room` are POD far refs (stored without `cloneReference`, dropped without
/// `freeReference`), so payload-by-value is safe.
pub const Phase = union(enum) {
    /// No wire. `cooldown` counts maintain wakes down to the next dial.
    down: struct { cooldown: u32 },
    /// Connect in flight. The countdown keeps running so a refused connect
    /// resumes pacing in `.down` instead of restarting it.
    dialing: struct { cooldown: u32 },
    /// Session open, join chain (fetch directory, enter/open, subscribe) in
    /// flight. `age` counts maintain wakes toward the join deadline.
    joining: Joining,
    /// Join failed under a live session; `maintain` closes the slot next tick.
    abandoning: *HostSession,
    /// Subscribed to the room. `reg` tracks directory registration (DM
    /// introducibility), a separate capability from presence.
    joined: Joined,

    pub const Joining = struct {
        session: *HostSession,
        directory: ?model.Reference = null,
        /// Retained while the subscribe vow is pending. The peer is not
        /// `.joined` until that vow fulfills.
        room: ?model.Reference = null,
        age: u32 = 0,
    };

    pub const Joined = struct {
        session: *HostSession,
        directory: model.Reference,
        room: model.Reference,
        reg: Reg,
    };

    /// Directory registration state while joined: a retry countdown, or done.
    pub const Reg = union(enum) {
        pending: u32,
        registered,
    };

    /// The live room session, across every arm that holds one.
    pub fn session(self: *const Phase) ?*HostSession {
        return switch (self.*) {
            .joining => |j| j.session,
            .abandoning => |s| s,
            .joined => |j| j.session,
            .down, .dialing => null,
        };
    }

    /// DM introduce works only once the directory has confirmed registration.
    pub fn isRegistered(self: *const Phase) bool {
        return self.* == .joined and self.joined.reg == .registered;
    }

    /// The state.json status string for this arm. The strings are a byte-pinned
    /// on-disk contract — the supervisor exact-matches "joined" and treats
    /// everything else as keep-polling — so they are explicit literals here,
    /// never `@tagName`.
    pub fn statusOf(self: *const Phase) []const u8 {
        return switch (self.*) {
            .down, .dialing, .abandoning => "reconnecting",
            .joining => "joining",
            .joined => "joined",
        };
    }
};

/// One maintain wake against a countdown: decrements toward zero and returns
/// whether the countdown has already run out (the guarded action may fire).
pub fn tickCooldown(cooldown: *u32) bool {
    if (cooldown.* > 0) {
        cooldown.* -= 1;
        return false;
    }
    return true;
}

/// Age a table of cooling-off refusals, freeing the key of each one whose wait
/// is over, and return how many were forgotten.
///
/// A refusal is the one cached thing no object can invalidate. A capability
/// names something that can report itself gone; a refusal names something that
/// was never there, so only a clock can clear it. Held without one, a peer who
/// was briefly unreachable stays unreachable for as long as the process lives.
pub fn expireCooldowns(
    gpa: std.mem.Allocator,
    table: *std.StringHashMapUnmanaged(u32),
) usize {
    // Two passes: a hash map may not be mutated while its iterator is live.
    var expired: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = table.iterator();
    while (it.next()) |entry| {
        if (!tickCooldown(entry.value_ptr)) continue;
        if (n == expired.len) break;
        expired[n] = entry.key_ptr.*;
        n += 1;
    }
    for (expired[0..n]) |key| {
        if (table.fetchRemove(key)) |old| gpa.free(old.key);
    }
    return n;
}

pub const PendingOfferResult = enum {
    queued,
    already_pending,
    at_capacity,
    allocation_failed,
};

/// Queue an owned nick for a later inbox offer, idempotently and up to
/// `max_pending`. Resource failure is distinct from the intentional bound so
/// the caller can preserve one bounded retry marker.
/// Safe under the host callback latch: only allocates into the map; never
/// publishes or tells.
pub fn schedulePendingOffer(
    gpa: std.mem.Allocator,
    table: *std.StringHashMapUnmanaged(void),
    peer: []const u8,
    max_pending: usize,
) PendingOfferResult {
    if (peer.len == 0) return .at_capacity;
    if (table.contains(peer)) return .already_pending;
    if (table.count() >= max_pending) return .at_capacity;
    const key = gpa.dupe(u8, peer) catch return .allocation_failed;
    table.put(gpa, key, {}) catch {
        gpa.free(key);
        return .allocation_failed;
    };
    return .queued;
}

/// Call `offer` for each pending nick; free and remove those that return true.
/// Keeps a nick across a false return so the next maintain wake retries.
/// Two-pass: a hash map may not be mutated while its iterator is live.
pub fn drainPendingOffers(
    gpa: std.mem.Allocator,
    table: *std.StringHashMapUnmanaged(void),
    context: anytype,
    comptime offer: anytype,
) void {
    if (table.count() == 0) return;
    var done: std.ArrayList([]const u8) = .empty;
    defer done.deinit(gpa);
    // Reserve before calling offer: once a tell is admitted, recording its
    // removal must be infallible or the next wake can send it twice.
    // best-effort: refusing the reservation defers the sweep to the next wake.
    done.ensureTotalCapacity(gpa, table.count()) catch return;
    var it = table.keyIterator();
    while (it.next()) |key_ptr| {
        if (offer(context, key_ptr.*)) done.appendAssumeCapacity(key_ptr.*);
    }
    for (done.items) |peer| {
        if (table.fetchRemove(peer)) |kv| gpa.free(kv.key);
    }
}

/// A dial that never reached session open is dead: carry the countdown into
/// `.down` so redial pacing continues instead of restarting. No-op in any
/// other phase (a stale close must not clobber a live session).
pub fn connectRefused(phase: *Phase) void {
    switch (phase.*) {
        .dialing => |d| phase.* = .{ .down = .{ .cooldown = d.cooldown } },
        else => {},
    }
}

/// One maintain wake in `.joining`: ages the join window. Returns true when
/// the deadline fires — on exactly the `deadline`-th wake, not before — with
/// the phase left for the caller to abandon.
pub fn joinDeadlineFires(joining: *Phase.Joining, deadline: u32) bool {
    joining.age += 1;
    return joining.age >= deadline;
}

/// A join-path failure asked for recovery: move a live `.joining` to
/// `.abandoning` (maintain closes the slot outside the callback latch) and
/// return true. Every other phase no-ops — a late vow callback after teardown
/// or after a successful join must not clobber the phase.
pub fn requestAbandon(phase: *Phase) bool {
    switch (phase.*) {
        .joining => |j| {
            phase.* = .{ .abandoning = j.session };
            return true;
        },
        else => return false,
    }
}

/// Whether `session` owns the join currently in flight. Subscribe listeners
/// retain the session that minted their vow and use this guard before touching
/// state, so a settlement from an abandoned attempt cannot complete a later
/// join.
pub fn isJoiningSession(phase: *const Phase, session: *HostSession) bool {
    return phase.* == .joining and phase.joining.session == session;
}

/// A room `subscribe` fulfilled: promote the fully prepared join to `.joined`
/// and start directory-registration pacing. A callback with incomplete or
/// stale state changes nothing, so its caller can route a live `.joining`
/// through `requestAbandon` instead of manufacturing a second recovery path.
pub fn noteSubscribed(phase: *Phase, registration_wait: u32) bool {
    switch (phase.*) {
        .joining => |j| {
            const directory = j.directory orelse return false;
            const room = j.room orelse return false;
            phase.* = .{ .joined = .{
                .session = j.session,
                .directory = directory,
                .room = room,
                .reg = .{ .pending = registration_wait },
            } };
            return true;
        },
        else => return false,
    }
}

/// A directory `registered` notify landed: flip `.joined`'s pending countdown
/// to `.registered` and return true. Every other phase no-ops — a late notify
/// arriving after teardown must not report the wire as up.
pub fn noteRegistered(phase: *Phase) bool {
    switch (phase.*) {
        .joined => |*j| {
            j.reg = .registered;
            return true;
        },
        else => return false,
    }
}
