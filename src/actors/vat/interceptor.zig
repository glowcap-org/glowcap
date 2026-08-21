//! Served-reply interception before a vat publishes an answer settlement.

const model = @import("model");
const engine = @import("engine");

/// What a reply interceptor decided: claim publication completely, or return
/// the turn-borrowed value the vat should resolve with.
pub const Outcome = union(enum) {
    claimed,
    resolve: model.Argument,
};

/// A served reply's interceptor. Host integration uses this seam to turn a
/// foreign object into a signed give, project a foreign promise, or rewrite a
/// node-local route before the value reaches the wire.
pub const Interceptor = struct {
    ctx: ?*anyopaque,
    func: *const fn (
        ctx: ?*anyopaque,
        answer: engine.AnswerTarget,
        fulfilled: model.Argument,
    ) anyerror!Outcome,
};
