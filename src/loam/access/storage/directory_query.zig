//! A revision-bound sparse index cursor retains only a four-level path.
const loam = @import("loam_core");
const records = @import("loam_access_records");
const Read = @import("read.zig").Read;
const Step = @import("read.zig").Step;
const Load = @import("load.zig").Load;

pub const DirectoryQuery = struct {
    view: *Read,
    frames: [4]Frame = undefined,
    count: u3 = 0,
    load: Load = .{},
    entry: ?Entry = null,
    done: bool = false,
    family: records.DirectoryPage.Family = .resource,
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

    pub fn initAt(view: *Read, root: ?loam.ObjectId, family: records.DirectoryPage.Family, floor: u64) DirectoryQuery {
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
            const frame = &self.frames[level];
            const page = if (try self.view.store.proposed(frame.object)) |proposal| try records.DirectoryPage.decode(proposal.view) else page: {
                const lease = switch (try self.load.acquire(self.view.store, frame.object)) {
                    .read => |request| return .{ .read = request },
                    .waiting => return .waiting,
                    .ready => |lease| lease,
                };
                defer self.view.store.release(lease) catch unreachable;
                // Decode before releasing; the page owns scalar target copies.
                break :page try records.DirectoryPage.decode(try self.view.store.currentView(lease));
            };
            const result = try self.advancePage(page, level);
            if (result == .ready and self.entry == null and !self.done) continue;
            return result;
        }
        self.done = true;
        return .ready;
    }

    fn advancePage(self: *DirectoryQuery, value: records.DirectoryPage, level: u2) !Step {
        const frame = &self.frames[level];
        if (value.owner != self.view.header.owner or value.family != self.family or value.level != level or value.prefix != frame.prefix) return error.InvalidRecord;
        while (frame.digit < 256) {
            const digit: u8 = @intCast(frame.digit);
            frame.digit += 1;
            const target = value.get(digit) orelse continue;
            const prefix = frame.prefix | (@as(u32, digit) << (@as(u5, 3 - @as(u5, level)) * 8));
            const span: u64 = @as(u64, 1) << (@as(u6, 3 - @as(u6, level)) * 8);
            if (@as(u64, prefix) + span <= self.floor) continue;
            if (level == 3) {
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
