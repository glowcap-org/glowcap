//! Untrusted-bytes fuzzing of locator and sturdyref parsing.
//!
//! An `ocapn://` URI is not a local configuration string. A partner sends one
//! in its `op:start-session`, and a gifter sends another naming a third party
//! inside a handoff, so the parser is fed text somebody else wrote. It also
//! allocates: percent-decoding, splitting the netloc, and building the hint
//! table each take memory, which means a refusal halfway through has partial
//! work to release.
//!
//! Three properties, and only the first is about crashing.
//!
//! Any text at all is parsed or refused, never crashes, and never leaks.
//! Everything runs under `std.testing.allocator`, which fails on a leak, and a
//! refusal partway through with one of those three allocations already made is
//! the shape that hides one.
//!
//! What we write, we can read back. A locator the writer emits and the parser
//! then refuses is one this node can send and cannot receive, which is a split
//! nobody notices until two peers disagree about the same address.
//!
//! Canonicalising is idempotent. The canonical form is a lookup key: a pending
//! dial is joined on identity rather than on how the address happened to be
//! spelled, so a form that moves when canonicalised twice opens a second dial to
//! a peer already being dialled. That one is worth stating because the function
//! has an escape hatch, text it cannot parse comes back verbatim, and a
//! locator that writes but does not re-parse would slip between the two.

const std = @import("std");
const glowcap = @import("glowcap");

const uri = glowcap.ocapn.model.uri;

/// Inputs the fuzzer found here, replayed by the ordinary suite so a bug it
/// caught cannot come back quietly. `zig build fuzz` prints what to add when it
/// finds one.
const regression_seeds = [_][]const u8{
    @embedFile("fuzz_regressions/uri-write-peer-roundtrip.bin"),
};

/// Upper bound on one fuzz input. A URI far past this is refused on length
/// before any of the interesting parsing happens.
const max_input = 1024;

fn uriOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    const gpa = std.testing.allocator;

    // Both entry points, because they diverge after the scheme: a peer locator
    // refuses a path and a sturdyref requires one.
    if (uri.parsePeer(gpa, input)) |locator| {
        defer uri.freePeer(gpa, locator);

        // What the writer emits, the parser has to accept.
        const written = try uri.writePeer(gpa, locator);
        defer gpa.free(written);
        const again = uri.parsePeer(gpa, written) catch |err| {
            std.debug.print("wrote a locator we cannot read back: {s}\n", .{written});
            return err;
        };
        uri.freePeer(gpa, again);
    } else |_| {}

    if (uri.parseSturdyref(gpa, input)) |sturdyref| {
        uri.freeSturdyref(gpa, sturdyref);
    } else |_| {}

    // Canonicalising twice lands where canonicalising once did.
    const once = uri.canonicalPeerIdentityUri(gpa, input) catch return;
    defer gpa.free(once);
    const twice = try uri.canonicalPeerIdentityUri(gpa, once);
    defer gpa.free(twice);
    std.testing.expectEqualSlices(u8, once, twice) catch |err| {
        std.debug.print("canonical form moved on the second pass\n", .{});
        return err;
    };
}

test "fuzz: arbitrary text never crashes or leaks the locator parsers" {
    // Real locators from around the tree, so the search starts from text that
    // parses rather than from noise the scheme check refuses at byte one.
    const seeds = [_][]const u8{
        "ocapn://tcp.127.0.0.1:9001",
        "ocapn://tcp.localhost:1234/s/swiss-number",
        "ocapn://iroh.0123456789abcdef",
        "ocapn://keyed-tcp.127.0.0.1:9001?direct-addresses=1.2.3.4:5",
        "ocapn://inproc.node-a",
        // The shape that had to be refused by hand: one hint name twice.
        "ocapn://tcp.h:1?a=1&a=2",
        // Percent-decoding, which is where the partial-failure paths live.
        "ocapn://tcp.%68%6f%73%74:9",
    };

    var storage: [seeds.len][4 + 128]u8 = undefined;
    var corpus: [seeds.len + regression_seeds.len][]const u8 = undefined;
    for (seeds, 0..) |text, i| {
        std.mem.writeInt(u32, storage[i][0..4], @intCast(text.len), .little);
        @memcpy(storage[i][4 .. 4 + text.len], text);
        corpus[i] = storage[i][0 .. 4 + text.len];
    }
    for (regression_seeds, 0..) |entry, i| corpus[seeds.len + i] = entry;
    try std.testing.fuzz({}, uriOne, .{ .corpus = corpus[0..] });
}
