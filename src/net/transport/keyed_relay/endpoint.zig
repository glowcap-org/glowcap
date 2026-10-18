//! Relay endpoint acquisition: DNS/IP resolution and TCP connection.

const std = @import("std");
const foundation = @import("foundation");

const address_race = @import("address_race.zig");
const netlayer = @import("../../netlayer.zig");
const socket = @import("../../socket.zig");
const carrier_failure = @import("../../carrier_failure.zig");
const route = @import("route.zig");
const race = @import("endpoint_race.zig");

const DialError = netlayer.DialError;
const DialFailure = netlayer.DialFailure;

pub const ConnectOutcome = union(enum) {
    connected: std.Io.net.Stream,
    failed: DialFailure,
};

fn failure(phase: carrier_failure.Phase, err: anyerror) DialFailure {
    const classification: DialError = switch (err) {
        error.ConnectionRefused => error.ConnectionRefused,
        error.HostUnreachable,
        error.NetworkUnreachable,
        error.NetworkDown,
        error.UnknownHostName,
        error.NoAddressReturned,
        error.TooManyAddresses,
        error.NameServerFailure,
        => error.NetworkUnreachable,
        error.Timeout => error.TimedOut,
        error.SystemResources,
        error.OptionUnsupported,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => error.SocketConfigurationFailed,
        else => error.ConnectionLost,
    };
    return .fromCarrier(classification, .init(phase, err));
}

/// Connect directly to an IP literal or resolve and race a validated DNS
/// hostname. The relay owns a bounded nonblocking race rather than delegating
/// to `HostName.connect`: every losing socket is joined locally, so cancellation
/// cannot escape through Zig's process-level unexpected-errno tracer.
/// Disable Nagle on the carrier socket. CapTP frames over the relay are
/// small and sequential, and with Nagle on, a frame written while an earlier
/// one is unacked waits out the peer's delayed-ACK timer. Throughput-only, so
/// a refused option keeps the working connection.
fn tuneCarrier(stream: std.Io.net.Stream) std.Io.net.Stream {
    socket.applyNodelay(stream.socket.handle) catch {}; // tolerant: throughput only
    return stream;
}

pub fn connect(io: std.Io, relay: route.RelayUrl) ConnectOutcome {
    if (std.Io.net.IpAddress.parse(relay.host, relay.port)) |address| {
        return .{ .connected = tuneCarrier(address.connect(io, .{ .mode = .stream }) catch |err|
            return .{ .failed = failure(.connect, err) }) };
    } else |_| {
        const host = std.Io.net.HostName.init(relay.host) catch
            return .{ .failed = .init(error.InvalidAddress) };
        return connectHost(io, host, relay.port);
    }
}

fn connectHost(io: std.Io, host: std.Io.net.HostName, port: u16) ConnectOutcome {
    var lookup_buffer: [address_race.max_resolved_addresses]std.Io.net.HostName.LookupResult = undefined;
    var resolved: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);
    var lookup = io.async(std.Io.net.HostName.lookup, .{ host, io, &resolved, .{ .port = port } });

    var addresses: [address_race.max_resolved_addresses]std.Io.net.IpAddress = undefined;
    var address_count: usize = 0;
    var address_overflow = false;
    var attempts: ?DialFailure = null;
    while (resolved.getOne(io)) |item| switch (item) {
        .canonical_name => continue,
        .address => |address| {
            if (address_count < addresses.len) {
                addresses[address_count] = address;
                address_count += 1;
            } else {
                address_overflow = true;
            }
        },
    } else |queue_error| switch (queue_error) {
        error.Canceled => {
            var canceled = failure(.resolve, error.Canceled);
            lookup.cancel(io) catch |err| if (err != error.Canceled)
                canceled.chain.note(err);
            return .{ .failed = canceled };
        },
        error.Closed => {
            lookup.await(io) catch |err| {
                noteAttempt(&attempts, .resolve, err);
                return .{ .failed = attempts.? };
            };
            if (address_overflow) {
                noteAttempt(&attempts, .resolve, error.TooManyAddresses);
                return .{ .failed = attempts.? };
            }
            return switch (race.connect(io, addresses[0..address_count], &attempts)) {
                .connected => |stream| .{ .connected = tuneCarrier(stream) },
                .failed => |failed| .{ .failed = failed },
            };
        },
    }
}

fn noteAttempt(attempts: *?DialFailure, phase: carrier_failure.Phase, err: anyerror) void {
    foundation.latchFailure(attempts, failure(phase, err));
}
