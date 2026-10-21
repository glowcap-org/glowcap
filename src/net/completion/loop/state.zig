//! Completion-loop operation identity and inline connection state.
//!
//! The root Loop embeds this state directly. This module adds no owner object.
//! It names the exact slot representation and the compact completion ticket
//! shared by the loop's internal transaction owners.

const std = @import("std");
const engine = @import("engine");
const frame_stream = @import("../../frame_stream.zig");
const contract = @import("../contract.zig");

const CloseReason = contract.CloseReason;

/// Which kind of submitted operation a completion belongs to. Packed into the low
/// bits of `user_data`. The rest is the connection slot index. `wake` and
/// `wake_cancel` have no connection: the out-of-band wake recv (ADR-0014) and
/// its shutdown cancellation always carry slot 0 and are dispatched before
/// any slot lookup.
pub const Op = enum(u3) { accept, connect, recv, send, close, wake, wake_cancel };

pub fn userData(op: Op, slot: usize) u64 {
    return (@as(u64, slot) << 3) | @backingInt(op);
}
pub fn opOf(ud: u64) Op {
    return @fromBackingInt(@intCast(@as(u3, @truncate(ud))));
}
pub fn slotOf(ud: u64) usize {
    return @intCast(ud >> 3);
}

pub fn pendingFront(c: anytype) usize {
    return c.front.items.len - c.front_off;
}

pub fn pendingOut(c: anytype) usize {
    return pendingFront(c) + c.back.items.len + c.peer.encodedOutboundBytes();
}

/// How long the loop may sleep while it still owes the backend a close it
/// could not admit. Short, because those closes are what retire the ops some
/// connections are waiting on, and the failure that caused them is transient.
pub const close_retry_ms: i32 = 50;

/// Outbound queue capacity a drained `front` retains (ADR-0017). The iroh
/// sidecar keeps the same bound for its own per-connection buffer, in Rust
/// (`NB_STEADY_BYTES`), so the per-connection footprint cannot split between
/// them. `source-check` holds the two numbers together.
pub const steady_outbound_bytes: usize = frame_stream.steady_outbound_bytes;

/// Per-connection slot bookkeeping ceiling (ADR-0009): the most a `Conn` may
/// cost *beyond* the `engine.Peer` it embeds, the slot state, the outbound
/// queue's two `ArrayList` headers, the spill header, the intrusive link, and
/// the in-flight/context words. `Peer` is gated by its own `@sizeOf(Peer)`
/// ceiling. This guards the wrapper the loop allocates `max_conns` of, which
/// nothing capped before. Isolating the overhead keeps a `Peer` change within
/// its own ceiling from tripping this, while a new `Conn` field always does.
/// Move it only by weighing the bytes, never to route around the check.
///
/// The assertion below is an equality, not a ceiling, so the constant is the
/// measurement: any change to `Conn` fails the build and moves this number
/// with it. A ceiling would let the overhead grow up to it while this comment
/// claimed a smaller figure. It holds across backends because `Backend.Fd` is
/// `i32` for TCP platform backends and iroh alike, so `Conn` carries no
/// backend-dependent width.
///
/// It exists to stop a field being *added* unnoticed, not to invite shaving
/// bytes off it. At 500k connections the whole slot overhead is a small share
/// of the steady outbound queues the same connections carry
/// (`steady_outbound_bytes` each), and the two list headers and the spill
/// header are most of it, so the whole available saving is noise against
/// the queues.
///
/// Like every footprint budget, this is the runtime-safety
/// measurement: each of the two outbound `std.ArrayList` headers carries std's
/// one-byte `pointer_stability` lock, padded to a word, in Debug and
/// ReleaseSafe. ReleaseFast and ReleaseSmall make that lock zero-sized, and
/// nothing else in `Conn` moves with the mode, so the assertion below takes
/// those two words back in a fast build rather than holding a second number.
pub const conn_slot_overhead_bytes: usize = 144;

/// How recv-completion consumption ended, decided by `onRecvConsume` while
/// the completion's pool buffer is still borrowed and acted on by
/// `onRecvFinish` after the buffer has been recycled, so every exit path
/// recycles exactly once.
pub const RecvVerdict = enum {
    /// Bytes consumed. Run events, outbound drive, and the next read arm.
    proceed,
    /// Close this connection after flushing what the engine projected
    /// (typically an `op:abort`).
    fail,
    /// Close this connection without an engine projection (EOF, read error,
    /// or out of memory).
    close,
    /// Nothing further: the connection was already closing, or it parked
    /// buffer-starved.
    done,
};

pub fn Types(comptime Backend: type) type {
    return struct {
        pub const Fd = Backend.Fd;
        pub const Conn = struct {
            /// The slot lifecycle: `.free` slots sit on the free list, `.open`
            /// slots carry a live (or still-connecting) connection,
            /// `.draining` slots accept only send completions until their
            /// already-projected terminal bytes flush, and `.closing` slots
            /// have their close queued and wait for in-flight ops to retire
            /// before `teardown` reclaims them.
            state: enum { free, open, draining, closing } = .free,
            /// The read seat, exactly one recv is armed per open connection,
            /// or the seat is explicitly idle/parked: `.idle` between a recv
            /// completion and its verdict, `.armed` while a recv is submitted,
            /// `.parked` under ADR-0017 backpressure (outbound past the
            /// high-water mark. `onSend`'s drain resumes it), `.starved` when
            /// the shared pool was empty (ADR-0019. A recycle resumes it).
            read: enum { idle, armed, parked, starved } = .idle,
            /// Monotonic ms (since boot, not wall-clock) when this connection
            /// started waiting on the partner, or 0 when it is not waiting
            /// (or is a fan-in victim, which the reaper exempts).
            /// Only differences are meaningful.
            ///
            /// Which wait this is, and therefore which deadline bounds it,
            /// comes from the connection's state, not from a second meaning
            /// packed into this number. `waiting_is_drain` records which one
            /// the stamp was taken for, so a connection that was already
            /// waiting when its state changed starts the new clock instead of
            /// inheriting the old one's elapsed time. `.open` with a parked read status-allow: replacement state identity
            /// is a slow reader, bounded by `Options.park_kill_ms`. A
            /// `.draining` connection is waiting for its terminal bytes to be
            /// read, bounded by `Options.drain_kill_ms`. Condemnation
            /// restamps it, which is correct: the slow-reader question is moot
            /// once the session is already being torn down, and the drain
            /// bound is the shorter of the two.
            waiting_since_ms: i64 = 0,
            /// Whether `waiting_since_ms` was taken for the terminal-flush wait
            /// rather than the slow-reader park. Meaningless when unstamped.
            waiting_is_drain: bool = false,
            /// Set when `closeConn` could not queue a close and shut the fd
            /// down instead: the last retiring op releases the handle, because
            /// no close completion is coming to do it.
            owns_fd_close: bool = false,
            /// Whether this connection's queue is over the high-water mark.
            /// Edge-triggered so `over_mark_count` stays exact.
            over_mark: bool = false,
            /// Bumped every time this slot is reclaimed, so slot reuse is
            /// observable, the state alone cannot show it, because a
            /// replacement occupant is `.open` too. No production path compares
            /// it. It is what `test/net/fuzz_test.zig` checks slot
            /// identity against, and it costs nothing, because the four bytes
            /// land in alignment padding `Conn` already carries.
            generation: u32 = 0,
            /// True once the connection completed its connect or accept. False
            /// for a dialed connection that failed before opening. Reported to
            /// `Options.on_close` at teardown.
            opened: bool = false,
            /// Why this connection is closing. Set before `closeConn` for a
            /// loop-initiated reclaim so `on_close` can name it (ADR-0030).
            close_reason: CloseReason = .ordinary,
            fd: Fd = undefined,
            peer: engine.Peer = undefined,
            /// Bounded overflow for a frame that does not complete within one
            /// recv completion's borrowed pool buffer. Inactive (and
            /// allocation-free) while whole frames arrive per completion.
            spill: frame_stream.Spill = .{},
            /// The frozen half of the outbound queue. A submitted write borrows
            /// `front.items[front_off..]` until the backend reports it complete,
            /// so nothing may append to (or otherwise resize) `front` while
            /// `write_in_flight`, a realloc would free the storage the kernel
            /// is still reading. Bytes queued meanwhile land in `back`.
            front: std.ArrayList(u8) = .empty,
            front_off: usize = 0,
            /// The open half of the outbound queue: where `flushOutbound`
            /// appends while a write is in flight. When the in-flight write
            /// drains, the emptied front and this swap, and the queued bytes
            /// submit as the next write.
            back: std.ArrayList(u8) = .empty,
            write_in_flight: bool = false,
            /// Per-connection recv/send/close operations the backend has not yet status-allow: pending state or quoted runtime label
            /// reported complete. Teardown waits for this to reach zero, so the
            /// slot is never reused and `front` is never freed while a
            /// completion-based backend could still write into it. That prevents
            /// stale completions from landing on a reused slot and prevents the
            /// kernel from writing a pending send's bytes after they are freed.
            ops_in_flight: usize = 0,
            /// Per-connection application context (from `make_conn_ctx`), passed
            /// to the serve hook for every event and freed at teardown. Opaque to
            /// this layer. Typically this is the connection's `actors.Vat`.
            app_ctx: ?*anyopaque = null,
            /// Intrusive links for the one list this slot is on, holding slot
            /// indices, or `conns.len` as the end sentinel.
            ///
            /// Four lists share this pair: the ordinary and reserved free lists
            /// while `state ==.free`, buffer-starved while `read ==.starved`,
            /// and backpressure-parked while `read ==.parked`. A slot belongs
            /// to exactly one. A free slot's seat is `.idle`, because the slot
            /// reset leaves it there, and `.starved` and `.parked` are two
            /// values of one enum. Every departure unlinks before the state
            /// changes, so no successor rides from one list into another. This
            /// is the invariant the whole scheme rests on. The heads below and
            /// the link helpers point back here rather than restating it.
            ///
            /// Two `u32`s rather than one `usize`, which costs the same eight
            /// bytes and buys `O(1)` removal. Removing by value from a singly
            /// linked list walks it, and the list this matters for is the parked
            /// one: it is longest in exactly the regime it exists for, a fan-in
            /// throttle holding every connection behind one slow reader. Every
            /// `closeConn` walking it makes `closeAndDrain` quadratic, the
            /// shape `teardown` refuses two hundred lines below.
            /// `max_conns` is checked against `maxInt(u32)` at construction.
            next_link: u32 = 0,
            prev_link: u32 = 0,
        };

        comptime {
            const fast_mode_discount: usize = if (std.debug.runtime_safety) 0 else 2 * @sizeOf(usize);
            std.debug.assert(@sizeOf(Conn) - @sizeOf(engine.Peer) == conn_slot_overhead_bytes - fast_mode_discount);
            std.debug.assert(@alignOf(Conn) == @alignOf(engine.Peer));
        }
    };
}
