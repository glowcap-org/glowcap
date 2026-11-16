//! Classification for authority-free model values.
//!
//! A plain value contains neither a reference nor a handoff anywhere in its
//! tree. Resolver settlements and cross-thread mailboxes share this predicate:
//! both lack a session in which capability authority could be homed.

const model = @import("mod.zig");

pub fn argumentIsPlainData(argument: *const model.Argument) bool {
    return argumentIsPlainDataAt(argument, 0);
}

fn argumentIsPlainDataAt(argument: *const model.Argument, depth: usize) bool {
    return switch (argument.*) {
        .reference, .handoff => false,
        .list, .set => |items| itemsArePlainData(items, depth),
        .tagged => |tagged| itemsArePlainData(tagged.value, depth),
        .@"struct" => |entries| model.mayHoldItems(depth) and for (entries) |*entry| {
            if (!argumentIsPlainDataAt(&entry.value, depth + 1)) break false;
        } else true,
        else => true,
    };
}

/// The items of the container at `depth`.
fn itemsArePlainData(items: []const model.Argument, depth: usize) bool {
    if (!model.mayHoldItems(depth)) return false;
    for (items) |*item| if (!argumentIsPlainDataAt(item, depth + 1)) return false;
    return true;
}
