//! The off-turn settle mailbox (ADR-0102 stage 4): the one sanctioned way a
//! worker thread hands a resolver settle back to the thread that owns its
//! Host. A worker calls `post` from any thread; the entry is recorded into a
//! fixed slot under a spin lock and the owning thread is woken through the
//! mailbox's socketpair, whose nudge follows the ADR-0089 invariant — a
//! `WouldBlock` on the wake write means unread bytes already make the read
//! half readable, so no wake is ever lost. The owning thread drains the wake
//! and applies every recorded settle through the ordinary top-level resolver
//! verbs, so nothing about the Host's one-thread contract changes: the
//! mailbox carries the *call*, never the authority.
//!
//! `driver.PollHost` polls the mailbox's wake fd beside its wires; the
//! completion loop arms an ordinary recv on it (a socketpair is a socket,
//! which is why it is not a pipe). Both apply on their own thread.
//!
//! Bounds, named: the slots are allocated once at init — a post allocates
//! nothing — and each entry's payload clones into its slot's fixed storage,
//! so a full mailbox refuses `MailboxFull` and an oversized value refuses
//! `ValueTooLarge`, loudly, instead of blocking the loop or growing without
//! bound. Off-thread settles carry plain data only (`NotPlainData` otherwise):
//! a capability never crosses threads, per the decision.

const std = @import("std");
const model = @import("model");
const net = @import("net");
const driver_core = @import("driver_core");

pub const Resolution = union(enum) {
    fulfilled: model.Argument,
    broken: []const u8,
};

pub const PostError = error{
    /// Every slot holds an unapplied settle; the owning thread has not caught
    /// up. Retry after it drains, or treat as backpressure.
    MailboxFull,
    /// The cloned payload does not fit the slot's fixed storage
    /// (`slot_payload_bytes`). Settle with a smaller value, or move the bulk
    /// through a channel the application owns.
    ValueTooLarge,
    /// The value names a capability (a reference or handoff). Authority never
    /// crosses threads; an answer that carries it settles on the owning
    /// thread, or forwards to a send.
    NotPlainData,
};

/// Fixed per-entry payload storage. A settle is a completion notice, not a
/// bulk channel; a worker with more bytes than this hands them over through
/// its own storage and settles with the key.
pub const slot_payload_bytes = 512;

/// Default slot count for `init`; an application expecting more concurrent
/// unapplied settles sizes it explicitly.
pub const default_slots = 16;

const Slot = struct {
    resolver_id: u64,
    resolution: Resolution,
    storage: [slot_payload_bytes]u8 align(16),
};

pub const SettleMailbox = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    lock: net.sync.SpinLock = .{},
    /// Ring state: `head` is the next entry to apply, `count` the recorded
    /// entries. Posts append at `head + count`; apply consumes at `head`.
    head: usize = 0,
    count: usize = 0,
    channel: net.wake_channel.WakeChannel,

    /// Allocate the mailbox on the heap — workers hold the pointer across
    /// threads, so it needs one stable address — with `slot_count` fixed
    /// slots and a `net.wake_channel.WakeChannel` as the wake.
    pub fn init(allocator: std.mem.Allocator, slot_count: usize) !*SettleMailbox {
        const channel = try net.wake_channel.WakeChannel.open();
        errdefer channel.deinit();
        const slots = try allocator.alloc(Slot, slot_count);
        errdefer allocator.free(slots);
        const self = try allocator.create(SettleMailbox);
        self.* = .{
            .allocator = allocator,
            .slots = slots,
            .channel = channel,
        };
        return self;
    }

    /// Tear down on the owning thread, after every worker holding this
    /// mailbox has stopped posting.
    pub fn deinit(self: *SettleMailbox) void {
        self.channel.deinit();
        const allocator = self.allocator;
        allocator.free(self.slots);
        allocator.destroy(self);
    }

    /// The fd the owning thread waits on: readable while posted settles are
    /// pending. Poll it beside the wires, or arm a recv on it in a
    /// completion loop — it is a socket on purpose.
    pub fn wakeFd(self: *const SettleMailbox) i32 {
        return self.channel.read;
    }

    /// Wake the owner without recording a settle — the stopper's share of
    /// the channel: a thread that flipped a done flag wakes the parked wait
    /// through the same sanctioned entry the settles use.
    pub fn wake(self: *SettleMailbox) void {
        self.channel.nudge();
    }

    /// Record a settle from any thread and wake the owner. The resolution is
    /// borrowed for the call and cloned into the slot; refusals are loud
    /// (`PostError`) and consume nothing.
    pub fn post(self: *SettleMailbox, resolver_id: u64, resolution: Resolution) PostError!void {
        if (resolution == .fulfilled and !argumentIsPlain(&resolution.fulfilled, 0)) {
            return PostError.NotPlainData;
        }
        {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.count == self.slots.len) return PostError.MailboxFull;
            const slot = &self.slots[(self.head + self.count) % self.slots.len];
            var fba = std.heap.FixedBufferAllocator.init(&slot.storage);
            slot.resolver_id = resolver_id;
            slot.resolution = switch (resolution) {
                .fulfilled => |value| .{
                    .fulfilled = model.cloneArgument(fba.allocator(), value) catch
                        return PostError.ValueTooLarge,
                },
                .broken => |reason| .{
                    .broken = fba.allocator().dupe(u8, reason) catch
                        return PostError.ValueTooLarge,
                },
            };
            self.count += 1;
        }
        self.channel.nudge();
    }

    /// Drain the wake channel, on the owning thread, before applying: a post
    /// racing the apply leaves its byte unread, so the next wait wakes again
    /// rather than losing the entry.
    pub fn drainWake(self: *SettleMailbox) void {
        self.channel.drain();
    }

    /// Apply every recorded settle through `host`'s top-level resolver verbs,
    /// on the thread that owns `host`. A refused settle (a worker that posted
    /// twice for one resolver, allocator pressure mid-settle) is dropped
    /// after the attempt — the mailbox carries best-effort completions, and a
    /// worker that needs the outcome observes its own answer's settlement.
    /// The lock brackets only the ring bookkeeping; the resolver verb runs
    /// unlocked while the entry's slot stays reserved, so a concurrent post
    /// can fill every other slot but never the one being applied.
    pub fn apply(self: *SettleMailbox, host: *driver_core.Host) void {
        while (true) {
            self.lock.lock();
            if (self.count == 0) {
                self.lock.unlock();
                return;
            }
            const slot = &self.slots[self.head % self.slots.len];
            self.lock.unlock();

            switch (slot.resolution) {
                .fulfilled => |value| host.resolverFulfill(slot.resolver_id, value) catch {},
                .broken => |reason| host.resolverBreak(slot.resolver_id, reason) catch {},
            }

            self.lock.lock();
            self.head +%= 1;
            self.count -= 1;
            self.lock.unlock();
        }
    }
};

/// Whether a value is plain data — no reference or handoff arm anywhere in
/// the tree. The mailbox's admission rule: authority never crosses threads.
fn argumentIsPlain(argument: *const model.Argument, depth: usize) bool {
    if (depth > model.max_value_depth) return false;
    return switch (argument.*) {
        .reference, .handoff => false,
        .list, .set => |items| for (items) |*item| {
            if (!argumentIsPlain(item, depth + 1)) break false;
        } else true,
        .tagged => |tagged| for (tagged.value) |*item| {
            if (!argumentIsPlain(item, depth + 1)) break false;
        } else true,
        .@"struct" => |entries| for (entries) |*entry| {
            if (!argumentIsPlain(&entry.value, depth + 1)) break false;
        } else true,
        else => true,
    };
}
