//! Readiness to completion for the kqueue backend: what each registered
//! descriptor waits to do, and the one syscall a readiness event earns.
//!
//! kqueue reports that a descriptor is ready, not that a transfer finished,
//! so `complete` performs the `accept`, `recv`, `send`, or connect check the
//! pending operation names and writes the completion it produced. A spurious
//! or interrupted edge re-arms instead, because every submitted operation
//! must still complete exactly once. `kqueue.zig` owns registration and the
//! wait.

const std = @import("std");
const builtin = @import("builtin");

const completion = @import("loop.zig");
const socket_tcp = @import("socket_tcp.zig");

comptime {
    if (!builtin.os.tag.isDarwin()) @compileError("the kqueue completion backend is for Darwin");
}

const c = std.c;
const tcp_os = socket_tcp.Os.darwin;

// close(2) is not re-exported as public from std.c; declare it.
pub extern "c" fn close(fd: c_int) c_int;

const EV_ERROR: u16 = 0x4000;

pub const Pending = @import("readiness_pending.zig").Pending;

/// Complete `p`'s operation for readiness event `ev` on `fd`, appending at
/// most one completion to `out[produced.*..]`.
pub fn complete(
    backend: anytype,
    fd: c.fd_t,
    p: *Pending,
    ev: c.Kevent,
    out: []completion.Completion,
    produced: *usize,
) void {
    if (ev.filter == c.EVFILT.READ) {
        switch (p.read) {
            .idle => return,
            .poll => |ud| {
                p.read = .idle;
                out[produced.*] = .{ .user_data = ud, .result = 0 };
                produced.* += 1;
            },
            .recv => |ud| {
                var comp: completion.Completion = .{ .user_data = ud, .result = -1 };
                if (ev.flags & EV_ERROR != 0) {
                    comp.failure = completion.failureFromErrno(@fromBackingInt(@intCast(@as(c_int, @intCast(ev.data)))));
                } else if (backend.buffer_pool.acquire()) |idx| {
                    const buf = backend.buffer_pool.buffer(idx);
                    const r = c.recv(fd, buf.ptr, buf.len, 0);
                    if (r < 0) switch (std.posix.errno(r)) {
                        // Readiness is a hint, not a promise, and a
                        // signal can land between the wakeup and the
                        // syscall. Neither is a connection failure, but
                        // both return -1, and the loop reads a negative
                        // result as fatal. Re-arm and produce nothing:
                        // the operation is still outstanding, so the
                        // contract that every submitted op eventually
                        // yields a completion still holds.
                        .AGAIN, .INTR => {
                            backend.buffer_pool.release(idx);
                            backend.register(fd, c.EVFILT.READ) catch {
                                // The re-arm is the only way this op
                                // can ever complete, so a failure here
                                // does have to end the connection.
                                p.read = .idle;
                                comp.failure = error.KeventFailed;
                                out[produced.*] = comp;
                                produced.* += 1;
                            };
                            return;
                        },
                        else => comp.failure = completion.failureFromErrno(std.posix.errno(r)),
                    };
                    comp.result = @intCast(r);
                    if (r > 0) {
                        comp.borrowed = .recv(buf[0..@intCast(r)], idx);
                    } else {
                        // EOF or error: nothing for the loop to consume,
                        // so the buffer goes straight back to the pool.
                        backend.buffer_pool.release(idx);
                    }
                } else {
                    // Pool exhausted: surface starvation. The one-shot
                    // interest is spent; the loop's re-arm registers a
                    // fresh one once a buffer recycles.
                    comp.recv_no_buffer = true;
                }
                p.read = .idle;
                out[produced.*] = comp;
                produced.* += 1;
            },
            .accept => |ud| {
                var comp: completion.Completion = .{ .user_data = ud, .result = -1 };
                if (ev.flags & EV_ERROR != 0) {
                    comp.failure = completion.failureFromErrno(@fromBackingInt(@intCast(@as(c_int, @intCast(ev.data)))));
                } else {
                    const accepted = accept(fd, null, null);
                    if (accepted < 0) switch (std.posix.errno(accepted)) {
                        // Readiness can be spent by another kernel event,
                        // and a signal can interrupt before accept makes
                        // progress. Preserve the outstanding operation;
                        // only a failed re-arm is terminal.
                        .AGAIN, .INTR => {
                            backend.register(fd, c.EVFILT.READ) catch {
                                p.read = .idle;
                                comp.failure = error.KeventFailed;
                                out[produced.*] = comp;
                                produced.* += 1;
                            };
                            return;
                        },
                        else => comp.failure = completion.failureFromErrno(std.posix.errno(accepted)),
                    };
                    // Darwin does not inherit nonblocking across
                    // accept(2), and a blocking send at write-readiness
                    // would park the whole loop (ADR-0017). The accepted
                    // fd also needs SO_NOSIGPIPE before any send, so a
                    // torn-down peer becomes a completion error rather
                    // than a process signal, and close-on-exec so a child
                    // the embedder spawns never inherits it. If any option
                    // cannot be set, refuse the connection; the loop's
                    // re-arm recovers.
                    if (accepted >= 0 and (!socket_tcp.setNonblocking(accepted) or !socket_tcp.setNoSigpipe(accepted) or !socket_tcp.setNodelay(tcp_os, accepted) or !socket_tcp.setCloseOnExec(accepted))) {
                        _ = close(accepted);
                        comp.result = -1;
                        comp.failure = error.SocketConfigurationFailed;
                    } else {
                        comp.result = accepted;
                    }
                }
                p.read = .idle;
                out[produced.*] = comp;
                produced.* += 1;
            },
        }
    } else if (ev.filter == c.EVFILT.WRITE) {
        switch (p.write) {
            .idle => return,
            .poll => |ud| {
                p.write = .idle;
                out[produced.*] = .{ .user_data = ud, .result = 0 };
                produced.* += 1;
            },
            .connect => |ud| {
                const failure: ?anyerror = if (ev.flags & EV_ERROR != 0)
                    completion.failureFromErrno(@fromBackingInt(@intCast(@as(c_int, @intCast(ev.data)))))
                else
                    connectFailure(fd);
                p.write = .idle;
                out[produced.*] = .{
                    .user_data = ud,
                    .result = if (failure == null) 0 else -1,
                    .failure = failure,
                };
                produced.* += 1;
            },
            .send => |s| {
                if (ev.flags & EV_ERROR == 0) {
                    const sent = c.send(fd, s.bytes.ptr, s.bytes.len, 0);
                    if (sent < 0) switch (std.posix.errno(sent)) {
                        // kqueue reports readiness, not completion.
                        // A stale edge can find the socket not writable
                        // anymore, and a signal can interrupt before
                        // progress. Keep the op outstanding and wait
                        // for the next write edge.
                        .AGAIN, .INTR => {
                            backend.register(fd, c.EVFILT.WRITE) catch {
                                p.write = .idle;
                                out[produced.*] = .{ .user_data = s.ud, .result = -1, .failure = error.KeventFailed };
                                produced.* += 1;
                            };
                            return;
                        },
                        else => {
                            p.write = .idle;
                            out[produced.*] = .{
                                .user_data = s.ud,
                                .result = -1,
                                .failure = completion.failureFromErrno(std.posix.errno(sent)),
                            };
                            produced.* += 1;
                            return;
                        },
                    };
                    p.write = .idle;
                    out[produced.*] = .{ .user_data = s.ud, .result = @intCast(sent) };
                    produced.* += 1;
                    return;
                }
                p.write = .idle;
                out[produced.*] = .{
                    .user_data = s.ud,
                    .result = -1,
                    .failure = completion.failureFromErrno(@fromBackingInt(@intCast(@as(c_int, @intCast(ev.data))))),
                };
                produced.* += 1;
            },
        }
    }
}

// accept(2) is `pub extern` in std.c, but reference it through a thin alias so the
// call sites read the same as the other socket calls.
fn accept(sockfd: c.fd_t, addr: ?*c.sockaddr, addrlen: ?*c.socklen_t) i32 {
    return c.accept(sockfd, addr, addrlen);
}

fn connectFailure(fd: c.fd_t) ?anyerror {
    var so_error: c_int = 0;
    var len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, &so_error, &len) < 0)
        return error.GetsockoptFailed;
    return if (so_error == 0) null else completion.failureFromErrno(@fromBackingInt(@intCast(so_error)));
}
