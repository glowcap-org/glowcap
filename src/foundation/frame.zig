const std = @import("std");

pub const FrameShape = enum {
    byte,
    word,
};

pub const FrameView = struct {
    bytes: []const u8,
    shape: FrameShape,
};

pub const Frame = struct {
    pub const Error = error{
        InvalidFrameShape,
    };

    storage: []u8,
    shape: FrameShape,
    owner: Owner,

    pub const ExternalReleaseFn = *const fn (*anyopaque) void;

    const Owner = union(enum) {
        allocator: AllocatorOwner,
        external: ExternalOwner,
    };

    const AllocatorOwner = struct {
        allocator: std.mem.Allocator,
        storage_alignment: std.mem.Alignment,
    };

    const ExternalOwner = struct {
        context: *anyopaque,
        release: ExternalReleaseFn,
    };

    pub fn initOwned(
        allocator: std.mem.Allocator,
        storage: []u8,
        shape: FrameShape,
        storage_alignment: std.mem.Alignment,
    ) Error!Frame {
        try validateShape(storage, shape);
        return .{
            .storage = storage,
            .shape = shape,
            .owner = .{
                .allocator = .{
                    .allocator = allocator,
                    .storage_alignment = storage_alignment,
                },
            },
        };
    }

    pub fn initExternal(
        storage: []u8,
        shape: FrameShape,
        context: *anyopaque,
        release: ExternalReleaseFn,
    ) Error!Frame {
        try validateShape(storage, shape);
        return .{
            .storage = storage,
            .shape = shape,
            .owner = .{ .external = .{ .context = context, .release = release } },
        };
    }

    pub fn deinit(self: *Frame) void {
        switch (self.owner) {
            .allocator => |owner| freeStorage(owner.allocator, self.storage, owner.storage_alignment),
            .external => |owner| owner.release(owner.context),
        }
    }

    pub fn bytes(self: *const Frame) []const u8 {
        return self.storage;
    }

    pub fn view(self: *const Frame) FrameView {
        return .{
            .bytes = self.storage,
            .shape = self.shape,
        };
    }
};

fn freeStorage(allocator: std.mem.Allocator, storage: []u8, alignment: std.mem.Alignment) void {
    if (storage.len == 0) {
        return;
    }
    @memset(storage, undefined);
    allocator.rawFree(storage, alignment, @returnAddress());
}

fn validateShape(bytes: []const u8, shape: FrameShape) Frame.Error!void {
    switch (shape) {
        .byte => {},
        .word => {
            if (bytes.len % 8 != 0) {
                return Frame.Error.InvalidFrameShape;
            }
            if (bytes.len != 0 and !std.mem.Alignment.fromByteUnits(8).check(@intFromPtr(bytes.ptr))) {
                return Frame.Error.InvalidFrameShape;
            }
        },
    }
}
