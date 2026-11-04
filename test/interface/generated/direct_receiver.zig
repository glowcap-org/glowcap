//! Generated from checked interface descriptions.
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;

/// Values borrow this call. Keeping one requires existing ownership operations.
pub fn receive(receiver: anytype, delivery: glowcap.actors.Delivery) !model.Argument {
    const peeled = delivery.verb != null;
    if (try delivery.args.len() != @as(usize, if (peeled) 1 else 2)) return error.InvalidArguments;
    // Two fixed stack view slots. No payload is copied or retained here.
    // value admits every passable category; projection must finish before invoke.
    const raw = [2]model.view.Argument{
        if (delivery.verb) |symbol| .{ .symbol = symbol } else try delivery.args.at(0),
        try delivery.args.at(if (peeled) 0 else 1),
    };
    try receiver.invoke(raw[0], raw[1]);
    return .{ .void = {} };
}
