//! Generates `include/pancake_ocapn.h` from the Zig `c_abi` (ocapn) source.
//!
//! This is the single source of truth for the `libpancake_ocapn` C ABI surface:
//! the shared vocabulary (types, codes, the C-visible frame/context types) plus
//! the peer/uri families. Struct layouts, constant values, and function
//! signatures are *reflected* from the real `c_abi` types (so the header cannot
//! disagree with the implementation), and the prose lives here, in the
//! generator. `zig build gen-header-ocapn` writes the header; a test re-runs
//! this and asserts the committed header matches, so a change to `c_abi` that is
//! not regenerated fails `zig build check`. The transport archives ship their
//! own headers that `#include` this one (ADR-0059).

const std = @import("std");
const c = @import("c_abi");

// The constant names the header emits, grouped for section comments. The version
// macros are emitted inline; these three groups plus the version triple are the
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
    "PANCAKE_ERR_BROKEN",         "PANCAKE_ERR_NOT_FOUND",
};
const discriminant_consts = [_][]const u8{
    "PANCAKE_CODEC_SYRUP",            "PANCAKE_CODEC_CAPNP",
    "PANCAKE_FRAME_SHAPE_BYTE",       "PANCAKE_FRAME_SHAPE_WORD",
    "PANCAKE_EVENT_NONE",             "PANCAKE_EVENT_DELIVER",
    "PANCAKE_EVENT_RESOLVE",          "PANCAKE_EVENT_GC_EXPORT",
    "PANCAKE_EVENT_GC_ANSWER",        "PANCAKE_EVENT_HANDOFF",
    "PANCAKE_EVENT_START_SESSION",    "PANCAKE_EVENT_ABORT",
    "PANCAKE_EVENT_LISTEN",           "PANCAKE_EVENT_GET",
    "PANCAKE_EVENT_INDEX",            "PANCAKE_EVENT_UNTAG",
    "PANCAKE_REF_NEAR",               "PANCAKE_REF_FAR",
    "PANCAKE_REF_PROMISE",            "PANCAKE_REF_STURDY",
    "PANCAKE_REF_BROKEN",             "PANCAKE_REF_SUB_OBJECT",
    "PANCAKE_REF_SUB_PROMISE",        "PANCAKE_ARG_INTEGER",
    "PANCAKE_ARG_FLOAT64",            "PANCAKE_ARG_BOOLEAN",
    "PANCAKE_ARG_BYTES",              "PANCAKE_ARG_STRING",
    "PANCAKE_ARG_SYMBOL",             "PANCAKE_ARG_VOID",
    "PANCAKE_ARG_REFERENCE",          "PANCAKE_ARG_LIST",
    "PANCAKE_ARG_SET",                "PANCAKE_ARG_TAGGED",
    "PANCAKE_ARG_KEYWORD",            "PANCAKE_ARG_BIG_INTEGER",
    "PANCAKE_RESOLUTION_FULFILL",     "PANCAKE_RESOLUTION_BREAK",
    "PANCAKE_RESOLUTION_HANDOFF",     "PANCAKE_HINTS_EMPTY_MAP",
    "PANCAKE_HINTS_EMPTY_FALSE",      "PANCAKE_CAPTP_VERSION_V1_0",
    "PANCAKE_CAPTP_VERSION_PRE_SPEC", "PANCAKE_ABORT_DOMAIN_CODEC",
    "PANCAKE_ABORT_DOMAIN_SESSION",   "PANCAKE_ABORT_DOMAIN_FOREIGN",
    "PANCAKE_ENLIVEN_FRESH",          "PANCAKE_ENLIVEN_CACHED",
    "PANCAKE_ENLIVEN_IN_FLIGHT",      "PANCAKE_ENLIVEN_OUTCOME_FULFILLED",
    "PANCAKE_ENLIVEN_OUTCOME_BROKEN",
};
const protocol_consts = [_][]const u8{
    "PANCAKE_BOOTSTRAP_POSITION",
};

// One curated comment line per constant that needs one (every return code, plus
// the discriminants whose meaning is not obvious from the name). `emitConst`
// consults this table; the guard below keeps every return code documented.
const const_docs = [_]struct { name: []const u8, doc: []const u8 }{
    .{ .name = "PANCAKE_OK", .doc = "Success." },
    .{ .name = "PANCAKE_ERR_NULL_POINTER", .doc = "A required pointer argument was NULL." },
    .{ .name = "PANCAKE_ERR_INVALID_HANDLE", .doc = "Reserved for a future stale-handle check; no function returns this today." },
    .{ .name = "PANCAKE_ERR_INVALID_ARGUMENT", .doc = "A non-pointer argument was out of range or unparseable (a bad shape/codec discriminant, a zero frame cap, an unparseable host address)." },
    .{ .name = "PANCAKE_ERR_SESSION", .doc = "The session state machine refused the operation (a protocol violation, a resource cap, an already-closed session)." },
    .{ .name = "PANCAKE_ERR_CODEC", .doc = "Inbound bytes failed codec decode, or outbound work failed to encode." },
    .{ .name = "PANCAKE_ERR_INTERNAL", .doc = "A host-internal failure (allocation, ...)." },
    .{ .name = "PANCAKE_ERR_WOULD_BLOCK", .doc = "Nothing to do right now: an empty queue, or a partial frame awaiting more bytes." },
    .{ .name = "PANCAKE_ERR_CLOSED", .doc = "The peer closed the stream gracefully on a frame boundary (clean EOF)." },
    .{ .name = "PANCAKE_ERR_IO", .doc = "An underlying socket read/write failed; pancake_last_error carries the concrete cause." },
    .{ .name = "PANCAKE_ERR_MALFORMED", .doc = "Inbound bytes were not a structurally valid frame." },
    .{ .name = "PANCAKE_ERR_FRAME_TOO_LARGE", .doc = "An inbound frame exceeded the endpoint's max_frame_bytes." },
    .{ .name = "PANCAKE_ERR_WRONG_EVENT", .doc = "A typed poll_event_* was called but the next event is a different kind. The event stays queued; call pancake_peer_peek_event first." },
    .{ .name = "PANCAKE_ERR_UNSUPPORTED_VALUE", .doc = "A value crossed the typed surface that the C ABI cannot carry (e.g. a handoff argument); on a typed poll the event stays queued for pancake_peer_poll_event." },
    .{ .name = "PANCAKE_ERR_BROKEN", .doc = "Never returned by a C ABI function: the shared code a binding surfaces when a partner breaks a promise (the break arrives as a PANCAKE_RESOLUTION_BREAK resolve event)." },
    .{ .name = "PANCAKE_ERR_NOT_FOUND", .doc = "A well-formed lookup found nothing: pancake_locator_hint named a key absent from the locator. Distinct from _INVALID_ARGUMENT (a malformed request)." },
    .{ .name = "PANCAKE_FRAME_SHAPE_WORD", .doc = "Word-aligned storage: pointer 8-byte aligned, length divisible by 8; anything else is PANCAKE_ERR_INVALID_ARGUMENT." },
    .{ .name = "PANCAKE_EVENT_NONE", .doc = "The no-event sentinel pancake_event_release zeroes a released event's kind to; never returned by a successful poll." },
    .{ .name = "PANCAKE_CODEC_SYRUP", .doc = "codec for pancake_peer_new_negotiated and the transport endpoints: Syrup. The session's grammar and the endpoint's framing must carry the same value." },
    .{ .name = "PANCAKE_CODEC_CAPNP", .doc = "codec for pancake_peer_new_negotiated and the transport endpoints: Cap'n Proto." },
    .{ .name = "PANCAKE_CAPTP_VERSION_V1_0", .doc = "captp_version for pancake_peer_new_negotiated: the authenticated v1.0 profile." },
    .{ .name = "PANCAKE_CAPTP_VERSION_PRE_SPEC", .doc = "captp_version for pancake_peer_new_negotiated: PreSpec, the upstream OCapN prerelease profile." },
    .{ .name = "PANCAKE_REF_SUB_OBJECT", .doc = "PancakeReference.sub_kind for a near/far reference: the position names a plain object. The SUB names are their own namespace, never `kind` values." },
    .{ .name = "PANCAKE_REF_SUB_PROMISE", .doc = "PancakeReference.sub_kind for a near/far reference: the position names a promise (desc:import-promise rather than desc:import-object)." },
    .{ .name = "PANCAKE_ABORT_DOMAIN_CODEC", .doc = "PancakeLastAbort.domain: a codec decode/encode malformation." },
    .{ .name = "PANCAKE_ABORT_DOMAIN_SESSION", .doc = "PancakeLastAbort.domain: the session state machine refused the operation." },
    .{ .name = "PANCAKE_ABORT_DOMAIN_FOREIGN", .doc = "PancakeLastAbort.domain: a host-internal failure (allocation, ...)." },
    .{ .name = "PANCAKE_ENLIVEN_FRESH", .doc = "PancakeEnlivenStart.status: a fresh bootstrap-fetch was queued; drive `answer` and settle with pancake_peer_record_enlivenment." },
    .{ .name = "PANCAKE_ENLIVEN_CACHED", .doc = "PancakeEnlivenStart.status: short-circuited to an already-enlivened reference (no wire); read import_position and kind." },
    .{ .name = "PANCAKE_ENLIVEN_IN_FLIGHT", .doc = "PancakeEnlivenStart.status: collapsed onto an enliven already outstanding on `answer`." },
    .{ .name = "PANCAKE_ENLIVEN_OUTCOME_FULFILLED", .doc = "pancake_peer_record_enlivenment outcome: the partner fulfilled with a capability; cache it under the swissnum." },
    .{ .name = "PANCAKE_ENLIVEN_OUTCOME_BROKEN", .doc = "pancake_peer_record_enlivenment outcome: the partner broke the answer; clear the in-flight marker, cache nothing." },
};

// Guard: every return code carries a comment line in the header.
comptime {
    @setEvalBranchQuota(20000);
    for (error_consts) |name| {
        var documented = false;
        for (const_docs) |entry| {
            if (std.mem.eql(u8, entry.name, name)) documented = true;
        }
        if (!documented) @compileError("return code missing a header comment in const_docs: " ++ name);
    }
}

// Compile-time coverage guard: every `pub const PANCAKE_*` integer in `c_abi`
// must appear in an emitted group, so adding a constant without listing it for
// the header fails to compile instead of silently dropping from pancake_ocapn.h.
comptime {
    @setEvalBranchQuota(20000);
    const all = version_consts ++ error_consts ++ discriminant_consts ++ protocol_consts;
    for (@typeInfo(c).@"struct".decls) |decl| {
        if (!std.mem.startsWith(u8, decl.name, "PANCAKE_")) continue;
        if (@typeInfo(@TypeOf(@field(c, decl.name))) != .int) continue;
        var found = false;
        for (all) |name| {
            if (std.mem.eql(u8, name, decl.name)) found = true;
        }
        if (!found) @compileError("constant in c_abi but not emitted to pancake_ocapn.h: " ++ decl.name);
    }
}

// Every function prototype the header emits, in emission order. This is the
// functions' counterpart of the constant groups above: `emitFn` refuses a name
// missing from this table, the comptime guard below holds the table against
// the real `c_abi` declarations in both directions, and `generate` verifies
// every listed name landed in the output text — so a new `pub fn pancake_*`
// in c_abi cannot silently miss pancake_ocapn.h while the check stays green.
const emitted_fns = [_][]const u8{
    "pancake_abi_version",
    "pancake_managed_frame_release",
    "pancake_event_release",
    "pancake_context_new",
    "pancake_context_new_with_allocator",
    "pancake_context_release",
    "pancake_peer_new",
    "pancake_peer_new_in",
    "pancake_peer_new_negotiated",
    "pancake_peer_new_negotiated_in",
    "pancake_peer_new_raw_open",
    "pancake_peer_new_raw_open_in",
    "pancake_peer_release",
    "pancake_peer_feed_borrowed",
    "pancake_peer_feed_owned",
    "pancake_peer_recv_stream",
    "pancake_peer_step",
    "pancake_peer_step_to_idle",
    "pancake_peer_take_outbound",
    "pancake_peer_poll_event",
    "pancake_peer_codec",
    "pancake_peer_register_bootstrap_cap",
    "pancake_peer_send_bootstrap_fetch",
    "pancake_peer_prepare_enliven",
    "pancake_peer_record_enlivenment",
    "pancake_peer_register_export",
    "pancake_peer_next_export",
    "pancake_peer_next_answer",
    "pancake_peer_last_abort",
    "pancake_peer_register_import",
    "pancake_peer_start_session",
    "pancake_peer_session_is_open",
    "pancake_peer_peek_event",
    "pancake_peer_send_deliver",
    "pancake_peer_send_resolve",
    "pancake_peer_send_get",
    "pancake_peer_send_index",
    "pancake_peer_send_untag",
    "pancake_peer_send_gc_export",
    "pancake_peer_send_gc_answer",
    "pancake_peer_send_withdraw_gift",
    "pancake_peer_partner_session_key",
    "pancake_peer_partner_locator_raw",
    "pancake_build_handoff_give",
    "pancake_handoff_give_bytes_release",
    "pancake_peer_send_deposit_gift",
    "pancake_peer_send_resolve_handoff_give",
    "pancake_gift_registry_new",
    "pancake_gift_registry_new_in",
    "pancake_gift_registry_free",
    "pancake_peer_set_gift_registry",
    "pancake_peer_poll_event_deliver",
    "pancake_peer_poll_event_resolve",
    "pancake_deliver_release",
    "pancake_resolve_release",
    "pancake_last_error",
    "pancake_clear_last_error",
    "pancake_uri_parse_peer",
    "pancake_uri_parse_sturdyref",
    "pancake_uri_format_peer",
    "pancake_uri_format_sturdyref",
    "pancake_locator_transport",
    "pancake_locator_designator",
    "pancake_locator_swissnum",
    "pancake_locator_hint",
    "pancake_locator_hint_count",
    "pancake_locator_hint_at",
    "pancake_locator_release",
};

// Compile-time coverage guard for functions, both directions: every
// `pub fn pancake_*` in c_abi must be listed in `emitted_fns`, and every table
// entry must name a real c_abi function (a stale entry is a broken promise).
comptime {
    @setEvalBranchQuota(40000);
    for (@typeInfo(c).@"struct".decls) |decl| {
        if (!std.mem.startsWith(u8, decl.name, "pancake_")) continue;
        if (@typeInfo(@TypeOf(@field(c, decl.name))) != .@"fn") continue;
        var found = false;
        for (emitted_fns) |name| {
            if (std.mem.eql(u8, name, decl.name)) found = true;
        }
        if (!found) @compileError("function in c_abi but not emitted to pancake_ocapn.h: " ++ decl.name);
    }
    for (emitted_fns) |name| {
        if (!@hasDecl(c, name)) @compileError("emitted_fns lists '" ++ name ++ "' but c_abi has no such declaration");
        if (@typeInfo(@TypeOf(@field(c, name))) != .@"fn") @compileError("emitted_fns entry '" ++ name ++ "' is not a c_abi function");
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

/// Emit `#define NAME <value>` with the value reflected from `c_abi`. Values
/// are plain decimal literals (C type `int`) on purpose: every constant is a
/// small discriminant that callers compare against both `int32_t` returns
/// (`pancake_peer_peek_event`) and `uint32_t` struct fields, and a `u` suffix
/// would force a cast or a sign-compare warning on the signed side. A constant
/// listed in `const_docs` gets its one curated comment line first.
fn emitConst(b: *Buf, gpa: std.mem.Allocator, comptime name: []const u8) !void {
    inline for (const_docs) |entry| {
        if (comptime std.mem.eql(u8, entry.name, name)) {
            try line(b, gpa, "/* {s} */", .{entry.doc});
        }
    }
    try line(b, gpa, "#define {s} {d}", .{ name, @field(c, name) });
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
    try emitStructBody(b, gpa, T, name, docs, true);
}

/// `emitStruct` without the typedef wrapper, for a struct whose typedef was
/// already forward-declared (a second `typedef struct X X;` would redeclare it).
fn emitBareStruct(
    b: *Buf,
    gpa: std.mem.Allocator,
    comptime T: type,
    comptime name: []const u8,
    comptime docs: []const []const u8,
) !void {
    try emitStructBody(b, gpa, T, name, docs, false);
}

fn emitStructBody(
    b: *Buf,
    gpa: std.mem.Allocator,
    comptime T: type,
    comptime name: []const u8,
    comptime docs: []const []const u8,
    comptime use_typedef: bool,
) !void {
    const fields = @typeInfo(T).@"struct".fields;
    if (docs.len != fields.len) @compileError("field doc count mismatch for " ++ name);
    if (use_typedef) {
        try line(b, gpa, "typedef struct {s} {{", .{name});
    } else {
        try line(b, gpa, "struct {s} {{", .{name});
    }
    inline for (fields, docs) |f, doc| {
        if (doc.len != 0) try line(b, gpa, "    /* {s} */", .{doc});
        // A struct that references itself uses `struct Name *` in C.
        const ty = comptime selfRef(T, f.type, name);
        const space = if (ty.len > 0 and ty[ty.len - 1] == '*') "" else " ";
        try line(b, gpa, "    {s}{s}{s};", .{ ty, space, f.name });
    }
    if (use_typedef) {
        try line(b, gpa, "}} {s};", .{name});
    } else {
        try b.appendSlice(gpa, "};\n");
    }
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
    comptime {
        var listed = false;
        for (emitted_fns) |name| {
            if (std.mem.eql(u8, name, fn_name)) listed = true;
        }
        if (!listed) @compileError("emitFn called for '" ++ fn_name ++ "' which is missing from emitted_fns");
        // The header is the C consumer's only surface, so a bare prototype is
        // an undocumented function no matter what the Zig source says.
        if (doc.len == 0) @compileError("prototype '" ++ fn_name ++ "' has no header doc; write the contract here");
    }
    const info = @typeInfo(@TypeOf(@field(c, fn_name))).@"fn";
    if (info.params.len != param_names.len) @compileError("param name count mismatch for " ++ fn_name);
    if (doc.len != 0) try emitDoc(b, gpa, doc);

    try b.print(gpa, "{s} {s}(", .{ comptime cType(info.return_type.?), fn_name });
    // A zero-parameter C prototype must spell `(void)`: a bare `()` is a
    // K&R-style unchecked parameter list, not "no parameters".
    if (info.params.len == 0) try b.appendSlice(gpa, "void");
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
        @setEvalBranchQuota(8000);
        var ls: []const []const u8 = &.{};
        var it = std.mem.splitScalar(u8, doc, '\n');
        while (it.next()) |l| ls = ls ++ .{l};
        break :blk ls;
    };
    inline for (lines, 0..) |l, i| {
        // An empty doc line separates paragraphs; emit it bare so the header
        // carries no trailing whitespace.
        const prefix = if (i == 0) "/* " else if (l.len == 0) "" else "   ";
        const suffix = if (i == lines.len - 1) " */" else "";
        try line(b, gpa, "{s}{s}{s}", .{ prefix, l, suffix });
    }
}

fn section(b: *Buf, gpa: std.mem.Allocator, comptime title: []const u8) !void {
    try b.appendSlice(gpa, "\n");
    try line(b, gpa, "/* ── {s} ── */", .{title});
}

pub const header_path = "include/pancake_ocapn.h";

/// Build the full header text. Caller owns the returned bytes.
pub fn generate(gpa: std.mem.Allocator) ![]u8 {
    var b: Buf = .empty;
    errdefer b.deinit(gpa);

    try b.appendSlice(gpa,
        \\/* Generated from src/c_abi/ocapn/mod.zig by tools/header_gen.zig.
        \\   Do not edit by hand: run `zig build gen-header-ocapn`. Struct layouts,
        \\   constant values, and function signatures are reflected from the Zig
        \\   source, so this header cannot drift from the implementation.
        \\
        \\   libpancake_ocapn is the sans-io OCapN base archive: the shared C ABI
        \\   vocabulary (frame/context types, return codes, the codec selector)
        \\   plus the peer-driving and locator-URI families. The transports ship
        \\   their own archives and headers — pancake_net_transport_tcp.h,
        \\   pancake_net_transport_inproc.h, pancake_net_transport_iroh.h — each of
        \\   which #includes this one for the shared types (ADR-0059). */
        \\#ifndef PANCAKE_OCAPN_H
        \\#define PANCAKE_OCAPN_H
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
    try b.appendSlice(gpa, "\n");
    try emitDoc(&b, gpa,
        \\Orientation: a PancakePeer is a sans-I/O CapTP state machine. It owns no
        \\socket and never blocks: feed inbound bytes with pancake_peer_recv_stream,
        \\advance with pancake_peer_step, and drain outbound frames with
        \\pancake_peer_take_outbound; sockets, threads, and scheduling stay in the
        \\host. examples/c/echo_peer.c is a complete in-memory conversation built
        \\from exactly those calls, and docs/consuming-from-c.md is the guided
        \\route from build to first program.
        \\
        \\There are two inbound models; pick one per loop and do not mix them. One
        \\dispatches synchronously as bytes arrive: pancake_peer_feed_borrowed takes
        \\one whole borrowed frame, and pancake_peer_recv_stream takes a byte-stream
        \\buffer. The other transfers owned frames into the queue with
        \\pancake_peer_feed_owned and applies them in a later pancake_peer_step.
        \\Either way, pancake_peer_step is what encodes and drains outbound work.
        \\
        \\This header is the peer-driving substrate. The nine-verb application
        \\surface the bindings expose (connect, listen, fetch, publish, spawn,
        \\send, tell, serve, close) is built above these primitives, not in them;
        \\bindings/README.md names that contract.
        \\
        \\Ownership is four rules, restated per function below. Pointers you pass
        \\are borrowed for that one call. Values the library fills for you to keep
        \\have exactly one matching pancake_*_release. Handles release through
        \\their constructor's family (peer, context, netlayer, connection,
        \\listener). Release is the only verb that frees; a *_close is a
        \\shutdown lever that leaves the handle alive. pancake_peer_feed_owned
        \\is the one call that takes ownership from you, and only on success.
        \\
        \\Threading: a PancakePeer is a single-owner state machine. Serialize every
        \\call on a given peer onto one thread or behind one lock. pancake_last_error
        \\is per-thread; read it on the thread that made the failing call.
        \\
        \\Out parameters: out structs are written only on PANCAKE_OK;
        \\zero-initialize or never release on failure.
    );

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
        \\typedef struct PancakeGiftRegistry PancakeGiftRegistry;
        \\typedef void (*PancakeReleaseFn)(PancakeManagedFrame *frame);
        \\
    );
    try emitBareStruct(&b, gpa, c.PancakeManagedFrame, "PancakeManagedFrame", &.{
        "Owned and self-releasing: release with `pancake_managed_frame_release`.",
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
    try emitFn(&b, gpa, "pancake_managed_frame_release", &.{"frame"}, "Release a managed frame. Idempotent; call when done.");
    try emitFn(&b, gpa, "pancake_event_release", &.{"event"}, "Release an event's frame and zero its kind to PANCAKE_EVENT_NONE. Idempotent.");

    try section(&b, gpa, "Allocation context");
    try emitDoc(&b, gpa,
        \\A context owns allocation policy for a family of handles. The simple
        \\constructors use the library allocator; the `*_in` constructors allocate
        \\from a context you supply, and everything those handles own frees back
        \\through it. The context must outlive every handle created in it:
        \\releasing it while a handle is live leaves the handle pointing into
        \\freed memory, and its next allocation or release is undefined behavior.
        \\A host-backed context stores the PancakeAllocator callbacks and
        \\user_data as given, so both must stay valid until
        \\pancake_context_release.
        \\
        \\Host allocator contract: alloc returns memory aligned to `alignment` (a
        \\power of two) or NULL on failure; free receives the exact size and
        \\alignment the allocation was made with. There is no realloc by design:
        \\the library never resizes in place, so free's size always equals
        \\alloc's — correct even for a size-tracking host allocator.
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
    try emitFn(&b, gpa, "pancake_context_new", &.{"out_context"}, "Create a context backed by the library-owned allocator.");
    try emitFn(&b, gpa, "pancake_context_new_with_allocator", &.{ "allocator", "out_context" }, "Create a context that routes every allocation through host callbacks.\nThe callbacks must be thread-safe.");
    try emitFn(&b, gpa, "pancake_context_release", &.{"context"}, "Release a context after every handle created in it has been released.");

    try section(&b, gpa, "Peer lifecycle and frame I/O");
    try emitFn(&b, gpa, "pancake_peer_new", &.{"out_peer"}, "Create a peer in the authenticated v1.0 negotiating state. Pair with\npancake_peer_start_session, pump frames, then wait for\npancake_peer_session_is_open before application traffic.");
    try emitFn(&b, gpa, "pancake_peer_new_in", &.{ "context", "out_peer" }, "Context-backed counterpart of pancake_peer_new.");
    try emitFn(&b, gpa, "pancake_peer_new_negotiated", &.{ "captp_version", "codec", "out_peer" }, "Create a negotiating peer carrying an out-of-band negotiated profile and\ncodec: captp_version is a PANCAKE_CAPTP_VERSION_* value (_V1_0, or _PRE_SPEC\nfor the upstream OCapN prerelease profile), codec a PANCAKE_CODEC_* value.\nBoth ends of a connection must construct with the same pair —\nop:start-session carries the profile but no codec operand, so codec\nagreement is the caller's, the same agreement the matching codec argument\nto pancake_tcp_connect / pancake_tcp_accept records.\npancake_peer_start_session signs with the profile chosen here.");
    try emitFn(&b, gpa, "pancake_peer_new_negotiated_in", &.{ "context", "captp_version", "codec", "out_peer" }, "Context-backed counterpart of pancake_peer_new_negotiated.");
    try emitFn(&b, gpa, "pancake_peer_new_raw_open", &.{"out_peer"}, "Create an already-open peer for low-level tests and harnesses that inject\nframes directly. This is a fixture surface; real OCapN connections should use\npancake_peer_new.");
    try emitFn(&b, gpa, "pancake_peer_new_raw_open_in", &.{ "context", "out_peer" }, "Context-backed counterpart of pancake_peer_new_raw_open.");
    try emitFn(&b, gpa, "pancake_peer_release", &.{"peer"}, "Release a peer and everything it still owns: queued inbound frames,\nundrained outbound frames and events, and the session tables. Frames already\ntaken out carry their own release and stay valid. NULL is a no-op.");
    try emitFn(&b, gpa, "pancake_peer_feed_borrowed", &.{ "peer", "frame" }, "Dispatch a borrowed frame synchronously; the caller retains ownership.");
    try emitFn(&b, gpa, "pancake_peer_feed_owned", &.{ "peer", "frame" }, "Transfer a managed frame into the inbound queue for `pancake_peer_step`.\nOwnership always transfers once peer, frame, and frame->bytes are non-NULL:\non failure the frame is released through its own callback and the caller's\nstruct is cleared, so a late pancake_managed_frame_release is a no-op. Only\nPANCAKE_ERR_NULL_POINTER leaves the caller owning the frame.");
    try emitFn(&b, gpa, "pancake_peer_recv_stream", &.{ "peer", "bytes", "len", "out_consumed" }, "Frame and dispatch one inbound frame from a byte-stream buffer, writing the\nbytes consumed into `out_consumed`. PANCAKE_ERR_WOULD_BLOCK (out_consumed 0)\nmeans the buffer holds only part of a frame — read more and retry; an empty\nbuffer (len == 0, bytes may be NULL) reports the same. The sans-I/O\nstream-input primitive: the caller owns the socket and buffer.");
    try emitFn(&b, gpa, "pancake_peer_step", &.{"peer"}, "Advance the peer: validate and apply queued inbound frames and encode\npending outbound work. No I/O happens here — drain\npancake_peer_take_outbound and pancake_peer_poll_event afterward.");
    try emitFn(&b, gpa, "pancake_peer_step_to_idle", &.{"peer"}, "Advance the peer to quiescence: step until both the inbound and pending\noutbound queues are empty. A single pancake_peer_step does one unit of work,\nso a cascading settlement (a resolve that drains a projection whose own\nresolve fires a listener that queues a deliver) needs several steps to fully\nencode; this runs them all so one pancake_peer_take_outbound sweep drains\nevery queued frame. No I/O — drain pancake_peer_take_outbound and\npancake_peer_poll_event afterward, as for pancake_peer_step.");
    try emitFn(&b, gpa, "pancake_peer_take_outbound", &.{ "peer", "out_frame" }, "Take the next outbound frame as an owned managed frame, or\nPANCAKE_ERR_WOULD_BLOCK when the queue is empty. On PANCAKE_ERR_INTERNAL the\ndequeued frame could not be wrapped for C and was freed; it is not\nretrievable.");
    try emitFn(&b, gpa, "pancake_peer_poll_event", &.{ "peer", "out_event" }, "Take the next event (opaque frame in the negotiated codec), or\nPANCAKE_ERR_WOULD_BLOCK when none is queued.");
    try emitFn(&b, gpa, "pancake_peer_codec", &.{ "peer", "out_codec" }, "The codec the peer's session speaks, as a PANCAKE_CODEC_* value. Event and\noutbound frames are encoded in it, so a consumer that drains an event\nthrough the opaque pancake_peer_poll_event knows how to read the raw frame.");

    try section(&b, gpa, "Capability registration");
    try emitDoc(&b, gpa,
        \\The well-known bootstrap export position every OCapN peer answers `fetch`
        \\on. Use this name instead of re-deriving the magic 0.
    );
    try emitConst(&b, gpa, "PANCAKE_BOOTSTRAP_POSITION");
    try emitFn(&b, gpa, "pancake_peer_register_bootstrap_cap", &.{ "peer", "swissnum", "swissnum_len", "out_export_position" }, "Expose a local capability behind `swissnum` for inbound bootstrap-fetch;\nwrites the allocated export position. `swissnum` is borrowed.");
    try emitFn(&b, gpa, "pancake_peer_send_bootstrap_fetch", &.{ "peer", "name", "name_len", "out_answer" }, "Ask the partner's bootstrap object for the capability published behind\n`name`: registers the bootstrap import if needed, allocates the answer from\nthe session's one answer allocator, and queues the canonical fetch deliver.\nThe question id lands in `out_answer`; the partner's resolution arrives as a\nPANCAKE_EVENT_RESOLVE keyed on it. `name` is borrowed for the call.");
    try b.appendSlice(gpa, "\n");
    try emitStruct(&b, gpa, c.PancakeEnlivenStart, "PancakeEnlivenStart", &.{
        "a PANCAKE_ENLIVEN_* status selecting the live fields",
        "_CACHED far reference kind: a PANCAKE_REF_SUB_* value",
        "_FRESH/_IN_FLIGHT question id to drive",
        "_CACHED far import position",
    });
    try b.appendSlice(gpa, "\n");
    try emitFn(&b, gpa, "pancake_peer_prepare_enliven", &.{ "peer", "swissnum", "swissnum_len", "out" }, "Begin enlivening the sturdyref published behind `swissnum` (ADR-0012): the\nrequester half over bootstrap-fetch with the dedup cache threaded in.\n`swissnum` is borrowed; the result lands in `out`. A PANCAKE_ENLIVEN_FRESH\nstatus queued the fetch deliver (flush with pancake_peer_step +\npancake_peer_take_outbound); its resolution arrives as a\nPANCAKE_EVENT_RESOLVE keyed on out.answer, after which the caller calls\npancake_peer_record_enlivenment to cache it. A PANCAKE_ENLIVEN_CACHED status\nshort-circuits with no wire traffic (read out.import_position and out.kind);\na PANCAKE_ENLIVEN_IN_FLIGHT status names an enliven already outstanding on\nout.answer. Requires the session to have negotiated the sturdyref feature\nand be open, else PANCAKE_ERR_SESSION.");
    try emitFn(&b, gpa, "pancake_peer_record_enlivenment", &.{ "peer", "swissnum", "swissnum_len", "outcome", "import_position", "kind" }, "Settle a PANCAKE_ENLIVEN_FRESH enliven once its resolution arrives\n(ADR-0012 dedup cache). On PANCAKE_ENLIVEN_OUTCOME_FULFILLED the resolved far\nreference (import_position plus kind, a PANCAKE_REF_SUB_* value read from the\nresolve event) is cached under `swissnum` so a repeat enliven short-circuits;\non PANCAKE_ENLIVEN_OUTCOME_BROKEN the in-flight marker is cleared and nothing\nis cached. `swissnum` is borrowed for the call.");
    try emitFn(&b, gpa, "pancake_peer_register_export", &.{ "peer", "export_position" }, "Register a local export position so deliveries to it surface as events.");
    try emitFn(&b, gpa, "pancake_peer_next_export", &.{ "peer", "out_export_position" }, "Allocate the next free export position from the session's one export\nallocator and REGISTER it (unlike pancake_peer_next_answer, which only\nallocates), writing it into `out_export_position`. A binding's `spawn` must\ntake its position here: the same counter mints bootstrap and resolver\nexports, so a privately-counted position would eventually alias one.");
    try emitFn(&b, gpa, "pancake_peer_next_answer", &.{ "peer", "out_answer" }, "Allocate the next outbound answer position — the question id for a\nsend_deliver that wants a reply — writing it into `out_answer`. A binding's\neventual-send must take its answer here: the same counter backs every\noutbound question on the session, so a privately-counted position would\neventually alias a live answer and route the partner's op:resolve to the\nwrong caller.");
    try b.appendSlice(gpa, "\n");
    try emitStruct(&b, gpa, c.PancakeLastAbort, "PancakeLastAbort", &.{
        "a PANCAKE_ABORT_DOMAIN_* value",               "nonzero when an op:abort kind was projected",
        "wire name of the abort kind (process-static)", "",
        "static diagnostic",                            "",
        "originating error name (process-static)",      "",
    });
    try b.appendSlice(gpa, "\n");
    try emitFn(&b, gpa, "pancake_peer_last_abort", &.{ "peer", "out" }, "Read the typed cause of the peer's most recent local dispatch failure into\n`out` (the counterpart of the Zig `Peer.lastAbort`). PANCAKE_OK when one was\nrecorded, PANCAKE_ERR_WOULD_BLOCK when none. The string views are\nprocess-static — read them, never free them. The per-feed return code names\nthe failure family; this names the member.");
    try emitFn(&b, gpa, "pancake_peer_register_import", &.{ "peer", "import_position" }, "Track a partner-hosted import this peer holds, so a _FAR send_deliver to it\nis admitted (e.g. the bootstrap import).");
    try emitFn(&b, gpa, "pancake_peer_start_session", &.{ "peer", "transport", "transport_len", "designator", "designator_len", "hints", "seed", "seed_len" }, "Sign and queue op:start-session for a negotiating peer. Derives the session\nkey from the 32-byte `seed`, signs the canonical location bytes for the\n(transport, designator) locator, and enqueues the handshake frame. `hints`\nselects the wire spelling of the locator's empty hints —\nPANCAKE_HINTS_EMPTY_MAP encodes {}, PANCAKE_HINTS_EMPTY_FALSE encodes #f\n(the spelling Goblins emits) — any other value is refused with\nPANCAKE_ERR_INVALID_ARGUMENT. For a Goblins target use profile v1.0, Syrup,\ntransport \"tcp\", and PANCAKE_HINTS_EMPTY_FALSE. The handshake speaks the\nprofile the peer was constructed with; the peer already knows it, so this\ncall never re-takes it. `seed` is borrowed and `seed_len` must be 32;\nanything else is refused with PANCAKE_ERR_INVALID_ARGUMENT.");
    try emitFn(&b, gpa, "pancake_peer_session_is_open", &.{"peer"}, "Whether the session has completed the handshake and is open for traffic:\n1 when open, 0 when not. A NULL peer has no open session, so it reports 0;\nthe result is never negative, so a plain `if` on it reads correctly in C.");

    try section(&b, gpa, "Typed OCapN driving surface");
    try emitDoc(&b, gpa,
        \\Construct a call and read a delivery as structured values without authoring
        \\a codec. Send borrows the C structs for the call (the clone owns the copy);
        \\receive projects views aliasing an internal arena, released by `*_release`.
        \\These struct layouts are frozen ABI (ADR-0031).
        \\
        \\PancakeArgument field mapping by kind: _BYTES, _STRING, _SYMBOL, and
        \\_KEYWORD carry their payload in `bytes`/`bytes_len`. _LIST and _SET carry
        \\their elements in `items`/`items_len`. _TAGGED carries the tag in
        \\`bytes`/`bytes_len` and the value list in `items`/`items_len`.
        \\_BIG_INTEGER carries the canonical decimal magnitude in `bytes`/`bytes_len`
        \\(ASCII digits, no leading zero) and the sign in `boolean` (1 = negative);
        \\a magnitude that fits int64_t belongs in _INTEGER and is refused here.
    );
    try emitStruct(&b, gpa, c.PancakeReference, "PancakeReference", &.{
        "_NEAR export position, _FAR import position, or _PROMISE answer position.", "object/promise for near/far", "",
    });
    try b.appendSlice(gpa, "\n");
    try emitStruct(&b, gpa, c.PancakeArgument, "PancakeArgument", &.{
        "selects the live field",
        "_BOOLEAN value; also the _BIG_INTEGER sign (1 = negative)",
        "",
        "",
        "_BYTES/_STRING/_SYMBOL/_KEYWORD payload; a _TAGGED's tag; a _BIG_INTEGER's digits",
        "",
        "",
        "a _LIST's or _SET's elements; a _TAGGED's value list",
        "",
    });
    try b.appendSlice(gpa, "\n");
    try emitStruct(&b, gpa, c.PancakeDeliver, "PancakeDeliver", &.{
        "", "aliases an internal arena", "", "", "", "release with pancake_deliver_release",
    });
    try b.appendSlice(gpa, "\n");
    try emitStruct(&b, gpa, c.PancakeHandoffGive, "PancakeHandoffGive", &.{
        "verbatim signed give; feed to pancake_peer_send_withdraw_gift",          "",
        "exporter ocapn:// URI, or NULL when the location is not a flat locator", "",
        "32-byte Ed25519 key the give is addressed to",                           "",
    });
    try b.appendSlice(gpa, "\n");
    try emitStruct(&b, gpa, c.PancakeResolve, "PancakeResolve", &.{
        "", "fulfill, break, or handoff", "", "", "", "set when resolution_kind is _HANDOFF", "release with pancake_resolve_release",
    });
    try b.appendSlice(gpa, "\n");
    try emitFn(&b, gpa, "pancake_peer_peek_event", &.{"peer"}, "The kind of the next event without consuming it: a positive PANCAKE_EVENT_*\nor PANCAKE_ERR_WOULD_BLOCK.");
    try emitFn(&b, gpa, "pancake_peer_send_deliver", &.{ "peer", "target", "args", "args_len", "has_answer", "answer" }, "Construct and queue an op:deliver. When `has_answer` is nonzero the call\nexpects a reply on `answer`, which must come from pancake_peer_next_answer\non this same peer (a privately-counted id eventually aliases a live answer).\nWhen `has_answer` is zero, `answer` is ignored.");
    try emitFn(&b, gpa, "pancake_peer_send_resolve", &.{ "peer", "answer", "resolution_kind", "fulfill", "break_message", "break_message_len" }, "Construct and queue an op:resolve settling `answer`.");
    try emitFn(&b, gpa, "pancake_peer_send_get", &.{ "peer", "receiver", "field", "field_len", "answer" }, "Queue an op:get projection (ADR-0050): export a fresh promise at `answer`\nthat resolves to the `field` member of whatever `receiver` resolves to.\n`receiver` is typically a _PROMISE (the answer position a prior send_deliver\nreturned), so the projection pipelines ahead of that answer settling; a _FAR\nreceiver projects an already-settled capability. The settlement arrives as a\nPANCAKE_EVENT_RESOLVE keyed on `answer`, which must come from\npancake_peer_next_answer on this peer. `field` is borrowed.");
    try emitFn(&b, gpa, "pancake_peer_send_index", &.{ "peer", "receiver", "index", "answer" }, "Queue an op:index projection (ADR-0050): export a fresh promise at `answer`\nthat resolves to element `index` of whatever `receiver` resolves to. Like\npancake_peer_send_get but for a List position. `answer` must come from\npancake_peer_next_answer on this peer.");
    try emitFn(&b, gpa, "pancake_peer_send_untag", &.{ "peer", "receiver", "tag", "tag_len", "answer" }, "Queue an op:untag projection (ADR-0052): export a fresh promise at `answer`\nthat resolves to the payload of whatever `receiver` resolves to, requiring a\nTagged record whose tag equals `tag` (breaks on a mismatched tag or\nwrong-shape value). `answer` must come from pancake_peer_next_answer on this\npeer; `tag` is borrowed.");
    try emitFn(&b, gpa, "pancake_peer_send_gc_export", &.{ "peer", "positions", "deltas", "len" }, "Construct and queue an op:gc-export releasing wire-delta counts on imports\nthis peer holds: positions[i] is released by deltas[i], for `len` parallel\nentries (both borrowed; len == 0 is PANCAKE_ERR_INVALID_ARGUMENT).");
    try emitFn(&b, gpa, "pancake_peer_send_gc_answer", &.{ "peer", "answer" }, "Construct and queue an op:gc-answer releasing the answer position this peer\nno longer needs.");
    try emitFn(&b, gpa, "pancake_peer_send_withdraw_gift", &.{ "peer", "give", "give_len", "seed", "seed_len", "handoff_count", "answer" }, "Recipient half of a three-party handoff (ADR-0009): build a signed\ndesc:handoff-receive embedding the verbatim `give` bytes and queue a\nwithdraw-gift op:deliver to the exporter's bootstrap (far object 0) under\n`answer`. The caller must already hold an open keyed session to the exporter\nnamed by the give's exporter-location, opened with the same 32-byte `seed`\nthe gift was deposited under (seed_len must be 32, the session must be open,\nelse PANCAKE_ERR_SESSION). `handoff_count` is the 1-based count of\nwithdrawals from this exporter. The withdrawn reference arrives as a\nPANCAKE_EVENT_RESOLVE keyed on `answer`. `give` and `seed` are borrowed.");
    try emitFn(&b, gpa, "pancake_peer_partner_session_key", &.{ "peer", "out_ptr", "out_len" }, "Borrow the partner's session public key learned from its op:start-session\ninto out_ptr/out_len (a NULL pointer and zero length before the handshake\nhalf arrives). A gifter reads it on the to-recipient session for a give's\nrecipient key, and on the to-exporter session to derive the gifter-exporter\nsession name. The view aliases the session until the peer is released.");
    try emitFn(&b, gpa, "pancake_peer_partner_locator_raw", &.{ "peer", "out_ptr", "out_len" }, "Borrow the partner's verbatim location-record bytes from its op:start-session\ninto out_ptr/out_len (a NULL pointer and zero length when none were captured).\nA gifter embeds these as a give's exporter location so a peer comparing\nlocations matches byte-for-byte. The view aliases the session until release.");
    try emitFn(&b, gpa, "pancake_build_handoff_give", &.{ "seed", "seed_len", "recipient_key", "recipient_key_len", "exporter_locator_raw", "exporter_locator_raw_len", "exporter_session_key", "exporter_session_key_len", "gift_id", "gift_id_len", "out_give", "out_give_len" }, "Build the signed desc:handoff-give a gifter returns to a recipient, writing\nowned bytes into out_give/out_give_len (release with\npancake_handoff_give_bytes_release). `seed` is the gifter's 32-byte identity\nseed (the key it presents on the to-exporter session, which signs the give\nand must equal the deposit's provenance); seed_len must be 32. recipient_key\nis the recipient's session public key, exporter_locator_raw the exporter's\nverbatim location bytes, exporter_session_key the exporter's session public\nkey, gift_id the deposited gift's id. The gifter side and gifter-exporter\nsession name are derived from the keys. All inputs are borrowed.");
    try emitFn(&b, gpa, "pancake_handoff_give_bytes_release", &.{ "give", "give_len" }, "Release give bytes returned by pancake_build_handoff_give. NULL is a no-op.");
    try emitFn(&b, gpa, "pancake_peer_send_deposit_gift", &.{ "peer", "gift_id", "gift_id_len", "gifted_ref" }, "Deposit a gift with this (exporter) session: queue a deposit-gift op:deliver\nto the exporter's bootstrap object (far object 0) carrying the gift id and\nthe gifted reference. Fire-and-forget (no answer): the exporter records the\ngift and parks any withdraw-gift that arrives first until this deposit lands.\ngift_id is borrowed; gifted_ref is borrowed and cloned by the send.");
    try emitFn(&b, gpa, "pancake_peer_send_resolve_handoff_give", &.{ "peer", "answer", "give", "give_len" }, "Resolve `answer` (a question the recipient asked this gifter) with a signed\ndesc:handoff-give: queue an op:resolve whose fulfill carries `give` verbatim,\nso the encoder emits the exact bytes the gifter signed and the recipient\nredeems them transparently. `give` is borrowed for the call.");
    try emitFn(&b, gpa, "pancake_gift_registry_new", &.{"out_registry"}, "Create a shared gift registry backed by the library allocator, writing the\nhandle into out_registry. Bind it onto each peer of a node with\npancake_peer_set_gift_registry before the peers exchange handoff traffic, and\nrelease it with pancake_gift_registry_free only after every peer that\nreferenced it is released.");
    try emitFn(&b, gpa, "pancake_gift_registry_new_in", &.{ "context", "out_registry" }, "Context-backed counterpart of pancake_gift_registry_new: the registry and\nevery gift row it owns allocate and free through `context`'s allocator\n(ADR-0059). The context must outlive the registry.");
    try emitFn(&b, gpa, "pancake_gift_registry_free", &.{"registry"}, "Release a shared gift registry and every gift row it still owns. The caller\nmust have released (or never set this registry on) every peer first. NULL is\na no-op.");
    try emitFn(&b, gpa, "pancake_peer_set_gift_registry", &.{ "peer", "registry" }, "Bind `registry` as `peer`'s shared gift registry, so the peer's inbound\ndeposit-gift / withdraw-gift resolve against the shared table instead of its\nprivate one. Set this before the peer's handshake; the registry must outlive\nthe peer. A NULL registry detaches the peer back to its own table.");
    try emitFn(&b, gpa, "pancake_peer_poll_event_deliver", &.{ "peer", "out" }, "Take the next event as a structured deliver, or PANCAKE_ERR_WRONG_EVENT /\nPANCAKE_ERR_WOULD_BLOCK. PANCAKE_ERR_WRONG_EVENT, PANCAKE_ERR_UNSUPPORTED_VALUE,\nand decode failures leave the event queued; drain it with\npancake_peer_poll_event or the queue never advances (pancake_peer_codec names\nthe raw frame's codec). Release with the matching *_release.");
    try emitFn(&b, gpa, "pancake_peer_poll_event_resolve", &.{ "peer", "out" }, "Take the next event as a structured resolve; same routing contract as\npancake_peer_poll_event_deliver, including the leave-queued fallback to\npancake_peer_poll_event on PANCAKE_ERR_UNSUPPORTED_VALUE and decode failures.");
    try emitFn(&b, gpa, "pancake_deliver_release", &.{"deliver"}, "Release a deliver projection; the `args` views aliasing its arena die with\nit. Idempotent: the struct is cleared, so releasing again (or a\nzero-initialized struct) is a no-op.");
    try emitFn(&b, gpa, "pancake_resolve_release", &.{"resolve"}, "Release a resolve projection; the `fulfill` and `break_message` views\naliasing its arena die with it. Idempotent: the struct is cleared, so\nreleasing again (or a zero-initialized struct) is a no-op.");

    try section(&b, gpa, "Per-thread last error");
    try emitFn(&b, gpa, "pancake_last_error", &.{ "out_buf", "cap" }, "Copy the calling thread's last error into `out_buf`. Copies at most cap - 1\nbytes and always NUL-terminates when cap > 0. Returns the full message\nlength; to receive the whole message pass a buffer of that length plus one.\nout_buf == NULL or cap == 0 queries the length.");
    try emitFn(&b, gpa, "pancake_clear_last_error", &.{}, "Clear the calling thread's last error slot.");

    try section(&b, gpa, "OCapN locator URIs");
    try emitDoc(&b, gpa,
        \\The ocapn://<designator>.<transport>[/s/<swiss>][?hints] bootstrap form a
        \\peer or sturdyref address travels in — core OCapN vocabulary, the one
        \\place the grammar lives so no consumer hand-rolls a percent codec.
        \\Parsing and formatting are separate from dialing: parse a URI, read its
        \\transport, then call the matching transport's connect (pancake_tcp_connect,
        \\the iroh companion library's connect, ...). The pancake_uri_* verbs do the
        \\string<->structure conversion; a parse returns one owned PancakeLocator
        \\read through the pancake_locator_* accessors. One handle carries both a
        \\peer and a sturdyref — a sturdyref is a peer locator plus a swissnum — so
        \\a parsed peer reports a zero-length swissnum. Accessor views alias the
        \\handle and are valid until pancake_locator_release. Locator handles
        \\allocate through the library allocator; there is no context-backed
        \\parse, so a context cannot account for them.
    );
    try b.appendSlice(gpa,
        \\typedef struct PancakeLocator PancakeLocator;
        \\
    );
    try emitFn(&b, gpa, "pancake_uri_parse_peer", &.{ "uri", "uri_len", "out_locator" }, "Parse an ocapn:// peer URI into an owned locator handle; `uri` is borrowed.\nPANCAKE_ERR_INVALID_ARGUMENT (see pancake_last_error) for a malformed URI.\nRelease with pancake_locator_release.");
    try emitFn(&b, gpa, "pancake_uri_parse_sturdyref", &.{ "uri", "uri_len", "out_locator" }, "Parse an ocapn://.../s/<swiss> sturdyref URI into an owned locator handle\ncarrying its swissnum. Same borrow, error, and release contract as\npancake_uri_parse_peer.");
    try emitFn(&b, gpa, "pancake_uri_format_peer", &.{ "transport", "transport_len", "designator", "designator_len", "hint_keys", "hint_key_lens", "hint_vals", "hint_val_lens", "hint_count", "out", "cap", "out_len" }, "Format a peer locator as an ocapn:// URI into `out`. Hints are parallel\nkey/value string arrays (hint_keys[i]/hint_key_lens[i] and the val pair) of\nhint_count entries; all inputs are borrowed. `out_len` always receives the\nfull URI length; a buffer too small or NULL is PANCAKE_ERR_INVALID_ARGUMENT\nwith the length still reported, so size with out_len then retry.");
    try emitFn(&b, gpa, "pancake_uri_format_sturdyref", &.{ "transport", "transport_len", "designator", "designator_len", "swissnum", "swissnum_len", "hint_keys", "hint_key_lens", "hint_vals", "hint_val_lens", "hint_count", "out", "cap", "out_len" }, "Format a sturdyref locator (peer plus swissnum) as an ocapn://.../s/<swiss>\nURI. Same hint-array and buffer contract as pancake_uri_format_peer;\n`swissnum` is borrowed.");
    try emitFn(&b, gpa, "pancake_locator_transport", &.{ "loc", "out_ptr", "out_len" }, "Borrow the locator's transport (\"tcp\", \"iroh\", \"inproc\", ...): the field a\ndispatcher reads to pick a netlayer. The view aliases the handle until\nrelease.");
    try emitFn(&b, gpa, "pancake_locator_designator", &.{ "loc", "out_ptr", "out_len" }, "Borrow the locator's designator — the transport-specific address (a TCP\nhost:port string, an iroh node id, an inproc designator).");
    try emitFn(&b, gpa, "pancake_locator_swissnum", &.{ "loc", "out_ptr", "out_len" }, "Borrow the locator's swissnum: zero-length (NULL pointer) for a peer URI, the\nswiss bytes for a sturdyref. The discriminator a C caller reads instead of a\nsecond handle type.");
    try emitFn(&b, gpa, "pancake_locator_hint", &.{ "loc", "key", "key_len", "out_ptr", "out_len" }, "Borrow the value of the hint named by `key` (e.g. \"direct-addresses\").\nPANCAKE_ERR_NOT_FOUND when no hint carries that key. `key` is borrowed.");
    try emitFn(&b, gpa, "pancake_locator_hint_count", &.{ "loc", "out_count" }, "The number of hints on the locator, for index enumeration with\npancake_locator_hint_at.");
    try emitFn(&b, gpa, "pancake_locator_hint_at", &.{ "loc", "idx", "out_key", "out_key_len", "out_val", "out_val_len" }, "Borrow the key and value of hint `idx` (0-based). PANCAKE_ERR_INVALID_ARGUMENT\nwhen idx is out of range. Both views alias the handle until release.");
    try emitFn(&b, gpa, "pancake_locator_release", &.{"loc"}, "Release a locator handle and the parse allocations it owns. NULL is a no-op.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif
        \\
    );

    // The table's last tooth: every listed prototype must have landed in the
    // generated text, so a table entry whose `emitFn` call was dropped fails
    // the generator (and with it `zig build check`) instead of shipping a
    // header without the function.
    inline for (emitted_fns) |name| {
        if (std.mem.indexOf(u8, b.items, " " ++ name ++ "(") == null) {
            std.debug.print("gen-header: emitted_fns lists `{s}` but no emitFn call emitted it\n", .{name});
            return error.MissingEmittedFunction;
        }
    }
    return b.toOwnedSlice(gpa);
}
