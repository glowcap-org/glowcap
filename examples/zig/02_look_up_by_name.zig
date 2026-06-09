//! 02 — Look up a service by name.
//!
//! A client asks the server's bootstrap object for a capability, naming it with a
//! swiss-number. This is the spec-shaped way to do what chapter 01 did by
//! pre-wiring. Notice the server never writes a fetch handler: it just maps the
//! swiss-number to a capability, and the runtime answers the inbound `'fetch` for
//! it on its own (ADR-0006, our side of the exchange).
//!
//! On the client side, `fetch.prepareFetchSwissnum` builds the bootstrap-fetch
//! deliver, plus, on V1.0, the resolver the answer comes back to. Then
//! `tryMatchFetchOutcome` takes the partner's reply (on V1.0 that's a
//! resolver-callback `op:deliver`) and turns it back into a plain fulfilled or
//! broken outcome.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const pancake = @import("pancake");
const model = pancake.model;
const engine = pancake.engine;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer if (gpa.deinit() == .leak) @panic("leaked memory");
    const allocator = gpa.allocator();

    var pair = try engine.pairing.paired(allocator);
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
    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &client.session_state, swissnum);
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
    const match = try engine.fetch.tryMatchFetchOutcome(
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
