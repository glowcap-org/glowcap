//! One valid stream dial whose connection adoption can be failed by the
//! driver's allocator. The provider then exposes an exact rollback refusal.

const c = @import("c_abi");
const cshared = @import("c_abi_shared");
const cdrv = @import("c_abi_driver");
const glowcap = @import("glowcap");

pub const StreamAdoptionResident = struct {
    wake: glowcap.net.wake_channel.WakeChannel,
    pending: bool = false,
    close_calls: usize = 0,

    fn self(raw: ?*anyopaque) *StreamAdoptionResident {
        return @ptrCast(@alignCast(raw.?));
    }

    pub fn startConnect(
        ctx: ?*anyopaque,
        _: ?*const cdrv.GlowcapLocatorView,
        _: ?*const cshared.GlowcapTransportOperationOptions,
        out_attempt: ?*?*anyopaque,
        out_fd: ?*i32,
        _: ?*cdrv.GlowcapProviderFailure,
    ) callconv(.c) i32 {
        const resident = self(ctx);
        resident.pending = true;
        out_attempt.?.* = resident;
        out_fd.?.* = resident.wake.read;
        return c.GLOWCAP_OK;
    }

    pub fn finishConnect(
        attempt: ?*anyopaque,
        out_conn: ?*?*anyopaque,
        out_fd: ?*i32,
        _: ?*cdrv.GlowcapProviderFailure,
    ) callconv(.c) i32 {
        const resident = self(attempt);
        resident.wake.drain() catch unreachable;
        resident.pending = false;
        out_conn.?.* = resident;
        out_fd.?.* = resident.wake.read;
        return c.GLOWCAP_OK;
    }

    pub fn cancelConnect(attempt: ?*anyopaque, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        self(attempt).pending = false;
        return c.GLOWCAP_OK;
    }

    pub fn read(_: ?*anyopaque, _: ?*anyopaque, _: ?[*]u8, _: usize) callconv(.c) isize {
        return -1;
    }

    pub fn writeAll(_: ?*anyopaque, _: ?*anyopaque, _: ?[*]const u8, _: usize) callconv(.c) i32 {
        return c.GLOWCAP_ERR_IO;
    }

    pub fn closeConnection(ctx: ?*anyopaque, _: ?*anyopaque, out: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const resident = self(ctx);
        resident.close_calls += 1;
        const report = out orelse return c.GLOWCAP_ERR_IO;
        const name = "StreamAdoptionCloseFailed";
        report.* = cshared.transport_provider.emptyProviderFailure();
        report.result = c.GLOWCAP_ERR_IO;
        report.primary_name = name.ptr;
        report.primary_name_len = name.len;
        return c.GLOWCAP_ERR_IO;
    }

    pub fn takeFailure(_: ?*anyopaque, _: ?*anyopaque, out: ?*cdrv.GlowcapProviderFailure) callconv(.c) void {
        if (out) |report| report.* = cshared.transport_provider.emptyProviderFailure();
    }

    pub fn table(resident: *StreamAdoptionResident) cdrv.GlowcapStreamTransport {
        return .{
            .abi_version = cdrv.GLOWCAP_STREAM_TRANSPORT_ABI_VERSION,
            .struct_size = @sizeOf(cdrv.GlowcapStreamTransport),
            .ctx = resident,
            .start_connect = startConnect,
            .finish_connect = finishConnect,
            .cancel_connect = cancelConnect,
            .listen = null,
            .finish_listen = null,
            .cancel_listen = null,
            .listener_wait_acceptable = null,
            .listener_readiness_fd = null,
            .listener_locator = null,
            .listener_advertise = null,
            .listener_restoration_state = null,
            .accept = null,
            .listener_close = null,
            .read = read,
            .write_all = writeAll,
            .conn_close = closeConnection,
            .conn_take_failure = takeFailure,
        };
    }
};
