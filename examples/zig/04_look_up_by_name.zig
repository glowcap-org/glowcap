//! 04: Look up a service by name.
//!
//! A client asks the server's bootstrap object for a capability, naming it with
//! a swiss-number. This is the engine-level machinery beneath the fetch-by-name
//! that chapter 01 rides. Chapter 05 pre-wires the import by hand instead.
//! The server never writes a fetch handler. It maps the swiss-number to a
//! capability, and the runtime answers the inbound fetch on its own.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer if (gpa.deinit() == .leak) @panic("leaked memory");
    const allocator = gpa.allocator();

    var pair = try engine.pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();
    const client = &pair.p1;
    const server = &pair.p2;

    const swissnum = "thermostat-swiss";
    const cap_export = try server.registerBootstrapCap(swissnum);
    std.debug.print("server published swissnum -> export {d}\n", .{cap_export});

    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &client.session_state, swissnum);
    try client.send(prepared.message);
    _ = try client.step();
    try server.feedOwned(client.takeOutbound().?);

    _ = try server.step();
    {
        var ev = server.pollEvent().?;
        ev.deinit();
    }
    _ = try server.step();
    try client.feedOwned(server.takeOutbound().?);
    _ = try client.step();

    var settle = client.pollEvent().?;
    defer settle.deinit();
    const owned = try settle.decodeOwned(allocator);
    const match = try engine.fetch.tryMatchFetchOutcome(
        allocator,
        prepared.resolver_export,
        prepared.answer_position,
        owned,
    );
    switch (match) {
        .settled => |outcome| switch (outcome) {
            .fulfilled => |reference| {
                defer model.freeReference(allocator, reference);
                const position = switch (reference) {
                    .far => |far| far.import_position.int(),
                    .near => |near| near.export_position.int(),
                    else => return error.UnexpectedReferenceShape,
                };
                std.debug.print("client fetched the thermostat as import {d}\n", .{position});
            },
            // Each of these is a failed lookup, so each one fails the run.
            // This example runs under `zig build examples`; printing a problem
            // and exiting zero tells the gate the chapter worked.
            .broken => |reason| {
                defer allocator.free(reason);
                std.debug.print("fetch broke: {s}\n", .{reason});
                return error.FetchBroke;
            },
            .malformed => {
                std.debug.print("fetch settlement was malformed\n", .{});
                return error.MalformedSettlement;
            },
        },
        .unrelated => |message| {
            model.freeMessage(allocator, message);
            std.debug.print("settlement was unrelated traffic\n", .{});
            return error.UnrelatedSettlement;
        },
    }
}
