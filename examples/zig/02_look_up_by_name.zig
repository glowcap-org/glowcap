//! 02 — Look up a service by name.
//!
//! A client fetches a capability through the server's bootstrap object using a
//! swiss-number — the spec-shaped alternative to chapter 01's pre-wiring. The
//! server never writes a fetch handler: it registers `(swissnum -> cap)` and the
//! runtime answers the inbound `'fetch` automatically (ADR-0006 responder half).
//!
//! `fetch.prepareFetchSwissnum` builds the canonical bootstrap-fetch deliver and
//! (on V1.0) the resolver the settlement rides back to; `tryMatchFetchOutcome`
//! turns the partner's settlement — a resolver-callback `op:deliver` on V1.0 —
//! back into a `fulfilled` / `broken` outcome.
//!
//! Run: `zig build examples` (also runs under `zig build check`).

const std = @import("std");
const pancake = @import("pancake");
const model = pancake.model;
const runtime = pancake.runtime;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer if (gpa.deinit() == .leak) @panic("leaked memory");
    const allocator = gpa.allocator();

    var pair = try runtime.factories.paired(allocator);
    defer pair.deinit();
    const client = &pair.p1;
    const server = &pair.p2;

    // The server publishes a thermostat behind a swiss-number. That is the whole
    // server side — no handler, no dispatch loop.
    const swissnum = "thermostat-swiss";
    const cap_export = try server.registerBootstrapCap(swissnum);
    std.debug.print("server published swissnum -> export {d}\n", .{cap_export});

    // The client prepares a bootstrap fetch and drives the wire loop. `send`
    // takes ownership of the prepared (heap-owned) message.
    const prepared = try runtime.fetch.prepareFetchSwissnum(allocator, &client.session_state, swissnum);
    try client.send(prepared.message);
    _ = try client.step();
    try server.feedInbound(client.takeOutbound().?);

    // This step recognizes the fetch, surfaces the deliver event, and enqueues
    // the synthesized resolve; a second step encodes that settlement.
    _ = try server.step();
    {
        var ev = server.pollEvent().?;
        ev.deinit();
    }
    _ = try server.step();
    try client.feedInbound(server.takeOutbound().?);
    _ = try client.step();

    // Match the settlement into an owned outcome.
    var settle = client.pollEvent().?;
    defer settle.deinit();
    const owned = try settle.decodeOwned(allocator);
    const match = try runtime.fetch.tryMatchFetchOutcome(
        allocator,
        prepared.resolver_export,
        prepared.answer_id,
        owned,
    );
    switch (match) {
        .settled => |outcome| switch (outcome) {
            .fulfilled => |reference| {
                defer model.freeReference(allocator, reference);
                // The server fulfilled with its bootstrap export; the perspective
                // flip lands it on the client as the import it now holds.
                const position = switch (reference) {
                    .far => |far| far.import_id,
                    .near => |near| near.export_id,
                    else => return error.UnexpectedReferenceShape,
                };
                std.debug.print("client fetched the thermostat as import {d}\n", .{position});
            },
            .broken => |reason| {
                defer allocator.free(reason);
                std.debug.print("fetch broke: {s}\n", .{reason});
            },
            .malformed => std.debug.print("fetch settlement was malformed\n", .{}),
        },
        .unrelated => |message| {
            model.freeMessage(allocator, message);
            std.debug.print("settlement was unrelated traffic\n", .{});
        },
    }
}
