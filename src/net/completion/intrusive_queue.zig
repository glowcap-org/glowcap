//! Allocation-free FIFO ownership for completion-adapter work queues.
//!
//! Queue links live on the connection that owns the deferred work. This makes
//! enqueue, dequeue, and arbitrary teardown removal constant-time without a
//! second allocation or a stale connection pointer. Connection id zero is the
//! empty sentinel; completion adapters already reserve it from their synthetic
//! handle namespaces.

const std = @import("std");

pub fn Links(comptime Id: type) type {
    return struct {
        previous: Id = 0,
        next: Id = 0,
    };
}

pub fn Queue(
    comptime Id: type,
    comptime Item: type,
    comptime linksOf: fn (*Item) *Links(Id),
) type {
    return struct {
        const Self = @This();

        head: Id = 0,
        tail: Id = 0,
        count: usize = 0,

        pub fn contains(self: *const Self, item: *Item) bool {
            const links = linksOf(item);
            return self.head == item.id or links.previous != 0 or links.next != 0;
        }

        pub fn push(self: *Self, items: anytype, item: *Item) void {
            std.debug.assert(item.id != 0);
            std.debug.assert(!self.contains(item));
            const links = linksOf(item);
            links.previous = self.tail;
            if (self.tail != 0) {
                const tail = items.get(self.tail) orelse unreachable;
                const tail_links = linksOf(tail);
                std.debug.assert(tail_links.next == 0);
                tail_links.next = item.id;
            } else {
                self.head = item.id;
            }
            self.tail = item.id;
            self.count += 1;
        }

        pub fn pop(self: *Self, items: anytype) ?*Item {
            if (self.head == 0) return null;
            const item = items.get(self.head) orelse unreachable;
            self.removeQueued(items, item);
            return item;
        }

        pub fn removeIfQueued(self: *Self, items: anytype, item: *Item) void {
            if (self.contains(item)) self.removeQueued(items, item);
        }

        pub fn removeQueued(self: *Self, items: anytype, item: *Item) void {
            std.debug.assert(self.contains(item));
            const links = linksOf(item);
            const previous = links.previous;
            const next = links.next;
            if (previous != 0) {
                const previous_item = items.get(previous) orelse unreachable;
                linksOf(previous_item).next = next;
            } else {
                std.debug.assert(self.head == item.id);
                self.head = next;
            }
            if (next != 0) {
                const next_item = items.get(next) orelse unreachable;
                linksOf(next_item).previous = previous;
            } else {
                std.debug.assert(self.tail == item.id);
                self.tail = previous;
            }
            links.* = .{};
            self.count -= 1;
        }
    };
}
