const std = @import("std");
const pancake = @import("pancake");

pub fn example(io: std.Io, allocator: std.mem.Allocator) !void {
    // Key designator, cleartext CapTP. Reuse a seed across restarts to keep the same key.
    var keyed_resident = pancake.net.tcp.keyed.Resident{ .io = io };
    const netlayers = [_]pancake.net.netlayer.Netlayer{keyed_resident.netlayer()};
    var hint_storage: [1]pancake.ocapn.model.HintEntry = undefined;
    const peer_key = "<64 lowercase hex characters from the server>";
    const partner = pancake.net.tcp.keyed.locator(
        peer_key,
        "127.0.0.1:9099",
        &hint_storage,
    );

    // From here, the CapTP workflow is transport-independent.
    const session = try pancake.driver.connect(
        allocator,
        &netlayers,
        partner,
        .ephemeral,
        .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } },
    );
    defer session.deinit();

    const greeter = try session.fetch("greeter"); // a capability this peer published
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const settled = try session.call(greeter, "greet", &.{.{ .string = "world" }}, arena.allocator());
    switch (settled) {
        .fulfilled => |value| std.debug.print("{s}\n", .{value.string}),
        .broken => |reason| std.debug.print("the greeter refused: {s}\n", .{reason}),
    }
}
