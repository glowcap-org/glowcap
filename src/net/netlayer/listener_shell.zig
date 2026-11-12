//! The contract listener vtable, emitted once from a resident's typed
//! listener verbs, and the restoration-state copy those verbs share.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const connection = @import("../connection.zig");
const failure_contract = @import("failure.zig");
const netlayer = @import("../netlayer.zig");
const operation = @import("operation.zig");

const Buffers = operation.Buffers;

/// One listener behind the contract `netlayer.Listener` vtable, written once
/// as typed verbs over `Impl.State`. The shell owns the `*anyopaque` recovery,
/// the scalar-to-outcome adaptation, and the vtable itself, so a resident never
/// writes a `@ptrCast` accessor stub. `Impl` declares:
///
/// - `State`: the type the vtable's `ctx` points at, usually heap-pinned.
/// - `metadata`: the `model.transport.Metadata` this listener hosts. Its symbol,
///   designator scheme, and sealed-channel flag fill the vtable.
/// - `accept(*State, *engine.Peer, Buffers) AcceptError!Connection`
/// - `waitAcceptable(*State, i32) AcceptError!bool`
/// - `localLocator(*State, std.mem.Allocator) ListenError!model.PeerLocator`
/// - `canonicalizeLocator(*State, std.mem.Allocator, model.PeerLocator) ListenError!model.PeerLocator`
/// - `close(*State) ?ListenerCloseFailure`, releasing whatever `State` owns,
///   its own storage included when the listener is heap-pinned. A borrowed
///   listener returns null and frees nothing.
/// - optional `readinessFd(*State) i32`, when accept has one pollable
///   descriptor.
/// - optional `restorationState(*State, []u8) RestorationStateError!usize`.
///
/// Each verb keeps its own error projection. The shell adds none.
pub fn ListenerShell(comptime Impl: type) type {
    return struct {
        pub const State = Impl.State;

        pub const vtable: netlayer.Listener.VTable = .{
            .transport_name = Impl.metadata.symbol,
            .designator_scheme = Impl.metadata.designator_scheme,
            .sealed_channel = Impl.metadata.sealed_channel,
            .accept = failure_contract.adaptAccept(accept),
            .wait_acceptable = failure_contract.adaptAcceptReadiness(waitAcceptable),
            .local_locator = failure_contract.adaptListenerLocator(localLocator),
            .canonicalize_locator = failure_contract.adaptListenerCanonicalize(canonicalizeLocator),
            .restoration_state = if (@hasDecl(Impl, "restorationState"))
                failure_contract.adaptRestorationState(restorationState)
            else
                null,
            .readiness_fd = if (@hasDecl(Impl, "readinessFd")) &readinessFd else null,
            .close = close,
        };

        pub fn of(ctx: *anyopaque) *State {
            return @ptrCast(@alignCast(ctx));
        }

        /// `state` as the contract listener.
        pub fn listener(state: *State) netlayer.Listener {
            return .{ .ctx = state, .vtable = &vtable };
        }

        fn accept(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) failure_contract.AcceptError!connection.Connection {
            return Impl.accept(of(ctx), peer, bufs);
        }

        fn waitAcceptable(ctx: *anyopaque, timeout_ms: i32) failure_contract.AcceptError!bool {
            return Impl.waitAcceptable(of(ctx), timeout_ms);
        }

        fn localLocator(ctx: *anyopaque, allocator: std.mem.Allocator) failure_contract.ListenError!model.PeerLocator {
            return Impl.localLocator(of(ctx), allocator);
        }

        fn canonicalizeLocator(
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            candidate: model.PeerLocator,
        ) failure_contract.ListenError!model.PeerLocator {
            return Impl.canonicalizeLocator(of(ctx), allocator, candidate);
        }

        fn restorationState(ctx: *anyopaque, out: []u8) failure_contract.RestorationStateError!usize {
            return Impl.restorationState(of(ctx), out);
        }

        fn readinessFd(ctx: *anyopaque) i32 {
            return Impl.readinessFd(of(ctx));
        }

        fn close(ctx: *anyopaque) ?failure_contract.ListenerCloseFailure {
            return Impl.close(of(ctx));
        }
    };
}

/// Complete-size query/copy: no partial restoration state is ever published.
pub fn writeListenerRestorationState(out: []u8, value: []const u8) usize {
    if (out.len >= value.len) @memcpy(out[0..value.len], value);
    return value.len;
}
