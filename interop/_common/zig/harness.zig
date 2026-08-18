//! Shared harness for the Zig interop drivers under `interop/*/driver.zig`:
//! the one-verb scenario actor, deadline-guarded waits, the caller-owned
//! peer-and-buffers scaffold, the `--port=` flag contract, loop-thread
//! runners, and the fetch-call-assert client bracket.
//!
//! Each driver keeps its scenario — topology, narration, and per-step
//! assertions stay local — and imports only the plumbing every driver
//! re-rolled. The wait helpers are `test/support/wait.zig` itself, handed to
//! this module by `build.zig` as the `support_wait` import and re-exported
//! here, so the fail-loud vocabulary has one owner across both trees.
//!
//! Wired in `build.zig` as the `interop_harness` module import of every Zig
//! interop executable. Like `test/support`, this is scaffolding, not product:
//! it sits outside the `src/` layer DAG.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;
const crypto = pancake.foundation.crypto;

/// A published actor that answers exactly one verb with a fixed string reply
/// and refuses everything else with `error.NoSuchMethod`. Each driver picks a
/// distinct reply text, so a cross-wired session fails its reply assertion
/// instead of passing on another scenario's greeting.
pub fn StaticReplyActor(comptime verb: []const u8, comptime reply: []const u8) type {
    return struct {
        pub fn handle(self: *@This(), turn: *actors.Turn, msg: actors.Message) !model.Argument {
            _ = self;
            _ = turn;
            if (!std.mem.eql(u8, msg.verb, verb)) return error.NoSuchMethod;
            return .{ .string = reply };
        }
    };
}

/// An actor a live Goblins peer calls, for a driver whose partner invokes a cap
/// **positionally**: `(<- actor "world")` carries no method symbol, so the first
/// argument is the name rather than the verb. `template` is a format string with
/// one `{s}` for that name; the reply is built on `turn.arena`, the per-turn
/// allocator the vat reclaims. A partner that names a verb wants
/// `StaticReplyActor` instead.
pub fn PositionalReplyActor(comptime template: []const u8) type {
    return struct {
        pub fn handle(self: *@This(), turn: *actors.Turn, msg: actors.Message) !model.Argument {
            _ = self;
            const name: []const u8 = switch (try msg.arg(0)) {
                .string => |s| s,
                .bytes => |b| b,
                else => "stranger",
            };
            return .{ .string = try std.fmt.allocPrint(turn.arena, template, .{name}) };
        }
    };
}

/// A publish callback for `driver.Bridge` options: publishes one fresh `Actor`
/// behind `swiss` on every adopted connection.
pub fn publisher(comptime swiss: []const u8, comptime Actor: type) fn (?*anyopaque, *driver.Served, *actors.Vat) anyerror!void {
    return struct {
        fn publish(ctx: ?*anyopaque, served: *driver.Served, vat: *actors.Vat) anyerror!void {
            _ = ctx;
            _ = try served.publish(vat, swiss, Actor, .{});
        }
    }.publish;
}

const wait = @import("support_wait");

pub const deadlineAfter = wait.deadlineAfter;
pub const expired = wait.expired;
pub const untilFlag = wait.untilFlag;

/// `net.tcp.connect` with a bounded retry on `ConnectionRefused`: a spawned
/// host's readiness line can race its listener's actual bind, so the first
/// dial may land in the gap. Any other error fails immediately; refusal past
/// the deadline fails with the refusal.
pub fn tcpConnectRetry(
    io: std.Io,
    peer: *engine.Peer,
    loc: model.PeerLocator,
    read_buf: []u8,
    write_buf: []u8,
    deadline_ms: u64,
) !net.Connection {
    const deadline = deadlineAfter(io, deadline_ms);
    while (true) {
        return net.tcp.connect(io, peer, loc, read_buf, write_buf, .{}) catch |err| switch (err) {
            error.ConnectionRefused => {
                if (expired(io, deadline)) return err;
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
                continue;
            },
            else => return err,
        };
    }
}

/// Block until `listener.waitAcceptable` reports a pending connection, failing
/// loud with `error.WaitTimedOut` past the deadline. A bare blocking `accept`
/// against a spawned dialer is a silent hang: a child that dies before dialing
/// parks the driver in the kernel accept with no location and no failure.
pub fn untilAcceptable(io: std.Io, deadline_ms: u64, listener: anytype) !void {
    const deadline = deadlineAfter(io, deadline_ms);
    while (true) {
        if (try listener.waitAcceptable(250)) return;
        if (expired(io, deadline)) return error.WaitTimedOut;
    }
}

pub const PortFlagError = error{ BadPort, BadArgument };

pub const PortFlagOptions = struct {
    /// Highest acceptable port. A driver whose sibling binds `port + 1` passes
    /// 65534 so the pair stays in range.
    max: u16 = 65535,
    /// Suffix for the range diagnostic, e.g. " (carol binds port+1)".
    note: []const u8 = "",
    /// Exact flag spellings the driver reads itself (via `hasFlag`), tolerated
    /// here so the unknown-argument refusal stays exact.
    tolerated: []const []const u8 = &.{},
};

/// The interop drivers' one-flag argv contract: an optional `--port=N`
/// (last one wins), any `opts.tolerated` flag the driver reads itself, and
/// nothing else. Returns `default` when the flag is absent; a port outside
/// `1..opts.max` or an unknown argument prints a diagnostic under `prefix`
/// and fails typed.
pub fn parsePortFlag(
    minimal_args: anytype,
    prefix: []const u8,
    default: u16,
    opts: PortFlagOptions,
) PortFlagError!u16 {
    var args = std.process.Args.Iterator.init(minimal_args);
    _ = args.next(); // program name
    var port: u16 = default;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            const parsed = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch 0;
            if (parsed == 0 or parsed > opts.max) {
                std.debug.print("{s}: --port must be an integer in 1..{d}{s}\n", .{ prefix, opts.max, opts.note });
                return error.BadPort;
            }
            port = parsed;
        } else {
            const tolerated = for (opts.tolerated) |flag| {
                if (std.mem.eql(u8, arg, flag)) break true;
            } else false;
            if (!tolerated) {
                std.debug.print("{s}: unknown argument '{s}'\n", .{ prefix, arg });
                return error.BadArgument;
            }
        }
    }
    return port;
}

/// Whether `flag` (exact spelling) appears in the argv. Pair it with
/// `PortFlagOptions.tolerated` so `parsePortFlag` accepts the flag.
pub fn hasFlag(minimal_args: anytype, flag: []const u8) bool {
    var args = std.process.Args.Iterator.init(minimal_args);
    _ = args.next(); // program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

/// A caller-owned negotiating peer with its frame-capped read and write
/// buffers, the setup every driver-side dial and accept shares. The scaffold
/// owns the buffers and the peer; `deinit` releases both.
pub const PeerScaffold = struct {
    peer: engine.Peer,
    read_buf: []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, frame_cap: usize) !PeerScaffold {
        return initWith(allocator, frame_cap, .{});
    }

    /// `init` with the peer's negotiating options stated, for a driver whose
    /// scenario needs a non-baseline preference on a caller-owned peer.
    pub fn initWith(
        allocator: std.mem.Allocator,
        frame_cap: usize,
        options: engine.Peer.NegotiatingOptions,
    ) !PeerScaffold {
        var peer = engine.Peer.initNegotiatingWith(allocator, options);
        errdefer peer.deinit();
        peer.session_state.limits.max_frame_bytes = frame_cap;
        const read_buf = try allocator.alloc(u8, frame_cap);
        errdefer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, frame_cap);
        return .{ .peer = peer, .read_buf = read_buf, .write_buf = write_buf, .allocator = allocator };
    }

    pub fn deinit(self: *PeerScaffold) void {
        self.peer.deinit();
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
    }
};

/// Call `target` on the blocking session and require a fulfilled string reply
/// equal to `expected`; a mismatch, break, or give is `error.WrongReply`. The
/// settle materializes into a throwaway arena, so the caller keeps no reply
/// ownership to manage.
pub fn expectStringReply(
    cv: *driver.BlockingSession,
    allocator: std.mem.Allocator,
    target: actors.Ref,
    verb: []const u8,
    args: []const model.Argument,
    expected: []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const settled = try cv.call(target, .{ .verb = verb, .args = args }, arena_state.allocator());
    const ok = switch (settled) {
        .fulfilled => |arg| arg == .string and std.mem.eql(u8, arg.string, expected),
        .broken, .give => false,
    };
    if (!ok) return error.WrongReply;
}

/// One keyed server bracket: accept a single partner on `listener` signing
/// with `secret`, print `banner` once the session opens, publish `Actor`
/// behind `swiss`, and serve until the partner hangs up.
pub fn AcceptServeOne(
    comptime Actor: type,
    comptime swiss: []const u8,
    comptime frame_cap: usize,
    comptime banner: ?[]const u8,
) type {
    return struct {
        pub fn run(
            listener: net.netlayer.Listener,
            allocator: std.mem.Allocator,
            secret: crypto.SecretKey,
        ) anyerror!void {
            var scaffold = try PeerScaffold.init(allocator, frame_cap);
            defer scaffold.deinit();
            var cv = try driver.acceptVia(allocator, listener, &scaffold.peer, .{ .keyed = secret }, scaffold.read_buf, scaffold.write_buf, .{
                .handshake = .unbounded,
                .settle = .unbounded,
            });
            defer cv.deinit();
            if (banner) |line| std.debug.print("{s}\n", .{line});
            _ = try cv.publish(swiss, Actor, .{});
            try cv.serve();
        }
    };
}

/// The loop-thread entry points a Bridge-driven driver hands to
/// `io.concurrent`, generic over the completion loop type.
pub fn LoopRunner(comptime Loop: type) type {
    return struct {
        /// Run until `done` flips, then close every slot and drain; either
        /// failure lands in `out_err` for the joining thread to surface.
        pub fn runUntilFlag(loop: *Loop, done: *const std.atomic.Value(bool), out_err: *?anyerror) void {
            loop.runUntil(done, 0) catch |err| {
                out_err.* = err;
                return;
            };
            loop.closeAndDrain() catch |err| {
                out_err.* = err;
            };
        }

        /// Run until `until_closed` connections have fully closed; a failure
        /// lands in `out_err` for the joining thread to surface.
        pub fn runAfterClosed(loop: *Loop, until_closed: usize, out_err: *?anyerror) void {
            loop.run(.{ .after_closed = until_closed }) catch |err| {
                out_err.* = err;
            };
        }
    };
}

/// A Tor daemon a driver starts and owns, for the live onion checks. It lives in
/// its own file because it is a process bracket rather than a CapTP helper.
pub const Tor = @import("tor.zig").Tor;
