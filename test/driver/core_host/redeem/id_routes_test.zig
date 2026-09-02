//! Identity-first sturdyref routing at the Host seam: feature admission,
//! concrete route staging, fail-closed identity checks, and reuse of
//! an authenticated session for a later `via` path.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../../support/core_host.zig");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const crypto = glowcap.foundation.crypto;

const Host = driver.core.Host;

const harness = @import("../harness.zig");
const frame_cap = harness.frame_cap;
const Widget = harness.Widget;
const Pair = harness.Pair;
const shuttleAll = harness.shuttleAll;
const publishAndOpenAccepted = harness.publishAndOpenAccepted;
const ParkedDial = harness.ParkedDial;
const pumpToQuiescence = harness.pumpToQuiescence;
const CapturedRef = harness.CapturedRef;
const keyedDesignator = harness.keyedDesignator;
const nextRouteOptions = harness.nextRouteOptions;

test "core host: pending id enliven reuses an authenticated via session" {
    const allocator = std.testing.allocator;
    const client_seed = @as([32]u8, @splat(0x6c));
    const server_seed = @as([32]u8, @splat(0x6d));
    var client = test_host.init(allocator, client_seed, nextRouteOptions());
    defer client.deinit();
    var server = test_host.init(allocator, server_seed, nextRouteOptions());
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |dial| allocator.free(dial.designator);
        dials.deinit(allocator);
    }

    const client_key = keyedDesignator(client_seed);
    const server_key = keyedDesignator(server_seed);
    const accepted = try publishAndOpenAccepted(&server, model.transport.iroh, &server_key, &.{});
    try server.bindVerifiedChannelKey(accepted, &client_key);
    _ = try accepted.served.publish(&accepted.host.vat, "widget", Widget, .{});
    try client.ensureAdvertisedLocator(model.transport.iroh);

    const direct_hints = [_]model.HintEntry{.{
        .name = model.transport.hint_direct_addresses,
        .value = .{ .string = "127.0.0.1:7818" },
    }};
    const primary = try model.uri.writePeer(allocator, .{
        .transport = model.transport.noise_tcp,
        .designator = &server_key,
        .hints = .{ .entries = &direct_hints },
    });
    defer allocator.free(primary);
    const alternate = try model.uri.writePeer(allocator, .{
        .transport = model.transport.iroh,
        .designator = &server_key,
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(alternate);
    const routes = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ primary, alternate });
    defer allocator.free(routes);
    const via = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = routes },
    }};
    const vow_id = try client.enlivenSelectOrDial(.{
        .peer = .{
            .transport = model.transport.id,
            .designator = &server_key,
            .hints = .{ .entries = &via },
        },
        .swissnum = "widget",
    });
    const first = (try client.nextAction()).?;
    try std.testing.expect(first == .dial);
    const ticket = first.dial.ticket;
    try std.testing.expectEqualStrings(model.transport.noise_tcp, client.pendingDial(ticket, 0).?.locator.transport);

    const dialed = try client.openDialedLocator(.{
        .transport = model.transport.iroh,
        .designator = &server_key,
        .hints = model.Hints.emptyFalse(),
    });
    try client.bindVerifiedChannelKey(dialed, &server_key);
    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(dialed.sessionOpen());
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    try std.testing.expectEqual(@as(usize, 1), dials.items[0].route_index);

    try client.dialFailed(ticket, 0, "primary unreachable");
    try std.testing.expect(try client.exporterDialed(ticket, 1, dialed));

    var settled = false;
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        const moved = try shuttleAll(&.{pair});
        var acted = false;
        for ([_]*Host{ &client, &server }) |host| {
            while (try host.nextAction()) |action| {
                acted = true;
                switch (action) {
                    .dial => return error.UnexpectedDial,
                    .cancel_dial => |cancel| try host.dialCancelled(cancel.ticket, cancel.route_index),
                    .settled => |result| if (result.vow_id == vow_id) {
                        try std.testing.expect(result.value == .reference);
                        settled = true;
                    },
                    else => {},
                }
            }
        }
        if (!moved and !acted) break;
    }
    try std.testing.expect(client.pendingDial(ticket, 1) == null);
    try std.testing.expect(settled);
}

test "core host: id enliven reuses an authenticated baseline session but not a finishing one" {
    const allocator = std.testing.allocator;
    const client_seed = @as([32]u8, @splat(0x71));
    const server_seed = @as([32]u8, @splat(0x72));
    var client = test_host.init(allocator, client_seed, nextRouteOptions());
    defer client.deinit();
    var server = test_host.init(allocator, server_seed, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |dial| allocator.free(dial.designator);
        dials.deinit(allocator);
    }

    const client_key = keyedDesignator(client_seed);
    const server_key = keyedDesignator(server_seed);
    const accepted = try publishAndOpenAccepted(&server, model.transport.iroh, &server_key, &.{});
    try server.bindVerifiedChannelKey(accepted, &client_key);
    _ = try accepted.served.publish(&accepted.host.vat, "widget", Widget, .{});
    try client.ensureAdvertisedLocator(model.transport.iroh);
    const dialed = try client.openDialedLocator(.{
        .transport = model.transport.iroh,
        .designator = &server_key,
        .hints = model.Hints.emptyFalse(),
    });
    try client.bindVerifiedChannelKey(dialed, &server_key);
    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expectEqual(model.CaptpVersion.v1_0, dialed.captpVersion());

    const route = try std.fmt.allocPrint(allocator, "ocapn://{s}.iroh", .{server_key[0..]});
    defer allocator.free(route);
    const via = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = route },
    }};
    const sturdyref: model.SturdyRef = .{
        .peer = .{
            .transport = model.transport.id,
            .designator = &server_key,
            .hints = .{ .entries = &via },
        },
        .swissnum = "widget",
    };
    var fetched = CapturedRef{};
    try client.vowOn(try client.enlivenSelectOrDial(sturdyref), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    _ = try fetched.require();
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);

    try client.beginSessionClose(dialed, .{ .finish = .unbounded }, 0);
    _ = try client.enlivenSelectOrDial(sturdyref);
    var saw_dial = false;
    while (try client.nextAction()) |action| switch (action) {
        .dial => saw_dial = true,
        else => {},
    };
    try std.testing.expect(saw_dial);
}

test "core host: failed select-or-dial admission publishes no Node dial" {
    var saw_refusal = false;
    var saw_success = false;
    for (0..32) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        failing.fail_index = fail_index;
        var host = test_host.init(failing.allocator(), @as([32]u8, @splat(0x73)), Host.Options.withFrameCap(frame_cap));
        defer host.deinit();

        const result = host.enlivenSelectOrDial(harness.tcpSturdyref("127.0.0.1:7820", "widget"));
        if (result) |_| {
            saw_success = true;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), host.node.pendingDialCount());
            try std.testing.expect(!host.node.hasAction());
            saw_refusal = true;
        }
    }
    try std.testing.expect(saw_refusal);
    try std.testing.expect(saw_success);
}

test "core host: id sturdyrefs require opt-in before select-or-dial" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x0e)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const key = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x11))).publicKey().toDesignator();
    const id_routes = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = "ocapn://127.0.0.1%3A7814.tcp" },
    }};
    try std.testing.expectError(driver.core.HostError.PeerIdentityMismatch, host.enlivenSelectOrDial(.{
        .peer = .{
            .transport = model.transport.id,
            .designator = &key,
            .hints = .{ .entries = &id_routes },
        },
        .swissnum = "widget",
    }));

    try std.testing.expect(try host.nextAction() == null);
}

test "core host: id sturdyrefs stage the selected concrete route when opted in" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x10)), nextRouteOptions());
    defer host.deinit();

    const key = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x12))).publicKey().toDesignator();
    const route = try std.fmt.allocPrint(allocator, "ocapn://{s}.iroh", .{key[0..]});
    defer allocator.free(route);
    const id_routes = [_]model.HintEntry{.{
        .name = model.transport.hint_via,
        .value = .{ .string = route },
    }};
    const vow_id = try host.enlivenSelectOrDial(.{
        .peer = .{
            .transport = model.transport.id,
            .designator = &key,
            .hints = .{ .entries = &id_routes },
        },
        .swissnum = "widget",
    });
    try std.testing.expect(vow_id != 0);
    const action = (try host.nextAction()).?;
    try std.testing.expect(action == .dial);
    const pending = host.pendingDial(action.dial.ticket, 0) orelse return error.MissingPendingDial;
    try std.testing.expectEqualStrings(model.transport.iroh, pending.locator.transport);
    try std.testing.expectEqualStrings(&key, pending.locator.designator);
    try std.testing.expect(pending.demanded_partner_key != null);
}

test "core host: id sturdyrefs validate but never dial weak fallback paths" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x13)), nextRouteOptions());
    defer host.deinit();

    const key = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x14))).publicKey().toDesignator();
    const route = try std.fmt.allocPrint(allocator, "ocapn://{s}.iroh", .{key[0..]});
    defer allocator.free(route);
    const hints = [_]model.HintEntry{
        .{ .name = model.transport.hint_via, .value = .{ .string = route } },
        .{ .name = model.transport.hint_alt_locators, .value = .{ .string = "ocapn://baseline-service.onion" } },
    };
    const vow_id = try host.enlivenSelectOrDial(.{
        .peer = .{
            .transport = model.transport.id,
            .designator = &key,
            .hints = .{ .entries = &hints },
        },
        .swissnum = "widget",
    });
    const first = (try host.nextAction()).?;
    try std.testing.expect(first == .dial);
    try std.testing.expectEqualStrings(model.transport.iroh, host.pendingDial(first.dial.ticket, 0).?.locator.transport);

    try host.dialFailed(first.dial.ticket, 0, "identity route unavailable");
    const failed = (try host.nextAction()).?;
    try std.testing.expect(failed == .failed);
    try std.testing.expectEqual(vow_id, failed.failed.vow_id);
    try std.testing.expect(try host.nextAction() == null);
}
