//! The owning, one-call driver surface: `Session` and `Server`.
//!
//! `connect`, `connectUriOwned`, and `listen` each hand back an owning bundle
//! that holds the peer and both read/write buffers, so a native Zig app connects
//! (or accepts) in one call instead of stitching a peer, two buffers, and a
//! borrowing constructor together by hand. Each forwards to the borrowing
//! `BlockingSession` surface in `blocking_session.zig`; the shared vocabulary lives in
//! the driver root (`mod.zig`). This is the native-Zig spelling of the
//! `Session` every binding exposes.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const net = @import("net");

const blocking_session = @import("blocking_session.zig");
const BlockingSession = blocking_session.BlockingSession;
const connectVia = blocking_session.connectVia;
const acceptVia = blocking_session.acceptVia;

const driver = @import("mod.zig");
const Settled = driver.Settled;
const Capability = driver.Capability;
const Identity = driver.Identity;

/// Options for `connect` and `listen`. `frame_cap` sizes the owned read/write
/// buffers and the session's `max_frame_bytes` limit together, so the buffers
/// and the limit cannot drift apart. `codec` is the wire grammar the negotiating
/// peer encodes in; it defaults to `.syrup`, the v1.0 interop floor, and a
/// caller speaking Cap'n Proto sets `.capnp`. There is deliberately no
/// `verify_partner` knob here: the application tier always verifies, and only
/// the harness-facing loop and core options can turn verification off.
pub const SessionOptions = struct {
    frame_cap: usize = 1 << 16,
    codec: model.CodecId = .syrup,
    /// An opt-in per-read deadline for the keyed handshake, in milliseconds; 0
    /// (the default) leaves the handshake unbounded. When set, `Server.accept`
    /// and `connect` bound each handshake read and break with
    /// `Error.HandshakeTimedOut` if a partner finishes connect and then goes
    /// silent — the slowloris a one-connection-per-thread `accept` must not park
    /// on (ADR-0081). The value is the caller's policy; it binds fd-backed
    /// transports (tcp, keyed-tcp), where the handshake read has a pollable fd.
    handshake_timeout_ms: i32 = 0,
    /// An opt-in wall-clock deadline for blocking answer-waits after the
    /// session is open (`settle` / `call` / `fetch`), in milliseconds; 0 leaves
    /// them unbounded. Threaded onto `BlockingSession.settle_timeout_ms`
    /// (ADR-0076).
    settle_timeout_ms: i32 = 0,
};

/// An owning connection, the one object a native Zig application holds. It
/// owns the peer and both read/write buffers, so a caller connects (or
/// accepts) with one call instead of stitching a negotiating peer, two
/// buffers, and `connectVia` together by hand. Heap-pinned because the
/// connected vat borrows the peer: the pointer `connect` and `Server.accept`
/// return is stable for the connection's life, and `Session.deinit` frees
/// the whole bundle (`close` is the C vocabulary for a shutdown lever that
/// never frees; native Zig frees through `deinit`). The explicit `connectVia` / `acceptVia` (and the tcp-named
/// `connectTcp` / `acceptTcp`) path remains available when the caller wants to
/// own the peer and buffers and see every allocation at the call site. This
/// type is the native-Zig spelling of the `Session` every binding exposes.
pub const Session = struct {
    /// The borrowing surface this owning shell delegates its verbs to. Every
    /// method below that is a one-line forward carries `BlockingSession`'s
    /// contract unchanged; read it there. Only the three reference-keyed verbs
    /// (`fetchReference`, `callReference`, `sendReference`) add behavior, and
    /// they document what they add. `zig build meta-check` holds this forwarder
    /// set against `BlockingSession`'s verbs so the mirror cannot silently
    /// drift.
    cv: BlockingSession,
    peer: engine.Peer,
    read_buf: []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,

    /// Tear down the connection and free the peer and buffers this owns.
    pub fn deinit(self: *Session) void {
        self.cv.deinit();
        self.freeShell();
    }

    pub fn beginFetch(self: *Session, name: []const u8) !actors.Vow {
        return self.cv.beginFetch(name);
    }
    pub fn beginSendNamed(self: *Session, pending: *driver.PendingSend, name: []const u8, msg: actors.Message, terminal: actors.Listener) !void {
        return self.cv.beginSendNamed(pending, name, msg, terminal);
    }
    pub fn beginTellNamed(self: *Session, pending: *driver.PendingSend, name: []const u8, msg: actors.Message, terminal: actors.Listener) !void {
        return self.cv.beginTellNamed(pending, name, msg, terminal);
    }
    pub fn breakFarVows(self: *Session, message: []const u8) void {
        self.cv.breakFarVows(message);
    }
    pub fn fetch(self: *Session, name: []const u8) !actors.Ref {
        return self.cv.fetch(name);
    }
    pub fn fetchSettled(self: *Session, name: []const u8, arena: std.mem.Allocator) !Settled {
        return self.cv.fetchSettled(name, arena);
    }
    pub fn call(self: *Session, target: actors.Ref, msg: actors.Message, arena: std.mem.Allocator) !Settled {
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
    /// responder — so `BlockingSession.fetch` never yields a `.local` ref. The
    /// `.local` arm is therefore unreachable; it fails closed rather than
    /// fabricate a near reference from an actor id, which is a different number
    /// space than the export position a near reference names. (Reflexive
    /// references — a partner handing back one of our own exports — do occur, but
    /// in deliver arguments and call/send resolutions, not here; a handler reaches
    /// them through `Vat.refForExport`.)
    pub fn fetchReference(self: *Session, name: []const u8) !model.Reference {
        return switch (try self.cv.fetch(name)) {
            .far => |far_ref| .{ .far = far_ref },
            .local => driver.Error.FetchNotACapability,
        };
    }
    /// `call` addressed by a wire `model.Reference` and verb/args, the
    /// reference-keyed twin of `call` for a non-Zig surface (the owning C
    /// session's `pancake_tcp_session_call`, ADR-0062). Only a near or far
    /// _object_ reference is an eventual-send target; a promise-kind near/far,
    /// a `sturdy`, a `broken`, or a bare answer-`promise` reference is refused
    /// with `Error.UncallableTarget`.
    pub fn callReference(self: *Session, target: model.Reference, verb: []const u8, args: []const model.Argument, arena: std.mem.Allocator) !Settled {
        const ref = self.refForTarget(target) orelse return driver.Error.UncallableTarget;
        return self.cv.call(ref, .{ .verb = verb, .args = args }, arena);
    }
    pub fn send(self: *Session, target: actors.Ref, msg: actors.Message) !actors.Vow {
        return self.cv.send(target, msg);
    }
    /// `send` addressed by a wire `model.Reference`, the non-blocking,
    /// reference-keyed twin of `callReference` for a non-Zig surface (the owning
    /// C session's `pancake_tcp_session_send`). Returns the answer `Vow` to
    /// pipeline against (`sendToAnswer`) or await (`settleVow`); the flush is
    /// the caller's, deferred to the next `step`/settle so a batch of sends
    /// leaves together. Only a near or far _object_ reference is an
    /// eventual-send target; a promise-kind near/far, a `promise`, a `sturdy`,
    /// or a `broken` reference is refused with `Error.UncallableTarget`.
    pub fn sendReference(self: *Session, target: model.Reference, verb: []const u8, args: []const model.Argument) !actors.Vow {
        const ref = self.refForTarget(target) orelse return driver.Error.UncallableTarget;
        return self.cv.send(ref, .{ .verb = verb, .args = args });
    }

    /// Resolve a wire `model.Reference` to the `actors.Ref` an eventual-send
    /// targets, or null when it names no callable object. Only an _object_
    /// near or far reference is a target. A far object is a partner-hosted
    /// import. A near object names a local object by its wire export position,
    /// which is a different number space from the vat's actor ids, so it
    /// resolves through the export table (`Vat.refForExport`) and fails closed
    /// when no actor is bound there rather than treating the position as an
    /// actor id. A _promise-kind_ near or far reference is not a target either:
    /// an unresolved import/export promise is pipelined against its answer vow
    /// (`sendToAnswer`), never called as if it were the settled object, so it
    /// is refused here rather than silently coerced into an object turn. A bare
    /// answer-`promise`, a `sturdy`, or a `broken` reference is not a target.
    fn refForTarget(self: *Session, target: model.Reference) ?actors.Ref {
        return switch (target) {
            .far => |far_ref| if (far_ref.kind == .object) actors.Ref{ .far = far_ref } else null,
            .near => |near_ref| if (near_ref.kind == .object) self.cv.served.refForExport(near_ref.export_position.int()) else null,
            .promise, .sturdy, .broken => null,
        };
    }
    pub fn sendToAnswer(self: *Session, vow: actors.Vow, msg: actors.Message) !actors.Vow {
        return self.cv.sendToAnswer(vow, msg);
    }
    pub fn settleVow(self: *Session, vow: actors.Vow, arena: std.mem.Allocator) !Settled {
        return self.cv.settleVow(vow, arena);
    }
    pub fn tell(self: *Session, target: actors.Ref, msg: actors.Message) !void {
        return self.cv.tell(target, msg);
    }
    pub fn on(self: *Session, vow: actors.Vow, listener: actors.Listener) !void {
        return self.cv.on(vow, listener);
    }
    pub fn spawn(self: *Session, comptime Behavior: type, initial: Behavior) !Capability {
        return self.cv.spawn(Behavior, initial);
    }
    pub fn publish(self: *Session, name: []const u8, comptime Behavior: type, initial: Behavior) !Capability {
        return self.cv.publish(name, Behavior, initial);
    }
    pub fn step(self: *Session) !net.Progress {
        return self.cv.step();
    }
    pub fn stepReadable(self: *Session, timeout_ms: i32) !?net.Progress {
        return self.cv.stepReadable(timeout_ms);
    }
    pub fn serve(self: *Session) !void {
        return self.cv.serve();
    }
    pub fn partnerAbort(self: *const Session) ?driver.Served.PartnerAbortView {
        return self.cv.partnerAbort();
    }

    pub fn abortReason(self: *const Session) ?[]const u8 {
        return self.cv.abortReason();
    }

    /// Free everything `createShell` allocated, in reverse. `deinit` runs this
    /// after the connected vat is down; a constructor runs it when the
    /// handshake fails after the shell exists.
    fn freeShell(self: *Session) void {
        self.allocator.free(self.write_buf);
        self.allocator.free(self.read_buf);
        self.peer.deinit();
        self.allocator.destroy(self);
    }
};

/// Allocate the owned bundle a `Session` carries — the heap-pinned struct,
/// a negotiating peer whose `max_frame_bytes` is `frame_cap`, and both
/// buffers sized to match — without binding it to a transport yet. `connect`
/// and `Server.accept` fill `cv` and return the stable pointer.
fn createShell(allocator: std.mem.Allocator, opts: SessionOptions) !*Session {
    const self = try allocator.create(Session);
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
/// `.keyed` signs with a caller-held key. The returned `*Session` is freed by
/// `Session.deinit`. `netlayers` (and the residents behind it, which can hold
/// state) must outlive the returned `*Session`. A caller that wants to own
/// the peer and buffers directly uses the borrowing `connectVia` / `connectUri`.
pub fn connect(
    allocator: std.mem.Allocator,
    netlayers: []const net.netlayer.Netlayer,
    locator: model.PeerLocator,
    identity: Identity,
    opts: SessionOptions,
) !*Session {
    const self = try createShell(allocator, opts);
    errdefer self.freeShell();
    self.cv = try connectVia(allocator, netlayers, &self.peer, locator, identity, self.read_buf, self.write_buf, opts.handshake_timeout_ms);
    self.cv.settle_timeout_ms = opts.settle_timeout_ms;
    return self;
}

/// Dial an `ocapn://` URI string in one call, owning the peer and buffers, the
/// sibling of `connect` for a caller that holds a published URI rather than a
/// parsed `model.PeerLocator`. Parses the URI through the core grammar (so the
/// percent-encoded designator is decoded correctly), then dials it with
/// `connect`, signing with `identity`. `netlayers` must outlive the returned
/// `*Session`.
pub fn connectUriOwned(
    allocator: std.mem.Allocator,
    netlayers: []const net.netlayer.Netlayer,
    uri_str: []const u8,
    identity: Identity,
    opts: SessionOptions,
) !*Session {
    const locator = try model.uri.parsePeer(allocator, uri_str);
    defer model.freePeerLocator(allocator, locator);
    return connect(allocator, netlayers, locator, identity, opts);
}

/// The owning hosting half, bound by `listen` — the host twin of `connect`.
/// Each `accept` gives the partner its own `*Session` with the same owned
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
    opts: SessionOptions,

    /// Write the bound dialable designator (with the kernel-chosen port when
    /// `listen` bound port 0) into `out` and return the written slice: the
    /// designator a partner dials.
    ///
    /// An error rather than an empty slice. The netlayer primitive underneath
    /// keeps the empty-slice contract, because "no address available" is a real
    /// answer for it — but this is the public surface a caller signs from, and
    /// a comment telling callers to treat empty as a defect is exactly what a
    /// type can say instead. Both shipped examples ignored it, and one byte
    /// less buffer would have had them publish a locator nobody can dial.
    pub fn localDesignator(self: *const Server, out: []u8) driver.Error![]const u8 {
        const designator = self.listener.localDesignator(out);
        if (designator.len == 0) return driver.Error.DesignatorUnavailable;
        return designator;
    }

    /// Accept one partner into its own owned `*Session`. The responder
    /// keyed handshake completes inside (this is `acceptVia` underneath,
    /// signing with `self.identity`), so the returned connection rides an open
    /// session. Freed by `Session.deinit`.
    pub fn accept(self: *Server) !*Session {
        const conn = try createShell(self.allocator, self.opts);
        errdefer conn.freeShell();
        conn.cv = try acceptVia(self.allocator, self.listener, &conn.peer, self.identity, conn.read_buf, conn.write_buf, self.opts.handshake_timeout_ms);
        conn.cv.settle_timeout_ms = self.opts.settle_timeout_ms;
        return conn;
    }

    /// Wait until `accept` would make progress, up to `timeout_ms` (see
    /// `net.netlayer.Listener.waitAcceptable`). The stop-friendly twin of
    /// blocking accept: poll, check a latch, then `accept`.
    pub fn waitAcceptable(self: *Server, timeout_ms: i32) !bool {
        return self.listener.waitAcceptable(timeout_ms);
    }

    /// Stop listening. Connections already accepted live on; each one is torn
    /// down by its own `Session.deinit`.
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
    opts: SessionOptions,
) !Server {
    return .{
        .listener = try netlayer.listen(allocator, config),
        .identity = identity,
        .allocator = allocator,
        .opts = opts,
    };
}
