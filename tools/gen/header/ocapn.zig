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
    "PANCAKE_CODEC_UNKNOWN",          "PANCAKE_CODEC_SYRUP",
    "PANCAKE_CODEC_CAPNP",            "PANCAKE_CAPTP_V1_0",
    "PANCAKE_CAPTP_NEXT",             "PANCAKE_FEATURE_PIPELINING",
    "PANCAKE_FEATURE_HANDOFF",        "PANCAKE_FEATURE_WIRE_DELTA",
    "PANCAKE_FEATURE_STURDYREF",      "PANCAKE_FEATURE_UNTAG",
    "PANCAKE_FEATURE_MULTI_LOCATION", "PANCAKE_FEATURE_MINIMUM",
    "PANCAKE_FEATURE_BASELINE",       "PANCAKE_FEATURE_FULL",
    "PANCAKE_FRAME_SHAPE_BYTE",       "PANCAKE_DEFAULT_CODEC",
    "PANCAKE_DEFAULT_CAPTP_VERSION",  "PANCAKE_DEFAULT_FEATURES",
    "PANCAKE_FRAME_SHAPE_WORD",       "PANCAKE_ARG_INTEGER",
    "PANCAKE_ARG_FLOAT64",            "PANCAKE_ARG_BOOLEAN",
    "PANCAKE_ARG_BYTES",              "PANCAKE_ARG_STRING",
    "PANCAKE_ARG_SYMBOL",             "PANCAKE_ARG_VOID",
    "PANCAKE_ARG_REFERENCE",          "PANCAKE_ARG_LIST",
    "PANCAKE_ARG_SET",                "PANCAKE_ARG_TAGGED",
    "PANCAKE_ARG_KEYWORD",            "PANCAKE_ARG_BIG_INTEGER",
    "PANCAKE_ARG_STRUCT",             "PANCAKE_ARG_ERROR",
    "PANCAKE_RESOLUTION_FULFILL",     "PANCAKE_RESOLUTION_BREAK",
    "PANCAKE_RESOLUTION_HANDOFF",     "PANCAKE_ABORT_DOMAIN_CODEC",
    "PANCAKE_ABORT_DOMAIN_SESSION",   "PANCAKE_ABORT_DOMAIN_FOREIGN",
};
const locator_consts = [_][]const u8{
    "PANCAKE_LOCATOR_VIEW_ABI_VERSION", "PANCAKE_HINT_STRING",
    "PANCAKE_HINT_BYTES",               "PANCAKE_HINT_BOOLEAN",
    "PANCAKE_HINT_INTEGER",             "PANCAKE_HINTS_MAP",
    "PANCAKE_HINTS_BOOLEAN_FALSE",
};
const resource_consts = [_][]const u8{
    "PANCAKE_RAW_TRANSPORT_DEFAULT_FRAME_CAP",
    "PANCAKE_DEFAULT_FAILURE_CAPACITY",
    "PANCAKE_DEFAULT_FAILURE_PAYLOAD_CAP",
};
const failure_consts = [_][]const u8{
    "PANCAKE_FAILURE_EVENT_ABI_VERSION",
    "PANCAKE_FAILURE_LAYER_CORE",
    "PANCAKE_FAILURE_LAYER_DRIVER",
    "PANCAKE_FAILURE_LAYER_TRANSPORT",
    "PANCAKE_FAILURE_LAYER_BINDING",
    "PANCAKE_FAILURE_LAYER_APPLICATION_OBSERVER",
    "PANCAKE_FAILURE_SCOPE_PROCESS",
    "PANCAKE_FAILURE_SCOPE_CONTEXT",
    "PANCAKE_FAILURE_SCOPE_HOST",
    "PANCAKE_FAILURE_SCOPE_SESSION",
    "PANCAKE_FAILURE_SCOPE_LISTENER",
    "PANCAKE_FAILURE_SCOPE_TRANSPORT",
    "PANCAKE_FAILURE_SCOPE_OPERATION",
    "PANCAKE_FAILURE_TRUNCATED_OPERATION",
    "PANCAKE_FAILURE_TRUNCATED_PRIMARY_NAME",
    "PANCAKE_FAILURE_TRUNCATED_PRIMARY_MESSAGE",
    "PANCAKE_FAILURE_TRUNCATED_SECONDARY_NAME",
    "PANCAKE_FAILURE_TRUNCATED_SECONDARY_MESSAGE",
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
    .{ .name = "PANCAKE_RAW_TRANSPORT_DEFAULT_FRAME_CAP", .doc = "Default max_frame_bytes for direct blocking transport frame-shuttle helpers." },
    .{ .name = "PANCAKE_DEFAULT_CODEC", .doc = "Default codec selector for byte-fed Host constructors." },
    .{ .name = "PANCAKE_DEFAULT_CAPTP_VERSION", .doc = "Default CapTP profile selector for byte-fed Host constructors." },
    .{ .name = "PANCAKE_DEFAULT_FEATURES", .doc = "Default feature bitmask for byte-fed Host constructors." },
    .{ .name = "PANCAKE_DEFAULT_FAILURE_CAPACITY", .doc = "Default records retained by a Context diagnostic queue." },
    .{ .name = "PANCAKE_DEFAULT_FAILURE_PAYLOAD_CAP", .doc = "Default aggregate text bytes retained per Context diagnostic record." },
};

const emitted_fn_names = [_][]const u8{
    "pancake_ocapn_archive_fingerprint",
    "pancake_abi_version",
    "pancake_managed_frame_release",
    "pancake_context_new",
    "pancake_context_new_with_allocator",
    "pancake_context_allocate_lifecycle_id",
    "pancake_context_report_failure",
    "pancake_context_next_failure",
    "pancake_context_release",
    "pancake_last_error",
    "pancake_clear_last_error",
    "pancake_uri_parse_peer",
    "pancake_uri_parse_peer_in",
    "pancake_uri_parse_sturdyref",
    "pancake_uri_parse_sturdyref_in",
    "pancake_uri_format_peer",
    "pancake_uri_format_sturdyref",
    "pancake_locator_new",
    "pancake_locator_new_in",
    "pancake_locator_clone",
    "pancake_locator_clone_in",
    "pancake_locator_borrow_view",
    "pancake_sturdyref_borrow_locator",
    "pancake_sturdyref_swissnum",
    "pancake_sturdyref_release",
    "pancake_locator_add_string",
    "pancake_locator_add_bytes",
    "pancake_locator_add_boolean",
    "pancake_locator_add_integer",
    "pancake_locator_transport",
    "pancake_locator_designator",
    "pancake_locator_host_port",
    "pancake_designator_host_port",
    "pancake_locator_hint",
    "pancake_locator_hint_count",
    "pancake_locator_hint_at",
    "pancake_locator_hint_wire_form",
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

    const all = version_consts ++ error_consts ++ discriminant_consts ++ locator_consts ++ resource_consts ++ failure_consts;
    for (@typeInfo(c).@"struct".decl_names) |decl_name| {
        if (!std.mem.startsWith(u8, decl_name, "PANCAKE_")) continue;
        if (@typeInfo(@TypeOf(@field(c, decl_name))) != .int) continue;
        // Archive identity crosses through its function, not a C macro: a
        // consumer must compare against the binding/header version it built.
        if (std.mem.eql(u8, decl_name, "PANCAKE_OCAPN_ARCHIVE_FINGERPRINT")) continue;
        var found = false;
        for (all) |name| {
            if (std.mem.eql(u8, name, decl_name)) found = true;
        }
        if (!found) @compileError("constant not emitted to pancake_ocapn.h: " ++ decl_name);
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
        \\#include "pancake_locator.h"
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    );

    inline for (version_consts) |name| try emitConst(&b, gpa, name);
    try emitFn(&b, gpa, "pancake_ocapn_archive_fingerprint", &.{}, "Read the exact reflected callable and layout identity of this core archive.");
    try emitFn(&b, gpa, "pancake_abi_version", &.{ "out_major", "out_minor", "out_patch" }, "Read the linked shared archive's ABI version.");
    try section(&b, gpa, "Return codes");
    inline for (error_consts) |name| try emitConst(&b, gpa, name);
    try section(&b, gpa, "Shared discriminants");
    inline for (discriminant_consts) |name| try emitConst(&b, gpa, name);
    try section(&b, gpa, "Resource limits");
    inline for (resource_consts) |name| try emitConst(&b, gpa, name);

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
        "owned bytes",                                               "byte length",                                  "PANCAKE_FRAME_SHAPE_*",
        "internal release hook; call pancake_managed_frame_release", "internal owned-frame storage; do not inspect",
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
    try emitFn(&b, gpa, "pancake_context_allocate_lifecycle_id", &.{ "context", "out_id" }, "Allocate a stable Context-local lifecycle identity. Zero is reserved for no identity; exhaustion leaves out_id unchanged.");
    try section(&b, gpa, "Unreturned failures");
    inline for (failure_consts) |name| try emitConst(&b, gpa, name);
    try emitStruct(&b, gpa, c.PancakeFailureReport, "PancakeFailureReport", &.{
        "PANCAKE_FAILURE_EVENT_ABI_VERSION", "sizeof(PancakeFailureReport)",       "PANCAKE_FAILURE_LAYER_*",        "PANCAKE_FAILURE_SCOPE_*",
        "stable identity within the scope",  "stable operation identity, or zero", "stable primary result, or zero", "stable first secondary result, or zero",
        "total secondary failures",          "required operation name",            "operation length",               "required primary cause name",
        "primary name length",               "optional primary message",           "primary message length",         "optional first secondary cause name",
        "secondary name length",             "optional first secondary message",   "secondary message length",
    });
    try emitStruct(&b, gpa, c.PancakeFailureEvent, "PancakeFailureEvent", &.{
        "PANCAKE_FAILURE_EVENT_ABI_VERSION",         "sizeof(PancakeFailureEvent)",            "monotonic Context sequence",                   "records lost before this one",
        "PANCAKE_FAILURE_LAYER_*",                   "PANCAKE_FAILURE_SCOPE_*",                "stable identity within the scope",             "stable operation identity, or zero",
        "stable primary result, or zero",            "stable first secondary result, or zero", "total secondary failures",                     "PANCAKE_FAILURE_TRUNCATED_* bitmask",
        "operation in caller payload",               "operation length",                       "primary cause name in caller payload",         "primary name length",
        "primary message in caller payload",         "primary message length",                 "first secondary cause name in caller payload", "secondary name length",
        "first secondary message in caller payload", "secondary message length",
    });
    try emitFn(&b, gpa, "pancake_context_report_failure", &.{ "context", "report" }, "Record one failure only after its last deterministic return recipient has gone. Text fields must be valid UTF-8; the Context copies bounded code-point prefixes and retains no report pointer. Result codes must be zero or stable PANCAKE_ERR_* values; secondary fields must agree with secondary_count.");
    try emitFn(&b, gpa, "pancake_context_next_failure", &.{ "context", "out_event", "out_payload", "payload_cap", "out_required" }, "Atomically claim the oldest unreturned failure into caller-owned payload storage. BUFFER_TOO_SMALL leaves it queued and reports the exact required bytes; WOULD_BLOCK reports an empty queue.");
    try emitFn(&b, gpa, "pancake_context_release", &.{"context"}, "Release a context after every handle created through it.");

    try section(&b, gpa, "Application values");
    try emitDoc(&b, gpa,
        \\PancakeArgument is the pass-by-copy value tree used by PancakeHost.
        \\Byte views and child arrays are borrowed on input and alias the owning
        \\Host result arena on output. PANCAKE_ARG_STRUCT uses an even-length
        \\items array of alternating PANCAKE_ARG_STRING keys and values; keys
        \\must be unique.
    );
    try emitStruct(&b, gpa, c.PancakeReference, "PancakeReference", &.{
        "opaque process-unique Host capability identity; compare ids for Target equality",
    });
    try emitStruct(&b, gpa, c.PancakeArgument, "PancakeArgument", &.{
        "PANCAKE_ARG_*", "boolean or big-integer sign", "integer",              "float",
        "byte payload",  "payload length",              "capability reference", "child values",
        "child count",
    });
    try emitStruct(&b, gpa, c.PancakeLastAbort, "PancakeLastAbort", &.{
        "PANCAKE_ABORT_DOMAIN_*",                          "whether kind_name is present",      "static kind name",
        "kind length",                                     "static message",                    "message length",
        "static Zig error name",                           "error-name length",                 "static abort-delivery error name",
        "abort-delivery error-name length",                "static first secondary error name", "secondary error-name length",
        "secondary failure count (255 means 255 or more)",
    });

    try section(&b, gpa, "Per-thread last error");
    try emitFn(&b, gpa, "pancake_last_error", &.{ "out_buf", "cap" }, "Read this archive's calling-thread error message. NULL or cap 0 queries its length." ++ header_emit.last_error_freshness_doc);
    try emitFn(&b, gpa, "pancake_clear_last_error", &.{}, "Clear this archive's calling-thread error message.");

    try section(&b, gpa, "OCapN locators");
    try b.appendSlice(gpa,
        \\typedef struct PancakeLocator PancakeLocator;
        \\typedef struct PancakeSturdyRef PancakeSturdyRef;
        \\
    );
    try emitFn(&b, gpa, "pancake_uri_parse_peer", &.{ "uri", "uri_len", "out_locator" }, "Parse an ocapn:// peer URI into an owned locator.");
    try emitFn(&b, gpa, "pancake_uri_parse_peer_in", &.{ "context", "uri", "uri_len", "out_locator" }, "Parse a peer URI into a locator allocated through context.");
    try emitFn(&b, gpa, "pancake_uri_parse_sturdyref", &.{ "captp_version", "uri", "uri_len", "out_sturdyref" }, "Parse an ocapn:// sturdyref URI under the selected PANCAKE_CAPTP_* profile into an owned sturdyref.");
    try emitFn(&b, gpa, "pancake_uri_parse_sturdyref_in", &.{ "context", "captp_version", "uri", "uri_len", "out_sturdyref" }, "Parse a sturdyref URI under the selected PANCAKE_CAPTP_* profile through context.");
    try emitFn(&b, gpa, "pancake_uri_format_peer", &.{ "transport", "transport_len", "designator", "designator_len", "hint_keys", "hint_key_lens", "hint_vals", "hint_val_lens", "hint_count", "out", "cap", "out_len" }, "Format a peer locator into a caller-owned buffer. out_len is mandatory and\nreceives the required byte length, excluding any NUL terminator. A null output\nis allowed only with cap == 0 to query that length; a short buffer reports the\nrequired length and returns PANCAKE_ERR_BUFFER_TOO_SMALL.");
    try emitFn(&b, gpa, "pancake_uri_format_sturdyref", &.{ "captp_version", "transport", "transport_len", "designator", "designator_len", "swissnum", "swissnum_len", "hint_keys", "hint_key_lens", "hint_vals", "hint_val_lens", "hint_count", "out", "cap", "out_len" }, "Format a sturdyref under the selected PANCAKE_CAPTP_* profile into a\ncaller-owned buffer. out_len is mandatory and receives the required byte length,\nexcluding any NUL terminator. A null output is allowed only with cap == 0 to\nquery that length; a short buffer reports the required length and returns\nPANCAKE_ERR_BUFFER_TOO_SMALL.");
    try emitFn(&b, gpa, "pancake_locator_new", &.{ "transport", "transport_len", "designator", "designator_len", "hint_wire_form", "out_locator" }, "Construct an owned OCapN peer locator.");
    try emitFn(&b, gpa, "pancake_locator_new_in", &.{ "context", "transport", "transport_len", "designator", "designator_len", "hint_wire_form", "out_locator" }, "Construct an OCapN peer locator allocated through context.");
    try emitFn(&b, gpa, "pancake_locator_clone", &.{ "view", "out_locator" }, "Clone a borrowed locator view into an owned OCapN locator.");
    try emitFn(&b, gpa, "pancake_locator_clone_in", &.{ "context", "view", "out_locator" }, "Clone a borrowed locator view through context.");
    try emitFn(&b, gpa, "pancake_locator_borrow_view", &.{ "loc", "out_view" }, "Borrow the complete locator view until mutation or release.");
    try emitFn(&b, gpa, "pancake_sturdyref_borrow_locator", &.{ "sturdyref", "out_view" }, "Borrow the sturdyref's embedded peer locator view.");
    try emitFn(&b, gpa, "pancake_sturdyref_swissnum", &.{ "sturdyref", "out_ptr", "out_len" }, "Borrow the sturdyref's authority-bearing swissnum.");
    try emitFn(&b, gpa, "pancake_sturdyref_release", &.{"sturdyref"}, "Release an owned sturdyref.");
    try emitFn(&b, gpa, "pancake_locator_add_string", &.{ "loc", "name", "name_len", "value", "value_len" }, "Add one owned string hint.");
    try emitFn(&b, gpa, "pancake_locator_add_bytes", &.{ "loc", "name", "name_len", "value", "value_len" }, "Add one owned byte-string hint.");
    try emitFn(&b, gpa, "pancake_locator_add_boolean", &.{ "loc", "name", "name_len", "value" }, "Add one owned boolean hint.");
    try emitFn(&b, gpa, "pancake_locator_add_integer", &.{ "loc", "name", "name_len", "value" }, "Add one owned integer hint.");
    try emitFn(&b, gpa, "pancake_locator_transport", &.{ "loc", "out_ptr", "out_len" }, "Borrow the locator transport.");
    try emitFn(&b, gpa, "pancake_locator_designator", &.{ "loc", "out_ptr", "out_len" }, "Borrow the locator designator.");
    try emitFn(&b, gpa, "pancake_locator_host_port", &.{ "loc", "out_host", "out_host_len", "out_port" }, "Split a locator designator as host:port.");
    try emitFn(&b, gpa, "pancake_designator_host_port", &.{ "designator", "designator_len", "out_host", "out_host_len", "out_port" }, "Split a borrowed designator as host:port.");
    try emitFn(&b, gpa, "pancake_locator_hint", &.{ "loc", "key", "key_len", "out_hint" }, "Borrow one typed locator hint by key.");
    try emitFn(&b, gpa, "pancake_locator_hint_count", &.{ "loc", "out_count" }, "Read the number of locator hints.");
    try emitFn(&b, gpa, "pancake_locator_hint_at", &.{ "loc", "idx", "out_hint" }, "Borrow one typed locator hint by index.");
    try emitFn(&b, gpa, "pancake_locator_hint_wire_form", &.{ "loc", "out_wire_form" }, "Read the locator hint container's wire spelling.");
    try emitFn(&b, gpa, "pancake_locator_release", &.{"loc"}, "Release an owned locator.");
    try emitFn(&b, gpa, "pancake_locator_record_encode", &.{ "locator", "out", "out_len" }, "Encode an owned Syrup <ocapn-peer> record for a signed handoff locator.");
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
