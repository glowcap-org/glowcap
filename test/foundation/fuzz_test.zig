//! Untrusted-bytes fuzzing of the sealed channel, against a live pair.
//!
//! The channel is the one piece of glowcap that stands between a network
//! attacker and every CapTP byte on a `noise-tcp` or `noise-relay` session,
//! so its refusals are the ones that matter most: a handshake message that
//! was tampered with, a record whose tag does not verify, a length header
//! that promises more than arrived. The Noise test vectors prove the
//! transcript and the unit tests pin each refusal by hand. What neither
//! reaches is the space between: bytes that are nearly right, at a boundary
//! the ingest arithmetic did not expect, in a phase the sender did not mean.
//!
//! So the fuzzer drives a program rather than a buffer. An initiator and a
//! responder stand at either end, and each step either moves one side's
//! honest wire bytes across, split where the fuzzer chooses, or seals a frame
//! and moves that, or damages a unit the honest side produced and feeds it
//! anyway, or feeds the fuzzer's own bytes. Over a few dozen steps that
//! reaches an open channel with records in flight, and then attacks it.
//!
//! Four properties are checked, and only the first is about crashing.
//!
//! Nothing crashes and nothing leaks, whatever the program was. An
//! allocation failure the run asked for ends the run, and the channel it
//! interrupted still tears down clean.
//!
//! A `consumed` count never passes the bytes offered, and a step that moves
//! nothing says `need_input`. Both are the arithmetic slips a split-unit
//! reader makes, and neither crashes on the machine that made it.
//!
//! No plaintext comes out of a damaged unit. A handshake message with a byte
//! flipped never advances the transcript, and a record with a byte flipped
//! never yields a `plaintext` event: the only answers are a refusal, which
//! retires the channel, or a wait for more input.
//!
//! Honest bytes are never refused by a channel nobody has attacked, and the
//! plaintext a sealed frame yields is exactly the framed bytes that went in.
//!
//! Validated by injecting one defect per property and watching the seeds
//! catch it: a record whose tag is ignored, a handshake whose payload
//! decrypt is ignored, a `consumed` count one past the bytes, a second copy
//! of each handshake message that nobody frees, and a plaintext missing its
//! last byte. What it cannot reach: a peer holding a different key or
//! presenting a forged identity proof, which needs a second honest identity
//! rather than damage (`driver/sealed_channel_test.zig` holds those), a
//! replayed message at a fresh channel (same file), and a record longer than
//! one chunk, since `max_chunk` keeps every damaged unit to one record.

const std = @import("std");
const glowcap = @import("glowcap");

const crypto = glowcap.foundation.crypto;
const sealed = glowcap.foundation.sealed;
const noise = glowcap.foundation.noise;
const stream_framing = glowcap.foundation.stream_framing;
const Budget = @import("../support/fuzz_budget.zig").Budget;

/// Inputs the fuzzer found here, replayed by the ordinary suite so a bug it
/// caught cannot come back quietly. `zig build fuzz` prints what to add when it
/// finds one.
const regression_seeds = [_][]const u8{};

const transport = "noise-tcp";
/// One step's chunk: the frame a side seals, or the bytes the fuzzer feeds.
/// Under one record's plaintext, so a damaged unit is exactly one record.
const max_chunk = 1024;
const max_steps = 48;
/// How far into a run the drawn allocation failure may land.
const span = 128;

/// Program draws, named so a seed cannot miscount them.
const act_move: u64 = 0;
const act_seal: u64 = 1;
const act_seal_back: u64 = 2;
const act_damage: u64 = 3;
const act_inject: u64 = 4;

/// One end of the pair, with whether an attack has touched it. A channel an
/// attack touched may refuse honest bytes afterwards, since whatever it
/// staged is now ahead of them, so the honest-bytes property holds only for
/// a channel nothing has touched.
const End = struct {
    channel: sealed.SealedChannel,
    tainted: bool = false,
};

const Pair = struct {
    a: End,
    b: End,

    fn init() !Pair {
        const a_identity = crypto.SecretKey.fromSeed(@splat(1));
        const b_identity = crypto.SecretKey.fromSeed(@splat(2));
        return .{
            .a = .{ .channel = try sealed.SealedChannel.initInitiator(&a_identity, b_identity.publicKey(), @splat(3), transport) },
            .b = .{ .channel = try sealed.SealedChannel.initResponder(&b_identity, @splat(4), transport) },
        };
    }

    fn deinit(self: *Pair, gpa: std.mem.Allocator) void {
        self.a.channel.deinit(gpa);
        self.b.channel.deinit(gpa);
    }
};

/// What a feed may legitimately answer.
const Expect = enum {
    /// Honest bytes: every event is allowed and plaintext is collected.
    honest,
    /// A damaged unit: a refusal or a wait, never progress.
    no_progress,
    /// The fuzzer's own bytes: anything the channel answers, short of a crash.
    anything,
};

/// Feed `bytes` to `end` in the pieces a read boundary might cut them into,
/// checking the arithmetic on every step. `out` collects plaintext.
fn feed(
    gpa: std.mem.Allocator,
    end: *End,
    bytes: []const u8,
    split_at: usize,
    expect: Expect,
    out: ?*std.ArrayList(u8),
) !void {
    const cut = @min(split_at, bytes.len);
    try feedPiece(gpa, end, bytes[0..cut], expect, out);
    try feedPiece(gpa, end, bytes[cut..], expect, out);
}

fn feedPiece(gpa: std.mem.Allocator, end: *End, piece: []const u8, expect: Expect, out: ?*std.ArrayList(u8)) !void {
    var offset: usize = 0;
    while (offset < piece.len) {
        const open_before = end.channel.isOpen();
        const step = end.channel.ingest(gpa, piece[offset..]) catch |err| {
            if (err == error.OutOfMemory) {
                // Pressure consumes nothing and retires nothing.
                try std.testing.expectEqual(open_before, end.channel.isOpen());
                return err;
            }
            // A refusal retires the channel: no key survives, nothing is
            // pending to write, and the next byte moves nothing.
            try std.testing.expect(!end.channel.isOpen());
            try std.testing.expect(!end.channel.hasPendingWire());
            const after = try end.channel.ingest(gpa, piece[offset..]);
            try std.testing.expectEqual(@as(usize, 0), after.consumed);
            try std.testing.expect(after.event == .need_input);
            if (expect == .honest and !end.tainted) return error.HonestBytesRefused;
            return;
        };
        try std.testing.expect(step.consumed <= piece.len - offset);
        switch (step.event) {
            .need_input => {
                // A retired channel moves nothing. A live one took every
                // byte it was offered and wants more.
                if (step.consumed == 0) return;
            },
            .handshake, .completed => {
                try std.testing.expect(step.consumed > 0);
                if (expect == .no_progress) return error.DamagedHandshakeAdvanced;
            },
            .plaintext => |plain| {
                try std.testing.expect(step.consumed > 0);
                defer end.channel.releasePlaintext();
                if (expect == .no_progress) return error.DamagedRecordOpened;
                if (out) |sink| try sink.appendSlice(std.testing.allocator, plain);
            },
        }
        offset += step.consumed;
    }
}

/// Move the actor's honest bytes to the partner: a pending handshake message
/// if one waits, otherwise a sealed frame carrying `chunk`, whose plaintext
/// must come out exactly as the framed bytes went in.
fn honest(gpa: std.mem.Allocator, actor: *End, partner: *End, chunk: []const u8, split_at: usize) !void {
    if (actor.channel.hasPendingWire()) {
        var wire = (try actor.channel.takeWire(gpa)).?;
        defer wire.deinit();
        return feed(gpa, partner, wire.bytes(), split_at, .honest, null);
    }
    if (!actor.channel.isOpen()) return;
    var wire = try actor.channel.sealFrame(gpa, chunk);
    defer wire.deinit();
    const verify = partner.channel.isOpen() and !partner.tainted;
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(std.testing.allocator);
    try feed(gpa, partner, wire.bytes(), split_at, .honest, if (verify) &got else null);
    if (!verify) return;
    var prefix_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
    const prefix = stream_framing.renderPrefix(&prefix_buf, chunk.len);
    try std.testing.expectEqual(prefix.len + chunk.len, got.items.len);
    try std.testing.expectEqualSlices(u8, prefix, got.items[0..prefix.len]);
    try std.testing.expectEqualSlices(u8, chunk, got.items[prefix.len..]);
}

/// One honest unit, a handshake message or a single record, with a few
/// bytes flipped, fed to the partner, which must make no progress on it.
fn damaged(gpa: std.mem.Allocator, smith: *std.testing.Smith, actor: *End, partner: *End, chunk: []const u8) !void {
    var unit: std.ArrayList(u8) = .empty;
    defer unit.deinit(gpa);
    if (actor.channel.hasPendingWire()) {
        try actor.channel.takeWireInto(gpa, &unit);
    } else if (actor.channel.isOpen()) {
        // At least one byte, so a record exists to damage.
        try actor.channel.sealBytes(gpa, &unit, if (chunk.len == 0) "x" else chunk);
    } else return;
    if (unit.items.len == 0) return;

    // Each flip lands on a position no earlier flip used, so two flips status-allow: event or source ordering
    // cannot cancel and hand the partner the honest unit after all.
    const flips = smith.valueRangeAtMost(u8, 1, 4);
    var used: [4]usize = undefined;
    var used_len: usize = 0;
    var i: u8 = 0;
    while (i < flips) : (i += 1) {
        const at = smith.valueRangeAtMost(u16, 0, @intCast(unit.items.len - 1));
        var seen = false;
        for (used[0..used_len]) |u| seen = seen or u == at;
        if (seen) continue;
        used[used_len] = at;
        used_len += 1;
        unit.items[at] ^= smith.valueRangeAtMost(u8, 1, 255);
    }
    partner.tainted = true;
    const split_at = smith.valueRangeAtMost(u16, 0, @intCast(unit.items.len));
    try feed(gpa, partner, unit.items, split_at, .no_progress, null);
}

fn programOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var budget = Budget.draw(smith, span);
    const gpa = budget.allocator();

    var pair = Pair.init() catch return;
    defer pair.deinit(gpa);

    // Every error out of a step is a property that did not hold, except the
    // allocation failure this run asked for: refusals of untrusted bytes are
    // answered inside `feedPiece`, never raised.
    run(gpa, smith, &pair) catch |err| return budget.onlyInducedFailure(err);
}

/// The program itself, over a pair the caller owns, so a seed can be
/// replayed and its end state inspected.
fn run(gpa: std.mem.Allocator, smith: *std.testing.Smith, pair: *Pair) !void {
    var chunk: [max_chunk]u8 = undefined;
    var step: usize = 0;
    while (step < max_steps) : (step += 1) {
        // The chunk is drawn first because that is how a seed is framed: a
        // length then the bytes.
        const len = smith.slice(&chunk);
        if (smith.eos()) break;

        const on_a = smith.valueRangeAtMost(u8, 0, 1) == 0;
        const actor = if (on_a) &pair.a else &pair.b;
        const partner = if (on_a) &pair.b else &pair.a;

        // Attacks are the top of the range, not the bottom: a draw past the
        // input falls back to the low end, and the honest steps are what
        // build the open channel the attacks need.
        switch (smith.valueRangeAtMost(u8, 0, 4)) {
            act_damage => try damaged(gpa, smith, actor, partner, chunk[0..len]),
            act_inject => {
                partner.tainted = true;
                try feed(gpa, partner, chunk[0..len], len, .anything, null);
            },
            else => try honest(gpa, actor, partner, chunk[0..len], smith.valueRangeAtMost(u16, 0, max_chunk)),
        }

        // Once both ends are retired, every later step moves nothing.
        if (pair.a.channel.phase == .failed and pair.b.channel.phase == .failed) break;
    }
}

/// One step of a seed program. `draws` are the step's own draws after the
/// action, in the order the arm makes them: a split point for an honest
/// move, then flips, position, mask, and split for a damaged unit, and
/// nothing for injected bytes. An arm that draws a different number than its
/// row carries shifts every later row, so each seed's end state is checked.
const Step = struct { chunk: []const u8, side: u64, action: u64, draws: []const u64 };

/// A seed is a program: the opening allocation draw, then per step a chunk,
/// a not-the-end byte, the side, the action, and the arm's draws.
fn programSeed(comptime steps: []const Step) []const u8 {
    const bytes = comptime blk: {
        var out: []const u8 = &.{};
        out = out ++ draw(0);
        for (steps) |s| {
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @as(u32, @intCast(s.chunk.len)), .little);
            out = out ++ len_buf ++ s.chunk ++ [_]u8{0} ++ draw(s.side) ++ draw(s.action);
            for (s.draws) |d| out = out ++ draw(d);
        }
        break :blk out;
    };
    return bytes;
}

/// Flip one bit of a unit's third byte: past a record's length header, so
/// the partner reads a whole unit and refuses its tag, and inside a
/// handshake message's ephemeral key.
const flip_body = [_]u64{ 1, 2, 1, 0 };
/// Flip one bit of a record's first byte, the length header, so the partner
/// waits for the bytes the header now promises.
const flip_header = [_]u64{ 1, 0, 1, 0 };

fn draw(comptime v: u64) [8]u8 {
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, v, .little);
    return out;
}

fn drawsOf(comptime draws: []const u64) []const u8 {
    const bytes = comptime blk: {
        var out: []const u8 = &.{};
        for (draws) |d| out = out ++ draw(d);
        break :blk out;
    };
    return bytes;
}

/// Run a seed as `programOne` would, over a pair the caller keeps.
fn replay(gpa: std.mem.Allocator, seed: []const u8) !Pair {
    var reader: std.testing.Smith = .{ .in = seed };
    _ = Budget.draw(&reader, span);
    var pair = try Pair.init();
    errdefer pair.deinit(gpa);
    try run(gpa, &reader, &pair);
    return pair;
}

/// The handshake, split at a few places, then one sealed frame each way.
const open_program = programSeed(&.{
    .{ .chunk = "", .side = 0, .action = act_move, .draws = &.{7} },
    .{ .chunk = "", .side = 1, .action = act_move, .draws = &.{0} },
    .{ .chunk = "", .side = 0, .action = act_move, .draws = &.{100} },
    .{ .chunk = "<hello>", .side = 0, .action = act_seal, .draws = &.{3} },
    .{ .chunk = "<reply>", .side = 1, .action = act_seal_back, .draws = &.{0} },
});

/// The handshake, a record with a damaged header at one side, which waits,
/// a record with a damaged body at the other, which retires, then raw
/// bytes at the waiting side.
const attack_program = programSeed(&.{
    .{ .chunk = "", .side = 0, .action = act_move, .draws = &.{0} },
    .{ .chunk = "", .side = 1, .action = act_move, .draws = &.{0} },
    .{ .chunk = "", .side = 0, .action = act_move, .draws = &.{0} },
    .{ .chunk = "<forged>", .side = 0, .action = act_damage, .draws = &flip_header },
    .{ .chunk = "<forged>", .side = 1, .action = act_damage, .draws = &flip_body },
    .{ .chunk = "\x00\x10garbage", .side = 0, .action = act_inject, .draws = &.{} },
});

/// A damaged first message, before any key is shared, then raw bytes at
/// the initiator.
const cold_program = programSeed(&.{
    .{ .chunk = "", .side = 0, .action = act_damage, .draws = &flip_body },
    .{ .chunk = "\x00\x10garbage", .side = 1, .action = act_inject, .draws = &.{} },
});

const program_seeds = [_][]const u8{ open_program, attack_program, cold_program };

test "fuzz: no program of handshake steps and untrusted bytes crashes or leaks a sealed channel" {
    // The honest program has to open the channel and round-trip a frame,
    // otherwise every attack runs against a cold channel and the whole point
    // of this target is gone with no failing test to say so.
    {
        const gpa = std.testing.allocator;
        var pair = try Pair.init();
        defer pair.deinit(gpa);
        try honest(gpa, &pair.a, &pair.b, "", 7);
        try honest(gpa, &pair.b, &pair.a, "", 0);
        try honest(gpa, &pair.a, &pair.b, "", 100);
        try std.testing.expect(pair.a.channel.isOpen() and pair.b.channel.isOpen());
        try honest(gpa, &pair.a, &pair.b, "<hello>", 3);
        try honest(gpa, &pair.b, &pair.a, "<reply>", 0);
        try std.testing.expect(pair.a.channel.isOpen() and pair.b.channel.isOpen());
    }

    // The damaged arm has to retire the channel it attacks. If it never
    // produced a unit the arm silently does nothing, the same shape as a
    // refusal nobody can see.
    {
        const gpa = std.testing.allocator;
        var pair = try Pair.init();
        defer pair.deinit(gpa);
        try honest(gpa, &pair.a, &pair.b, "", 0);
        try honest(gpa, &pair.b, &pair.a, "", 0);
        try honest(gpa, &pair.a, &pair.b, "", 0);
        var reader: std.testing.Smith = .{ .in = drawsOf(&flip_body) };
        try damaged(gpa, &reader, &pair.a, &pair.b, "<forged>");
        try std.testing.expect(!pair.b.channel.isOpen());
        try std.testing.expect(pair.a.channel.isOpen());
    }

    // A flip inside the length header is the other legitimate answer: the
    // partner waits for the bytes the header now promises and stays open,
    // and no plaintext comes out while it waits.
    {
        const gpa = std.testing.allocator;
        var pair = try Pair.init();
        defer pair.deinit(gpa);
        try honest(gpa, &pair.a, &pair.b, "", 0);
        try honest(gpa, &pair.b, &pair.a, "", 0);
        try honest(gpa, &pair.a, &pair.b, "", 0);
        var reader: std.testing.Smith = .{ .in = drawsOf(&flip_header) };
        try damaged(gpa, &reader, &pair.a, &pair.b, "<forged>");
        try std.testing.expect(pair.b.channel.isOpen());
        try std.testing.expect(pair.b.channel.hasStagedInbound());
    }

    // Every seed runs the program its comment describes, replayed through
    // the real loop and judged by where it leaves the pair. A row whose
    // draws do not match its arm shifts every later row, and the end state
    // is what notices.
    {
        const gpa = std.testing.allocator;
        var open = try replay(gpa, open_program);
        defer open.deinit(gpa);
        try std.testing.expect(open.a.channel.isOpen() and open.b.channel.isOpen());
        try std.testing.expect(!open.a.tainted and !open.b.tainted);

        var attacked = try replay(gpa, attack_program);
        defer attacked.deinit(gpa);
        try std.testing.expect(!attacked.a.channel.isOpen());
        try std.testing.expect(attacked.b.channel.isOpen() and attacked.b.channel.hasStagedInbound());
        try std.testing.expect(attacked.a.tainted and attacked.b.tainted);

        var cold = try replay(gpa, cold_program);
        defer cold.deinit(gpa);
        // The responder is retired: a live handshake would stage the byte.
        const after = try cold.b.channel.ingest(gpa, "x");
        try std.testing.expectEqual(@as(usize, 0), after.consumed);
        try std.testing.expect(cold.a.channel.hasStagedInbound());
    }

    try std.testing.fuzz({}, programOne, .{ .corpus = (program_seeds ++ regression_seeds)[0..] });
}
