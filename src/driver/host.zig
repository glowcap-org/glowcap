//! `BlockingHost`: the blocking I/O binding over the sans-io host core
//! (`driver_core.Host`, ADR-0072). The core owns every multi-connection
//! decision — one identity, one `engine.Node`, routing, give origination,
//! auto-redeem, the crossed-hellos tiebreak — and this tier owns only what the
//! I/O ban keeps out of the core: real sockets, blocking pumps, and the
//! entropy boundary. Every verb here delegates to the core and then answers
//! its action queue the way every language binding answers it over the C ABI:
//! a `dial` action becomes a real dial, a `flush` becomes a socket write, a
//! `need_gift_id` draws entropy, and a `settled`/`failed` completion routes to
//! the blocking wait that asked for it. A call whose answer is a three-party
//! introduction therefore settles as an ordinary routable reference: the host
//! dials the exporter and withdraws the gift inside the wait, with no redeem
//! verb to call. The single-connection `connect`/`listen` tier stays below for
//! the client that will never hold two connections at once.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const net = @import("net");

const driver = @import("mod.zig");
const driver_core = @import("driver_core");
const connection_mod = @import("connection.zig");
const ConnectionOptions = connection_mod.ConnectionOptions;
const Error = driver.Error;
const Settled = driver.Settled;
const SettleCapture = driver_core.SettleCapture;

const crypto = foundation.crypto;

/// One identity, one node, many blocking connections: a socket loop over the
/// sans-io `driver_core.Host`. `netlayers` is borrowed and must outlive the
/// host; every connection the host mints shares `opts`. Free with `deinit`,
/// after every `Connection` the host handed out is closed.
///
/// One thread drives all of a host's connections — the core's own contract.
/// The multiplexing primitive for a single thread is
/// `Connection.stepReadable`, round-robined across the connections. A
/// blocking wait (`call`, `settleVow`, `fetch`, `enliven`) pumps its own
/// connection plus the host-owned legs the core's dial actions opened, never a
/// sibling connection the application holds.
pub const BlockingHost = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The sans-io host core: node, routing, vows, crossed-hellos, the action
    /// queue. Reach it for the node's tables (`core.node`) or an in-process
    /// vow listener (`core.vowOn`).
    core: driver_core.Host,
    netlayers: []const net.netlayer.Netlayer,
    opts: ConnectionOptions,
    connections: std.AutoHashMapUnmanaged(engine.ConnId, *Connection) = .{},
    /// Completions that settled while no blocking wait was registered on them
    /// (a `send` whose `settleVow` comes later, or a completion a nested drain
    /// met first): the outcome is cloned host-owned and handed to the wait
    /// that eventually asks. Freed on hand-off or at `deinit`.
    parked: std.AutoHashMapUnmanaged(u64, Parked) = .{},
    /// Reused id scratch for one pump round's connection set, so a round
    /// survives the set mutating under it (a failed leg tears down mid-round).
    pump_scratch: std.ArrayListUnmanaged(engine.ConnId) = .empty,

    /// A parked completion's owned outcome (see `parked`).
    const Parked = union(enum) {
        fulfilled: model.Argument,
        broken: []const u8,

        fn deinit(self: Parked, allocator: std.mem.Allocator) void {
            switch (self) {
                .fulfilled => |value| model.freeArgument(allocator, value),
                .broken => |message| if (message.len != 0) allocator.free(message),
            }
        }
    };

    /// How long one blocking-wait pump round waits on each connection in its
    /// set before giving the next one a turn.
    const wait_poll_ms: i32 = 10;
    /// The DIAL executor's handshake budget: long enough for a live exporter
    /// across a real network, short enough that a dead one breaks the redeem
    /// instead of freezing the host.
    const redeem_handshake_ms: i32 = 5_000;

    /// Create a host with a fresh identity drawn at this I/O boundary; the
    /// node reuses it for every connection, so an exporter verifies a
    /// handoff signature against the one key the gifter named.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        netlayers: []const net.netlayer.Netlayer,
        opts: ConnectionOptions,
    ) !BlockingHost {
        var seed: [crypto.SEED_BYTES]u8 = undefined;
        defer std.crypto.secureZero(u8, &seed);
        try io.randomSecure(&seed);
        return initSeeded(allocator, io, netlayers, seed, opts);
    }

    /// The retained-identity constructor: `seed` is the host's stable session
    /// identity (a listener that must present the same key across restarts).
    pub fn initSeeded(
        allocator: std.mem.Allocator,
        io: std.Io,
        netlayers: []const net.netlayer.Netlayer,
        seed: [crypto.SEED_BYTES]u8,
        opts: ConnectionOptions,
    ) BlockingHost {
        return .{
            .allocator = allocator,
            .io = io,
            .core = driver_core.Host.init(allocator, seed, .{
                .frame_cap = opts.frame_cap,
                .codec = opts.codec,
            }),
            .netlayers = netlayers,
            .opts = opts,
        };
    }

    /// Close every socket shell the host still holds, then free the core
    /// (which breaks every still-parked vow and frees the node) and any
    /// parked completions no wait ever collected.
    pub fn deinit(self: *BlockingHost) void {
        var it = self.connections.valueIterator();
        while (it.next()) |shell| self.freeShell(shell.*);
        self.connections.deinit(self.allocator);
        self.core.deinit();
        var parked_it = self.parked.valueIterator();
        while (parked_it.next()) |entry| entry.deinit(self.allocator);
        self.parked.deinit(self.allocator);
        self.pump_scratch.deinit(self.allocator);
    }

    /// Free one connection shell's memory — the socket, the buffers, and the
    /// block — in the one place, so a new `Connection` field cannot
    /// silently leak from one of two hand-listed teardown paths. The core
    /// connection and the map row are the caller's to retire.
    fn freeShell(self: *BlockingHost, shell: *Connection) void {
        shell.conn.deinit();
        self.allocator.free(shell.read_buf);
        self.allocator.free(shell.write_buf);
        self.allocator.destroy(shell);
    }

    /// Allocate one shell over a minted core connection: the block and both
    /// buffers, each unwound on an internal failure, with the map slot
    /// reserved so `enrollShell` cannot fail. The socket is the caller's next
    /// step; a caller that fails after this unwinds with `failShell`.
    fn mintShell(self: *BlockingHost, core_conn: *driver_core.HostConnection) !*Connection {
        try self.connections.ensureUnusedCapacity(self.allocator, 1);
        const shell = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(shell);
        shell.* = .{
            .host = self,
            .conn_id = core_conn.conn_id,
            .core = core_conn,
            .conn = undefined,
            .read_buf = &.{},
            .write_buf = &.{},
        };
        shell.read_buf = try self.allocator.alloc(u8, self.opts.frame_cap);
        errdefer self.allocator.free(shell.read_buf);
        shell.write_buf = try self.allocator.alloc(u8, self.opts.frame_cap);
        return shell;
    }

    /// Unwind a `mintShell` whose caller failed before the socket was bound:
    /// free the buffers and the block. The core connection is the caller's
    /// own errdefer.
    fn failShell(self: *BlockingHost, shell: *Connection) void {
        self.allocator.free(shell.read_buf);
        self.allocator.free(shell.write_buf);
        self.allocator.destroy(shell);
    }

    /// Register a fully opened shell. Infallible: `mintShell` reserved the slot.
    fn enrollShell(self: *BlockingHost, shell: *Connection) void {
        self.connections.putAssumeCapacity(shell.conn_id, shell);
    }

    /// Tear a live shell down whole: retire the core connection (which breaks
    /// its vows and fail-closes the node's pending withdraws, so a dead
    /// exporter's cache row is evicted), remove the map row, and free the
    /// shell. The completions and fail actions the release queues stay on the
    /// core queue for the next drain — teardown never pops them.
    fn destroyShell(self: *BlockingHost, shell: *Connection) void {
        std.debug.assert(self.connections.remove(shell.conn_id));
        // The release's own pump can fail only on OOM; the retire itself
        // (vow breaks, node sweep) has already run by then.
        self.core.releaseConn(shell.core) catch {};
        self.freeShell(shell);
    }

    /// Dial `locator`, register the connection on the node, and complete the
    /// keyed handshake under the host identity. The returned connection is
    /// closed with `Connection.deinit`, which also retires it from the
    /// node (failing anything still pending on it closed).
    pub fn dial(self: *BlockingHost, locator: model.PeerLocator) !*Connection {
        const nl = net.netlayer.resolve(self.netlayers, locator.transport) orelse return Error.UnknownTransport;
        return self.dialOn(nl, locator, false);
    }

    /// `dial` for a caller holding a published `ocapn://` URI string.
    pub fn dialUri(self: *BlockingHost, uri_str: []const u8) !*Connection {
        const locator = try model.uri.parsePeer(self.allocator, uri_str);
        defer model.freePeerLocator(self.allocator, locator);
        return self.dial(locator);
    }

    /// The DIAL executor's dial: identical to `dialUri`, but the shell is
    /// host-owned from mint (the host pumps and tears down its own redeem
    /// legs).
    fn dialUriOwned(self: *BlockingHost, uri_str: []const u8) !*Connection {
        const locator = try model.uri.parsePeer(self.allocator, uri_str);
        defer model.freePeerLocator(self.allocator, locator);
        const nl = net.netlayer.resolve(self.netlayers, locator.transport) orelse return Error.UnknownTransport;
        return self.dialOn(nl, locator, true);
    }

    fn dialOn(self: *BlockingHost, nl: net.netlayer.Netlayer, locator: model.PeerLocator, host_owned: bool) !*Connection {
        const core_conn = try self.core.openDialedLocator(locator);
        errdefer self.core.releaseConn(core_conn) catch {};
        const shell = try self.mintShell(core_conn);
        // Ownership is decided at mint, never mutated after the shell is
        // observable: a host-owned leg (the DIAL executor's redeem dial) is
        // the host's to pump and tear down from birth. The same flag picks the
        // handshake contract — the host's own legs carry the liveness budget,
        // an application's dial blocks on its caller's terms.
        shell.host_owned = host_owned;
        errdefer self.failShell(shell);
        shell.conn = try nl.dial(core_conn.served.peer, locator, .{ .read = shell.read_buf, .write = shell.write_buf });
        errdefer shell.conn.deinit();
        try self.finishOpen(shell, if (host_owned) redeem_handshake_ms else null);
        self.enrollShell(shell);
        return shell;
    }

    /// Drive a freshly bound shell's keyed handshake to an open session: write
    /// the hello the core already encoded, pump until the session opens, then
    /// drain the actions the handshake queued and flush what they encoded.
    /// `budget_ms` null keeps ordinary blocking semantics (an application's
    /// own dial/accept); a value is the DIAL executor's liveness budget so a
    /// redeem against a wedged exporter fails with `HandshakeTimedOut`
    /// instead of wedging the whole host. A partner that sends a partial
    /// frame and stalls can still hold one `pump` call; closing that residual
    /// needs a transport read deadline, its own pass.
    fn finishOpen(self: *BlockingHost, shell: *Connection, budget_ms: ?i32) !void {
        try shell.conn.flush();
        var remaining: i32 = budget_ms orelse 0;
        while (!shell.core.sessionOpen()) {
            if (budget_ms != null) {
                if (remaining <= 0) return Error.HandshakeTimedOut;
                if (try shell.conn.waitReadable(wait_poll_ms)) {
                    const progress = try shell.conn.pump();
                    try self.core.pumped(shell.core);
                    if (progress == .closed) return Error.ConnectionClosed;
                } else {
                    remaining -= wait_poll_ms;
                }
            } else {
                const progress = try shell.conn.pump();
                try self.core.pumped(shell.core);
                if (progress == .closed) return Error.ConnectionClosed;
            }
        }
        try self.drainActions();
        try shell.conn.flush();
    }

    /// Bind `netlayer` per `config` and return the accepting half: each
    /// `Server.accept` mints a node-registered connection whose responder
    /// handshake signs with the host identity and the listener's own dialable
    /// designator — the locator record a give made on this host names as the
    /// exporter location. The first listener's bound address becomes the
    /// designator the host's own dials sign (see
    /// `driver_core.Host.setSelfDesignator`).
    pub fn listen(self: *BlockingHost, netlayer: net.netlayer.Netlayer, config: net.netlayer.ListenConfig) !Server {
        const listener = try netlayer.listen(self.allocator, config);
        if (!self.core.hasSelfDesignator()) {
            var designator_buf: [64]u8 = undefined;
            const bound = listener.localDesignator(&designator_buf);
            try self.core.setSelfDesignator(bound);
        }
        return .{ .host = self, .listener = listener };
    }

    // ── The action pump ──────────────────────────────────────────────────────

    /// Execute the core's queued actions with blocking I/O — the embedder loop
    /// every binding runs, in its native Zig spelling. Actions pop *owned*
    /// (`takeAction`), so a completion's settled value moves into the parked
    /// table with no clone. Flushes write the
    /// named connection's socket; a dial opens a host-owned leg and reports
    /// it back; a gift-id draw happens at this entropy boundary; a completion
    /// with no wait pending parks until `settleVow` (or a wait already
    /// registered through `core.vowOn` heard it fire and nothing lands here).
    /// Every action is context-free, so a dial's own nested drain can pop a
    /// sibling wait's completion and only park it — nothing is lost or eaten.
    /// The arm set lives once in `driver_core.drainActions`; this tier only
    /// supplies the per-arm I/O.
    fn drainActions(self: *BlockingHost) !void {
        const Exec = struct {
            host: *BlockingHost,

            pub fn flush(e: @This(), conn_id: engine.ConnId) !void {
                const shell = e.host.connections.get(conn_id) orelse return;
                shell.conn.flush() catch {
                    e.host.failShellWire(shell, "connection lost");
                };
            }

            pub fn close(e: @This(), conn_id: engine.ConnId) !void {
                // The core condemned this connection mid-pump (its local
                // turns amplified past `Options.local_turn_budget`).
                // This tier never sets a budget, so the action cannot
                // fire today; it is handled anyway so a future budgeted
                // embedder is not silently stranded: write the queued
                // typed abort best-effort, then tear the transport down —
                // a host-owned leg whole, an application-held shell by
                // breaking its vows and leaving the shell for the
                // application's own `deinit` (this tier must not free a
                // shell the application still holds).
                const shell = e.host.connections.get(conn_id) orelse return;
                shell.conn.flush() catch {};
                e.host.failShellWire(shell, "connection closed by the host");
            }

            pub fn dial(e: @This(), d: driver_core.HostAction.Dial) !void {
                try e.host.execDial(d);
            }

            pub fn complete(e: @This(), action: driver_core.HostAction) !void {
                switch (action) {
                    .settled => |s| try e.host.park(s.vow_id, .{ .fulfilled = s.value }),
                    .failed => |f| try e.host.park(f.vow_id, .{ .broken = f.message }),
                    else => unreachable,
                }
            }
        };
        try driver_core.drainActions(&self.core, self.io, Exec{ .host = self });
    }

    /// Execute one `dial` action: open a host-owned connection to the give's
    /// exporter and report it back, so the node withdraws over it. A refused
    /// dial reports `dialFailed`, which breaks the waiting vow with the
    /// reason instead of stranding it. The explicit `anyerror` breaks the
    /// inferred-error-set cycle a dial's own nested drain would otherwise
    /// form (dial → drain → this dial).
    fn execDial(self: *BlockingHost, d: driver_core.HostAction.Dial) anyerror!void {
        const shell = self.dialUriOwned(d.locator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try self.core.dialFailed(d.ticket, @errorName(err));
                return;
            },
        };
        try self.core.exporterDialed(d.ticket, shell.core);
    }

    /// Park a completion no wait was registered for. The caller moves the
    /// owned outcome in (`takeAction` transferred it), so parking pays no
    /// clone; a failed park frees the moved value instead of leaking it.
    fn park(self: *BlockingHost, vow_id: u64, entry: Parked) !void {
        self.parked.ensureUnusedCapacity(self.allocator, 1) catch |err| {
            entry.deinit(self.allocator);
            return err;
        };
        self.parked.putAssumeCapacity(vow_id, entry);
    }

    /// Hand a parked completion to `listener` (borrowed for the call, the
    /// `actors.Listener` contract) and free it. False when nothing is parked
    /// under the id.
    fn fireParked(self: *BlockingHost, vow_id: u64, listener: actors.Listener) bool {
        const kv = self.parked.fetchRemove(vow_id) orelse return false;
        defer kv.value.deinit(self.allocator);
        switch (kv.value) {
            .fulfilled => |value| listener.func(listener.ctx, .{ .fulfilled = value }),
            .broken => |message| listener.func(listener.ctx, .{ .broken = message }),
        }
        return true;
    }

    // ── Blocking waits ───────────────────────────────────────────────────────

    /// Drive the wire until the host vow `vow_id` settles into `listener`: the
    /// shared blocking tail of `call`, `settleVow`, `fetch`, and `enliven`.
    /// The pump set is the vow's own connection (the routed one the send left
    /// on) plus every host-owned leg, so a withdraw settling on a fresh
    /// exporter connection is heard without ever pumping a sibling connection
    /// the application holds. A vow that settled before the wait registered —
    /// a near-target send, an enliven cache hit, a completion a nested drain
    /// parked — is handed straight from the parked table.
    fn awaitVow(self: *BlockingHost, fallback: *Connection, vow_id: u64, listener: actors.Listener) !void {
        if (self.fireParked(vow_id, listener)) return;
        var state = driver_core.SettleFlag{ .inner = listener };
        self.core.vowOn(vow_id, .{ .ctx = &state, .func = driver_core.SettleFlag.fire }) catch |err| switch (err) {
            driver_core.HostError.NoSuchVow => {
                // The vow settled before this wait: its completion is on the
                // action queue (or already parked). Drain and collect it.
                try self.drainActions();
                if (self.fireParked(vow_id, listener)) return;
                return err;
            },
            else => return err,
        };
        // From here the stack-bound listener is registered on the core: every
        // exit below must have fired it (a vow break fires it broken), so a
        // later settle can never write into a dead frame.
        const anchor = blk: {
            if (self.core.vowConn(vow_id)) |conn_id| {
                if (self.connections.get(conn_id)) |shell| break :blk shell;
            }
            break :blk fallback;
        };
        self.drainActions() catch |err| {
            self.core.breakFarVows(anchor.core, "connection failed") catch {};
            return err;
        };
        while (!state.done) {
            self.pumpRound(anchor, &state.done) catch |err| {
                // The listener must not outlive this frame: break the vow's
                // connection so the row fires broken (a wire fault inside the
                // round already did; this covers the round's own failures).
                if (!state.done) {
                    if (self.connections.get(anchor.conn_id)) |shell| {
                        self.core.breakFarVows(shell.core, "connection failed") catch {};
                    }
                }
                return err;
            };
        }
    }

    /// One bounded pump across the wait's connection set (see `awaitVow`),
    /// followed by an action drain. A host-owned leg that fails is torn down
    /// whole (its release fail-closes the withdraws it carried); a failure on
    /// the application's own connection breaks its far vows — which fires the
    /// waiting listener broken — and only a non-wire fault propagates.
    fn pumpRound(self: *BlockingHost, anchor: *Connection, done: *const bool) !void {
        self.pump_scratch.clearRetainingCapacity();
        try self.pump_scratch.append(self.allocator, anchor.conn_id);
        var it = self.connections.valueIterator();
        while (it.next()) |shell| {
            if (shell.*.host_owned and shell.*.conn_id != anchor.conn_id)
                try self.pump_scratch.append(self.allocator, shell.*.conn_id);
        }
        for (self.pump_scratch.items) |conn_id| {
            if (done.*) return;
            const shell = self.connections.get(conn_id) orelse continue;
            const progress = self.stepShell(shell, wait_poll_ms) catch |err| {
                if (shell.host_owned) {
                    self.destroyShell(shell);
                    continue;
                }
                self.core.breakFarVows(shell.core, "connection lost") catch {};
                switch (err) {
                    error.ConnectionLost, error.TruncatedFrame => continue,
                    else => return err,
                }
            };
            if (progress) |p| {
                // A clean close already broke the shell's vows in `stepShell`;
                // a host-owned leg's shell is also done for.
                if (p == .closed and shell.host_owned) self.destroyShell(shell);
            }
        }
        try self.drainActions();
        // Every connection in the set is gone and the vow still has not
        // fired: the vow's own connection must have been torn down with the
        // vow already broken, so this is unreachable in practice — fail
        // closed rather than spin.
        if (!done.* and self.connections.get(anchor.conn_id) == null and !self.anyHostOwned())
            return Error.ConnectionClosed;
    }

    fn anyHostOwned(self: *BlockingHost) bool {
        var it = self.connections.valueIterator();
        while (it.next()) |shell| {
            if (shell.*.host_owned) return true;
        }
        return false;
    }

    /// One bounded socket step: write pending outbound, wait up to
    /// `timeout_ms` for readable bytes (null on timeout), pump, and serve
    /// what arrived through the core (hooks, listeners, and the node pump all
    /// run inside `pumped`). A clean close breaks the shell's far vows with
    /// the partner's retained abort diagnostic when one arrived.
    fn stepShell(self: *BlockingHost, shell: *Connection, timeout_ms: i32) !?net.Progress {
        try shell.conn.flush();
        if (!try shell.conn.waitReadable(timeout_ms)) return null;
        const progress = try shell.conn.pump();
        try self.core.pumped(shell.core);
        if (progress == .closed)
            self.core.breakFarVows(shell.core, "connection closed") catch {};
        return progress;
    }

    /// Break an application-held shell's far vows when its wire dies under a
    /// drain (a flush write failed); the shell itself stays for the
    /// application's own `deinit`. A host-owned leg is torn down whole.
    fn failShellWire(self: *BlockingHost, shell: *Connection, reason: []const u8) void {
        if (shell.host_owned) {
            self.destroyShell(shell);
            return;
        }
        self.core.breakFarVows(shell.core, reason) catch {};
    }

    /// The accepting half a `BlockingHost.listen` binds: each accepted partner becomes a
    /// node-registered `Connection` with the same core hooks a dialed one
    /// carries, so redeem claiming and give origination work on served
    /// connections too.
    pub const Server = struct {
        host: *BlockingHost,
        listener: net.netlayer.Listener,

        /// The bound dialable designator (kernel-chosen port resolved), written
        /// into `out`: what a partner dials, and what this host's gives name.
        pub fn localDesignator(self: *const Server, out: []u8) []const u8 {
            return self.listener.localDesignator(out);
        }

        /// Accept one partner into a node-registered connection; the responder
        /// keyed handshake (host identity, the listener's real designator)
        /// completes before this returns. An accepted connection that loses the
        /// crossed-hellos tiebreak comes back condemned with its typed abort
        /// already written; every verb on it refuses `ConnectionCondemned`.
        pub fn accept(self: *Server) !*Connection {
            const host = self.host;
            var designator_buf: [64]u8 = undefined;
            const core_conn = try host.core.openAccepted(
                self.listener.transportName(),
                self.listener.localDesignator(&designator_buf),
            );
            errdefer host.core.releaseConn(core_conn) catch {};
            const shell = try host.mintShell(core_conn);
            errdefer host.failShell(shell);
            shell.conn = try self.listener.accept(core_conn.served.peer, .{ .read = shell.read_buf, .write = shell.write_buf });
            errdefer shell.conn.deinit();
            try host.finishOpen(shell, null);
            host.enrollShell(shell);
            return shell;
        }

        /// Stop listening. Accepted connections live on; each is torn down by its
        /// own `Connection.deinit`.
        pub fn close(self: *Server) void {
            self.listener.close();
        }
    };

    /// An owning connection minted by `BlockingHost.dial` or `Server.accept`: one
    /// socket bound to one core connection. Sends and calls route through the
    /// host's node, so a fetched or introduced capability's token is addressable
    /// from here like any other reference, and a blocking wait executes whatever
    /// the core asks for on the way — including the dial-and-withdraw a
    /// three-party give needs. The peer is node-owned; `deinit` retires the
    /// connection from the node (failing anything still pending on it closed)
    /// and frees the shell.
    pub const Connection = struct {
        host: *BlockingHost,
        conn_id: engine.ConnId,
        /// The sans-io half: the node-registered peer under its `Served` core.
        core: *driver_core.HostConnection,
        conn: net.Connection,
        read_buf: []u8,
        write_buf: []u8,
        /// Set on a leg the host's own dial action opened (a give's exporter):
        /// pumped by blocking waits and torn down by the host, never handed to
        /// the application.
        host_owned: bool = false,

        /// Tear down: deregister from the host, retire the core connection (its
        /// peer frees with it; stranded withdraws fail closed), close the socket,
        /// and free the buffers. The fail-closed actions the release queues stay
        /// on the core queue for the driving loop to consume — teardown never
        /// pops them.
        pub fn deinit(self: *Connection) void {
            self.host.destroyShell(self);
        }

        /// The partner's retained abort diagnostic, or null (see
        /// `Served.abortReason`).
        pub fn abortReason(self: *const Connection) ?[]const u8 {
            return self.core.served.abortReason();
        }

        /// Fetch the partner capability published as `name` and block until it
        /// settles. The core enrolls a fulfilled far capability under a
        /// node-unique token (ADR-0069) before the outcome is dispatched, so the
        /// returned reference routes to the right exporter even from a reply that
        /// immediately re-gifts it. An unpublished name returns
        /// `Error.FetchBroken`; any other fulfillment returns
        /// `Error.FetchNotACapability`.
        pub fn fetch(self: *Connection, name: []const u8) !model.Reference {
            const vow_id = try self.host.core.fetch(self.core, name);
            return self.awaitReference(vow_id);
        }

        /// Enliven the sturdyref published behind `swissnum` (ADR-0012) and block
        /// until the live reference settles. A dedup-cache hit settles without
        /// touching the wire.
        pub fn enliven(self: *Connection, swissnum: []const u8) !model.Reference {
            const vow_id = try self.host.core.enliven(self.core, swissnum);
            return self.awaitReference(vow_id);
        }

        fn awaitReference(self: *Connection, vow_id: u64) !model.Reference {
            var state = driver_core.FetchCapture{};
            try self.host.awaitVow(self, vow_id, .{ .ctx = &state, .func = driver_core.FetchCapture.record });
            return switch (state.outcome orelse return Error.ConnectionClosed) {
                .capability => |far| .{ .far = far },
                .broken => Error.FetchBroken,
                .not_a_capability => Error.FetchNotACapability,
            };
        }

        /// Eventual-send `msg` to `target` and block until the answer settles,
        /// materializing the outcome into caller-owned `arena`. A target token
        /// routes through the node to its exporter connection transparently, and
        /// an introduction settles as the introduced capability itself: the host
        /// auto-redeems the give inside this wait (dial, withdraw, settle), so
        /// `.give` never surfaces here.
        pub fn call(self: *Connection, target: model.Reference, msg: actors.Message, arena: std.mem.Allocator) !Settled {
            const vow_id = try self.host.core.send(self.core, target, msg);
            return self.settleVow(vow_id, arena);
        }

        /// Eventual-send `msg` to `target` and return the host vow id of the
        /// answer, to block on later with `settleVow`. The deliver goes on the
        /// wire before this returns.
        pub fn send(self: *Connection, target: model.Reference, msg: actors.Message) !u64 {
            const vow_id = try self.host.core.send(self.core, target, msg);
            try self.host.drainActions();
            return vow_id;
        }

        /// Block until the host vow `vow_id` (from `send`) settles, materializing
        /// the outcome into caller-owned `arena`. A vow that settled while the
        /// caller was doing other work is handed from the parked table without
        /// touching the wire.
        pub fn settleVow(self: *Connection, vow_id: u64, arena: std.mem.Allocator) !Settled {
            var capture = SettleCapture{ .arena = arena };
            try self.host.awaitVow(self, vow_id, .{ .ctx = &capture, .func = SettleCapture.fire });
            return capture.finish();
        }

        /// Fire-and-forget eventual-send with node routing; the deliver goes on
        /// the wire before this returns.
        pub fn tell(self: *Connection, target: model.Reference, msg: actors.Message) !void {
            try self.host.core.tell(self.core, target, msg);
            try self.host.drainActions();
        }

        /// Publish an actor fetchable by `name` on this connection's session (see
        /// `Served.publish`). A host serving an object to several partners
        /// publishes it on each accepted connection under the same name; the
        /// node's shared registry is what lets a gift deposited on one connection
        /// be withdrawn on another (ADR-0056).
        pub fn publish(self: *Connection, name: []const u8, comptime Behavior: type, initial: Behavior) !driver.Capability {
            return self.core.served.publish(name, Behavior, initial);
        }

        /// Serve until the partner leaves: pump this connection and answer the
        /// core's actions after every step, so claims, originations, and the
        /// dials they need all fire here too. A partner that drops the socket
        /// without a clean shutdown has still left, so serve breaks the waiting
        /// far vows and returns normally, as it does for a graceful close.
        pub fn serve(self: *Connection) !void {
            const host = self.host;
            while (true) {
                try host.drainActions();
                const progress = host.stepShell(self, -1) catch |err| switch (err) {
                    error.ConnectionLost, error.TruncatedFrame => {
                        host.core.breakFarVows(self.core, "connection lost") catch {};
                        return;
                    },
                    else => return err,
                };
                if (progress) |p| if (p == .closed) return;
            }
        }

        /// One bounded pump: answer any queued core actions, wait up to
        /// `timeout_ms` for readable bytes, apply them, and return, or null on
        /// timeout. The round-robin primitive for a single thread serving several
        /// connections of one host.
        pub fn stepReadable(self: *Connection, timeout_ms: i32) !?net.Progress {
            const host = self.host;
            try host.drainActions();
            const progress = try host.stepShell(self, timeout_ms);
            try host.drainActions();
            return progress;
        }
    };
};
