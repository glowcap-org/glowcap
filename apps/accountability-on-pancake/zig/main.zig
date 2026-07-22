//! accountability-on-pancake — a real application on pancake's own runtime.
//!
//! The same accountability shape as the Goblins worked example, on pancake as its
//! CapTP runtime: a vat hosts an Affordance behind an OCapN capability, a caller invokes
//! it across a real TCP/OCapN session, and every invocation produces a signed,
//! transparency-logged Episode attributing the caller. Identity (KERI), Episodes,
//! and the transparency log all live above pancake; pancake provides only the
//! capability-secure wire.
//!
//! Run it with one command:
//!
//!   zig build accountability
//!
//! Two real `engine.Peer`s talk over a 127.0.0.1 socket pair on a
//! `std.Io.Threaded` backend. The host accepts on a concurrent fiber, the caller
//! drives this one. The host publishes the Affordance by name; the caller fetches
//! it and eventual-sends an `invoke`. Attribution is not a trusted
//! header: the caller signs the request with its KERI key, and the host refuses
//! to account for an invocation it cannot attest. That signed attribution is the
//! thing an ambient-authority HTTP call structurally cannot produce. See
//! `../why-this-couldnt-be-http.md`.

const std = @import("std");
const pancake = @import("pancake");

const identity = @import("identity.zig");
const accountable = @import("accountable.zig");
const affordance = @import("affordance.zig");
const log = @import("log.zig");

const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net.tcp;
const ip = std.Io.net;

const AFFORDANCE_NAME = affordance.AFFORDANCE_NAME;
const frame_cap = affordance.frame_cap;
const data_root = affordance.data_root;

const HostArgs = struct {
    listener: *tcp.Listener,
    allocator: std.mem.Allocator,
    store: *accountable.Store,
    served: *usize,
    last_subject: *[identity.SAID_LEN]u8,
};

/// Accept one connection, publish the Affordance by name, and serve invocations
/// until the caller leaves.
fn hostServe(args: HostArgs) !void {
    const allocator = args.allocator;
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var vat = try driver.acceptTcp(allocator, &peer, args.listener, read_buf, write_buf);
    defer vat.deinit();

    _ = try vat.publish(AFFORDANCE_NAME, affordance.Affordance, .{
        .store = args.store,
        .served = args.served,
        .last_subject = args.last_subject,
    });

    try vat.serve();
}

fn banner(step: u8, msg: []const u8) void {
    std.debug.print("[{d}/8] {s}\n", .{ step, msg });
}

/// Drive one capability invocation to its settled outcome over the live
/// session (the driver's `call` materializes both arms into `arena`).
/// `tamper` corrupts the signature so the host refuses to attest it, the path
/// that must surface as a clean broken promise, not a crash or a silent success.
fn invoke(
    cv: *driver.BlockingSession,
    target: actors.Ref,
    caller: *const identity.Identity,
    request: []const u8,
    tamper: bool,
    arena: std.mem.Allocator,
) !driver.Settled {
    const att = affordance.Attestation.sign(caller.current, request, tamper);
    return cv.call(target, .{
        .verb = affordance.invoke_verb,
        .args = &.{
            .{ .string = caller.aidSlice() },
            .{ .string = &att.verkey },
            .{ .string = request },
            .{ .string = &att.signature },
        },
    }, arena);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("accountability-on-pancake, a real application on pancake's runtime\n\n", .{});

    // ---- Identities (above pancake) -------------------------------------------
    banner(1, "Host vat and caller each incept a KERI-anchored identity");
    var host_id = try identity.Identity.incept(allocator, io);
    defer host_id.deinit();
    var caller_id = try identity.Identity.incept(allocator, io);
    defer caller_id.deinit();
    std.debug.print("      host AID:   {s}\n", .{host_id.aidSlice()});
    std.debug.print("      caller AID: {s}\n", .{caller_id.aidSlice()});

    banner(2, "Caller rotates its key (pre-rotation discipline holds)");
    const rot_said = try caller_id.rotate(io);
    std.debug.print("      caller rotated; new key-event SAID: {s}\n", .{&rot_said});

    var host_store = try accountable.Store.init(allocator, io, &host_id, data_root ++ "/host");
    defer host_store.deinit();
    var caller_store = try accountable.Store.init(allocator, io, &caller_id, data_root ++ "/caller");
    defer caller_store.deinit();

    // ---- The capability wire (pancake) ----------------------------------------
    banner(3, "Host publishes the Affordance behind an OCapN capability");
    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer listener.deinit();
    const address = listener.localAddress();

    var served: usize = 0;
    var last_subject: [identity.SAID_LEN]u8 = undefined;
    var host_future = try io.concurrent(hostServe, .{HostArgs{
        .listener = &listener,
        .allocator = allocator,
        .store = &host_store,
        .served = &served,
        .last_subject = &last_subject,
    }});

    // Caller side. `connectTcp` completes the keyed handshake before returning.
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var cv = try driver.connectTcp(allocator, io, &peer, address, read_buf, write_buf);
    std.debug.print("      session open over TCP {f}\n", .{address});

    const affordance_ref = try cv.fetch(AFFORDANCE_NAME);

    // ---- The invocation, accounted on both sides ------------------------------
    const request = "read-thermostat";

    banner(4, "Caller writes an Attempt Episode, then invokes the capability");
    // The Attempt Episode is durable *before* the wire send: intent is
    // recorded first, exactly as the documented seam requires.
    _ = try caller_store.record(.attempt, caller_id.aidSlice(), "demo", request);

    var call_arena = std.heap.ArenaAllocator.init(allocator);
    defer call_arena.deinit();

    const outcome = try invoke(&cv, affordance_ref, &caller_id, request, false, call_arena.allocator());
    const result: []const u8 = switch (outcome) {
        .fulfilled => |arg| affordance.strArg(arg) orelse "",
        .give => "",
        .broken => |reason| {
            std.debug.print("      invocation did not resolve fulfilled (reason='{s}')\n", .{reason});
            cv.deinit();
            _ = host_future.await(io) catch |err| std.debug.print("      host fiber error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        },
    };

    banner(5, "Host verifies the attestation and resolves the invocation");
    std.debug.print("      result: {s}\n", .{result});
    _ = try caller_store.record(.outcome, caller_id.aidSlice(), "demo", result);

    banner(6, "A caller it cannot attest is refused, a clean broken promise, no Episode");
    // Same caller, same request, but a corrupted signature: the host must refuse
    // to account for what it cannot attribute. The refusal travels back as a
    // broken promise (not a session abort), and the host writes no Episode for it.
    const served_before = served;
    const refused = try invoke(&cv, affordance_ref, &caller_id, request, true, call_arena.allocator());
    const refusal_reason: []const u8 = switch (refused) {
        .broken => |reason| reason,
        .fulfilled, .give => {
            std.debug.print("      a tampered invocation was NOT refused\n", .{});
            cv.deinit();
            _ = host_future.await(io) catch {};
            std.process.exit(1);
        },
    };
    if (served != served_before) {
        std.debug.print("      host accounted for an unattested invocation\n", .{});
        std.process.exit(1);
    }
    std.debug.print("      refused: {s}\n", .{refusal_reason});

    // Let the host observe EOF and finish.
    cv.deinit();
    _ = host_future.await(io) catch |err| {
        std.debug.print("      host fiber error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    banner(7, "Host's Outcome Episode attributes the TRUE caller");
    if (served == 0) {
        std.debug.print("      host served no invocation\n", .{});
        std.process.exit(1);
    }
    const attributed = std.mem.eql(u8, &last_subject, caller_id.aidSlice());
    std.debug.print("      host attributed: {s}\n", .{&last_subject});
    std.debug.print("      matches caller AID: {}\n", .{attributed});
    if (!attributed) std.process.exit(1);

    // ---- Audit -----------------------------------------------------------------
    banner(8, "Every Episode is auditable; transparency roots are stable");
    const caller_count = try caller_store.auditAll();
    const host_count = try host_store.auditAll();
    const caller_root = log.toHex(try caller_store.currentRoot());
    const host_root = log.toHex(try host_store.currentRoot());
    std.debug.print("      caller episodes: {d} (root {s})\n", .{ caller_count, &caller_root });
    std.debug.print("      host episodes:   {d} (root {s})\n", .{ host_count, &host_root });

    if (caller_count != 2 or host_count != 1) {
        std.debug.print("      unexpected episode counts (caller={d} host={d})\n", .{ caller_count, host_count });
        std.process.exit(1);
    }

    std.debug.print(
        \\
        \\accountability-on-pancake OK: a capability invocation crossed a real
        \\OCapN session on the `tcp` netlayer between two pancake peers, and the host produced a
        \\verifiable Episode attributing the attested caller. pancake hosted the
        \\wire; identity, Episodes, and the transparency log stayed above it.
        \\
    , .{});
}
