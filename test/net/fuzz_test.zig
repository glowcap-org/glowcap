//! Hostile-bytes fuzzing of blocking frame reads, spill and all.
//!
//! `readFrameFrom` is what the blocking session calls to get one frame off a
//! stream. It has a job the frame parsers do not: a frame bigger than the read
//! buffer cannot be decoded in place, so it accumulates in a spill and is
//! decoded from there instead, and the spill is freed again when it drains
//! (ADR-0041). That handover between two supplies is the part worth fuzzing.
//!
//! Reaching it takes a particular geometry, and getting the geometry wrong is
//! silent. Over a reader whose buffer already holds the whole input, a frame is
//! always decoded straight out of that buffer: the spill absorbs once when the
//! bytes run short and then can never be topped up, so it is never decoded from
//! and never drained. The path looks exercised and is not. So the read buffer
//! here is small and bounded, and the stream arrives in pieces the fuzzer
//! chooses, forcing a frame to cross the boundary and go through the spill
//! for real.
//!
//! What is asserted beyond not crashing and not leaking: a spill that is not
//! accumulating anything has freed its storage, not merely emptied it. That is
//! the whole reason this is a spill rather than a buffer per connection, and it
//! is the kind of property that stays true until one refactor makes it false
//! and nothing says so.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const codec = pancake.ocapn.codec;
const net = pancake.net;

/// Every shape in the checked-in corpus, so the search starts from bytes that
/// decode instead of rediscovering what a frame looks like.
const seeds = @import("../support/corpus_seeds.zig");

const bounds = @import("fuzz/bounds.zig");
const max_input = bounds.max_input;
const frame_cap = bounds.frame_cap;

/// Inputs the fuzzer found here, replayed by the ordinary suite so a bug it
/// caught cannot come back quietly. `zig build fuzz` prints what to add when it
/// finds one.
const regression_seeds = [_][]const u8{};

fn readOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    const gpa = std.testing.allocator;

    // The geometry comes out of the drawn bytes, not from separate draws.
    // A draw made after `smith.slice` has consumed the input returns the low
    // end of its range on every replay, so a saved crash would replay under a
    // one-byte read buffer and one-byte reads whatever geometry the fuzzer
    // actually found it with — which for a target whose whole subject is the
    // handover between two supplies is the wrong geometry every time.
    var read_buf: [64]u8 = undefined;
    const read_len: usize = 1 + @as(usize, if (input.len > 0) input[0] % 63 else 0);

    // The stream in pieces. Sized so the pieces can span the whole input: a
    // fixed small piece silently truncates anything past `calls.len` bytes.
    var calls: [64]std.testing.Reader.Call = undefined;
    const min_piece = std.math.divCeil(usize, input.len, calls.len) catch 1;
    const piece: usize = @max(min_piece, 1 + @as(usize, if (input.len > 1) input[1] % 127 else 0));
    var call_count: usize = 0;
    var at: usize = 0;
    while (at < input.len and call_count < calls.len) : (call_count += 1) {
        const end = @min(at + piece, input.len);
        calls[call_count] = .{ .buffer = input[at..end] };
        at = end;
    }

    // Both codecs, because the framing decision is per codec and only one of
    // them is length-prefixed.
    for ([_]model.CodecId{ .syrup, .capnp }) |codec_id| {
        var test_reader = std.testing.Reader.init(read_buf[0..read_len], calls[0..call_count]);
        const reader = &test_reader.interface;
        var spill: net.Spill = .{};
        var scan: net.StreamScan = .{};
        defer spill.deinit(gpa);

        // Keep reading until the stream refuses or runs out. A frame that ends
        // part-way through the buffer leaves the rest for the next read, which
        // is the case that builds and drains the spill. The count is a bound on
        // this harness, not on the code: a stream of tiny valid frames would
        // otherwise spend the whole budget in one input.
        var frames: usize = 0;
        while (frames < 64) : (frames += 1) {
            var frame = net.readFrameFrom(reader, gpa, codec_id, frame_cap, &spill, &scan) catch break;
            frame.deinit();

            // A drained spill has freed its storage, not merely emptied it.
            if (!spill.isActive()) {
                try std.testing.expectEqual(@as(usize, 0), spill.buf.len);
            }
            // And an active one stays inside what it holds and inside the cap
            // that admitted it. This is ADR-0041's boundedness, checked while
            // the spill is live rather than assumed.
            try std.testing.expect(spill.len <= spill.buf.len);
            try std.testing.expect(spill.len <= frame_cap + 32 + read_len);
        }
    }
}

test "fuzz: arbitrary stream bytes never crash or leak a blocking frame read" {
    // Every shape in the corpus, not a hand-picked few: a shape the search
    // never starts from is a shape it will almost certainly never build.
    try std.testing.fuzz({}, readOne, .{ .corpus = (seeds.all ++ regression_seeds)[0..] });
}

// ── The completion loop's lifecycle accounting, under arbitrary schedules ────
//
// This target exists because of how the loop's bugs kept being found. The same
// class surfaced over and over: a counter released on one path and not another,
// a stamp that had to survive a state change and did not, an identity cleared
// by the assignment that handed the slot to somebody else. Every one was found
// by a person reading carefully, and every fix added one more site that has to
// remember.
//
// Reading does not scale to the combinations. The loop's derived state — how
// many connections carry a deadline, how many sit over the outbound mark, how
// many closes it still owes, which slots are free — is maintained across dozens
// of mutation sites, and what breaks it is an *ordering*: a close arriving
// between a park and a drain, a partial write on a slot already draining, a
// teardown while a slot is being adopted. A fuzzer chooses orderings for free.
//
// So the backend below is driven entirely by the fuzzer: it decides which
// outstanding operation completes next, whether it succeeds, how much of a
// write went out, how many complete together, and whether the loop is even
// allowed to queue a close or re-arm an accept. After the schedule runs out the
// loop is drained and every derived count is compared against a walk of the
// slots. A count that drifts is exactly the defect these reviews kept catching,
// and here it fails the build instead.
//
// A property test that passes proves nothing on its own, so this one was built
// against defects rather than against the passing tree. Each of these was
// injected into the loop and the search asked to find it, and each was found:
// a batch abandoned after a failing completion; a deadline release skipped on
// one path; a retried close that forgets
// its counter; a closing connection that keeps its deadline stamp; one that
// keeps its outbound over-mark; a reclaimed slot that never returns to the free
// list; and a slot adopted without advancing its generation. Two of those had
// escaped an earlier version of this file, and the escapes are what shaped it:
// the backend hands back several completions at once because a batch of one can
// never show the batch contract failing, and the closing-connection properties
// are stated outright because a count compared against a walk of the same field
// agrees with itself even when both have drifted.
//
// What it reaches and what it does not, counted rather than assumed. Per
// fifteen hundred schedules: the sink park fires about four thousand times, the
// single-connection un-park twelve hundred, the deadline reaper six hundred,
// connect completions a thousand, the park hook forty-five hundred, and a
// terminal failure leaves a connection draining about four thousand. Every one
// of those was zero at some point, each because of one decision the backend
// kept to itself — an infallible submit, a refused dial, a null hook, a peer
// with nothing to send.
//
// Two remain at zero, and the reason is the same for both: they need a
// connection that is simultaneously waiting to read and mid-write, and this
// harness's traffic never produces one. `onRecvConsume`'s draining arm needs a
// terminal failure to arrive on a connection with a recv already armed *and*
// something to flush — armed alone goes straight to closing, where the liveness
// guard drops the late recv first. `onSend`'s terminal back-swap needs the same
// overlap from the other side. `test/net/completion/cross_arm_test.zig` holds
// the first of them with a scripted backend, which is the right tool: a
// schedule that has to arrange an overlap is a worse instrument than a script
// that simply states it.
//
// `deinit`'s release of a live connection's contributions is a third, and it is
// structurally unreachable rather than unlucky: an over-mark or a deadline
// stamp implies queued outbound, which implies a write in flight, so the run is
// not quiescent and the branch is never entered.
//
// `max_conns`, `read_buffers`, and the high-water mark stay fixed. And under
// `zig build test` this target runs no loop at all — its corpus is empty, so
// the one empty input returns early. Every count above is `zig build fuzz`.

const completion = net.completion;
const engine = pancake.ocapn.engine;

/// Completion schedules the fuzzer found here, replayed by the ordinary suite
/// so a lifecycle bug it caught cannot come back quietly. Separate from the
/// frame-shaped `regression_seeds` above because the two targets read their
/// input differently: a saved schedule means nothing to a frame reader, and a
/// saved frame means nothing to the loop.
const schedule_regression_seeds = [_][]const u8{};

const lifecycle_drive = @import("fuzz/lifecycle_drive.zig");
const stream_plan = @import("fuzz/stream_plan.zig");

test "fuzz: arbitrary completion schedules keep the loop's lifecycle accounting exact" {
    // No shaped seeds: a schedule is an arbitrary byte string with no shape to
    // start from, unlike the frame corpus the target above seeds with. But the
    // regressions still replay here, so a schedule that broke the loop once
    // runs on every ordinary suite from then on.
    try std.testing.fuzz({}, lifecycle_drive.driveLifecycle, .{ .corpus = schedule_regression_seeds[0..] });
}

// ── A frame stream's bytes, across arbitrary chunk splits ────────────────────
//
// The first target in this file feeds hostile bytes and asks whether anything
// crashes. This one feeds frames it already knows and asks whether they come
// back: the same frames, whole, in order, once each. That question needs a
// reference to check against, so the stream is built here rather than drawn,
// and what the fuzzer
// chooses is the geometry — how big the read buffer is, how much one read is
// allowed to return, where the chunk boundaries fall, which frames arrive, and
// how the stream ends.
//
// Geometry is the whole subject, because it is what decides which of the two
// byte supplies a frame is decoded from. A frame that fits the read buffer is
// decoded where it landed and the spill never opens. A frame larger than the
// buffer cannot be, so returning it whole is itself the evidence the spill
// carried it (ADR-0041). And past `codec.framing.scan_threshold_bytes` pending
// bytes the codec stops decoding on every read and walks a resumable scan
// instead, which withholds the decoder — and with it the decoder's own refusal —
// so `codec.dispatch.framePrefix` owes the frame cap in its place. One
// synthesized frame and the open-record tail both reach past that threshold, so
// a stream here crosses every one of those handovers.
//
// What is asserted, beyond not crashing and not leaking:
//
//   - Every frame fed comes back byte-identical, in order, exactly once. That
//     is the coalesce contract stated as an equality rather than as an absence
//     of crashes: a byte dropped, duplicated, or read twice fails here.
//   - The read after the last frame gives the verdict the tail earned: a clean
//     end is `Closed`, a record opened and never closed is `FrameTooLarge`, and
//     a frame cut short mid-way is `TruncatedFrame`.
//   - The spill stays inside the cap that admitted it plus the one read that
//     carried it there, and a spill that is not accumulating has freed its
//     storage rather than merely emptied it (`net.spill_retain_bytes` is zero at
//     this tier). The sibling target above states the same retention property
//     over hostile bytes; this one reaches it on every frame of every stream,
//     because a stream of known frames actually drains.
//
// The harness's own claims are checked before the search runs, in
// `ratifyStreamShapes`: every corpus frame is one whole admissible frame, the
// synthesized frame crosses the scan threshold at every argument count the plan
// can choose and stays under the cap, and the open-record tail is refused at the
// cap rather than at the end of the stream. A geometry claim nobody checks is
// how the first target in this file spent a while never touching the spill it
// exists for.
//
// Validated against defects rather than against a passing tree. Each of these
// was injected into the production path, one at a time, and the search asked to
// find it, and each was found: bytes lost on the way into the spill
// (`net.absorbFrom` absorbing one byte fewer than it tosses); bytes duplicated
// on the way in (tossing one fewer than it absorbs); a consumed frame's last
// byte left in the spill for the next frame to trip over; a drained spill
// retaining its storage instead of freeing it; the cap refusal removed from the
// withheld-decode arm of `codec.dispatch.framePrefix`; and the resumable scan
// letting a length-prefixed leaf's payload move its depth.
//
// Two of those are worth spelling out, because of what caught them.
//
// The missing cap refusal was caught by the spill bound, not by the tail's
// verdict — the verdict still came back `FrameTooLarge`, because the scan settles
// once its own cursor passes the cap and the decoder then refuses. What had
// changed was how much had piled up first. Asserting boundedness separately from
// the verdict is the whole reason that was visible.
//
// The scan defect is why the synthesized frame carries byte-string arguments
// whose payload spells `<`. Two earlier attempts at the same defect class
// escaped: dropping the scan's digit arm and dropping its symbol arm both make
// the walk fail *early*, and failing early hands the question straight to the
// decoder, which is the safe direction. So this target can only see a scan defect
// that keeps the walk going while miscounting depth, and it needs a frame with a
// payload that can be miscounted to see even that. The escape shaped the frame;
// without those arguments the whole class was invisible here.
//
// What it does not reach, measured rather than assumed:
//
//   - A scan that gives up too early, per the escape above. By design that costs
//     a wasted decode and nothing observable, so nothing here can judge it;
//     `test/codec` drives `scanStream` directly, which is the right instrument
//     for the walk itself.
//   - Which of the two cap mirrors refused an over-cap prefix. The decoder
//     refuses one byte later than `framePrefix` does, and one read buffer is
//     wider than the byte between them.
//   - `net.drainWholeFrames`, the other spill consumer at this tier. It carries a
//     chunk tail into the same spill for the readiness loops, but it drives a
//     `Peer` rather than returning frames, so the target below it is the
//     completion-loop one above.
//   - Cap'n Proto, on purpose. Its frames declare their length up front, so it
//     has no scan and no self-delimiting grammar to resume, and the corpus this
//     target checks streams against is Syrup.
//
// Reachability was measured the same way as the defects, by asserting a state
// unreachable and letting the search refute it: a stream carrying two or more
// frames, one of them past the scan threshold, under the large cap, ending in an
// open record turns up within a few dozen runs.
//
// Under `zig build test` the search does not run: the corpus is the regression
// seeds alone, so the ratification is what the ordinary suite gets from this
// target. It is not a small part — a scan that miscounts a leaf's payload fails
// it outright, with no fuzzer involved.

/// Streams the fuzzer found here, replayed by the ordinary suite so a bug it
/// caught cannot come back quietly. Its own list, separate from the two above,
/// because a saved stream plan is neither a frame nor a completion schedule.
const stream_regression_seeds = [_][]const u8{};

test "fuzz: a frame stream returns every frame fed to it whole, in order, once" {
    try stream_plan.ratifyStreamShapes();
    // No shaped seeds: an input here is a stream plan, not a frame, so a corpus
    // frame would be read as a geometry and a list of indices. The regressions
    // still replay, so a stream that broke the reader once runs on every
    // ordinary suite from then on.
    try std.testing.fuzz({}, stream_plan.driveStream, .{ .corpus = stream_regression_seeds[0..] });
}
