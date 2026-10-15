//! Generates the shared C vocabulary header from `c_abi`.
//!
//! Function signatures, constants, and layouts are reflected from the Zig
//! declarations. `libglowcap_host` supplies the application-facing CapTP API,
//! this archive supplies allocation, frame, value, and locator vocabulary.

const std = @import("std");
const c = @import("c_abi");
const header_emit = @import("header_emit.zig");

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/glowcap_ocapn.h", .generate = generate },
};
pub const step_name = "gen-header-ocapn";

const version_consts = [_][]const u8{
    "GLOWCAP_VERSION_MAJOR", "GLOWCAP_VERSION_MINOR", "GLOWCAP_VERSION_PATCH",
};
const error_consts = [_][]const u8{
    "GLOWCAP_OK",                   "GLOWCAP_ERR_NULL_POINTER",
    "GLOWCAP_ERR_INVALID_ARGUMENT", "GLOWCAP_ERR_SESSION",
    "GLOWCAP_ERR_CODEC",            "GLOWCAP_ERR_INTERNAL",
    "GLOWCAP_ERR_WOULD_BLOCK",      "GLOWCAP_ERR_CLOSED",
    "GLOWCAP_ERR_IO",               "GLOWCAP_ERR_MALFORMED",
    "GLOWCAP_ERR_FRAME_TOO_LARGE",  "GLOWCAP_ERR_UNSUPPORTED_VALUE",
    "GLOWCAP_ERR_BROKEN",           "GLOWCAP_ERR_NOT_FOUND",
    "GLOWCAP_ERR_BUFFER_TOO_SMALL", "GLOWCAP_ERR_TIMEOUT",
};
const discriminant_consts = [_][]const u8{
    "GLOWCAP_CODEC_UNKNOWN",          "GLOWCAP_CODEC_SYRUP",
    "GLOWCAP_CODEC_CAPNP",            "GLOWCAP_CAPTP_V1_0",
    "GLOWCAP_CAPTP_NEXT",             "GLOWCAP_FEATURE_PIPELINING",
    "GLOWCAP_FEATURE_HANDOFF",        "GLOWCAP_FEATURE_WIRE_DELTA",
    "GLOWCAP_FEATURE_STURDYREF",      "GLOWCAP_FEATURE_UNTAG",
    "GLOWCAP_FEATURE_MULTI_LOCATION", "GLOWCAP_FEATURE_MINIMUM",
    "GLOWCAP_FEATURE_BASELINE",       "GLOWCAP_FEATURE_FULL",
    "GLOWCAP_FRAME_SHAPE_BYTE",       "GLOWCAP_DEFAULT_CODEC",
    "GLOWCAP_DEFAULT_CAPTP_VERSION",  "GLOWCAP_DEFAULT_FEATURES",
    "GLOWCAP_OWN_CODEC",              "GLOWCAP_OWN_CAPTP_VERSION",
    "GLOWCAP_INTEROP_CODEC",          "GLOWCAP_INTEROP_CAPTP_VERSION",
    "GLOWCAP_FRAME_SHAPE_WORD",       "GLOWCAP_ARG_INTEGER",
    "GLOWCAP_ARG_FLOAT64",            "GLOWCAP_ARG_BOOLEAN",
    "GLOWCAP_ARG_BYTES",              "GLOWCAP_ARG_STRING",
    "GLOWCAP_ARG_SYMBOL",             "GLOWCAP_ARG_VOID",
    "GLOWCAP_ARG_REFERENCE",          "GLOWCAP_ARG_LIST",
    "GLOWCAP_ARG_SET",                "GLOWCAP_ARG_TAGGED",
    "GLOWCAP_ARG_KEYWORD",            "GLOWCAP_ARG_BIG_INTEGER",
    "GLOWCAP_ARG_STRUCT",             "GLOWCAP_ARG_ERROR",
    "GLOWCAP_ARG_INTEGERS",           "GLOWCAP_RESOLUTION_FULFILL",
    "GLOWCAP_RESOLUTION_BREAK",       "GLOWCAP_RESOLUTION_HANDOFF",
    "GLOWCAP_ABORT_DOMAIN_CODEC",     "GLOWCAP_ABORT_DOMAIN_SESSION",
    "GLOWCAP_ABORT_DOMAIN_FOREIGN",
};
const locator_consts = [_][]const u8{
    "GLOWCAP_LOCATOR_VIEW_ABI_VERSION", "GLOWCAP_HINT_STRING",
    "GLOWCAP_HINT_BYTES",               "GLOWCAP_HINT_BOOLEAN",
    "GLOWCAP_HINT_INTEGER",             "GLOWCAP_HINTS_MAP",
    "GLOWCAP_HINTS_BOOLEAN_FALSE",
};
const resource_consts = [_][]const u8{
    "GLOWCAP_RAW_TRANSPORT_DEFAULT_FRAME_CAP",
    "GLOWCAP_DEFAULT_FAILURE_CAPACITY",
    "GLOWCAP_DEFAULT_FAILURE_PAYLOAD_CAP",
};
const failure_consts = [_][]const u8{
    "GLOWCAP_FAILURE_EVENT_ABI_VERSION",
    "GLOWCAP_FAILURE_LAYER_CORE",
    "GLOWCAP_FAILURE_LAYER_DRIVER",
    "GLOWCAP_FAILURE_LAYER_TRANSPORT",
    "GLOWCAP_FAILURE_LAYER_BINDING",
    "GLOWCAP_FAILURE_LAYER_APPLICATION_OBSERVER",
    "GLOWCAP_FAILURE_SCOPE_PROCESS",
    "GLOWCAP_FAILURE_SCOPE_CONTEXT",
    "GLOWCAP_FAILURE_SCOPE_HOST",
    "GLOWCAP_FAILURE_SCOPE_SESSION",
    "GLOWCAP_FAILURE_SCOPE_LISTENER",
    "GLOWCAP_FAILURE_SCOPE_TRANSPORT",
    "GLOWCAP_FAILURE_SCOPE_OPERATION",
    "GLOWCAP_FAILURE_TRUNCATED_OPERATION",
    "GLOWCAP_FAILURE_TRUNCATED_PRIMARY_NAME",
    "GLOWCAP_FAILURE_TRUNCATED_PRIMARY_MESSAGE",
    "GLOWCAP_FAILURE_TRUNCATED_SECONDARY_NAME",
    "GLOWCAP_FAILURE_TRUNCATED_SECONDARY_MESSAGE",
};

const const_doc_entries = [_]struct { name: []const u8, doc: []const u8 }{
    .{ .name = "GLOWCAP_OK", .doc = "Success." },
    .{ .name = "GLOWCAP_ERR_NULL_POINTER", .doc = "A required pointer argument was NULL." },
    .{ .name = "GLOWCAP_ERR_INVALID_ARGUMENT", .doc = "An argument was outside its accepted range or grammar." },
    .{ .name = "GLOWCAP_ERR_SESSION", .doc = "The CapTP session refused the operation." },
    .{ .name = "GLOWCAP_ERR_CODEC", .doc = "A frame could not be decoded or encoded." },
    .{ .name = "GLOWCAP_ERR_INTERNAL", .doc = "Allocation or another host-internal operation failed." },
    .{ .name = "GLOWCAP_ERR_WOULD_BLOCK", .doc = "No result is ready." },
    .{ .name = "GLOWCAP_ERR_CLOSED", .doc = "The peer closed cleanly." },
    .{ .name = "GLOWCAP_ERR_IO", .doc = "Transport I/O failed; read the matching archive's last-error slot." },
    .{ .name = "GLOWCAP_ERR_MALFORMED", .doc = "Input bytes were malformed." },
    .{ .name = "GLOWCAP_ERR_FRAME_TOO_LARGE", .doc = "A frame exceeded its configured limit." },
    .{ .name = "GLOWCAP_ERR_UNSUPPORTED_VALUE", .doc = "The C value algebra cannot represent the supplied value." },
    .{ .name = "GLOWCAP_ERR_BROKEN", .doc = "A remote promise broke." },
    .{ .name = "GLOWCAP_ERR_NOT_FOUND", .doc = "The requested locator field or hint is absent." },
    .{ .name = "GLOWCAP_ERR_BUFFER_TOO_SMALL", .doc = "The caller-provided output buffer is too small." },
    .{ .name = "GLOWCAP_ERR_TIMEOUT", .doc = "The configured time budget expired." },
    .{ .name = "GLOWCAP_RAW_TRANSPORT_DEFAULT_FRAME_CAP", .doc = "Default max_frame_bytes for direct blocking transport frame-shuttle helpers." },
    .{ .name = "GLOWCAP_DEFAULT_CODEC", .doc = "Default codec selector for byte-fed Host constructors." },
    .{ .name = "GLOWCAP_DEFAULT_CAPTP_VERSION", .doc = "Default CapTP profile selector for byte-fed Host constructors." },
    .{ .name = "GLOWCAP_DEFAULT_FEATURES", .doc = "Default feature bitmask for byte-fed Host constructors." },
    .{ .name = "GLOWCAP_OWN_CODEC", .doc = "The codec glowcap's own Host profile prefers." },
    .{ .name = "GLOWCAP_OWN_CAPTP_VERSION", .doc = "The CapTP version glowcap's own Host profile prefers." },
    .{ .name = "GLOWCAP_INTEROP_CODEC", .doc = "Codec half of glowcap's coherent interop Host profile." },
    .{ .name = "GLOWCAP_INTEROP_CAPTP_VERSION", .doc = "CapTP-version half of glowcap's coherent interop Host profile." },
    .{ .name = "GLOWCAP_DEFAULT_FAILURE_CAPACITY", .doc = "Default records retained by a Context diagnostic queue." },
    .{ .name = "GLOWCAP_DEFAULT_FAILURE_PAYLOAD_CAP", .doc = "Default aggregate text bytes retained per Context diagnostic record." },
};

const emitted_fn_names = [_][]const u8{
    "glowcap_ocapn_archive_fingerprint",
    "glowcap_abi_version",
    "glowcap_managed_frame_release",
    "glowcap_context_new",
    "glowcap_context_new_with_allocator",
    "glowcap_context_allocate_lifecycle_id",
    "glowcap_context_report_failure",
    "glowcap_context_next_failure",
    "glowcap_context_release",
    "glowcap_last_error",
    "glowcap_clear_last_error",
    "glowcap_uri_parse_peer",
    "glowcap_uri_parse_peer_in",
    "glowcap_uri_parse_sturdyref",
    "glowcap_uri_parse_sturdyref_in",
    "glowcap_uri_format_peer",
    "glowcap_uri_format_sturdyref",
    "glowcap_locator_new",
    "glowcap_locator_new_in",
    "glowcap_locator_clone",
    "glowcap_locator_clone_in",
    "glowcap_locator_borrow_view",
    "glowcap_sturdyref_borrow_locator",
    "glowcap_sturdyref_swissnum",
    "glowcap_sturdyref_release",
    "glowcap_locator_add_string",
    "glowcap_locator_add_bytes",
    "glowcap_locator_add_boolean",
    "glowcap_locator_add_integer",
    "glowcap_locator_transport",
    "glowcap_locator_designator",
    "glowcap_locator_host_port",
    "glowcap_designator_host_port",
    "glowcap_locator_hint",
    "glowcap_locator_hint_count",
    "glowcap_locator_hint_at",
    "glowcap_locator_hint_wire_form",
    "glowcap_locator_release",
    "glowcap_locator_record_encode",
    "glowcap_locator_record_bytes_release",
};

const Spec = struct {
    pub const c = @import("c_abi");
    pub const emitted_fns: []const []const u8 = &emitted_fn_names;
    pub const const_docs = &const_doc_entries;

    pub fn special(comptime T: type) ?[]const u8 {
        if (T == Spec.c.ReleaseFn or T == ?Spec.c.ReleaseFn) return "GlowcapReleaseFn";
        if (T == Spec.c.GlowcapAllocFn or T == ?Spec.c.GlowcapAllocFn) return "GlowcapAllocFn";
        if (T == Spec.c.GlowcapFreeFn or T == ?Spec.c.GlowcapFreeFn) return "GlowcapFreeFn";
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
    E.guardFns("c_abi", "glowcap_");

    const all = version_consts ++ error_consts ++ discriminant_consts ++ locator_consts ++ resource_consts ++ failure_consts;
    for (@typeInfo(c).@"struct".decl_names) |decl_name| {
        if (!std.mem.startsWith(u8, decl_name, "GLOWCAP_")) continue;
        if (@typeInfo(@TypeOf(@field(c, decl_name))) != .int) continue;
        // Archive identity crosses through its function, not a C macro: a
        // consumer must compare against the binding/header version it built.
        if (std.mem.eql(u8, decl_name, "GLOWCAP_OCAPN_ARCHIVE_FINGERPRINT")) continue;
        var found = false;
        for (all) |name| {
            if (std.mem.eql(u8, name, decl_name)) found = true;
        }
        if (!found) @compileError("constant not emitted to glowcap_ocapn.h: " ++ decl_name);
    }
}

fn generate(gpa: std.mem.Allocator) ![]u8 {
    var b: Buf = .empty;
    errdefer b.deinit(gpa);

    try b.appendSlice(gpa,
        \\/* Generated from src/c_abi/ocapn by tools/gen/header/ocapn.zig.
        \\   Run `zig build gen-header-ocapn`; do not edit this file. */
        \\#ifndef GLOWCAP_OCAPN_H
        \\#define GLOWCAP_OCAPN_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include "glowcap_locator.h"
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    );

    inline for (version_consts) |name| try emitConst(&b, gpa, name);
    try emitFn(&b, gpa, "glowcap_ocapn_archive_fingerprint", &.{}, "Read the exact reflected callable and layout identity of this core archive.");
    try emitFn(&b, gpa, "glowcap_abi_version", &.{ "out_major", "out_minor", "out_patch" }, "Read the linked shared archive's ABI version.");
    try section(&b, gpa, "Return codes");
    inline for (error_consts) |name| try emitConst(&b, gpa, name);
    try section(&b, gpa, "Shared discriminants");
    inline for (discriminant_consts) |name| try emitConst(&b, gpa, name);
    try section(&b, gpa, "Resource limits");
    inline for (resource_consts) |name| try emitConst(&b, gpa, name);

    try section(&b, gpa, "Frames");
    try emitStruct(&b, gpa, c.GlowcapFrame, "GlowcapFrame", &.{
        "borrowed bytes", "byte length", "GLOWCAP_FRAME_SHAPE_*",
    });
    try b.appendSlice(gpa,
        \\typedef struct GlowcapManagedFrame GlowcapManagedFrame;
        \\typedef void (*GlowcapReleaseFn)(GlowcapManagedFrame *frame);
        \\
    );
    try emitBareStruct(&b, gpa, c.GlowcapManagedFrame, "GlowcapManagedFrame", &.{
        "owned bytes",                                               "byte length",                                  "GLOWCAP_FRAME_SHAPE_*",
        "internal release hook; call glowcap_managed_frame_release", "internal owned-frame storage; do not inspect",
    });
    try emitFn(&b, gpa, "glowcap_managed_frame_release", &.{"frame"}, "Release an owned managed frame. NULL and repeated release are no-ops.");

    try section(&b, gpa, "Allocation context");
    try b.appendSlice(gpa,
        \\typedef struct GlowcapContext GlowcapContext;
        \\typedef void *(*GlowcapAllocFn)(void *user_data, size_t size, size_t alignment);
        \\typedef void (*GlowcapFreeFn)(void *user_data, void *ptr, size_t size, size_t alignment);
        \\
    );
    try emitStruct(&b, gpa, c.GlowcapAllocator, "GlowcapAllocator", &.{
        "required allocator", "required deallocator", "passed to both callbacks",
    });
    try emitFn(&b, gpa, "glowcap_context_new", &.{"out_context"}, "Create a context backed by the library allocator.");
    try emitFn(&b, gpa, "glowcap_context_new_with_allocator", &.{ "allocator", "out_context" }, "Create a context backed by caller callbacks. The callbacks must be thread-safe.");
    try emitFn(&b, gpa, "glowcap_context_allocate_lifecycle_id", &.{ "context", "out_id" }, "Allocate a stable Context-local lifecycle identity. Zero is reserved for no identity; exhaustion leaves out_id unchanged.");
    try section(&b, gpa, "Unreturned failures");
    inline for (failure_consts) |name| try emitConst(&b, gpa, name);
    try emitStruct(&b, gpa, c.GlowcapFailureReport, "GlowcapFailureReport", &.{
        "GLOWCAP_FAILURE_EVENT_ABI_VERSION", "sizeof(GlowcapFailureReport)",       "GLOWCAP_FAILURE_LAYER_*",        "GLOWCAP_FAILURE_SCOPE_*",
        "stable identity within the scope",  "stable operation identity, or zero", "stable primary result, or zero", "stable first secondary result, or zero",
        "total secondary failures",          "required operation name",            "operation length",               "required primary cause name",
        "primary name length",               "optional primary message",           "primary message length",         "optional first secondary cause name",
        "secondary name length",             "optional first secondary message",   "secondary message length",
    });
    try emitStruct(&b, gpa, c.GlowcapFailureEvent, "GlowcapFailureEvent", &.{
        "GLOWCAP_FAILURE_EVENT_ABI_VERSION",         "sizeof(GlowcapFailureEvent)",            "monotonic Context sequence",                   "records lost before this one",
        "GLOWCAP_FAILURE_LAYER_*",                   "GLOWCAP_FAILURE_SCOPE_*",                "stable identity within the scope",             "stable operation identity, or zero",
        "stable primary result, or zero",            "stable first secondary result, or zero", "total secondary failures",                     "GLOWCAP_FAILURE_TRUNCATED_* bitmask",
        "operation in caller payload",               "operation length",                       "primary cause name in caller payload",         "primary name length",
        "primary message in caller payload",         "primary message length",                 "first secondary cause name in caller payload", "secondary name length",
        "first secondary message in caller payload", "secondary message length",
    });
    try emitFn(&b, gpa, "glowcap_context_report_failure", &.{ "context", "report" }, "Record one failure only after its last deterministic return recipient has gone. Text fields must be valid UTF-8; the Context copies bounded code-point prefixes and retains no report pointer. Result codes must be zero or stable GLOWCAP_ERR_* values; secondary fields must agree with secondary_count.");
    try emitFn(&b, gpa, "glowcap_context_next_failure", &.{ "context", "out_event", "out_payload", "payload_cap", "out_required" }, "Atomically claim the oldest unreturned failure into caller-owned payload storage. BUFFER_TOO_SMALL leaves it queued and reports the exact required bytes; WOULD_BLOCK reports an empty queue.");
    try emitFn(&b, gpa, "glowcap_context_release", &.{"context"}, "Release a context after every handle created through it.");

    try section(&b, gpa, "Application values");
    try emitDoc(&b, gpa,
        \\GlowcapArgument is the pass-by-copy value tree used by GlowcapHost.
        \\Byte views and child arrays are borrowed on input and alias the owning
        \\Host result arena on output. GLOWCAP_ARG_STRUCT uses an even-length
        \\items array of alternating GLOWCAP_ARG_STRING keys and values; keys
        \\must be unique.
    );
    try emitStruct(&b, gpa, c.GlowcapReference, "GlowcapReference", &.{
        "opaque process-unique Host capability identity; compare ids for Target equality",
    });
    try emitStruct(&b, gpa, c.GlowcapArgument, "GlowcapArgument", &.{
        "GLOWCAP_ARG_*", "boolean or big-integer sign", "integer",              "float",
        "byte payload",  "payload length",              "capability reference", "child values",
        "child count",
    });
    try emitStruct(&b, gpa, c.GlowcapLastAbort, "GlowcapLastAbort", &.{
        "GLOWCAP_ABORT_DOMAIN_*",                          "whether kind_name is present",      "static kind name",
        "kind length",                                     "static message",                    "message length",
        "static Zig error name",                           "error-name length",                 "static abort-delivery error name",
        "abort-delivery error-name length",                "static first secondary error name", "secondary error-name length",
        "secondary failure count (255 means 255 or more)",
    });

    try section(&b, gpa, "Per-thread last error");
    try emitFn(&b, gpa, "glowcap_last_error", &.{ "out_buf", "cap" }, "Read this archive's calling-thread error message. NULL or cap 0 queries its length." ++ header_emit.last_error_freshness_doc);
    try emitFn(&b, gpa, "glowcap_clear_last_error", &.{}, "Clear this archive's calling-thread error message.");

    try section(&b, gpa, "OCapN locators");
    try b.appendSlice(gpa,
        \\typedef struct GlowcapLocator GlowcapLocator;
        \\typedef struct GlowcapSturdyRef GlowcapSturdyRef;
        \\
    );
    try emitFn(&b, gpa, "glowcap_uri_parse_peer", &.{ "uri", "uri_len", "out_locator" }, "Parse an ocapn:// peer URI into an owned locator.");
    try emitFn(&b, gpa, "glowcap_uri_parse_peer_in", &.{ "context", "uri", "uri_len", "out_locator" }, "Parse a peer URI into a locator allocated through context.");
    try emitFn(&b, gpa, "glowcap_uri_parse_sturdyref", &.{ "captp_version", "uri", "uri_len", "out_sturdyref" }, "Parse an ocapn:// sturdyref URI under the selected GLOWCAP_CAPTP_* profile into an owned sturdyref.");
    try emitFn(&b, gpa, "glowcap_uri_parse_sturdyref_in", &.{ "context", "captp_version", "uri", "uri_len", "out_sturdyref" }, "Parse a sturdyref URI under the selected GLOWCAP_CAPTP_* profile through context.");
    try emitFn(&b, gpa, "glowcap_uri_format_peer", &.{ "transport", "transport_len", "designator", "designator_len", "hint_keys", "hint_key_lens", "hint_vals", "hint_val_lens", "hint_count", "out", "cap", "out_len" }, "Format a peer locator into a caller-owned buffer. out_len is mandatory and\nreceives the required byte length, excluding any NUL terminator. A null output\nis allowed only with cap == 0 to query that length; a short buffer reports the\nrequired length and returns GLOWCAP_ERR_BUFFER_TOO_SMALL.");
    try emitFn(&b, gpa, "glowcap_uri_format_sturdyref", &.{ "captp_version", "transport", "transport_len", "designator", "designator_len", "swissnum", "swissnum_len", "hint_keys", "hint_key_lens", "hint_vals", "hint_val_lens", "hint_count", "out", "cap", "out_len" }, "Format a sturdyref under the selected GLOWCAP_CAPTP_* profile into a\ncaller-owned buffer. out_len is mandatory and receives the required byte length,\nexcluding any NUL terminator. A null output is allowed only with cap == 0 to\nquery that length; a short buffer reports the required length and returns\nGLOWCAP_ERR_BUFFER_TOO_SMALL.");
    try emitFn(&b, gpa, "glowcap_locator_new", &.{ "transport", "transport_len", "designator", "designator_len", "hint_wire_form", "out_locator" }, "Construct an owned OCapN peer locator.");
    try emitFn(&b, gpa, "glowcap_locator_new_in", &.{ "context", "transport", "transport_len", "designator", "designator_len", "hint_wire_form", "out_locator" }, "Construct an OCapN peer locator allocated through context.");
    try emitFn(&b, gpa, "glowcap_locator_clone", &.{ "view", "out_locator" }, "Clone a borrowed locator view into an owned OCapN locator.");
    try emitFn(&b, gpa, "glowcap_locator_clone_in", &.{ "context", "view", "out_locator" }, "Clone a borrowed locator view through context.");
    try emitFn(&b, gpa, "glowcap_locator_borrow_view", &.{ "loc", "out_view" }, "Borrow the complete locator view until mutation or release.");
    try emitFn(&b, gpa, "glowcap_sturdyref_borrow_locator", &.{ "sturdyref", "out_view" }, "Borrow the sturdyref's embedded peer locator view.");
    try emitFn(&b, gpa, "glowcap_sturdyref_swissnum", &.{ "sturdyref", "out_ptr", "out_len" }, "Borrow the sturdyref's authority-bearing swissnum.");
    try emitFn(&b, gpa, "glowcap_sturdyref_release", &.{"sturdyref"}, "Release an owned sturdyref.");
    try emitFn(&b, gpa, "glowcap_locator_add_string", &.{ "loc", "name", "name_len", "value", "value_len" }, "Add one owned string hint.");
    try emitFn(&b, gpa, "glowcap_locator_add_bytes", &.{ "loc", "name", "name_len", "value", "value_len" }, "Add one owned byte-string hint.");
    try emitFn(&b, gpa, "glowcap_locator_add_boolean", &.{ "loc", "name", "name_len", "value" }, "Add one owned boolean hint.");
    try emitFn(&b, gpa, "glowcap_locator_add_integer", &.{ "loc", "name", "name_len", "value" }, "Add one owned integer hint.");
    try emitFn(&b, gpa, "glowcap_locator_transport", &.{ "loc", "out_ptr", "out_len" }, "Borrow the locator transport.");
    try emitFn(&b, gpa, "glowcap_locator_designator", &.{ "loc", "out_ptr", "out_len" }, "Borrow the locator designator.");
    try emitFn(&b, gpa, "glowcap_locator_host_port", &.{ "loc", "out_host", "out_host_len", "out_port" }, "Split a locator designator as host:port.");
    try emitFn(&b, gpa, "glowcap_designator_host_port", &.{ "designator", "designator_len", "out_host", "out_host_len", "out_port" }, "Split a borrowed designator as host:port.");
    try emitFn(&b, gpa, "glowcap_locator_hint", &.{ "loc", "key", "key_len", "out_hint" }, "Borrow one typed locator hint by key.");
    try emitFn(&b, gpa, "glowcap_locator_hint_count", &.{ "loc", "out_count" }, "Read the number of locator hints.");
    try emitFn(&b, gpa, "glowcap_locator_hint_at", &.{ "loc", "idx", "out_hint" }, "Borrow one typed locator hint by index.");
    try emitFn(&b, gpa, "glowcap_locator_hint_wire_form", &.{ "loc", "out_wire_form" }, "Read the locator hint container's wire spelling.");
    try emitFn(&b, gpa, "glowcap_locator_release", &.{"loc"}, "Release an owned locator.");
    try emitFn(&b, gpa, "glowcap_locator_record_encode", &.{ "locator", "out", "out_len" }, "Encode an owned Syrup <ocapn-peer> record for a signed handoff locator.");
    try emitFn(&b, gpa, "glowcap_locator_record_bytes_release", &.{ "bytes", "len" }, "Release bytes returned by glowcap_locator_record_encode.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* GLOWCAP_OCAPN_H */
        \\
    );
    try E.assertAllEmitted(&b, "gen-header-ocapn");
    return b.toOwnedSlice(gpa);
}
