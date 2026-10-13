//! accountability-on-glowcap: a real application on glowcap's own runtime.
//!
//! The same accountability shape as the Goblins worked example, on glowcap as its
//! CapTP runtime: a vat hosts an Affordance behind an OCapN capability, a caller invokes
//! it across a real TCP/OCapN session, and every invocation produces a signed,
//! transparency-logged Episode attributing the caller. Identity (KERI), Episodes,
//! and the transparency log all live above glowcap, glowcap provides only the
//! capability-secure wire.
//!
//! Run it with one command:
//!
//!   zig build accountability
//!
//! Two `driver.Session`s talk over a 127.0.0.1 socket pair on a
//! `std.Io.Threaded` backend. The host accepts on a concurrent fiber, the caller
//! drives this one. The host publishes the Affordance by name. The caller fetches
//! it and eventual-sends an `invoke`. Attribution is not a trusted
//! header: the caller signs the request with its KERI key and sends the key event
//! log that binds that key to its AID, and the host refuses to account for an
//! invocation it cannot attest or cannot bind. That signed attribution is the
//! thing an ambient-authority HTTP call structurally cannot produce. See
//! `../http-comparison.md`.

const std = @import("std");
const glowcap = @import("glowcap");

const identity = @import("identity.zig");
const said = @import("said.zig");
const accountable = @import("accountable.zig");
const affordance = @import("affordance.zig");
const log = @import("log.zig");

/// Finite budgets for the listen and the dial below: a partner that connects
/// and then goes silent fails the run instead of hanging it.
const session_opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const tcp = glowcap.net.tcp;

const AFFORDANCE_NAME = affordance.AFFORDANCE_NAME;
const frame_cap = affordance.frame_cap;

const HostArgs = struct {
    server: *driver.Server,
    store: *accountable.Store,
    served: *usize,
    last_subject: *[said.SAID_LEN]u8,
};

/// Accept one connection, publish the Affordance by name, and serve invocations
/// until the caller leaves.
fn hostServe(args: HostArgs) !void {
    var vat = try args.server.accept();
    defer vat.deinit();

    _ = try vat.publish(AFFORDANCE_NAME, affordance.HostAffordance, .{
        .state = .{
            .store = args.store,
            .served = args.served,
            .last_subject = args.last_subject,
        },
    });

    try vat.serve();
}

fn banner(step: u8, msg: []const u8) void {
    std.debug.print("[{d}/9] {s}\n", .{ step, msg });
}

/// Drive one capability invocation to its settled outcome over the live
/// session (the driver's `call` materializes both arms into `arena`).
///
/// `key` is the key the caller signs with, which is not always the one its log
/// makes authoritative: passing a retired pre-rotation key is how the run shows
/// the host refusing a key the log has moved past. `tamper` corrupts the
/// signature instead, so the host cannot attest it at all. Both refusals must
/// surface as clean broken promises, not a crash or a silent success.
fn invoke(
    cv: *driver.Session,
    target: driver.Capability,
    caller: *const identity.Identity,
    key: said.Key,
    request: []const u8,
    tamper: bool,
    arena: std.mem.Allocator,
) !driver.Reply {
    const att = try affordance.Attestation.sign(arena, key, &caller.aid, request, tamper);
    return cv.call(target, affordance.invoke_verb, &.{
        .{ .string = caller.aidSlice() },
        .{ .string = &att.verkey },
        .{ .string = request },
        .{ .string = &att.signature },
        .{ .string = caller.kelSlice() },
    }, arena);
}

/// The reason a settled outcome broke, or null if it did not break at all.
fn brokenReason(settled: driver.Reply) ?[]const u8 {
    return switch (settled) {
        .broken => |reason| reason,
        .fulfilled => null,
    };
}

/// Report an assertion the run failed and stop, letting the host fiber finish
/// first so its own error, if it has one, is printed too.
fn bail(
    cv: *driver.Session,
    io: std.Io,
    host_future: anytype,
    comptime msg: []const u8,
) noreturn {
    std.debug.print("      " ++ msg ++ "\n", .{});
    cv.deinit();
    // best-effort: unwind join; this path has already printed the failure and
    // exits nonzero on the next line.
    _ = host_future.await(io) catch {};
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const data_root = affordance.dataRoot(init);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("accountability-on-glowcap\n\n", .{});

    // ---- Identities (above glowcap) -------------------------------------------
    banner(1, "Host vat and caller each incept a KERI-anchored identity");
    var host_id = try identity.Identity.incept(allocator, io);
    defer host_id.deinit();
    var caller_id = try identity.Identity.incept(allocator, io);
    defer caller_id.deinit();
    std.debug.print("      host AID:   {s}\n", .{host_id.aidSlice()});
    std.debug.print("      caller AID: {s}\n", .{caller_id.aidSlice()});

    banner(2, "Caller rotates its key (pre-rotation discipline holds)");
    // Kept so step 7 can present it: after the rotation this key is retired, and
    // the caller's own log is what says so.
    const retired_key = caller_id.current;
    const rot_said = try caller_id.rotate(io);
    std.debug.print("      caller rotated; new key-event SAID: {s}\n", .{&rot_said});

    const host_data_dir = try std.fmt.allocPrint(allocator, "{s}/host", .{data_root});
    defer allocator.free(host_data_dir);
    var host_store = try accountable.Store.init(allocator, io, &host_id, host_data_dir);
    defer host_store.deinit();
    const caller_data_dir = try std.fmt.allocPrint(allocator, "{s}/caller", .{data_root});
    defer allocator.free(caller_data_dir);
    var caller_store = try accountable.Store.init(allocator, io, &caller_id, caller_data_dir);
    defer caller_store.deinit();

    // ---- The capability wire (glowcap) ----------------------------------------
    banner(3, "Host publishes the Affordance behind an OCapN capability");
    var server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, session_opts);
    defer server.deinit();
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const designator = try server.localDesignator(&designator_buf);

    var served: usize = 0;
    var last_subject: [said.SAID_LEN]u8 = undefined;
    var host_future = try io.concurrent(hostServe, .{HostArgs{
        .server = server,
        .store = &host_store,
        .served = &served,
        .last_subject = &last_subject,
    }});

    // Caller side. `driver.connect` completes the keyed handshake before
    // returning.
    var cv = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, try server.advertisedLocator(), .ephemeral, session_opts);
    std.debug.print("      session open over TCP {s}\n", .{designator});

    const affordance_ref = try cv.fetch(AFFORDANCE_NAME);

    // ---- The invocation, accounted on both sides ------------------------------
    const request = "read-thermostat";

    banner(4, "Caller writes an Attempt Episode, then invokes the capability");
    // The Attempt Episode is durable *before* the wire send: intent is
    // recorded first, exactly as the documented seam requires.
    _ = try caller_store.record(.attempt, caller_id.aidSlice(), "demo", request);

    var call_arena = std.heap.ArenaAllocator.init(allocator);
    defer call_arena.deinit();

    const outcome = try invoke(cv, affordance_ref, &caller_id, caller_id.current, request, false, call_arena.allocator());
    const result: []const u8 = switch (outcome) {
        .fulfilled => |arg| affordance.valueString(arg) orelse "",
        .broken => |reason| {
            std.debug.print("      invocation did not resolve fulfilled (reason='{s}')\n", .{reason});
            cv.deinit();
            _ = host_future.await(io) catch |err| std.debug.print("      host fiber error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        },
    };

    banner(5, "Host verifies the attestation and the key's binding, then resolves");
    std.debug.print("      result: {s}\n", .{result});
    _ = try caller_store.record(.outcome, caller_id.aidSlice(), "demo", result);

    banner(6, "A caller it cannot attest is refused: a clean broken promise, no Episode");
    // Same caller, same request, but a corrupted signature: the host must refuse
    // to account for what it cannot attribute. The refusal travels back as a
    // broken promise (not a session abort), and the host writes no Episode for it.
    const served_before = served;
    const tampered = try invoke(cv, affordance_ref, &caller_id, caller_id.current, request, true, call_arena.allocator());
    const tampered_reason = brokenReason(tampered) orelse
        bail(cv, io, &host_future, "a tampered invocation was NOT refused");
    if (served != served_before) {
        bail(cv, io, &host_future, "host accounted for an unattested invocation");
    }
    std.debug.print("      refused: {s}\n", .{tampered_reason});

    banner(7, "A key the caller's own log has retired is refused too");
    // This signature verifies: it is a real signature by a key this caller
    // really held, over this exact subject and request. What fails is the
    // binding. The log the caller presents rotated past that key in step 2, so
    // the host reads the log, arrives at a different current key, and refuses.
    // A leaked pre-rotation key therefore buys its holder nothing.
    const retired = try invoke(cv, affordance_ref, &caller_id, retired_key, request, false, call_arena.allocator());
    const retired_reason = brokenReason(retired) orelse
        bail(cv, io, &host_future, "a retired pre-rotation key was NOT refused");
    if (served != served_before) {
        bail(cv, io, &host_future, "host accounted for an invocation signed by a retired key");
    }
    std.debug.print("      refused: {s}\n", .{retired_reason});

    // Let the host observe EOF and finish.
    cv.deinit();
    _ = host_future.await(io) catch |err| {
        std.debug.print("      host fiber error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    banner(8, "Host's Outcome Episode attributes the attested caller");
    if (served == 0) {
        std.debug.print("      host served no invocation\n", .{});
        std.process.exit(1);
    }
    const attributed = std.mem.eql(u8, &last_subject, caller_id.aidSlice());
    std.debug.print("      host attributed: {s}\n", .{&last_subject});
    std.debug.print("      matches caller AID: {}\n", .{attributed});
    if (!attributed) std.process.exit(1);

    // ---- Audit -----------------------------------------------------------------
    banner(9, "Every Episode is auditable; transparency roots are stable");
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
        \\accountability-on-glowcap OK: a capability invocation crossed a real
        \\OCapN session on the `tcp` netlayer between two glowcap peers, and the host produced a
        \\verifiable Episode attributing the attested caller. glowcap hosted the
        \\wire; identity, Episodes, and the transparency log stayed above it.
        \\
        \\The host attributed that Episode to an AID it resolved for itself: the
        \\caller's key event log arrived with the request, the AID is the digest of
        \\that log's inception event, and the key that signed the request is the one
        \\the log's rotations end on. What the host still takes on faith is that the
        \\log it was handed is the whole log. Witness receipts and cross-session
        \\state are what would settle that; see "Limits" in the README and the
        \\design note for details.
        \\
    , .{});
}
