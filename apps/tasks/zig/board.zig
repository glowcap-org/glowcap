//! The board's records and the calls each one answers.
//!
//! A board holds lists and a list holds tasks. Each is a Loam resource with
//! its own content record, so a task can be shared or moved on its own. A
//! record's fields are strong references to its children, in order, and a
//! reader reaches a child through the facet `list` or `task` returns. Calls
//! that change anything name a sequence number (`mutate`), so a client that
//! retries after a lost reply changes the board once.
const std = @import("std");
const interface = @import("interface.zig");
const glowcap = @import("glowcap");
const core = glowcap.loam.core;
const access = glowcap.loam.access;
const driver = glowcap.driver.core;

/// A list holds at most this many tasks.
pub const max_tasks = 256;
/// A board holds at most this many lists.
pub const max_lists = 16;
pub const max_text_bytes = interface.max_text_bytes;
pub const max_name_bytes = 64;

pub const board_schema = 0x5441534b53424f41;
pub const list_schema = 0x5441534b534c4953;
pub const task_schema = 0x5441534b53544153;

pub const schemas = [_]core.Schema{
    .{ .id = board_schema, .version = 1, .max_payload = max_name_bytes, .max_edges = max_lists },
    .{ .id = list_schema, .version = 1, .max_payload = max_name_bytes, .max_edges = max_tasks },
    .{ .id = task_schema, .version = 1, .max_payload = max_text_bytes, .max_edges = 0 },
};

/// Reading lists and tasks, and changing them, are the two permissions a
/// share can carry.
pub const read: access.core.Policy.Key = @fromBackingInt(1);
pub const post: access.core.Policy.Key = @fromBackingInt(2);
pub const policy: access.core.Policy.Descriptor = .{ .id = @fromBackingInt(0x5441534b53), .permissions = &.{ read, post } };
/// Boards, lists and tasks share one kind, so any node can hold any other.
pub const kind: access.core.KindId = @fromBackingInt(1);

pub const contents = [_]access.hosting.ContentBehavior{
    .{ .schema = board_schema, .requirement = requirement, .retry = retry, .create = createList, .invoke = invokeBoard },
    .{ .schema = list_schema, .requirement = requirement, .retry = retry, .participants = moveParticipants, .resource = moveTask, .create = createTask, .invoke = invokeList },
    .{ .schema = task_schema, .requirement = requirement, .retry = retry, .invoke = invokeTask },
};

const readers = [_][]const u8{ "lists", "list", "name", "count", "task", "text" };
const writers = [_][]const u8{ "add-list", interface.add_verb, "move" };

fn named(verb: []const u8, set: []const []const u8) bool {
    for (set) |candidate| if (std.mem.eql(u8, verb, candidate)) return true;
    return false;
}

fn requirement(_: ?*anyopaque, _: std.mem.Allocator, input: access.hosting.ContentInvocation) !access.core.Policy.Requirement {
    if (named(input.verb, &readers)) return .{ .permissions = &.{read} };
    if (named(input.verb, &writers)) return .{ .permissions = &.{post} };
    return error.NoSuchMethod;
}

fn retry(_: ?*anyopaque, verb: []const u8, _: []const driver.Value) !access.hosting.RetryMode {
    return if (named(verb, &readers)) .read_only else .receipt;
}

fn index(args: []const driver.Value) !usize {
    if (args.len == 0 or args[0] != .integer) return error.InvalidArguments;
    return std.math.cast(usize, args[0].integer) orelse error.InvalidArguments;
}

fn text(args: []const driver.Value, limit: usize) ![]const u8 {
    if (args.len != 1 or args[0] != .string) return error.InvalidArguments;
    const value = args[0].string;
    if (value.len == 0 or value.len > limit) return error.InvalidArguments;
    return value;
}

fn count(content: core.RecordView) driver.Value {
    return .{ .integer = @intCast(content.edge_count) };
}

/// The destination's count once a move appends the task.
fn countAfterAdd(content: core.RecordView) driver.Value {
    return .{ .integer = @intCast(content.edge_count + 1) };
}

fn createList(_: ?*anyopaque, _: std.mem.Allocator, input: access.hosting.ContentInvocation) !?access.hosting.Creation {
    if (!std.mem.eql(u8, input.verb, "add-list")) return null;
    return .{ .kind = kind, .schema = list_schema };
}

fn invokeBoard(_: ?*anyopaque, call: *access.hosting.ContentCall, input: access.hosting.ContentInvocation) !driver.Value {
    if (std.mem.eql(u8, input.verb, "lists")) return count(input.content);
    if (std.mem.eql(u8, input.verb, "list")) return call.discloseDependent(try index(input.args));
    if (std.mem.eql(u8, input.verb, "add-list")) {
        try call.createChild(try text(input.args, max_name_bytes));
        return .void;
    }
    return error.NoSuchMethod;
}

fn createTask(_: ?*anyopaque, _: std.mem.Allocator, input: access.hosting.ContentInvocation) !?access.hosting.Creation {
    if (!std.mem.eql(u8, input.verb, interface.add_verb)) return null;
    return .{ .kind = kind, .schema = task_schema };
}

/// `move task destination` moves a task this list holds to the end of the
/// destination list. Both are capabilities, so the task is named by what the
/// caller holds, never by a position another client's change may shift. The
/// task, this list, and the destination change in one save, and every link to
/// the task keeps working.
fn moveParticipants(_: ?*anyopaque, arena: std.mem.Allocator, input: access.hosting.ContentInvocation) ![]const access.hosting.Participant {
    if (!std.mem.eql(u8, input.verb, "move")) return &.{};
    if (input.args.len != 2) return error.InvalidArguments;
    const changing: access.core.Policy.Requirement = .{ .permissions = &.{post} };
    const declared = try arena.alloc(access.hosting.Participant, 2);
    declared[0] = .{ .source = .{ .argument = 0 }, .requirement = changing };
    declared[1] = .{ .source = .{ .argument = 1 }, .requirement = changing };
    return declared;
}

fn moveTask(_: ?*anyopaque, _: std.mem.Allocator, input: access.hosting.ContentInvocation) !?access.hosting.ResourceEffect {
    if (!std.mem.eql(u8, input.verb, "move")) return null;
    const destination = input.participants[1];
    if (destination.content.schema != list_schema) return error.InvalidArguments;
    return .{ .target = .{ .participant = 0 }, .action = .{ .move = destination.resource.id } };
}

fn invokeList(_: ?*anyopaque, call: *access.hosting.ContentCall, input: access.hosting.ContentInvocation) !driver.Value {
    if (std.mem.eql(u8, input.verb, "name")) return .{ .string = input.content.payload };
    if (std.mem.eql(u8, input.verb, "count")) return count(input.content);
    if (std.mem.eql(u8, input.verb, "task")) return call.discloseDependent(try index(input.args));
    if (std.mem.eql(u8, input.verb, interface.add_verb)) {
        try call.createChild(try interface.addArguments(input.args));
        return .void;
    }
    if (std.mem.eql(u8, input.verb, "move")) {
        const at = input.participants[0].field orelse return error.NotInThisList;
        try call.removeReference(at);
        try (try call.participant(1)).appendReference(try call.reference(at));
        return countAfterAdd(input.participants[1].content);
    }
    return error.NoSuchMethod;
}

fn invokeTask(_: ?*anyopaque, _: *access.hosting.ContentCall, input: access.hosting.ContentInvocation) !driver.Value {
    if (std.mem.eql(u8, input.verb, "text")) return .{ .string = input.content.payload };
    return error.NoSuchMethod;
}
