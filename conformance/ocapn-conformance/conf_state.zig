//! Per-process conformance tables: the uuid→address map the
//! `tcp-testing-only` dialer consults, and the per-session bag the
//! suite interceptors write (resolver map, pending gifter enlivens,
//! deferred Host effects).
//!
//! `pancake_peer.zig` owns the bootstrap actors, the promise-resolver
//! interceptor, and `main`. Gift/recipient interceptors live in
//! `handoff.zig`.

const std = @import("std");
const pancake = @import("pancake");
const peer_options = @import("ocapn_peer_options");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const net = pancake.net;
const driver = pancake.driver;
const tcp = net.tcp;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const PeerHandle = engine.PeerHandle;

const use_onion = peer_options.use_onion;

/// The ordinary suite path uses a bare UUID plus address hints. The dedicated
/// onion path uses the standardized self-routing onion service designator.
pub const transport_name = if (use_onion) model.transport.onion else "tcp-testing-only";

pub const CAR_FACTORY_BUILDER = "JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ";
pub const ECHO = "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w";
pub const GREETER = "VMDDd1voKWarCe2GvgLbxbVFysNzRPzx";
pub const PROMISE_RESOLVER = "IokCxYmMj04nos2JN1TDoY1bT8dXh6Lr";
pub const STURDYREF_ENLIVENER = "gi02I1qghIwPiKGKleCQAOhpy3ZtYRpB";

/// uuid → `host:port`, filled on the loop thread whenever a give or sturdyref
/// names a `tcp-testing-only` exporter, read when the Host's redeem or gifter
/// dial resolves that locator. Single loop thread owns it, so no lock.
pub const AddrTable = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged([]u8) = .{},

    pub fn put(self: *AddrTable, uuid: []const u8, hostport: []const u8) void {
        const gop = self.entries.getOrPut(self.allocator, uuid) catch return;
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.allocator.dupe(u8, uuid) catch {
                // By slot, not by key: the slot's key is still undefined, and a
                // keyed remove would read it to compare.
                self.entries.removeByPtr(gop.key_ptr);
                return;
            };
        }
        gop.value_ptr.* = self.allocator.dupe(u8, hostport) catch "";
    }

    fn get(self: *const AddrTable, uuid: []const u8) ?[]const u8 {
        return self.entries.get(uuid);
    }

    pub fn deinit(self: *AddrTable) void {
        var it = self.entries.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.entries.deinit(self.allocator);
    }
};

/// Process-global address table. The conformance peer is one Host on one loop
/// in one process, and the loop's `DialResolver.resolve` is a free function with no
/// context slot, so the table it consults lives here. `main` owns its storage.
pub var g_addrs: ?*AddrTable = null;

/// The loop's OCapN-locator → dial-target resolver. `tcp-testing-only` resolves
/// through the address table (the designator is a uuid, the address a hint we
/// recorded); every other transport defers to the standard `tcp.DialResolver`.
const ConformanceLocator = struct {
    pub fn resolve(locator: model.PeerLocator) !std.Io.net.IpAddress {
        if (std.mem.eql(u8, locator.transport, transport_name)) {
            const table = g_addrs orelse return error.InvalidAddress;
            const hostport = table.get(locator.designator) orelse return error.InvalidAddress;
            return tcp.parseDesignator(hostport);
        }
        return tcp.DialResolver.resolve(locator);
    }
};

pub const ConfLoop = if (use_onion)
    net.OnionLoop
else
    net.completion.Loop(net.Backend, ConformanceLocator);
pub const ConfBridge = driver.Bridge(ConfLoop);

/// Per-accepted-session conformance state: the resolver→answer map the promise
/// resolver fills and the serve interceptor reads. Allocated at adoption
/// (`publishConf`), freed at close (`confFreeConnCtx`).
pub const ConfCtx = struct {
    shared: *Shared,
    session: *HostSession,
    host_serve_options: driver.core.ServeOptions,
    resolver_map: std.AutoHashMapUnmanaged(u64, engine.AnswerTarget) = .{},
};

/// A gifter enliven waiting for an exporter session to open before its fetch
/// can go out — the no-prior-connection gifter path. Bounded by concurrent
/// enlivens; `runGifterFetch` consumes one when its exporter opens.
pub const PendingEnliven = struct {
    exporter_uuid: []u8,
    swiss: []u8,
    recipient_peer: PeerHandle,
    answer: engine.AnswerTarget,
};

/// A Host-driving effect classified under the before-serve callback latch and
/// executed after Host.serveEvent unwinds. The hook may inspect and claim an
/// event, but Host.fetch/acceptInlineGive and Bridge.dialOutbound are deliberately
/// top-level operations and reject callback re-entry.
pub const DeferredAction = union(enum) {
    accept_give: struct {
        session: *HostSession,
        give: model.HandoffGive,
    },
    fetch: struct {
        exporter: *HostSession,
        swiss: []u8,
        recipient_peer: PeerHandle,
        answer: engine.AnswerTarget,
    },
    dial: []u8,

    pub fn deinit(self: DeferredAction, allocator: std.mem.Allocator) void {
        switch (self) {
            .accept_give => |action| model.freeHandoffGive(allocator, action.give),
            .fetch => |action| allocator.free(action.swiss),
            .dial => |designator| allocator.free(designator),
        }
    }
};

pub const Shared = struct {
    allocator: std.mem.Allocator,
    host: *Host,
    bridge: *ConfBridge,
    /// Per-session conformance state, keyed by session. Only accepted sessions
    /// (desks) register here; dialed exporter/redeem legs never do.
    confs: std.AutoHashMapUnmanaged(PeerHandle, *ConfCtx) = .{},
    /// Gifter enlivens whose exporter session was not yet open when the enliven
    /// arrived; drained in `on_open`.
    pending: std.ArrayListUnmanaged(PendingEnliven) = .empty,
    /// Host-driving effects held until the before-serve callback latch opens.
    deferred: std.ArrayListUnmanaged(DeferredAction) = .empty,
    /// Exact failure from a callback that has no return slot. Drained at the
    /// next `confServe` boundary so a gifter intercept cannot vanish as success.
    callback_err: ?anyerror = null,

    pub fn noteCallbackErr(self: *Shared, err: anyerror) void {
        if (self.callback_err == null) self.callback_err = err;
    }

    pub fn deinit(self: *Shared) void {
        var it = self.confs.valueIterator();
        while (it.next()) |c| {
            c.*.resolver_map.deinit(self.allocator);
            self.allocator.destroy(c.*);
        }
        self.confs.deinit(self.allocator);
        for (self.pending.items) |p| {
            self.allocator.free(p.exporter_uuid);
            self.allocator.free(p.swiss);
        }
        self.pending.deinit(self.allocator);
        for (self.deferred.items) |action| action.deinit(self.allocator);
        self.deferred.deinit(self.allocator);
    }
};
