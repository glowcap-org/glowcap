//! The engine under an allocator that refuses.
//!
//! Every mutation prepares its fallible work before its commit point, so an
//! allocation refused in the middle of a legitimate program leaves the pair in
//! one of two states: both sessions open and agreeing about every row, or the
//! session the refusal reached closed under `resource_exhausted` because the
//! embedder could not offer the frame again. A third state, both open and
//! disagreeing, is a mutation that committed half of its effect, and a closed
//! session blaming the partner is a shortage reported as a protocol error.
//! Either is a finding. Nothing may leak on any path, and nothing may panic.
//!
//! The program is the same legitimate traffic the fuzz targets drive
//! (`support/fuzz_program.zig`), replayed byte for byte with the refusal moved
//! one allocation later each run, so every allocation site the program reaches
//! is refused once. A second sweep refuses every allocation from the index on,
//! the lasting shortage, and holds the same relation.

const std = @import("std");
const glowcap = @import("glowcap");
const engine = glowcap.ocapn.engine;
const pairing = engine.pairing;
const program = @import("../support/fuzz_program.zig");
const agreement = @import("oracle").agreement;
const FailingOnce = @import("../support/failing_once.zig").FailingOnce;

/// Steps per program. Enough to build answers, listeners, imports, and
/// releases on both sides; each run replays them all.
const steps = 160;
/// Draw bytes per program: eight per draw, and a step draws a handful.
const draw_bytes = 1 << 15;
/// Distinct programs per sweep. Each seed fills its draws from a PRNG so the
/// programs differ in shape while every run of one seed is identical.
const seeds = [_]u64{ 0x5bd1e995, 0x9e3779b9 };

const RunError = error{
    /// The refusal landed in pairing, before the program began.
    SetupRefused,
    /// A session closed, and the abort it recorded was not a shortage.
    ClosedForAnotherReason,
    /// Both sessions are open and read a row differently.
    Disagreement,
};

/// One program under one allocator. `negotiated` picks the glowcap-next pair
/// over the CapTP 1.0 Syrup pair, so both profiles meet every refusal. Under
/// `lasting` pressure every allocation after the first refused one fails too,
/// so a pair whose steps keep failing has work it can never finish: it is
/// stalled, not disagreeing, and only its closes and its balance are judged.
fn run(gpa: std.mem.Allocator, draws: []const u8, negotiated: bool, lasting: bool) anyerror!void {
    var smith: std.testing.Smith = .{ .in = draws };
    var pair = (if (negotiated) pairing.paired(gpa) else pairing.pairedWithLimits(gpa, .syrup, .{})) catch
        return error.SetupRefused;
    defer pair.deinit();
    var step: usize = 0;
    while (step < steps) : (step += 1) {
        const on_p1 = smith.valueRangeAtMost(u8, 0, 1) == 0;
        const actor = if (on_p1) &pair.p1 else &pair.p2;
        const partner = if (on_p1) &pair.p2 else &pair.p1;
        try program.legitimateOp(&smith, actor, partner);
    }
    program.settle(&pair.p1, &pair.p2) catch |err| switch (err) {
        error.PairDidNotSettle => if (lasting) {
            try expectClosedForMemory(&pair.p1);
            try expectClosedForMemory(&pair.p2);
            return;
        } else return err,
        else => return err,
    };
    if (!pair.p1.sessionIsOpen() or !pair.p2.sessionIsOpen()) {
        try expectClosedForMemory(&pair.p1);
        try expectClosedForMemory(&pair.p2);
        return;
    }
    if (agreement.find(&pair.p1, &pair.p2)) |finding| {
        std.debug.print("disagreement: {any}\n", .{finding});
        return error.Disagreement;
    }
}

/// A closed session recorded a shortage, or it closed because its partner's
/// abort reached it. Any other recorded cause blames the partner for memory.
fn expectClosedForMemory(peer: *const engine.Peer) RunError!void {
    if (peer.sessionIsOpen()) return;
    const abort = peer.lastAbort() orelse {
        std.debug.print("closed with no recorded cause\n", .{});
        return error.ClosedForAnotherReason;
    };
    if (abort.kind) |kind| {
        if (kind == .resource_exhausted) return;
    } else if (std.mem.eql(u8, abort.error_name, "OutOfMemory")) return;
    std.debug.print("closed for {?s}: {s} ({s})\n", .{ if (abort.kind) |k| @tagName(k) else null, abort.message, abort.error_name });
    return error.ClosedForAnotherReason;
}

/// Draw words for one program. A replayed draw is a little-endian word, and a
/// word outside the range its consumer asks for falls back to that range's
/// minimum, so the words stay small: most fit the operation menu and the
/// peer pick, and one in eight reaches the wider answer positions.
fn fill(seed: u64) [draw_bytes]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var out: [draw_bytes]u8 = undefined;
    var cursor: usize = 0;
    while (cursor < draw_bytes) : (cursor += 8) {
        const word: u64 = if (random.int(u3) == 0) random.intRangeAtMost(u64, 8, 40) else random.intRangeAtMost(u64, 0, 7);
        std.mem.writeInt(u64, out[cursor..][0..8], word, .little);
    }
    return out;
}

/// Judge one run's end state and allocator balance, naming the refusal site
/// when either fails.
fn judge(outcome: anyerror!void, balanced: bool, trace: ?std.debug.StackTrace, fail_index: usize) !void {
    const failed = if (outcome) |_| false else |err| switch (err) {
        error.SetupRefused => false,
        else => true,
    };
    if (!failed and balanced) return;
    std.debug.print("allocation {d} refused: outcome {any}, balanced {}\n", .{ fail_index, outcome, balanced });
    if (trace) |t| std.debug.dumpStackTrace(&t);
    if (failed) return outcome;
    return error.Leak;
}

test "one refused allocation at every site leaves the pair agreeing or closed for memory" {
    for (seeds) |seed| {
        const draws = fill(seed);
        for ([_]bool{ false, true }) |negotiated| {
            var fail_index: usize = 0;
            while (true) : (fail_index += 1) {
                var failing = FailingOnce.init(std.testing.allocator, fail_index);
                const outcome = run(failing.allocator(), &draws, negotiated, false);
                if (!failing.induced) break;
                try judge(outcome, failing.balanced(), failing.stackTrace(), fail_index);
            }
        }
    }
}

test "a lasting shortage from any site on leaves the pair agreeing or closed for memory" {
    for (seeds) |seed| {
        const draws = fill(seed);
        for ([_]bool{ false, true }) |negotiated| {
            var fail_index: usize = 0;
            while (true) : (fail_index += 1) {
                var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
                const outcome = run(failing.allocator(), &draws, negotiated, true);
                if (!failing.has_induced_failure) break;
                const balanced = failing.allocated_bytes == failing.freed_bytes;
                try judge(outcome, balanced, failing.getStackTrace(), fail_index);
            }
        }
    }
}
