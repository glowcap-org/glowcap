//! Operation context preserves the source and reason of a failure.
const std = @import("std");
const failures = @import("glowcap").foundation.break_cause;
const Cause = failures.BreakCause;

test "failure context cannot promote partner prose into a runtime reason" {
    const peer = Cause.partner();
    const fetch = peer.withFetch();
    const restored = fetch.withRestoration();
    try std.testing.expectEqual(.partner, restored.origin);
    try std.testing.expectEqual(.application, restored.reason);
    try std.testing.expect(restored.context.fetch);
    try std.testing.expect(restored.context.restoration);
    try std.testing.expect(peer.isApplication());
    try std.testing.expect(!fetch.isApplication());
    try std.testing.expect(fetch.isPublicationRefusal());
    try std.testing.expect(!restored.isPublicationRefusal());
    try std.testing.expect(!restored.isApplication());
    const missing = Cause.local(.transport_unavailable).withRestoration();
    try std.testing.expectEqual(.transport_unavailable, missing.reason);
    try std.testing.expectEqual(.local, missing.origin);
}

test "nested failure rendering keeps each operation without changing provenance" {
    var first: [failures.Broken.diagnostic_capacity]u8 = undefined;
    var second: [failures.Broken.diagnostic_capacity]u8 = undefined;
    const route = failures.Broken{ .detail = "UnknownTransport", .cause = Cause.local(.transport_unavailable) };
    const restored = failures.Broken{ .detail = route.render(&first), .cause = route.cause.withRestoration() };
    try std.testing.expectEqualStrings("RestorationFailed: ExporterUnreachable: UnknownTransport", restored.render(&second));
    const nested = failures.Broken{ .detail = restored.render(&second), .cause = restored.cause.withRestoration() };
    try std.testing.expectEqualStrings("RestorationFailed: RestorationFailed: ExporterUnreachable: UnknownTransport", nested.render(&first));
    const peer = failures.Broken{ .detail = "UnknownTransport", .cause = Cause.partner().withRestoration() };
    try std.testing.expectEqualStrings("RestorationFailed: UnknownTransport", peer.render(&first));
    try std.testing.expectEqual(.application, peer.cause.reason);
}

test "failure formatting renders provenance and context at the output boundary" {
    var text: [512]u8 = undefined;
    try std.testing.expectEqualStrings("plain refusal", try std.fmt.bufPrint(&text, "{f}", .{failures.Broken.unnamed("plain refusal")}));
    try std.testing.expectEqualStrings("ExporterUnreachable: no connector", try std.fmt.bufPrint(&text, "{f}", .{@as(failures.Broken, .{ .detail = "no connector", .cause = Cause.local(.transport_unavailable) })}));
    try std.testing.expectEqualStrings("PeerIdentityUnverified", try std.fmt.bufPrint(&text, "{f}", .{failures.Broken.partner("PeerIdentityUnverified")}));
}

// Restoration is an outer failure; its route diagnosis remains available as data.
test "failure route queries retain fetch and withdrawal but exclude restoration" {
    for (0..8) |bits| {
        const context: failures.Context = @bitCast(@as(u3, @intCast(bits)));
        for ([_]failures.Reason{ .peer_unreachable, .transport_unavailable, .identity_unverified }) |reason| {
            var cause = Cause.local(reason);
            cause.context = context;
            try std.testing.expectEqual(!context.restoration and reason != .identity_unverified, cause.isExporterUnreachable());
            try std.testing.expectEqual(!context.restoration and reason == .identity_unverified, cause.isPeerIdentityUnverified());
            try std.testing.expectEqual(reason, cause.reason);
        }
    }
}
