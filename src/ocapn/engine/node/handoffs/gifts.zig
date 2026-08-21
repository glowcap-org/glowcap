//! Gifter-side entropy tickets and signed-give origination state.

const node_mod = @import("../../node.zig");
const recipe = @import("gifts/recipe.zig");
const tickets = @import("gifts/tickets.zig");

const Node = node_mod.Node;

/// Inline aggregate for the two independent gifter-side registries.
pub const State = struct {
    tickets: tickets.State = .{},
    recipe: recipe.State = .{},
};

/// Retire gifter-owned rows after every Passable batch has released its
/// tickets and while the Node allocator is still live.
pub fn deinit(self: *Node) void {
    tickets.deinit(self);
    recipe.deinit(self);
}
