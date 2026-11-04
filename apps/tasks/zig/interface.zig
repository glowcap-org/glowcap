//! Generated from checked interface descriptions.
const std = @import("std");
pub const add_verb = "add";
pub const min_text_bytes: usize = 1;
pub const max_text_bytes: usize = 4096;
/// Borrowed through the hosting turn. The caller owns mutation and storage.
pub fn addArguments(args: anytype) error{InvalidArguments}![]const u8 {
    if (args.len != 1 or args[0] != .string) return error.InvalidArguments;
    const text = args[0].string;
    if (text.len < min_text_bytes or text.len > max_text_bytes or !std.unicode.utf8ValidateSlice(text)) return error.InvalidArguments;
    return text;
}

pub const board_list_verb = "list";

pub const list_name_verb = "name";
pub const max_name_bytes: u64 = 64;
/// Borrows stored payload through the hosting turn. Checks UTF-8 once after enforcing a 64-byte maximum. No copy or allocation.
pub fn listNameReply(bytes: []const u8) error{InvalidReply}![]const u8 {
    if (@as(u128, bytes.len) < 1 or @as(u128, bytes.len) > 64) return error.InvalidReply;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidReply;
    return bytes;
}

pub const list_count_verb = "count";
pub const max_tasks: u64 = 256;
pub fn listCountReply(count: usize) error{InvalidReply}!i64 {
    if (@as(u128, count) < 0 or @as(u128, count) > 256) return error.InvalidReply;
    return @intCast(count);
}

pub const list_task_verb = "task";

pub const task_text_verb = "text";
/// Borrows stored payload through the hosting turn. Checks UTF-8 once after enforcing a 4096-byte maximum. No copy or allocation.
pub fn taskTextReply(bytes: []const u8) error{InvalidReply}![]const u8 {
    if (@as(u128, bytes.len) < 1 or @as(u128, bytes.len) > 4096) return error.InvalidReply;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidReply;
    return bytes;
}

pub const board_lists_verb = "lists";
pub const max_lists: u64 = 16;
pub fn boardListsReply(count: usize) error{InvalidReply}!i64 {
    if (@as(u128, count) < 0 or @as(u128, count) > 16) return error.InvalidReply;
    return @intCast(count);
}
/// Validate the schema's integer domain. The caller converts to its storage index.
pub fn indexArguments(args: anytype) error{InvalidArguments}!i64 {
    if (args.len != 1 or args[0] != .integer) return error.InvalidArguments;
    const index = args[0].integer;
    if (index < 0 or index > 9223372036854775807) return error.InvalidArguments;
    return index;
}
pub fn readArguments(args: anytype) error{InvalidArguments}!void {
    if (args.len != 0) return error.InvalidArguments;
}
