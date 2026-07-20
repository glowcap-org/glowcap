//! Pure lifecycle-phase goldens for `pancake app rooms-peer` (no wire): the
//! `phase.zig` transition helpers and the state.json status projection.
const std = @import("std");
const cli = @import("cli");

const phase_mod = cli.rooms_peer_phase;
const Phase = phase_mod.Phase;
const HostSession = cli.rooms_peer_common.HostSession;
const model = cli.rooms_peer_common.model;

// Pointer-identity payload only; never dereferenced by the pure helpers.
fn dummySession() *HostSession {
    const S = struct {
        var dummy: HostSession = undefined;
    };
    return &S.dummy;
}

fn farRef(n: u64) model.Reference {
    return .{ .far = model.FarRef.object(n) };
}

test "rooms-peer phase cooldown paces .down: counts to zero, then permits" {
    var phase: Phase = .{ .down = .{ .cooldown = 3 } };
    // Three wakes count down without permitting; the fourth permits the dial.
    try std.testing.expect(!phase_mod.tickCooldown(&phase.down.cooldown));
    try std.testing.expect(!phase_mod.tickCooldown(&phase.down.cooldown));
    try std.testing.expect(!phase_mod.tickCooldown(&phase.down.cooldown));
    try std.testing.expectEqual(@as(u32, 0), phase.down.cooldown);
    try std.testing.expect(phase_mod.tickCooldown(&phase.down.cooldown));
    // Permitting does not underflow: it keeps permitting at zero.
    try std.testing.expect(phase_mod.tickCooldown(&phase.down.cooldown));
    try std.testing.expectEqual(@as(u32, 0), phase.down.cooldown);
}

test "rooms-peer phase refused connect carries the countdown .dialing to .down" {
    var phase: Phase = .{ .dialing = .{ .cooldown = 7 } };
    phase_mod.connectRefused(&phase);
    try std.testing.expect(phase == .down);
    try std.testing.expectEqual(@as(u32, 7), phase.down.cooldown);

    // Any other phase is untouched by a stale refused-connect close.
    phase = .{ .down = .{ .cooldown = 5 } };
    phase_mod.connectRefused(&phase);
    try std.testing.expect(phase == .down);
    try std.testing.expectEqual(@as(u32, 5), phase.down.cooldown);

    phase = .{ .joining = .{ .session = dummySession() } };
    phase_mod.connectRefused(&phase);
    try std.testing.expect(phase == .joining);

    phase = .{ .joined = .{
        .session = dummySession(),
        .directory = farRef(1),
        .room = farRef(2),
        .reg = .registered,
    } };
    phase_mod.connectRefused(&phase);
    try std.testing.expect(phase == .joined);
}

test "rooms-peer phase join deadline fires at exactly join_deadline_wakes" {
    const deadline = cli.rooms_peer_common.join_deadline_wakes;
    var phase: Phase = .{ .joining = .{ .session = dummySession() } };
    var wake: u32 = 1;
    while (wake < deadline) : (wake += 1) {
        try std.testing.expect(!phase_mod.joinDeadlineFires(&phase.joining, deadline));
    }
    try std.testing.expectEqual(deadline - 1, phase.joining.age);
    // The deadline-th wake fires, and not before.
    try std.testing.expect(phase_mod.joinDeadlineFires(&phase.joining, deadline));
}

test "rooms-peer phase abandon request no-ops outside .joining" {
    const session = dummySession();
    var phase: Phase = .{ .joining = .{ .session = session } };
    try std.testing.expect(phase_mod.requestAbandon(&phase));
    try std.testing.expect(phase == .abandoning);
    // The abandoned session rides along by pointer identity.
    try std.testing.expectEqual(session, phase.abandoning);

    // Already abandoning: a second request is a no-op.
    try std.testing.expect(!phase_mod.requestAbandon(&phase));
    try std.testing.expect(phase == .abandoning);

    phase = .{ .down = .{ .cooldown = 4 } };
    try std.testing.expect(!phase_mod.requestAbandon(&phase));
    try std.testing.expect(phase == .down);
    try std.testing.expectEqual(@as(u32, 4), phase.down.cooldown);

    phase = .{ .dialing = .{ .cooldown = 2 } };
    try std.testing.expect(!phase_mod.requestAbandon(&phase));
    try std.testing.expect(phase == .dialing);

    phase = .{ .joined = .{
        .session = session,
        .directory = farRef(1),
        .room = farRef(2),
        .reg = .{ .pending = 3 },
    } };
    try std.testing.expect(!phase_mod.requestAbandon(&phase));
    try std.testing.expect(phase == .joined);
}

test "rooms-peer phase registered-notify flips only a live .joined" {
    const session = dummySession();
    var phase: Phase = .{ .joined = .{
        .session = session,
        .directory = farRef(1),
        .room = farRef(2),
        .reg = .{ .pending = 9 },
    } };
    try std.testing.expect(!phase.isRegistered());
    try std.testing.expect(phase_mod.noteRegistered(&phase));
    try std.testing.expect(phase == .joined);
    try std.testing.expect(phase.joined.reg == .registered);
    try std.testing.expect(phase.isRegistered());

    // A late notify after teardown must not report the wire as up.
    phase = .{ .down = .{ .cooldown = 0 } };
    try std.testing.expect(!phase_mod.noteRegistered(&phase));
    try std.testing.expect(phase == .down);

    phase = .{ .dialing = .{ .cooldown = 1 } };
    try std.testing.expect(!phase_mod.noteRegistered(&phase));
    try std.testing.expect(phase == .dialing);

    phase = .{ .joining = .{ .session = session } };
    try std.testing.expect(!phase_mod.noteRegistered(&phase));
    try std.testing.expect(phase == .joining);

    phase = .{ .abandoning = session };
    try std.testing.expect(!phase_mod.noteRegistered(&phase));
    try std.testing.expect(phase == .abandoning);
}

test "rooms-peer phase status projection over every arm" {
    const session = dummySession();

    var phase: Phase = .{ .down = .{ .cooldown = 3 } };
    try std.testing.expectEqualStrings("reconnecting", phase.statusOf());
    try std.testing.expect(!phase.isRegistered());
    try std.testing.expect(phase.session() == null);

    phase = .{ .dialing = .{ .cooldown = 0 } };
    try std.testing.expectEqualStrings("reconnecting", phase.statusOf());
    try std.testing.expect(!phase.isRegistered());
    try std.testing.expect(phase.session() == null);

    phase = .{ .joining = .{ .session = session } };
    try std.testing.expectEqualStrings("joining", phase.statusOf());
    try std.testing.expect(!phase.isRegistered());
    try std.testing.expectEqual(session, phase.session().?);

    phase = .{ .abandoning = session };
    try std.testing.expectEqualStrings("reconnecting", phase.statusOf());
    try std.testing.expect(!phase.isRegistered());
    try std.testing.expectEqual(session, phase.session().?);

    phase = .{ .joined = .{
        .session = session,
        .directory = farRef(1),
        .room = farRef(2),
        .reg = .{ .pending = 13 },
    } };
    // "joined" is written only from the .joined arm; registered stays false
    // until the directory's notify lands.
    try std.testing.expectEqualStrings("joined", phase.statusOf());
    try std.testing.expect(!phase.isRegistered());
    try std.testing.expectEqual(session, phase.session().?);

    phase.joined.reg = .registered;
    try std.testing.expectEqualStrings("joined", phase.statusOf());
    try std.testing.expect(phase.isRegistered());
}
