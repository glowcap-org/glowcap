//! Bounded branch inventory copies descriptive rows into one retained call.
const std = @import("std");
const storage = @import("loam_access_storage");
const loam = @import("loam_core");
const hosting = @import("loam_hosting");
const driver = @import("driver_core");
const description = @import("description.zig");

pub const Page = struct {
    call: *hosting.Call,
    cursor: ?storage.GrantInventory = null,
    floor: u64 = 0,
    limit: usize,
    rows: []driver.Value,
    count: usize = 0,
    byte_bound: usize = 256,
    result: ?driver.Value = null,
    pub const Step = union(enum) { ready, more, read: loam.Read, waiting };
    const cursor_bytes = 49;
    pub const max_page_bytes = 64 * 1024;

    pub fn init(call: *hosting.Call, args: []const driver.Value) !Page {
        if (args.len != 2 or args[1] != .integer or args[1].integer < 1 or args[1].integer > 32) return error.InvalidArguments;
        var floor: u64 = 0;
        if (args[0] != .void) {
            if (args[0] != .bytes or args[0].bytes.len != cursor_bytes) return error.InvalidArguments;
            const bytes = args[0].bytes;
            if (!std.mem.eql(u8, bytes[0..33], &call.view.id.key())) return error.OutOfScope;
            if (std.mem.readInt(u64, bytes[33..41], .big) != call.attachment.store.metadata.revision) return error.RevisionConflict;
            floor = std.mem.readInt(u64, bytes[41..49], .big);
        }
        const limit: usize = @intCast(args[1].integer);
        return .{ .call = call, .floor = floor, .limit = limit, .rows = try call.arena().alloc(driver.Value, limit) };
    }

    pub fn advance(self: *Page, operation: *storage.Operation) !Step {
        if (self.result != null) return .ready;
        if (self.cursor == null) self.cursor = storage.GrantInventory.init(operation, self.floor) catch |err| {
            if (err == error.RecordUnloaded) return .more;
            return err;
        };
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
                const bytes = try rowSizeBound(item, &schema);
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
                    const bytes = try self.call.arena().alloc(u8, cursor_bytes);
                    @memcpy(bytes[0..33], &self.call.view.id.key());
                    std.mem.writeInt(u64, bytes[33..41], self.call.attachment.store.metadata.revision, .big);
                    std.mem.writeInt(u64, bytes[41..49], self.cursor.?.floor, .big);
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
/// three bound scalars. Unsigned leaves use at most 39 decimal bytes; labels
/// and tags add their fixed UTF-8 allowance. The shared receipt writer derives
/// scalar/container overhead. This bound admits pages before allocating rows.
fn rowSizeBound(item: storage.GrantInventory.Item, schema: *const @import("loam_access_core").Policy) !usize {
    var values: usize = 10;
    var bytes: usize = item.label.len + 2 * 39 + "access:grant".len + 2 * "revoked".len;
    for ([_]@import("loam_access_core").Policy.Value{ item.ceiling, item.configured }) |policy| {
        values += 5 + @popCount(policy.permissions);
        bytes += "access:policy".len;
        for (policy.bounds[0..schema.constraint_count]) |limit| if (limit != null) {
            values += 4;
            bytes += "access:bound".len + "upper".len + 39;
        };
    }
    return @import("loam_access_records").ValueRecord.encodedSizeBound(driver.Value, values, 0, bytes, 0);
}

/// One retained-call allocation per projected spine and copied descriptive
/// leaf. Rows outlive disk reads and their decoded source leases, so borrowing
/// those labels would dangle. Page limits bound this owner; no grant mirror or
/// capability retain is created, and all storage retires with the call arena.
pub fn encode(arena: std.mem.Allocator, schema: *const @import("loam_access_core").Policy, item: storage.GrantInventory.Item) !driver.Value {
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
