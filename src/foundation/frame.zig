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

    /// The callback that releases storage glowcap didn't allocate. See `initExternal`.
    pub const ExternalReleaseFn = *const fn (*anyopaque) void;

    const Owner = union(enum) {
        allocator: AllocatorOwner,
        external: ExternalOwner,
    };

    const AllocatorOwner = struct {
        allocator: std.mem.Allocator,
        /// The alignment this storage was allocated with. We track it so the
        /// free matches the allocation. It's kept separate from `shape`
        /// because a `byte` frame might be over-aligned, and it should still
        /// free with the alignment it was really allocated under.
        storage_alignment: std.mem.Alignment,
        /// Bytes of private head in front of `storage` in the same block. See
        /// `initHeaded`. Zero for a frame adopted through `initOwned`.
        head_len: u16 = 0,
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

    /// Copy `wire` into a fresh block that also holds one `Head` in front of
    /// it, so what a layer learns about the bytes (the engine keeps the parse
    /// there) lives and dies with them in one allocation. `head` reads it
    /// back. The block is aligned for both the head and the shape, and the
    /// wire bytes start at a shape-aligned offset. Ownership is the frame's
    /// from the first byte: a shape refusal frees the block before returning.
    /// One pointer before the head identifies the head and tail types exactly.
    /// Keeping it in this block costs one pointer plus alignment padding, rather than
    /// growing every `Frame`, including frames with no head. It needs no
    /// separate allocation.
    pub fn initHeaded(
        allocator: std.mem.Allocator,
        comptime Head: type,
        comptime Tail: type,
        tail_len: usize,
        wire: []const u8,
        shape: FrameShape,
    ) (Error || std.mem.Allocator.Error)!Frame {
        // One block holds a type-descriptor pointer, the head slot, then
        // `tail_len` values of `Tail`, then the wire bytes. A layer that learns something about the
        // bytes, such as the decoded parse and its argument views, stores it
        // there, and it is freed with the bytes. The head is padded so the
        // bytes still start at an aligned offset.
        const block_len = try headedBlockLen(Head, Tail, tail_len, wire.len, shape);
        const head_len = block_len - wire.len;
        const alignment = headAlignment(Head, Tail, shape);
        const block = allocator.rawAlloc(block_len, alignment, @returnAddress()) orelse
            return error.OutOfMemory;
        @as(**const HeadTypes, @ptrCast(@alignCast(block))).* = headTypes(Head, Tail);
        const storage = block[head_len..][0..wire.len];
        @memcpy(storage, wire);
        validateShape(storage, shape) catch |err| {
            freeStorage(allocator, block[0 .. head_len + wire.len], alignment);
            return err;
        };
        return .{
            .storage = storage,
            .shape = shape,
            .owner = .{
                .allocator = .{
                    .allocator = allocator,
                    .storage_alignment = alignment,
                    .head_len = @intCast(head_len),
                },
            },
        };
    }

    /// The one block `initHeaded` allocates: type identity, head, tail, shape
    /// padding, and the wire bytes. Refuses lengths that overflow or whose
    /// head and tail do not fit the frame's metadata.
    pub fn headedBlockLen(comptime Head: type, comptime Tail: type, tail_len: usize, wire_len: usize, shape: FrameShape) std.mem.Allocator.Error!usize {
        return std.math.add(usize, try headLen(Head, Tail, tail_len, shape), wire_len) catch error.OutOfMemory;
    }

    /// The `Head` this frame was allocated with through `initHeaded`, or null
    /// for a frame that carries none or was built for another type. The pointer is
    /// good for as long as the frame is.
    pub fn head(self: *const Frame, comptime Head: type) ?*Head {
        const types = self.headTypesOf() orelse return null;
        if (types.head != typeIdentity(Head)) return null;
        const base = self.storage.ptr - self.owner.allocator.head_len;
        return @ptrCast(@alignCast(base + headOffset(Head)));
    }

    /// The tail of `Tail` values behind the head, empty for a frame built
    /// without one or with different head or tail types. A tail element is at
    /// least a word, so shape padding is never mistaken for an element.
    pub fn headTail(self: *const Frame, comptime Head: type, comptime Tail: type) []Tail {
        return if (self.headed(Head, Tail)) |slot| slot.tail else &.{};
    }

    /// What `headed` returns: the head and the tail it fronts.
    pub fn Headed(comptime Head: type, comptime Tail: type) type {
        return struct { head: *Head, tail: []Tail };
    }

    /// `head` and `headTail` in one walk, for a reader that fills both.
    pub fn headed(self: *const Frame, comptime Head: type, comptime Tail: type) ?Headed(Head, Tail) {
        comptime std.debug.assert(@sizeOf(Tail) >= 8);
        const types = self.headTypesOf() orelse return null;
        if (types.head != typeIdentity(Head) or types.tail != typeIdentity(Tail)) return null;
        const owner = self.owner.allocator;
        const offset = tailOffset(Head, Tail);
        const len = (owner.head_len - offset) / @sizeOf(Tail);
        const base = self.storage.ptr - owner.head_len;
        return .{
            .head = @ptrCast(@alignCast(base + headOffset(Head))),
            .tail = @as([*]Tail, @ptrCast(@alignCast(base + offset)))[0..len],
        };
    }

    fn headTypesOf(self: *const Frame) ?*const HeadTypes {
        const owner = switch (self.owner) {
            .allocator => |owner| owner,
            .external => return null,
        };
        if (owner.head_len == 0) return null;
        const base = self.storage.ptr - owner.head_len;
        return @as(*const *const HeadTypes, @ptrCast(@alignCast(base))).*;
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
            .allocator => |owner| freeStorage(
                owner.allocator,
                (self.storage.ptr - owner.head_len)[0 .. owner.head_len + self.storage.len],
                owner.storage_alignment,
            ),
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

const HeadTypes = struct {
    head: *const u8,
    tail: *const u8,
};

fn headTypes(comptime Head: type, comptime Tail: type) *const HeadTypes {
    const Types = struct {
        const value: HeadTypes = .{ .head = typeIdentity(Head), .tail = typeIdentity(Tail) };
    };
    return &Types.value;
}

/// A unique address for each Zig type. A type name is not an identity:
/// independently imported modules may declare distinct types with equal names.
fn typeIdentity(comptime T: type) *const u8 {
    const Identity = struct {
        // Mutable storage gives each type a distinct address even when a
        // linker merges equal constants. No code reads or writes its value.
        var token: u8 = 0;
        comptime {
            _ = T;
        }
    };
    return &Identity.token;
}

fn headOffset(comptime Head: type) usize {
    return std.mem.alignForward(usize, @sizeOf(*const HeadTypes), @alignOf(Head));
}

fn tailOffset(comptime Head: type, comptime Tail: type) usize {
    return std.mem.alignForward(usize, headOffset(Head) + @sizeOf(Head), @alignOf(Tail));
}

fn headLen(comptime Head: type, comptime Tail: type, tail_len: usize, shape: FrameShape) std.mem.Allocator.Error!usize {
    comptime std.debug.assert(@sizeOf(Head) <= std.math.maxInt(u16));
    const tail_bytes = std.math.mul(usize, tail_len, @sizeOf(Tail)) catch return error.OutOfMemory;
    const used = std.math.add(usize, tailOffset(Head, Tail), tail_bytes) catch return error.OutOfMemory;
    const alignment = shapeAlignment(shape);
    // Bound the padded head before rounding, so alignment cannot overflow.
    if (used > alignment.backward(std.math.maxInt(u16))) return error.OutOfMemory;
    return alignment.forward(used);
}

fn headAlignment(comptime Head: type, comptime Tail: type, shape: FrameShape) std.mem.Alignment {
    return shapeAlignment(shape).max(.of(*const HeadTypes)).max(.of(Head)).max(.of(Tail));
}

fn shapeAlignment(shape: FrameShape) std.mem.Alignment {
    return switch (shape) {
        .byte => .fromByteUnits(1),
        .word => .fromByteUnits(8),
    };
}

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
