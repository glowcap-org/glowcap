//! Signaling exchange admission, cross-thread transfer, and publication.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const net = @import("net");
const sidecar = @import("../sidecar.zig");

const crypto = foundation.crypto;
const Peer = sidecar.Peer;

/// One bounded SDP/ICE frame. Candidate pumping borrows one such transient
/// stack buffer per pump call, never per connection; admission uses the same
/// bound for the endpoint-owned transfer pool.
pub const signaling_frame_bytes: usize = sidecar.max_signal_bytes;
const max_signal_payloads = 256;

pub const SignalPayloadPool = struct {
    storage: [][signaling_frame_bytes]u8,
    free_slots: [max_signal_payloads]u8 = undefined,
    free_len: usize = max_signal_payloads,

    pub fn init(allocator: std.mem.Allocator) !SignalPayloadPool {
        const storage = try allocator.alloc([signaling_frame_bytes]u8, max_signal_payloads);
        var pool: SignalPayloadPool = .{ .storage = storage };
        for (&pool.free_slots, 0..) |*slot, i| slot.* = @intCast(i);
        return pool;
    }

    pub fn deinit(self: *SignalPayloadPool, allocator: std.mem.Allocator) void {
        std.debug.assert(self.free_len == max_signal_payloads);
        allocator.free(self.storage);
        self.* = undefined;
    }

    pub fn acquire(self: *SignalPayloadPool) ?u8 {
        if (self.free_len == 0) return null;
        self.free_len -= 1;
        return self.free_slots[self.free_len];
    }

    pub fn release(self: *SignalPayloadPool, slot: u8) void {
        std.debug.assert(self.free_len < max_signal_payloads);
        self.free_slots[self.free_len] = slot;
        self.free_len += 1;
    }

    pub fn bytes(self: *SignalPayloadPool, slot: u8, len: usize) []u8 {
        std.debug.assert(len <= signaling_frame_bytes);
        return self.storage[slot][0..len];
    }
};

pub const ConnectTarget = struct { designator: []const u8 };

pub const DialResolver = struct {
    pub fn resolve(partner: model.PeerLocator) !ConnectTarget {
        if (!std.mem.eql(u8, partner.transport, model.transport.webrtc)) return error.UnknownTransport;
        if (crypto.PeerKey.fromDesignator(partner.designator) == null) return error.InvalidAddress;
        return .{ .designator = partner.designator };
    }
};

pub const SignalingAuthority = struct {
    ctx: *anyopaque,
    sendOffer: *const fn (ctx: *anyopaque, fd: i32, designator: []const u8, sdp: []const u8) anyerror!void,
    sendCandidate: *const fn (ctx: *anyopaque, fd: i32, ice: []const u8) anyerror!void,
};

pub const DialRow = struct { user_data: u64, peer: Peer, designator: []u8 };
pub const AdoptRow = struct { peer: Peer };
pub const Accepted = struct { fd: i32, peer: Peer };
pub const AcceptOutcome = union(enum) { connected: Accepted, failed: anyerror };
pub const SignalIn = union(enum) {
    adopt: struct { fd: i32, peer: Peer },
    answer: struct { fd: i32, slot: u8, len: u16 },
    candidate: struct { fd: i32, slot: u8, len: u16 },
};
pub const max_accept_stash = 128;
pub const max_signal_in = 256;

/// Rows before consumed have retired their owners. On a mid-drain failure,
/// retain the unvisited owner-bearing suffix with one allocation-free memmove.
/// The healthy path moves nothing.
fn retainUnvisited(comptime T: type, items: []T, consumed: usize) usize {
    std.debug.assert(consumed <= items.len);
    const remaining = items.len - consumed;
    if (remaining > 0) std.mem.copyForwards(T, items[0..remaining], items[consumed..]);
    return remaining;
}

pub fn Machine(comptime Self: type, comptime Fd: type, comptime Connections: type) type {
    return struct {
        pub fn freeQueued(self: *Self, queued: SignalIn) void {
            switch (queued) {
                .adopt => |a| {
                    var peer = a.peer;
                    peer.deinit();
                },
                .answer => |a| releaseSignalPayload(self, a.slot),
                .candidate => |c| releaseSignalPayload(self, c.slot),
            }
        }

        pub fn releaseSignalPayload(self: *Self, slot: u8) void {
            self.signal_mutex.lock();
            defer self.signal_mutex.unlock();
            self.signal_payloads.release(slot);
        }

        pub fn reserveFdLocked(self: *Self) !Fd {
            self.signal_mutex.lock();
            defer self.signal_mutex.unlock();
            const fd = self.next_fd;
            if (fd == std.math.maxInt(Fd)) return error.OutOfFds;
            self.next_fd += 1;
            return fd;
        }

        pub fn reserveSignalPayload(self: *Self) !u8 {
            self.signal_mutex.lock();
            defer self.signal_mutex.unlock();
            if (self.signal_in.items.len + self.signal_reservations >= max_signal_in) return error.WouldBlock;
            const slot = self.signal_payloads.acquire() orelse return error.WouldBlock;
            self.signal_reservations += 1;
            return slot;
        }

        pub fn publishSignalPayload(self: *Self, item: SignalIn) error{WakeNudgeFailed}!void {
            self.signal_mutex.lock();
            defer self.signal_mutex.unlock();
            std.debug.assert(self.signal_reservations > 0);
            std.debug.assert(self.signal_in.items.len < max_signal_in);
            self.signal_reservations -= 1;
            _ = self.signal_wake.nudge() catch |err| {
                const slot = switch (item) {
                    .answer => |value| value.slot,
                    .candidate => |value| value.slot,
                    .adopt => unreachable,
                };
                self.signal_payloads.release(slot);
                self.signal_wake_failure.record(err);
                return err;
            };
            self.signal_in.appendAssumeCapacity(item);
        }

        /// Start an offerer bring-up: create the peer, produce its offer, and hand
        /// it to the signaling authority under the reserved fd. The connect
        /// completion fires when the channel opens; the answer and far candidates
        /// arrive through `provideAnswer` / `provideRemoteCandidate`.
        pub fn startDial(self: *Self, user_data: u64, target: ConnectTarget) !Fd {
            const fd = try reserveFdLocked(
                self,
            );
            var peer = self.resident.newPeer(true) catch return error.ConnectFailed;
            errdefer peer.deinit();
            // The dialed designator is the identity this channel's signaling is
            // scoped to (ADR-0105), which is what the bridge reads back through
            // `verifiedChannelKey` and asserts to the engine.
            peer.authorizeRemote(crypto.PeerKey.fromDesignator(target.designator) orelse
                return error.ConnectFailed);
            var sdp_buf: [signaling_frame_bytes]u8 = undefined;
            var sdp_len: usize = 0;
            const sdp = peer.createOffer(&sdp_buf, &sdp_len) catch return error.ConnectFailed;
            const designator = try self.allocator.dupe(u8, target.designator);
            errdefer self.allocator.free(designator);
            try self.pending_dials.put(fd, .{ .user_data = user_data, .peer = peer, .designator = designator });
            errdefer std.debug.assert(self.pending_dials.remove(fd));
            try self.by_id.put(@backingInt(peer.id()), fd);
            errdefer std.debug.assert(self.by_id.remove(@backingInt(peer.id())));
            self.signaling.sendOffer(self.signaling.ctx, fd, designator, sdp) catch
                return error.ConnectFailed;
            return fd;
        }

        /// Adopt an answerer peer a signaling owner brought up against an inbound
        /// offer. Thread-safe. Returns the exchange fd: route the offerer's later
        /// candidates to it with `provideRemoteCandidate`, and expect the
        /// backend's own `sendCandidate` calls under it. Ownership of `peer`
        /// transfers to the backend on entry, including failure: overload or fd
        /// exhaustion closes it here rather than returning a half-owned sidecar
        /// peer to the signaling layer.
        pub fn adoptAnswerer(self: *Self, peer: Peer) !Fd {
            var owned = peer;
            self.signal_wake_failure.check() catch |err| {
                owned.deinit();
                return err;
            };
            self.signal_mutex.lock();
            const fd = self.next_fd;
            if (fd == std.math.maxInt(Fd)) {
                self.signal_mutex.unlock();
                owned.deinit();
                return error.OutOfFds;
            }
            if (self.signal_in.items.len + self.signal_reservations >= max_signal_in) {
                self.signal_mutex.unlock();
                owned.deinit();
                return error.WouldBlock;
            }
            self.next_fd += 1;
            _ = self.signal_wake.nudge() catch |err| {
                self.signal_wake_failure.record(err);
                self.signal_mutex.unlock();
                owned.deinit();
                return err;
            };
            self.signal_in.appendAssumeCapacity(.{ .adopt = .{ .fd = fd, .peer = owned } });
            self.signal_mutex.unlock();
            return fd;
        }

        /// Deliver the far answerer's SDP for the exchange `fd` names. Thread-safe.
        pub fn provideAnswer(self: *Self, fd: Fd, sdp: []const u8) !void {
            try self.signal_wake_failure.check();
            if (sdp.len > signaling_frame_bytes) return error.SignalTooLarge;
            const slot = try reserveSignalPayload(
                self,
            );
            @memcpy(self.signal_payloads.bytes(slot, sdp.len), sdp);
            try publishSignalPayload(self, .{ .answer = .{ .fd = fd, .slot = slot, .len = @intCast(sdp.len) } });
        }

        /// Deliver one far ICE candidate for the exchange `fd` names. Thread-safe.
        pub fn provideRemoteCandidate(self: *Self, fd: Fd, ice: []const u8) !void {
            try self.signal_wake_failure.check();
            if (ice.len > signaling_frame_bytes) return error.SignalTooLarge;
            const slot = try reserveSignalPayload(
                self,
            );
            @memcpy(self.signal_payloads.bytes(slot, ice.len), ice);
            try publishSignalPayload(self, .{ .candidate = .{ .fd = fd, .slot = slot, .len = @intCast(ice.len) } });
        }

        /// Wake a parked `poll` so an owner-thread stop flag can be observed without
        /// timeout polling. Carries no authority and records no work; the next
        /// harvest drains the nudge and then finds the normal state the caller
        /// already changed.
        pub fn wake(self: *Self) net.wake_channel.Failure!void {
            try self.signal_wake_failure.check();
            _ = self.signal_wake.nudge() catch |err| {
                self.signal_wake_failure.record(err);
                return err;
            };
        }

        pub fn submitAccept(self: *Self, user_data: u64, listen: Fd) !void {
            if (listen != Self.listen_fd) return error.InvalidListenFd;
            if (self.accept_ud != null) return error.AlreadyAccepting;
            try self.ready.ensureUnusedCapacity(self.allocator, 1);
            self.accept_ud = user_data;
            takeAccept(
                self,
            );
        }

        /// Requires one unused ready-queue seat when an accept is stashed.
        pub fn takeAccept(self: *Self) void {
            const ud = self.accept_ud orelse return;
            if (self.accept_stash.items.len == 0) return;
            const outcome = self.accept_stash.orderedRemove(0);
            switch (outcome) {
                .connected => |held| {
                    self.conns.put(held.fd, .{ .peer = held.peer, .pending = .{ .writable_hint = true } }) catch |err| {
                        var peer = held.peer;
                        std.debug.assert(self.by_id.remove(@backingInt(peer.id())));
                        peer.deinit();
                        self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1, .failure = err });
                        self.accept_ud = null;
                        return;
                    };
                    self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = held.fd });
                },
                .failed => |err| self.ready.appendAssumeCapacity(.{
                    .user_data = ud,
                    .result = -1,
                    .failure = err,
                }),
            }
            self.accept_ud = null;
        }

        pub fn pumpLocalCandidates(self: *Self, fd: Fd, peer: *Peer) !void {
            // One transient loop-stack buffer per pump invocation, never per
            // connection. This is the same bound admission promises to carry.
            var cand_buf: [signaling_frame_bytes]u8 = undefined;
            var cand_len: usize = 0;
            while (true) {
                const cand = try peer.nextLocalCandidate(&cand_buf, &cand_len);
                const ice = cand orelse return;
                try self.signaling.sendCandidate(self.signaling.ctx, fd, ice);
            }
        }

        /// Requires one unused ready-queue seat. The row is removed before the
        /// completion is published, so callers reserve that seat first.
        pub fn failDial(self: *Self, fd: Fd, cause: anyerror) void {
            const kv = self.pending_dials.fetchRemove(fd) orelse return;
            var row = kv.value;
            std.debug.assert(self.by_id.remove(@backingInt(row.peer.id())));
            row.peer.deinit();
            self.allocator.free(row.designator);
            self.ready.appendAssumeCapacity(.{ .user_data = row.user_data, .result = -1, .failure = cause });
        }

        /// Publish an inbound exchange failure now or retain it for the next
        /// accept. The stash is pre-reserved: saturation is an explicit backend
        /// overload, never permission to discard an exchange.
        pub fn queueAcceptFailure(self: *Self, cause: anyerror) !void {
            if (self.accept_ud) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1, .failure = cause });
                self.accept_ud = null;
                return;
            }
            if (self.accept_stash.items.len >= max_accept_stash) return error.AcceptBacklogFull;
            self.accept_stash.appendAssumeCapacity(.{ .failed = cause });
        }

        /// Remove and close an answerer whose bring-up failed, then preserve that
        /// exact cause for the accept owner.
        pub fn failAdopt(self: *Self, fd: Fd, cause: anyerror) !void {
            const kv = self.adopting.fetchRemove(fd) orelse return;
            var peer = kv.value.peer;
            std.debug.assert(self.by_id.remove(@backingInt(peer.id())));
            peer.deinit();
            try queueAcceptFailure(self, cause);
        }

        /// Mark an open channel terminal and wake every operation already parked
        /// on it. Future submissions observe the same originating cause.
        pub fn openAdopted(self: *Self, fd: Fd) !void {
            const kv = self.adopting.fetchRemove(fd) orelse return;
            if (self.accept_stash.items.len >= max_accept_stash) {
                var peer = kv.value.peer;
                std.debug.assert(self.by_id.remove(@backingInt(peer.id())));
                peer.deinit();
                return error.AcceptBacklogFull;
            }
            self.accept_stash.appendAssumeCapacity(.{ .connected = .{ .fd = fd, .peer = kv.value.peer } });
            takeAccept(
                self,
            );
        }

        /// Apply the thread-safe queue on the loop thread: register adopted
        /// answerers, apply answers, apply candidates. Registration re-checks the
        /// open state because the open edge may have been drained before the row
        /// was visible (`checkOpen` is level, the event is edge).
        pub fn drainSignalIn(self: *Self) !void {
            if (self.signal_work.items.len == 0) {
                self.signal_mutex.lock();
                defer self.signal_mutex.unlock();
                std.mem.swap(std.ArrayList(SignalIn), &self.signal_work, &self.signal_in);
            }
            // A queued answer or adoption can complete one Loop operation. Reserve
            // publication before consuming or freeing any queue row; on OOM the
            // work list remains intact for a caller that retries the backend.
            try self.ready.ensureUnusedCapacity(self.allocator, self.signal_work.items.len * 2);
            var consumed: usize = 0;
            defer {
                self.signal_work.items.len = retainUnvisited(
                    SignalIn,
                    self.signal_work.items,
                    consumed,
                );
            }
            while (consumed < self.signal_work.items.len) {
                const item = self.signal_work.items[consumed];
                consumed += 1;
                switch (item) {
                    .adopt => |a| {
                        var peer = a.peer;
                        self.by_id.put(@backingInt(peer.id()), a.fd) catch {
                            peer.deinit();
                            try queueAcceptFailure(self, error.OutOfMemory);
                            continue;
                        };
                        self.adopting.put(a.fd, .{ .peer = peer }) catch {
                            std.debug.assert(self.by_id.remove(@backingInt(peer.id())));
                            peer.deinit();
                            try queueAcceptFailure(self, error.OutOfMemory);
                            continue;
                        };
                        const row = self.adopting.getPtr(a.fd).?;
                        pumpLocalCandidates(self, a.fd, &row.peer) catch |err| {
                            try failAdopt(self, a.fd, err);
                            continue;
                        };
                        if (row.peer.checkOpen()) |_| {
                            try openAdopted(self, a.fd);
                        } else |err| switch (err) {
                            error.WouldBlock => {},
                            error.Closed => try failAdopt(self, a.fd, error.WebRtcChannelClosed),
                            error.Failed => try failAdopt(self, a.fd, error.WebRtcChannelFailed),
                        }
                    },
                    .answer => |a| {
                        defer releaseSignalPayload(self, a.slot);
                        const sdp = self.signal_payloads.bytes(a.slot, a.len);
                        const row = self.pending_dials.getPtr(a.fd) orelse continue;
                        row.peer.setRemoteAnswer(sdp) catch |err| {
                            failDial(self, a.fd, err);
                            continue;
                        };
                        // The open edge may already have fired while the answer sat
                        // queued; re-check the level.
                        if (row.peer.checkOpen()) |_| {
                            finishDial(self, a.fd);
                        } else |err| switch (err) {
                            error.WouldBlock => {},
                            error.Closed => failDial(self, a.fd, error.WebRtcChannelClosed),
                            error.Failed => failDial(self, a.fd, error.WebRtcChannelFailed),
                        }
                    },
                    .candidate => |c| {
                        defer releaseSignalPayload(self, c.slot);
                        const ice = self.signal_payloads.bytes(c.slot, c.len);
                        if (self.pending_dials.getPtr(c.fd)) |row| {
                            row.peer.addRemoteCandidate(ice) catch |err| {
                                // A candidate refusal while the exchange is still
                                // negotiating is terminal: no later readiness edge
                                // can complete this dial honestly.
                                failDial(self, c.fd, err);
                            };
                        } else if (self.adopting.getPtr(c.fd)) |row| {
                            row.peer.addRemoteCandidate(ice) catch |err| {
                                try failAdopt(self, c.fd, err);
                            };
                        } else if (self.conns.getPtr(c.fd)) |entry| {
                            entry.peer.addRemoteCandidate(ice) catch |err| Connections.failOpenConnection(self, entry, err);
                        }
                    },
                }
            }
        }

        /// Move an opened dial into the connection table and complete the connect.
        /// Requires one unused ready-queue seat. The row is removed before the
        /// completion is published, so callers reserve that seat first.
        pub fn finishDial(self: *Self, fd: Fd) void {
            const kv = self.pending_dials.fetchRemove(fd) orelse return;
            var row = kv.value;
            self.allocator.free(row.designator);
            self.conns.put(fd, .{ .peer = row.peer, .pending = .{ .writable_hint = true } }) catch {
                std.debug.assert(self.by_id.remove(@backingInt(row.peer.id())));
                row.peer.deinit();
                self.ready.appendAssumeCapacity(.{ .user_data = row.user_data, .result = -1, .failure = error.OutOfMemory });
                return;
            };
            self.ready.appendAssumeCapacity(.{ .user_data = row.user_data, .result = 0 });
        }
    };
}
