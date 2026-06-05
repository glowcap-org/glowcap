//! Frame ownership: the byte-storage primitive every protocol layer moves.
//!
//! `Frame` owns wire bytes; `FrameView` borrows them for a bounded call scope.
//! Production paths move owned frames or take bounded borrows — never a hidden
//! copy. Copy helpers live in `test/support`, not here.

const std = @import("std");

/// How a frame's storage is laid out, kept explicit so a codec-neutral core
/// never flattens one shape into the other.
///
/// - `byte`: ordinary byte storage (Syrup is byte-framed).
/// - `word`: word-aligned storage — pointer aligned to 8, byte length divisible
///   by 8 (Cap'n Proto is word-framed).
pub const FrameShape = enum {
    byte,
    word,
};

/// A borrowed view over a frame's bytes, valid only for the call scope that was
/// handed it. Holds no owner and allocates nothing; session state must never
/// retain one. Obtain with [`Frame.view`].
pub const FrameView = struct {
    bytes: []const u8,
    shape: FrameShape,
};

/// Owned wire bytes with a single visible owner. The owner that allocated
/// releases — `deinit` frees through whichever ownership path constructed the
/// frame, with the metadata needed to free correctly.
pub const Frame = struct {
    pub const Error = error{
        InvalidFrameShape,
    };

    storage: []u8,
    shape: FrameShape,
    owner: Owner,

    /// Release hook for externally-owned storage; see [`initExternal`].
    pub const ExternalReleaseFn = *const fn (*anyopaque) void;

    const Owner = union(enum) {
        allocator: AllocatorOwner,
        external: ExternalOwner,
    };

    const AllocatorOwner = struct {
        allocator: std.mem.Allocator,
        /// The alignment the storage was allocated with — tracked so the free
        /// matches the allocation. Decoupled from `shape`: a `byte` frame may be
        /// over-aligned and still frees with its true allocation metadata.
        storage_alignment: std.mem.Alignment,
    };

    const ExternalOwner = struct {
        context: *anyopaque,
        release: ExternalReleaseFn,
    };

    /// Adopt allocator-owned `storage` without copying. `storage_alignment` is
    /// the alignment `storage` was allocated with — `deinit` frees with it, so a
    /// `word` frame's 8-byte allocation is reclaimed correctly. Rejects storage
    /// whose layout violates `shape` ([`Error.InvalidFrameShape`]).
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

    /// Adopt storage owned elsewhere (a host buffer, an mmap, another runtime)
    /// without copying. `deinit` hands `context` to `release` instead of freeing;
    /// the external owner decides what that means. Rejects storage whose layout
    /// violates `shape` ([`Error.InvalidFrameShape`]).
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

    /// Release the storage through its ownership path: an allocator-owned frame
    /// is freed with its tracked alignment; an external frame's `release` is
    /// invoked. Call exactly once.
    pub fn deinit(self: *Frame) void {
        switch (self.owner) {
            .allocator => |owner| freeStorage(owner.allocator, self.storage, owner.storage_alignment),
            .external => |owner| owner.release(owner.context),
        }
    }

    /// Borrow the frame's bytes as a const slice for the frame's lifetime. No
    /// allocation, no ownership transfer.
    pub fn bytes(self: *const Frame) []const u8 {
        return self.storage;
    }

    /// Borrow a [`FrameView`] over the frame's bytes — no allocation, no copy.
    /// The view is valid only while this frame is.
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
