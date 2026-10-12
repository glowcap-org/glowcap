//! Inline connection-slot lifecycle and intrusive-list ownership.
//!
//! One owner admits a peer into a free slot, links its transient read state,
//! retires backend operations, and reclaims the slot. Close submission and
//! teardown stay together so descriptor, borrowed-send, callback, and Peer
//! lifetimes cannot split across competing state machines.

const std = @import("std");
const engine = @import("engine");
const clock = @import("../../../clock.zig");
const state = @import("../state.zig");
const configuration = @import("../configuration.zig");

pub fn Machine(
    comptime Self: type,
    comptime Backend: type,
    comptime Types: type,
    comptime Deadlines: type,
) type {
    _ = Backend;
    return struct {
        const Conn = Types.Conn;
        const Fd = Types.Fd;
        const DialAdmission = configuration.DialAdmission;

        pub fn adoptSlot(
            self: *Self,
            slot: usize,
            fd: Fd,
            peer: engine.Peer,
            opened: bool,
            admission: DialAdmission,
        ) *Conn {
            const c = &self.conns[slot];
            const generation = c.generation;
            c.* = .{
                .state = .open,
                .opened = opened,
                .fd = fd,
                .peer = peer,
            };
            self.live_count += 1;
            std.debug.assert((slot < self.ordinary_capacity) == (admission == .ordinary));
            c.generation = generation;
            return c;
        }

        pub fn liveConn(self: *Self, slot: usize) ?*Conn {
            if (slot >= self.conns.len) return null;
            const c = &self.conns[slot];
            if (c.state != .open) return null;
            return c;
        }

        pub fn reapDeadlines(self: *Self) void {
            const due = Deadlines.earliestDue(self) orelse return;
            const now = clock.nowMonotonicMs();
            if (now < due) return;
            // Something was due, or the cache was stale-early. Either way the
            // next nearest has to be found again, and this walk is already
            // visiting every slot and already computing each deadline, so it
            // finds it here. Leaving the cache null costs a second full walk on
            // the next poll, over the slots this one just read.
            self.earliest_due_ms = null;
            var next_earliest: ?i64 = null;
            for (self.conns, 0..) |*c, slot| {
                const deadline = Deadlines.pendingDeadline(self, c) orelse continue;
                if (now < deadline.due) {
                    if (next_earliest == null or deadline.due < next_earliest.?) next_earliest = deadline.due;
                    continue;
                }
                c.close_reason = deadline.reason;
                // Shut a draining fd down so an armed recv completes at once
                // rather than waiting on the partner that already will not
                // read.
                if (c.state == .draining) self.backend.shutdownFd(c.fd);
                closeConn(self, slot, c);
            }
            // Safe to install, though not for the reason the "only ever lowers"
            // rule would give: that rule is disabled here, because the cache
            // was set null above and `setWaiting`'s fold is a no-op on a null
            // one. It is safe because no hook can run during this walk. A
            // reaped connection is over the mark or draining, which means a
            // send was submitted, which means an op is in flight, so
            // `closeConn`'s inline-teardown arm is unreachable from here and
            // `on_close` and `free_conn_ctx` never fire. A future change that
            // lets one fire has to revisit this line.
            self.earliest_due_ms = next_earliest;
        }

        /// Push a slot onto `head`. The caller guarantees it is on no list.
        /// Pushing an already-listed slot would build a cycle.
        pub fn linkOnto(self: *Self, head: *usize, slot: usize) void {
            const c = &self.conns[slot];
            c.prev_link = @intCast(self.conns.len);
            c.next_link = @intCast(head.*);
            if (head.* < self.conns.len) self.conns[head.*].prev_link = @intCast(slot);
            head.* = slot;
        }

        /// Splice a slot out of the list at `head`. `O(1)`, which is the reason
        /// the links are a pair: removal by value from a singly linked list
        /// walks it, and this runs on the close path, where a walk per departure
        /// makes a mass close quadratic.
        pub fn unlinkFrom(self: *Self, head: *usize, slot: usize) void {
            const c = &self.conns[slot];
            if (c.next_link < self.conns.len) self.conns[c.next_link].prev_link = c.prev_link;
            if (c.prev_link < self.conns.len) {
                self.conns[c.prev_link].next_link = c.next_link;
            } else {
                head.* = c.next_link;
            }
        }

        /// Take a connection off the parked list, leaving the seat `.idle`.
        /// A seat that is not parked is not listed, so this is a no-op there.
        pub fn unlinkParked(self: *Self, slot: usize) void {
            const c = &self.conns[slot];
            if (c.read != .parked) return;
            c.read = .idle;
            unlinkFrom(self, &self.parked_head, slot);
        }

        /// Remove a connection from the starved list (on close) so teardown's
        /// slot reset cannot break the chain.
        pub fn unlinkStarved(self: *Self, slot: usize) void {
            const c = &self.conns[slot];
            if (c.read != .starved) return;
            c.read = .idle;
            unlinkFrom(self, &self.starved_head, slot);
        }

        pub fn closeConn(self: *Self, slot: usize, c: *Conn) void {
            // A free slot has an undefined `fd`, so closing one would hand the
            // backend garbage. Reaching here with one is currently impossible
            // (a recv's op stays counted across `onRecvFinish`, so no nested
            // teardown can reclaim the slot under it), but that argument spans
            // three functions and should not be the only thing standing
            // between this and a bad close.
            if (c.state == .free or c.state == .closing) return;
            unlinkStarved(self, slot);
            unlinkParked(self, slot);
            // A closing connection waits on nothing: its deadline, if any, has
            // already done its work. Dropping the stamp here keeps
            // `waiting_count` at zero on a healthy loop rather than pinned by
            // slots that are merely retiring their ops.
            Deadlines.setWaiting(self, c, 0);
            c.state = .closing;
            // A closing connection throttles nobody, and the slot reset at
            // teardown would otherwise drop its contribution silently.
            Deadlines.refreshOverMark(self, c);
            // Closing an fd does not itself cancel an async operation that
            // already holds the underlying socket (notably an io_uring recv).
            // Shutdown first on every terminal path, not only closeAndDrain,
            // so kernel operations retire even when close completes before
            // them. Userspace backends may make this a no-op and synthesize
            // those completions from submitClose instead.
            self.backend.shutdownFd(c.fd);
            self.backend.submitClose(state.userData(.close, slot), c.fd) catch {
                // Could not even queue the close, so this branch owns the fd:
                // the normal path closes it through the queued op, and
                // `teardown` never closes, so the two are mutually exclusive
                // and there is no double close.
                //
                // Shut it down first. `submitClose` is contracted to complete
                // whatever is pending on the fd; `closeFd` is only "release a
                // handle" and neither backend synthesizes completions for it.
                // Closing straight away would leave an armed recv and an
                // in-flight send counted forever: `closeAndDrain` would wait
                // on work that can never arrive, and `deinit` would trip its
                // assertion. A shutdown makes those complete, and the fd is
                // released once they have.
                if (c.ops_in_flight == 0) {
                    self.backend.closeFd(c.fd);
                    if (teardown(self, slot)) self.closed_count += 1;
                    return;
                }
                // Ops are still counted, and this branch cannot assume they
                // will retire on their own: `shutdownFd` unblocks an OS recv,
                // but a userspace backend is allowed to make it a no-op and
                // iroh does, so the only thing that retires those ops there is
                // the `submitClose` that just failed. Failing means the
                // backend could not allocate completion capacity, which is
                // transient, so the retry rides the poll batch.
                c.owns_fd_close = true;
                self.pending_close_submits += 1;
                return;
            };
            c.ops_in_flight += 1;
        }

        /// Retry closes the backend could not admit. This is the one repeated
        /// table walk: it runs only while transient completion-capacity
        /// pressure leaves an owed close, and the driver bounds that wait.
        pub fn retryPendingCloses(self: *Self) !void {
            if (self.pending_close_submits == 0) return;
            var first_err: ?anyerror = null;
            for (self.conns, 0..) |*c, slot| {
                // `owns_fd_close` is set at exactly one site, the failed
                // submit below, so it doubles as the marker for a close this
                // loop still owes. Clearing it hands the fd back to the close
                // op that just landed.
                if (!c.owns_fd_close) continue;
                self.backend.submitClose(state.userData(.close, slot), c.fd) catch |err| {
                    if (first_err == null) first_err = err;
                    continue;
                };
                c.owns_fd_close = false;
                c.ops_in_flight += 1;
                self.pending_close_submits -= 1;
            }
            if (first_err) |err| return err;
        }

        /// Submit the listener cancellation/close when backend capacity admits
        /// it. Unlike a newly accepted descriptor, the listener can have an
        /// accept operation pending. `closeFd` alone is not contracted to retire
        /// that operation. Retain the descriptor and retry instead of letting
        /// `closeAndDrain` return while the backend still owns an accept.
        pub fn retryListenerClose(self: *Self) !void {
            if (self.listener_close_pending) return;
            const fd = self.listener_close_fd orelse return;
            try self.backend.submitClose(state.userData(.close, self.conns.len), fd);
            self.listener_close_pending = true;
        }

        /// Account one completed per-connection op. On a closing connection the
        /// op that drains the last in-flight one reclaims the slot, deferring
        /// teardown until here is what keeps `front` alive for as long as any
        /// submitted send could still touch it, and keeps the slot from being
        /// reused while a stale completion could still arrive for it. A close
        /// for a refused accept carries the out-of-range sentinel slot
        /// `conns.len` and is ignored rather than indexed.
        pub fn retireConnOp(self: *Self, slot: usize) void {
            if (slot >= self.conns.len) return;
            const c = &self.conns[slot];
            if (c.state == .free) return;
            // Not a tolerant decrement: a completion for a live slot always
            // corresponds to an op this loop counted, and both directions of
            // drift are serious. Under-counting strands the slot; over-counting
            // tears it down while the kernel still reads `front`.
            std.debug.assert(c.ops_in_flight > 0);
            c.ops_in_flight -= 1;
            if (c.state == .closing and c.ops_in_flight == 0) {
                if (c.owns_fd_close) self.backend.closeFd(c.fd);
                if (teardown(self, slot)) self.closed_count += 1;
            }
        }

        /// Reclaim a slot, reporting whether it happened.
        ///
        /// The return value is what keeps `closed_count` to one writer per
        /// reclaim. A teardown that arrives while the slot is being adopted is
        /// deferred, not performed, and `finishConnected` performs it later,
        /// so a caller that counts unconditionally counts the same connection
        /// twice, once where it asked and once where it happened. That is not
        /// bookkeeping: `closed_count` is what `run(.{ .after_closed = n })`
        /// stops on, so an over-count returns the loop with connections still
        /// open. The counters beside this one (`waiting_count`,
        /// `over_mark_count`) each have exactly one writer. This gives
        /// `closed_count` the same.
        pub fn teardown(self: *Self, slot: usize) bool {
            const c = &self.conns[slot];
            if (self.adopting_slot) |adopting| {
                if (adopting == slot) {
                    // `finishConnected` reclaims it once the hook returns and
                    // its context has been released.
                    self.adopting_teardown_deferred = true;
                    return false;
                }
            }
            // Notify the application first, while the per-connection context
            // is still alive: this fires once per connection, and `opened`
            // tells a dialer whether the connection ever completed its
            // connect (a refused dial reports `opened == false`).
            if (self.on_close) |on_close| on_close(self.make_ctx, slot, c.app_ctx, .{
                .opened = c.opened,
                .reason = c.close_reason,
                .failure = c.peer.lastAbort(),
            });
            // Free the per-connection app context next: it may hold a vat that
            // borrows this peer, so it must release before the peer deinits.
            if (c.app_ctx) |app_ctx| {
                if (self.free_conn_ctx) |free| free(self.make_ctx, app_ctx);
            }
            const generation = c.generation;
            if (c.owns_fd_close) self.pending_close_submits -= 1;
            c.peer.deinit();
            c.spill.deinit(self.allocator);
            c.front.deinit(self.allocator);
            c.back.deinit(self.allocator);
            Deadlines.setWaiting(self, c, 0);
            // Unconditional, not a recompute: `deinit` tears down slots that
            // are still `.open`, where a recompute would agree they are over
            // the mark and leave the count pointing at a slot about to be
            // wiped.
            if (c.over_mark) {
                c.over_mark = false;
                self.over_mark_count -= 1;
            }
            c.* = .{};
            self.live_count -= 1;
            // The slot is somebody else's now; anyone holding a `*Conn` from
            // before this point can tell by comparing.
            c.generation = generation +% 1;
            pushFreeSlot(self, slot);

            // The connection that just left may have been the last sink over
            // the high-water mark, and the fan-in sources it throttled have no
            // other resume trigger: every terminal path returns before
            // `onSend`'s tail runs (ADR-0082). Without a resume, a closing
            // sink strands its victims parked for the loop's lifetime, they
            // are exempt from the park reaper because they are
            // victims, not slow readers.
            //
            // Recorded, not performed. Resuming here would re-enter the loop
            // from inside a teardown: `resumeFanInSources` arms reads, an arm
            // failure closes, and a close whose submit fails tears down again,
            // one stack frame per slot. It would also make a mass close
            // quadratic, since every teardown would sweep the whole table.
            // The loop body drains this once per poll batch instead.
            if (self.fan_in_throttle) self.fan_in_dirty = true;
            return true;
        }

        pub fn freeSlot(self: *Self, admission: DialAdmission) ?usize {
            const head = switch (admission) {
                .ordinary => &self.ordinary_free_head,
                .reserved => &self.reserved_free_head,
            };
            if (head.* >= self.conns.len) return null;
            const slot = head.*;
            // Push/pop at the head only, so the free list needs no `prev_link`.
            head.* = self.conns[slot].next_link;
            return slot;
        }

        pub fn pushFreeSlot(self: *Self, slot: usize) void {
            std.debug.assert(self.conns[slot].state == .free);
            const head = if (slot < self.ordinary_capacity)
                &self.ordinary_free_head
            else
                &self.reserved_free_head;
            self.conns[slot].next_link = @intCast(head.*);
            head.* = slot;
        }
    };
}
