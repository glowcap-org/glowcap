//! Generates the shared C vocabulary header from `c_abi`.
//!
//! Function signatures, constants, and layouts are reflected from the Zig
//! declarations. `libpancake_host` supplies the application-facing CapTP API;
//! this archive supplies allocation, frame, value, and locator vocabulary.

const std = @import("std");
const c = @import("c_abi");
const header_emit = @import("header_emit.zig");

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/pancake_ocapn.h", .generate = generate },
};
pub const step_name = "gen-header-ocapn";

const version_consts = [_][]const u8{
    "PANCAKE_VERSION_MAJOR", "PANCAKE_VERSION_MINOR", "PANCAKE_VERSION_PATCH",
};
const error_consts = [_][]const u8{
    "PANCAKE_OK",                   "PANCAKE_ERR_NULL_POINTER",
    "PANCAKE_ERR_INVALID_ARGUMENT", "PANCAKE_ERR_SESSION",
    "PANCAKE_ERR_CODEC",            "PANCAKE_ERR_INTERNAL",
    "PANCAKE_ERR_WOULD_BLOCK",      "PANCAKE_ERR_CLOSED",
    "PANCAKE_ERR_IO",               "PANCAKE_ERR_MALFORMED",
    "PANCAKE_ERR_FRAME_TOO_LARGE",  "PANCAKE_ERR_UNSUPPORTED_VALUE",
    "PANCAKE_ERR_BROKEN",           "PANCAKE_ERR_NOT_FOUND",
    "PANCAKE_ERR_BUFFER_TOO_SMALL", "PANCAKE_ERR_TIMEOUT",
};
const discriminant_consts = [_][]const u8{
    "PANCAKE_CODEC_UNKNOWN",        "PANCAKE_CODEC_SYRUP",
    "PANCAKE_CODEC_CAPNP",          "PANCAKE_CAPTP_V1_0",
    "PANCAKE_CAPTP_NEXT",           "PANCAKE_FEATURE_PIPELINING",
    "PANCAKE_FEATURE_HANDOFF",      "PANCAKE_FEATURE_WIRE_DELTA",
    "PANCAKE_FEATURE_STURDYREF",    "PANCAKE_FEATURE_MINIMUM",
    "PANCAKE_FEATURE_FULL",         "PANCAKE_FRAME_SHAPE_BYTE",
    "PANCAKE_FRAME_SHAPE_WORD",     "PANCAKE_ARG_INTEGER",
    "PANCAKE_ARG_FLOAT64",          "PANCAKE_ARG_BOOLEAN",
    "PANCAKE_ARG_BYTES",            "PANCAKE_ARG_STRING",
    "PANCAKE_ARG_SYMBOL",           "PANCAKE_ARG_VOID",
    "PANCAKE_ARG_REFERENCE",        "PANCAKE_ARG_LIST",
    "PANCAKE_ARG_SET",              "PANCAKE_ARG_TAGGED",
    "PANCAKE_ARG_KEYWORD",          "PANCAKE_ARG_BIG_INTEGER",
    "PANCAKE_RESOLUTION_FULFILL",   "PANCAKE_RESOLUTION_BREAK",
    "PANCAKE_RESOLUTION_HANDOFF",   "PANCAKE_ABORT_DOMAIN_CODEC",
    "PANCAKE_ABORT_DOMAIN_SESSION", "PANCAKE_ABORT_DOMAIN_FOREIGN",
};

const const_doc_entries = [_]struct { name: []const u8, doc: []const u8 }{
    .{ .name = "PANCAKE_OK", .doc = "Success." },
    .{ .name = "PANCAKE_ERR_NULL_POINTER", .doc = "A required pointer argument was NULL." },
    .{ .name = "PANCAKE_ERR_INVALID_ARGUMENT", .doc = "An argument was outside its accepted range or grammar." },
    .{ .name = "PANCAKE_ERR_SESSION", .doc = "The CapTP session refused the operation." },
    .{ .name = "PANCAKE_ERR_CODEC", .doc = "A frame could not be decoded or encoded." },
    .{ .name = "PANCAKE_ERR_INTERNAL", .doc = "Allocation or another host-internal operation failed." },
    .{ .name = "PANCAKE_ERR_WOULD_BLOCK", .doc = "No result is ready." },
    .{ .name = "PANCAKE_ERR_CLOSED", .doc = "The peer closed cleanly." },
    .{ .name = "PANCAKE_ERR_IO", .doc = "Transport I/O failed; read the matching archive's last-error slot." },
    .{ .name = "PANCAKE_ERR_MALFORMED", .doc = "Input bytes were malformed." },
    .{ .name = "PANCAKE_ERR_FRAME_TOO_LARGE", .doc = "A frame exceeded its configured limit." },
    .{ .name = "PANCAKE_ERR_UNSUPPORTED_VALUE", .doc = "The C value algebra cannot represent the supplied value." },
    .{ .name = "PANCAKE_ERR_BROKEN", .doc = "A remote promise broke." },
    .{ .name = "PANCAKE_ERR_NOT_FOUND", .doc = "The requested locator field or hint is absent." },
    .{ .name = "PANCAKE_ERR_BUFFER_TOO_SMALL", .doc = "The caller-provided output buffer is too small." },
    .{ .name = "PANCAKE_ERR_TIMEOUT", .doc = "The configured time budget expired." },
};

const emitted_fn_names = [_][]const u8{
    "pancake_abi_version",
    "pancake_managed_frame_release",
    "pancake_context_new",
    "pancake_context_new_with_allocator",
    "pancake_context_release",
    "pancake_last_error",
    "pancake_clear_last_error",
    "pancake_uri_parse_peer",
    "pancake_uri_parse_sturdyref",
    "pancake_uri_format_peer",
    "pancake_uri_format_sturdyref",
    "pancake_locator_transport",
    "pancake_locator_designator",
    "pancake_locator_host_port",
    "pancake_designator_host_port",
    "pancake_locator_swissnum",
    "pancake_locator_hint",
    "pancake_locator_hint_count",
    "pancake_locator_hint_at",
    "pancake_locator_release",
    "pancake_locator_record_encode",
    "pancake_locator_record_bytes_release",
};

const Spec = struct {
    pub const c = @import("c_abi");
    pub const emitted_fns: []const []const u8 = &emitted_fn_names;
    pub const const_docs = &const_doc_entries;

    pub fn special(comptime T: type) ?[]const u8 {
        if (T == Spec.c.ReleaseFn or T == ?Spec.c.ReleaseFn) return "PancakeReleaseFn";
        if (T == Spec.c.PancakeAllocFn or T == ?Spec.c.PancakeAllocFn) return "PancakeAllocFn";
        if (T == Spec.c.PancakeFreeFn or T == ?Spec.c.PancakeFreeFn) return "PancakeFreeFn";
        return null;
    }
};
const E = header_emit.Emit(Spec);
const Buf = header_emit.Buf;
const section = header_emit.section;
const emitDoc = header_emit.emitDoc;
const emitConst = E.emitConst;
const emitStruct = E.emitStruct;
const emitBareStruct = E.emitBareStruct;
const emitFn = E.emitFn;

comptime {
    @setEvalBranchQuota(40000);
    E.guardFns("c_abi", "pancake_");

    const all = version_consts ++ error_consts ++ discriminant_consts;
    for (@typeInfo(c).@"struct".decls) |decl| {
        if (!std.mem.startsWith(u8, decl.name, "PANCAKE_")) continue;
        if (@typeInfo(@TypeOf(@field(c, decl.name))) != .int) continue;
        var found = false;
        for (all) |name| {
            if (std.mem.eql(u8, name, decl.name)) found = true;
        }
        if (!found) @compileError("constant not emitted to pancake_ocapn.h: " ++ decl.name);
    }
}

fn generate(gpa: std.mem.Allocator) ![]u8 {
    var b: Buf = .empty;
    errdefer b.deinit(gpa);

    try b.appendSlice(gpa,
        \\/* Generated from src/c_abi/ocapn by tools/gen/header/ocapn.zig.
        \\   Run `zig build gen-header-ocapn`; do not edit this file. */
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

    inline for (version_consts) |name| try emitConst(&b, gpa, name);
    try emitFn(&b, gpa, "pancake_abi_version", &.{ "out_major", "out_minor", "out_patch" }, "Read the linked shared archive's ABI version.");
    try section(&b, gpa, "Return codes");
    inline for (error_consts) |name| try emitConst(&b, gpa, name);
    try section(&b, gpa, "Shared discriminants");
    inline for (discriminant_consts) |name| try emitConst(&b, gpa, name);

    try section(&b, gpa, "Frames");
    try emitStruct(&b, gpa, c.PancakeFrame, "PancakeFrame", &.{
        "borrowed bytes", "byte length", "PANCAKE_FRAME_SHAPE_*",
    });
    try b.appendSlice(gpa,
        \\typedef struct PancakeManagedFrame PancakeManagedFrame;
        \\typedef void (*PancakeReleaseFn)(PancakeManagedFrame *frame);
        \\
    );
    try emitBareStruct(&b, gpa, c.PancakeManagedFrame, "PancakeManagedFrame", &.{
        "owned bytes",                                               "byte length", "PANCAKE_FRAME_SHAPE_*",
        "internal release hook; call pancake_managed_frame_release", "",
    });
    try emitFn(&b, gpa, "pancake_managed_frame_release", &.{"frame"}, "Release an owned managed frame. NULL and repeated release are no-ops.");

    try section(&b, gpa, "Allocation context");
    try b.appendSlice(gpa,
        \\typedef struct PancakeContext PancakeContext;
        \\typedef void *(*PancakeAllocFn)(void *user_data, size_t size, size_t alignment);
        \\typedef void (*PancakeFreeFn)(void *user_data, void *ptr, size_t size, size_t alignment);
        \\
    );
    try emitStruct(&b, gpa, c.PancakeAllocator, "PancakeAllocator", &.{
        "required allocator", "required deallocator", "passed to both callbacks",
    });
    try emitFn(&b, gpa, "pancake_context_new", &.{"out_context"}, "Create a context backed by the library allocator.");
    try emitFn(&b, gpa, "pancake_context_new_with_allocator", &.{ "allocator", "out_context" }, "Create a context backed by caller callbacks. The callbacks must be thread-safe.");
    try emitFn(&b, gpa, "pancake_context_release", &.{"context"}, "Release a context after every handle created through it.");

    try section(&b, gpa, "Application values");
    try emitDoc(&b, gpa,
        \\PancakeArgument is the pass-by-copy value tree used by PancakeHost.
        \\Byte views and child arrays are borrowed on input and alias the owning
        \\Host result arena on output.
    );
    try emitStruct(&b, gpa, c.PancakeReference, "PancakeReference", &.{
        "opaque Host capability identity",
    });
    try emitStruct(&b, gpa, c.PancakeArgument, "PancakeArgument", &.{
        "PANCAKE_ARG_*", "boolean or big-integer sign", "integer",              "float",
        "byte payload",  "payload length",              "capability reference", "child values",
        "child count",
    });
    try emitStruct(&b, gpa, c.PancakeLastAbort, "PancakeLastAbort", &.{
        "PANCAKE_ABORT_DOMAIN_*", "whether kind_name is present", "static kind name",
        "kind length",            "static message",               "message length",
        "static Zig error name",  "error-name length",
    });

    try section(&b, gpa, "Per-thread last error");
    try emitFn(&b, gpa, "pancake_last_error", &.{ "out_buf", "cap" }, "Read this archive's calling-thread error message. NULL or cap 0 queries its length.");
    try emitFn(&b, gpa, "pancake_clear_last_error", &.{}, "Clear this archive's calling-thread error message.");

    try section(&b, gpa, "OCapN locators");
    try b.appendSlice(gpa, "typedef struct PancakeLocator PancakeLocator;\n\n");
    try emitFn(&b, gpa, "pancake_uri_parse_peer", &.{ "uri", "uri_len", "out_locator" }, "Parse an ocapn:// peer URI into an owned locator.");
    try emitFn(&b, gpa, "pancake_uri_parse_sturdyref", &.{ "uri", "uri_len", "out_locator" }, "Parse an ocapn:// sturdyref URI into an owned locator.");
    try emitFn(&b, gpa, "pancake_uri_format_peer", &.{ "transport", "transport_len", "designator", "designator_len", "hint_keys", "hint_key_lens", "hint_vals", "hint_val_lens", "hint_count", "out", "cap", "out_len" }, "Format a peer locator into a caller-owned buffer.");
    try emitFn(&b, gpa, "pancake_uri_format_sturdyref", &.{ "transport", "transport_len", "designator", "designator_len", "swissnum", "swissnum_len", "hint_keys", "hint_key_lens", "hint_vals", "hint_val_lens", "hint_count", "out", "cap", "out_len" }, "Format a sturdyref into a caller-owned buffer.");
    try emitFn(&b, gpa, "pancake_locator_transport", &.{ "loc", "out_ptr", "out_len" }, "Borrow the locator transport.");
    try emitFn(&b, gpa, "pancake_locator_designator", &.{ "loc", "out_ptr", "out_len" }, "Borrow the locator designator.");
    try emitFn(&b, gpa, "pancake_locator_host_port", &.{ "loc", "out_host", "out_host_len", "out_port" }, "Split a locator designator as host:port.");
    try emitFn(&b, gpa, "pancake_designator_host_port", &.{ "designator", "designator_len", "out_host", "out_host_len", "out_port" }, "Split a borrowed designator as host:port.");
    try emitFn(&b, gpa, "pancake_locator_swissnum", &.{ "loc", "out_ptr", "out_len" }, "Borrow the sturdyref swissnum, or an empty view for a peer locator.");
    try emitFn(&b, gpa, "pancake_locator_hint", &.{ "loc", "key", "key_len", "out_ptr", "out_len" }, "Borrow one locator hint by key.");
    try emitFn(&b, gpa, "pancake_locator_hint_count", &.{ "loc", "out_count" }, "Read the number of locator hints.");
    try emitFn(&b, gpa, "pancake_locator_hint_at", &.{ "loc", "idx", "out_key", "out_key_len", "out_val", "out_val_len" }, "Borrow one locator hint by index.");
    try emitFn(&b, gpa, "pancake_locator_release", &.{"loc"}, "Release an owned locator.");
    try emitFn(&b, gpa, "pancake_locator_record_encode", &.{ "transport", "transport_len", "designator", "designator_len", "direct_addresses", "direct_addresses_len", "out", "out_len" }, "Encode an owned Syrup <ocapn-peer> record for a signed handoff locator.");
    try emitFn(&b, gpa, "pancake_locator_record_bytes_release", &.{ "bytes", "len" }, "Release bytes returned by pancake_locator_record_encode.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* PANCAKE_OCAPN_H */
        \\
    );
    try E.assertAllEmitted(&b, "gen-header-ocapn");
    return b.toOwnedSlice(gpa);
}
