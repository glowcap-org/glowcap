//! Classification for authority-free model values.
//!
//! A plain value contains neither a reference nor a handoff anywhere in its
//! tree. Resolver settlements and cross-thread mailboxes share this predicate:
//! both lack a session in which capability authority could be homed.

const model = @import("mod.zig");

/// Whether `argument` is plain data. The one walk also bounds the tree: a
/// caller's value nested past `model.max_value_depth` is `ValueTooDeep`, which
/// is a different refusal from carrying authority.
pub fn argumentIsPlainData(argument: *const model.Argument) error{ValueTooDeep}!bool {
    return argumentIsPlainDataAt(argument, 0);
}

fn argumentIsPlainDataAt(argument: *const model.Argument, depth: usize) error{ValueTooDeep}!bool {
    return switch (argument.*) {
        .reference, .handoff => false,
        .list, .set => |items| itemsArePlainData(items, depth),
        .tagged => |tagged| itemsArePlainData(tagged.value, depth),
        .@"struct" => |entries| {
            if (!model.mayHoldItems(depth)) return error.ValueTooDeep;
            for (entries) |*entry| if (!try argumentIsPlainDataAt(&entry.value, depth + 1)) return false;
            return true;
        },
        else => true,
    };
}

/// The items of the container at `depth`.
fn itemsArePlainData(items: []const model.Argument, depth: usize) error{ValueTooDeep}!bool {
    if (!model.mayHoldItems(depth)) return error.ValueTooDeep;
    for (items) |*item| if (!try argumentIsPlainDataAt(item, depth + 1)) return false;
    return true;
}
