//! The owning, one-call driver surface: `Connection` and `Server`.
//!
//! `connect`, `connectUriOwned`, and `listen` each hand back an owning bundle
//! that holds the peer and both read/write buffers, so a native Zig app connects
//! (or accepts) in one call instead of stitching a peer, two buffers, and a
//! borrowing constructor together by hand. Each forwards to the borrowing
//! `ConnectedVat` surface in `connected_vat.zig`; the shared vocabulary lives in
//! the driver root (`mod.zig`). This is the native-Zig spelling of the
//! `Connection` every binding exposes.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const net = @import("net");

const connected_vat = @import("connected_vat.zig");
const ConnectedVat = connected_vat.ConnectedVat;
const connectVia = connected_vat.connectVia;
const acceptVia = connected_vat.acceptVia;

const driver = @import("mod.zig");
const Settled = driver.Settled;
const Capability = driver.Capability;
const Identity = driver.Identity;

/// Options for `connect` and `listen`. `frame_cap` sizes the owned read/write
/// buffers and the session's `max_frame_bytes` limit together, so the buffers
/// and the limit cannot drift apart. `codec` is the wire grammar the negotiating
/// peer encodes in; it defaults to `.syrup`, the Goblins-interop target, and a
/// caller speaking Cap'n Proto sets `.capnp`.
pub const ConnectionOptions = struct {
    frame_cap: usize = 1 << 16,
    codec: model.CodecId = .syrup,
};

/// An owning connection, the one object a native Zig application holds. It
/// owns the peer and both read/write buffers, so a caller connects (or
/// accepts) with one call instead of stitching a negotiating peer, two
/// buffers, and `connectVia` together by hand. Heap-pinned because the
/// connected vat borrows the peer: the pointer `connect` and `Server.accept`
/// return is stable for the connection's life, and `Connection.deinit` frees
/// the whole bundle (`close` is the C vocabulary for a shutdown lever that
/// never frees; native Zig frees through `deinit`). The explicit `connectVia` / `acceptVia` (and the tcp-named
/// `connectTcp` / `acceptTcp`) path remains available when the caller wants to
/// own the peer and buffers and see every allocation at the call site. This
/// type is the native-Zig spelling of the `Connection` every binding exposes.
pub const Connection = struct {
    cv: ConnectedVat,
    peer: engine.Peer,
    read_buf: []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,

    /// Tear down the connection and free the peer and buffers this owns.
    pub fn deinit(self: *Connection) void {
        self.cv.deinit();
        self.freeShell();
    }

    /// Fetch a partner's published capability by `name` (see `ConnectedVat.fetch`).
    pub fn fetch(self: *Connection, name: []const u8) !actors.Ref {
        return self.cv.fetch(name);
    }
    /// The reason-bearing fetch (see `ConnectedVat.fetchSettled`).
    pub fn fetchSettled(self: *Connection, name: []const u8, arena: std.mem.Allocator) !Settled {
        return self.cv.fetchSettled(name, arena);
    }
    /// Send `msg` to `target`, drive until the reply settles, and return the
    /// outcome materialized into `arena` (see `ConnectedVat.call`).
    pub fn call(self: *Connection, target: actors.Ref, msg: actors.Message, arena: std.mem.Allocator) !Settled {
        return self.cv.call(target, msg, arena);
    }
    /// `fetch`, projected to the wire `model.Reference` a non-Zig surface speaks
    /// instead of the vat-local `actors.Ref`: the owning C session
    /// (`pancake_tcp_session_fetch`, ADR-0062) hands the partner's fetched
    /// capability back as a `model.Reference` without naming the actor layer. A
    /// bootstrap fetch always resolves to the responder's *own* published export:
    /// the responder names it with a near reference to itself, which arrives here,
    /// after OCapN's perspective flip, as a far reference (an import). The
    /// responder has no path that hands back one of *our* exports —
    /// `registerBootstrapCap` maps a swissnum only to a fresh local export of the
    /// responder — so `ConnectedVat.fetch` never yields a `.local` ref. The
    /// `.local` arm is therefore unreachable; it fails closed rather than
    /// fabricate a near reference from an actor id, which is a different number
    /// space than the export position a near reference names. (Reflexive
    /// references — a partner handing back one of our own exports — do occur, but
    /// in deliver arguments and call/send resolutions, not here; a handler reaches
    /// them through `Vat.refForExport`.)
    pub fn fetchReference(self: *Connection, name: []const u8) !model.Reference {
        return switch (try self.cv.fetch(name)) {
            .far => |far_ref| .{ .far = far_ref },
            .local => driver.Error.FetchNotACapability,
        };
    }
    /// `call` addressed by a wire `model.Reference` and verb/args, the
    /// reference-keyed twin of `call` for a non-Zig surface (the owning C
    /// session's `pancake_tcp_session_call`, ADR-0062). Only a near or far
    /// object/promise reference is an eventual-send target; a `sturdy`,
    /// `broken`, or bare answer-`promise` reference is refused with
    /// `Error.UncallableTarget`.
    pub fn callReference(self: *Connection, target: model.Reference, verb: []const u8, args: []const model.Argument, arena: std.mem.Allocator) !Settled {
        const ref = self.refForTarget(target) orelse return driver.Error.UncallableTarget;
        return self.cv.call(ref, .{ .verb = verb, .args = args }, arena);
    }
    /// Eventual-send `msg` to `target`, returning a promise (see `ConnectedVat.send`).
    pub fn send(self: *Connection, target: actors.Ref, msg: actors.Message) !actors.Promise {
        return self.cv.send(target, msg);
    }
    /// `send` addressed by a wire `model.Reference`, the non-blocking,
    /// reference-keyed twin of `callReference` for a non-Zig surface (the owning
    /// C session's `pancake_tcp_session_send`). Returns the answer `Promise` to
    /// pipeline against (`sendToAnswer`) or await (`settlePromise`); the flush is
    /// the caller's, deferred to the next `step`/settle so a batch of sends
    /// leaves together. Only a near or far object reference is an eventual-send
    /// target; a `promise`, `sturdy`, or `broken` reference is refused with
    /// `Error.UncallableTarget`.
    pub fn sendReference(self: *Connection, target: model.Reference, verb: []const u8, args: []const model.Argument) !actors.Promise {
        const ref = self.refForTarget(target) orelse return driver.Error.UncallableTarget;
        return self.cv.send(ref, .{ .verb = verb, .args = args });
    }

    /// Resolve a wire `model.Reference` to the `actors.Ref` an eventual-send
    /// targets, or null when it names no callable object. A far reference is a
    /// partner-hosted import. A near reference names a local object by its wire
    /// export position, which is a different number space from the vat's actor
    /// ids, so it resolves through the export table (`Vat.refForExport`) and
    /// fails closed when no actor is bound there rather than treating the
    /// position as an actor id. A `promise`, `sturdy`, or `broken` reference is
    /// not an eventual-send target.
    fn refForTarget(self: *Connection, target: model.Reference) ?actors.Ref {
        return switch (target) {
            .far => |far_ref| .{ .far = far_ref },
            .near => |near_ref| self.cv.vat.refForExport(near_ref.export_position.int()),
            .promise, .sturdy, .broken => null,
        };
    }
    /// Promise pipelining: eventual-send `msg` to a far `promise` a prior
    /// `send`/`sendToAnswer` returned, before it resolves (see
    /// `ConnectedVat.sendToAnswer`).
    pub fn sendToAnswer(self: *Connection, promise: actors.Promise, msg: actors.Message) !actors.Promise {
        return self.cv.sendToAnswer(promise, msg);
    }
    /// Drive until `promise` settles and return the outcome materialized into
    /// `arena` (see `ConnectedVat.settlePromise`).
    pub fn settlePromise(self: *Connection, promise: actors.Promise, arena: std.mem.Allocator) !Settled {
        return self.cv.settlePromise(promise, arena);
    }
    /// Fire-and-forget eventual-send (see `ConnectedVat.tell`).
    pub fn tell(self: *Connection, target: actors.Ref, msg: actors.Message) !void {
        return self.cv.tell(target, msg);
    }
    /// Register a one-shot listener on `promise` (see `ConnectedVat.on`).
    pub fn on(self: *Connection, promise: actors.Promise, listener: actors.Listener) !void {
        return self.cv.on(promise, listener);
    }
    /// Spawn a local actor and return a capability to it (see `ConnectedVat.spawn`).
    pub fn spawn(self: *Connection, comptime Behavior: type, initial: Behavior) !Capability {
        return self.cv.spawn(Behavior, initial);
    }
    /// Publish an actor fetchable by `name` (see `ConnectedVat.publish`).
    pub fn publish(self: *Connection, name: []const u8, comptime Behavior: type, initial: Behavior) !Capability {
        return self.cv.publish(name, Behavior, initial);
    }
    /// One pump cycle (see `ConnectedVat.step`).
    pub fn step(self: *Connection) !net.Progress {
        return self.cv.step();
    }
    /// Serve until the partner leaves (see `ConnectedVat.serve`).
    pub fn serve(self: *Connection) !void {
        return self.cv.serve();
    }
    /// The partner's retained abort diagnostic, if an `op:abort` arrived (see
    /// `ConnectedVat.abortReason`).
    pub fn abortReason(self: *const Connection) ?[]const u8 {
        return self.cv.abortReason();
    }

    /// Free everything `createShell` allocated, in reverse. `deinit` runs this
    /// after the connected vat is down; a constructor runs it when the
    /// handshake fails after the shell exists.
    fn freeShell(self: *Connection) void {
        self.allocator.free(self.write_buf);
        self.allocator.free(self.read_buf);
        self.peer.deinit();
        self.allocator.destroy(self);
    }
};

/// Allocate the owned bundle a `Connection` carries — the heap-pinned struct,
/// a negotiating peer whose `max_frame_bytes` is `frame_cap`, and both
/// buffers sized to match — without binding it to a transport yet. `connect`
/// and `Server.accept` fill `cv` and return the stable pointer.
fn createShell(allocator: std.mem.Allocator, opts: ConnectionOptions) !*Connection {
    const self = try allocator.create(Connection);
    errdefer allocator.destroy(self);
    self.allocator = allocator;
    self.peer = engine.Peer.initNegotiatingWith(allocator, .{ .codec = opts.codec, .limits = .{ .max_frame_bytes = opts.frame_cap } });
    errdefer self.peer.deinit();
    self.read_buf = try allocator.alloc(u8, opts.frame_cap);
    errdefer allocator.free(self.read_buf);
    self.write_buf = try allocator.alloc(u8, opts.frame_cap);
    return self;
}

/// Dial a `model.PeerLocator` in one call, own the peer and buffers, and
/// complete the keyed handshake, the one-call native-Zig client and the one
/// dialer, matching every binding's `connect`. Resolves the locator's
/// `transport` symbol against the netlayer that hosts it in `netlayers` (so a
/// transport the core never named, like iroh, dials here as soon as its netlayer
/// is in the slice) and dials it. A one-transport client passes
/// `&.{ tcp.netlayer() }`; multi-transport is `&.{ tcp.netlayer(), iroh.netlayer() }`,
/// the same call. A literal `host:port` becomes a `tcp` locator with
/// `net.tcp.at(designator)` (no caller buffer, no hint spelling); a locator a
/// partner published as an `ocapn://` URI string is dialed with
/// `connectUriOwned`, which parses it and calls this. `identity` is the signing
/// posture, explicit and never defaulted: `.ephemeral` is the ordinary client,
/// `.keyed` signs with a caller-held key. The returned `*Connection` is freed by
/// `Connection.deinit`. `netlayers` (and the residents behind it, which can hold
/// state) must outlive the returned `*Connection`. A caller that wants to own
/// the peer and buffers directly uses the borrowing `connectVia` / `connectUri`.
pub fn connect(
    allocator: std.mem.Allocator,
    netlayers: []const net.netlayer.Netlayer,
    locator: model.PeerLocator,
    identity: Identity,
    opts: ConnectionOptions,
) !*Connection {
    const self = try createShell(allocator, opts);
    errdefer self.freeShell();
    self.cv = try connectVia(allocator, netlayers, &self.peer, locator, identity, self.read_buf, self.write_buf);
    return self;
}

/// Dial an `ocapn://` URI string in one call, owning the peer and buffers, the
/// sibling of `connect` for a caller that holds a published URI rather than a
/// parsed `model.PeerLocator`. Parses the URI through the core grammar (so the
/// percent-encoded designator is decoded correctly), then dials it with
/// `connect`, signing with `identity`. `netlayers` must outlive the returned
/// `*Connection`.
pub fn connectUriOwned(
    allocator: std.mem.Allocator,
    netlayers: []const net.netlayer.Netlayer,
    uri_str: []const u8,
    identity: Identity,
    opts: ConnectionOptions,
) !*Connection {
    const locator = try model.uri.parsePeer(allocator, uri_str);
    defer model.freePeerLocator(allocator, locator);
    return connect(allocator, netlayers, locator, identity, opts);
}

/// The owning hosting half, bound by `listen` — the host twin of `connect`.
/// Each `accept` gives the partner its own `*Connection` with the same owned
/// peer and buffers `connect` gives a client, so the two halves reach parity:
/// one call, owned buffers, one `frame_cap` from which the buffers and the
/// session limit both derive. It holds a transport-neutral
/// `net.netlayer.Listener`, so a `Server` hosts over whatever transport bound
/// it (tcp, inproc, iroh), never a privileged built-in — `net` already names
/// its per-transport listener types, so the driver's owner is a `Server`, the
/// same word the bindings use for it. `identity` is the responder signing
/// posture the keyed handshake uses on each accept.
pub const Server = struct {
    listener: net.netlayer.Listener,
    identity: driver.AcceptIdentity,
    allocator: std.mem.Allocator,
    opts: ConnectionOptions,

    /// Write the bound dialable designator (with the kernel-chosen port when
    /// `listen` bound port 0) into `out` and return the written slice: the
    /// designator a partner dials. Empty when `out` cannot hold it or the
    /// transport faulted, callers must treat empty as a defect, never sign it.
    pub fn localDesignator(self: *const Server, out: []u8) []const u8 {
        return self.listener.localDesignator(out);
    }

    /// Accept one partner into its own owned `*Connection`. The responder
    /// keyed handshake completes inside (this is `acceptVia` underneath,
    /// signing with `self.identity`), so the returned connection rides an open
    /// session. Freed by `Connection.deinit`.
    pub fn accept(self: *Server) !*Connection {
        const conn = try createShell(self.allocator, self.opts);
        errdefer conn.freeShell();
        conn.cv = try acceptVia(self.allocator, self.listener, &conn.peer, self.identity, conn.read_buf, conn.write_buf);
        return conn;
    }

    /// Stop listening. Connections already accepted live on; each one is torn
    /// down by its own `Connection.deinit`.
    pub fn close(self: *Server) void {
        self.listener.close();
    }
};

/// Bind `netlayer` per `config` and return the owning `Server` — the one-call
/// native-Zig host, the host twin of `connect`. The transport is whatever
/// `netlayer` hosts (its `transport_name`), chosen by the netlayer you bind and
/// never defaulted; `config.designator` names where to bind (a `host:port` for
/// tcp, a node default for a userspace transport), and `identity` is the
/// responder signing posture. Accept each partner with `Server.accept`; a
/// caller that wants to own the peer and buffers directly binds a
/// `net.netlayer.Listener` (or a `net.tcp.Listener`) and uses `acceptVia` /
/// `acceptTcp` instead. The `netlayer` (and the resident behind it, which can
/// hold state) must outlive the returned `Server`.
pub fn listen(
    allocator: std.mem.Allocator,
    netlayer: net.netlayer.Netlayer,
    config: net.netlayer.ListenConfig,
    identity: driver.AcceptIdentity,
    opts: ConnectionOptions,
) !Server {
    return .{
        .listener = try netlayer.listen(allocator, config),
        .identity = identity,
        .allocator = allocator,
        .opts = opts,
    };
}
