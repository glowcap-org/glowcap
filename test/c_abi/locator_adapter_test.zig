const std = @import("std");

const c = @import("c_abi_shared");
const model = @import("pancake").ocapn.model;

fn integerHint(name: []const u8, value: i64) c.PancakeLocatorHintView {
    return .{
        .name = name.ptr,
        .name_len = name.len,
        .kind = c.PANCAKE_HINT_INTEGER,
        .bytes = null,
        .bytes_len = 0,
        .boolean_value = 0,
        .integer_value = value,
    };
}

fn locatorView(hints: []const c.PancakeLocatorHintView) c.PancakeLocatorView {
    return .{
        .abi_version = c.PANCAKE_LOCATOR_VIEW_ABI_VERSION,
        .struct_size = @sizeOf(c.PancakeLocatorView),
        .transport = "tcp".ptr,
        .transport_len = "tcp".len,
        .designator = "127.0.0.1:1234".ptr,
        .designator_len = "127.0.0.1:1234".len,
        .hints = if (hints.len == 0) null else hints.ptr,
        .hint_count = hints.len,
        .hint_wire_form = c.PANCAKE_HINTS_MAP,
    };
}

test "locator adapters keep the common callback path allocation-free" {
    var hint_views = [_]c.PancakeLocatorHintView{
        integerHint("a", 1),
        integerHint("b", 2),
    };
    const view = locatorView(&hint_views);
    var empty_storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&empty_storage);

    var model_stack: [c.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = try c.locator_adapter.BorrowedLocator.init(fixed.allocator(), &view, &model_stack);
    defer borrowed.deinit(fixed.allocator());
    try std.testing.expectEqual(null, borrowed.heap_hints);
    try std.testing.expectEqual(@as(usize, 2), borrowed.value.hints.entries.len);
    try std.testing.expectEqual(@as(i64, 2), borrowed.value.hints.entries[1].value.integer);

    var c_stack: [c.locator_adapter.inline_hint_capacity]c.PancakeLocatorHintView = undefined;
    var projection = try c.locator_adapter.Projection.init(fixed.allocator(), borrowed.value, &c_stack);
    defer projection.deinit(fixed.allocator());
    try std.testing.expectEqual(null, projection.heap_hints);
    try std.testing.expectEqual(@as(usize, 2), projection.view.hint_count);
    try std.testing.expectEqual(@as(i64, 1), projection.view.hints.?[0].integer_value);
}

test "locator adapters own spill storage for large hint sets" {
    const names = [_][]const u8{ "h0", "h1", "h2", "h3", "h4", "h5", "h6", "h7", "h8" };
    var hint_views: [9]c.PancakeLocatorHintView = undefined;
    for (&hint_views, names, 0..) |*hint, name, i| hint.* = integerHint(name, @intCast(i));
    const view = locatorView(&hint_views);

    var model_stack: [c.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = try c.locator_adapter.BorrowedLocator.init(std.testing.allocator, &view, &model_stack);
    defer borrowed.deinit(std.testing.allocator);
    try std.testing.expect(borrowed.heap_hints != null);
    try std.testing.expectEqual(@as(usize, 9), borrowed.value.hints.entries.len);

    var c_stack: [c.locator_adapter.inline_hint_capacity]c.PancakeLocatorHintView = undefined;
    var projection = try c.locator_adapter.Projection.init(std.testing.allocator, borrowed.value, &c_stack);
    defer projection.deinit(std.testing.allocator);
    try std.testing.expect(projection.heap_hints != null);
    try std.testing.expectEqual(@as(usize, 9), projection.view.hint_count);
    try std.testing.expectEqual(@as(i64, 8), projection.view.hints.?[8].integer_value);
}

test "locator adapters validate the ABI header before sizing scratch storage" {
    var hint_views: [c.locator_adapter.inline_hint_capacity + 1]c.PancakeLocatorHintView = undefined;
    const view = locatorView(&hint_views);
    var invalid = view;
    invalid.abi_version += 1;
    var empty_storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&empty_storage);
    var model_stack: [c.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;

    try std.testing.expectError(
        error.InvalidLocatorView,
        c.locator_adapter.BorrowedLocator.init(fixed.allocator(), &invalid, &model_stack),
    );
}
