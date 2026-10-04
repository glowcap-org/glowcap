//! Stable attachment routing over one Host and Store. The embedding
//! registers each restoration owner; stored strong edges retain its dependencies
//! even before that owner is registered during restart.
const std = @import("std");
const h = @import("attachment.zig");
const driver = @import("driver_core");
const core = @import("loam_core");

pub const Scope = struct {
    allocator: std.mem.Allocator,
    slots: []?*h.Attachment,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Scope {
        if (capacity == 0) return error.InvalidLimits;
        const slots = try allocator.alloc(?*h.Attachment, capacity);
        @memset(slots, null);
        return .{ .allocator = allocator, .slots = slots };
    }

    pub fn deinit(self: *Scope) !void {
        for (self.slots) |slot| if (slot != null) return error.Busy;
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn register(self: *Scope, owner: *h.Attachment) !void {
        const name = owner.options.attachment_name orelse return error.InvalidAttachmentName;
        if (name.len == 0 or name.len > 128) return error.InvalidAttachmentName;
        for (self.slots) |slot| if (slot) |prior| {
            if (prior.host != owner.host or prior.store != owner.store) return error.ForeignStore;
            if (std.mem.eql(u8, prior.options.attachment_name.?, name)) return error.DuplicateAttachment;
        };
        for (self.slots) |*slot| if (slot.* == null) {
            slot.* = owner;
            return;
        };
        return error.AttachmentCapacity;
    }

    pub fn unregister(self: *Scope, owner: *h.Attachment) void {
        for (self.slots) |*slot| if (slot.* == owner) {
            slot.* = null;
            return;
        };
        unreachable;
    }

    pub fn find(self: *Scope, name: []const u8) ?*h.Attachment {
        for (self.slots) |slot| if (slot) |owner| {
            if (std.mem.eql(u8, owner.options.attachment_name.?, name)) return owner;
        };
        return null;
    }

    pub const Captured = struct { attachment: []const u8, target: core.ObjectId };

    /// A live capability proves which restoration owner may save this target.
    pub fn capture(self: *Scope, owner: *h.Attachment, capability: driver.Capability) !Captured {
        for (self.slots) |slot| if (slot) |candidate| {
            if (candidate.host != owner.host or candidate.store != owner.store) return error.ForeignStore;
            const entry = candidate.entryFor(capability) catch |err| {
                if (err == error.NotDurable) continue;
                return err;
            };
            return .{ .attachment = candidate.options.attachment_name.?, .target = entry.id };
        };
        return error.NotDurable;
    }
};
