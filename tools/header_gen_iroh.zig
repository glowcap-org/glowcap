//! Generates `include/pancake_iroh.h` from the Zig `c_abi_iroh` source.
//!
//! The public iroh transport C ABI is a separate artifact from `libpancake`
//! (ADR-0055), so it gets its own header. As with `tools/header_gen.zig`, the
//! function signatures are *reflected* from the real `src/c_abi/iroh.zig`
//! exports, so the header cannot disagree with the implementation, and the
//! prose lives here. `zig build gen-header-iroh-check` is the staleness gate;
//! `zig build gen-header-iroh` is the fixer. Both run cargo-free: the generator
//! reflects types only and links the sidecar stubs (`iroh_sidecar_stub.zig`).
//!
//! The shared frame/peer/context vocabulary (`PancakeFrame`,
//! `PancakeManagedFrame`, `PancakeContext`) is declared in `pancake.h`, which
//! this header includes; only the two iroh handles and the `pancake_iroh_*`
//! prototypes are new here.

const std = @import("std");
const c = @import("c_abi_iroh");

pub const header_path = "include/pancake_iroh.h";

// Every prototype the header emits, in order. `emitFn` refuses a name missing
// here; the comptime guard below holds the table against the real `c_abi_iroh`
// declarations in both directions, so a new `pub export fn pancake_iroh_*`
// cannot silently miss the header while the gate stays green.
const emitted_fns = [_][]const u8{
    "pancake_iroh_netlayer_new",
    "pancake_iroh_netlayer_new_in",
    "pancake_iroh_netlayer_close",
    "pancake_iroh_netlayer_release",
    "pancake_iroh_netlayer_node_id",
    "pancake_iroh_netlayer_direct_addrs",
    "pancake_iroh_netlayer_connect",
    "pancake_iroh_netlayer_accept",
    "pancake_iroh_conn_read_frame",
    "pancake_iroh_conn_write_frame",
    "pancake_iroh_conn_release",
};

// Coverage guard, both directions: every `pub export fn pancake_iroh_*` in
// `c_abi_iroh` must be listed, and every listed name must be a real function.
comptime {
    @setEvalBranchQuota(20000);
    for (@typeInfo(c).@"struct".decls) |decl| {
        if (!std.mem.startsWith(u8, decl.name, "pancake_iroh_")) continue;
        if (@typeInfo(@TypeOf(@field(c, decl.name))) != .@"fn") continue;
        var found = false;
        for (emitted_fns) |name| {
            if (std.mem.eql(u8, name, decl.name)) found = true;
        }
        if (!found) @compileError("function in c_abi_iroh but not emitted to pancake_iroh.h: " ++ decl.name);
    }
    for (emitted_fns) |name| {
        if (!@hasDecl(c, name)) @compileError("emitted_fns lists '" ++ name ++ "' but c_abi_iroh has no such declaration");
        if (@typeInfo(@TypeOf(@field(c, name))) != .@"fn") @compileError("emitted_fns entry '" ++ name ++ "' is not a c_abi_iroh function");
    }
}

/// Map a Zig type to its C spelling — reflection-driven, so a parameter type
/// change in `c_abi_iroh` flows into the header automatically.
fn cType(comptime T: type) []const u8 {
    return switch (T) {
        u8 => "uint8_t",
        u16 => "uint16_t",
        u32 => "uint32_t",
        u64 => "uint64_t",
        i32 => "int32_t",
        i64 => "int64_t",
        usize => "size_t",
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

/// `c_abi_iroh.PancakeIrohConn` → `PancakeIrohConn` (strip the module path).
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
        \\/* Generated from src/c_abi/iroh.zig by tools/header_gen_iroh.zig.
        \\   Do not edit by hand: run `zig build gen-header-iroh`. Function
        \\   signatures are reflected from the Zig source, so this header cannot
        \\   drift from the implementation.
        \\
        \\   The iroh transport's public C ABI: a separate artifact
        \\   (libpancake_iroh) from libpancake, because it links the Rust iroh
        \\   sidecar (ADR-0055). The artifact is a superset — it carries the
        \\   whole libpancake surface too — so a consumer loads one library and
        \\   includes both this header and pancake.h. The shared frame, peer, and
        \\   context vocabulary lives in pancake.h; only the two iroh handles and
        \\   the pancake_iroh_* prototypes are declared here.
        \\
        \\   This is NOT transports/iroh/include/pancake_iroh_sidecar.h, which is
        \\   the sidecar's internal byte-level seam (pancake_iroh_sidecar_connect,
        \\   pancake_iroh_sidecar_conn_read, ...). This is the frame-level public
        \\   surface (pancake_iroh_netlayer_*, pancake_iroh_conn_read_frame, ...). */
        \\#ifndef PANCAKE_IROH_H
        \\#define PANCAKE_IROH_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include "pancake.h"
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    );

    try emitDoc(&b, gpa,
        \\Orientation: the iroh transport is the host-driven netlayer boundary's
        \\encrypted-QUIC sibling of the blocking TCP endpoints in pancake.h. The
        \\host owns the peer: dial or accept a connection, then loop reading a
        \\whole frame (pancake_iroh_conn_read_frame), feeding it to a PancakePeer,
        \\stepping, and writing the peer's outbound frames back
        \\(pancake_iroh_conn_write_frame).
        \\
        \\The one difference from TCP is addressing: there is no host:port. A
        \\partner is dialed by its endpoint id — the canonical lowercase-hex
        \\designator pancake_iroh_netlayer_node_id prints. Whether you also need a
        \\direct-address hint string from pancake_iroh_netlayer_direct_addrs
        \\depends on the reachability the netlayer was created with: a
        \\PANCAKE_IROH_REACH_DIRECT endpoint dials by id plus hints, while a
        \\discovery endpoint resolves the partner by id alone. Carry both in the
        \\OCapN locator a peer signs (transport "iroh", the id as designator, the
        \\hints under "direct-addresses").
        \\
        \\Lifetime: release every connection before the netlayer that minted it.
        \\Threading: a connection is single-owner like a peer; serialize calls on
        \\one onto one thread. Every call blocks the calling thread (the endpoint
        \\runs its own runtime), so run accept loops and per-connection pumps on
        \\your own threads (or a binding's non-blocking FFI).
    );

    try b.appendSlice(gpa,
        \\
        \\/* An iroh netlayer: one bound QUIC endpoint plus the sidecar runtime
        \\   driving it. Created by pancake_iroh_netlayer_new; released by
        \\   pancake_iroh_netlayer_release after every connection is released. */
        \\typedef struct PancakeIrohNetlayer PancakeIrohNetlayer;
        \\/* One QUIC connection carrying one OCapN session, framed on the
        \\   netlayer's codec. Created by pancake_iroh_netlayer_connect or
        \\   _accept; released by pancake_iroh_conn_release. */
        \\typedef struct PancakeIrohConn PancakeIrohConn;
        \\
        \\/* Reachability postures for pancake_iroh_netlayer_new. The caller always
        \\   passes one — there is no default. A pancake peer never turns on relays
        \\   or a discovery service as a hidden implementation detail; the host
        \\   chooses, in the open, how the endpoint becomes reachable.
        \\     DIRECT             relay-less, lookup-less; dial by id plus
        \\                        explicit address hints (loopback/LAN).
        \\     DISCOVERY          number-0 relays + DNS/pkarr discovery; a peer is
        \\                        dialable by id alone over the internet, with
        \\                        hole-punching and NAT traversal.
        \\     DISCOVERY_NO_RELAY DNS/pkarr discovery without relays.
        \\     LOCAL_DISCOVERY    in-process shared address book; resolves by id
        \\                        alone with no relay, DNS, or hints. For tests
        \\                        and same-process embeddings, never the internet. */
        \\#define PANCAKE_IROH_REACH_DIRECT 0u
        \\#define PANCAKE_IROH_REACH_DISCOVERY 1u
        \\#define PANCAKE_IROH_REACH_DISCOVERY_NO_RELAY 2u
        \\#define PANCAKE_IROH_REACH_LOCAL_DISCOVERY 3u
        \\
        \\
    );

    try emitFn(&b, gpa, "pancake_iroh_netlayer_new", &.{ "secret_seed", "secret_seed_len", "reachability", "out_netlayer" }, "Create an iroh netlayer (one bound endpoint) allocating through the library\nallocator. secret_seed/secret_seed_len is either a 32-byte Ed25519 secret key\n(borrowed) or empty (secret_seed_len == 0) for a fresh random key; any other\nlength is PANCAKE_ERR_INVALID_ARGUMENT. reachability is one of\nPANCAKE_IROH_REACH_* and is mandatory — it decides whether the endpoint uses\nrelays or a discovery service, with no default; an unknown value is\nPANCAKE_ERR_INVALID_ARGUMENT. PANCAKE_ERR_IO (see pancake_last_error) if the\nendpoint cannot bind. Release with pancake_iroh_netlayer_release after\nreleasing every connection made from it.");
    try emitFn(&b, gpa, "pancake_iroh_netlayer_new_in", &.{ "context", "secret_seed", "secret_seed_len", "reachability", "out_netlayer" }, "As pancake_iroh_netlayer_new, allocating the netlayer, endpoint, and every\nper-connection buffer through context.");
    try emitFn(&b, gpa, "pancake_iroh_netlayer_close", &.{"netlayer"}, "Close the endpoint without releasing the handle: a blocked\npancake_iroh_netlayer_accept returns PANCAKE_ERR_IO and later dials fail.\nIdempotent. The shutdown lever for a host whose accept loop parks on another\nthread.");
    try emitFn(&b, gpa, "pancake_iroh_netlayer_release", &.{"netlayer"}, "Release the netlayer, its endpoint, and the runtime. Every connection made\nfrom it must already be released. NULL is a no-op.");
    try emitFn(&b, gpa, "pancake_iroh_netlayer_node_id", &.{ "netlayer", "out", "cap", "out_len" }, "Write this endpoint's id — its Ed25519 public key, the dialable designator —\ninto out as lowercase hex, and the byte count into out_len. cap must be at\nleast the id length (64) or the call is PANCAKE_ERR_INVALID_ARGUMENT. No\nterminator is written.");
    try emitFn(&b, gpa, "pancake_iroh_netlayer_direct_addrs", &.{ "netlayer", "out", "cap", "out_len" }, "Write this endpoint's comma-separated direct socket addresses into out (the\nhint string a partner passes to pancake_iroh_netlayer_connect) and the byte\ncount into out_len. A buffer too small is PANCAKE_ERR_INVALID_ARGUMENT; an\nendpoint with no direct addresses writes zero bytes and returns PANCAKE_OK. No\nterminator is written.");
    try emitFn(&b, gpa, "pancake_iroh_netlayer_connect", &.{ "netlayer", "node_id", "node_id_len", "addr_hints", "addr_hints_len", "codec", "max_frame_bytes", "out_conn" }, "Dial a partner by endpoint id and return an owned connection framing on codec,\nrefusing inbound frames over max_frame_bytes. node_id is the partner's\ncanonical id; addr_hints is its comma-separated direct-address list (it may be\nempty when the netlayer has a discovery posture, which resolves the partner by\nid; a DIRECT netlayer needs it); both are borrowed for the\ncall. Blocking. PANCAKE_ERR_INVALID_ARGUMENT for a bad codec, a zero frame\ncap, or a malformed id/hint; PANCAKE_ERR_IO (see pancake_last_error) when the\ndial fails. Release with pancake_iroh_conn_release.");
    try emitFn(&b, gpa, "pancake_iroh_netlayer_accept", &.{ "netlayer", "codec", "max_frame_bytes", "out_conn" }, "Block until a partner dials this endpoint, returning an owned connection\nframing on codec. Same argument and release contract as\npancake_iroh_netlayer_connect. PANCAKE_ERR_IO when the endpoint is closed (the\nshutdown lever) or the accept faults.");
    try emitFn(&b, gpa, "pancake_iroh_conn_read_frame", &.{ "conn", "out_frame" }, "Block for one whole frame as an owned managed frame (release it, or hand it to\npancake_peer_feed_owned). PANCAKE_ERR_CLOSED on graceful end of stream,\nPANCAKE_ERR_IO on a QUIC fault, PANCAKE_ERR_MALFORMED / PANCAKE_ERR_FRAME_TOO_LARGE\nfor a bad frame.");
    try emitFn(&b, gpa, "pancake_iroh_conn_write_frame", &.{ "conn", "frame" }, "Write one frame's borrowed bytes and flush. PANCAKE_ERR_IO on a QUIC fault.");
    try emitFn(&b, gpa, "pancake_iroh_conn_release", &.{"conn"}, "Close the connection and free the handle; do not use conn afterward.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* PANCAKE_IROH_H */
        \\
    );

    inline for (emitted_fns) |name| {
        if (std.mem.indexOf(u8, b.items, " " ++ name ++ "(") == null) {
            std.debug.print("gen-header-iroh: emitted_fns lists `{s}` but no emitFn call emitted it\n", .{name});
            return error.MissingEmittedFunction;
        }
    }
    return b.toOwnedSlice(gpa);
}
