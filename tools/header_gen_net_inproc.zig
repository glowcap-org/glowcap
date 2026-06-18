//! Generates `include/pancake_net_transport_inproc.h` from the Zig
//! `c_abi_net_transport_inproc` source.
//!
//! The in-process transport's public C ABI is a separate archive from
//! `libpancake_ocapn` (ADR-0059), so it gets its own header. As with
//! `tools/header_gen.zig`, the function signatures are *reflected* from the real
//! `src/c_abi/net_transport/inproc/mod.zig` exports, so the header cannot
//! disagree with the implementation, and the prose lives here.
//! `zig build gen-header-net-transport-inproc-check` is the staleness gate;
//! `zig build gen-header-net-transport-inproc` is the fixer.
//!
//! The shared frame/peer/context vocabulary (`PancakeFrame`,
//! `PancakeManagedFrame`, `PancakeContext`) is declared in `pancake_ocapn.h`,
//! which this header includes; only the three in-process handles and the
//! `pancake_inproc_*` prototypes are new here.

const std = @import("std");
const c = @import("c_abi_net_transport_inproc");

pub const header_path = "include/pancake_net_transport_inproc.h";

// Every prototype the header emits, in order. `emitFn` refuses a name missing
// here; the comptime guard below holds the table against the real
// `c_abi_net_transport_inproc` declarations in both directions, so a new
// `pub export fn pancake_inproc_*` cannot silently miss the header while the
// gate stays green.
const emitted_fns = [_][]const u8{
    "pancake_inproc_netlayer_new",
    "pancake_inproc_netlayer_new_in",
    "pancake_inproc_netlayer_release",
    "pancake_inproc_connect",
    "pancake_inproc_listen",
    "pancake_inproc_accept",
    "pancake_inproc_conn_read_frame",
    "pancake_inproc_conn_write_frame",
    "pancake_inproc_conn_release",
    "pancake_inproc_listener_release",
    "pancake_inproc_last_error",
    "pancake_inproc_clear_last_error",
};

// Coverage guard, both directions: every `pub export fn pancake_inproc_*` in
// `c_abi_net_transport_inproc` must be listed, and every listed name must be a
// real function.
comptime {
    @setEvalBranchQuota(20000);
    for (@typeInfo(c).@"struct".decls) |decl| {
        if (!std.mem.startsWith(u8, decl.name, "pancake_inproc_")) continue;
        if (@typeInfo(@TypeOf(@field(c, decl.name))) != .@"fn") continue;
        var found = false;
        for (emitted_fns) |name| {
            if (std.mem.eql(u8, name, decl.name)) found = true;
        }
        if (!found) @compileError("function in c_abi_net_transport_inproc but not emitted to pancake_net_transport_inproc.h: " ++ decl.name);
    }
    for (emitted_fns) |name| {
        if (!@hasDecl(c, name)) @compileError("emitted_fns lists '" ++ name ++ "' but c_abi_net_transport_inproc has no such declaration");
        if (@typeInfo(@TypeOf(@field(c, name))) != .@"fn") @compileError("emitted_fns entry '" ++ name ++ "' is not a c_abi_net_transport_inproc function");
    }
}

/// Map a Zig type to its C spelling — reflection-driven, so a parameter type
/// change in `c_abi_net_transport_inproc` flows into the header automatically.
fn cType(comptime T: type) []const u8 {
    return switch (T) {
        u8 => "uint8_t",
        u16 => "uint16_t",
        u32 => "uint32_t",
        u64 => "uint64_t",
        i32 => "int32_t",
        i64 => "int64_t",
        usize => "size_t",
        isize => "intptr_t",
        void => "void",
        anyopaque => "void",
        else => switch (@typeInfo(T)) {
            .optional => |o| cType(o.child),
            .pointer => |p| blk: {
                const child = cType(p.child);
                if (child.len > 0 and child[child.len - 1] == '*') break :blk child ++ "*";
                const prefix = if (p.is_const) "const " else "";
                break :blk prefix ++ child ++ " *";
            },
            .@"struct", .@"opaque" => baseName(T),
            else => @compileError("no C mapping for " ++ @typeName(T)),
        },
    };
}

/// `c_abi_net_transport_inproc.PancakeInprocConn` → `PancakeInprocConn` (strip the path).
fn baseName(comptime T: type) []const u8 {
    const name = @typeName(T);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    return if (dot) |i| name[i + 1 ..] else name;
}

const Buf = std.ArrayList(u8);

fn line(b: *Buf, gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    try b.print(gpa, fmt ++ "\n", args);
}

fn emitDoc(b: *Buf, gpa: std.mem.Allocator, comptime doc: []const u8) !void {
    const lines = comptime blk: {
        @setEvalBranchQuota(8000);
        var ls: []const []const u8 = &.{};
        var it = std.mem.splitScalar(u8, doc, '\n');
        while (it.next()) |l| ls = ls ++ .{l};
        break :blk ls;
    };
    inline for (lines, 0..) |l, i| {
        const prefix = if (i == 0) "/* " else if (l.len == 0) "" else "   ";
        const suffix = if (i == lines.len - 1) " */" else "";
        try line(b, gpa, "{s}{s}{s}", .{ prefix, l, suffix });
    }
}

fn emitFn(
    b: *Buf,
    gpa: std.mem.Allocator,
    comptime fn_name: []const u8,
    comptime param_names: []const []const u8,
    comptime doc: []const u8,
) !void {
    comptime {
        var listed = false;
        for (emitted_fns) |name| {
            if (std.mem.eql(u8, name, fn_name)) listed = true;
        }
        if (!listed) @compileError("emitFn called for '" ++ fn_name ++ "' which is missing from emitted_fns");
        if (doc.len == 0) @compileError("prototype '" ++ fn_name ++ "' has no header doc; write the contract here");
    }
    const info = @typeInfo(@TypeOf(@field(c, fn_name))).@"fn";
    if (info.params.len != param_names.len) @compileError("param name count mismatch for " ++ fn_name);
    try emitDoc(b, gpa, doc);

    try b.print(gpa, "{s} {s}(", .{ comptime cType(info.return_type.?), fn_name });
    if (info.params.len == 0) try b.appendSlice(gpa, "void");
    inline for (info.params, param_names, 0..) |p, pname, i| {
        const ty = comptime cType(p.type.?);
        const sep = if (i == 0) "" else ", ";
        const space = if (ty.len > 0 and ty[ty.len - 1] == '*') "" else " ";
        try b.print(gpa, "{s}{s}{s}{s}", .{ sep, ty, space, pname });
    }
    try b.appendSlice(gpa, ");\n");
}

/// Build the full header text. Caller owns the returned bytes.
pub fn generate(gpa: std.mem.Allocator) ![]u8 {
    var b: Buf = .empty;
    errdefer b.deinit(gpa);

    try b.appendSlice(gpa,
        \\/* Generated from src/c_abi/net_transport/inproc/mod.zig by tools/header_gen_net_inproc.zig.
        \\   Do not edit by hand: run `zig build gen-header-net-transport-inproc`.
        \\   Function signatures are reflected from the Zig source, so this header
        \\   cannot drift from the implementation.
        \\
        \\   The in-process transport's public C ABI: a separate archive
        \\   (libpancake_net_transport_inproc) from libpancake_ocapn (ADR-0059). It
        \\   is a companion, not a superset: it exports only the pancake_inproc_*
        \\   family and shares no core symbol with libpancake_ocapn, so a consumer
        \\   links BOTH archives and includes BOTH headers. The shared frame, peer,
        \\   and context vocabulary lives in pancake_ocapn.h (included below) and
        \\   the archives agree on its layout; only the three in-process handles and
        \\   the pancake_inproc_* prototypes are declared here. The in-process
        \\   family has its own last-error slot, read through
        \\   pancake_inproc_last_error rather than pancake_ocapn's
        \\   pancake_last_error. */
        \\#ifndef PANCAKE_NET_TRANSPORT_INPROC_H
        \\#define PANCAKE_NET_TRANSPORT_INPROC_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include "pancake_ocapn.h"
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    );

    try emitDoc(&b, gpa,
        \\Orientation: the socket-free sibling of the TCP endpoints (pancake_net_transport_tcp.h):
        \\two peers in one process wired by in-process pipes, no kernel transport
        \\and no file descriptors. Same host-owns-the-peer frame shuttle and same
        \\netlayer lifecycle — create the netlayer, make connections/listeners from
        \\it, release them, then release it — but a listener binds to a string
        \\designator (any opaque token, not a host:port) and a dialer names that
        \\designator. This is the path a binding's smoke test dials to run a full
        \\OCapN conversation without touching a socket. Blocking; in-process only.
    );

    try b.appendSlice(gpa,
        \\
        \\/* An in-process netlayer: the switchboard plus the one owned I/O backend
        \\   its pipes block on. Created by pancake_inproc_netlayer_new; released by
        \\   pancake_inproc_netlayer_release after every endpoint is released. */
        \\typedef struct PancakeInprocNetlayer PancakeInprocNetlayer;
        \\/* One in-process connection carrying one OCapN session, framed on the
        \\   netlayer's codec. Created by pancake_inproc_connect or
        \\   pancake_inproc_accept; released by pancake_inproc_conn_release. */
        \\typedef struct PancakeInprocConn PancakeInprocConn;
        \\/* A bound in-process listener. Created by pancake_inproc_listen; released
        \\   by pancake_inproc_listener_release. */
        \\typedef struct PancakeInprocListener PancakeInprocListener;
        \\
        \\
    );

    try emitFn(&b, gpa, "pancake_inproc_netlayer_new", &.{"out_netlayer"}, "Create the in-process netlayer handle that owns the switchboard and its I/O\nbackend, allocating through the library allocator. Release with\npancake_inproc_netlayer_release after releasing every endpoint made from it.");
    try emitFn(&b, gpa, "pancake_inproc_netlayer_new_in", &.{ "context", "out_netlayer" }, "Create an in-process netlayer whose switchboard, backend, and per-connection\nbuffers allocate through `context`.");
    try emitFn(&b, gpa, "pancake_inproc_netlayer_release", &.{"netlayer"}, "Release the in-process netlayer. Every connection and listener made from it\nmust already be released.");
    try emitFn(&b, gpa, "pancake_inproc_connect", &.{ "netlayer", "designator", "designator_len", "codec", "max_frame_bytes", "out_conn" }, "Dial the listener bound at `designator` and return an owned connection\nframing on `codec`, refusing inbound frames over max_frame_bytes.\n`designator` is borrowed. PANCAKE_ERR_INVALID_ARGUMENT for a bad codec or a\nzero frame cap; PANCAKE_ERR_IO (see pancake_inproc_last_error) when no listener\nis bound there. Release with pancake_inproc_conn_release.");
    try emitFn(&b, gpa, "pancake_inproc_listen", &.{ "netlayer", "designator", "designator_len", "out_listener" }, "Bind an in-process listener on `designator` (any opaque token; borrowed).\nPANCAKE_ERR_INVALID_ARGUMENT for an empty or already-bound designator. Release\nwith pancake_inproc_listener_release.");
    try emitFn(&b, gpa, "pancake_inproc_accept", &.{ "listener", "codec", "max_frame_bytes", "out_conn" }, "Block until a dialer connects, returning an owned connection framing on\n`codec`. Same argument and release contract as pancake_inproc_connect.");
    try emitFn(&b, gpa, "pancake_inproc_conn_read_frame", &.{ "conn", "out_frame" }, "Block for one whole frame as an owned managed frame. Returns\nPANCAKE_ERR_CLOSED on graceful EOF.");
    try emitFn(&b, gpa, "pancake_inproc_conn_write_frame", &.{ "conn", "frame" }, "Write one frame's borrowed bytes into the partner's pipe.");
    try emitFn(&b, gpa, "pancake_inproc_conn_release", &.{"conn"}, "Close the connection and free the handle; do not use `conn` afterward.");
    try emitFn(&b, gpa, "pancake_inproc_listener_release", &.{"listener"}, "Close the listener and free the handle; do not use `listener` afterward.");

    try emitFn(&b, gpa, "pancake_inproc_last_error", &.{ "out_buf", "cap" }, "Copy the calling thread's last in-process-transport error into out_buf — the\ninproc sibling of pancake_last_error, reading this archive's own per-thread\nslot. A pancake_inproc_* call that returns a cause-bearing code records it\nhere. Copies at most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or\ncap 0 queries the length. Returns the full message length, or 0 when none is\nset.");
    try emitFn(&b, gpa, "pancake_inproc_clear_last_error", &.{}, "Clear the calling thread's in-process-transport last-error slot.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* PANCAKE_NET_TRANSPORT_INPROC_H */
        \\
    );

    inline for (emitted_fns) |name| {
        if (std.mem.indexOf(u8, b.items, " " ++ name ++ "(") == null) {
            std.debug.print("gen-header-net-transport-inproc: emitted_fns lists `{s}` but no emitFn call emitted it\n", .{name});
            return error.MissingEmittedFunction;
        }
    }
    return b.toOwnedSlice(gpa);
}
