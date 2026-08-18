//! Shared harness for the blocking-session loopback proofs: the plain
//! keyed connect and accept halves and the two greeter actors every scenario
//! family publishes.

const std = @import("std");
const pancake = @import("pancake");
const support_actors = @import("../../support/actors.zig");

/// A finite handshake budget for every dial in this file. Unbounded is the
/// library default and the wrong thing in a test: a partner that connects and
/// then goes quiet would park the suite instead of failing it.
pub const handshake_budget: driver.Budget = .{ .ms = 10_000 };

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net.tcp;
const net = pancake.net;
const syrup = pancake.ocapn.codec.syrup;
const crypto = pancake.foundation.crypto;

const ip = std.Io.net;

pub const frame_cap = 4096;

/// Session options for a real loopback dial. The budgets are finite on purpose:
/// an unbounded CapTP wait against a partner that goes quiet does not fail the
/// suite, it wedges the test binary, which reads as a hang rather than a bug.
pub const dial_opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

pub fn connectPlain(
    allocator: std.mem.Allocator,
    io: std.Io,
    peer: *engine.Peer,
    address: ip.IpAddress,
    read_buf: []u8,
    write_buf: []u8,
    options: driver.BlockingSession.Options,
) !driver.BlockingSession {
    var resident = tcp.Resident{ .io = io };
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    return driver.connectVia(
        allocator,
        &.{resident.netlayer()},
        peer,
        tcp.locatorFromAddress(&designator_buf, address),
        .ephemeral,
        read_buf,
        write_buf,
        options,
    );
}

pub fn acceptPlain(
    allocator: std.mem.Allocator,
    peer: *engine.Peer,
    listener: *tcp.Listener,
    read_buf: []u8,
    write_buf: []u8,
    options: driver.BlockingSession.Options,
) !driver.BlockingSession {
    return driver.acceptVia(allocator, listener.asNetlayer(), peer, .ephemeral, read_buf, write_buf, options);
}

/// The published actor: answers `greet(name)` with a static greeting.
pub const Greeter = support_actors.StaticReplyActor("greet", "hello from the hosting vat");
/// The same greeter as an owning-tier (Value-shaped) behavior, for the tests
/// publishing through `driver.Session` instead of the borrowing tier.
pub const HostedGreeter = support_actors.StaticReplyValueActor("greet", "hello from the hosting vat");
