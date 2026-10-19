//! Three-party redeem over iroh: a recipient's runtime dials the exporter by
//! node id inside the call that receives the introduction (ADR-0019).
//!
//!   E (exporter)   `driver.Server`, publishes the widget
//!   G (gifter)     `driver.Server`, fetches E's widget and introduces it
//!   R (recipient)  `driver.Session`, redeems by dialing E by node id alone
//!
//! Every party rides a managed iroh resident, and the `local_discovery` book
//! resolves each node id in process. R's `call` returns the widget only after
//! its runtime has dialed E, proved E's key over QUIC, and withdrawn the
//! gift, so R's poke reaches E on a session R owns, not through G.
//!
//! Not part of the hermetic `zig build check`: it links the Rust sidecar
//! staticlib, so it runs as the sibling step `zig build iroh-redeem`.

const std = @import("std");
const glowcap = @import("glowcap");
const iroh = @import("iroh");
const harness = @import("interop_harness");

const model = glowcap.ocapn.model;
const crypto = glowcap.foundation.crypto;
const driver = glowcap.driver;

const deadline_ms: u64 = 30_000;
const poked = "poked directly at the exporter";

const opts: driver.SessionOptions = .{
    .frame_cap = 4096,
    .handshake = .{ .ms = 20_000 },
    .settle = .{ .ms = 20_000 },
};

const exporter_seed: [32]u8 = @splat(0x2e);
const gifter_seed: [32]u8 = @splat(0x26);

const Widget = harness.StaticReplyBehavior("poke", poked);

const Introducer = struct {
    widget: driver.Capability,

    pub fn handle(self: *Introducer, ht: *driver.HostTurn, verb: []const u8, args: driver.Args) !driver.Value {
        _ = ht;
        _ = args;
        if (!std.mem.eql(u8, verb, "introduce")) return error.NoSuchMethod;
        return .{ .capability = self.widget };
    }
};

/// One party's iroh endpoint and the resident its runtime polls.
const Endpoint = struct {
    endpoint: iroh.Resident,
    adapter: iroh.MultiplexedAdapter,
    id_buf: [iroh.node_id_len]u8 = undefined,

    fn init(self: *Endpoint, io: std.Io, allocator: std.mem.Allocator, seed: ?*const [32]u8) !void {
        self.endpoint = try iroh.Resident.init(io, seed, .{ .reachability = .local_discovery });
        // best-effort: this unwind returns the adapter's init error, and a failed endpoint close would only mask it.
        errdefer self.endpoint.deinit() catch {};
        self.adapter = try iroh.MultiplexedAdapter.init(allocator, &self.endpoint);
    }

    fn deinit(self: *Endpoint) void {
        if (self.adapter.deinit()) |failure| std.log.err("iroh adapter: {s}", .{failure.primaryName()});
        self.endpoint.deinit() catch |err| std.log.err("iroh endpoint: {s}", .{@errorName(err)});
    }

    fn registration(self: *Endpoint) driver.HostRuntime.ProviderRegistration {
        return .{ .profile = iroh.transport_profile, .resident = self.adapter.multiplexed() };
    }

    fn locator(self: *Endpoint) model.PeerLocator {
        return .{ .transport = iroh.transport_name, .designator = self.endpoint.nodeId(&self.id_buf), .hints = model.Hints.emptyFalse() };
    }

    /// A Server keyed with the endpoint's own seed: iroh is a key-designator
    /// transport, so the session identity must be the node id dialers pin.
    fn listen(self: *Endpoint, io: std.Io, allocator: std.mem.Allocator, seed: [32]u8, providers: *[1]driver.HostRuntime.ProviderRegistration) !*driver.Server {
        providers.* = .{self.registration()};
        return driver.listen(allocator, io, .{ .residents = providers }, iroh.transport_name, .{ .designator = "" }, .{
            .keyed = crypto.SecretKey.fromSeed(seed),
        }, opts);
    }
};

/// Accept and serve every session `server` receives until `done`.
fn serveAll(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    var sessions: [4]*driver.Session = undefined;
    var accepted: usize = 0;
    defer for (sessions[0..accepted]) |session| session.deinit();
    while (!done.load(.acquire)) {
        if (accepted < sessions.len and try server.waitAcceptable(0)) {
            sessions[accepted] = try server.accept();
            accepted += 1;
            // An accepted session dispatches nothing until its owner attends.
            try sessions[accepted - 1].attend();
            continue;
        }
        _ = try server.runtime.stepAny(10);
    }
}

/// G: fetch E's widget over G's own runtime, publish the introducer, serve.
fn serveGifter(
    gifter: *driver.Server,
    exporter_locator: model.PeerLocator,
    ready: *std.atomic.Value(bool),
    published: *std.atomic.Value(bool),
    done: *std.atomic.Value(bool),
) anyerror!void {
    defer ready.store(true, .release);
    const to_exporter = try gifter.runtime.connectLocator(exporter_locator, .inherit);
    const exporter = try driver.Session.adopt(gifter.runtime, to_exporter);
    defer exporter.deinit();
    const widget = try exporter.fetch("widget");
    try gifter.publish("introducer", Introducer, .{ .widget = widget });
    published.store(true, .release);
    ready.store(true, .release);
    try serveAll(gifter, done);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var exporter_endpoint: Endpoint = undefined;
    try exporter_endpoint.init(io, allocator, &exporter_seed);
    defer exporter_endpoint.deinit();
    var gifter_endpoint: Endpoint = undefined;
    try gifter_endpoint.init(io, allocator, &gifter_seed);
    defer gifter_endpoint.deinit();
    var recipient_endpoint: Endpoint = undefined;
    try recipient_endpoint.init(io, allocator, null);
    defer recipient_endpoint.deinit();

    var exporter_providers: [1]driver.HostRuntime.ProviderRegistration = undefined;
    var exporter = try exporter_endpoint.listen(io, allocator, exporter_seed, &exporter_providers);
    defer exporter.deinit();
    try exporter.publish("widget", Widget, .{});
    var gifter_providers: [1]driver.HostRuntime.ProviderRegistration = undefined;
    var gifter = try gifter_endpoint.listen(io, allocator, gifter_seed, &gifter_providers);
    defer gifter.deinit();

    var done = std.atomic.Value(bool).init(false);
    var gifter_ready = std.atomic.Value(bool).init(false);
    var gifter_published = std.atomic.Value(bool).init(false);
    var exporter_future = try io.concurrent(serveAll, .{ exporter, &done });
    var gifter_future = try io.concurrent(serveGifter, .{ gifter, exporter_endpoint.locator(), &gifter_ready, &gifter_published, &done });
    var joined = false;
    defer if (!joined) {
        done.store(true, .release);
        gifter_future.await(io) catch |err| std.debug.print("iroh-redeem: gifter: {s}\n", .{@errorName(err)});
        exporter_future.await(io) catch |err| std.debug.print("iroh-redeem: exporter: {s}\n", .{@errorName(err)});
    };
    try harness.untilFlag(io, deadline_ms, &gifter_ready);
    if (!gifter_published.load(.acquire)) return error.GifterSetupFailed;

    // R: dial G, receive the introduction, and poke the widget directly.
    const recipient_providers = [_]driver.HostRuntime.ProviderRegistration{recipient_endpoint.registration()};
    const to_gifter = try driver.connect(allocator, io, .{ .residents = &recipient_providers }, gifter_endpoint.locator(), .ephemeral, opts);
    defer to_gifter.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const introducer = try to_gifter.fetch("introducer");
    const widget = switch (try to_gifter.call(introducer, "introduce", &.{}, arena.allocator())) {
        .fulfilled => |value| if (value == .capability) value.capability else return error.NoIntroduction,
        .broken => |reason| {
            std.debug.print("iroh-redeem: introduce broke: {s}\n", .{reason});
            return error.NoIntroduction;
        },
    };
    try expectHomedAt(to_gifter, widget, exporter_endpoint.locator().designator);
    switch (try to_gifter.call(widget, "poke", &.{}, arena.allocator())) {
        .fulfilled => |value| if (value != .string or !std.mem.eql(u8, value.string, poked)) return error.WrongReply,
        .broken => return error.WrongReply,
    }

    done.store(true, .release);
    joined = true;
    const gifter_result = gifter_future.await(io);
    const exporter_result = exporter_future.await(io);
    try gifter_result;
    try exporter_result;
    std.debug.print("iroh-redeem: OK, R redeemed G's introduction by dialing E over iroh and poked the widget directly\n", .{});
}

/// The widget lives on R's own session to E, whose key QUIC proved, not on
/// R's session to G.
fn expectHomedAt(to_gifter: *driver.Session, widget: driver.Capability, exporter_id: []const u8) !void {
    const core = to_gifter.runtime.core;
    const target = core.capabilities.resolve(widget) orelse return error.UnknownCapability;
    const peer_handle = switch (target) {
        .remote => |remote| remote.peer_handle,
        else => return error.MissingExporterRoute,
    };
    const home = core.sessionForPeer(peer_handle) orelse return error.MissingExporterSession;
    if (home == to_gifter.hs) return error.GiftWasProxied;
    const identity = try core.partnerIdentity(home);
    if (!std.mem.eql(u8, identity.designator, exporter_id)) return error.WrongExporter;
    if (identity.provenance != .authenticated_transport) return error.UnprovenExporter;
}
