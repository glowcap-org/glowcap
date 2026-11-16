//! The nesting step shared by the Host's value walks that refuse with
//! `NestingTooDeep`: lift, lower, and routing.

const model = @import("model");

/// The depth of the items of a container at `depth`, or `NestingTooDeep` when
/// `model.mayHoldItems` refuses them.
pub inline fn itemsDepth(depth: usize) error{NestingTooDeep}!usize {
    if (!model.mayHoldItems(depth)) return error.NestingTooDeep;
    return depth + 1;
}
