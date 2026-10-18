//! A revision-bound sparse index cursor retains only a four-level path.
const std = @import("std");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const Page = records.DirectoryPage;
const Read = @import("read.zig").Read;
const Step = @import("read.zig").Step;
const Load = @import("load.zig").Load;

pub const DirectoryQuery = struct {
    view: *Read,
    frames: [Page.levels]Frame = undefined,
    count: std.math.IntFittingRange(0, Page.levels) = 0,
    load: Load = .{},
    entry: ?Entry = null,
    done: bool = false,
    family: Page.Family = .resource,
    floor: u64 = 0,
    pub const Entry = struct { slot: u32, object: loam.ObjectId };
    const Frame = struct { object: loam.ObjectId, digit: u16 = 0, prefix: u32 };

    pub fn init(view: *Read, root: ?loam.ObjectId) DirectoryQuery {
        var self: DirectoryQuery = .{ .view = view, .done = root == null };
        if (root) |object| {
            self.frames[0] = .{ .object = object, .prefix = 0 };
            self.count = 1;
        }
        return self;
    }

    pub fn initAt(view: *Read, root: ?loam.ObjectId, family: Page.Family, floor: u64) DirectoryQuery {
        var result = init(view, if (floor < records.OwnerRecord.max_slots) root else null);
        result.family = family;
        result.floor = floor;
        return result;
    }

    pub fn advance(self: *DirectoryQuery) !Step {
        try self.view.current();
        self.entry = null;
        while (self.count != 0) {
            const level: u2 = @intCast(self.count - 1);
            const object = self.frames[level].object;
            const result = if (try self.view.store.proposed(object)) |proposal| try self.advancePage(proposal.view, level) else result: {
                const lease = switch (try self.load.acquire(self.view.store, object)) {
                    .read => |request| return .{ .read = request },
                    .waiting => return .waiting,
                    .ready => |lease| lease,
                };
                defer self.view.store.release(lease) catch unreachable;
                break :result try self.advancePage(try self.view.store.currentView(lease), level);
            };
            if (result == .ready and self.entry == null and !self.done) continue;
            return result;
        }
        self.done = true;
        return .ready;
    }

    /// Step to the page's next populated key, reading that one edge from the
    /// view: descend into an inner page, yield a leaf, or pop an exhausted
    /// page.
    fn advancePage(self: *DirectoryQuery, view: loam.RecordView, level: u2) !Step {
        const frame = &self.frames[level];
        const page = try Page.decodeHeader(view);
        try page.expect(self.view.header.owner, self.family, level, frame.prefix);
        while (page.nextKey(frame.digit)) |digit| {
            frame.digit = @as(u16, digit) + 1;
            const target = (try page.target(view, digit)).?;
            const prefix = Page.childPrefix(frame.prefix, digit, level);
            if (@as(u64, prefix) + Page.span(level) <= self.floor) continue;
            if (level == Page.last_level) {
                self.entry = .{ .slot = prefix, .object = target };
                return .ready;
            }
            self.frames[self.count] = .{ .object = target, .prefix = prefix };
            self.count += 1;
            return .ready;
        }
        self.count -= 1;
        if (self.count == 0) self.done = true;
        return .ready;
    }

    pub fn completeRead(self: *DirectoryQuery, ticket: loam.Ticket, result: loam.ReadResult) !void {
        try self.load.complete(self.view.store, ticket, result);
    }
};
