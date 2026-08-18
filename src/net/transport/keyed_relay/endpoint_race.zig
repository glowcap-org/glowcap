//! Bounded POSIX race for resolved relay addresses.
//!
//! `std.Io.net.HostName.connect` owns a useful address race, but its threaded
//! cancellation closes losing sockets underneath `connect(2)`. Some kernels
//! report that wakeup as `EINVAL`; Zig classifies it through
//! `unexpectedErrno`, which prints a process stack in Debug before a library
//! can retain the failure. This module owns the narrower relay race directly:
//! nonblocking sockets enter `poll(2)`, every result is read through
//! `SO_ERROR`, and losing descriptors are closed only after a winner exists.

const std = @import("std");
const builtin = @import("builtin");

const address_race = @import("address_race.zig");
const netlayer = @import("../../netlayer.zig");
const carrier_failure = @import("../../carrier_failure.zig");

const DialFailure = netlayer.DialFailure;
const IpAddress = std.Io.net.IpAddress;
const Stream = std.Io.net.Stream;
const c = std.c;
const posix = std.posix;
const system = posix.system;
const use_libc = builtin.link_libc or switch (builtin.os.tag) {
    .windows, .wasi => true,
    else => false,
};

pub const max_parallel_attempts = address_race.max_parallel_attempts;
const cancel_poll_ms = 100;

pub const Outcome = union(enum) {
    connected: Stream,
    failed: DialFailure,
};

const Candidate = struct {
    fd: c.fd_t,
    address_index: u8,
};

const RaceStorage = struct {
    candidates: [max_parallel_attempts]Candidate = undefined,
    polls: [max_parallel_attempts]c.pollfd = undefined,
    failures: address_race.FailureLedger(DialFailure) = .{},
    cleanup_failure: ?DialFailure = null,
    live: usize = 0,
    next_address: usize = 0,
};

/// The complete bounded stack state for one pollable hostname race. Keep the
/// ceiling architecture-neutral so 32- and 64-bit targets share one budget.
pub const transient_state_bytes = @sizeOf(RaceStorage);
pub const transient_state_ceiling_bytes = 4608;

comptime {
    if (transient_state_bytes > transient_state_ceiling_bytes)
        @compileError("pollable relay address race exceeds its transient-state budget");
}

const PosixAddress = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,
};

pub fn connect(
    io: std.Io,
    addresses: []const IpAddress,
    attempts: *?DialFailure,
) Outcome {
    std.debug.assert(addresses.len <= address_race.max_resolved_addresses);
    var state: RaceStorage = .{};

    while (true) {
        // Keep every available seat occupied. A failed address immediately
        // admits the next resolver answer; one slow leg never holds an entire
        // later wave behind it.
        while (state.live < state.candidates.len and state.next_address < addresses.len) {
            const address_index = state.next_address;
            state.next_address += 1;
            switch (start(addresses[address_index])) {
                .failed => |failed| {
                    state.failures.note(address_index, failed);
                    continue;
                },
                .connected => |fd| {
                    const stream = adopt(fd) catch |err| {
                        noteAttempt(&state.failures, address_index, err);
                        noteClose(&state.cleanup_failure, closeFd(fd));
                        continue;
                    };
                    return finishWinner(&state, stream);
                },
                .pending => |fd| {
                    state.candidates[state.live] = .{ .fd = fd, .address_index = @intCast(address_index) };
                    state.polls[state.live] = .{ .fd = fd, .events = c.POLL.OUT, .revents = 0 };
                    state.live += 1;
                },
            }
        }
        if (state.live == 0) {
            state.failures.appendTo(attempts, addresses.len);
            appendFailure(attempts, state.cleanup_failure);
            return .{ .failed = attempts.* orelse noAddressFailure() };
        }

        io.checkCancel() catch {
            var canceled: ?DialFailure = failure(.shutdown, error.Canceled);
            state.failures.appendTo(&canceled, addresses.len);
            closeCandidates(&state);
            appendFailure(&canceled, state.cleanup_failure);
            return .{ .failed = canceled.? };
        };
        const poll_result = system.poll(&state.polls, @intCast(state.live), cancel_poll_ms);
        const ready: usize = switch (posix.errno(poll_result)) {
            .SUCCESS => @intCast(poll_result),
            .INTR => continue,
            else => |err| {
                var failed: ?DialFailure = failure(.connect, pollError(err));
                state.failures.appendTo(&failed, addresses.len);
                closeCandidates(&state);
                appendFailure(&failed, state.cleanup_failure);
                return .{ .failed = failed.? };
            },
        };
        if (ready == 0) continue;

        var index: usize = 0;
        while (index < state.live) {
            if (state.polls[index].revents == 0) {
                index += 1;
                continue;
            }
            const candidate = state.candidates[index];
            const socket_error = takeSocketError(candidate.fd) catch |err| {
                noteAttempt(&state.failures, candidate.address_index, err);
                removeCandidate(&state, index);
                continue;
            };
            if (socket_error) |err| {
                noteAttempt(&state.failures, candidate.address_index, err);
                removeCandidate(&state, index);
                continue;
            }
            const stream = adopt(candidate.fd) catch |err| {
                noteAttempt(&state.failures, candidate.address_index, err);
                removeCandidate(&state, index);
                continue;
            };
            // Ownership moved into the Stream. Remove without closing it;
            // winner settlement retires every other in-flight leg first.
            state.live -= 1;
            state.candidates[index] = state.candidates[state.live];
            state.polls[index] = state.polls[state.live];
            return finishWinner(&state, stream);
        }
    }
}

const Start = union(enum) {
    connected: c.fd_t,
    pending: c.fd_t,
    failed: DialFailure,
};

fn start(address: IpAddress) Start {
    const family: c_int = switch (address) {
        .ip4 => c.AF.INET,
        .ip6 => c.AF.INET6,
    };
    const socket_result = system.socket(
        @intCast(family),
        @intCast(c.SOCK.STREAM | c.SOCK.CLOEXEC | c.SOCK.NONBLOCK),
        0,
    );
    const fd: c.fd_t = switch (posix.errno(socket_result)) {
        .SUCCESS => @intCast(socket_result),
        else => |err| return .{ .failed = failure(.connect, socketError(err)) },
    };

    var storage: PosixAddress = undefined;
    const address_len = addressToPosix(&address, &storage);
    const connect_result = system.connect(fd, &storage.any, address_len);
    return switch (posix.errno(connect_result)) {
        .SUCCESS => .{ .connected = fd },
        .INPROGRESS, .ALREADY, .AGAIN => .{ .pending = fd },
        .ISCONN => .{ .connected = fd },
        else => |err| failed: {
            var result = failure(.connect, socketError(err));
            if (closeFd(fd)) |cleanup|
                result.chain.noteChain(failure(.shutdown, cleanup).chain);
            break :failed .{ .failed = result };
        },
    };
}

fn adopt(fd: c.fd_t) !Stream {
    try setNonblocking(fd, false);
    var storage: PosixAddress = undefined;
    var address_len: c.socklen_t = @sizeOf(PosixAddress);
    const name_result = system.getsockname(fd, &storage.any, &address_len);
    switch (posix.errno(name_result)) {
        .SUCCESS => {},
        else => |err| return socketStatusError(err),
    }
    const address = addressFromPosix(&storage);
    return .{ .socket = .{ .handle = fd, .address = address } };
}

fn takeSocketError(fd: c.fd_t) !?anyerror {
    var value: c_int = 0;
    var value_len: c.socklen_t = @sizeOf(c_int);
    const option_result = system.getsockopt(
        fd,
        c.SOL.SOCKET,
        c.SO.ERROR,
        @ptrCast(&value),
        &value_len,
    );
    switch (posix.errno(option_result)) {
        .SUCCESS => {},
        else => |err| return socketStatusError(err),
    }
    if (value == 0) return null;
    return socketError(@enumFromInt(value));
}

fn socketStatusError(err: c.E) anyerror {
    return switch (err) {
        .NOMEM, .NOBUFS => error.SystemResources,
        .BADF => error.InvalidSocketHandle,
        .NOTSOCK => error.InvalidSocketState,
        else => error.SocketStatusFailed,
    };
}

fn setNonblocking(fd: c.fd_t, enabled: bool) !void {
    const get_result = if (comptime use_libc)
        system.fcntl(fd, c.F.GETFL, @as(c_int, 0))
    else
        system.fcntl(fd, c.F.GETFL, @as(usize, 0));
    const flags: c_int = switch (posix.errno(get_result)) {
        .SUCCESS => @intCast(get_result),
        else => return error.SocketConfigurationFailed,
    };
    const bit: c_int = @bitCast(c.O{ .NONBLOCK = true });
    const updated = if (enabled) flags | bit else flags & ~bit;
    const set_result = if (comptime use_libc)
        system.fcntl(fd, c.F.SETFL, updated)
    else
        system.fcntl(fd, c.F.SETFL, @as(usize, @intCast(updated)));
    if (posix.errno(set_result) != .SUCCESS) return error.SocketConfigurationFailed;
}

fn finishWinner(state: *RaceStorage, stream: Stream) Outcome {
    closeCandidates(state);
    if (state.cleanup_failure) |cleanup_value| {
        var cleanup = cleanup_value;
        if (closeFd(stream.socket.handle)) |winner_cleanup|
            cleanup.chain.noteChain(failure(.shutdown, winner_cleanup).chain);
        return .{ .failed = cleanup };
    }
    return .{ .connected = stream };
}

fn removeCandidate(state: *RaceStorage, index: usize) void {
    noteClose(&state.cleanup_failure, closeFd(state.candidates[index].fd));
    state.live -= 1;
    state.candidates[index] = state.candidates[state.live];
    state.polls[index] = state.polls[state.live];
}

fn closeCandidates(state: *RaceStorage) void {
    while (state.live != 0) {
        state.live -= 1;
        noteClose(
            &state.cleanup_failure,
            closeFd(state.candidates[state.live].fd),
        );
    }
}

fn closeFd(fd: c.fd_t) ?anyerror {
    return switch (posix.errno(system.close(fd))) {
        .SUCCESS => null,
        .BADF => error.InvalidSocketHandle,
        .INTR => error.CloseInterrupted,
        else => error.CloseFailed,
    };
}

fn addressToPosix(address: *const IpAddress, storage: *PosixAddress) c.socklen_t {
    return switch (address.*) {
        .ip4 => |ip4| {
            storage.in = .{
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = @bitCast(ip4.bytes),
            };
            return @sizeOf(posix.sockaddr.in);
        },
        .ip6 => |ip6| {
            storage.in6 = .{
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = ip6.flow,
                .addr = ip6.bytes,
                .scope_id = ip6.interface.index,
            };
            return @sizeOf(posix.sockaddr.in6);
        },
    };
}

fn addressFromPosix(storage: *const PosixAddress) IpAddress {
    return switch (storage.any.family) {
        posix.AF.INET => .{ .ip4 = .{
            .port = std.mem.bigToNative(u16, storage.in.port),
            .bytes = @bitCast(storage.in.addr),
        } },
        posix.AF.INET6 => .{ .ip6 = .{
            .port = std.mem.bigToNative(u16, storage.in6.port),
            .bytes = storage.in6.addr,
            .flow = storage.in6.flowinfo,
            .interface = .{ .index = storage.in6.scope_id },
        } },
        else => unreachable,
    };
}

fn socketError(err: c.E) anyerror {
    return switch (err) {
        .ACCES, .PERM => error.AccessDenied,
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .NETDOWN => error.NetworkDown,
        .TIMEDOUT => error.Timeout,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM, .NOBUFS => error.SystemResources,
        .INVAL => error.InvalidSocketState,
        else => error.ConnectFailed,
    };
}

fn pollError(err: c.E) anyerror {
    return switch (err) {
        .NOMEM => error.SystemResources,
        .INVAL => error.InvalidPollSet,
        else => error.PollFailed,
    };
}

fn noteAttempt(
    failures: *address_race.FailureLedger(DialFailure),
    address_index: usize,
    err: anyerror,
) void {
    failures.note(address_index, failure(.connect, err));
}

fn noteClose(cleanup_failure: *?DialFailure, close_failure: ?anyerror) void {
    const err = close_failure orelse return;
    appendFailure(cleanup_failure, failure(.shutdown, err));
}

fn appendFailure(target: *?DialFailure, next: ?DialFailure) void {
    const value = next orelse return;
    if (target.*) |*first|
        first.chain.noteChain(value.chain)
    else
        target.* = value;
}

fn failure(phase: carrier_failure.Phase, err: anyerror) DialFailure {
    const classification: netlayer.DialError = switch (err) {
        error.ConnectionRefused => error.ConnectionRefused,
        error.HostUnreachable,
        error.NetworkUnreachable,
        error.NetworkDown,
        => error.NetworkUnreachable,
        error.Timeout => error.TimedOut,
        error.SystemResources,
        error.AddressUnavailable,
        error.AddressFamilyUnsupported,
        error.AccessDenied,
        error.InvalidSocketHandle,
        error.InvalidSocketState,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.SocketConfigurationFailed,
        => error.SocketConfigurationFailed,
        else => error.ConnectionLost,
    };
    return .fromCarrier(classification, carrier_failure.Failure.init(phase, err));
}

pub const white_box = if (builtin.is_test) struct {
    pub fn descriptorRetirementFailure(fd: c.fd_t) DialFailure {
        var state: RaceStorage = .{};
        state.candidates[0] = .{ .fd = fd, .address_index = 0 };
        state.live = 1;
        closeCandidates(&state);
        std.debug.assert(state.live == 0);
        return state.cleanup_failure.?;
    }
} else struct {};

fn noAddressFailure() DialFailure {
    return .fromCarrier(
        error.NetworkUnreachable,
        .init(.resolve, error.NoAddressReturned),
    );
}
