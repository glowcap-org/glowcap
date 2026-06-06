//! Generates `include/pancake.h` from the Zig `c_abi` source.
//!
//! This is the single source of truth for the C ABI surface: struct layouts,
//! constant values, and function signatures are *reflected* from the real
//! `c_abi` types (so the header cannot disagree with the implementation), and
//! the prose lives here, in the generator. `zig build gen-header` writes the
//! header; a test re-runs this and asserts the committed header matches, so a
//! change to `c_abi` that is not regenerated fails `zig build check`.

const std = @import("std");
const c = @import("pancake").c_abi;

// The constant names the header emits, grouped for section comments. The version
// macros are emitted inline; these two groups plus the version triple are the
// complete set, guarded below so a new c_abi constant cannot be silently dropped.
const version_consts = [_][]const u8{
    "PANCAKE_VERSION_MAJOR", "PANCAKE_VERSION_MINOR", "PANCAKE_VERSION_PATCH",
};
const error_consts = [_][]const u8{
    "PANCAKE_OK",                 "PANCAKE_ERR_NULL_POINTER",
    "PANCAKE_ERR_INVALID_HANDLE", "PANCAKE_ERR_INVALID_ARGUMENT",
    "PANCAKE_ERR_SESSION",        "PANCAKE_ERR_CODEC",
    "PANCAKE_ERR_INTERNAL",       "PANCAKE_ERR_WOULD_BLOCK",
    "PANCAKE_ERR_CLOSED",         "PANCAKE_ERR_IO",
    "PANCAKE_ERR_MALFORMED",      "PANCAKE_ERR_FRAME_TOO_LARGE",
    "PANCAKE_ERR_WRONG_EVENT",    "PANCAKE_ERR_UNSUPPORTED_VALUE",
};
const discriminant_consts = [_][]const u8{
    "PANCAKE_CODEC_SYRUP",      "PANCAKE_CODEC_CAPNP",
    "PANCAKE_FRAME_SHAPE_BYTE", "PANCAKE_FRAME_SHAPE_WORD",
    "PANCAKE_EVENT_DELIVER",    "PANCAKE_EVENT_RESOLVE",
    "PANCAKE_EVENT_GC_EXPORT",  "PANCAKE_EVENT_GC_ANSWER",
    "PANCAKE_EVENT_HANDOFF",    "PANCAKE_EVENT_START_SESSION",
    "PANCAKE_EVENT_ABORT",      "PANCAKE_EVENT_LISTEN",
    "PANCAKE_EVENT_GET",        "PANCAKE_EVENT_INDEX",
    "PANCAKE_REF_NEAR",         "PANCAKE_REF_FAR",
    "PANCAKE_REF_PROMISE",      "PANCAKE_REF_STURDY",
    "PANCAKE_REF_BROKEN",       "PANCAKE_REF_OBJECT",
    "PANCAKE_REF_PROMISE_KIND", "PANCAKE_ARG_INTEGER",
    "PANCAKE_ARG_FLOAT64",      "PANCAKE_ARG_BOOLEAN",
    "PANCAKE_ARG_BYTES",        "PANCAKE_ARG_STRING",
    "PANCAKE_ARG_SYMBOL",       "PANCAKE_ARG_VOID",
    "PANCAKE_ARG_REFERENCE",    "PANCAKE_ARG_LIST",
    "PANCAKE_ARG_SET",          "PANCAKE_ARG_TAGGED",
    "PANCAKE_ARG_KEYWORD",      "PANCAKE_RESOLUTION_FULFILL",
    "PANCAKE_RESOLUTION_BREAK",
};

// Compile-time coverage guard: every `pub const PANCAKE_*` integer in `c_abi`
// must appear in an emitted group, so adding a constant without listing it for
// the header fails to compile instead of silently dropping from pancake.h.
comptime {
    @setEvalBranchQuota(20000);
    const all = version_consts ++ error_consts ++ discriminant_consts;
    for (@typeInfo(c).@"struct".decls) |decl| {
        if (!std.mem.startsWith(u8, decl.name, "PANCAKE_")) continue;
        if (@typeInfo(@TypeOf(@field(c, decl.name))) != .int) continue;
        var found = false;
        for (all) |name| {
            if (std.mem.eql(u8, name, decl.name)) found = true;
        }
        if (!found) @compileError("constant in c_abi but not emitted to pancake.h: " ++ decl.name);
    }
}

/// Map a Zig type to its C spelling. Reflection-driven, so a field/parameter
/// type change in `c_abi` flows into the header automatically.
fn cType(comptime T: type) []const u8 {
    // The three function-pointer typedefs the header names.
    if (T == c.ReleaseFn or T == ?c.ReleaseFn) return "PancakeReleaseFn";
    if (T == c.PancakeAllocFn or T == ?c.PancakeAllocFn) return "PancakeAllocFn";
    if (T == c.PancakeFreeFn or T == ?c.PancakeFreeFn) return "PancakeFreeFn";

    return switch (T) {
        u8 => "uint8_t",
        u16 => "uint16_t",
        u32 => "uint32_t",
        u64 => "uint64_t",
        i32 => "int32_t",
        i64 => "int64_t",
        usize => "size_t",
        f64 => "double",
        void => "void",
        anyopaque => "void",
        else => switch (@typeInfo(T)) {
            .optional => |o| cType(o.child), // nullable in C is the same spelling
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

/// `c_abi.PancakeFrame` → `PancakeFrame` (strip the module path).
fn baseName(comptime T: type) []const u8 {
    const name = @typeName(T);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    return if (dot) |i| name[i + 1 ..] else name;
}

const Buf = std.ArrayList(u8);

fn line(b: *Buf, gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    try b.print(gpa, fmt ++ "\n", args);
}

/// Emit `#define NAME <value>` with the value reflected from `c_abi`; unsigned
/// constants get a `u` suffix to match their Zig type.
fn emitConst(b: *Buf, gpa: std.mem.Allocator, comptime name: []const u8) !void {
    const value = @field(c, name);
    const suffix = if (@typeInfo(@TypeOf(value)).int.signedness == .unsigned) "u" else "";
    try line(b, gpa, "#define {s} {d}{s}", .{ name, value, suffix });
}

/// Emit a struct typedef, fields reflected from the real `c_abi` type. `docs`
/// gives an optional `/* ... */` line per field (in field order; "" to skip).
fn emitStruct(
    b: *Buf,
    gpa: std.mem.Allocator,
    comptime T: type,
    comptime name: []const u8,
    comptime docs: []const []const u8,
) !void {
    const fields = @typeInfo(T).@"struct".fields;
    if (docs.len != fields.len) @compileError("field doc count mismatch for " ++ name);
    try line(b, gpa, "typedef struct {s} {{", .{name});
    inline for (fields, docs) |f, doc| {
        if (doc.len != 0) try line(b, gpa, "    /* {s} */", .{doc});
        // A struct that references itself uses `struct Name *` in C.
        const ty = comptime selfRef(T, f.type, name);
        const space = if (ty.len > 0 and ty[ty.len - 1] == '*') "" else " ";
        try line(b, gpa, "    {s}{s}{s};", .{ ty, space, f.name });
    }
    try line(b, gpa, "}} {s};", .{name});
}

/// A pointer-to-self field must spell `const struct Name *` in C (the typedef is
/// not complete yet at that point).
fn selfRef(comptime Owner: type, comptime FieldT: type, comptime name: []const u8) []const u8 {
    if (@typeInfo(FieldT) == .optional) {
        const child = @typeInfo(FieldT).optional.child;
        if (@typeInfo(child) == .pointer and @typeInfo(child).pointer.child == Owner) {
            const prefix = if (@typeInfo(child).pointer.is_const) "const " else "";
            return prefix ++ "struct " ++ name ++ " *";
        }
    }
    return cType(FieldT);
}

/// Emit a function prototype: return type and parameter types are reflected from
/// the real export; `param_names` and `doc` are curated here. A parameter added
/// in `c_abi` without a name here is a compile error.
fn emitFn(
    b: *Buf,
    gpa: std.mem.Allocator,
    comptime fn_name: []const u8,
    comptime param_names: []const []const u8,
    comptime doc: []const u8,
) !void {
    const info = @typeInfo(@TypeOf(@field(c, fn_name))).@"fn";
    if (info.params.len != param_names.len) @compileError("param name count mismatch for " ++ fn_name);
    if (doc.len != 0) try emitDoc(b, gpa, doc);

    try b.print(gpa, "{s} {s}(", .{ comptime cType(info.return_type.?), fn_name });
    inline for (info.params, param_names, 0..) |p, pname, i| {
        const ty = comptime cType(p.type.?);
        const sep = if (i == 0) "" else ", ";
        const space = if (ty.len > 0 and ty[ty.len - 1] == '*') "" else " ";
        try b.print(gpa, "{s}{s}{s}{s}", .{ sep, ty, space, pname });
    }
    try b.appendSlice(gpa, ");\n");
}

fn emitDoc(b: *Buf, gpa: std.mem.Allocator, comptime doc: []const u8) !void {
    const lines = comptime blk: {
        var ls: []const []const u8 = &.{};
        var it = std.mem.splitScalar(u8, doc, '\n');
        while (it.next()) |l| ls = ls ++ .{l};
        break :blk ls;
    };
    inline for (lines, 0..) |l, i| {
        const prefix = if (i == 0) "/* " else "   ";
        const suffix = if (i == lines.len - 1) " */" else "";
        try line(b, gpa, "{s}{s}{s}", .{ prefix, l, suffix });
    }
}

fn section(b: *Buf, gpa: std.mem.Allocator, comptime title: []const u8) !void {
    try b.appendSlice(gpa, "\n");
    try line(b, gpa, "/* ── {s} ── */", .{title});
}

pub const header_path = "include/pancake.h";

/// Build the full header text. Caller owns the returned bytes.
pub fn generate(gpa: std.mem.Allocator) ![]u8 {
    var b: Buf = .empty;
    errdefer b.deinit(gpa);

    try b.appendSlice(gpa,
        \\/* Generated from src/c_abi/mod.zig by tools/header_gen.zig.
        \\   Do not edit by hand: run `zig build gen-header`. Struct layouts,
        \\   constant values, and function signatures are reflected from the Zig
        \\   source, so this header cannot drift from the implementation. */
        \\#ifndef PANCAKE_H
        \\#define PANCAKE_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    );

    try emitDoc(&b, gpa,
        \\ABI version. While MAJOR is 0 the ABI is unstable: any release may change
        \\symbols, layouts, or return codes. These macros are the version the header
        \\was compiled against; `pancake_abi_version` reports the linked library's.
    );
    try emitConst(&b, gpa, "PANCAKE_VERSION_MAJOR");
    try emitConst(&b, gpa, "PANCAKE_VERSION_MINOR");
    try emitConst(&b, gpa, "PANCAKE_VERSION_PATCH");
    try emitFn(&b, gpa, "pancake_abi_version", &.{ "out_major", "out_minor", "out_patch" }, "Report the ABI version the linked library implements; any out-pointer may\nbe NULL to skip that component.");

    try section(&b, gpa, "Return codes");
    inline for (error_consts) |name| try emitConst(&b, gpa, name);

    try section(&b, gpa, "Discriminants");
    inline for (discriminant_consts) |name| try emitConst(&b, gpa, name);

    try section(&b, gpa, "Frames and events");
    try b.appendSlice(gpa, "\n");
    try emitStruct(&b, gpa, c.PancakeFrame, "PancakeFrame", &.{
        "Borrowed for one call; the caller keeps owning the bytes.", "", "",
    });
    try b.appendSlice(gpa,
        \\
        \\typedef struct PancakeManagedFrame PancakeManagedFrame;
        \\typedef struct PancakePeer PancakePeer;
        \\typedef void (*PancakeReleaseFn)(PancakeManagedFrame *frame);
        \\
    );
    try emitStruct(&b, gpa, c.PancakeManagedFrame, "PancakeManagedFrame", &.{
        "Owned and self-releasing: call `pancake_managed_frame_release` exactly\n       once (repeated release is safe).",
        "",
        "",
        "",
        "",
    });
    try b.appendSlice(gpa, "\n");
    try emitStruct(&b, gpa, c.PancakeEvent, "PancakeEvent", &.{
        "",
        "Originating message bytes in the negotiated codec (no re-encode); release\n       with `pancake_event_release`.",
    });
    try b.appendSlice(gpa, "\n");
    try emitFn(&b, gpa, "pancake_managed_frame_release", &.{"frame"}, "");
    try emitFn(&b, gpa, "pancake_event_release", &.{"event"}, "");

    try section(&b, gpa, "Allocation context");
    try emitDoc(&b, gpa,
        \\A context owns allocation policy for a family of handles. The simple
        \\constructors use the library allocator; the `*_in` constructors allocate
        \\from a context you supply, and everything those handles own frees back
        \\through it. The context must outlive every handle created in it.
    );
    try b.appendSlice(gpa,
        \\typedef struct PancakeContext PancakeContext;
        \\typedef void *(*PancakeAllocFn)(void *user_data, size_t size, size_t alignment);
        \\typedef void (*PancakeFreeFn)(void *user_data, void *ptr, size_t size, size_t alignment);
        \\
    );
    try emitStruct(&b, gpa, c.PancakeAllocator, "PancakeAllocator", &.{
        "required", "required", "optional; passed back to every callback",
    });
    try b.appendSlice(gpa, "\n");
    try emitFn(&b, gpa, "pancake_context_new_default", &.{"out_context"}, "Create a context backed by the library-owned allocator.");
    try emitFn(&b, gpa, "pancake_context_new_with_allocator", &.{ "allocator", "out_context" }, "Create a context that routes every allocation through host callbacks.\nThe callbacks must be thread-safe.");
    try emitFn(&b, gpa, "pancake_context_release", &.{"context"}, "Release a context after every handle created in it has been released.");

    try section(&b, gpa, "Peer lifecycle and frame I/O");
    try emitFn(&b, gpa, "pancake_peer_new", &.{"out_peer"}, "");
    try emitFn(&b, gpa, "pancake_peer_new_in", &.{ "context", "out_peer" }, "Create a peer whose allocations route through `context`.");
    try emitFn(&b, gpa, "pancake_peer_release", &.{"peer"}, "");
    try emitFn(&b, gpa, "pancake_peer_feed_borrowed", &.{ "peer", "frame" }, "Dispatch a borrowed frame synchronously; the caller retains ownership.");
    try emitFn(&b, gpa, "pancake_peer_feed_owned", &.{ "peer", "frame" }, "Transfer a managed frame into the inbound queue for `pancake_peer_step`;\non success the caller's descriptor is cleared.");
    try emitFn(&b, gpa, "pancake_peer_recv_stream", &.{ "peer", "bytes", "len", "out_consumed" }, "Frame and dispatch one inbound frame from a byte-stream buffer, writing the\nbytes consumed into `out_consumed`. PANCAKE_ERR_WOULD_BLOCK (out_consumed 0)\nmeans the buffer holds only part of a frame — read more and retry. The\nsans-I/O stream-input primitive: the caller owns the socket and buffer.");
    try emitFn(&b, gpa, "pancake_peer_step", &.{"peer"}, "");
    try emitFn(&b, gpa, "pancake_peer_take_outbound", &.{ "peer", "out_frame" }, "Take the next outbound frame as an owned managed frame, or\nPANCAKE_ERR_WOULD_BLOCK when the queue is empty.");
    try emitFn(&b, gpa, "pancake_peer_poll_event", &.{ "peer", "out_event" }, "Take the next event (opaque frame in the negotiated codec), or\nPANCAKE_ERR_WOULD_BLOCK when none is queued.");

    try section(&b, gpa, "Capability registration");
    try emitFn(&b, gpa, "pancake_peer_register_bootstrap_cap", &.{ "peer", "swissnum", "swissnum_len", "out_export_id" }, "Expose a local capability behind `swissnum` for inbound bootstrap-fetch;\nwrites the allocated export id. `swissnum` is borrowed.");
    try emitFn(&b, gpa, "pancake_peer_register_export", &.{ "peer", "export_id" }, "Register a local export position so deliveries to it surface as events.");
    try emitFn(&b, gpa, "pancake_peer_register_import", &.{ "peer", "import_id" }, "Track a partner-hosted import this peer holds, so a _FAR send_deliver to it\nis admitted (e.g. the bootstrap import).");

    try section(&b, gpa, "Typed OCapN driving surface");
    try emitDoc(&b, gpa,
        \\Construct a call and read a delivery as structured values without authoring
        \\a codec. Send borrows the C structs for the call (the clone owns the copy);
        \\receive projects views aliasing an internal arena, released by `*_free`.
        \\These struct layouts are frozen ABI (ADR-0032).
    );
    try emitStruct(&b, gpa, c.PancakeReference, "PancakeReference", &.{
        "_NEAR export id, _FAR import id, or _PROMISE answer id.", "object/promise for near/far", "",
    });
    try b.appendSlice(gpa, "\n");
    try emitStruct(&b, gpa, c.PancakeArgument, "PancakeArgument", &.{
        "selects the live field", "", "", "", "_BYTES/_STRING/_SYMBOL", "", "", "a _LIST's children", "",
    });
    try b.appendSlice(gpa, "\n");
    try emitStruct(&b, gpa, c.PancakeDeliver, "PancakeDeliver", &.{
        "", "aliases an internal arena", "", "", "", "release with pancake_deliver_free",
    });
    try b.appendSlice(gpa, "\n");
    try emitStruct(&b, gpa, c.PancakeResolve, "PancakeResolve", &.{
        "", "fulfill or break", "", "", "", "release with pancake_resolve_free",
    });
    try b.appendSlice(gpa, "\n");
    try emitFn(&b, gpa, "pancake_peer_peek_event", &.{"peer"}, "The kind of the next event without consuming it: a positive PANCAKE_EVENT_*\nor PANCAKE_ERR_WOULD_BLOCK.");
    try emitFn(&b, gpa, "pancake_peer_send_deliver", &.{ "peer", "target", "args", "args_len", "has_answer", "answer" }, "Construct and queue an op:deliver. When `has_answer` is nonzero the call\nexpects a reply on `answer`.");
    try emitFn(&b, gpa, "pancake_peer_send_resolve", &.{ "peer", "answer", "resolution_kind", "fulfill", "break_message", "break_message_len" }, "Construct and queue an op:resolve settling `answer`.");
    try emitFn(&b, gpa, "pancake_peer_poll_event_deliver", &.{ "peer", "out" }, "Take the next event as a structured deliver, or PANCAKE_ERR_WRONG_EVENT\n(left queued) / PANCAKE_ERR_WOULD_BLOCK. Release with the matching *_free.");
    try emitFn(&b, gpa, "pancake_peer_poll_event_resolve", &.{ "peer", "out" }, "");
    try emitFn(&b, gpa, "pancake_deliver_free", &.{"deliver"}, "");
    try emitFn(&b, gpa, "pancake_resolve_free", &.{"resolve"}, "");

    try section(&b, gpa, "Per-thread last error");
    try emitFn(&b, gpa, "pancake_last_error", &.{ "out_buf", "cap" }, "Copy the calling thread's last error into `out_buf` (NUL-terminated if it\nfits), returning the full length. `out_buf` may be NULL to query the length.");
    try emitFn(&b, gpa, "pancake_clear_last_error", &.{}, "");

    try section(&b, gpa, "Blocking TCP endpoints (tcp-testing-only)");
    try emitDoc(&b, gpa,
        \\The host owns the peer and shuttles whole frames. The netlayer owns the I/O
        \\backend; create it, make connections/listeners from it, then release it
        \\after every endpoint made from it is closed. Cleartext, loopback-grade.
    );
    try b.appendSlice(gpa,
        \\typedef struct PancakeTcpNetlayer PancakeTcpNetlayer;
        \\typedef struct PancakeTcpConn PancakeTcpConn;
        \\typedef struct PancakeTcpListener PancakeTcpListener;
        \\
    );
    try emitFn(&b, gpa, "pancake_tcp_netlayer_new", &.{"out_netlayer"}, "");
    try emitFn(&b, gpa, "pancake_tcp_netlayer_new_in", &.{ "context", "out_netlayer" }, "Create a netlayer whose backend and per-connection buffers allocate through\n`context`.");
    try emitFn(&b, gpa, "pancake_tcp_netlayer_release", &.{"netlayer"}, "");
    try emitFn(&b, gpa, "pancake_endpoint_tcp_testing_connect", &.{ "netlayer", "host", "host_len", "port", "codec", "max_frame_bytes", "out_conn" }, "");
    try emitFn(&b, gpa, "pancake_endpoint_tcp_testing_listen", &.{ "netlayer", "host", "host_len", "port", "out_listener" }, "");
    try emitFn(&b, gpa, "pancake_endpoint_tcp_listener_port", &.{ "listener", "out_port" }, "");
    try emitFn(&b, gpa, "pancake_endpoint_tcp_testing_accept", &.{ "listener", "codec", "max_frame_bytes", "out_conn" }, "");
    try emitFn(&b, gpa, "pancake_endpoint_tcp_read_frame", &.{ "conn", "out_frame" }, "Block for one whole frame as an owned managed frame. Returns PANCAKE_ERR_CLOSED\non graceful EOF, PANCAKE_ERR_IO on a socket fault.");
    try emitFn(&b, gpa, "pancake_endpoint_tcp_write_frame", &.{ "conn", "frame" }, "Write one frame's borrowed bytes and flush.");
    try emitFn(&b, gpa, "pancake_endpoint_tcp_conn_close", &.{"conn"}, "");
    try emitFn(&b, gpa, "pancake_endpoint_tcp_listener_close", &.{"listener"}, "");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif
        \\
    );
    return b.toOwnedSlice(gpa);
}
