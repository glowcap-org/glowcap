//! A frame is a chunk of wire bytes, and this file pins down who owns it.
//!
//! Ownership comes in two shapes. A `Frame` owns its bytes and frees them when
//! it's done. A `FrameView` only borrows them, and only for the length of a
//! single call. Production code either moves an owned frame or takes a brief
//! borrow. It never copies behind your back. The copy helpers you'd want for a
//! test live in `test/support`, not in here.

const std = @import("std");

/// How a frame's bytes are laid out. We keep this explicit so the core never
/// quietly treats one layout as the other.
///
/// Syrup works in plain bytes, so its frames are `byte`. Cap'n Proto works in
/// 8-byte words, so its frames are `word`: the pointer is aligned to 8 and the
/// length is a multiple of 8.
pub const FrameShape = enum {
    byte,
    word,
};

/// A borrowed look at a frame's bytes, good only for the call you were handed it
/// in. It owns nothing and allocates nothing. Don't stash one in session state,
/// because the bytes can vanish out from under you. You get one from `Frame.view`.
pub const FrameView = struct {
    bytes: []const u8,
    shape: FrameShape,
};

/// Wire bytes with exactly one owner: this frame. Whoever allocated the storage
/// is who releases it. `deinit` frees it back through whichever path created the
/// frame, carrying the metadata it needs to free correctly.
pub const Frame = struct {
    pub const Error = error{
        InvalidFrameShape,
    };

    storage: []u8,
    shape: FrameShape,
    owner: Owner,

    /// The callback that releases storage pancake didn't allocate. See `initExternal`.
    pub const ExternalReleaseFn = *const fn (*anyopaque) void;

    const Owner = union(enum) {
        allocator: AllocatorOwner,
        external: ExternalOwner,
    };

    const AllocatorOwner = struct {
        allocator: std.mem.Allocator,
        /// The alignment this storage was allocated with. We track it so the
        /// free matches the allocation exactly. It's kept separate from `shape`
        /// on purpose: a `byte` frame might be over-aligned, and it should still
        /// free with the alignment it was really allocated under.
        storage_alignment: std.mem.Alignment,
    };

    const ExternalOwner = struct {
        context: *anyopaque,
        release: ExternalReleaseFn,
    };

    /// Take ownership of `storage` as it is, with no copy. Pass the alignment it
    /// was allocated with as `storage_alignment`, and `deinit` will free it with
    /// that same alignment, so a `word` frame's 8-byte allocation comes back
    /// cleanly. Ownership transfers unconditionally: if the bytes don't actually
    /// fit `shape`, the storage is freed right here and you get
    /// `Error.InvalidFrameShape`. Either way, the caller owns nothing afterward.
    pub fn initOwned(
        allocator: std.mem.Allocator,
        storage: []u8,
        shape: FrameShape,
        storage_alignment: std.mem.Alignment,
    ) Error!Frame {
        validateShape(storage, shape) catch |err| {
            freeStorage(allocator, storage, storage_alignment);
            return err;
        };
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

    /// Wrap storage that something else owns, like a host buffer, an mmap, or
    /// another runtime, without copying it. Instead of freeing, `deinit` calls
    /// your `release` with `context`, and what that means is up to you.
    /// Ownership transfers unconditionally: if the bytes don't fit `shape`,
    /// `release(context)` is called right here and you get
    /// `Error.InvalidFrameShape`. Either way, the caller owns nothing afterward.
    pub fn initExternal(
        storage: []u8,
        shape: FrameShape,
        context: *anyopaque,
        release: ExternalReleaseFn,
    ) Error!Frame {
        validateShape(storage, shape) catch |err| {
            release(context);
            return err;
        };
        return .{
            .storage = storage,
            .shape = shape,
            .owner = .{ .external = .{ .context = context, .release = release } },
        };
    }

    /// Let the storage go. An allocator-owned frame is freed with the alignment
    /// it remembered. An external frame gets its `release` called. The frame is
    /// left undefined afterward, so a second `deinit` or a late read trips the
    /// debug-mode poison instead of quietly using freed bytes.
    pub fn deinit(self: *Frame) void {
        switch (self.owner) {
            .allocator => |owner| freeStorage(owner.allocator, self.storage, owner.storage_alignment),
            .external => |owner| owner.release(owner.context),
        }
        self.* = undefined;
    }

    /// Read the frame's bytes as a const slice. They're good for as long as the
    /// frame is. Nothing is allocated, and nothing changes hands.
    pub fn bytes(self: *const Frame) []const u8 {
        return self.storage;
    }

    /// Hand out a `FrameView` over these bytes. No allocation, no copy. The view
    /// is only good while this frame is still around.
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
