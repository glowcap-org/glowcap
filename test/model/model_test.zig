const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;

fn exporterUriWithAlternatives(
    allocator: std.mem.Allocator,
    alternatives: []const u8,
) ![]u8 {
    const hints = [_]model.HintEntry{.{
        .name = model.transport.hint_alt_locators,
        .value = .{ .string = alternatives },
    }};
    return model.uri.writePeer(allocator, .{
        .transport = model.transport.tcp,
        .designator = "127.0.0.1:9049",
        .hints = .{ .entries = &hints },
    });
}

test "hint addition preserves locator invariants" {
    const entries = [_]model.HintEntry{.{ .name = "route", .value = .{ .string = "direct" } }};
    const locator = model.PeerLocator{
        .transport = "tcp",
        .designator = "127.0.0.1:1",
        .hints = .{ .entries = &entries },
    };
    try model.validateLocatorHintAddition(locator, "token");
    try std.testing.expectError(error.EmptyHintName, model.validateLocatorHintAddition(locator, ""));
    try std.testing.expectError(error.DuplicateHintName, model.validateLocatorHintAddition(locator, "route"));

    var no_hints = locator;
    no_hints.hints = model.Hints.emptyFalse();
    try std.testing.expectError(error.InvalidFalseHints, model.validateLocatorHintAddition(no_hints, "route"));

    var names: [model.max_locator_hint_count + 1][2]u8 = undefined;
    var too_many: [model.max_locator_hint_count + 1]model.HintEntry = undefined;
    for (&too_many, 0..) |*entry, i| {
        names[i] = .{ @intCast(i + 1), 'h' };
        entry.* = .{ .name = &names[i], .value = .{ .boolean = true } };
    }
    try std.testing.expectError(error.TooManyHints, model.validatePeerLocator(.{
        .transport = "tcp",
        .designator = "127.0.0.1:1",
        .hints = .{ .entries = &too_many },
    }));
}

test "route plan equality treats hint maps semantically" {
    const left_entries = [_]model.HintEntry{
        .{ .name = "address", .value = .{ .string = "127.0.0.1:1" } },
        .{ .name = "zone", .value = .{ .integer = 2 } },
    };
    const right_entries = [_]model.HintEntry{
        .{ .name = "zone", .value = .{ .integer = 2 } },
        .{ .name = "address", .value = .{ .string = "127.0.0.1:1" } },
    };
    var left_paths = [_]model.RoutePath{
        .{ .transport = model.transport.keyed_tcp, .designator = "key", .hints = .{ .entries = &left_entries } },
        .{ .transport = model.transport.tcp, .designator = "127.0.0.1:2", .hints = model.Hints.emptyFalse() },
    };
    var right_paths = [_]model.RoutePath{
        .{ .transport = model.transport.keyed_tcp, .designator = "key", .hints = .{ .entries = &right_entries } },
        .{ .transport = model.transport.tcp, .designator = "127.0.0.1:2", .hints = model.Hints.emptyMap() },
    };
    var left_identity = [_]u8{'l'};
    var right_identity = [_]u8{'r'};
    try std.testing.expect(model.route_bundle.samePaths(
        .{ .source = .peer_locator, .identity = &left_identity, .paths = &left_paths },
        .{ .source = .peer_locator, .identity = &right_identity, .paths = &right_paths },
    ));
}

test "value-tree types stay within their documented size budget" {
    // The owned `Argument`/`Resolution`/`Reference` ceilings are comptime
    // asserts beside the types in `src/ocapn/model/mod.zig`; un-boxing the
    // handoff arm fails the build there, not this test.
    // The borrowed twins get their gate here. `view.Argument` keeps its handoff
    // arm inline — it borrows wire bytes and may not allocate a box — so it is
    // roughly eight times its owned twin, and the inbound set-uniqueness fold
    // parks one per set element (stack for small sets, `recv_scratch` above
    // that). That spend is deliberate, but it must not grow silently: a new
    // field on any record under the handoff arm moves these numbers. Both
    // bounds rose by one pointer (312 → 320, 120 → 128) when `view.HintList`
    // gained its allocation-free borrowed `find` fn pointer, carried under
    // every borrowed locator's hints.
    try std.testing.expect(@sizeOf(model.view.Argument) <= 320);
    try std.testing.expect(@sizeOf(model.view.Reference) <= 128);
}

test "owned argument measurement matches the clone payload shape" {
    const nested = [_]model.Argument{.{ .string = "xy" }};
    const args = [_]model.Argument{
        .{ .bytes = "abc" },
        .{ .list = &nested },
    };
    const expected = args.len * @sizeOf(model.Argument) + "abc".len +
        nested.len * @sizeOf(model.Argument) + "xy".len;
    try std.testing.expectEqual(expected, try model.measureArgumentSliceOwnedBytes(&args));
}

test "owned message measurement counts only heap-carrying listener fields" {
    const message: model.Message = .{ .listen = .{
        .target = .{ .broken = .{ .message = "target" } },
        .listener = .{ .broken = .{ .message = "listener" } },
        .mode = .settling_only,
    } };
    try std.testing.expectEqual(
        @sizeOf(model.Message) + "target".len + "listener".len,
        try model.measureMessageOwnedBytes(message),
    );
}

test "owned message measurement counts a big integer index payload" {
    const message: model.Message = .{ .index = .{
        .receiver = .{ .near = model.NearRef.object(7) },
        .index = .{ .big_integer = .{ .negative = false, .digits = "12345678901234567890" } },
        .answer = .from(11),
    } };
    try std.testing.expectEqual(
        @sizeOf(model.Message) + "12345678901234567890".len,
        try model.measureMessageOwnedBytes(message),
    );
}

test "CapTP versions parse and render wire strings" {
    try std.testing.expectEqualStrings("1.0", model.CaptpVersion.v1_0.wireString());
    try std.testing.expectEqualStrings("pancake-next", model.CaptpVersion.next.wireString());

    try std.testing.expectEqual(model.CaptpVersion.v1_0, model.CaptpVersion.fromWireString("1.0").?);
    try std.testing.expectEqual(model.CaptpVersion.next, model.CaptpVersion.fromWireString("pancake-next").?);
    try std.testing.expectEqual(@as(?model.CaptpVersion, null), model.CaptpVersion.fromWireString("ocapn-1.0"));
    try std.testing.expectEqual(@as(?model.CaptpVersion, null), model.CaptpVersion.fromWireString("2.0"));
}

test "CaptpVersion diagnostic names" {
    try std.testing.expectEqualStrings("ocapn-v1.0", model.CaptpVersion.v1_0.name());
    try std.testing.expectEqualStrings("pancake-next", model.CaptpVersion.next.name());
}

test "abort kinds round-trip every variant through their wire names" {
    const expected = [_]struct { model.AbortKind, []const u8 }{
        .{ .normal_shutdown, "NormalShutdown" },
        .{ .version_mismatch, "VersionMismatch" },
        .{ .protocol_error, "ProtocolError" },
        .{ .timeout, "Timeout" },
        .{ .unauthorized, "Unauthorized" },
        .{ .invalid_handoff_signature, "InvalidHandoffSignature" },
        .{ .handoff_replay, "HandoffReplay" },
        .{ .queue_cap_exceeded, "QueueCapExceeded" },
        .{ .pipelining_not_negotiated, "PipeliningNotNegotiated" },
        .{ .wire_delta_not_negotiated, "WireDeltaNotNegotiated" },
        .{ .handoffs_not_negotiated, "HandoffsNotNegotiated" },
        .{ .sturdyrefs_not_negotiated, "SturdyrefsNotNegotiated" },
        .{ .invalid_start_session_signature, "InvalidStartSessionSignature" },
        .{ .crossed_hellos, "CrossedHellos" },
        .{ .connection_lost, "ConnectionLost" },
        .{ .graceful_shutdown, "GracefulShutdown" },
        .{ .malformed_frame, "MalformedFrame" },
        .{ .resource_exhausted, "ResourceExhausted" },
        .{ .other, "Other" },
    };

    for (expected) |entry| {
        try std.testing.expectEqualStrings(entry[1], entry[0].wireName());
        try std.testing.expectEqual(entry[0], model.AbortKind.fromWireName(entry[1]).?);
    }
}

test "capability routes and wire imports are disjoint by type (ADR-0091)" {
    const wire = model.ImportPosition.from(std.math.maxInt(u64));
    const route_id = model.CapabilityRouteId.from(std.math.maxInt(u64));
    try std.testing.expectEqual(wire.int(), route_id.int());
    const wire_ref: model.Reference = .{ .far = .{ .import_position = wire } };
    const routed_ref: model.Reference = .{ .routed = .{ .id = route_id } };
    try std.testing.expect(wire_ref == .far);
    try std.testing.expect(routed_ref == .routed);
}

test "virtual and wire answers are disjoint by type" {
    const wire = model.AnswerName.fromWire(.from(1));
    const virtual = model.AnswerName.fromVirtual(.from(1));
    try std.testing.expect(wire == .wire);
    try std.testing.expect(virtual == .virtual);
    try std.testing.expectEqual(wire.wire.int(), virtual.virtual.int());
}

test "near and far ref constructors set the wire-tag kind discriminant" {
    try std.testing.expectEqual(model.RefKind.object, model.NearRef.object(1).kind);
    try std.testing.expectEqual(model.RefKind.promise, model.NearRef.promise(1).kind);
    try std.testing.expectEqual(model.RefKind.object, model.FarRef.object(2).kind);
    try std.testing.expectEqual(model.RefKind.promise, model.FarRef.promise(2).kind);
}

test "protocol model arms map one-to-one onto Zig Message tags" {
    const oracle = @import("../oracle/protocol_oracle.zig");

    // Truth derives from the `model.Message` union itself, not from a second
    // hand list: a new union arm fails here until `message_kinds` carries its
    // row, and a kinds row fails until the oracle registry carries its arm,
    // so new protocol vocabulary cannot land without oracle pressure.
    const fields = @typeInfo(model.Message).@"union".field_names;
    try std.testing.expectEqual(fields.len, model.message_kinds.len);
    try std.testing.expectEqual(fields.len, oracle.message_arms.len);
    inline for (fields, 0..) |field_name, i| {
        if (comptime (i < model.message_kinds.len and i < oracle.message_arms.len)) {
            try std.testing.expectEqualStrings(field_name, model.message_kinds[i].tag_name);
            try std.testing.expectEqualStrings(model.message_kinds[i].model_name, oracle.message_arms[i].name);
        }
    }
}

test "route bundle parses primary locators and route-list hints through one owner" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(model.transport.DialShape.route_bundle, model.transport.Known.id.metadata().dial_shape);
    try std.testing.expect(!model.transport.Known.id.metadata().sealed_channel);

    const exporter =
        "ocapn://127.0.0.1%3A9049.tcp?alt-locators=ocapn%3A%2F%2F127.0.0.1%253A9050.tcp%7Cocapn%3A%2F%2Fpeer.keyed-relay";
    var fallback = try model.parseExporterRouteBundleUri(allocator, exporter);
    defer fallback.deinit(allocator);
    try std.testing.expectEqual(model.route_bundle.Source.peer_locator, fallback.source);
    try std.testing.expectEqual(@as(usize, 3), fallback.paths.len);
    try std.testing.expectEqualStrings("ocapn://127.0.0.1%3A9049.tcp", fallback.identity);
    try std.testing.expectEqualStrings("tcp", fallback.paths[0].transport);
    try std.testing.expectEqualStrings("127.0.0.1:9049", fallback.paths[0].designator);
    try std.testing.expectEqualStrings("127.0.0.1:9050", fallback.paths[1].designator);
    try std.testing.expectEqualStrings(model.transport.keyed_relay, fallback.paths[2].transport);

    const routes = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = "ocapn://127.0.0.1%3A9051.tcp|ocapn://relay-key.keyed-relay" },
    }};
    var id = try model.parseIdRouteBundle(allocator, .{
        .transport = model.transport.id,
        .designator = "peer-key",
        .hints = .{ .entries = &routes },
    });
    defer id.deinit(allocator);
    try std.testing.expectEqual(model.route_bundle.Source.id, id.source);
    try std.testing.expectEqual(@as(usize, 2), id.paths.len);
    try std.testing.expectEqualStrings("ocapn://peer-key.id", id.identity);
    try std.testing.expectEqualStrings("127.0.0.1:9051", id.paths[0].designator);
    try std.testing.expectEqualStrings("relay-key", id.paths[1].designator);

    const id_exporter =
        "ocapn://peer-key.id?via=ocapn%3A%2F%2F127.0.0.1%253A9051.tcp%7Cocapn%3A%2F%2Frelay-key.keyed-relay";
    var exported_id = try model.parseExporterRouteBundleUri(allocator, id_exporter);
    defer exported_id.deinit(allocator);
    try std.testing.expectEqual(model.route_bundle.Source.id, exported_id.source);
    try std.testing.expectEqual(@as(usize, 2), exported_id.paths.len);

    const malformed_alt_hints = [_]model.HintEntry{
        .{
            .name = model.transport.hint_via,
            .value = .{ .string = "ocapn://127.0.0.1%3A9051.tcp" },
        },
        .{ .name = model.transport.hint_alt_locators, .value = .{ .boolean = true } },
    };
    try std.testing.expectError(error.UnparseableLocator, model.route_bundle.fromIdLocator(
        allocator,
        .{
            .transport = model.transport.id,
            .designator = "peer-key",
            .hints = .{ .entries = &malformed_alt_hints },
        },
    ));
    try std.testing.expectEqualStrings("ocapn://peer-key.id", exported_id.identity);
    try std.testing.expectEqualStrings("127.0.0.1:9051", exported_id.paths[0].designator);

    const nested_commas =
        "ocapn://peer-key.id?via=ocapn%3A%2F%2Froute-key.noise-tcp%3Fdirect-addresses%3D127.0.0.1%253A9051%252C127.0.0.1%253A9052";
    var nested = try model.parseExporterRouteBundleUri(allocator, nested_commas);
    defer nested.deinit(allocator);
    try std.testing.expectEqual(model.route_bundle.Source.id, nested.source);
    try std.testing.expectEqual(@as(usize, 1), nested.paths.len);
    try std.testing.expectEqualStrings(model.transport.noise_tcp, nested.paths[0].transport);
    try std.testing.expectEqualStrings("route-key", nested.paths[0].designator);
    try std.testing.expectEqual(@as(usize, 1), nested.paths[0].hints.entries.len);
    try std.testing.expectEqualStrings(model.transport.hint_direct_addresses, nested.paths[0].hints.entries[0].name);
    try std.testing.expectEqualStrings(
        "127.0.0.1:9051,127.0.0.1:9052",
        nested.paths[0].hints.entries[0].value.string,
    );

    const direct_hints = [_]model.HintEntry{.{
        .name = model.transport.hint_direct_addresses,
        .value = .{ .string = "127.0.0.1:9051,127.0.0.1:9052" },
    }};
    const direct_uri = try model.uri.writePeer(allocator, .{
        .transport = model.transport.noise_tcp,
        .designator = "route-key",
        .hints = .{ .entries = &direct_hints },
    });
    defer allocator.free(direct_uri);
    try std.testing.expectEqualStrings(
        "ocapn://route-key.noise-tcp?direct-addresses=127.0.0.1%3A9051,127.0.0.1%3A9052",
        direct_uri,
    );
    const rendered_routes = try std.fmt.allocPrint(
        allocator,
        "{s}|ocapn://relay-key.keyed-relay",
        .{direct_uri},
    );
    defer allocator.free(rendered_routes);
    const rendered_hints = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = rendered_routes },
    }};
    var rendered = try model.parseIdRouteBundle(allocator, .{
        .transport = model.transport.id,
        .designator = "peer-key",
        .hints = .{ .entries = &rendered_hints },
    });
    defer rendered.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), rendered.paths.len);
    try std.testing.expectEqualStrings(
        "127.0.0.1:9051,127.0.0.1:9052",
        rendered.paths[0].hints.entries[0].value.string,
    );

    const moved_locator = try model.uri.parsePeer(
        allocator,
        "ocapn://127.0.0.1%3A9047.tcp?direct-addresses=127.0.0.1%3A9047",
    );
    const moved_transport = moved_locator.transport.ptr;
    const moved_designator = moved_locator.designator.ptr;
    var moved = try model.route_bundle.fromOwnedPeerLocator(allocator, moved_locator);
    defer moved.deinit(allocator);
    try std.testing.expectEqual(moved_transport, moved.paths[0].transport.ptr);
    try std.testing.expectEqual(moved_designator, moved.paths[0].designator.ptr);
}

test "route bundle refuses malformed and over-budget route lists" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.UnparseableLocator,
        model.parseExporterRouteBundleUri(allocator, "ocapn://127.0.0.1%3A9049.tcp?alt-locators=not-a-peer-uri"),
    );

    var too_many = std.ArrayList(u8).empty;
    defer too_many.deinit(allocator);
    for (0..model.route_bundle.max_route_list_count + 1) |index| {
        if (index != 0) try too_many.append(allocator, '|');
        try too_many.appendSlice(allocator, "ocapn://127.0.0.1%3A9051.tcp");
    }
    const count_limited = try exporterUriWithAlternatives(allocator, too_many.items);
    defer allocator.free(count_limited);
    try std.testing.expectError(error.UnparseableLocator, model.parseExporterRouteBundleUri(allocator, count_limited));

    var at_limit = std.ArrayList(u8).empty;
    defer at_limit.deinit(allocator);
    for (0..model.route_bundle.max_route_list_count - 1) |index| {
        if (index != 0) try at_limit.append(allocator, '|');
        try at_limit.appendSlice(allocator, "ocapn://127.0.0.1%3A9051.tcp");
    }
    const accepted_at_limit = try exporterUriWithAlternatives(allocator, at_limit.items);
    defer allocator.free(accepted_at_limit);
    var full = try model.parseExporterRouteBundleUri(allocator, accepted_at_limit);
    defer full.deinit(allocator);
    try std.testing.expectEqual(model.route_bundle.max_route_list_count, full.paths.len);

    var full_fallbacks = std.ArrayList(u8).empty;
    defer full_fallbacks.deinit(allocator);
    for (0..model.route_bundle.max_route_list_count) |index| {
        if (index != 0) try full_fallbacks.append(allocator, '|');
        try full_fallbacks.appendSlice(allocator, "ocapn://127.0.0.1%3A9051.tcp");
    }
    const primary_plus_full_list = try exporterUriWithAlternatives(allocator, full_fallbacks.items);
    defer allocator.free(primary_plus_full_list);
    try std.testing.expectError(
        error.UnparseableLocator,
        model.parseExporterRouteBundleUri(allocator, primary_plus_full_list),
    );

    try std.testing.expectError(
        error.UnparseableLocator,
        model.parseExporterRouteBundleUri(
            allocator,
            "ocapn://127.0.0.1%3A9049.tcp?alt-locators=ocapn%3A%2F%2Fpeer.id%3Fvia%3Docapn%253A%252F%252Fpeer.iroh",
        ),
    );
    try std.testing.expectError(
        error.UnparseableLocator,
        model.parseExporterRouteBundleUri(
            allocator,
            "ocapn://127.0.0.1%3A9049.tcp?alt-locators=ocapn%3A%2F%2F127.0.0.1%253A9050.tcp%3Falt-locators%3Docapn%253A%252F%252F127.0.0.1%25253A9051.tcp",
        ),
    );

    const duplicate_alt_hints = [_]model.HintEntry{
        .{
            .name = model.transport.hint_alt_locators,
            .value = .{ .string = "ocapn://127.0.0.1%3A9050.tcp" },
        },
        .{
            .name = model.transport.hint_alt_locators,
            .value = .{ .string = "ocapn://127.0.0.1%3A9051.tcp" },
        },
    };
    try std.testing.expectError(error.UnparseableLocator, model.parseRouteBundleLocator(allocator, .{
        .transport = model.transport.tcp,
        .designator = "127.0.0.1:9049",
        .hints = .{ .entries = &duplicate_alt_hints },
    }));

    const byte_alt_hints = [_]model.HintEntry{.{
        .name = model.transport.hint_alt_locators,
        .value = .{ .bytes = "ocapn://127.0.0.1%3A9050.tcp" },
    }};
    try std.testing.expectError(error.UnparseableLocator, model.parseRouteBundleLocator(allocator, .{
        .transport = model.transport.tcp,
        .designator = "127.0.0.1:9049",
        .hints = .{ .entries = &byte_alt_hints },
    }));
}
