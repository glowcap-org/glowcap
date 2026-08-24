//! Terminal ownership when an inbound listen frame is consumed under pressure.

const std = @import("std");
const pancake = @import("pancake");

const session = pancake.ocapn.session;
const peer_fixture = @import("../../support/peer_fixture.zig");

test "consumed listen frame closes when event allocation fails after listener publication" {
    var proved_post_publication_failure = false;

    for (0..32) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var peer = peer_fixture.openPeer(failing.allocator());
        defer {
            failing.fail_index = std.math.maxInt(usize);
            peer.deinit();
        }
        try peer.session_state.installInboundAnswer(.from(7));

        failing.fail_index = failing.alloc_index + offset;
        const attempt = peer.recvBorrowed(.{
            .bytes = "<9'op:listen<11'desc:answer7+><18'desc:import-object9+>3+>",
            .shape = .byte,
        });
        failing.fail_index = std.math.maxInt(usize);

        if (attempt) |_| {
            while (peer.pollEvent()) |event_value| {
                var event = event_value;
                event.deinit();
            }
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            if (peer.session_state.inboundAnswer(.from(7)).?.listeners == 1) {
                proved_post_publication_failure = true;
                try std.testing.expect(peer.sessionIsClosed());
                try std.testing.expect(peer.pollEvent() == null);
                try std.testing.expectError(
                    session.Error.SessionClosed,
                    peer.recvBorrowed(.{
                        .bytes = "<13'op:gc-answers[7+]>",
                        .shape = .byte,
                    }),
                );
            }
        }
    }

    try std.testing.expect(proved_post_publication_failure);
}
