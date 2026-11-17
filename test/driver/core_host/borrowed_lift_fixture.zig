//! The two-Host fixture the borrowed-lift tests share: a Host and its
//! partner over one pair, with the snapshot every refusal must leave kept.

const std = @import("std");
const glowcap = @import("glowcap");
const shapes = @import("../../support/depth_shapes.zig");
const test_host = @import("../../support/core_host.zig");
const host_pair = @import("../../support/host_pair.zig");
const capture = @import("../../support/capture.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;
const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const allocator = std.testing.allocator;

pub const far7: model.Argument = .{ .reference = .{ .far = model.FarRef.object(7) } };

pub const LocalActor = struct {
    pub fn handle(_: *LocalActor, _: *actors.Turn, _: actors.Delivery) !model.Argument {
        return .{ .void = {} };
    }
};

/// Parks every answer, so a client's question stays open on the server.
pub const Greeter = struct {
    pub var resolver: u64 = 0;
    pub fn handle(_: *@This(), ht: *driver.HostTurn, _: ?[]const u8, _: driver.Args) !driver.Value {
        resolver = try ht.deferAnswer();
        return .{ .void = {} };
    }
};

pub fn inlineGive() model.HandoffGive {
    return .{
        .recipient_key = &(@as([32]u8, @splat(0x11))),
        .exporter = .{ .transport = "tcp", .designator = "127.0.0.1:9799", .hints = model.Hints.emptyFalse() },
        .gifter_exporter_session = &(@as([32]u8, @splat(0x22))),
        .gifter_side = &(@as([32]u8, @splat(0x33))),
        .gift_id = &(@as([model.handoff_gift_id_bytes]u8, @splat(0x44))),
        .signature = &(@as([64]u8, @splat(0x55))),
    };
}

/// Counts the calls whose arguments lifted, and releases them at the turn's end.
pub const Probe = struct {
    pub var ran: usize = 0;
    pub fn handle(_: *@This(), ht: *driver.HostTurn, _: ?[]const u8, args: driver.Args) !driver.Value {
        defer ht.releaseArguments(args);
        ran += 1;
        return .{ .void = {} };
    }
};

pub const Fixture = struct {
    host: Host,
    partner: Host,
    pair: host_pair.Pair,
    session: *HostSession,

    pub fn init(self: *Fixture, seed: u8, designator: []const u8) !void {
        return self.initIn(allocator, seed, designator);
    }

    /// The same fixture with both Hosts (and so every Node and Peer) drawing
    /// from `gpa`, so a test can make their allocations fail.
    pub fn initIn(self: *Fixture, gpa: std.mem.Allocator, seed: u8, designator: []const u8) !void {
        self.host = test_host.init(gpa, @as([32]u8, @splat(seed)), .{ .thread_policy = .unchecked });
        self.partner = test_host.init(gpa, @as([32]u8, @splat(seed +% 1)), .{ .thread_policy = .unchecked });
        self.pair = try host_pair.openPair(&self.host, &self.partner, designator);
        self.session = self.pair.a;
    }

    pub fn deinit(self: *Fixture) void {
        self.host.deinit();
        self.partner.deinit();
    }

    pub fn peer(self: *Fixture) *glowcap.ocapn.engine.Peer {
        return self.session.served.port.peer;
    }

    pub fn state(self: *Fixture) *glowcap.ocapn.session.Session {
        return &self.peer().session_state;
    }

    /// What the lift must leave unchanged when its input stays with the caller.
    pub const Snapshot = struct {
        refcount: u64,
        releasable: u64,
        host_ref: ?u64,
        lifted: u64,
        live: usize,
        promises: usize,
        queued: bool,
    };

    pub fn snapshot(self: *Fixture, position: u64) Snapshot {
        const pos: model.ImportPosition = .from(position);
        const identity = self.state().hostImportIdentity(pos);
        return .{
            .refcount = self.state().importRefcount(pos),
            .releasable = self.state().importReleasable(pos),
            .host_ref = self.state().hostCapabilityFor(pos),
            .lifted = if (identity) |found| found.lifted_retains else 0,
            .live = self.host.capabilities.liveCount(),
            .promises = self.host.capability_promises.count(),
            .queued = self.peer().hasOutbound(),
        };
    }

    /// The caller kept everything: the same counts, no new frame queued, no abort,
    /// and a session that still serves.
    pub fn expectKept(self: *Fixture, before: Snapshot, position: u64) !void {
        try std.testing.expectEqual(before, self.snapshot(position));
        try std.testing.expect(self.peer().lastAbort() == null);
        try std.testing.expectEqual(HostSession.LifecyclePhase.active, self.session.lifecyclePhase());
    }

    pub fn lift(self: *Fixture, arena: std.mem.Allocator, args: []const model.Argument, input: anytype) ![]const driver.core.Value {
        return self.host.liftValues(self.session, arena, .fromOwnedSlice(args), input);
    }
};

pub fn chain(arena: std.mem.Allocator) !model.Argument {
    return (try shapes.ownedArgs(arena, model.max_value_depth + 1, .leaf))[0];
}

/// The import position `importer` holds after fetching `name` from its partner.
pub fn importOf(importer: *Host, session: *HostSession, pair: host_pair.Pair, name: []const u8) !u64 {
    const vow = try importer.fetch(session, name);
    var captured: capture.CapturedRef = .{};
    try importer.vowOn(vow, .{ .ctx = &captured, .func = capture.CapturedRef.record });
    try host_pair.pumpToQuiescence(&.{pair});
    if (captured.ref == null) return error.FetchUnsettled;
    var found: ?u64 = null;
    var scan: struct {
        found: *?u64,
        fn take(self: *@This(), view: glowcap.ocapn.session.ImportView) void {
            if (view.refcount != 0) self.found.* = view.position.int();
        }
    } = .{ .found = &found };
    glowcap.ocapn.session.inspect.forEachImport(&session.served.port.peer.session_state, &scan, @TypeOf(scan).take);
    return found orelse error.NoNewImport;
}

pub fn partnerImport(f: *Fixture, name: []const u8) !u64 {
    return importOf(&f.partner, f.pair.b, f.pair, name);
}
