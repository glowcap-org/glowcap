//! A rooms chat client, written on glowcap actors in Zig. Zig is the home
//! language; this runs on the same core every binding wraps, and it drives the
//! real netlayers glowcap ships.
//!
//! On the driver surface this reads like the other languages: one
//! `driver.connect`, `fetch` the directory by name, `call` it to enter or open
//! the named room (which hands back a live capability to that room), `spawn`
//! an inbox the room can call back, `call` the room with a subscribe carrying
//! that capability, `call` the returned membership seat with the post, and
//! `stepReadable` the session with one explicit pump per step, with the loop
//! still owned by the caller the Zig way.
//!
//!   glowcap-rooms-client <locator> <room> <nick> <line> [roster]
//!
//! The locator is transport-neutral: a `host:port` reaches a TCP room, and an
//! `ocapn://<nodeid>.iroh?direct-addresses=…` URI reaches an iroh room (when
//! this client was built with the iroh transport (`zig build demo-rooms-iroh`).
//! the default `demo-rooms` build is TCP-only and refuses a URI with a typed
//! message rather than dragging the Rust sidecar into the hermetic build).
//!
//! The last argument is the roster: a comma-separated list of the member nicks
//! to expect (default: just you). The client posts only once every roster member
//! is present. It learns who is present from the structured presence the room
//! attaches to each membership line (the roster on arrival and each join), and
//! exits 0 once it has seen a line from every roster member. Members outside the roster
//! (people already chatting in an attached room, say) are printed but never
//! counted, so a busy room cannot fake or break the assertion.
//!
//! The wire grammar this switches on, the verbs, the publication record, the
//! watch kinds, the notify tails, and the subscribe answer, is the generated
//! table every sibling client reads. `protocol.zig` beside this file is the Zig
//! way of asking that table whether an argument fits.

const std = @import("std");
const glowcap = @import("glowcap");
const build_options = @import("rooms_client_build_options");

const wire = @import("protocol.zig");
const proto = wire.gen;

const demo_rooms = @import("demo_rooms_cli");
const demo_usage = @import("demo_usage");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = glowcap.net.tcp;

const frame_cap: usize = 1 << 16;
/// The whole roster wait is bounded, like the Deno/Python/Racket clients'
/// deadlines: a member that never completes exits 1 with its seen-count
/// instead of wedging the demo. The deadline itself is the generated one every
/// sibling client holds.
const roster_wait_budget_ms: i64 = proto.session_deadline_ms;
/// One bounded readable-wait per loop turn, so the deadline above is checked
/// even while the wire is silent.
const step_poll_ms: i32 = 250;

/// State the inbox actor and the main loop share: which roster members are
/// present, which we have seen a chat line from, and whether the room has
/// ended this membership.
const State = struct {
    nick: []const u8,
    roster: []const []const u8,
    present: []bool,
    seen: []bool,
    /// Set once the room said `membershipEnded` to our inbox: no more lines will
    /// reach it, so the roster wait cannot complete. The reason was printed as
    /// the last line.
    ended: bool = false,

    fn markPresent(self: *State, name: []const u8) void {
        for (self.roster, 0..) |member, i| {
            if (std.mem.eql(u8, member, name)) self.present[i] = true;
        }
    }

    fn markSeen(self: *State, name: []const u8) void {
        for (self.roster, 0..) |member, i| {
            if (std.mem.eql(u8, member, name)) self.seen[i] = true;
        }
    }

    fn markAbsent(self: *State, name: []const u8) void {
        for (self.roster, 0..) |member, i| {
            if (std.mem.eql(u8, member, name)) self.present[i] = false;
        }
    }

    /// Fold what one presence tail does to one member it names into the roster.
    fn apply(self: *State, effect: proto.Effect, name: []const u8) void {
        switch (effect) {
            .arrive => self.markPresent(name),
            .depart => self.markAbsent(name),
            .stay => {},
        }
    }

    fn allPresent(self: *const State) bool {
        for (self.present) |p| if (!p) return false;
        return true;
    }

    fn seenCount(self: *const State) usize {
        var n: usize = 0;
        for (self.seen) |s| {
            if (s) n += 1;
        }
        return n;
    }
};

/// The inbox the room calls back on. A `notify(from, text, ...presence)` is either
/// a room announcement (from "room", carrying a structured presence change after
/// the text) or a plain chat line from a member.
const Inbox = struct {
    state: *State,

    pub fn handle(self: *Inbox, turn: *driver.HostTurn, selector: ?[]const u8, args: driver.Args) !driver.Value {
        defer turn.releaseArguments(args);
        const verb = selector orelse return error.NoSuchMethod;
        const arg_values = try args.values();
        if (!std.mem.eql(u8, verb, proto.notify)) return error.NoSuchMethod;
        try applyNotify(self.state, arg_values);
        return .{ .boolean = true };
    }
};

/// The sender a notify names, or "?" when the line does not name one.
fn senderOf(args: []const driver.Value) []const u8 {
    return if (args.len > 0 and args[0] == .string) args[0].string else "?";
}

/// The display text a notify carries, empty when it carries none.
fn textOf(args: []const driver.Value) []const u8 {
    return if (args.len > 1 and args[1] == .string) args[1].string else "";
}

/// Print one notified line, then fold it into the roster state.
fn applyNotify(state: *State, args: []const driver.Value) !void {
    std.debug.print("[{s}] {s}: {s}\n", .{ state.nick, senderOf(args), textOf(args) });
    return readNotify(state, args);
}

/// The room's last word to an inbox, held to the shape the generated table
/// gives it: the room says it, the reason is the display text, and nothing
/// rides after the tag.
const membership_ended_tail = wire.tailFor(proto.membership_ended);

/// The pure half of a notify: presence, the membership-ended notice held to
/// its shape, and who has been seen. A `membershipEnded` tail is the room's
/// last word to this inbox (a steward's kick, say). Otherwise a membership line
/// carries its change as structured args, a plain chat line does not, and a
/// line from a member is presence too. Tests drive this so they print nothing.
fn readNotify(state: *State, args: []const driver.Value) !void {
    const from = senderOf(args);
    const text = textOf(args);
    if (args.len > 2 and args[2] == .string and std.mem.eql(u8, args[2].string, proto.membership_ended)) {
        if (!wire.tailFits(membership_ended_tail, from, text, args[3..])) return error.MalformedMembershipEnded;
        state.ended = true;
        return;
    }
    if (!applyPresence(state, args) and !std.mem.eql(u8, from, proto.room_sender)) {
        state.markPresent(from);
        state.markSeen(from);
    }
}

fn printRoomEvent(nick: []const u8, event_kind: []const u8, room: wire.RoomInfo) void {
    std.debug.print("[{s}] directory: {s} {s} (", .{ nick, event_kind, room.name });
    if (room.count) |count| std.debug.print("{d}", .{count}) else std.debug.print("unknown", .{});
    std.debug.print(")\n", .{});
}

/// The directory's watch observer: the room list's live feed.
const Watcher = struct {
    nick: []const u8,

    pub fn handle(self: *Watcher, turn: *driver.HostTurn, selector: ?[]const u8, args: driver.Args) !driver.Value {
        defer turn.releaseArguments(args);
        const verb = selector orelse return error.NoSuchMethod;
        const arg_values = try args.values();
        if (!std.mem.eql(u8, verb, proto.notify)) return error.NoSuchMethod;
        if (try wire.watchEvent(arg_values)) |room| printRoomEvent(self.nick, arg_values[0].string, room);
        return .{ .boolean = true };
    }
};

/// Every dial this client makes wears the core-authored glowcap profile and the
/// same finite waits, so they are named once here rather than respelled per
/// transport.
fn roomsSessionOpts() driver.SessionOptions {
    return .{
        .frame_cap = frame_cap,
        .codec = model.Preference.glowcap.codec,
        .captp_version = model.Preference.glowcap.captp_version,
        .handshake = .{ .ms = 10_000 },
        .settle = .{ .ms = 10_000 },
    };
}

/// Print the first room page without turning unknown foreign occupancy into 0.
fn printRooms(nick: []const u8, arg: driver.Value) !void {
    const listed = wire.roomPage(arg) orelse return error.InvalidRoomList;
    std.debug.print("[{s}] rooms:", .{nick});
    for (listed.rows) |item| {
        const room = wire.roomInfo(item.list).?;
        std.debug.print(" {s} (", .{room.name});
        if (room.count) |count| std.debug.print("{d}", .{count}) else std.debug.print("unknown", .{});
        std.debug.print(")", .{});
    }
    if (listed.rows.len == 0) std.debug.print(" (none yet)", .{});
    if (listed.next != null) std.debug.print(" and more", .{});
    std.debug.print("\n", .{});
}

/// Apply the structured presence a room line carries after its display text, if
/// any. The generated table says which tags are presence and what each does:
/// `notify("room", text, "roster", names…)` names everyone already here (our
/// welcome), `notify("room", text, "join"|"leave", nick)` moves that one member
/// in or out, and the rest are facts about a member who is still here. Returns
/// true when the line was a presence change, so the caller does not also count
/// it as a chat line.
fn applyPresence(state: *State, args: []const driver.Value) bool {
    const tail = wire.presenceTail(senderOf(args), textOf(args), args) orelse return false;
    const effect = tail.effect.?;
    const extra = args[3..];
    // The members a tail names are its `name` arguments, then the roster riding
    // after them when the tail admits a rest.
    for (tail.trailing, extra[0..tail.trailing.len]) |field, arg| {
        if (std.mem.eql(u8, field.name, "name") and arg == .string) state.apply(effect, arg.string);
    }
    if (tail.rest != null) {
        for (extra[tail.trailing.len..]) |arg| {
            if (arg == .string) state.apply(effect, arg.string);
        }
    }
    return true;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program name
    const locator = args.next() orelse return fail("missing <locator>");
    const room_name = args.next() orelse return fail("missing <room>");
    const nick = args.next() orelse return fail("missing <nick>");
    const line = args.next() orelse return fail("missing <line>");
    const roster_str = args.next() orelse nick;

    var roster: std.ArrayList([]const u8) = .empty;
    defer roster.deinit(allocator);
    var roster_names = std.mem.splitScalar(u8, roster_str, ',');
    while (roster_names.next()) |name| {
        if (name.len > 0) try roster.append(allocator, name);
    }
    if (roster.items.len == 0) return fail("empty <roster>");

    const present = try allocator.alloc(bool, roster.items.len);
    defer allocator.free(present);
    @memset(present, false);
    const seen = try allocator.alloc(bool, roster.items.len);
    defer allocator.free(seen);
    @memset(seen, false);
    var state = State{ .nick = nick, .roster = roster.items, .present = present, .seen = seen };

    if (std.mem.indexOf(u8, locator, "://") != null) {
        if (build_options.iroh_enabled) {
            try dialIroh(io, allocator, locator, &state, room_name, nick, line);
        } else {
            return fail("this Zig rooms client is TCP-only; build the iroh variant (`zig build demo-rooms-iroh`) to dial an ocapn:// URI");
        }
    } else {
        try runTcpRoom(io, allocator, locator, &state, room_name, nick, line);
    }

    if (state.seenCount() < state.roster.len) {
        std.debug.print("rooms-client: {s} saw lines from {d}/{d} members before the stream ended\n", .{ nick, state.seenCount(), state.roster.len });
        std.process.exit(1);
    }
}

/// Dial a `host:port` designator over the cleartext TCP transport glowcap
/// ships.
fn runTcpRoom(io: std.Io, allocator: std.mem.Allocator, locator: []const u8, state: *State, room_name: []const u8, nick: []const u8, line: []const u8) !void {
    try dialVia(io, allocator, .{ .symbols = &.{.tcp} }, tcp.locator(locator), state, room_name, nick, line);
}

/// Dial an `ocapn://<nodeid>.iroh?direct-addresses=…` URI over iroh's encrypted
/// QUIC. Compiled only into the iroh-enabled build (the `iroh` import links the
/// Rust sidecar), so the default TCP build never pulls cargo into its graph. A
/// URI carrying direct-addresses dials those directly (relay-less Direct); a
/// node-id-only URI resolves the peer through discovery.
fn dialIroh(io: std.Io, allocator: std.mem.Allocator, uri: []const u8, state: *State, room_name: []const u8, nick: []const u8, line: []const u8) !void {
    const loc = try model.uri.parsePeer(allocator, uri);
    defer model.freePeerLocator(allocator, loc);
    if (!std.mem.eql(u8, loc.transport, model.transport.iroh)) {
        return fail("rooms expected an iroh ocapn:// URI");
    }
    const hints = net.netlayer.directAddrHint(loc.hints) orelse "";
    const reachability: @import("iroh").Reachability = if (hints.len > 0) .direct else .discovery;
    const iroh = @import("iroh");
    var resident = try iroh.Resident.init(io, null, .{ .reachability = reachability });
    defer resident.deinit() catch |err| std.log.err("iroh teardown failed: {s}", .{@errorName(err)});
    var adapter = try iroh.MultiplexedAdapter.init(allocator, &resident);
    defer if (adapter.deinit()) |failure| std.log.err("iroh adapter teardown failed: {s}", .{failure.primaryName()});
    const providers = [_]driver.HostRuntime.ProviderRegistration{.{ .profile = iroh.transport_profile, .resident = adapter.multiplexed() }};
    try dialVia(io, allocator, .{ .residents = &providers }, loc, state, room_name, nick, line);
}

/// One `driver.Session` over the named transports, shared by TCP and iroh:
/// `driver.connect` builds the runtime, completes the keyed handshake, and
/// hands back the session the room loop pumps.
fn dialVia(
    io: std.Io,
    allocator: std.mem.Allocator,
    transports: driver.Transports,
    locator: model.PeerLocator,
    state: *State,
    room_name: []const u8,
    nick: []const u8,
    line: []const u8,
) !void {
    var session = try driver.connect(allocator, io, transports, locator, .ephemeral, roomsSessionOpts());
    defer session.deinit();
    try runRoom(io, session, allocator, state, room_name, nick, line);
}

/// The capability a `call` returned, or a refusal when the reply carried
/// something else.
fn roomRefFromArg(arg: driver.Value) !driver.Capability {
    if (arg != .capability) return error.NotACapability;
    return arg.capability;
}

/// Where the seat sits in the generated subscribe answer.
const seat_at = wire.indexOf(&proto.subscribe_answer_fields, "seat");

/// The membership seat out of a `subscribe` answer, the whole answer held to
/// the generated fields. Every later membership verb goes to the seat, never to
/// the room it was answered for.
fn membershipSeatFromArg(arg: driver.Value) !driver.Capability {
    if (arg != .list or !wire.fits(&proto.subscribe_answer_fields, arg.list)) return error.NotAMembership;
    return roomRefFromArg(arg.list[seat_at]);
}

/// Enter-or-open lives here because it materializes settled outcomes through
/// `driver.Session.call`; see `_demo/rooms_cli.{py,rkt,rs}` for the same CLI
/// leniency in other languages.
/// Enter the named room, opening it if it does not exist. The wire stays strict (
/// `enter` breaks if there is no such room, `open` breaks if the name is taken)
/// so this tries `enter`, falls back to `open`, and on a creation race falls
/// back to `enter` once more. The settled outcomes are materialized into a
/// scratch arena that frees here; the returned capability is a session-scoped
/// handle and outlives it.
fn enterOrOpen(session: *driver.Session, allocator: std.mem.Allocator, directory: driver.Capability, room_name: []const u8) !driver.Capability {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const name_arg = driver.Value{ .string = room_name };

    switch (try session.call(directory, proto.enter, &.{name_arg}, scratch)) {
        .fulfilled => |arg| return roomRefFromArg(arg),
        .broken => |reason| if (!std.mem.eql(u8, demo_rooms.errorCode(reason), demo_rooms.no_such_room)) {
            std.debug.print("rooms-client: enter \"{s}\" broke: {s}\n", .{ room_name, reason });
            return error.EnterFailed;
        },
    }
    switch (try session.call(directory, proto.open, &.{name_arg}, scratch)) {
        .fulfilled => |arg| return roomRefFromArg(arg),
        .broken => |reason| if (!std.mem.eql(u8, demo_rooms.errorCode(reason), demo_rooms.room_exists)) {
            std.debug.print("rooms-client: open \"{s}\" broke: {s}\n", .{ room_name, reason });
            return error.OpenFailed;
        },
    }
    switch (try session.call(directory, proto.enter, &.{name_arg}, scratch)) {
        .fulfilled => |arg| return roomRefFromArg(arg),
        .broken => return error.EnterFailed,
    }
}

/// Post one line on the membership seat and wait for the room's answer, so a
/// refusal (an observer seat, a line past the room's limit) fails loud the way
/// `subscribe` does instead of vanishing behind a fire-and-forget tell. The
/// answer is the line's own reference, scratch here: this client never edits
/// or withdraws.
fn postLine(session: *driver.Session, allocator: std.mem.Allocator, seat: driver.Capability, line: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    switch (try session.call(seat, proto.post, &.{.{ .string = line }}, arena.allocator())) {
        .fulfilled => {},
        .broken => |reason| {
            std.debug.print("rooms-client: post broke: {s}\n", .{reason});
            return error.PostFailed;
        },
    }
}

/// Enter the room, subscribe our inbox, and pump until every roster member's
/// line has arrived, the transport-neutral body both dial paths share.
fn runRoom(io: std.Io, session: *driver.Session, allocator: std.mem.Allocator, state: *State, room_name: []const u8, nick: []const u8, line: []const u8) !void {
    const directory = try session.fetch(proto.directory);

    // Discovery: list the live rooms once, then watch the directory so the room
    // list's changes print as members come and go. The watcher actor outlives
    // this scope on the connection's vat, receiving deltas as we step below.
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        switch (try session.call(directory, proto.list_publications, &.{}, scratch)) {
            .fulfilled => |arg| try printRooms(nick, arg),
            .broken => |reason| std.debug.print("[{s}] list broke: {s}\n", .{ nick, reason }),
        }
        const watcher = try session.spawn(Watcher, .{ .nick = nick });
        switch (try session.call(directory, proto.watch_publications, &.{.{ .capability = watcher }}, scratch)) {
            .fulfilled => |arg| if (!wire.validWatchSnapshot(arg)) return error.InvalidWatchSnapshot,
            .broken => |reason| std.debug.print("[{s}] watch broke: {s}\n", .{ nick, reason }),
        }
    }

    const room = try enterOrOpen(session, allocator, directory, room_name);
    const inbox = try session.spawn(Inbox, .{ .state = state });

    // Subscribe, handing the room a capability to our inbox. The room answers
    // with the membership seat; the welcome and roster arrive as our first
    // `notify` (the roster line), not as part of that answer.
    const seat = blk: {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const subscribe_args = [_]driver.Value{ .{ .string = nick }, .{ .capability = inbox } };
        switch (try session.call(room, proto.subscribe, &subscribe_args, arena.allocator())) {
            .fulfilled => |arg| break :blk try membershipSeatFromArg(arg),
            .broken => |reason| {
                std.debug.print("rooms-client: subscribe broke: {s}\n", .{reason});
                return error.SubscribeFailed;
            },
        }
    };

    // Bounded like every sibling client: if the roster never completes (a
    // member failed to join), fail loud with the seen-count message below
    // instead of parking the demo in an unbounded socket wait.
    var posted = false;
    const deadline = net.clock.nowMs(io) + roster_wait_budget_ms;
    while (state.seenCount() < state.roster.len) {
        if (net.clock.nowMs(io) >= deadline) break;
        const progress = session.stepReadable(step_poll_ms) catch |err| {
            std.debug.print("rooms-client: step error: {s}\n", .{@errorName(err)});
            break;
        };
        if (state.ended) {
            std.debug.print("rooms-client: the room ended {s}'s membership\n", .{nick});
            return error.MembershipEnded;
        }
        if (!posted and state.allPresent()) {
            try postLine(session, allocator, seat, line);
            posted = true;
        }
        if (progress) |p| {
            if (p == .closed) break;
        }
    }
}

test "a wire null is an unknown count and an absent offer, not a malformed record" {
    const foreign = [_]driver.Value{
        .{ .string = "lobby" },     .void,                    .{ .string = "id-1" },        .{ .string = "foreign" },
        .{ .string = "ocapn://x" }, .{ .string = "session" }, .{ .string = "participant" },
    };
    try std.testing.expectEqual(proto.publication_fields.len, foreign.len);
    const known = wire.roomInfo(&foreign).?;
    try std.testing.expect(known.count == null);
    try std.testing.expectEqualStrings("participant", known.offers.?);
    const closed = [_]driver.Value{
        .{ .string = "lobby" }, .{ .integer = 2 },      .{ .string = "id-2" }, .{ .string = "local" },
        .{ .string = "" },      .{ .string = "local" }, .void,
    };
    try std.testing.expectEqual(@as(?i64, 2), wire.roomInfo(&closed).?.count);
    try std.testing.expect(wire.roomInfo(&closed).?.offers == null);
    // Both enumerations are the generated ones, so a value outside either is a
    // malformed record rather than a row this client prints.
    const bad_offer = [_]driver.Value{
        .{ .string = "lobby" }, .{ .integer = 2 },      .{ .string = "id-3" },    .{ .string = "local" },
        .{ .string = "" },      .{ .string = "local" }, .{ .string = "steward" },
    };
    try std.testing.expect(wire.roomInfo(&bad_offer) == null);
    const bad_proof = [_]driver.Value{
        .{ .string = "lobby" }, .{ .integer = 2 },        .{ .string = "id-4" }, .{ .string = "local" },
        .{ .string = "" },      .{ .string = "hearsay" }, .void,
    };
    try std.testing.expect(wire.roomInfo(&bad_proof) == null);
}

test "malformed and unknown watch callbacks are refused" {
    const malformed = [_]driver.Value{ .{ .string = "opened" }, .{ .string = "only-a-name" } };
    try std.testing.expectError(error.MalformedRoomWatchNotification, wire.watchEvent(&malformed));
    const registered = [_]driver.Value{
        .{ .string = "registered" },
        .{ .string = "ada" },
        .{ .integer = 1 },
        .{ .string = "00000000-0000-4000-8000-000000000001" },
    };
    try std.testing.expect((try wire.watchEvent(&registered)) == null);
    const bad_id = [_]driver.Value{
        .{ .string = "registered" },
        .{ .string = "ada" },
        .{ .integer = 1 },
        .{ .string = "not-a-registration-id" },
    };
    try std.testing.expectError(error.MalformedMemberWatchNotification, wire.watchEvent(&bad_id));
    const truncated = [_]driver.Value{ .{ .string = "truncated" }, .{ .integer = 3 } };
    try std.testing.expect((try wire.watchEvent(&truncated)) == null);
    const unknown = [_]driver.Value{ .{ .string = "renamed" }, .{ .string = "lobby" } };
    try std.testing.expectError(error.UnknownWatchEvent, wire.watchEvent(&unknown));
}

test "a membership-ended notice ends the roster wait and is held to its shape" {
    var present = [_]bool{false};
    var seen = [_]bool{false};
    var state = State{ .nick = "zig", .roster = &.{"ada"}, .present = &present, .seen = &seen };
    const room = driver.Value{ .string = proto.room_sender };
    const tag = driver.Value{ .string = proto.membership_ended };
    const notice = [_]driver.Value{ room, .{ .string = "kicked by the steward" }, tag };
    try readNotify(&state, &notice);
    try std.testing.expect(state.ended);
    try std.testing.expect(!state.present[0]);
    const blank = [_]driver.Value{ room, .{ .string = "" }, tag };
    try std.testing.expectError(error.MalformedMembershipEnded, readNotify(&state, &blank));
    const not_the_room = [_]driver.Value{ .{ .string = "ada" }, .{ .string = "bye" }, tag };
    try std.testing.expectError(error.MalformedMembershipEnded, readNotify(&state, &not_the_room));
    const trailing = [_]driver.Value{ room, .{ .string = "bye" }, tag, .{ .string = "extra" } };
    try std.testing.expectError(error.MalformedMembershipEnded, readNotify(&state, &trailing));
}

test "presence follows the generated tails and the effect each declares" {
    var present = [_]bool{ false, false };
    var seen = [_]bool{ false, false };
    var state = State{ .nick = "zig", .roster = &.{ "ada", "bo" }, .present = &present, .seen = &seen };
    const room = driver.Value{ .string = proto.room_sender };
    const welcome = [_]driver.Value{ room, .{ .string = "welcome" }, .{ .string = "roster" }, .{ .string = "ada" }, .{ .string = "bo" } };
    try readNotify(&state, &welcome);
    try std.testing.expect(state.allPresent());
    const left = [_]driver.Value{ room, .{ .string = "bo left" }, .{ .string = "leave" }, .{ .string = "bo" } };
    try readNotify(&state, &left);
    try std.testing.expect(!state.present[1]);
    // A tail that stays is a fact about a member who is still here, so it moves
    // nobody and counts as nobody's chat line.
    const typing = [_]driver.Value{ room, .{ .string = "" }, .{ .string = "typing" }, .{ .string = "ada" }, .{ .boolean = true } };
    try readNotify(&state, &typing);
    try std.testing.expect(!state.seen[0]);
    // A line from a member is presence too, and the only thing counted as seen.
    const said = [_]driver.Value{ .{ .string = "bo" }, .{ .string = "hi" } };
    try readNotify(&state, &said);
    try std.testing.expect(state.present[1] and state.seen[1]);
}

fn fail(message: []const u8) error{Usage} {
    return demo_usage.usage("usage: glowcap-rooms-client <locator> <room> <nick> <line> [roster]\n  (locator: host:port or an ocapn:// URI; roster: comma-separated nicks to expect; default just you)", message);
}
