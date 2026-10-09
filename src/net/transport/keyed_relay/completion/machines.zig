//! Composition root for the completion relay's mutually cooperating machines.
//!
//! The machines remain separate subjects; this module owns only their typed
//! access seams. Keeping that wiring here leaves `completion.zig` responsible
//! for backend ownership and the public completion contract.

const completion = @import("../../../completion/loop.zig");
const completion_contract = @import("../../../completion/contract.zig");
const carrier_failure = @import("../../../carrier_failure.zig");
const protocol = @import("../../../websocket.zig").client_protocol;

const buffers = @import("buffers.zig");
const dispatch_machine = @import("dispatch.zig");
const lifecycle_machine = @import("lifecycle.zig");
const receive_machine = @import("receive.zig");
const send_machine = @import("send.zig");
const tls_machine = @import("tls.zig");

const OutgoingOpcode = protocol.OutgoingOpcode;

pub fn Machines(
    comptime Backend: type,
    comptime Types: type,
    comptime Namespace: type,
    comptime Operations: type,
    comptime max_header_len: usize,
    comptime close_retry_batch: usize,
) type {
    return struct {
        const Self = Backend;
        const Fd = Self.Fd;
        const ConnId = Types.ConnId;
        const InternalOp = Types.InternalOp;
        const PlatformBufferDisposition = Types.PlatformBufferDisposition;
        const RelayConn = Types.RelayConn;

        const ReceiveAccess = struct {
            pub fn rawBytes(c: *const RelayConn) []const u8 {
                return buffers.rawBytes(c);
            }

            pub fn dropRaw(backend: *Self, c: *RelayConn, count: usize) void {
                buffers.dropRaw(backend, c, count);
            }

            pub fn appendRaw(backend: *Self, c: *RelayConn, bytes: []const u8) !void {
                try buffers.appendRaw(backend, c, bytes);
            }

            pub fn armPlatformRecv(backend: *Self, c: *RelayConn) !void {
                try Operations.armPlatformRecv(backend, c);
            }

            pub fn failRelay(backend: *Self, c: *RelayConn) void {
                Lifecycle.fail(backend, c);
            }

            pub fn queueControlFrame(
                backend: *Self,
                c: *RelayConn,
                opcode: OutgoingOpcode,
                bytes: []const u8,
            ) !void {
                try Send.queueAndDrive(backend, c, .control, opcode, bytes);
            }

            pub fn refuseExternalSend(backend: *Self, c: *RelayConn) void {
                Send.refuseExternal(backend, c);
            }

            pub fn refuseExternalSendWith(
                backend: *Self,
                c: *RelayConn,
                cause: ?anyerror,
                phase: carrier_failure.Phase,
            ) void {
                Send.refuseExternalWith(backend, c, cause, phase);
            }

            pub fn borrowToken(index: u16) u32 {
                return Namespace.borrowToken(index);
            }

            pub fn promoteParked(backend: *Self, c: *RelayConn) void {
                Operations.promoteParked(backend, c);
            }
        };
        pub const Receive = receive_machine.Machine(Self, Types, ReceiveAccess);

        const SendAccess = struct {
            pub fn idFromFd(fd: Fd) ?ConnId {
                return Operations.idFromFd(fd);
            }

            pub fn isSecure(backend: *const Self, c: *const RelayConn) bool {
                return Tls.has(backend, c);
            }

            pub fn clearWsOut(backend: *Self, c: *RelayConn) void {
                buffers.clearSend(backend, c);
            }

            pub fn sendUserData(id: ConnId) u64 {
                return Operations.internalUd(.send, id);
            }

            pub fn driveSecure(backend: *Self, c: *RelayConn) !void {
                Tls.drive(backend, c);
            }

            pub fn borrowCarrierFailure(backend: *Self, c: *RelayConn) completion_contract.Borrowed {
                return Tls.borrowFailure(backend, c) orelse .{};
            }

            pub fn refuseExternalBorrowed(
                backend: *Self,
                c: *RelayConn,
                comp: completion.Completion,
                phase: carrier_failure.Phase,
            ) bool {
                return Send.refuseExternalBorrowed(backend, c, comp, phase);
            }
        };
        pub const Send = send_machine.Machine(Self, Types, SendAccess, max_header_len);

        const LifecycleAccess = struct {
            pub fn idFromFd(fd: Fd) ?ConnId {
                return Operations.idFromFd(fd);
            }

            pub fn refuseExternalSend(backend: *Self, c: *RelayConn) void {
                Send.refuseExternal(backend, c);
            }

            pub fn refuseExternalSendWith(
                backend: *Self,
                c: *RelayConn,
                cause: ?anyerror,
                phase: carrier_failure.Phase,
            ) void {
                Send.refuseExternalWith(backend, c, cause, phase);
            }

            pub fn clearWsOut(backend: *Self, c: *RelayConn) void {
                buffers.clearSend(backend, c);
            }

            pub fn queueCloseFrame(backend: *Self, c: *RelayConn) !void {
                try Send.queueFrame(backend, c, .control, .close, &.{});
            }

            pub fn driveRelaySend(backend: *Self, c: *RelayConn) !void {
                try Send.drive(backend, c);
            }

            pub fn closeUserData(id: ConnId) u64 {
                return Operations.internalUd(.close, id);
            }

            pub fn beginCarrierClose(backend: *Self, c: *RelayConn) void {
                Tls.beginShutdown(backend, c);
            }

            pub fn borrowCarrierFailure(backend: *Self, c: *RelayConn) completion_contract.Borrowed {
                return Tls.borrowFailure(backend, c) orelse .{};
            }

            pub fn prepareCarrierClose(backend: *Self, c: *RelayConn, platform_failed: bool) bool {
                return Tls.prepareClose(backend, c, platform_failed);
            }

            pub fn hasBorrowedCarrierFailure(backend: *const Self, c: *const RelayConn) bool {
                return Tls.hasBorrowedFailure(backend, c);
            }

            pub fn destroyCarrier(backend: *Self, c: *RelayConn) void {
                Tls.destroy(backend, c);
            }
        };
        pub const Lifecycle = lifecycle_machine.Machine(
            Self,
            Types,
            LifecycleAccess,
            max_header_len,
            close_retry_batch,
        );

        const DispatchAccess = struct {
            pub fn internalId(user_data: u64) ConnId {
                return Operations.internalId(user_data);
            }

            pub fn isSecure(backend: *const Self, c: *const RelayConn) bool {
                return Tls.has(backend, c);
            }

            pub fn internalOp(user_data: u64) InternalOp {
                return Operations.internalOp(user_data);
            }

            pub fn receivePlatform(
                backend: *Self,
                c: *RelayConn,
                comp: completion.Completion,
                bytes: []const u8,
            ) !PlatformBufferDisposition {
                return Receive.tryEmitPlatform(backend, c, comp, bytes);
            }

            pub fn receiveBuffered(backend: *Self, c: *RelayConn) !void {
                try Receive.tryEmit(backend, c);
            }

            pub fn serviceBuffered(backend: *Self, c: *RelayConn) !void {
                try Receive.serviceBuffered(backend, c);
            }

            pub fn serviceParked(backend: *Self, c: *RelayConn) !void {
                try Receive.serviceParked(backend, c);
            }

            pub fn isRegistrationLeg(backend: *const Self, id: ConnId) bool {
                return Operations.isRegistrationLeg(backend, id);
            }

            pub fn fail(backend: *Self, c: *RelayConn) void {
                Lifecycle.fail(backend, c);
            }

            pub fn failWith(
                backend: *Self,
                c: *RelayConn,
                phase: carrier_failure.Phase,
                cause: anyerror,
            ) void {
                Lifecycle.failWith(backend, c, phase, cause);
            }

            pub fn end(backend: *Self, c: *RelayConn, result: i32) void {
                Lifecycle.end(backend, c, result);
            }

            pub fn endWith(
                backend: *Self,
                c: *RelayConn,
                result: i32,
                phase: carrier_failure.Phase,
                cause: ?anyerror,
            ) void {
                Lifecycle.endWith(backend, c, result, phase, cause);
            }

            pub fn refuseExternalBorrowed(
                backend: *Self,
                c: *RelayConn,
                comp: completion.Completion,
                phase: carrier_failure.Phase,
            ) bool {
                return Send.refuseExternalBorrowed(backend, c, comp, phase);
            }

            pub fn beginPlatformClose(backend: *Self, c: *RelayConn) void {
                Lifecycle.beginPlatformClose(backend, c);
            }

            pub fn advanceClose(backend: *Self, c: *RelayConn) void {
                Lifecycle.advance(backend, c);
            }

            pub fn maybeFinish(backend: *Self, c: *RelayConn) void {
                Lifecycle.maybeFinish(backend, c);
            }

            pub fn driveSend(backend: *Self, c: *RelayConn) !void {
                try Send.drive(backend, c);
            }

            pub fn completeSend(backend: *Self, c: *RelayConn) void {
                Send.completeExternal(backend, c);
            }

            pub fn stageSend(backend: *Self, c: *RelayConn) !void {
                try Send.stageExternalChunk(backend, c);
            }

            pub fn armPlatformRecv(backend: *Self, c: *RelayConn) !void {
                try Operations.armPlatformRecv(backend, c);
            }

            pub fn secureReceive(backend: *Self, c: *RelayConn, bytes: []const u8) !void {
                try Tls.receive(backend, c, bytes);
            }

            pub fn secureSent(backend: *Self, c: *RelayConn, result: i32) !void {
                try Tls.sent(backend, c, result);
            }

            pub fn secureEof(backend: *Self, c: *RelayConn) void {
                Tls.transportEof(backend, c);
            }

            pub fn securePlatformFailed(
                backend: *Self,
                c: *RelayConn,
                phase: carrier_failure.Phase,
                comp: completion.Completion,
                fallback: anyerror,
            ) void {
                Tls.platformFailed(backend, c, phase, comp, fallback);
            }

            pub fn driveSecure(backend: *Self, c: *RelayConn) !void {
                Tls.drive(backend, c);
            }
        };
        pub const Dispatch = dispatch_machine.Machine(Self, Types, DispatchAccess);

        const TlsAccess = struct {
            pub fn sendUserData(id: ConnId) u64 {
                return Operations.internalUd(.send, id);
            }

            pub fn failureToken(id: ConnId) u32 {
                return Namespace.borrowToken(id);
            }

            pub fn armPlatformRecv(backend: *Self, c: *RelayConn) !void {
                try Operations.armPlatformRecv(backend, c);
            }

            pub fn finishWebSocketSend(backend: *Self, c: *RelayConn) !void {
                try Dispatch.finishWebSocketSend(backend, c);
            }

            pub fn onPlaintext(backend: *Self, c: *RelayConn) !void {
                try Dispatch.onBytes(backend, c);
            }

            pub fn beginPlatformClose(backend: *Self, c: *RelayConn) void {
                Lifecycle.beginPlatformClose(backend, c);
            }

            pub fn advanceClose(backend: *Self, c: *RelayConn) void {
                Lifecycle.advance(backend, c);
            }

            pub fn end(backend: *Self, c: *RelayConn, result: i32) void {
                Lifecycle.end(backend, c, result);
            }
        };
        pub const Tls = tls_machine.Machine(Self, Types, TlsAccess);
    };
}
