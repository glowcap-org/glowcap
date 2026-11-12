//! The terminal callback error selects its diagnostic, in every callback phase.
const std = @import("std");
const f = @import("fixture.zig");

const Failure = struct {
    materialize: bool,
    application_first: bool,
    return_application: bool,
    bare: bool,

    fn invoke(call: *f.hosting.Call, _: f.loam.core.RecordView, _: []const u8, _: []const f.driver.Value) !f.driver.Value {
        const self: *Failure = @ptrCast(@alignCast(call.context.?));
        if (!self.materialize) return result(call);
        call.result = result;
        return .{ .void = {} };
    }

    fn result(call: *f.hosting.Call) !f.driver.Value {
        const self: *Failure = @ptrCast(@alignCast(call.context.?));
        if (self.bare) return error.RestorationFailed;
        if (self.application_first) try call.refuseCopying("application declined");
        try std.testing.expectEqual(error.RestorationFailed, call.restorationFailed(.{ .detail = "no route", .cause = f.driver.BreakCause.local(.transport_unavailable) }));
        // A second restoration cannot overwrite the first diagnostic.
        try std.testing.expectEqual(error.RestorationFailed, call.restorationFailed(f.driver.Broken.unnamed("later failure")));
        if (!self.application_first) try call.refuseCopying("application declined");
        return if (self.return_application) error.ApplicationRefused else error.RestorationFailed;
    }
};

test "loam terminal failure selects independent candidates through invocation and materialization" {
    for ([_]bool{ false, true }) |materialize| {
        for ([_]bool{ false, true }) |application_first| {
            for ([_]bool{ false, true }) |return_application| {
                var fixture: f.Fixture = undefined;
                try fixture.init(.{});
                defer fixture.deinit();
                var failure: Failure = .{ .materialize = materialize, .application_first = application_first, .return_application = return_application, .bare = false };
                const behaviors = [_]f.hosting.Behavior{.{ .schema = 7, .context = &failure, .invoke = Failure.invoke }};
                fixture.attached.behaviors = &behaviors;
                const call = try fixture.host.callLocalCapability(std.testing.allocator, fixture.root, "fail", &.{}, 4096);
                defer call.deinit();
                try fixture.drain();
                const failed = call.result().failed;
                try std.testing.expectEqual(if (return_application) f.driver.BreakCause.local(.application) else f.driver.BreakCause.local(.transport_unavailable).withRestoration(), failed.cause);
                try std.testing.expectEqualStrings(if (return_application) "application declined" else "ExporterUnreachable: no route", failed.message);
                try std.testing.expectEqual(@as(usize, 0), fixture.attached.pending_bytes);
                try std.testing.expectEqual(@as(u64, 1), fixture.data.store.metadata.revision);
            }
        }
    }
}

test "loam terminal restoration without a diagnostic renders its label once" {
    for ([_]bool{ false, true }) |materialize| {
        var fixture: f.Fixture = undefined;
        try fixture.init(.{});
        defer fixture.deinit();
        var failure: Failure = .{ .materialize = materialize, .application_first = false, .return_application = false, .bare = true };
        const behaviors = [_]f.hosting.Behavior{.{ .schema = 7, .context = &failure, .invoke = Failure.invoke }};
        fixture.attached.behaviors = &behaviors;
        const call = try fixture.host.callLocalCapability(std.testing.allocator, fixture.root, "fail", &.{}, 4096);
        defer call.deinit();
        try fixture.drain();
        const failed = call.result().failed;
        try std.testing.expectEqualStrings("", failed.message);
        var buffer: [f.driver.Broken.diagnostic_capacity]u8 = undefined;
        try std.testing.expectEqualStrings("RestorationFailed", (f.driver.Broken{ .detail = failed.message, .cause = failed.cause }).render(&buffer));
        try std.testing.expect(call.result().failed.cause.context.restoration);
    }
}
