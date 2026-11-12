//! Stream transports on HostRuntime through a completion backend
//! (ADR-0018): `net.completion_resident` presents the platform TCP backend as
//! a multiplexed resident, so the recipient's first dial and the redeem dial a
//! give provokes inside a blocking call both run on pooled completion I/O, and
//! no wire holds a read buffer.

const std = @import("std");
const wait = @import("../../support/wait.zig");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = net.tcp;

const fixtures = @import("residents.zig");
const exporterServe = fixtures.exporterServe;
const gifterServe = fixtures.gifterServe;
const frame_cap = fixtures.frame_cap;
const opts = fixtures.opts;

const TcpResident = net.completion_resident.Resident(net.Backend, tcp.CompletionPolicy(net.Backend));

/// A resident outlives its runtime and retires the operations it still owes.
fn retire(resident: *TcpResident) void {
    resident.closeAndDrain(2_000) catch |err| std.debug.panic("completion resident drain failed: {t}", .{err});
    resident.deinit();
}

test "completion-backed residents accept, dial, call, and redeem a give over TCP (ADR-0018)" {
    if (!(@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var done = std.atomic.Value(bool).init(false);

    // The exporter accepts through a completion resident of its own; the
    // gifter reaches it over the stream netlayer, so both shapes interoperate.
    var exporter_resident = try TcpResident.init(allocator, try net.Backend.init(allocator, 64, 16, frame_cap), .{});
    defer retire(&exporter_resident);
    const exporter_providers = [_]driver.HostRuntime.ProviderRegistration{.{
        .profile = model.transport.Known.tcp.metadata(),
        .resident = exporter_resident.resident(),
    }};
    var exporter = try driver.listen(allocator, io, .{ .residents = &exporter_providers }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer exporter.deinit();
    const exporter_designator = try allocator.dupe(u8, (try exporter.advertisedLocator()).designator);
    defer allocator.free(exporter_designator);

    var gifter = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer gifter.deinit();
    const gifter_locator = try model.clonePeerLocator(allocator, try gifter.advertisedLocator());
    defer model.freePeerLocator(allocator, gifter_locator);

    var exporter_joined = false;
    var exporter_future = try io.concurrent(exporterServe, .{ exporter, &done });
    errdefer if (!exporter_joined) {
        done.store(true, .release);
        wait.joinedUnwinding("exporter", exporter_future.await(io));
    };
    var gifter_joined = false;
    var gifter_future = try io.concurrent(gifterServe, .{ gifter, exporter_designator, &done });
    errdefer if (!gifter_joined) {
        done.store(true, .release);
        wait.joinedUnwinding("gifter", gifter_future.await(io));
    };

    // The recipient has no stream netlayer: every dial goes through the
    // completion resident or fails with `UnknownTransport`.
    var resident = try TcpResident.init(allocator, try net.Backend.init(allocator, 64, 16, frame_cap), .{});
    defer retire(&resident);
    var recipient = try driver.HostRuntime.init(allocator, io, .{}, .ephemeral, opts);
    defer recipient.deinit();
    _ = try recipient.addResident(model.transport.Known.tcp.metadata(), resident.resident());

    const gifter_session = try recipient.connectLocator(gifter_locator, .inherit);
    const view = try driver.Session.adopt(&recipient, gifter_session);
    defer view.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const introducer = try view.fetch("introducer");
    const introduced = try view.call(introducer, "introduce", &.{}, arena);
    if (introduced == .broken) std.debug.print("introduce broke: {s}\n", .{introduced.broken.detail});
    try std.testing.expect(introduced == .fulfilled);
    try std.testing.expect(introduced.fulfilled == .capability);
    // The redeem dial the give provoked went through the resident too.
    try std.testing.expectEqual(@as(usize, 2), resident.conns.count());
    // The resident lends each received chunk, so neither the wires nor the
    // runtime hold a read buffer.
    try std.testing.expectEqual(@as(usize, 0), recipient.resident_read_scratch.len);

    const greeted = try view.call(introduced.fulfilled.capability, "greet", &.{}, arena);
    try std.testing.expect(greeted == .fulfilled and greeted.fulfilled == .string);
    try std.testing.expectEqualStrings("hello from the exporter", greeted.fulfilled.string);

    // A serving loop that failed fails the test, whatever the client saw.
    done.store(true, .release);
    gifter_joined = true;
    exporter_joined = true;
    const gifter_future_result = gifter_future.await(io);
    const exporter_future_result = exporter_future.await(io);
    try gifter_future_result;
    try exporter_future_result;
}
