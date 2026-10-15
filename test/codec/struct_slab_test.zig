//! Struct storage preserves values and refusals at every frame-head capacity.
const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const view = model.view;
const dispatch = glowcap.ocapn.codec.dispatch;
const messagesEqual = @import("../support/message_equality.zig").messagesEqual;

test "struct slab: mixed containers preserve values at every capacity" {
    const numbers = [_]model.Argument{ .{ .integer = -1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    const inner = [_]model.StructEntry{
        .{ .key = "a", .value = .{ .list = &numbers } },
        .{ .key = "b", .value = .{ .reference = .{ .far = model.FarRef.object(9) } } },
    };
    const mixed = [_]model.Argument{
        .{ .boolean = true },
        .{ .@"struct" = &inner },
        .{ .string = "last" },
    };
    const outer = [_]model.StructEntry{
        .{ .key = "first", .value = .{ .list = &mixed } },
        .{ .key = "other", .value = .{ .tagged = .{ .tag = "tag", .value = &mixed } } },
    };
    const args = [_]model.Argument{ .{ .symbol = "verb" }, .{ .@"struct" = &outer }, .{ .list = &numbers } };
    const message: model.Message = .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &args,
    } };
    for ([_]model.CodecId{ .syrup, .capnp }) |codec| {
        for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
            var frame = try dispatch.encodeMessageForProfile(codec, std.testing.allocator, profile, message);
            defer frame.deinit();
            const plain = try (try dispatch.decodeBodyForProfile(codec, profile, frame.view())).toOwned(std.testing.allocator);
            defer model.freeMessage(std.testing.allocator, plain);
            var storage: [64]view.Argument = undefined;
            const storage_bytes = std.mem.sliceAsBytes(&storage);
            for (0..storage_bytes.len + 1) |capacity| {
                var slab = view.ValueSlab.init(storage_bytes[0..capacity]);
                const body = try dispatch.decodeBodyInto(codec, profile, frame.view(), &slab);
                try std.testing.expectEqual(capacity - capacity % @alignOf(view.Argument), slab.open);
                try std.testing.expect(slab.used <= slab.open);
                if (capacity == storage_bytes.len)
                    try std.testing.expect((try body.deliver.args.at(1)).@"struct".backingViews() != null);
                const owned = try body.toOwned(std.testing.allocator);
                defer model.freeMessage(std.testing.allocator, owned);
                try std.testing.expect(messagesEqual(plain, owned));
            }
        }
    }
}

test "struct slab: malformed singleton key is refused with and without storage" {
    const entries = [_]model.StructEntry{.{ .key = "unique-key", .value = .{ .integer = 1 } }};
    const args = [_]model.Argument{.{ .@"struct" = &entries }};
    for ([_]model.CodecId{ .syrup, .capnp }) |codec| {
        for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
            var frame = try dispatch.encodeMessageForProfile(codec, std.testing.allocator, profile, .{ .deliver = .{
                .target = .{ .far = model.FarRef.object(7) },
                .args = &args,
            } });
            defer frame.deinit();
            const bytes = try std.testing.allocator.dupe(u8, frame.bytes());
            defer std.testing.allocator.free(bytes);
            const index = std.mem.indexOf(u8, bytes, "unique-key") orelse return error.TestUnexpectedResult;
            bytes[index] = 0xff;
            var storage: [8]view.Argument = undefined;
            for (0..storage.len + 1) |capacity| {
                var slab = view.ValueSlab.init(std.mem.sliceAsBytes(storage[0..capacity]));
                const malformed: glowcap.foundation.FrameView = .{ .bytes = bytes, .shape = frame.view().shape };
                try std.testing.expectError(error.MalformedFrame, dispatch.decodeBodyInto(codec, profile, malformed, &slab));
            }
        }
    }
}
