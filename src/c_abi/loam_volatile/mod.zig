//! Optional in-memory execution companion. It creates no Host or actor
//! runtime, and its store lives until release.
pub const std_options = @import("c_abi_shared").library_options;
const c = @import("c_abi_loam");
const bridge = c.embedding;
const shared = @import("c_abi_shared");
const loam = @import("loam_core");
pub const Serialized = @import("serialized.zig").Serialized;
pub const GlowcapLoamVolatile = opaque {};
pub const symbols = @import("symbols.zig");
const Executor = bridge.executor.Executor(Serialized);

/// A store in memory exists only from its creation, so opening an existing
/// one finds none, and bootstrap creates.
const Opener = struct {
    capacity_bytes: usize,

    pub fn open(self: Opener, identity: loam.StoreId, mode: loam.OpenMode) !Serialized {
        if (mode == .open) return error.MissingStore;
        return Serialized.open(shared.library_allocator, identity, self.capacity_bytes);
    }
};

pub fn glowcap_loam_volatile_open(store_id: ?[*]const u8, create: u32, capacity_bytes: usize, schemas: ?[*]const c.GlowcapLoamSchema, schema_count: usize, limits: ?*const c.GlowcapLoamLimits, out_storage: ?*?*GlowcapLoamVolatile, out_store: ?*?*c.GlowcapLoamStore) callconv(.c) i32 {
    return Executor.open(store_id, create, schemas, schema_count, limits, @ptrCast(out_storage), out_store, Opener{ .capacity_bytes = capacity_bytes });
}
pub fn glowcap_loam_volatile_release(raw: ?*GlowcapLoamVolatile) callconv(.c) i32 {
    return Executor.release(raw);
}
pub fn glowcap_loam_volatile_work_run(raw: ?*GlowcapLoamVolatile, work_handle: ?*c.GlowcapLoamWork) callconv(.c) i32 {
    return (Executor.from(raw) catch |err| return bridge.code(err)).workRun(work_handle);
}
pub fn glowcap_loam_volatile_restore(raw: ?*GlowcapLoamVolatile, attachment: ?*c.GlowcapLoamAttachment, object: ?*const c.GlowcapLoamObject, out_ref: ?*shared.GlowcapReference) callconv(.c) i32 {
    return (Executor.from(raw) catch |err| return bridge.code(err)).restore(attachment, object, out_ref);
}
pub fn glowcap_loam_volatile_commit(raw: ?*GlowcapLoamVolatile) callconv(.c) i32 {
    return (Executor.from(raw) catch |err| return bridge.code(err)).commit();
}
pub fn glowcap_loam_volatile_collect(raw: ?*GlowcapLoamVolatile, work_limit: usize) callconv(.c) i32 {
    return (Executor.from(raw) catch |err| return bridge.code(err)).collect(work_limit);
}
pub fn glowcap_loam_volatile_last_error(buf: ?[*]u8, len: usize) callconv(.c) usize {
    return shared.lastErrorRead(buf, len);
}

pub const contract_layouts = [_]shared.archive_contract.Layout{};
pub const GLOWCAP_LOAM_VOLATILE_ARCHIVE_FINGERPRINT = shared.archive_contract.fingerprint("glowcap_loam_volatile", @This(), .{ &shared.contract_layouts, &contract_layouts });
pub fn glowcap_loam_volatile_archive_fingerprint() callconv(.c) u64 {
    return GLOWCAP_LOAM_VOLATILE_ARCHIVE_FINGERPRINT;
}

pub fn glowcap_loam_volatile_recover(raw: ?*GlowcapLoamVolatile) callconv(.c) i32 {
    return (Executor.from(raw) catch |err| return bridge.code(err)).recover();
}

pub fn glowcap_loam_volatile_clear_last_error() callconv(.c) void {
    shared.lastErrorClear();
}
