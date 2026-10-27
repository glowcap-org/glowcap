//! Promise arguments against live Goblins, in both directions (ADR-0068).
//!
//! Toward Goblins, the Zig Session passes a pending reply as a capability
//! argument, which leaves the wire as a local promise export. The host's
//! `await` actor replies with that promise's eventual value, so the bracket
//! proves Goblins lifted the argument as a promise and settled through it
//! when the reply it names arrived.
//!
//! From Goblins, `glowcap-answer-argument.rkt` writes the canonical
//! `op:deliver` through its netlayer, because Goblins has no application-level
//! form for an answer in argument position either. An ordinary `make` whose
//! answer glowcap defers is followed by a `read` naming that answer. glowcap
//! lifts the pending answer to a capability promise and the actor listens on
//! it. The serving loop settles `make`, and the promise's value answers
//! `read`. Goblins observes both settlements.

const std = @import("std");
const glowcap = @import("glowcap");
const goblins_child = @import("goblins_child.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;
const tcp = glowcap.net.tcp;

const host_addr = "127.0.0.1";
const frame_cap: usize = 1 << 16;
/// The wait for the Goblins dialer, matching the sibling brackets.
const deadline_ms: i32 = 60_000;
const dialer_script = "conformance/goblins-peer/racket/glowcap-answer-argument.rkt";
/// The host script publishes `await` under this swiss-num beside echo.
const await_swiss = "glowcapAwaitSwissnumABCDEF123456";
/// The swiss-num glowcap publishes its answer reader behind.
const reader_swiss = "glowcapAnswerReaderSwissnum01234";
/// The value the deferred `make` answer settles to, which `read` relays.
const make_reply = "made after read asked";

const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 20_000 },
    .settle = .{ .ms = 20_000 },
};

/// glowcap as the sender: a reply Goblins has not given is passed to another
/// Goblins actor as a capability.
pub fn passToGoblins(io: std.Io, allocator: std.mem.Allocator, echo_swiss: []const u8, port: u16) !void {
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const locator = tcp.locatorFromAddress(&designator_buf, try tcp.parseHostPort(host_addr, port));
    const session = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, locator, .ephemeral, opts);
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const echo = try session.fetch(echo_swiss);
    const awaiter = try session.fetch(await_swiss);

    // The echo reply is pending when the await call names it, so Goblins
    // receives a promise and settles through it.
    const pending = try session.send(echo, "", &.{.{ .string = "promise-ping" }});
    const as_capability = try pending.capability();
    const awaited = session.call(awaiter, "", &.{.{ .capability = as_capability }}, arena);
    try session.release(as_capability);
    try expectEcho(try awaited, "await");
    // Naming the question changed nothing about its own settlement.
    try expectEcho(try pending.settle(arena), "echo");
    std.debug.print("goblins-interop: OK, goblins lifted a promise argument and settled through it\n", .{});
}

/// The echo reply: a one-element list holding the text that was sent.
fn expectEcho(reply: driver.core.Reply, who: []const u8) !void {
    switch (reply) {
        .fulfilled => |value| {
            if (value != .list or value.list.len != 1) return error.EchoWrongPayload;
            const text: []const u8 = switch (value.list[0]) {
                .string, .bytes => |t| t,
                else => return error.EchoWrongPayload,
            };
            if (!std.mem.eql(u8, text, "promise-ping")) return error.EchoWrongPayload;
        },
        .broken => |reason| {
            std.debug.print("goblins-interop: {s} broke: {s}\n", .{ who, reason });
            return error.EchoBroke;
        },
    }
}

/// What the serving thread learns in turns and settles between them. A
/// listener fires under the Host's callback latch, so it records, and the
/// serving loop performs the settlement.
const Shared = struct {
    host: *driver.core.Host,
    make_resolver: ?u64 = null,
    read_resolver: ?u64 = null,
    make_settled: bool = false,
    read_settled: bool = false,
    /// Room for `make_reply`, the only value the lifted promise settles to.
    text: [make_reply.len]u8 = undefined,
    text_len: usize = 0,
    text_ready: bool = false,
    failure: ?[]const u8 = null,

    fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *Shared = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| switch (value) {
                .string => |text| {
                    if (text.len > self.text.len) {
                        self.failure = "the lifted promise settled to a longer string than make answers";
                        return;
                    }
                    self.text_len = text.len;
                    @memcpy(self.text[0..text.len], text);
                    self.text_ready = true;
                },
                else => self.failure = "the lifted promise settled to something other than a string",
            },
            .broken => self.failure = "the lifted promise broke",
            .give => self.failure = "the lifted promise settled to a handoff",
        }
    }
};

/// The actor Goblins reaches. `make` defers its answer so the question is
/// pending when `read` names it, and `read` defers its own answer until the
/// promise it was handed settles.
const AnswerReader = struct {
    shared: *Shared,

    pub fn handle(self: *AnswerReader, ht: *driver.HostTurn, verb: []const u8, args: driver.Args) !driver.Value {
        if (std.mem.eql(u8, verb, "make")) {
            self.shared.make_resolver = try ht.deferAnswer();
            return .{ .void = {} };
        }
        if (!std.mem.eql(u8, verb, "read") or (try args.len()) != 1) return error.BadInvocation;
        // The answer is deferred before anything can fail, so a failure
        // reaches Goblins as the break of this answer, named.
        self.shared.read_resolver = try ht.deferAnswer();
        self.listen(ht, args) catch |err| {
            self.shared.failure = @errorName(err);
        };
        return .{ .void = {} };
    }

    fn listen(self: *AnswerReader, ht: *driver.HostTurn, args: driver.Args) !void {
        const cap = try args.capability(0);
        defer ht.releaseValues(&.{.{ .capability = cap }});
        switch (try ht.host.resolveCapability(ht.session.?, cap)) {
            .pending => |vow| try ht.host.vowOn(vow, .{ .ctx = self.shared, .func = Shared.record }),
            .resolved => |object| {
                ht.releaseValues(&.{.{ .capability = object }});
                self.shared.failure = "the argument lifted to an object rather than a promise";
            },
        }
    }
};

/// Serve the one Goblins dialer and settle the deferred answers between steps,
/// on the owning thread and outside any callback.
fn serveReader(server: *driver.Server, allocator: std.mem.Allocator, shared: *Shared, done: *std.atomic.Value(bool)) anyerror!void {
    try server.publish(reader_swiss, AnswerReader, .{ .shared = shared });
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var session: ?*driver.Session = null;
    defer if (session) |s| s.deinit();

    while (!done.load(.acquire)) {
        if (session == null and try server.waitAcceptable(20)) session = try server.accept();
        if (session) |s| {
            // best-effort: a step error belongs to this one session, whose dialer reports the loss.
            const progress = s.stepReadable(10) catch null;
            // The dialer left, so the loop waits on the listener again instead of stepping a closed session.
            if (progress != null and progress.? == .closed) {
                s.deinit();
                session = null;
            }
        }
        if (shared.make_resolver) |resolver| {
            if (shared.read_resolver != null and !shared.make_settled) {
                try shared.host.resolverFulfillValue(resolver, .{ .string = make_reply }, arena_state.allocator());
                shared.make_settled = true;
            }
        }
        if (shared.read_resolver) |resolver| {
            if (!shared.read_settled) {
                if (shared.failure) |why| {
                    try shared.host.resolverBreak(resolver, why);
                    shared.read_settled = true;
                } else if (shared.text_ready) {
                    try shared.host.resolverFulfillValue(resolver, .{ .string = shared.text[0..shared.text_len] }, arena_state.allocator());
                    shared.read_settled = true;
                }
            }
        }
        _ = arena_state.reset(.retain_capacity);
    }
}

/// glowcap as the receiver: Goblins names one of its own pending questions in
/// argument position, and the glowcap actor answers with that question's value.
pub fn receiveFromGoblins(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = host_addr ++ ":0" }, .ephemeral, opts);
    defer server.deinit();
    var designator_buf: [64]u8 = undefined;
    const designator = try server.localDesignator(&designator_buf);
    const port_text = designator[(std.mem.lastIndexOfScalar(u8, designator, ':') orelse return error.BadDesignator) + 1 ..];

    var shared: Shared = .{ .host = server.runtime.core };
    var done = std.atomic.Value(bool).init(false);
    var serving = try io.concurrent(serveReader, .{ server, allocator, &shared, &done });
    var serving_joined = false;
    defer if (!serving_joined) {
        done.store(true, .release);
        // best-effort: this unwind already returns the run's own error, and the serving thread's failure would only repeat it.
        serving.await(io) catch {};
    };

    var argv_buf: [6][]const u8 = undefined;
    var child = try std.process.spawn(io, .{
        .argv = goblins_child.racketArgv(&argv_buf, &.{ dialer_script, port_text, reader_swiss }),
        .environ_map = init.environ_map,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var reaped = false;
    defer if (!reaped) child.kill(io);

    var scratch: [4096]u8 = undefined;
    const line = goblins_child.awaitChildStdoutLine(io, &child, "ANSWER ARG", &scratch, deadline_ms) orelse {
        std.debug.print("goblins-interop: the answer-argument dialer printed no verdict\n", .{});
        goblins_child.dumpChildStderr(io, "goblins-interop", &child);
        return error.AnswerArgumentNeverSettled;
    };
    const verdict_ok = std.mem.indexOf(u8, line, "ANSWER ARG OK") != null;
    std.debug.print("goblins-interop: {s}\n", .{line});
    if (!verdict_ok) goblins_child.dumpChildStderr(io, "goblins-interop", &child);
    child.kill(io);
    reaped = true;

    done.store(true, .release);
    serving_joined = true;
    try serving.await(io);
    if (shared.failure) |why| {
        std.debug.print("goblins-interop: answer reader: {s}\n", .{why});
        return error.AnswerReaderFailed;
    }
    if (!verdict_ok) return error.GoblinsScenarioFailed;
    if (!shared.make_settled or !shared.read_settled) return error.AnswerReaderNeverSettled;
    std.debug.print("goblins-interop: OK, goblins named a pending question in argument position and a glowcap actor read its value\n", .{});
}
