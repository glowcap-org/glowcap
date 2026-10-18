//! Terminal eligibility reuses current grant authority and control dependencies.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const Read = @import("read.zig").Read;
const Step = @import("read.zig").Step;
const Load = @import("load.zig").Load;

pub const Probe = struct {
    read: *Read,
    cursor: ?loam.ObjectId,
    grant: ?core.GrantId = null,
    role: ?records.CapabilityRecord.Role = null,
    depth: usize = 0,
    load: Load = .{},
    terminal: bool = false,
    ready: bool = false,

    pub fn advance(self: *Probe) !Step {
        try self.read.current();
        if (self.ready) return .ready;
        if (self.read.header.lifecycle != .active) {
            self.terminal = true;
            self.ready = true;
            return .ready;
        }
        while (self.cursor) |id| {
            if (self.depth > self.read.header.max_grant_depth) return error.DepthLimit;
            const loaded = switch (try self.load.resolve(self.read.store, id)) {
                .read => |request| return .{ .read = request },
                .waiting => return .waiting,
                .ready => |row| row,
            };
            defer loaded.release(self.read.store);
            if (loaded.view.schema == records.profile.terminal) {
                if ((try records.TerminalRecord.decode(loaded.view)).kind != .capability) return error.InvalidRecord;
                self.terminal = true;
                self.ready = true;
                return .ready;
            }
            var scratch: [records.CapabilityRecord.selection_bytes]u8 align(@alignOf(core.ResourceId)) = undefined;
            var fixed = std.heap.FixedBufferAllocator.init(&scratch);
            var descriptor: records.CapabilityRecord = undefined;
            try descriptor.decodeOwned(fixed.allocator(), loaded.view);
            defer descriptor.deinit(fixed.allocator());
            if (!descriptor.owner.eql(self.read.owner_object) or descriptor.grant.owner != self.read.header.owner) return error.InvalidRecord;
            if (self.grant) |grant| if (!grant.eql(descriptor.grant) or descriptor.role != .control or self.role != .control) return error.InvalidRecord;
            self.grant = descriptor.grant;
            self.role = descriptor.role;
            if (descriptor.revoked) {
                self.terminal = true;
                self.ready = true;
                return .ready;
            }
            self.cursor = descriptor.dependency;
            self.depth += 1;
        }
        var grants = try self.read.grantView();
        const status = grants.effectiveStatus(self.grant orelse return error.InvalidRecord) catch |err| switch (err) {
            error.Gone => .revoked,
            else => return err,
        };
        self.terminal = status == .revoked;
        self.ready = true;
        return .ready;
    }
};
