//! Own multiplexed-provider connection byte I/O, failure, and close projection.

const std = @import("std");

const foundation = @import("foundation");
const net = @import("net");
const multiplexed = @import("multiplexed.zig");
const validation = @import("validation.zig");
const owner_mod = @import("owner.zig");
const shared = @import("c_abi_shared");

const crypto = @import("foundation").crypto;
const Adapter = multiplexed.Adapter;
const failureChainFromProvider = owner_mod.failureChainFromProvider;
const providerFailureIsEmpty = owner_mod.providerFailureIsEmpty;

fn of(ctx: *anyopaque) *Adapter {
    return @ptrCast(@alignCast(ctx));
}

pub fn tryRead(ctx: *anyopaque, conn: usize, buf: []u8) isize {
    const self = of(ctx);
    const got = self.table.try_read.?(self.table.ctx, @intCast(conn), buf.ptr, buf.len);
    if (!validation.multiplexedIoResultValid(got, buf.len)) {
        self.failContract(if (got < 0)
            "try_read returned an undocumented negative status"
        else
            "try_read returned more bytes than its capacity");
        return -1;
    }
    return got;
}

pub fn tryWrite(ctx: *anyopaque, conn: usize, bytes: []const u8) isize {
    const self = of(ctx);
    const wrote = self.table.try_write.?(self.table.ctx, @intCast(conn), bytes.ptr, bytes.len);
    if (!validation.multiplexedIoResultValid(wrote, bytes.len)) {
        self.failContract(if (wrote < 0)
            "try_write returned an undocumented negative status"
        else
            "try_write consumed more bytes than supplied");
        return -1;
    }
    return wrote;
}

pub fn close(ctx: *anyopaque, conn: usize) net.multiplexed_resident.TeardownOutcome {
    const self = of(ctx);
    var report = shared.transport_provider.emptyProviderFailure();
    const code = self.table.conn_close.?(self.table.ctx, @intCast(conn), &report);
    return self.teardownOutcome(code, report, "conn_close");
}

pub fn takeFailure(ctx: *anyopaque, conn: usize) ?foundation.FailureChain {
    const self = of(ctx);
    var report = std.mem.zeroes(shared.GlowcapProviderFailure);
    self.table.conn_take_failure.?(self.table.ctx, @intCast(conn), &report);
    if (providerFailureIsEmpty(report)) return null;
    return failureChainFromProvider(report.result, report) catch {
        self.failContract("multiplexed conn_take_failure returned an invalid report");
        return foundation.FailureChain.init(error.ProviderContract);
    };
}

pub fn remoteKey(ctx: *anyopaque, conn: usize) net.multiplexed_resident.ContractError!?crypto.PeerKey {
    const self = of(ctx);
    var key: [crypto.PEER_KEY_BYTES]u8 = undefined;
    const result = self.table.conn_remote_key.?(self.table.ctx, @intCast(conn), &key);
    return switch (result) {
        0 => null,
        1 => crypto.PeerKey.fromBytes(key),
        else => {
            self.failContract("conn_remote_key returned an invalid status");
            return error.ProviderContract;
        },
    };
}
