//! Per-connection receive, send, and backpressure transaction.
//!
//! Completion payloads are consumed once, borrowed buffers recycle once, and
//! outbound front storage stays frozen for the backend borrow. Terminal abort
//! projection remains here because it is the final outbound transaction. Slot
//! and descriptor retirement remain in lifecycle.

const std = @import("std");

const frame_stream = @import("../../../frame_stream.zig");
const failure_projection = @import("../../failure_projection.zig");
const contract = @import("../../contract.zig");
const configuration = @import("../configuration.zig");
const state = @import("../state.zig");
const affinity = @import("../affinity.zig");

pub fn Machine(
    comptime Self: type,
    comptime Types: type,
    comptime Deadlines: type,
    comptime Lifecycle: type,
) type {
    return struct {
        const Conn = Types.Conn;
        const Completion = contract.Completion;
        const RecvVerdict = state.RecvVerdict;
        const ParkReason = configuration.ParkReason;

        /// Encode and submit work queued on any connection, including one the
        /// loop is not serving. Safe mid-dispatch and idempotent for
        /// the served slot. A drive failure closes only that slot.
        pub fn armOutbound(self: *Self, slot: usize) void {
            affinity.assertOwnerOrUnclaimed(self);
            if (self.tearing_down) return;
            const c = Lifecycle.liveConn(self, slot) orelse return;
            driveOut(self, slot, c) catch |err| {
                failConnWith(self, slot, c, err);
                return;
            };
            // A cross-connection arm lands here when pump work touched this
            // session, and that work may have been what released the retained
            // bytes a saturated park was waiting on, with no send completion
            // on this connection to carry the resume. Re-evaluate the park
            // here so a pump-side drain wakes the read it throttled.
            resumeIfDrained(self, slot, c);
        }

        /// Close `slot` after flushing the engine's already-projected terminal
        /// bytes. A projection or send failure remains in its `CloseReport`.
        ///
        /// The first call waits for the partner to read. A second call hard
        /// closes. The ordinary wait is bounded by `Options.drain_kill_ms`.
        pub fn closeSlot(self: *Self, slot: usize) void {
            affinity.assertOwnerOrUnclaimed(self);
            if (self.tearing_down or slot >= self.conns.len) return;
            const c = &self.conns[slot];
            switch (c.state) {
                .open => failConn(self, slot, c),
                // Close already requested, and waiting on the partner to read its
                // abort. A second request means the caller will not wait:
                // shut the fd down so an armed recv completes at once, then
                // close, the same escalation `closeAndDrain` performs.
                .draining => {
                    self.backend.shutdownFd(c.fd);
                    Lifecycle.closeConn(self, slot, c);
                },
                .free, .closing => {},
            }
        }

        pub fn armRecv(self: *Self, slot: usize, c: *Conn) !void {
            // One recv per connection: arming over an armed/parked/starved
            // read seat would double-arm and corrupt the seat's accounting.
            std.debug.assert(c.read == .idle);
            try self.backend.submitRecv(state.userData(.recv, slot), c.fd);
            c.read = .armed;
            c.ops_in_flight += 1;
        }

        /// Arm the next read, unless the partner is not draining our writes.
        /// Pending outbound past the high-water mark means every newly applied
        /// inbound frame would pile more replies onto an unread socket, so the
        /// read parks instead and `onSend` resumes it when the queue drains
        /// (ADR-0017). The peer's own retained-work waterline parks the read
        /// the same way: a saturated session would break each new deliver's
        /// answer as resource-exhausted, and the byte-fed Host's feed
        /// admission already refuses at that line, so the loop tier throttles
        /// there too instead of letting inbound overrun it. With `fan_in_throttle`, a parked sink also parks every
        /// other connection's reads so many-A-to-one-B sources slow (ADR-0030).
        /// Protocol frames are never dropped. The queue is bounded at the mark
        /// plus the replies of frames already buffered.
        pub fn armOrPark(self: *Self, slot: usize, c: *Conn) !void {
            if (state.pendingOut(c) > self.outbound_high_water_bytes or
                c.peer.outboundSaturated())
            {
                // A genuine sink park: this connection is not draining its own
                // outbound, so it is the slow reader the reaper targets.
                // Which kind of park this is comes from the queue depth
                // `refreshWaiting` reads, not from a flag passed alongside.
                markParked(self, slot, c, .sink);
                return;
            }
            if (self.fan_in_throttle and anySinkParked(self)) {
                // A fan-in park: an innocent fast source throttled behind some
                // other slow sink. It is a victim, not the slow reader.
                markParked(self, slot, c, .fan_in);
                return;
            }
            try armRecv(self, slot, c);
        }

        /// Park the read seat, and tell the embedder once per park.
        ///
        /// `reason` is reported, not consulted: which deadline this park
        /// answers to still comes from the connection's own queue depth in
        /// `refreshWaiting`, so the hook cannot disagree with the reaper.
        pub fn markParked(self: *Self, slot: usize, c: *Conn, reason: ParkReason) void {
            // A seat arriving `.starved` is already on another list, and
            // linking it would put one slot on two (see `Conn.next_link`).
            // Every caller vacates the seat first.
            std.debug.assert(c.read == .idle or c.read == .parked);
            const was_parked = c.read == .parked;
            // State first, hook last. The hook receives `slot` so it may call
            // back in, `closeSlot` is public, and anything it does must land
            // on a seat that already reads `.parked`, not be overwritten after.
            c.read = .parked;
            if (!was_parked) Lifecycle.linkOnto(self, &self.parked_head, slot);
            Deadlines.refreshWaiting(self, c);
            if (!was_parked) {
                if (self.on_park) |hook| hook(self.make_ctx, slot, c.app_ctx, reason);
            }
        }

        /// True when any connection that can still write is over its outbound
        /// high-water mark (a true ADR-0017 sink park, not a fan-in source
        /// park). A `.draining` connection counts: its queued bytes are just
        /// as unread, and releasing the sources it throttles while they are
        /// still in the kernel's hands is what the fan-in mark exists to
        /// prevent.
        pub fn anySinkParked(self: *const Self) bool {
            return self.over_mark_count > 0;
        }

        /// Returns when this connection's wait runs out, and what the loop
        /// would call the resulting close. Null when it is not waiting on the
        /// partner.
        ///
        /// The one place that decides. `nextDeadlineMs` sizes the poll wait
        /// from this and `reapDeadlines` acts on it, so the two cannot
        /// disagree about which connections have deadlines. If they could,
        /// a connection the wait counted but the reap skipped would make
        /// `poll` return instantly forever: a busy-spin, not a leak, and the
        /// hardest failure here to see in a test.
        pub fn onRecvConsume(self: *Self, slot: usize, comp: Completion) RecvVerdict {
            if (slot >= self.conns.len) return .done;
            const c = &self.conns[slot];
            if (c.state == .draining) {
                // A terminal failure may race an already-armed recv (for
                // example closeSlot on a quiet bridge sibling). Retire that
                // borrow without applying bytes or admitting more work: the
                // abort already queued before `.draining` is final.
                std.debug.assert(c.read == .armed);
                c.read = .idle;
                return .done;
            }
            if (c.state != .open) return .done;
            // This completion retires the one armed recv: the read seat is
            // idle until the verdict re-arms or parks it.
            std.debug.assert(c.read == .armed);
            c.read = .idle;
            if (comp.recv_no_buffer) {
                // The shared pool was momentarily empty when data arrived. Not
                // a connection failure: park buffer-starved; a recycle (or the
                // end-of-batch sweep) re-arms the read.
                parkStarved(self, slot, c);
                return .done;
            }
            if (comp.result <= 0) {
                // result == 0 is a clean EOF; negative is a read error. Either
                // ends the connection.
                if (comp.result < 0)
                    failure_projection.record(&c.peer, comp, error.ReadFailed);
                return .close;
            }

            const incoming = comp.borrowed.recvBytes() orelse &.{};

            return switch (self.backend.wireFraming(c.fd)) {
                .byte_stream => stream: {
                    // Apply every whole frame in this completion's bytes,
                    // carrying a partial tail into the connection's spill.
                    // recvOuterPrefix projects an op:abort for a malformed or
                    // oversize frame before erroring; the .fail verdict flushes
                    // it, then closes. The drain, its cap mirror, and the
                    // tail-to-spill copy are shared with the iroh loop in
                    // `frame_stream.drainWholeFrames`, so the two cannot drift.
                    break :stream switch (frame_stream.drainWholeFrames(&c.peer, &c.spill, incoming, self.allocator)) {
                        .ok => .proceed,
                        .fail => .fail,
                        .close => .close,
                    };
                },
                .message => {
                    c.peer.recvPacket(incoming) catch return .fail;
                    return .proceed;
                },
            };
        }

        /// Act on `onRecvConsume`'s verdict, after the completion's pool
        /// buffer has been recycled.
        pub fn onRecvFinish(self: *Self, slot: usize, verdict: RecvVerdict) void {
            // The .close and .fail arms skip the `liveConn` guard:
            // a non-.done verdict was minted under it in `onRecvConsume`, and
            // this slot cannot have been *reclaimed* in between, its recv op
            // stays counted across this call, so no teardown can reach it. Its
            // state can still have changed: the recycle resumes a starved
            // connection, that can park one, and `on_park` is a public hook
            // free to close anything. `closeConn` and `failConn` both guard on
            // state, and that guard covers it.
            switch (verdict) {
                .done => return,
                .close => {
                    const c = &self.conns[slot];
                    Lifecycle.closeConn(self, slot, c);
                    return;
                },
                .fail => {
                    const c = &self.conns[slot];
                    failConn(self, slot, c);
                    return;
                },
                .proceed => {},
            }
            const c = Lifecycle.liveConn(self, slot) orelse return;

            // Surfaced events belong to the application. The engine auto-answers
            // a bootstrap fetch; every other event (an application deliver or
            // resolve) is offered to the optional serve hook, then released. With
            // no hook, the loop is blind to application traffic. The hook is where
            // an application runs objects on the scalable path. A hook error
            // closes only that connection; one bad partner never tears down the
            // loop. A reply the hook enqueues on the peer flushes in the
            // `driveOut` below, matching the drain-then-flush order
            // `driver.Session.step` uses.
            while (c.peer.pollEvent()) |ev_in| {
                var ev = ev_in;
                defer ev.deinit();
                if (self.serve) |serve_fn| {
                    serve_fn(c.app_ctx, &c.peer, &ev) catch |err| {
                        c.peer.emitFailure(err);
                        failConn(self, slot, c);
                        return;
                    };
                }
                // A hook may condemn its own connection (a bridge `close`
                // action for the session it is serving). That is terminal:
                // the abort is already queued, so serving further events
                // would mint replies behind it, and the drive and read-arm
                // below no longer apply. Unpolled events die with the peer. status-allow: lifecycle transition
                if (c.state != .open) return;
            }

            driveOut(self, slot, c) catch |err| {
                failConnWith(self, slot, c, err);
                return;
            };
            if (c.state != .open) return;

            armOrPark(self, slot, c) catch |err| closeConnWith(self, slot, c, err);
        }

        /// Park a connection whose recv found the shared pool empty. Distinct
        /// from ADR-0017 backpressure. Starvation ends when a
        /// buffer recycles.
        pub fn parkStarved(self: *Self, slot: usize, c: *Conn) void {
            // Only an idle read seat parks starved: the caller's recv
            // completion just vacated it, and linking an already-listed slot
            // would build a cycle.
            std.debug.assert(c.read == .idle);
            c.read = .starved;
            Lifecycle.linkOnto(self, &self.starved_head, slot);
        }

        /// Hand a borrowed completion payload back exactly once, then re-arm
        /// one buffer-starved connection when a recv buffer became available.
        pub fn recycleBorrowedPayload(self: *Self, comp: Completion) void {
            const freed_recv = comp.borrowed.kind == .recv;
            self.backend.recycleBorrowed(comp);
            if (freed_recv) resumeStarved(self, .one);
        }

        /// Re-arm starved connections. `.one` re-arms the first that can read,
        /// the per-recycle cadence, since exactly one buffer just freed. `.all`
        /// drains the list, the end-of-poll-batch cadence, when every pool
        /// buffer the batch carried has been recycled: a connection parked by a
        /// starved completion dispatched *after* the batch's recycles would
        /// otherwise wait for a recycle that already happened. Either way, one
        /// whose outbound crossed the high-water mark re-parks under ADR-0017
        /// (its drain re-arms it) without consuming a freed buffer, and a
        /// re-armed read that loses the race for a buffer completes
        /// starved again. It is never dropped.
        pub fn resumeStarved(self: *Self, comptime scope: enum { one, all }) void {
            while (self.starved_head < self.conns.len) {
                const slot = self.starved_head;
                const c = &self.conns[slot];
                Lifecycle.unlinkFrom(self, &self.starved_head, slot);
                c.read = .idle;
                if (c.state != .open) continue;
                // One owner for the arm-or-park decision (ADR-0017). Restating
                // its branches here is how the two drift.
                armOrPark(self, slot, c) catch |err| {
                    closeConnWith(self, slot, c, err);
                    continue;
                };
                // Only an actual arm consumed the buffer that freed.
                if (scope == .one and c.read == .armed) return;
            }
        }

        /// Encode queued sends, append their frame bytes to the outbound queue,
        /// and submit a write if one is not already in flight.
        pub fn driveOut(self: *Self, slot: usize, c: *Conn) !void {
            while (true) {
                const outcome = c.peer.step() catch |err| switch (err) {
                    // The engine's outbound waterline is flow control, not a
                    // verdict: the refused carrier stays queued and retryable
                    // (`Peer.pushEncodedFromPending`). Stop driving, flush what
                    // is already encoded, and let the send completion's next
                    // drive retry the carrier once the queue has room.
                    // Condemning here turned a full queue into a dead
                    // connection.
                    error.OutboundBackpressure => break,
                    else => return err,
                };
                if (outcome == .idle) break;
            }
            try flushOutbound(self, slot, c);
        }

        /// Append already-encoded outbound frames to the connection's queue and
        /// submit a write. Split from `driveOut` so a failed `step` can still
        /// flush the `op:abort` the engine projected for it. Frames always
        /// append to `back`: while a write is in flight, the backend borrows
        /// `front`'s storage, and an append there could realloc it out from
        /// under the kernel. With no write in flight, a drained front swaps
        /// with the back and the queued bytes become the next frozen submit.
        /// Queue depth is an eligibility input, so every path that changes it
        /// ends here and refreshes. Cross-connection arms land here too.
        pub fn flushOutbound(self: *Self, slot: usize, c: *Conn) !void {
            defer Deadlines.refreshWaiting(self, c);
            return switch (self.backend.wireFraming(c.fd)) {
                .byte_stream => flushStreamOutbound(self, slot, c),
                .message => flushMessageOutbound(self, slot, c),
            };
        }

        fn flushStreamOutbound(self: *Self, slot: usize, c: *Conn) !void {
            try frame_stream.queueOutboundBytes(&c.peer, self.allocator, &c.back);
            if (c.write_in_flight) return;
            if (state.pendingFront(c) == 0 and c.back.items.len > 0) {
                c.front.clearRetainingCapacity();
                c.front_off = 0;
                std.mem.swap(std.ArrayList(u8), &c.front, &c.back);
            }
            if (state.pendingFront(c) > 0) try submitSend(self, slot, c);
        }

        fn flushMessageOutbound(self: *Self, slot: usize, c: *Conn) !void {
            if (c.write_in_flight) return;
            std.debug.assert(c.back.items.len == 0);
            if (state.pendingFront(c) == 0) {
                var next = c.peer.takeOutbound() orelse return;
                defer next.deinit();
                c.front.clearRetainingCapacity();
                c.front_off = 0;
                try c.front.appendSlice(self.allocator, next.bytes());
            }
            try submitSend(self, slot, c);
        }

        /// Preserve a loop-owned operation failure unless the engine already
        /// recorded that same cause while projecting its abort. Re-recording
        /// it would erase any abort-delivery consequence already attached.
        pub fn recordConnFailure(c: *Conn, err: anyerror) void {
            if (c.peer.lastAbort()) |failure| {
                if (std.mem.eql(u8, failure.error_name, @errorName(err))) return;
            }
            c.peer.recordFailure(err);
        }

        pub fn failConnWith(self: *Self, slot: usize, c: *Conn, err: anyerror) void {
            recordConnFailure(c, err);
            failConn(self, slot, c);
        }

        pub fn closeConnWith(self: *Self, slot: usize, c: *Conn, err: anyerror) void {
            recordConnFailure(c, err);
            Lifecycle.closeConn(self, slot, c);
        }

        /// Resolve a per-connection failure the way the blocking pump does
        /// (`connection.pumpOver`): encode and flush whatever the engine
        /// projected, typically an `op:abort`, then close this one
        /// connection. A failure producing or submitting those terminal bytes
        /// is retained as the abort-delivery consequence. One bad partner
        /// still tears down only its own connection.
        pub fn failConn(self: *Self, slot: usize, c: *Conn) void {
            if (c.state != .open) return;
            // Terminal failure is a lifecycle, not an outbound-queue flag.
            // From here only already-projected bytes and their send
            // completions may run; an armed recv is retired without applying.
            c.state = .draining;
            // The flush below waits on the partner, so it is bounded: a
            // partner that never reads the abort must not pin this slot. This
            // is a different wait from the slow-reader park it may replace, so
            // the refresh restarts the clock rather than inheriting it.
            Deadlines.refreshWaiting(self, c);
            while (true) {
                const outcome = c.peer.step() catch |err| {
                    if (c.peer.lastAbort() == null)
                        c.peer.recordFailure(err)
                    else
                        c.peer.recordAbortDeliveryFailure(err);
                    break;
                };
                if (outcome == .idle) break;
            }
            flushOutbound(self, slot, c) catch |err| {
                if (c.peer.lastAbort() == null)
                    c.peer.recordFailure(err)
                else
                    c.peer.recordAbortDeliveryFailure(err);
                Lifecycle.closeConn(self, slot, c);
                return;
            };
            if (!c.write_in_flight and state.pendingOut(c) == 0) Lifecycle.closeConn(self, slot, c);
        }

        pub fn submitSend(self: *Self, slot: usize, c: *Conn) !void {
            // The backend borrows this slice until the send completes; `front`
            // is frozen from here until `onSend` sees it drained.
            try self.backend.submitSend(state.userData(.send, slot), c.fd, c.front.items[c.front_off..]);
            c.write_in_flight = true;
            c.ops_in_flight += 1;
        }

        /// The partner caught up: resume a read parked at the high-water mark,
        /// and release the fan-in sources that mark was holding.
        ///
        /// Both send paths need this. A partial write can take `pendingOut`
        /// under the mark just as a full drain can, and dropping the deadline
        /// there without re-arming the read left the connection with no
        /// wakeup at all: no armed recv, no deadline, and its victims still
        /// asleep. If the remainder then stalled, nothing would ever run again
        /// on that connection.
        pub fn resumeIfDrained(self: *Self, slot: usize, c: *Conn) void {
            // Unconditional: a `.draining` connection's queue moves too, and
            // its `over_mark` contribution keeps fan-in victims parked until
            // it is given back. Only the re-arm below is `.open`-only.
            Deadlines.refreshWaiting(self, c);
            if (c.state == .open and c.read == .parked and
                state.pendingOut(c) <= self.outbound_high_water_bytes and
                !c.peer.outboundSaturated())
            {
                if (!(self.fan_in_throttle and anySinkParked(self))) {
                    // No refresh here: the call above already evaluated
                    // eligibility with the enclosing condition's `pendingOut`
                    // under the mark, so the stamp is clear and the over-mark
                    // recount has run. Leaving `.parked` for `.idle` cannot
                    // make an ineligible connection eligible.
                    Lifecycle.unlinkParked(self, slot);
                    armRecv(self, slot, c) catch |err| closeConnWith(self, slot, c, err);
                }
            }
        }

        pub fn onSend(self: *Self, slot: usize, comp: Completion) void {
            if (slot >= self.conns.len) return;
            const c = &self.conns[slot];
            if (c.state != .open and c.state != .draining) return;
            const framing = self.backend.wireFraming(c.fd);
            if (comp.result <= 0) {
                failure_projection.record(&c.peer, comp, error.WriteFailed);
                Lifecycle.closeConn(self, slot, c);
                return;
            }
            if (framing == .message and
                @as(usize, @intCast(comp.result)) != state.pendingFront(c))
            {
                c.peer.recordFailure(error.WriteFailed);
                Lifecycle.closeConn(self, slot, c);
                return;
            }
            c.front_off += @intCast(comp.result);
            if (c.front_off < c.front.items.len) {
                // Partial write: send the remainder. `front` is untouched
                // since the original submit (appends went to `back`), so the
                // resubmitted slice is still backed by live storage. The
                // advance lowered `pendingOut` and may have taken it under the
                // mark, so this is a drain like any other: the read resumes
                // and the victims wake, not merely the deadline clearing.
                submitSend(self, slot, c) catch |err| {
                    closeConnWith(self, slot, c, err);
                    return;
                };
                resumeIfDrained(self, slot, c);
                return;
            }
            // Drained. Burst capacity frees on drain (the spill's posture,
            // ADR-0012/0042): one slow-reader episode must not pin its
            // high-water bytes for the connection's lifetime. Steady-sized
            // capacity is retained so ordinary reply traffic never reallocates.
            frame_stream.reclaimBurst(&c.front, self.allocator, state.steady_outbound_bytes);
            // A drained connection never pins burst capacity: this is the
            // 500k-footprint invariant a slow-drain episode must not break. This
            // pins the bound loudly in every safe build, on every drain.
            std.debug.assert(c.front.capacity <= state.steady_outbound_bytes);
            c.front_off = 0;
            c.write_in_flight = false;
            if (c.state == .draining) {
                switch (framing) {
                    .byte_stream => {
                        // Bytes queued behind the completed frozen front were
                        // already present when failConn entered `.draining`;
                        // send them without stepping the peer or admitting any
                        // new application work.
                        if (c.back.items.len > 0) {
                            // `reclaimBurst` above emptied the front in both
                            // its arms. Swapping a non-empty front into `back`
                            // would resend bytes the partner already has,
                            // forever.
                            std.debug.assert(c.front.items.len == 0);
                            std.mem.swap(std.ArrayList(u8), &c.front, &c.back);
                            submitSend(self, slot, c) catch |err| closeConnWith(self, slot, c, err);
                            // The swap can take this connection under the
                            // mark. It is terminal, so its own read stays down,
                            // but the refresh is what releases the sources it
                            // was throttling: they must not wait on a send that
                            // may never complete.
                            Deadlines.refreshWaiting(self, c);
                        } else {
                            Lifecycle.closeConn(self, slot, c);
                        }
                    },
                    .message => {
                        if (c.peer.hasOutbound()) {
                            flushMessageOutbound(self, slot, c) catch |err| closeConnWith(self, slot, c, err);
                        } else {
                            Lifecycle.closeConn(self, slot, c);
                        }
                    },
                }
                return;
            }
            // Bytes queued on `back` while this write was in flight, and any
            // reply this drive encodes, swap into the emptied front and go
            // out now (`flushOutbound`).
            driveOut(self, slot, c) catch |err| {
                failConnWith(self, slot, c, err);
                return;
            };
            resumeIfDrained(self, slot, c);
        }

        /// Re-evaluate fan-in throttling once for a poll batch in which one or
        /// more connections departed. Called from the loop body, never from a
        /// teardown, so the resume below cannot re-enter teardown, and a batch
        /// that closed many connections pays one table sweep rather than one
        /// per connection.
        pub fn drainFanInDirty(self: *Self) void {
            if (!self.fan_in_dirty) return;
            self.fan_in_dirty = false;
            // `closeAndDrain` is sweeping slots closed; arming a fresh recv
            // behind its sweep is the hazard `Bridge.freeConnCtx` refuses too.
            if (self.tearing_down or self.shutting_down) return;
            if (anySinkParked(self)) return;
            resumeFanInSources(self);
        }

        /// Re-arm connections parked solely by `fan_in_throttle` once no true
        /// ADR-0017 sink remains over the high-water mark. A seat that is still
        /// sink-parked (`pendingOut` over the mark) or no longer open is left status-allow: lifecycle transition
        /// alone, on the list, untouched.
        ///
        /// The walk follows the live list and splices in place. Detaching the
        /// list first would keep re-parks from being chased, but it opens a
        /// window: for the length of the walk a slot reads `.parked` while
        /// unreachable from `parked_head`, which is exactly the state
        /// `unlinkParked` treats as a corrupt chain, and a hook re-entering the
        /// loop meanwhile would hit it, `free_conn_ctx` drains host actions,
        /// and one of them can close a sibling. In place there is no window,
        /// and a re-park pushes onto the head the walk has already passed, so
        /// it still terminates.
        pub fn resumeFanInSources(self: *Self) void {
            var next = self.parked_head;
            while (next < self.conns.len) {
                const slot = next;
                const c = &self.conns[slot];
                // It left the list under us, a hook re-entered through the
                // previous iteration's close and reached this slot. Its link
                // word is no longer a parked-list link: `teardown` hands it to status-allow: lifecycle transition
                // the free list, and a re-adopting `dial` zeroes it, which
                // walks into slot 0 and, if slot 0 is an ordinary open
                // connection whose own link is still zero, never leaves. So do
                // not read it. The departure already asked for a re-sweep; ask
                // again for the rest of this list and let the batch's drain run
                // it.
                if (c.read != .parked) {
                    self.fan_in_dirty = true;
                    return;
                }
                next = c.next_link;
                if (c.state != .open or state.pendingOut(c) > self.outbound_high_water_bytes or
                    c.peer.outboundSaturated()) continue;
                Lifecycle.unlinkParked(self, slot);
                Deadlines.refreshWaiting(self, c);
                armOrPark(self, slot, c) catch |err| closeConnWith(self, slot, c, err);
            }
        }
    };
}
