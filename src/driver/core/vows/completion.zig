//! Completion rows for host vows with no in-process listener.
//!
//! Settlement fires while the Vat resolution is borrowed. The action queue is
//! drained later by an embedder, so this owner materializes the completion or
//! records an allocation-free failure.

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const host_mod = @import("../host.zig");
const host_action = @import("../host/action.zig");

const Host = host_mod.Host;

/// Queue a settled vow's completion for the embedder, infallible by reservation.
/// Fulfilled values are deep-cloned onto the Host because the source resolution
/// is turn-borrowed; the in-process `vowOn` path stays borrowed and pays no
/// clone.
pub fn queueVowCompletion(self: *Host, peer_handle: engine.PeerHandle, vow_id: u64, resolution: actors.Resolution) void {
    switch (resolution) {
        .fulfilled => |value| {
            const cloned = model.cloneArgument(self.allocator, value) catch {
                self.actions.pushReserved(.{ .failed = .{
                    .peer_handle = peer_handle,
                    .vow_id = vow_id,
                    .failure = .broken,
                    .message = host_action.failure_detail_allocation_message,
                    .message_owned = false,
                } });
                return;
            };
            self.actions.pushReserved(.{ .settled = .{ .peer_handle = peer_handle, .vow_id = vow_id, .value = cloned } });
        },
        .broken => |message| {
            const retained = host_action.retainFailureMessage(self.allocator, message);
            self.actions.pushReserved(.{ .failed = .{
                .peer_handle = peer_handle,
                .vow_id = vow_id,
                .failure = classifyFailure(self, peer_handle),
                .message = retained.bytes,
                .message_owned = retained.owned,
            } });
        },
        .give => {
            const retained = host_action.retainFailureMessage(self.allocator, "raw handoff reached a settle listener");
            self.actions.pushReserved(.{ .failed = .{
                .peer_handle = peer_handle,
                .vow_id = vow_id,
                .failure = .broken,
                .message = retained.bytes,
                .message_owned = retained.owned,
            } });
        },
    }
}

/// Classify a Vat break while the owning session row is still authoritative.
/// Finishing keeps admitted work live, so only terminal teardown is closure.
fn classifyFailure(self: *const Host, peer_handle: engine.PeerHandle) host_action.VowFailure {
    const session = self.sessions.get(peer_handle) orelse return .closed;
    return if (session.isTerminating()) .closed else .broken;
}
