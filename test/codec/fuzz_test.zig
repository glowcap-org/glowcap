//! Hostile-bytes fuzz entrypoints for both codecs.
//!
//! Three `std.testing.fuzz` blocks, one per untrusted-input decode surface:
//! the Syrup streaming framer (`decodePrefix`, cap-on-parse per ADR-0029), the
//! Cap'n Proto borrowed decode plus owned projection (the traversal-budget and
//! pointer-arithmetic paths), and the Syrup owned materializer (`decodeOwned`,
//! the multi-allocation partial-failure cleanup path). Under a plain
//! `zig build test` each block replays its seeds without mutating them, which
//! is how a crash the fuzzer once found stays caught.
//!
//! `zig build fuzz` turns the same blocks into live mutation fuzzers. It needs
//! a patched copy of Zig's test runner, which does not compile in fuzz mode in
//! this release; `build.zig` explains that where it wires the copy in.
//!
//! The contract per entrypoint: an arbitrary byte string never panics and
//! never leaks (everything runs under `std.testing.allocator`, which fails the
//! test on either), and a successful decode is re-encodable up to the codec's
//! typed refusals — when the re-encode succeeds, one further decode/encode
//! crossing must reproduce the same bytes exactly (the ADR-0010 perspective
//! flip is an involution, so two crossings are a fixed point).
//!
//! Seeds: the whole checked-in Syrup corpus under `test/oracle/corpus/*.bin`,
//! plus every input the fuzzer has found so far under `fuzz_regressions/`. A
//! build check holds both lists against their directories, so a file that is
//! not wired in fails rather than sitting there looking like coverage. Cap'n
//! Proto has no checked-in byte corpus, so its seeds are encoder output built
//! in the test.

const std = @import("std");
const glowcap = @import("glowcap");

const foundation = glowcap.foundation;
const model = glowcap.ocapn.model;
const syrup = glowcap.ocapn.codec.syrup;
const capnp = glowcap.ocapn.codec.capnp;

/// Inputs the fuzzer found here, replayed by the ordinary suite so a bug it
/// caught cannot come back quietly. `zig build fuzz` prints what to add when it
/// finds one.
const regression_seeds = [_][]const u8{};

/// Upper bound on one fuzz input. Large enough to cover every corpus frame and
/// deeply nested hostile constructions; small enough that the fuzzer spends
/// its budget on structure, not bulk.
const max_input = 4096;

/// The shared seed corpus, so every fuzz target starts from the same shapes.
/// See `test/support/corpus_seeds.zig` for why they live in one place.
const corpus = @import("../support/corpus_seeds.zig");
const message_seeds = corpus.message_seeds;
const corpus_seeds = corpus.all ++ regression_seeds;
const seed = corpus.seed;
const runtimeSeed = corpus.runtimeSeed;

/// Re-encoding a decoded message may refuse through the codec's typed refusals
/// (e.g. a decoded `near` deliver target never re-enters the wire — the
/// ADR-0010 perspective flip makes that pairing reachable from hostile bytes,
/// and `Unsupported*` names it). A refusal ends the property for this input;
/// only allocation failure is a real error.
fn swallowRefusal(err: anyerror) anyerror!void {
    if (err == error.OutOfMemory) return error.OutOfMemory;
}

/// An allocator that runs out of memory where the fuzzer says, shared with the
/// other targets. `test/support/fuzz_budget.zig` explains why it earns its
/// place; the span here is a decoder's worth of allocations.
const Budget = @import("../support/fuzz_budget.zig").Budget;

/// Structural message equality, shared with the fixed cross-codec fixtures.
const messagesEqual = @import("../support/message_equality.zig").messagesEqual;
const decode_span: u16 = 512;

/// Round-trip totality from a successfully decoded message: its re-encoding
/// (when the codec admits it) must decode, and one further crossing must land
/// on the exact same bytes. The flip swaps `near`/`far` arms on each decode,
/// so `frame1` and `frame3` — two crossings apart — are the comparable pair.
fn expectReencodeStability(comptime codec: anytype, gpa: std.mem.Allocator, first: model.Message) anyerror!void {
    var frame1 = codec.encodeMessage(gpa, first) catch |err| return swallowRefusal(err);
    defer frame1.deinit();

    // Encoder output must always decode: totality of decode over encode.
    const second = try codec.decodeOwned(gpa, frame1.view());
    defer model.freeMessage(gpa, second);

    var frame2 = codec.encodeMessage(gpa, second) catch |err| return swallowRefusal(err);
    defer frame2.deinit();

    const third = try codec.decodeOwned(gpa, frame2.view());
    defer model.freeMessage(gpa, third);

    var frame3 = try codec.encodeMessage(gpa, third);
    defer frame3.deinit();

    try std.testing.expectEqualSlices(u8, frame1.bytes(), frame3.bytes());
}

/// The whole Syrup decode surface: the framer, the whole-frame entry, and the
/// round trip out of both.
///
/// These were two targets. `decodeOwned` is `decodeBody` followed by `toOwned`,
/// and `decodePrefix` reaches `toOwned` too, so the two searched one spine with
/// half a budget each and two corpora that could not see each other's finds.
/// The only thing the second had that the first did not is the whole-frame
/// entry point, which is four lines at the end here.
///
/// The framer runs on every input before anything else, so its verdicts keep
/// their share of the feedback even when the search drifts towards inputs that
/// decode.
fn syrupOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var budget = Budget.draw(smith, decode_span);
    const gpa = budget.allocator();

    // Two caps: the small one forces the cap-during-scan verdicts (ADR-0029)
    // onto structurally valid frames too; the large one lets them through to
    // the round trip. A `.decoded` verdict must never consume past either the
    // input or the cap.
    for ([_]usize{ 64, max_input }) |cap| {
        switch (syrup.decodePrefix(input, cap)) {
            .decoded => |decoded| {
                try std.testing.expect(decoded.consumed <= input.len);
                try std.testing.expect(decoded.consumed <= cap);
                const first = decoded.body.toOwned(gpa) catch |err| return budget.refusalEndsIt(err);
                defer model.freeMessage(gpa, first);
                expectReencodeStability(syrup, gpa, first) catch |err| return budget.onlyInducedFailure(err);
            },
            .incomplete, .malformed, .too_large => {},
        }
    }

    // The whole-frame entry, which the framer above never takes: it decodes
    // from a cursor, this one from a frame that is claimed to be complete.
    const owned = syrup.decodeOwned(gpa, .{ .bytes = input, .shape = .byte }) catch |err| return budget.refusalEndsIt(err);
    defer model.freeMessage(gpa, owned);
    expectReencodeStability(syrup, gpa, owned) catch |err| return budget.onlyInducedFailure(err);

    expectCodecsAgree(gpa, owned) catch |err| return budget.onlyInducedFailure(err);
}

/// The two codecs read the same message out of what they each wrote.
///
/// This is the claim the cross-codec fixtures make, checked against messages
/// the fuzzer found rather than the handful somebody thought to write down. A
/// codec pair that disagrees is an interop split: two peers holding the same
/// capability graph, differing about what a partner just said, and neither one
/// wrong on its own terms.
///
/// Both sides are encoded and decoded once, so the perspective flip decode
/// performs applies equally to each and the two are comparable. Encoding may
/// legitimately refuse — a decoded near target never re-enters the wire — and a
/// refusal ends the property rather than failing it.
///
/// One difference is deliberately outside the comparison, and it is worth
/// naming because it is real. Syrup spells a reference to one of our own
/// exports `<desc:export N>`, which ADR-0010 says carries no object-or-promise
/// signal at all: the receiving session is the authority on its own export's
/// kind, so Syrup always reads one back as an object. Cap'n Proto's form does
/// carry the distinction, so it reads back what was sent. Feeding
/// `op_resolve_fulfill_import_promise` through both is enough to see it.
///
/// Whether that is Cap'n Proto being richer than the wire needs, or a place the
/// two ought to be made to agree, is a protocol question and not one a test
/// should settle by choosing the answer that makes it pass. Until it is
/// settled, the comparison holds the codecs to everything the narrower form can
/// carry and says here what it does not.
fn expectCodecsAgree(gpa: std.mem.Allocator, message: model.Message) anyerror!void {
    var as_syrup = syrup.encodeMessage(gpa, message) catch |err| return swallowRefusal(err);
    defer as_syrup.deinit();
    var as_capnp = capnp.encodeMessage(gpa, message) catch |err| return swallowRefusal(err);
    defer as_capnp.deinit();

    const via_syrup = try syrup.decodeOwned(gpa, as_syrup.view());
    defer model.freeMessage(gpa, via_syrup);
    const via_capnp = try capnp.decodeOwned(gpa, as_capnp.view());
    defer model.freeMessage(gpa, via_capnp);

    try std.testing.expect(messagesEqual(neutralizeNearKind(via_syrup), neutralizeNearKind(via_capnp)));
}

/// Read a resolution's near reference back as an object, all the narrower
/// of the two wire forms can say. Everything else is compared as it
/// stands.
fn neutralizeNearKind(message: model.Message) model.Message {
    var out = message;
    switch (out) {
        .resolve => |*resolve| switch (resolve.resolution) {
            .fulfill => |*arg| switch (arg.*) {
                .reference => |*reference| switch (reference.*) {
                    .near => |*near| near.kind = .object,
                    else => {},
                },
                else => {},
            },
            else => {},
        },
        else => {},
    }
    return out;
}

/// Every seed's frame part must still decode, otherwise the corpus silently
/// stops seeding the success paths (the length prefix is `seed`'s replay
/// framing, not part of the frame).
fn ratifySyrupSeeds(entries: []const []const u8) !void {
    for (entries) |entry| {
        try std.testing.expect(syrup.decodePrefix(entry[4..], max_input) == .decoded);
    }
}

test "fuzz: syrup decode is total over arbitrary bytes and round-trips what it accepts" {
    try ratifySyrupSeeds(message_seeds[0..]);
    // `corpus_seeds` is the shared shapes plus `regression_seeds`.
    try std.testing.fuzz({}, syrupOne, .{ .corpus = corpus_seeds[0..] });
}

/// The whole Cap'n Proto decode surface: the header-word arithmetic, the
/// traversal-budget charge pass, and the owned projection.
///
/// These were two targets, and the framer one threw away the body it had
/// already decoded — `decodePrefix` calls `decodeBody` on the way to a
/// `.decoded` verdict. So it was this target minus the interesting half, plus
/// the length arithmetic, running on its own budget against its own corpus.
///
/// The cap loop runs on every input before the projection, so the framing
/// verdicts keep their share of the feedback.
fn capnpOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var raw: [max_input]u8 = undefined;
    const input = raw[0..smith.slice(&raw)];
    var budget = Budget.draw(smith, decode_span);
    const gpa = budget.allocator();

    // A Cap'n Proto frame is word storage: copy into an aligned buffer and
    // truncate to whole words, the shape the netlayer guarantees before the
    // codec ever sees the bytes.
    var words: [max_input]u8 align(8) = undefined;
    const word_len = input.len - (input.len % 8);
    @memcpy(words[0..word_len], input[0..word_len]);
    const frame = foundation.FrameView{ .bytes = words[0..word_len], .shape = .word };

    // Two caps, the same pair the Syrup framer is fuzzed at. The small one
    // forces the cap verdict onto frames that are otherwise well formed. A
    // length that reaches past the buffer, or past the cap that admitted it, is
    // how a length-prefixed framer hands the layer above storage nobody filled.
    for ([_]usize{ 64, max_input }) |cap| {
        switch (capnp.decodePrefix(frame.bytes, cap)) {
            .decoded => |decoded| {
                try std.testing.expect(decoded.consumed <= frame.bytes.len);
                try std.testing.expect(decoded.consumed <= cap);
            },
            .incomplete, .malformed, .too_large => {},
        }
    }

    // `decodeBody` runs the eager traversal-budget charge pass over the raw
    // pointer graph; `toOwned` then exercises the lazy view walks and the
    // multi-allocation materializer.
    const body = capnp.decodeBody(frame) catch return;
    const first = body.toOwned(gpa) catch |err| return budget.refusalEndsIt(err);
    defer model.freeMessage(gpa, first);
    expectReencodeStability(capnp, gpa, first) catch |err| return budget.onlyInducedFailure(err);
}

test "fuzz: capnp decode is total over arbitrary word frames and round-trips what it accepts" {
    const gpa = std.testing.allocator;

    const args = [_]model.Argument{ .{ .bytes = "hello" }, .{ .integer = 7 } };
    var deliver_frame = try capnp.encodeMessage(gpa, .{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(0) } },
        .args = args[0..],
        .answer = .from(11),
    } });
    defer deliver_frame.deinit();
    var resolve_frame = try capnp.encodeMessage(gpa, .{ .resolve = .{
        .answer = .from(3),
        .resolution = .{ .fulfill = .{ .string = "done" } },
    } });
    defer resolve_frame.deinit();

    var buf0: [4 + 256]u8 = undefined;
    var buf1: [4 + 256]u8 = undefined;
    // The regressions ride along with the shaped seeds. Without them a crash
    // this target found and an author saved has no way back into the ordinary
    // suite, which is the whole point of keeping the file.
    var corpus_with_regressions: [2 + regression_seeds.len][]const u8 = undefined;
    corpus_with_regressions[0] = runtimeSeed(&buf0, deliver_frame.bytes());
    corpus_with_regressions[1] = runtimeSeed(&buf1, resolve_frame.bytes());
    for (regression_seeds, 0..) |entry, i| corpus_with_regressions[2 + i] = entry;
    try std.testing.fuzz({}, capnpOne, .{ .corpus = corpus_with_regressions[0..] });
}

fn handoffGiveOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    const gpa = std.testing.allocator;

    // These bytes reach the signature check, so a parser slip here is a slip in
    // the one place a third party's claim is weighed. The decode allocates in
    // several steps, and a refusal partway has to release what it took.
    if (syrup.decodeSignedHandoffGiveOwned(gpa, input)) |give| {
        model.freeHandoffGive(gpa, give);
    } else |_| {}
}

test "fuzz: standalone handoff give decode is total" {
    const give = seed(@embedFile("../oracle/corpus/desc_handoff_give_signed.bin"));
    const receive = seed(@embedFile("../oracle/corpus/desc_handoff_receive_signed.bin"));
    // Plus the regressions, for the reason the target above gives.
    try std.testing.fuzz({}, handoffGiveOne, .{ .corpus = ([_][]const u8{ give, receive } ++ regression_seeds)[0..] });
}
