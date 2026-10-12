//! Fixed completion-backend contract shared by the loop and its adapters.
//!
//! This module owns namespace composition, operation results, and ready-queue
//! mechanics. The loop owns connection orchestration. Platform and transport
//! adapters own how operations reach this contract.
//!
//! ## Backend interface
//!
//! A backend is a struct providing the platform completion primitive. The loop
//! calls only these. Nothing in the loop issues a syscall directly:
//!
//!   * `pub const Fd = <platform socket handle type>;`
//!   * `pub fn init(allocator, queue_entries: u16, read_buffers: u16,
//!     read_buffer_bytes: u32) !Backend;`: the backend owns a shared pool of
//!     `read_buffers` buffers with `read_buffer_bytes` bytes each.
//!   * `pub fn deinit(self: *Backend) void;`
//!   * `pub const ListenTarget;`, the backend-owned listen target, the
//!     listening counterpart of `ConnectTarget`. A platform backend's is the
//!     port it binds on its construction-time interface; an adapter's wraps its
//!     platform's beside the adapter's own listener.
//!   * `pub fn loopListenTarget(port: u16) ListenTarget;`, the listener
//!     `completion.Loop`'s `listen` option opens: the platform listener on
//!     `port`, or a transport's own acceptor where it has no port.
//!   * `pub fn openListener(self: *Backend, target: ListenTarget) !Fd;`: bind
//!     and listen for TCP, or arm a userspace transport acceptor.
//!   * `pub fn listenerPending(self: *const Backend, fd: Fd) bool;`: whether the
//!     listener on `fd` still finishes a setup after `openListener` returned.
//!     A backend whose listeners are live at once answers false.
//!   * `pub const ConnectTarget;`, the backend-owned dial target. There is no
//!     shared union through which one backend could receive another's target.
//!   * `pub fn startDial(self: *Backend, user_data: u64,
//!     target: ConnectTarget) !Fd;`: own the whole start and report terminal
//!     success as result zero; the returned handle belongs to the loop slot
//!     before the completion arrives.
//!   * `pub const ListenerAddress;`
//!   * `pub fn listenerAddress(self: *Backend, fd: Fd) !ListenerAddress;`
//!   * `pub fn listenerPort(address: ListenerAddress) ?u16;`
//!   * `pub fn closeFd(self: *Backend, fd: Fd) void;`
//!   * `pub fn submitAccept(self: *Backend, user_data: u64,
//!     listen_fd: Fd) !void;`: success reports the accepted handle in
//!     `Completion.accepted_fd`, or in `result` for an ordinary non-negative OS
//!     handle; failure reports a negative result and no handle.
//!   * `pub fn submitRecv(self: *Backend, user_data: u64, fd: Fd) !void;`, the
//!     backend selects a shared-pool buffer and lends it through
//!     `Completion.borrowed`; pool pressure reports `recv_no_buffer` rather
//!     than a connection failure.
//!   * `pub fn submitSend(self: *Backend, user_data: u64, fd: Fd,
//!     bytes: []const u8) !void;`
//!   * `pub fn submitCancel(self: *Backend, cancel_user_data: u64,
//!     target_user_data: u64, fd: Fd) !void;`: cancel the exact submitted recv
//!     without closing its handle. The target and cancellation completions may
//!     arrive in either order.
//!   * `pub fn submitClose(self: *Backend, user_data: u64, fd: Fd) !void;`,
//!     cancel a pending accept and close its handle, or close a connection
//!     after the loop calls `shutdownFd`. A userspace backend whose shutdown is
//!     a no-op must synthesize completions for every pending recv and send. A
//!     negative close result means the handle remains owned and the loop calls
//!     `closeFd`.
//!   * `pub fn shutdownFd(self: *Backend, fd: Fd) void;`
//!   * `pub fn wireFraming(self: *Backend, fd: Fd)
//!     model.transport.WireFraming;`: whether recv completions are arbitrary
//!     byte-stream chunks or complete message packets for this connection.
//!   * `pub fn recycleBorrowed(self: *Backend, completion: Completion) void;`:
//!     release the exact receive buffer or cold-path failure record after the
//!     loop has consumed it.
//!   * `pub fn poll(self: *Backend, out: []Completion,
//!     timeout_ms: i32) !usize;`: flush submissions and wait; a timeout or
//!     explicit wake with no completions returns zero.
//!
//! A platform backend also provides one readiness verb for adapters that run
//! I/O on descriptors they do not own (`net/transport/external/completion.zig`).
//! The loop never calls it:
//!
//!   * `pub fn submitPoll(self: *Backend, user_data: u64, fd: Fd,
//!     interest: Interest) !void;`: complete once with a non-negative
//!     result when `fd` is readable or writable, or has failed or hung up,
//!     consuming nothing. It is one-shot, it
//!     occupies that direction of `fd` like a recv or send, `submitCancel`
//!     retires it, and it never closes `fd`.
//!
//! A `submit*` refusal must mint no completion for that `user_data`. The loop
//! counts an operation only after successful submission. Violating this rule
//! can retire an idle seat and free storage still borrowed by the backend.
//! Conversely, every admitted operation must eventually produce exactly one
//! completion, including operations pending when `submitClose` is accepted.
//!
//! The loop separately accepts a `DialResolver` that maps OCapN locator parts
//! to `Backend.ConnectTarget`. That grammar belongs to the netlayer, never the
//! platform backend. A readiness backend may implement the contract by recording
//! submissions and performing I/O from `poll`. The loop observes the same
//! ownership and completion rules either way.

const std = @import("std");

const foundation = @import("foundation");
const engine = @import("engine");
const carrier_failure = @import("../carrier_failure.zig");

/// Why a connection is tearing down (ADR-0082).
pub const CloseReason = enum {
    ordinary,
    park_kill,
    drain_kill,
};

/// Complete teardown evidence captured before the loop releases the peer.
pub const CloseReport = struct {
    opened: bool,
    reason: CloseReason,
    failure: ?engine.AbortInfo,
};

/// One collision-free namespace layer for a completion-backend adapter.
///
/// Adapters share connection handles, completion `user_data`, and receive
/// buffer tokens with the backend they wrap. Ad-hoc sentinel ranges do not
/// compose: two wrappers can claim the same high bit and consume each other's
/// events. A wrapped backend therefore publishes `adapter_depth`. This type
/// derives the next disjoint layer for all three channels from that one fact.
///
/// Platform backends start at depth zero. Synthetic fds use successively
/// longer negative prefixes (`10`, `110`, ...), while user data and recv tokens
/// claim one high bit per layer. OS fds stay non-negative and Loop user data
/// stays below bit 35 (`max_conns < maxInt(u32)`), so neither can collide.
pub fn AdapterNamespace(comptime Platform: type) type {
    if (!@hasDecl(Platform, "adapter_depth"))
        @compileError(@typeName(Platform) ++ " must declare `pub const adapter_depth = 0` before it can be wrapped by a completion adapter");
    if (Platform.Fd != i32)
        @compileError("completion adapter namespaces currently require a signed 32-bit Fd");

    const child_depth: u6 = Platform.adapter_depth;
    if (child_depth >= 30)
        @compileError("completion adapter namespace depth exhausted");

    return struct {
        const Namespace = @This();

        pub const depth: u6 = child_depth + 1;

        const fd_prefix_bits: u6 = child_depth + 2;
        const fd_id_bits: u6 = 32 - fd_prefix_bits;
        const fd_id_mask: u32 = (@as(u32, 1) << @intCast(fd_id_bits)) - 1;
        const fd_prefix: u32 = (~@as(u32, 0)) << @intCast(32 - (child_depth + 1));
        const fd_prefix_mask: u32 = (~@as(u32, 0)) << @intCast(32 - fd_prefix_bits);
        const user_data_bit: u64 = @as(u64, 1) << @intCast(63 - child_depth);
        const borrow_token_bit: u32 = @as(u32, 1) << @intCast(31 - child_depth);
        pub const max_fd_id: u32 = fd_id_mask;

        pub fn fdFromId(id: u32) error{AdapterHandleExhausted}!i32 {
            if (id > fd_id_mask) return error.AdapterHandleExhausted;
            return @bitCast(fd_prefix | id);
        }

        /// Compile-time counterpart for mechanically bounded sentinel handles.
        pub fn fdFromComptimeId(comptime id: u32) i32 {
            if (id > fd_id_mask) @compileError("completion adapter handle exceeds its namespace");
            return @bitCast(fd_prefix | id);
        }

        pub fn ownsFd(fd: i32) bool {
            const bits: u32 = @bitCast(fd);
            return bits & fd_prefix_mask == fd_prefix;
        }

        pub fn fdId(fd: i32) u32 {
            std.debug.assert(ownsFd(fd));
            return @as(u32, @bitCast(fd)) & fd_id_mask;
        }

        pub fn userData(payload: u64) u64 {
            std.debug.assert(payload & user_data_bit == 0);
            return payload | user_data_bit;
        }

        pub fn ownsUserData(value: u64) bool {
            return value & user_data_bit != 0;
        }

        pub fn userDataPayload(value: u64) u64 {
            std.debug.assert(ownsUserData(value));
            return value & ~user_data_bit;
        }

        pub fn borrowToken(token: u32) u32 {
            std.debug.assert(token & borrow_token_bit == 0);
            return token | borrow_token_bit;
        }

        pub fn ownsBorrowToken(token: u32) bool {
            return token & borrow_token_bit != 0;
        }

        pub fn borrowTokenPayload(token: u32) u32 {
            std.debug.assert(ownsBorrowToken(token));
            return token & ~borrow_token_bit;
        }

        /// How this adapter names one row on both channels it shares with the
        /// backend it wraps. A synthetic handle carries the row id inside the
        /// namespace's fd prefix, and an internal completion carries the row
        /// id above the operation it retires. `Op` is the adapter's internal
        /// operation enum. Its values must fit the three low user-data bits.
        ///
        /// Row ids are reserved here too, wrapping through the namespace so a
        /// long-lived backend never runs out, and skipping any id a live or
        /// still-opening row holds. A backend that must never reuse an id
        /// because the id doubles as a request token toward another owner
        /// keeps its own monotonic counter instead.
        pub fn RowIdentity(comptime Op: type) type {
            comptime {
                for (@typeInfo(Op).@"enum".field_values) |field_value| {
                    if (field_value >= 8)
                        @compileError(@typeName(Op) ++ " must encode every internal operation in three bits");
                }
            }
            return struct {
                pub const ConnId = u32;

                pub fn fdFromId(row: ConnId) error{AdapterHandleExhausted}!i32 {
                    return Namespace.fdFromId(row);
                }

                pub fn idFromFd(fd: i32) ?ConnId {
                    if (!Namespace.ownsFd(fd)) return null;
                    return @intCast(Namespace.fdId(fd));
                }

                pub fn userData(operation: Op, row: ConnId) u64 {
                    return Namespace.userData((@as(u64, row) << 3) | @backingInt(operation));
                }

                pub fn owns(user_data: u64) bool {
                    return Namespace.ownsUserData(user_data);
                }

                pub fn id(user_data: u64) ConnId {
                    return @intCast(Namespace.userDataPayload(user_data) >> 3);
                }

                pub fn op(user_data: u64) Op {
                    return @fromBackingInt(@intCast(@as(u3, @truncate(Namespace.userDataPayload(user_data)))));
                }

                /// Reserve one row id no live or still-opening row holds.
                /// `occupied` answers `contains(id)` for every table that
                /// keys a row by this id, so an id a losing dial still owns
                /// cannot be handed to a fresh row.
                pub fn reserveId(next_id: *ConnId, occupied: anytype) error{TooManyConnections}!ConnId {
                    var remaining: u64 = Namespace.max_fd_id;
                    while (remaining != 0) : (remaining -= 1) {
                        const candidate = next_id.*;
                        next_id.* = if (candidate == Namespace.max_fd_id) 1 else candidate + 1;
                        if (!occupied.contains(candidate)) return candidate;
                    }
                    return error.TooManyConnections;
                }
            };
        }
    };
}

/// The direction a `submitPoll` waits on.
pub const Interest = enum { readable, writable };

/// Compile-check the total backend surface once, before the loop calls it.
/// Soft optionality at call sites is forbidden: a missing member fails here,
/// not as a latent special case on one path.
pub fn validateBackend(comptime Backend: type) void {
    const required = .{
        "Fd",
        "ConnectTarget",
        "ListenTarget",
        "loopListenTarget",
        "ListenerAddress",
        "deinit",
        "openListener",
        "listenerAddress",
        "listenerPort",
        "closeFd",
        "startDial",
        "shutdownFd",
        "wireFraming",
        "submitAccept",
        "listenerPending",
        "submitRecv",
        "submitSend",
        "submitCancel",
        "submitClose",
        "recycleBorrowed",
        "poll",
        "verifiedChannelKey",
        "applyKeepalive",
    };
    inline for (required) |name| {
        if (!@hasDecl(Backend, name))
            @compileError("completion Backend missing `" ++ name ++ "` — total contract, no optional dial/shutdown members");
    }
}

/// Compile-check that the netlayer resolver produces this backend's target.
/// Merely taking `resolve`'s type checks the half that never goes wrong. The
/// return payload check below catches a resolver bound to another backend.
pub fn validateDialResolver(comptime DialResolver: type, comptime ConnectTarget: type) void {
    if (!@hasDecl(DialResolver, "resolve"))
        @compileError("completion DialResolver missing `resolve` — OCapN locator → ConnectTarget");
    const info = @typeInfo(@TypeOf(DialResolver.resolve));
    if (info != .@"fn") @compileError("completion DialResolver.resolve must be a function");
    const returns = info.@"fn".return_type orelse
        @compileError("completion DialResolver.resolve must have a concrete return type");
    const payload = switch (@typeInfo(returns)) {
        .error_union => |eu| eu.payload,
        else => returns,
    };
    if (payload != ConnectTarget)
        @compileError("completion DialResolver.resolve must return " ++ @typeName(ConnectTarget) ++
            ", found " ++ @typeName(payload));
}

/// One backend-owned payload lent with a completion.
pub const Borrowed = struct {
    pub const Kind = enum(u8) { none, recv, failure, carrier_failure };

    ptr: ?*const anyopaque = null,
    len: usize = 0,
    token: u32 = 0,
    kind: Kind = .none,
    /// Stable carrier phase for a plain borrowed chain, or for a scalar
    /// failure with no retained payload. This occupies descriptor padding.
    /// `Completion` remains pinned at 48 bytes.
    carrier_phase: ?carrier_failure.Phase = null,

    pub fn recv(bytes: []const u8, token: u32) Borrowed {
        return .{ .ptr = bytes.ptr, .len = bytes.len, .token = token, .kind = .recv };
    }

    pub fn failure(chain: *const foundation.FailureChain, token: u32) Borrowed {
        return .{ .ptr = chain, .token = token, .kind = .failure };
    }

    pub fn carrierFailure(failure_value: *const carrier_failure.Failure, token: u32) Borrowed {
        return .{ .ptr = failure_value, .token = token, .kind = .carrier_failure };
    }

    pub fn phaseOnly(phase: carrier_failure.Phase) Borrowed {
        return .{ .carrier_phase = phase };
    }

    pub fn withPhase(self: Borrowed, phase: carrier_failure.Phase) Borrowed {
        var result = self;
        result.carrier_phase = phase;
        return result;
    }

    pub fn recvBytes(self: Borrowed) ?[]const u8 {
        if (self.kind != .recv) return null;
        const ptr: [*]const u8 = @ptrCast(self.ptr orelse unreachable);
        return ptr[0..self.len];
    }

    pub fn failureChain(self: Borrowed) ?*const foundation.FailureChain {
        return switch (self.kind) {
            .failure => failure: {
                std.debug.assert(self.len == 0);
                break :failure @ptrCast(@alignCast(self.ptr orelse unreachable));
            },
            .carrier_failure => &self.carrierFailureValue().?.chain,
            .none, .recv => null,
        };
    }

    pub fn carrierFailureValue(self: Borrowed) ?*const carrier_failure.Failure {
        if (self.kind != .carrier_failure) return null;
        std.debug.assert(self.len == 0);
        return @ptrCast(@alignCast(self.ptr orelse unreachable));
    }

    pub fn carrierPhase(self: Borrowed) ?carrier_failure.Phase {
        if (self.carrierFailureValue()) |failure_value| return failure_value.phase;
        return self.carrier_phase;
    }

    pub fn active(self: Borrowed) bool {
        return self.kind != .none;
    }
};

/// One finished operation reported by a backend: `result` follows the
/// underlying syscall's sign convention and `user_data` identifies the exact
/// submitted operation.
pub const Completion = struct {
    user_data: u64,
    result: i32,
    /// Typed primary when `result < 0`. Backends without a more specific cause
    /// leave this null. The loop supplies an operation-specific fallback.
    failure: ?anyerror = null,
    /// Successful accept result when a userspace adapter's synthetic handle
    /// can be negative. Ordinary non-negative OS fds may remain in `result`.
    accepted_fd: ?i32 = null,
    /// Backend-owned data borrowed until `recycleBorrowed` receives this exact
    /// completion. Receive bytes and a structured cold-path failure share one
    /// descriptor: neither inflates every completion or connection for the
    /// other's mutually exclusive payload.
    borrowed: Borrowed = .{},
    /// Pool pressure, not channel failure. The loop parks and re-arms the read
    /// after another completion returns a buffer.
    recv_no_buffer: bool = false,
};

comptime {
    // Completion arrays and adapter-held records multiply this value across
    // the scale path. A richer failure seam must reuse the existing borrowed
    // payload storage rather than silently taxing every live connection.
    std.debug.assert(@sizeOf(Completion) == 48);
}

/// Project a platform errno once onto the transport-neutral failure value.
pub fn failureFromErrno(errno: std.posix.E) anyerror {
    return switch (errno) {
        .CONNABORTED => error.ConnectionAborted,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .TIMEDOUT => error.TimedOut,
        .NETDOWN => error.NetworkDown,
        .NETUNREACH => error.NetworkUnreachable,
        .HOSTUNREACH => error.HostUnreachable,
        .PIPE => error.BrokenPipe,
        .CANCELED => error.Canceled,
        .BADF => error.InvalidFileDescriptor,
        .NOMEM => error.OutOfMemory,
        .NOSPC => error.SystemResources,
        else => error.Unexpected,
    };
}

/// Cursor-backed queue shared by readiness backends and transport adapters.
///
/// Sliding the remainder after each fixed-batch drain is quadratic over a
/// burst. Advancing a cursor makes the whole burst O(M). Compacting only when
/// the dead prefix outgrows the live suffix bounds retained storage by backlog
/// rather than process uptime.
pub const ReadyQueue = struct {
    items: std.ArrayList(Completion) = .empty,
    /// Prefix already moved to the caller. It resets with the list when empty.
    head: usize = 0,

    pub fn deinit(self: *ReadyQueue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.head = 0;
    }

    pub fn len(self: *const ReadyQueue) usize {
        return self.items.items.len - self.head;
    }

    pub fn append(self: *ReadyQueue, allocator: std.mem.Allocator, c: Completion) !void {
        try self.items.append(allocator, c);
    }

    pub fn ensureUnusedCapacity(self: *ReadyQueue, allocator: std.mem.Allocator, n: usize) !void {
        try self.items.ensureUnusedCapacity(allocator, n);
    }

    pub fn appendAssumeCapacity(self: *ReadyQueue, c: Completion) void {
        self.items.appendAssumeCapacity(c);
    }

    pub fn drain(self: *ReadyQueue, out: []Completion) usize {
        const n = @min(self.len(), out.len);
        if (n == 0) return 0;
        @memcpy(out[0..n], self.items.items[self.head..][0..n]);
        self.head += n;
        const rest = self.items.items.len - self.head;
        if (rest == 0) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        } else if (self.head >= rest) {
            // Halving the dead prefix each time keeps total copied records
            // linear over the burst while reclaiming space in a never-empty
            // queue.
            std.mem.copyForwards(Completion, self.items.items[0..rest], self.items.items[self.head..]);
            self.items.shrinkRetainingCapacity(rest);
            self.head = 0;
        }
        return n;
    }
};
