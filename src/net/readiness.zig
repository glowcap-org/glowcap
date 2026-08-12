//! One aggregate readiness descriptor for a poll-shaped host face
//! (ADR-0112): a kernel-held interest set over every descriptor the face
//! waits on, exposed as a single pollable fd. An embedder that owns its own
//! event loop parks on that one fd and calls the face's step verb when it
//! reads ready, instead of re-tracking every wire, resident, and mailbox
//! descriptor per language.
//!
//! The set is Linux `epoll` or Darwin `kqueue` — both kernel objects whose
//! own descriptor polls readable while any member is readable — and it
//! carries one `WakeChannel` of its own, so another thread can make a parked
//! owner return without touching any member. On a platform with neither
//! primitive `init` fails typed (`ReadinessUnavailable`); the face's
//! blocking verbs keep working without a set, because only the park-outside
//! contract needs one.
//!
//! Membership is readable-interest only and level-shaped. `add` is
//! idempotent and `remove` tolerates an fd that already left, because the
//! close path and the release path sweep the same wire.
//!
//! Platform-gated like `wake_channel.zig`: Linux by raw syscall, Darwin
//! through libc externs. Allowlisted for the platform-namespace ban in
//! `tools/check/arch_check.zig` beside `socket_tcp.zig`.

const std = @import("std");
const builtin = @import("builtin");

const wake_channel = @import("wake_channel.zig");

const linux = std.os.linux;
const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag.isDarwin();

// Darwin reaches kqueue through libc; Linux uses raw syscalls and never
// references these externs (the `wake_channel.zig` convention).
extern "c" fn kqueue() c_int;
extern "c" fn kevent(
    kq: c_int,
    changelist: ?[*]const DarwinKevent,
    nchanges: c_int,
    eventlist: ?[*]DarwinKevent,
    nevents: c_int,
    timeout: ?*const anyopaque,
) c_int;
extern "c" fn close(fd: c_int) c_int;

/// `struct kevent` as Darwin declares it; spelled here so the Linux build
/// never touches `std.c`'s Darwin-only namespace.
const DarwinKevent = extern struct {
    ident: usize,
    filter: i16,
    flags: u16,
    fflags: u32,
    data: isize,
    udata: usize,
};

/// `struct timespec` as Darwin `kevent` takes it. The Linux build never
/// passes one.
const DarwinTimespec = extern struct {
    tv_sec: isize,
    tv_nsec: isize,
};

const darwin_evfilt_read: i16 = -1;
const darwin_ev_add: u16 = 0x0001;
const darwin_ev_delete: u16 = 0x0002;

pub const Error = error{ReadinessUnavailable};

pub const ReadySet = struct {
    /// The pollable set descriptor an embedder parks on.
    fd: i32,
    /// The cross-thread wake, a member of the set from birth.
    wake: wake_channel.WakeChannel,

    pub fn init() Error!ReadySet {
        const set_fd: i32 = if (is_linux) blk: {
            const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) return Error.ReadinessUnavailable;
            break :blk @intCast(rc);
        } else if (is_darwin) blk: {
            const kq = kqueue();
            if (kq < 0) return Error.ReadinessUnavailable;
            break :blk kq;
        } else return Error.ReadinessUnavailable;
        errdefer closeFd(set_fd);
        const wake = wake_channel.WakeChannel.open() catch return Error.ReadinessUnavailable;
        errdefer wake.deinit();
        var set = ReadySet{ .fd = set_fd, .wake = wake };
        try set.add(wake.read);
        return set;
    }

    /// Close the set, on the owning thread, after every waking thread has
    /// stopped. Members are not closed; they belong to their owners.
    pub fn deinit(self: *ReadySet) void {
        closeFd(self.fd);
        self.wake.deinit();
        self.* = undefined;
    }

    /// The one descriptor an embedder polls readable.
    pub fn descriptor(self: *const ReadySet) i32 {
        return self.fd;
    }

    /// Register readable interest in `fd`. Idempotent: a member already in
    /// the set is left as it was.
    pub fn add(self: *ReadySet, fd: i32) Error!void {
        if (is_linux) {
            var ev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = fd } };
            const rc = linux.epoll_ctl(self.fd, linux.EPOLL.CTL_ADD, fd, &ev);
            switch (linux.errno(rc)) {
                .SUCCESS, .EXIST => {},
                else => return Error.ReadinessUnavailable,
            }
        } else if (is_darwin) {
            var change = DarwinKevent{
                .ident = @intCast(fd),
                .filter = darwin_evfilt_read,
                .flags = darwin_ev_add,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            if (kevent(self.fd, @ptrCast(&change), 1, null, 0, null) < 0) {
                return Error.ReadinessUnavailable;
            }
        } else return Error.ReadinessUnavailable;
    }

    /// Drop `fd` from the set. Tolerant of an fd that already left, because
    /// the close path and the release path sweep the same wire.
    pub fn remove(self: *ReadySet, fd: i32) void {
        if (is_linux) {
            var ev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = fd } };
            _ = linux.epoll_ctl(self.fd, linux.EPOLL.CTL_DEL, fd, &ev);
        } else if (is_darwin) {
            var change = DarwinKevent{
                .ident = @intCast(fd),
                .filter = darwin_evfilt_read,
                .flags = darwin_ev_delete,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            _ = kevent(self.fd, @ptrCast(&change), 1, null, 0, null);
        }
    }

    /// Make the set readable from any thread, so a parked owner returns and
    /// re-enters its step. Best-effort under the wake-channel invariant: a
    /// refused write means unread wake bytes already hold the set readable,
    /// so no wake is lost.
    pub fn postWake(self: *const ReadySet) void {
        self.wake.nudge();
    }

    /// The wake channel's read half, for a wait that polls it as its own row
    /// beside the set.
    pub fn wakeFd(self: *const ReadySet) i32 {
        return self.wake.read;
    }

    /// Consume pending wake posts, on the owning thread, at the top of every
    /// wait — a level-shaped wake left unread would pin the set readable
    /// forever. Darwin also requires draining queued kqueue notifications:
    /// polling the kqueue fd makes it readable, but the event stays queued
    /// until a `kevent` read consumes it.
    pub fn drainWake(self: *const ReadySet) void {
        self.wake.drain();
        self.drainQueuedEvents();
    }

    fn drainQueuedEvents(self: *const ReadySet) void {
        if (!is_darwin) return;
        var events: [32]DarwinKevent = undefined;
        var timeout = DarwinTimespec{ .tv_sec = 0, .tv_nsec = 0 };
        // One read consumes the queued wake notification. Do not loop: read
        // filters are level-triggered, so a genuinely readable member would
        // be returned forever until its owning transport services it.
        _ = kevent(
            self.fd,
            null,
            0,
            &events,
            @intCast(events.len),
            @ptrCast(&timeout),
        );
    }
};

fn closeFd(fd: i32) void {
    if (is_linux) {
        _ = linux.close(fd);
    } else {
        _ = close(fd);
    }
}
