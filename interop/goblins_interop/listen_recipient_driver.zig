//! Live foreign-promise recipient proof on `driver.Session`.
//!
//! A real Goblins vat delivers one of its still-unsettled promises as an
//! argument to a glowcap actor. glowcap installs `Session.listenTo` on that
//! capability, then queues the Goblins settlement request on the same wire.
//! FIFO delivery therefore makes listen-before-settle a protocol fact. The
//! listener fulfillment is a list containing a fresh Goblins greeter, calling
//! that nested capability proves recursive lifting, not merely notification.
//! Every application retain is released and the session finishes explicitly.

const std = @import("std");
const glowcap = @import("glowcap");
const goblins_child = @import("goblins_child.zig");
const harness = @import("interop_harness");

const driver = glowcap.driver;
const actors = glowcap.actors;
const tcp = glowcap.net.tcp;

const host = "127.0.0.1";
const default_port: u16 = 22180;
const frame_cap: usize = 1 << 16;
const rendezvous_swiss = "glowcapDeferredRendezvousSwiss01";
const exporter_script = "conformance/goblins-peer/racket/deferred-exporter-host.rkt";

const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 20_000 },
    .settle = .{ .ms = 20_000 },
};

const HolderState = struct {
    promise: ?driver.Capability = null,
    deliveries: u32 = 0,
};

/// Receives the Goblins-owned unresolved promise as a normal delivered
/// argument. `lend-to` waits for this answer, so the caller cannot subscribe
/// before the capability has crossed the owning Host boundary.
const Holder = struct {
    state: *HolderState,

    pub fn handle(
        self: *Holder,
        turn: *driver.HostTurn,
        verb: []const u8,
        args: driver.Args,
    ) !driver.Value {
        const arg_values = try args.values();
        _ = turn;
        if (!std.mem.eql(u8, verb, "hold")) return error.NoSuchMethod;
        if (arg_values.len != 1 or arg_values[0] != .capability) return error.NotACapability;
        if (self.state.promise != null) return error.PromiseDeliveredTwice;
        self.state.promise = arg_values[0].capability;
        self.state.deliveries += 1;
        return .{ .string = "held" };
    }
};

fn requireHeld(reply: driver.Reply) !void {
    const value = switch (reply) {
        .fulfilled => |value| value,
        .broken => return error.LendBroke,
    };
    if (value != .string or !std.mem.eql(u8, value.string, "held")) {
        return error.WrongLendReply;
    }
}

const SettlementCount = struct {
    done: bool = false,
    count: ?i64 = null,

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *SettlementCount = @ptrCast(@alignCast(ctx.?));
        self.done = true;
        self.count = switch (resolution) {
            .fulfilled => |value| if (value == .integer) value.integer else null,
            .broken, .give => null,
        };
    }
};

fn nestedGreeter(reply: driver.Reply) !driver.Capability {
    const value = switch (reply) {
        .fulfilled => |value| value,
        .broken => return error.ListenBroke,
    };
    if (value != .list or value.list.len != 2) return error.WrongListenPayload;
    const ready = value.list[0];
    if (ready != .string or !std.mem.eql(u8, ready.string, "ready")) {
        return error.WrongListenPayload;
    }
    if (value.list[1] != .capability) return error.WrongListenPayload;
    return value.list[1].capability;
}

fn requireGreeting(reply: driver.Reply) !void {
    const value = switch (reply) {
        .fulfilled => |value| value,
        .broken => return error.GreeterCallBroke,
    };
    if (value != .string or
        !std.mem.eql(u8, value.string, "hello glowcap, from goblins-bob"))
    {
        return error.WrongGreeting;
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const port = try harness.parsePortFlag(
        init.minimal.args,
        "goblins-listen-recipient",
        default_port,
        .{},
    );
    var port_buf: [8]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{port});

    // Keep stdin private even though this scenario settles over CapTP. The
    // sibling relayed-give proof uses the same fixture's stdin control path;
    // neither proof should inherit or consume the invoking terminal.
    const hosted = try goblins_child.spawnHostAwaitSwissWithStdin(
        io,
        allocator,
        init.environ_map,
        "goblins-listen-recipient",
        "rendezvous",
        &.{ exporter_script, host, port_str },
    );
    var bob = hosted.child;
    defer bob.kill(io);
    defer allocator.free(hosted.swiss);
    if (!std.mem.eql(u8, hosted.swiss, rendezvous_swiss)) return error.WrongSwiss;

    var locator_buf: [tcp.designator_buf_len]u8 = undefined;
    const address = try tcp.parseHostPort(host, port);
    var session = try driver.connect(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        tcp.locatorFromAddress(&locator_buf, address),
        .ephemeral,
        opts,
    );
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var holder_state = HolderState{};
    const holder = try session.spawn(Holder, .{ .state = &holder_state });
    const rendezvous = try session.fetch(rendezvous_swiss);

    requireHeld(try session.call(
        rendezvous,
        "lend-to",
        &.{.{ .capability = holder }},
        arena,
    )) catch |err| {
        goblins_child.dumpChildStderr(io, "goblins-listen-recipient", &bob);
        return err;
    };
    if (holder_state.deliveries != 1) return error.WrongPromiseDeliveryCount;
    const foreign_promise = holder_state.promise orelse return error.PromiseNotDelivered;
    _ = arena_state.reset(.retain_capacity);

    // Queue exactly one listen, then the request that settles its target. Both
    // travel on this session in order; Goblins cannot run `settle-nested`
    // before it has processed the preceding op:listen.
    const listened = try session.listenTo(foreign_promise);
    const requested = try session.send(rendezvous, "settle-nested", &.{});
    var settlement = SettlementCount{};
    try requested.on(.{ .ctx = &settlement, .func = SettlementCount.fire });

    const greeter = nestedGreeter(try listened.settle(arena)) catch |err| {
        goblins_child.dumpChildStderr(io, "goblins-listen-recipient", &bob);
        return err;
    };
    while (!settlement.done) {
        if (try session.step() == .closed) return error.SettleRequestNeverAnswered;
    }
    if (settlement.count != 1) return error.WrongSettlementCount;
    _ = arena_state.reset(.retain_capacity);
    requireGreeting(try session.call(
        greeter,
        "",
        &.{.{ .string = "glowcap" }},
        arena,
    )) catch |err| {
        goblins_child.dumpChildStderr(io, "goblins-listen-recipient", &bob);
        return err;
    };

    // Release in dependency order. The remote retains queue their exact
    // gc-answers / gc-exports traffic before finish closes the wire; the local
    // holder loses its application root as well.
    try session.release(greeter);
    try session.release(foreign_promise);
    try session.release(rendezvous);
    try session.release(holder);
    try session.close(.{ .finish = .{ .ms = 10_000 } });
    if (session.closeOutcome() != .closed) return error.SessionDidNotClose;

    std.debug.print(
        "goblins-listen-recipient: OK, one Session.listenTo observed one later Goblins settlement and called its nested capability\n",
        .{},
    );
}
