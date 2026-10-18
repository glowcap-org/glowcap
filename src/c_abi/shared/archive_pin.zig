//! Keep a shared archive mapped for the rest of its process.
//!
//! `std.Io.Threaded` detaches its worker threads, and its `deinit` returns
//! when their wait group finishes: a worker's final wake runs after that, in
//! the archive's code. An embedder that unloads the archive once its last
//! handle is released (Deno closes every FFI library at teardown) unmaps the
//! code a worker is still leaving, and the worker faults. So the archive
//! declares itself resident the way the loader states it, `RTLD_NODELETE`
//! promoted onto the already-loaded object with `RTLD_NOLOAD`, from an entry
//! the loader runs when it maps the archive.
//! `tools/check/archive_resident.py` holds every installed libc-linked ELF
//! archive to this, and macOS runs the same entry without an install check.
//!
//! Only a dynamic library that links libc emits the entry: libc is where the
//! loader's verbs live, and every thread-owning archive links it (`build.zig`
//! names why). A libc-free archive runs nothing after its last call returns.
//! A static archive is part of its executable, and a test or tool that
//! imports this module as code owns no mapping of its own.

const std = @import("std");
const builtin = @import("builtin");

const emits_entry = builtin.output_mode == .Lib and builtin.link_mode == .dynamic and
    builtin.link_libc and (builtin.object_format == .elf or builtin.object_format == .macho);

comptime {
    if (emits_entry) @export(&entry, .{
        .name = "glowcap_archive_pin_entry",
        .section = switch (builtin.object_format) {
            .elf => ".init_array",
            .macho => "__DATA,__mod_init_func",
            else => unreachable,
        },
        .visibility = .hidden,
    });
}

const entry: *const fn () callconv(.c) void = &pinResident;

/// `Dl_info`, shared by glibc, musl, and macOS.
const DlInfo = extern struct {
    fname: ?[*:0]const u8,
    fbase: ?*anyopaque,
    sname: ?[*:0]const u8,
    saddr: ?*anyopaque,
};

extern "c" fn dladdr(addr: ?*const anyopaque, info: *DlInfo) c_int;

fn pinResident() callconv(.c) void {
    var info: DlInfo = undefined;
    // tolerant: an address the loader cannot place belongs to no mapping it could unload.
    if (dladdr(@ptrCast(&pinResident), &info) == 0) return;
    const path = info.fname orelse return;
    // tolerant: null means the loader holds no library under this name, so nothing unloads it.
    _ = std.c.dlopen(path, .{ .LAZY = true, .NOLOAD = true, .NODELETE = true });
}
