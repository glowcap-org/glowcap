//! Archive-neutral conversion between the locator POD layout and the OCapN
//! model. The layout stays dependency-free in `locator.zig`. Semantic
//! validation remains model-owned through `model.validatePeerLocator`.

const std = @import("std");
const model = @import("model");
const locator = @import("locator.zig");

pub const ViewError = error{InvalidLocatorView};
pub const CloneViewError = ViewError || std.mem.Allocator.Error;
pub const inline_hint_capacity: usize = 8;

/// Project one C locator view into the model without copying its bytes.
/// Temporary hint entries use caller-provided storage first, so the ordinary
/// callback path stays allocation-free. The returned locator and its bytes
/// remain borrowed from `view` until `deinit`.
pub const BorrowedLocator = struct {
    value: model.PeerLocator,
    heap_hints: ?[]model.HintEntry,

    pub fn init(
        allocator: std.mem.Allocator,
        view: *const locator.GlowcapLocatorView,
        stack: []model.HintEntry,
    ) CloneViewError!BorrowedLocator {
        try validateViewHeader(view);
        const heap_hints = if (view.hint_count > stack.len)
            try allocator.alloc(model.HintEntry, view.hint_count)
        else
            null;
        errdefer if (heap_hints) |owned| allocator.free(owned);
        const hints = if (heap_hints) |owned| owned else stack[0..view.hint_count];
        return .{
            .value = try fromValidatedView(view, hints),
            .heap_hints = heap_hints,
        };
    }

    pub fn deinit(self: *BorrowedLocator, allocator: std.mem.Allocator) void {
        if (self.heap_hints) |owned| allocator.free(owned);
        self.* = undefined;
    }
};

/// Own the hint-view storage needed to project one borrowed model locator.
/// The locator bytes remain borrowed from `value`. Caller-provided storage
/// avoids allocation for small, callback-scoped projections.
pub const Projection = struct {
    view: locator.GlowcapLocatorView,
    heap_hints: ?[]locator.GlowcapLocatorHintView,

    pub fn init(
        allocator: std.mem.Allocator,
        value: model.PeerLocator,
        stack: []locator.GlowcapLocatorHintView,
    ) CloneViewError!Projection {
        model.validatePeerLocator(value) catch return error.InvalidLocatorView;
        const heap_hints = if (value.hints.entries.len > stack.len)
            try allocator.alloc(locator.GlowcapLocatorHintView, value.hints.entries.len)
        else
            null;
        errdefer if (heap_hints) |owned| allocator.free(owned);
        const hints = if (heap_hints) |owned| owned else stack[0..value.hints.entries.len];
        return .{
            .view = try projectValidated(value, hints),
            .heap_hints = heap_hints,
        };
    }

    pub fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        if (self.heap_hints) |owned| allocator.free(owned);
        self.* = undefined;
    }
};

pub fn fromView(
    view: *const locator.GlowcapLocatorView,
    hint_storage: []model.HintEntry,
) ViewError!model.PeerLocator {
    try validateViewHeader(view);
    return fromValidatedView(view, hint_storage);
}

fn fromValidatedView(
    view: *const locator.GlowcapLocatorView,
    hint_storage: []model.HintEntry,
) ViewError!model.PeerLocator {
    if (hint_storage.len != view.hint_count) return error.InvalidLocatorView;
    const transport = try requiredSlice(view.transport, view.transport_len);
    const designator = try requiredSlice(view.designator, view.designator_len);
    const c_hints = if (view.hint_count == 0)
        &.{}
    else
        (view.hints orelse return error.InvalidLocatorView)[0..view.hint_count];
    for (c_hints, hint_storage) |hint, *out| {
        out.name = try requiredSlice(hint.name, hint.name_len);
        out.value = switch (hint.kind) {
            locator.GLOWCAP_HINT_STRING => .{ .string = try optionalSlice(hint.bytes, hint.bytes_len) },
            locator.GLOWCAP_HINT_BYTES => .{ .bytes = try optionalSlice(hint.bytes, hint.bytes_len) },
            locator.GLOWCAP_HINT_BOOLEAN => .{ .boolean = switch (hint.boolean_value) {
                0 => false,
                1 => true,
                else => return error.InvalidLocatorView,
            } },
            locator.GLOWCAP_HINT_INTEGER => .{ .integer = hint.integer_value },
            else => return error.InvalidLocatorView,
        };
    }
    const wire_form: model.Hints.WireForm = switch (view.hint_wire_form) {
        locator.GLOWCAP_HINTS_MAP => .map,
        locator.GLOWCAP_HINTS_BOOLEAN_FALSE => .boolean_false,
        else => return error.InvalidLocatorView,
    };
    const value: model.PeerLocator = .{
        .transport = transport,
        .designator = designator,
        .hints = .{ .entries = hint_storage, .wire_form = wire_form },
    };
    model.validatePeerLocator(value) catch return error.InvalidLocatorView;
    return value;
}

pub fn cloneView(
    allocator: std.mem.Allocator,
    view: *const locator.GlowcapLocatorView,
) CloneViewError!model.PeerLocator {
    var hint_stack: [inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = try BorrowedLocator.init(allocator, view, &hint_stack);
    defer borrowed.deinit(allocator);
    return model.clonePeerLocator(allocator, borrowed.value);
}

pub fn project(
    value: model.PeerLocator,
    hint_storage: []locator.GlowcapLocatorHintView,
) ViewError!locator.GlowcapLocatorView {
    model.validatePeerLocator(value) catch return error.InvalidLocatorView;
    return projectValidated(value, hint_storage);
}

fn projectValidated(
    value: model.PeerLocator,
    hint_storage: []locator.GlowcapLocatorHintView,
) ViewError!locator.GlowcapLocatorView {
    if (hint_storage.len != value.hints.entries.len) return error.InvalidLocatorView;
    for (value.hints.entries, hint_storage) |entry, *out| {
        out.* = .{
            .name = entry.name.ptr,
            .name_len = entry.name.len,
            .kind = undefined,
            .bytes = null,
            .bytes_len = 0,
            .boolean_value = 0,
            .integer_value = 0,
        };
        switch (entry.value) {
            .string => |bytes| {
                out.kind = locator.GLOWCAP_HINT_STRING;
                out.bytes = if (bytes.len == 0) null else bytes.ptr;
                out.bytes_len = bytes.len;
            },
            .bytes => |bytes| {
                out.kind = locator.GLOWCAP_HINT_BYTES;
                out.bytes = if (bytes.len == 0) null else bytes.ptr;
                out.bytes_len = bytes.len;
            },
            .boolean => |boolean| {
                out.kind = locator.GLOWCAP_HINT_BOOLEAN;
                out.boolean_value = @intFromBool(boolean);
            },
            .integer => |integer| {
                out.kind = locator.GLOWCAP_HINT_INTEGER;
                out.integer_value = integer;
            },
        }
    }
    return .{
        .abi_version = locator.GLOWCAP_LOCATOR_VIEW_ABI_VERSION,
        .struct_size = @sizeOf(locator.GlowcapLocatorView),
        .transport = value.transport.ptr,
        .transport_len = value.transport.len,
        .designator = value.designator.ptr,
        .designator_len = value.designator.len,
        .hints = if (hint_storage.len == 0) null else hint_storage.ptr,
        .hint_count = hint_storage.len,
        .hint_wire_form = switch (value.hints.wire_form) {
            .map => locator.GLOWCAP_HINTS_MAP,
            .boolean_false => locator.GLOWCAP_HINTS_BOOLEAN_FALSE,
        },
    };
}

fn requiredSlice(ptr: ?[*]const u8, len: usize) ViewError![]const u8 {
    if (len == 0) return error.InvalidLocatorView;
    return (ptr orelse return error.InvalidLocatorView)[0..len];
}

fn optionalSlice(ptr: ?[*]const u8, len: usize) ViewError![]const u8 {
    if (len == 0) return &.{};
    return (ptr orelse return error.InvalidLocatorView)[0..len];
}

fn validateViewHeader(view: *const locator.GlowcapLocatorView) ViewError!void {
    if (view.abi_version != locator.GLOWCAP_LOCATOR_VIEW_ABI_VERSION or
        view.struct_size < @sizeOf(locator.GlowcapLocatorView) or
        view.hint_count > model.max_locator_hint_count)
        return error.InvalidLocatorView;
}
