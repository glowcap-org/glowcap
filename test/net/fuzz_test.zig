//! Untrusted-bytes fuzzing of blocking frame reads, spill and all.
//!
//! `readFrameFrom` is how a blocking `FrameStream` gets one frame off a
//! stream. It has a job the frame parsers do not: a frame bigger than the read
//! buffer cannot be decoded in place, so it accumulates in a spill and is
//! decoded from there instead, and the spill is freed again when it drains
//! (ADR-0012). That handover between two supplies is the part worth fuzzing.
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
//!
//! Eight targets live here. The first, `readOne`, is the blocking frame read
//! above. The second, `lifecycle_drive`, runs the completion loop against a
//! fuzzer-driven backend and compares its derived counts against a walk of the
//! slots after the schedule drains. The third, `stream_plan`, feeds known
//! frames through arbitrary chunk geometry and asks that each comes back whole,
//! in order, once. The next two, near the end of the file, feed the Tor onion
//! transport's parsers whatever a daemon the operator runs might send: one
//! control-port reply line, and the SOCKS5 greeting reply, connect reply head,
//! and service id. They assert that every refusal is one of the parser's own
//! errors and that a split reply field is a view into the line it came from. The last three, in
//! `fuzz/websocket_client.zig`, feed the WebSocket client's frame headers, close
//! payloads, and upgrade response what a relay might send. Validated by
//! injecting a reply field whose value runs one byte past its line, which the
//! seeds caught, and a `checkServiceId` that accepts a 55 byte id, which the
//! search found within its first few runs. They cannot reach a control line
//! past `max_line_bytes`, because the buffer is that size, a reply that
//! spans several lines, which the driver assembles, or the SOCKS5 reader's
//! socket reads, which the parsers never see.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const net = glowcap.net;

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
    // found it with, which for a target whose whole subject is the
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
        defer spill.deinit(gpa);

        // Keep reading until the stream refuses or runs out. A frame that ends
        // part-way through the buffer leaves the rest for the next read, which
        // is the case that builds and drains the spill. The count is a bound on
        // this harness, not on the code: a stream of tiny valid frames would
        // otherwise spend the whole budget in one input.
        var frames: usize = 0;
        while (frames < 64) : (frames += 1) {
            var frame = net.readFrameFrom(reader, gpa, codec_id, frame_cap, &spill) catch break;
            frame.deinit();

            // A drained spill has freed its storage, not merely emptied it.
            if (!spill.isActive()) {
                try std.testing.expectEqual(@as(usize, 0), spill.buf.len);
            }
            // And an active one stays inside what it holds and inside the cap
            // that admitted it. This is ADR-0012's boundedness, checked while
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
// Reading does not scale to the combinations. The loop's derived state, how
// many connections carry a deadline, how many sit over the outbound mark, how
// many closes it still owes, which slots are free, is maintained across dozens
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
// The backend returns several completions together to expose batch-contract
// failures. Closing-connection properties are asserted independently:
// comparing a count with a walk of the same field can agree while both are wrong.
//
// What it reaches and what it does not, counted rather than assumed. Per
// fifteen hundred schedules: the sink park fires about four thousand times, the
// single-connection un-park twelve hundred, the deadline reaper six hundred,
// connect completions a thousand, the park hook forty-five hundred, and a
// terminal failure leaves a connection draining about four thousand. Every one
// of those was zero at some point, each because of one decision the backend
// kept to itself, an infallible submit, a refused dial, a null hook, a peer
// with nothing to send.
//
// Two remain at zero, and the reason is the same for both: they need a
// connection that is simultaneously waiting to read and mid-write, and this
// harness's traffic never produces one. `onRecvConsume`'s draining arm needs a
// terminal failure to arrive on a connection with a recv already armed *and*
// something to flush, armed alone goes straight to closing, where the liveness
// guard drops the late recv first. `onSend`'s terminal back-swap needs the same
// overlap from the other side. `test/net/completion/cross_arm_test.zig` holds
// the first of them with a scripted backend, which is the right tool: a
// schedule that has to arrange an overlap is a worse instrument than a script
// that states it.
//
// `deinit`'s release of a live connection's contributions is a third, and it is
// structurally unreachable rather than unlucky: an over-mark or a deadline
// stamp implies queued outbound, which implies a write in flight, so the run is
// not quiescent and the branch is never entered.
//
// `max_conns`, `read_buffers`, and the high-water mark stay fixed. And under
// `zig build test` this target runs no loop at all, its corpus is empty, so
// the one empty input returns early. Every count above is `zig build fuzz`.

const completion = net.completion;
const engine = glowcap.ocapn.engine;

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
// The first target in this file feeds untrusted bytes and asks whether anything
// crashes. This one feeds frames it already knows and asks whether they come
// back: the same frames, whole, in order, once each. That question needs a
// reference to check against, so the stream is built here rather than drawn,
// and what the fuzzer
// chooses is the geometry, how big the read buffer is, how much one read is
// allowed to return, where the chunk boundaries fall, which frames arrive, and
// how the stream ends.
//
// Geometry is the whole subject, because it is what decides which of the two
// byte supplies a frame is lifted from. A frame that fits the read buffer is
// lifted from where it landed and the spill never opens. A frame larger than
// the buffer cannot be, so returning it whole is itself the evidence the spill
// carried it (ADR-0012). The synthesized frame is several kilobytes against
// reads of under a hundred bytes, so the spill grows over dozens of absorbs
// before it drains, and a stream here crosses every one of those handovers.
//
// What is asserted, beyond not crashing and not leaking:
//
//   - Every frame fed comes back byte-identical, in order, exactly once. That
//     is the coalesce contract stated as an equality rather than as an absence
//     of crashes: a byte dropped, duplicated, or read twice fails here.
//   - The read after the last frame gives the verdict the tail earned: a clean
//     end is `Closed`, an envelope declaring more than the cap is
//     `FrameTooLarge` before any of its body arrives, and a frame cut short
//     mid-way is `TruncatedFrame`.
//   - The spill stays inside the cap that admitted it plus the one read that
//     carried it there, and a spill that is not accumulating has freed its
//     storage rather than merely emptied it (`net.spill_retain_bytes` is zero at
//     this tier). The sibling target above states the same retention property
//     over untrusted bytes; this one reaches it on every frame of every stream,
//     because a stream of known frames actually drains.
//
// The harness's own claims are checked before the search runs, in
// `ratifyStreamShapes`: every corpus frame is one whole admissible frame, the
// synthesized frame is larger than any read buffer at every argument count the
// plan can choose and stays under the cap, and an over-cap declaration is
// refused on its length alone. A geometry claim nobody checks is how the first
// target in this file spent a while never touching the spill it exists for.
//
// Validated against defects rather than against a passing tree. Each of these
// was injected into the production path, one at a time, and the search asked to
// find it, and each was found: bytes lost on the way into the spill
// (`net.absorbFrom` absorbing one byte fewer than it tosses); bytes duplicated
// on the way in (tossing one fewer than it absorbs); a consumed frame's last
// byte left in the spill for the next frame to trip over; a drained spill
// retaining its storage instead of freeing it; and the cap check removed from
// the envelope's length (`net.outerPrefix`), which the spill bound caught
// before the tail's verdict did, because what changed was how much had piled
// up first. Asserting boundedness separately from the verdict is the whole
// reason that was visible. Before ADR-0012 the stream was framed by walking
// the inner codec, and this target found two defects in that walk; the
// envelope has no walk, and its body is opaque bytes that come back
// byte-identical or not at all.
//
// What it does not reach, measured rather than assumed:
//
//   - A body that is not one frame of the codec. The blocking read lifts the
//     envelope's body whole and the session refuses it at admission, which
//     `test/engine/completion_seam_test.zig` pins and the completion-loop
//     target above reaches.
//   - `net.drainWholeFrames`, the other spill consumer at this tier. It carries a
//     chunk tail into the same spill for the readiness loops, but it drives a
//     `Peer` rather than returning frames, so the target below it is the
//     completion-loop one above.
//   - Cap'n Proto. The envelope carries either codec the same way, and the
//     corpus this target checks streams against is Syrup.
//
// Reachability was measured the same way as the defects, by asserting a state
// unreachable and letting the search refute it: a stream carrying two or more
// frames, one of them larger than the read buffer, under the large cap, ending
// in an over-cap declaration turns up within a few dozen runs.
//
// Under `zig build test` the search does not run: the corpus is the regression
// seeds alone, so the ratification is what the ordinary suite gets from this
// target. It is not a small part: a corpus frame the codec no longer accepts status-allow: lifecycle transition
// whole fails it outright, with no fuzzer involved.

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

// ── Tor's replies, as a daemon the operator runs might send them ─────────────

const control = net.onion.control;
const socks5 = net.onion.socks5;

/// Control reply lines the fuzzer found here, replayed by the ordinary suite so
/// a parser bug it caught cannot come back quietly. Its own list because a saved
/// line means nothing to the SOCKS5 readers.
const control_regression_seeds = [_][]const u8{};

/// SOCKS5 reply bytes the fuzzer found here, replayed by the ordinary suite.
const socks_regression_seeds = [_][]const u8{};

/// A bounded view must lie inside the input it was cut from.
fn within(input: []const u8, part: []const u8) bool {
    const start = @intFromPtr(part.ptr);
    const base = @intFromPtr(input.ptr);
    return start >= base and start + part.len <= base + input.len;
}

fn parseControlLine(line: []const u8) !void {
    const reply = control.parseLine(line) catch |err| switch (err) {
        error.LineTooLong, error.MalformedReply, error.InvalidCredential => return,
    };
    _ = reply.isOk();
    try std.testing.expect(within(line, reply.text));
    if (reply.field()) |kv| {
        try std.testing.expect(within(line, kv.key));
        try std.testing.expect(within(line, kv.value));
        try std.testing.expect(std.mem.indexOfScalar(u8, kv.key, '=') == null);
    }
}

fn controlReplyLine(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [control.max_line_bytes]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    try parseControlLine(control.trimLineEnding(input));
    try parseControlLine(input);
}

const control_seeds = [_][]const u8{
    seeds.seed("250 OK"),
    seeds.seed("250-ServiceID=abc"),
    seeds.seed("250-ServiceID=wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd"),
    seeds.seed("515 Bad authentication"),
    seeds.seed("650 HS_DESC UPLOADED"),
    seeds.seed("250+onion_line=\r\n"),
};

test "fuzz: arbitrary control-port reply lines never crash the Tor reply parser" {
    try std.testing.fuzz({}, controlReplyLine, .{ .corpus = (control_seeds ++ control_regression_seeds)[0..] });
}

fn socksReplyBytes(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [64]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];

    socks5.checkGreetingReply(input) catch |err| switch (err) {
        error.InvalidServiceId, error.ProtocolViolation, error.ConnectRefused => {},
    };
    if (input.len >= socks5.connect_reply_head_len) {
        const head = input[0..socks5.connect_reply_head_len];
        socks5.checkConnectReply(head) catch |err| switch (err) {
            error.InvalidServiceId, error.ProtocolViolation, error.ConnectRefused => {},
        };
        _ = socks5.boundAddress(head) catch |err| switch (err) {
            error.InvalidServiceId, error.ProtocolViolation, error.ConnectRefused => {},
        };
    }
    socks5.checkServiceId(input) catch |err| switch (err) {
        error.InvalidServiceId, error.ProtocolViolation, error.ConnectRefused => {},
    };
}

const socks_seeds = [_][]const u8{
    seeds.seed(&[_]u8{ 0x05, 0x00 }),
    seeds.seed(&[_]u8{ 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }),
    seeds.seed("wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd"),
};

test "fuzz: arbitrary SOCKS5 reply bytes never crash the reply readers" {
    try std.testing.fuzz({}, socksReplyBytes, .{ .corpus = (socks_seeds ++ socks_regression_seeds)[0..] });
}

const ws_client = @import("fuzz/websocket_client.zig");

/// Frame headers, close payloads, and upgrade responses the fuzzer found here,
/// replayed by the ordinary suite. One list each because a saved header means
/// nothing to the upgrade validator.
const ws_frame_regression_seeds = [_][]const u8{};
const ws_close_regression_seeds = [_][]const u8{};
const ws_upgrade_regression_seeds = [_][]const u8{};

test "fuzz: arbitrary server frame headers keep the WebSocket client's length contract" {
    try std.testing.fuzz({}, ws_client.frameHeader, .{ .corpus = (ws_client.frame_seeds ++ ws_frame_regression_seeds)[0..] });
}

test "fuzz: arbitrary close payloads never crash the WebSocket close validator" {
    try std.testing.fuzz({}, ws_client.closePayload, .{ .corpus = (ws_client.close_seeds ++ ws_close_regression_seeds)[0..] });
}

test "fuzz: arbitrary upgrade responses are judged the same by both WebSocket validators" {
    try std.testing.fuzz({}, ws_client.upgrade, .{ .corpus = (ws_client.upgrade_seeds ++ ws_upgrade_regression_seeds)[0..] });
}
