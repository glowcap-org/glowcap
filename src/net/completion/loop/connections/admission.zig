//! Connection admission and post-connect publication.
//!
//! Locator resolution, slot admission, accept/connect completion, keepalive,
//! and application-context construction form one transaction. A connection
//! reaches the receive/send owner only after its stable slot and context are
//! published. Every refusal rolls back through the slot lifecycle.

const model = @import("model");
const contract = @import("../../contract.zig");
const configuration = @import("../configuration.zig");
const state = @import("../state.zig");
const affinity = @import("../affinity.zig");
const failure_projection = @import("../../failure_projection.zig");

pub fn Machine(
    comptime Self: type,
    comptime Backend: type,
    comptime DialResolver: type,
    comptime Types: type,
    comptime Lifecycle: type,
    comptime Flow: type,
) type {
    return struct {
        const Conn = Types.Conn;
        const Fd = Types.Fd;
        const ConnectTarget = Backend.ConnectTarget;
        const Completion = contract.Completion;
        const DialAdmission = configuration.DialAdmission;

        /// Resolve one complete OCapN locator through the transport resolver,
        /// then admit the dial. This is the only public dial verb: above the
        /// net boundary callers speak only transport, designator, and hints,
        /// never a Backend `ConnectTarget`.
        pub fn dialLocator(
            self: *Self,
            locator: model.PeerLocator,
        ) !usize {
            affinity.assertOwnerOrUnclaimed(self);
            const target = try DialResolver.resolve(locator);
            return dial(self, target, .ordinary);
        }

        /// Admit a dial through the capacity reserved in
        /// `Options.reserved_dial_conns`. Use only for a bounded control-plane
        /// relationship whose recovery must survive ordinary connection
        /// pressure. A zero reservation refuses it.
        pub fn dialLocatorReserved(
            self: *Self,
            locator: model.PeerLocator,
        ) !usize {
            affinity.assertOwnerOrUnclaimed(self);
            const target = try DialResolver.resolve(locator);
            return dial(self, target, .reserved);
        }

        /// Admit an outbound dial into the same slot lifecycle as an accepted
        /// connection once the backend reports connect completion. Returns the
        /// connection's slot index. Slots are recycled: the value is only valid
        /// until the connection closes, after which it may name a different
        /// connection. `Options.on_close` is where a dialed connection's end
        /// (including a refused connect) is observed.
        ///
        /// Private: resolve happens in `dialLocator`. The Backend owns dial
        /// *start* (`startDial`). The Loop only allocates the slot and peer,
        /// then accounts the in-flight connect op.
        fn dial(self: *Self, target: ConnectTarget, admission: DialAdmission) !usize {
            if (self.shutting_down or self.tearing_down) return error.ShuttingDown;

            const slot = Lifecycle.freeSlot(self, admission) orelse return error.TooManyConnections;
            errdefer Lifecycle.pushFreeSlot(self, slot);
            var peer = try self.make_peer(self.make_ctx, self.allocator);
            errdefer peer.deinit();

            const fd = try self.backend.startDial(state.userData(.connect, slot), target);
            // startDial submitted the connect: the slot must own the fd and the
            // in-flight op before any further failure can run, or a completion
            // would land with nowhere to go.
            const c = Lifecycle.adoptSlot(self, slot, fd, peer, false, admission);
            c.ops_in_flight += 1;
            return slot;
        }

        pub fn ensureAccepting(self: *Self) !void {
            if (self.accept_armed) return;
            const fd = self.listen_fd orelse return;
            try self.backend.submitAccept(state.userData(.accept, 0), fd);
            self.accept_armed = true;
        }

        pub fn onAccept(self: *Self, comp: Completion) !void {
            const accepted: ?Fd = if (comp.accepted_fd) |fd|
                @intCast(fd)
            else if (comp.result >= 0)
                @intCast(comp.result)
            else
                null;
            // Shutdown closed the listener (or cancelled its accept): drop any
            // racing accept and never re-arm.
            self.accept_armed = false;
            if (self.shutting_down or self.listen_fd == null) {
                if (accepted) |fd| self.backend.closeFd(fd);
                return;
            }
            // Keep one accept armed so the next connection is not missed. The
            // re-arm runs first; if it fails (loop-global, kills
            // `run`), the accepted fd must still be closed, not leaked.
            errdefer if (accepted) |fd| self.backend.closeFd(fd);
            try ensureAccepting(self);
            // An arrival that failed on its own (reset before accept took it,
            // a refused socket option) leaves the next one unaffected, and the
            // re-arm above already waits for it. A refusal that would complete
            // again for every arrival (descriptor quota, memory, a dead
            // listener) has no connection peer to carry it, so the loop owner
            // is its only diagnostic surface and `run` returns it.
            const fd = accepted orelse {
                const err = failure_projection.primary(comp, error.AcceptFailed);
                if (failure_projection.acceptRefusalPersists(err)) return err;
                return;
            };

            const slot = Lifecycle.freeSlot(self, .ordinary) orelse {
                self.backend.closeFd(fd);
                return;
            };
            const peer = self.make_peer(self.make_ctx, self.allocator) catch |err| {
                Lifecycle.pushFreeSlot(self, slot);
                return err;
            };
            const adopted = Lifecycle.adoptSlot(self, slot, fd, peer, true, .ordinary);
            finishConnected(self, slot, adopted);
        }

        pub fn onConnect(self: *Self, slot: usize, comp: Completion) void {
            const c = Lifecycle.liveConn(self, slot) orelse return;
            if (comp.result < 0) {
                failure_projection.record(&c.peer, comp, error.ConnectFailed);
                Lifecycle.closeConn(self, slot, c);
                return;
            }
            c.opened = true;
            finishConnected(self, slot, c);
        }

        pub fn finishConnected(self: *Self, slot: usize, c: *Conn) void {
            // No per-connection read buffer is allocated: reads borrow from the
            // backend's shared pool, completion by completion (ADR-0019).

            // Opt-in keepalive is a backend operation because adapters may use
            // synthetic descriptors. Socket-backed adapters project to their
            // physical stream; transports without TCP semantics refuse it.
            if (self.keepalive) |ka| {
                self.backend.applyKeepalive(c.fd, ka) catch |err| {
                    c.peer.recordFailure(err);
                    Lifecycle.closeConn(self, slot, c);
                    return;
                };
            }

            // Bind the per-connection application context to this connection's
            // peer now that it sits at its final, stable address. A failure here
            // closes the connection cleanly rather than serving it context-less.
            if (self.make_conn_ctx) |make| {
                // Staged, not published straight into the slot. The hook may
                // condemn this connection (a bridge drains host actions here),
                // and a close that cannot queue tears the slot down inline,
                // so by the time `make` returns, `c` can already be free and
                // on the free list. Writing a live context into a free slot
                // leaks it, because the next accept overwrites the field.
                // The slot cannot be reclaimed while this runs, so `c` still
                // names this connection when the hook returns. It may have
                // been condemned, and the teardown it deferred runs below.
                self.adopting_slot = slot;
                const ctx = make(self.make_ctx, &c.peer, slot) catch |err| {
                    c.peer.recordFailure(err);
                    self.adopting_slot = null;
                    if (self.adopting_teardown_deferred) {
                        self.adopting_teardown_deferred = false;
                        if (Lifecycle.teardown(self, slot)) self.closed_count += 1;
                    } else {
                        Lifecycle.closeConn(self, slot, c);
                    }
                    return;
                };
                self.adopting_slot = null;
                // The adoption guard kept this slot stable while the hook ran,
                // so publish every successfully built context even when the
                // hook condemned the connection. Teardown then preserves the
                // public callback order: `on_close` observes the live context,
                // `free_conn_ctx` releases it, and only then does the peer die.
                c.app_ctx = ctx;
                if (self.adopting_teardown_deferred) {
                    self.adopting_teardown_deferred = false;
                    if (Lifecycle.teardown(self, slot)) self.closed_count += 1;
                    return;
                }
                if (c.state != .open) return;
            }
            // The hook drains host actions, so a `close` for the peer it just
            // adopted can condemn this connection before it ever serves a
            // turn. Driving or arming past that would put new bytes on the
            // wire behind its abort, which `.draining` exists to forbid.
            if (c.state != .open) return;

            Flow.driveOut(self, slot, c) catch |err| {
                Flow.failConnWith(self, slot, c, err);
                return;
            };
            if (c.state != .open) return;
            Flow.armOrPark(self, slot, c) catch |err| Flow.closeConnWith(self, slot, c, err);
        }

        /// The durable key this connection's realizer proved its far end
        /// holds, when the backend proves one. Socket backends carry no
        /// lower-layer identity and answer null. This is the channel's far
        /// end, never necessarily the CapTP partner: a byte-transparent relay
        /// makes those two different parties (ADR-0028).
        pub fn verifiedChannelKey(self: *Self, slot: usize) ?[32]u8 {
            affinity.assertOwnerOrUnclaimed(self);
            const c = Lifecycle.liveConn(self, slot) orelse return null;
            return self.backend.verifiedChannelKey(c.fd);
        }
    };
}
