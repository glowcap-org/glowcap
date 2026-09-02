//! Hostile-bytes fuzzing of identity-route admission.
//!
//! An `id` locator's `via` and `alt-locators` hints are route lists a partner
//! wrote: they arrive in a peer's handshake and inside a handoff naming a
//! third party. Two functions read them, and they must agree. `validateLocator`
//! is the borrowed, allocation-free admission check a session runs before it
//! accepts the locator; `parseLocator` is the owned parser the dialer runs to
//! build the route bundle it will actually dial. A session that admits a
//! locator its own dialer then refuses — or the reverse — is the split that
//! matters here, so that agreement is the property, not merely not crashing.
//!
//! The fuzzer drives the route-list text; the outer `id` designator is a fixed
//! real key, because a garbage designator is refused at the first line and
//! never reaches the list parser this target exists to exercise.
//!
//! Validated against defects (per the tests rule): an owned parser made to
//! refuse a carrier the borrowed check admits is caught from the two-route
//! seed as `AdmissionParserSplit`, and the sibling unit test catches the
//! reverse (borrowed check dropping the proves-key requirement). The one
//! finding so far is `fuzz_regressions/empty-query-route.bin`: a route whose
//! `?` carries nothing, which the borrowed view check split into one nameless
//! segment and hit `unreachable` on while the owned parser read an empty hint
//! map, and which the replayed seed keeps refused-or-agreed. Not measured:
//! this drives the `via` list only, so an `alt-locators`-only defect is the
//! next seed to add if that path grows its own rule.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const id_route = session.id_route;

/// Inputs the fuzzer found here, replayed by the ordinary suite so a bug it
/// caught cannot come back quietly. `zig build fuzz` prints what to add.
const regression_seeds = [_][]const u8{
    // A route whose `?` carries an empty query: the owned parser reads it as an
    // empty hint map, and the borrowed view check once split it into one
    // segment with no `=` and hit `unreachable`.
    @embedFile("fuzz_regressions/empty-query-route.bin"),
};

const max_input = 1024;

/// A syntactically valid identity designator: exactly `designator_len` lowercase
/// hex characters. `fromDesignator` accepts it on length and alphabet, which is
/// all the route-list parser needs — curve membership is never checked here — so
/// this stays a plain constant rather than a comptime key derivation the SHA-2
/// backwards-branch budget refuses.
const valid_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn routeOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const via = buf[0..smith.slice(&buf)];
    const gpa = std.testing.allocator;

    const hints = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = via },
    }};
    const locator: model.PeerLocator = .{
        .transport = model.transport.id,
        .designator = valid_key,
        .hints = .{ .entries = &hints },
    };

    // The borrowed admission check: allocation-free, and the answer a session
    // acts on. It may refuse; it must not crash.
    const admitted = id_route.validateLocator(locator) catch {
        // Refused by admission. The owned parser must refuse it too, or the
        // dialer would build a bundle the session would never have accepted.
        if (id_route.parseLocator(gpa, locator)) |bundle| {
            defer bundle.deinit(gpa);
            std.debug.print("admission refused a locator the dialer parsed\n", .{});
            return error.AdmissionParserSplit;
        } else |_| return;
    };

    // Admitted. The owned parser must agree, and everything it allocates on the
    // way to a refusal or a bundle runs under the leak-checking allocator.
    var bundle = id_route.parseLocator(gpa, locator) catch {
        std.debug.print("admission accepted a locator the dialer refused\n", .{});
        return error.AdmissionParserSplit;
    };
    defer bundle.deinit(gpa);

    // Both agreed to accept, so the identity each recovers must be the one key
    // the outer designator named — the whole point of an identity route.
    const demanded = id_route.demandedPartnerKey(bundle) orelse {
        std.debug.print("an admitted id bundle demanded no partner key\n", .{});
        return error.MissingDemandedKey;
    };
    if (admitted) |key| {
        if (!key.eql(demanded)) {
            std.debug.print("admission and the bundle disagree on the demanded key\n", .{});
            return error.DemandedKeyMismatch;
        }
    }
}

test "fuzz: arbitrary id route lists never crash, leak, or split admission from dial" {
    const valid = valid_key;
    // A one-route list and a two-route list that both admit, so the search
    // starts from lists that parse rather than from noise refused at byte one.
    const one = "ocapn://" ++ valid ++ ".iroh";
    const two = "ocapn://" ++ valid ++ ".iroh|ocapn://" ++ valid ++ ".noise-tcp";
    const seeds = [_][]const u8{ one, two, "", "ocapn://x.iroh", "|", "ocapn://" ++ valid ++ ".id" };

    var storage: [seeds.len][4 + 512]u8 = undefined;
    var corpus: [seeds.len + regression_seeds.len][]const u8 = undefined;
    for (seeds, 0..) |text, i| {
        std.mem.writeInt(u32, storage[i][0..4], @intCast(text.len), .little);
        @memcpy(storage[i][4 .. 4 + text.len], text);
        corpus[i] = storage[i][0 .. 4 + text.len];
    }
    for (regression_seeds, 0..) |entry, i| corpus[seeds.len + i] = entry;
    try std.testing.fuzz({}, routeOne, .{ .corpus = corpus[0..] });
}
