//! Deterministic TLS runtime owner/child lifetime evidence.

const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;
const runtime = pancake.net.tls.runtime;
const runtime_owner = pancake.net.tls.runtime_owner;

const Fake = struct {
    opens: usize = 0,
    closes: usize = 0,
    refuse_close_once: bool = false,

    fn erased(self: *Fake) runtime.Runtime {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn open(raw: *anyopaque, _: []const u8) runtime.OpenOutcome {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.opens += 1;
        return .{ .failed = .init(.handshake, error.InjectedOpenRefusal) };
    }

    fn sameConfiguration(left: *anyopaque, right: *anyopaque) bool {
        return left == right;
    }

    fn deinitOutcome(raw: *anyopaque) ?foundation.FailureChain {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.closes += 1;
        if (self.refuse_close_once) {
            self.refuse_close_once = false;
            return .init(error.InjectedRuntimeCloseRefusal);
        }
        return null;
    }

    const vtable: runtime.Runtime.VTable = .{
        .open = open,
        .same_configuration = sameConfiguration,
        .deinit_outcome = deinitOutcome,
    };
};

test "runtime owner remains the final failure recipient" {
    var fake = Fake{ .refuse_close_once = true };
    var erased = fake.erased();
    var owner = try runtime_owner.Owner.init(std.testing.allocator, &erased);
    var child = try owner.lease();

    try std.testing.expect(owner.release() == .busy);
    try std.testing.expectEqual(@as(usize, 0), fake.closes);
    const opened = child.open("relay.example");
    try std.testing.expectEqualStrings(
        "InjectedOpenRefusal",
        opened.failed.chain.primaryName(),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.opens);

    child.release();
    const refused = owner.release();
    try std.testing.expectEqualStrings(
        "InjectedRuntimeCloseRefusal",
        refused.failed.primaryName(),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.closes);
    try std.testing.expect(owner.release() == .released);
    try std.testing.expectEqual(@as(usize, 2), fake.closes);
}

test "runtime owner initialization refusal preserves caller ownership" {
    var fake = Fake{};
    var erased = fake.erased();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        runtime_owner.Owner.init(failing.allocator(), &erased),
    );
    try std.testing.expectEqual(fake.erased().ctx, erased.ctx);
    try std.testing.expect(erased.deinitOutcome() == null);
}
