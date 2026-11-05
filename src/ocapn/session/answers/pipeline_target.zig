//! Composition-owned local callable for an answer published as a handoff.
const model = @import("model");

/// The private export is never sent to the partner. AnswerPayload owns this
/// destination until its final release, including detached answer obligations.
/// Retirement must be allocation-free and follow already-accepted deliveries.
pub const Target = struct {
    near: model.NearRef,
    retire: *const fn (*Target) void,

    pub fn retireOwned(slot: *?*Target) void {
        const target = slot.* orelse return;
        slot.* = null;
        target.retire(target);
    }
};
