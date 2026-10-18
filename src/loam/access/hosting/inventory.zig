//! Bounded branch inventory copies descriptive rows into one retained call.
const std = @import("std");
const storage = @import("loam_access_storage");
const loam = @import("loam_core");
const hosting = @import("loam_hosting");
const driver = @import("driver_core");
const description = @import("description.zig");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const Step = @import("step.zig").Step;

pub const Page = struct {
    call: *hosting.Call,
    cursor: ?storage.GrantInventory = null,
    floor: u64 = 0,
    limit: usize,
    rows: []driver.Value,
    count: usize = 0,
    byte_bound: usize = 256,
    result: ?driver.Value = null,
    pub const max_rows = 32;

    /// The next page's position, handed back by the caller: this endpoint's
    /// key, the Store revision the page read, and the floor it continues from.
    const Cursor = struct {
        const key_end = loam.ObjectId.key_bytes;
        const revision_end = key_end + @sizeOf(u64);
        const size = revision_end + @sizeOf(u64);

        fn floorOf(bytes: *const [size]u8, call: *const hosting.Call) !u64 {
            if (!std.mem.eql(u8, bytes[0..key_end], &call.view.id.key())) return error.OutOfScope;
            if (std.mem.readInt(u64, bytes[key_end..revision_end], .big) != call.attachment.store.metadata.revision) return error.RevisionConflict;
            return std.mem.readInt(u64, bytes[revision_end..size], .big);
        }

        fn write(bytes: *[size]u8, call: *const hosting.Call, floor: u64) void {
            bytes[0..key_end].* = call.view.id.key();
            std.mem.writeInt(u64, bytes[key_end..revision_end], call.attachment.store.metadata.revision, .big);
            std.mem.writeInt(u64, bytes[revision_end..size], floor, .big);
        }
    };
    pub const max_page_bytes = 64 * 1024;

    pub fn init(call: *hosting.Call, args: []const driver.Value) !Page {
        if (args.len != 2 or args[1] != .integer or args[1].integer < 1 or args[1].integer > max_rows) return error.InvalidArguments;
        var floor: u64 = 0;
        if (args[0] != .void) {
            if (args[0] != .bytes or args[0].bytes.len != Cursor.size) return error.InvalidArguments;
            floor = try Cursor.floorOf(args[0].bytes[0..Cursor.size], call);
        }
        const limit: usize = @intCast(args[1].integer);
        return .{ .call = call, .floor = floor, .limit = limit, .rows = try call.arena().alloc(driver.Value, limit) };
    }

    pub fn advance(self: *Page, operation: *storage.Operation) !Step {
        if (self.result != null) return .ready;
        if (self.cursor == null) self.cursor = try loam.reload(storage.GrantInventory.init(operation, self.floor)) orelse return .more;
        for (0..32) |_| {
            switch (try self.cursor.?.advance()) {
                .read => |read| return .{ .read = read },
                .waiting => return .waiting,
                .ready => {},
            }
            const floor = self.cursor.?.floor;
            var full = false;
            if (try self.cursor.?.take()) |item| {
                const schema = (try operation.describeControl()).policy;
                const bytes = try rowSizeBound(item);
                if (self.byte_bound + bytes > max_page_bytes) {
                    if (self.count == 0) return error.RecordTooLarge;
                    // The next page must revisit this unprojected row.
                    self.cursor.?.floor = floor;
                    full = true;
                } else {
                    self.rows[self.count] = try encode(self.call.arena(), &schema, item);
                    self.byte_bound += bytes;
                    self.count += 1;
                }
            }
            if (full or self.count == self.limit or self.cursor.?.done) {
                const values = try self.call.arena().alloc(driver.Value, 2);
                values[0] = .{ .list = self.rows[0..self.count] };
                values[1] = .{ .void = {} };
                if (!self.cursor.?.done) {
                    const bytes = try self.call.arena().create([Cursor.size]u8);
                    Cursor.write(bytes, self.call, self.cursor.?.floor);
                    values[1] = .{ .bytes = bytes };
                }
                self.result = .{ .tagged = .{ .tag = "access:inventory", .value = values } };
                return .ready;
            }
        }
        return .more;
    }

    pub fn completeRead(self: *Page, ticket: loam.Ticket, result: loam.ReadResult) !void {
        try self.cursor.?.completeRead(ticket, result);
    }

    pub fn deinit(self: *Page) void {
        if (self.cursor) |*cursor| cursor.deinit();
    }
};

/// Each policy projects its selected permission scalars, bound containers and
/// three bound scalars. Unsigned leaves use at most 39 decimal bytes. Labels
/// and tags add their fixed UTF-8 allowance. The shared receipt writer derives
/// scalar/container overhead. This bound admits pages before allocating rows.
fn rowSizeBound(item: storage.GrantInventory.Item) !usize {
    var values: usize = 10;
    var bytes: usize = item.label.len + 2 * 39 + "access:grant".len + 2 * "revoked".len;
    for ([_]core.Policy.Value{ item.ceiling, item.configured }) |policy| {
        values += 5 + @popCount(policy.permissions);
        bytes += "access:policy".len;
        const bounded: usize = @popCount(policy.bound_mask);
        values += 4 * bounded;
        bytes += ("access:bound".len + "upper".len + 39) * bounded;
    }
    return records.ValueRecord.encodedSizeBound(driver.Value, values, 0, bytes, 0);
}

/// One retained-call allocation per projected spine and copied descriptive
/// leaf. Rows outlive disk reads and their decoded source leases, so borrowing
/// those labels would dangle. Page limits bound this owner. No grant mirror or
/// capability retain is created, and all storage retires with the call arena.
pub fn encode(arena: std.mem.Allocator, schema: *const core.Policy, item: storage.GrantInventory.Item) !driver.Value {
    const values = try arena.alloc(driver.Value, 9);
    values[0] = .{ .integer = item.id.slot };
    values[1] = try description.unsigned(arena, item.id.generation);
    values[2] = try description.unsigned(arena, @backingInt(item.revision));
    values[3] = .{ .string = try arena.dupe(u8, item.label.slice()) };
    values[4] = .{ .symbol = @tagName(item.status) };
    values[5] = .{ .symbol = @tagName(item.effective_status) };
    values[6] = try description.policy(arena, schema, item.ceiling);
    values[7] = try description.policy(arena, schema, item.configured);
    values[8] = .{ .integer = item.delegation_depth };
    return .{ .tagged = .{ .tag = "access:grant", .value = values } };
}
