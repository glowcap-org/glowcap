//! The give's exporter-location form (ADR-0042): a `desc:handoff-give`
//! embeds the exporter's hello location in the form its recipient can use.
//! `handoff_gifter.exporterLocationForRecipient` keeps ADR-0042's byte-exact
//! profile behavior while stripping glowcap-private route vocabulary before a
//! give reaches an unknown recipient, so a Goblins recipient sees one concrete
//! baseline route rather than private vocabulary it never negotiated.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const codec = glowcap.ocapn.codec;
const crypto = glowcap.foundation.crypto;

fn recordBytes(allocator: std.mem.Allocator, locator: model.PeerLocator) ![]u8 {
    return codec.signed.encodeLocatorRecord(allocator, locator);
}

test "give refuses an exporter location it cannot privacy-filter" {
    const allocator = std.testing.allocator;
    const raw = try recordBytes(allocator, .{
        .transport = model.transport.onion,
        .designator = &@as([56]u8, @splat('a')),
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(raw);
    const trailing = try std.mem.concat(allocator, u8, &.{ raw, "f" });
    defer allocator.free(trailing);
    for ([_][]const u8{ "", raw[0 .. raw.len - 1], trailing }) |invalid| {
        try std.testing.expectError(error.UnsupportedArgument, engine.handoff_gifter.exporterLocationForRecipient(allocator, invalid, .{}));
        const secret = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x21)));
        try std.testing.expectError(error.UnsupportedArgument, engine.handoff_gifter.mintGive(
            allocator,
            secret,
            &@as([model.handoff_gift_id_bytes]u8, @splat(0x22)),
            &@as([32]u8, @splat(0x23)),
            &@as([32]u8, @splat(0x24)),
            invalid,
            .{},
            .{ .route_vocabulary = true, .session_location = invalid },
        ));
    }
}

test "a bare exporter location needs no stripping and allocates nothing" {
    const allocator = std.testing.allocator;
    const raw = try recordBytes(allocator, .{
        .transport = model.transport.onion,
        .designator = &@as([56]u8, @splat('a')),
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(raw);
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try engine.handoff_gifter.exporterLocationForRecipient(allocator, raw, .{}),
    );
}

test "profile hints strip to the bare onion form" {
    const allocator = std.testing.allocator;
    const hints = [_]model.HintEntry{
        .{ .name = model.transport.hint_captp_version, .value = .{ .string = model.CaptpVersion.next.hintToken() } },
        .{ .name = model.transport.hint_codec, .value = .{ .string = "1" } },
    };
    const raw = try recordBytes(allocator, .{
        .transport = model.transport.onion,
        .designator = &@as([56]u8, @splat('a')),
        .hints = .{ .entries = &hints },
    });
    defer allocator.free(raw);
    const stripped = (try engine.handoff_gifter.exporterLocationForRecipient(allocator, raw, .{})).?;
    defer allocator.free(stripped);
    const bare = try recordBytes(allocator, .{
        .transport = model.transport.onion,
        .designator = &@as([56]u8, @splat('a')),
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(bare);
    try std.testing.expectEqualSlices(u8, bare, stripped);
}

test "routing hints a receiver needs survive the onion profile strip" {
    const allocator = std.testing.allocator;
    const hints = [_]model.HintEntry{
        .{ .name = "direct-addresses", .value = .{ .string = "192.0.2.7:9045" } },
        .{ .name = model.transport.hint_captp_version, .value = .{ .string = model.CaptpVersion.next.hintToken() } },
    };
    const raw = try recordBytes(allocator, .{
        .transport = model.transport.onion,
        .designator = &@as([56]u8, @splat('a')),
        .hints = .{ .entries = &hints },
    });
    defer allocator.free(raw);
    const stripped = (try engine.handoff_gifter.exporterLocationForRecipient(allocator, raw, .{})).?;
    defer allocator.free(stripped);
    const routing_only = [_]model.HintEntry{
        .{ .name = "direct-addresses", .value = .{ .string = "192.0.2.7:9045" } },
    };
    const expected = try recordBytes(allocator, .{
        .transport = model.transport.onion,
        .designator = &@as([56]u8, @splat('a')),
        .hints = .{ .entries = &routing_only },
    });
    defer allocator.free(expected);
    try std.testing.expectEqualSlices(u8, expected, stripped);
}

test "a profile-only non-onion give keeps the exporter's hello verbatim" {
    // On every transport but onion the exporter's hello is hinted toward
    // everyone alike, and the pinned Goblins keys withdrawal lookups by the
    // full node value, `zig build goblins-gift-hints` observes the verbatim
    // match live, so the give must not shed a byte.
    const allocator = std.testing.allocator;
    const hints = [_]model.HintEntry{
        .{ .name = "direct-addresses", .value = .{ .string = "192.0.2.7:9045" } },
        .{ .name = model.transport.hint_captp_version, .value = .{ .string = model.CaptpVersion.next.hintToken() } },
    };
    const raw = try recordBytes(allocator, .{
        .transport = model.transport.iroh,
        .designator = &@as([52]u8, @splat('b')),
        .hints = .{ .entries = &hints },
    });
    defer allocator.free(raw);
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try engine.handoff_gifter.exporterLocationForRecipient(allocator, raw, .{}),
    );
}

fn expectMintedExporter(
    allocator: std.mem.Allocator,
    exporter_loc: []const u8,
    policy: engine.handoff_gifter.RecipientLocatorPolicy,
) !model.HandoffGive {
    const secret = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x21)));
    const give = try engine.handoff_gifter.mintGive(
        allocator,
        secret,
        &@as([model.handoff_gift_id_bytes]u8, @splat(0x22)),
        &@as([32]u8, @splat(0x23)),
        &@as([32]u8, @splat(0x24)),
        exporter_loc,
        policy,
        .{ .route_vocabulary = true, .session_location = exporter_loc },
    );
    defer allocator.free(give);
    return codec.signed.decodeGiveOwned(allocator, give);
}

test "id gives fail closed for recipients without route vocabulary" {
    const allocator = std.testing.allocator;
    const key = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x25))).publicKey().toDesignator();
    const route_text = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.iroh",
        .{key[0..]},
    );
    defer allocator.free(route_text);
    const routes = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = route_text },
    }};
    const id_raw = try recordBytes(allocator, .{
        .transport = model.transport.id,
        .designator = &key,
        .hints = .{ .entries = &routes },
    });
    defer allocator.free(id_raw);
    try std.testing.expectError(
        error.UnsupportedArgument,
        engine.handoff_gifter.exporterLocationForRecipient(allocator, id_raw, .{}),
    );
}

test "id gives lower to the recipient session transport" {
    const allocator = std.testing.allocator;
    const key = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x27))).publicKey().toDesignator();
    const route_text = try std.fmt.allocPrint(allocator, "ocapn://{s}.iroh", .{key[0..]});
    defer allocator.free(route_text);
    const routes = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = route_text },
    }};
    const id_raw = try recordBytes(allocator, .{
        .transport = model.transport.id,
        .designator = &key,
        .hints = .{ .entries = &routes },
    });
    defer allocator.free(id_raw);

    const give = try expectMintedExporter(allocator, id_raw, .{
        .known_glowcap = true,
        .session_transport = model.transport.iroh,
    });
    defer model.freeHandoffGive(allocator, give);
    try std.testing.expectEqualStrings(model.transport.iroh, give.exporter.transport);
    try std.testing.expectEqualStrings(key[0..], give.exporter.designator);
}

test "id gives without a recipient-compatible baseline route fail closed for unknown recipients" {
    const allocator = std.testing.allocator;
    const routes = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = "ocapn://relay-key.keyed-relay" },
    }};
    const raw = try recordBytes(allocator, .{
        .transport = model.transport.id,
        .designator = "peer-key",
        .hints = .{ .entries = &routes },
    });
    defer allocator.free(raw);
    try std.testing.expectError(
        error.UnsupportedArgument,
        engine.handoff_gifter.exporterLocationForRecipient(allocator, raw, .{}),
    );
}

test "via remains an ordinary unknown hint outside the id transport" {
    const allocator = std.testing.allocator;
    const hints = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = "transport-owned" },
    }};
    const raw = try recordBytes(allocator, .{
        .transport = model.transport.tcp,
        .designator = "127.0.0.1:9049",
        .hints = .{ .entries = &hints },
    });
    defer allocator.free(raw);
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try engine.handoff_gifter.exporterLocationForRecipient(allocator, raw, .{}),
    );
}

test "route vocabulary recipients keep id locators verbatim" {
    const allocator = std.testing.allocator;
    const key = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x26))).publicKey().toDesignator();
    const route_text = try std.fmt.allocPrint(allocator, "ocapn://{s}.iroh", .{key[0..]});
    defer allocator.free(route_text);
    const routes = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = route_text },
    }};
    const raw = try recordBytes(allocator, .{
        .transport = model.transport.id,
        .designator = &key,
        .hints = .{ .entries = &routes },
    });
    defer allocator.free(raw);

    const give = try expectMintedExporter(allocator, raw, .{
        .known_glowcap = true,
        .route_vocabulary = true,
    });
    defer model.freeHandoffGive(allocator, give);
    try std.testing.expectEqualStrings(model.transport.id, give.exporter.transport);
    try std.testing.expectEqualStrings(key[0..], give.exporter.designator);
    try std.testing.expectEqual(@as(usize, 1), give.exporter.hints.entries.len);
    try std.testing.expectEqualStrings(model.transport.hint_via, give.exporter.hints.entries[0].name);
}

test "route vocabulary recipients use a baseline exporter's session location" {
    const allocator = std.testing.allocator;
    const key = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x28))).publicKey().toDesignator();
    const route_text = try std.fmt.allocPrint(allocator, "ocapn://{s}.iroh", .{key[0..]});
    defer allocator.free(route_text);
    const routes = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = route_text },
    }};
    const id_raw = try recordBytes(allocator, .{
        .transport = model.transport.id,
        .designator = &key,
        .hints = .{ .entries = &routes },
    });
    defer allocator.free(id_raw);
    const baseline_raw = try recordBytes(allocator, .{
        .transport = model.transport.tcp,
        .designator = "127.0.0.1:9049",
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(baseline_raw);

    const secret = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x29)));
    const signed = try engine.handoff_gifter.mintGive(
        allocator,
        secret,
        &@as([model.handoff_gift_id_bytes]u8, @splat(0x2a)),
        &@as([32]u8, @splat(0x2b)),
        &@as([32]u8, @splat(0x2c)),
        id_raw,
        .{ .known_glowcap = true, .route_vocabulary = true },
        .{ .route_vocabulary = false, .session_location = baseline_raw },
    );
    defer allocator.free(signed);
    const give = try codec.signed.decodeGiveOwned(allocator, signed);
    defer model.freeHandoffGive(allocator, give);
    try std.testing.expectEqualStrings(model.transport.tcp, give.exporter.transport);
    try std.testing.expectEqualStrings("127.0.0.1:9049", give.exporter.designator);
}

test "route vocabulary recipients keep a baseline-compatible exporter override" {
    const allocator = std.testing.allocator;
    const override_raw = try recordBytes(allocator, .{
        .transport = model.transport.tcp,
        .designator = "127.0.0.1:9050",
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(override_raw);
    const session_raw = try recordBytes(allocator, .{
        .transport = model.transport.tcp,
        .designator = "127.0.0.1:9051",
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(session_raw);

    const secret = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x2d)));
    const signed = try engine.handoff_gifter.mintGive(
        allocator,
        secret,
        &@as([model.handoff_gift_id_bytes]u8, @splat(0x2e)),
        &@as([32]u8, @splat(0x2f)),
        &@as([32]u8, @splat(0x30)),
        override_raw,
        .{ .known_glowcap = true, .route_vocabulary = true },
        .{ .route_vocabulary = false, .session_location = session_raw },
    );
    defer allocator.free(signed);
    const give = try codec.signed.decodeGiveOwned(allocator, signed);
    defer model.freeHandoffGive(allocator, give);
    try std.testing.expectEqualStrings(model.transport.tcp, give.exporter.transport);
    try std.testing.expectEqualStrings("127.0.0.1:9050", give.exporter.designator);
}

test "allocation failure while lowering a private route is returned, never the unstripped bytes" {
    const key = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x31))).publicKey().toDesignator();
    const route_text = try std.fmt.allocPrint(std.testing.allocator, "ocapn://{s}.iroh", .{key[0..]});
    defer std.testing.allocator.free(route_text);
    const routes = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = route_text },
    }};
    const id_raw = try recordBytes(std.testing.allocator, .{
        .transport = model.transport.id,
        .designator = &key,
        .hints = .{ .entries = &routes },
    });
    defer std.testing.allocator.free(id_raw);
    const policy: engine.handoff_gifter.RecipientLocatorPolicy = .{ .session_transport = model.transport.iroh };

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const lowered = engine.handoff_gifter.exporterLocationForRecipient(
            failing.allocator(),
            id_raw,
            policy,
        ) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        // Every successful run lowered: the via-hinted id locator never ships.
        const owned = lowered orelse return error.TestUnexpectedResult;
        defer failing.allocator().free(owned);
        try std.testing.expect(!failing.has_induced_failure);
        break;
    }
}
