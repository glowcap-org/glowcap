//! The one walk a session takes over an outbound tree: what it measures,
//! what it lists, what it refuses, and what it allocates.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;

const near = struct {
    fn ref(position: u64) model.Argument {
        return .{ .reference = .{ .near = .{ .export_position = .from(position) } } };
    }
};

test "an inventory measures what the owned model measures" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();
    var set_items = [_]model.Argument{ near.ref(3), .{ .integer = 9 } };
    var entries = [_]model.StructEntry{
        .{ .key = "a", .value = .{ .set = &set_items } },
        .{ .key = "bb", .value = .{ .string = "hello" } },
    };
    var list_items = [_]model.Argument{ .{ .@"struct" = &entries }, .{ .bytes = &.{ 1, 2, 3 } } };
    var args = [_]model.Argument{ .{ .list = &list_items }, near.ref(4), .{ .symbol = "greet" } };

    const of_args = try s.inventoryArguments(&args);
    defer of_args.deinit(std.testing.allocator);
    try std.testing.expectEqual(try model.measureArgumentSliceOwnedBytes(&args), of_args.owned_bytes);

    const fulfill: model.Resolution = .{ .fulfill = .{ .list = &list_items } };
    const of_fulfill = try s.inventoryResolution(fulfill);
    defer of_fulfill.deinit(std.testing.allocator);
    try std.testing.expectEqual(try model.measureResolutionOwnedBytes(fulfill), of_fulfill.owned_bytes);

    const broken: model.Resolution = .{ .@"break" = .{ .message = "nope" } };
    const of_break = try s.inventoryResolution(broken);
    defer of_break.deinit(std.testing.allocator);
    try std.testing.expectEqual(try model.measureResolutionOwnedBytes(broken), of_break.owned_bytes);
    try std.testing.expectEqual(@as(usize, 0), of_break.slots.len);
}

test "an inventory lists references, handoffs, and sets in tree order" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();
    var set_items = [_]model.Argument{near.ref(3)};
    var list_items = [_]model.Argument{ near.ref(2), .{ .set = &set_items } };
    var args = [_]model.Argument{ near.ref(1), .{ .list = &list_items }, .{ .string = "tail" } };

    const inventory = try s.inventoryArguments(&args);
    defer inventory.deinit(std.testing.allocator);
    // A set is listed after its items, because its uniqueness is certified
    // once shortening has rewritten them.
    const expected = [_]*model.Argument{ &args[0], &list_items[0], &set_items[0], &list_items[1] };
    try std.testing.expectEqual(expected.len, inventory.slots.len);
    for (expected, inventory.slots) |argument, slot| try std.testing.expectEqual(argument, slot.heap);

    // A fulfillment that is itself a reference is the by-value root.
    const root_only = try s.inventoryResolution(.{ .fulfill = near.ref(5) });
    defer root_only.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), root_only.slots.len);
    try std.testing.expect(root_only.slots[0] == .root);
}

test "an inventory refuses nesting past the limit, an empty container included" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();
    s.limits.max_nesting_depth = 2;
    var empty = [_]model.Argument{};
    var inner = [_]model.Argument{.{ .list = &empty }};
    var outer = [_]model.Argument{.{ .list = &inner }};
    var deeper = [_]model.Argument{.{ .list = &outer }};

    // Two containers deep fits, and the third refuses even though it is empty.
    const fits = try s.inventoryArguments(&outer);
    defer fits.deinit(std.testing.allocator);
    try std.testing.expectError(session.Error.NestingTooDeep, s.inventoryArguments(&deeper));
    try std.testing.expectError(session.Error.NestingTooDeep, s.inventoryResolution(.{ .fulfill = .{ .list = &outer } }));
}

test "an inventory refuses a duplicate struct key" {
    var s = session.Session.init(std.testing.allocator);
    defer s.deinit();
    var entries = [_]model.StructEntry{
        .{ .key = "a", .value = .{ .integer = 1 } },
        .{ .key = "a", .value = .{ .integer = 2 } },
    };
    var args = [_]model.Argument{.{ .@"struct" = &entries }};
    try std.testing.expectError(session.Error.DuplicateStructKey, s.inventoryArguments(&args));
}

test "an inventory allocates only for a tree with something to return to" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var s = session.Session.init(failing.allocator());
    defer s.deinit();
    var plain_items = [_]model.Argument{ .{ .integer = 1 }, .{ .string = "two" } };
    var plain = [_]model.Argument{ .{ .list = &plain_items }, .{ .symbol = "greet" } };

    failing.fail_index = failing.alloc_index;
    const nothing = try s.inventoryArguments(&plain);
    nothing.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 0), nothing.slots.len);

    // One reference costs the slot list, and nothing else.
    var one_ref = [_]model.Argument{ .{ .list = &plain_items }, near.ref(1) };
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, s.inventoryArguments(&one_ref));
    failing.fail_index = failing.alloc_index + 1;
    const listed = try s.inventoryArguments(&one_ref);
    defer listed.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 1), listed.slots.len);
}

test "a set whose promises shorten onto one target is refused after the rewrite" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(5));
    try s.registerImport(.from(7));
    const shortening = (try s.nominateShorteningResolver(.from(5))).?;
    try s.validateShorteningCompletion(shortening.resolver_export, model.FarRef.promise(7));
    s.completeShortening(shortening.resolver_export, model.FarRef.promise(7), true);

    // Distinct on entry, so the walk certifies the set as it stands.
    var set_items = [_]model.Argument{
        .{ .reference = .{ .far = model.FarRef.promise(5) } },
        .{ .reference = .{ .far = model.FarRef.promise(7) } },
    };
    var args = [_]model.Argument{.{ .set = &set_items }};
    var message: model.Message = .{ .deliver = .{
        .target = .{ .far = model.FarRef.promise(7) },
        .args = &args,
    } };
    const inventory = try s.inventoryMessage(message);
    defer inventory.deinit(allocator);

    // Shortening folds both onto promise 7, and the send is refused before
    // any export is retained.
    s.rewriteShortenedMessage(&message, inventory);
    try std.testing.expectEqual(model.FarRef.promise(7), set_items[0].reference.far);
    try std.testing.expectError(
        session.Error.DuplicateSetElement,
        s.recordSendInventoried(message, inventory),
    );
}
