//! Generates `include/pancake_ocapn.h` from the Zig `c_abi` (ocapn) source.
//!
//! `pancake_ocapn.h` is the peer-first waist: shared vocabulary plus the
//! peer/uri families. Multi-session CapTP product work uses
//! `pancake_host_*` in `pancake_driver.h`. Struct layouts, constant values,
//! and function signatures are *reflected* from the real `c_abi` types, and
//! the prose lives here. `zig build gen-header-ocapn` writes the header; the
//! check step asserts the committed file matches. Transport archives
//! `#include` `pancake_ocapn.h` (ADR-0059).

const std = @import("std");
const c = @import("c_abi");
const header_emit = @import("header_emit.zig");

// The constant names the header emits, grouped for section comments. The version
// macros are emitted inline; these three groups plus the version triple are the
// complete set, guarded below so a new c_abi constant cannot be silently dropped.
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
    "PANCAKE_ERR_BUFFER_TOO_SMALL",
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
    "PANCAKE_PROJECTION_NONE",        "PANCAKE_PROJECTION_DELIVER",
    "PANCAKE_PROJECTION_RESOLVE",     "PANCAKE_PROJECTION_FRAME",
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
    "PANCAKE_REDEEMED_TOKEN_BASE",
};

// One curated comment line per constant that needs one (every return code, plus
// the discriminants whose meaning is not obvious from the name). `emitConst`
// consults this table; the guard below keeps every return code documented.
const const_doc_entries = [_]struct { name: []const u8, doc: []const u8 }{
    .{ .name = "PANCAKE_OK", .doc = "Success." },
    .{ .name = "PANCAKE_ERR_NULL_POINTER", .doc = "A required pointer argument was NULL." },
    .{ .name = "PANCAKE_ERR_INVALID_ARGUMENT", .doc = "A non-pointer argument was out of range or unparseable (a bad shape/codec discriminant, a zero frame cap, an unparseable host address)." },
    .{ .name = "PANCAKE_ERR_SESSION", .doc = "The session state machine refused the operation (a protocol violation, a resource cap, an already-closed session)." },
    .{ .name = "PANCAKE_ERR_CODEC", .doc = "Inbound bytes failed codec decode, or outbound work failed to encode." },
    .{ .name = "PANCAKE_ERR_INTERNAL", .doc = "A host-internal failure (allocation, ...)." },
    .{ .name = "PANCAKE_ERR_WOULD_BLOCK", .doc = "Nothing to do right now: an empty queue, or a partial frame awaiting more bytes." },
    .{ .name = "PANCAKE_ERR_CLOSED", .doc = "The peer closed the stream gracefully on a frame boundary (clean EOF)." },
    .{ .name = "PANCAKE_ERR_IO", .doc = "An underlying socket read/write failed; pancake_last_error carries the concrete cause." },
    .{ .name = "PANCAKE_ERR_MALFORMED", .doc = "Inbound bytes were not a structurally valid frame." },
    .{ .name = "PANCAKE_ERR_FRAME_TOO_LARGE", .doc = "An inbound frame exceeded the endpoint's max_frame_bytes." },
    .{ .name = "PANCAKE_ERR_UNSUPPORTED_VALUE", .doc = "A value SENT across the typed surface uses a variant the C ABI cannot carry (a handoff argument, an OCapN Struct argument, or a sturdy/broken reference target): refused loudly rather than marshalled wrong. There is no PANCAKE_ARG_STRUCT, so a Struct cannot be built as an argument. Received values never earn this code — pancake_peer_next_event projects an uncarriable inbound value (a Struct among them) as its raw wire frame instead." },
    .{ .name = "PANCAKE_ERR_BROKEN", .doc = "A partner broke a promise. The sans-io libpancake_ocapn surface never returns this: a break arrives there as a PANCAKE_RESOLUTION_BREAK resolve event. The owning-session transport surfaces do return it — pancake_tcp_session_fetch (pancake_net_transport_tcp.h) reports a partner break this way, and any future transport twin the same — and bindings reuse the code for that meaning." },
    .{ .name = "PANCAKE_ERR_NOT_FOUND", .doc = "A well-formed lookup found nothing: pancake_locator_hint named a key absent from the locator. Distinct from _INVALID_ARGUMENT (a malformed request)." },
    .{ .name = "PANCAKE_ERR_BUFFER_TOO_SMALL", .doc = "A caller-provided output buffer was too small for the value being written. The call still reports the required length in its out_len parameter, so a caller retries with a large enough buffer. Distinct from _INVALID_ARGUMENT (a malformed request)." },
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
        for (const_doc_entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) documented = true;
        }
        if (!documented) @compileError("return code missing a header comment in const_docs: " ++ name);
    }
}

// Compile-time coverage guard: every `pub const PANCAKE_*` integer in `c_abi`
// must appear in an emitted group, so adding a constant without listing it for
// the header fails to compile instead of silently dropping from pancake_ocapn.h.
comptime {
    @setEvalBranchQuota(40000);
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

// Peer-waist prototypes (`pancake_ocapn.h`) in emission order.
const peer_fn_names = [_][]const u8{
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
    "pancake_peer_recv_borrowed",
    "pancake_peer_feed_owned",
    "pancake_peer_recv_stream",
    "pancake_peer_step",
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
    "pancake_peer_expect_partner_key",
    "pancake_peer_peek_event",
    "pancake_peer_send_deliver",
    "pancake_peer_send_resolve",
    "pancake_peer_send_get",
    "pancake_peer_send_index",
    "pancake_peer_send_untag",
    "pancake_peer_send_abort",
    "pancake_peer_send_gc_export",
    "pancake_peer_send_gc_answer",
    "pancake_peer_send_withdraw_gift",
    "pancake_peer_partner_locator_raw",
    "pancake_build_handoff_give",
    "pancake_handoff_give_bytes_release",
    "pancake_encode_peer_locator",
    "pancake_peer_locator_bytes_release",
    "pancake_peer_send_deposit_gift",
    "pancake_peer_send_resolve_handoff_give",
    "pancake_peer_next_event",
    "pancake_any_event_release",
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
};
const emitted_fn_names = peer_fn_names;

// The reflection machinery is shared with the transport generators; this `Spec`
// is what makes `Emit` speak `libpancake_ocapn`: the reflected module, the
// prototype table, the curated `#define` comments, and the three
// function-pointer typedefs the base C spelling has no case for.
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
const line = header_emit.line;
const emitDoc = header_emit.emitDoc;
const section = header_emit.section;
const emitConst = E.emitConst;
const emitStruct = E.emitStruct;
const emitBareStruct = E.emitBareStruct;
const emitFn = E.emitFn;

// Coverage guard, both directions: every `pub fn pancake_*` in `c_abi` must be
// listed in `emitted_fns`, and every table entry must name a real function.
comptime {
    E.guardFns("c_abi", "pancake_");
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
        \\   plus the peer-driving and locator-URI families. Multi-session
        \\   CapTP product work uses pancake_host_* in pancake_driver.h. The
        \\   transports ship their own archives and headers —
        \\   pancake_net_transport_tcp.h, pancake_net_transport_inproc.h,
        \\   pancake_net_transport_iroh.h — each of which #includes this one for
        \\   the shared types (ADR-0059). */
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
        \\take the next application event with pancake_peer_next_event (it drives
        \\the engine to idle itself), and drain outbound frames with
        \\pancake_peer_take_outbound; sockets, threads, and scheduling stay in the
        \\host. examples/c/echo_peer.c is a complete in-memory conversation built
        \\from exactly those calls, and docs/consuming-from-c.md is the guided
        \\route from build to first program.
        \\
        \\There are two inbound models; pick one per loop and do not mix them. One
        \\dispatches synchronously as bytes arrive: pancake_peer_recv_borrowed takes
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
        \\is the one call that takes ownership from you: it takes the frame on
        \\every outcome except a NULL-pointer refusal, and on failure it releases
        \\the frame for you (see its own contract below).
        \\
        \\Threading: a PancakePeer is a single-owner state machine. Serialize every
        \\call on a given peer onto one thread or behind one lock. pancake_last_error
        \\is per-thread; read it on the thread that made the failing call.
        \\
        \\Out parameters: out structs are written only on PANCAKE_OK;
        \\zero-initialize or never release on failure.
    );

    try section(&b, gpa, "Return codes");
    inline for (error_consts) |name| {
        try emitConst(&b, gpa, name);
        // The retired codes carry no macro (a consumer must never compare
        // against a reused value), but the gap in the sequence is a statement,
        // not a mystery: -2 (a stale-handle check) and -12 (a wrong-kind typed
        // poll) were removed and their numbers are never reused.
        if (comptime std.mem.eql(u8, name, "PANCAKE_ERR_NULL_POINTER"))
            try line(&b, gpa, "/* -2 retired, never reused */", .{});
        if (comptime std.mem.eql(u8, name, "PANCAKE_ERR_FRAME_TOO_LARGE"))
            try line(&b, gpa, "/* -12 retired, never reused */", .{});
    }

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
    try emitBareStruct(&b, gpa, c.PancakeManagedFrame, "PancakeManagedFrame", &.{
        "Owned and self-releasing: release with `pancake_managed_frame_release`.",
        "",
        "",
        "Internal self-release hook; never call it directly. Free the frame with\n       `pancake_managed_frame_release`, which is idempotent and nulls this first.",
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
        \\alloc's, correct even for a size-tracking host allocator.
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
    try emitFn(&b, gpa, "pancake_peer_recv_borrowed", &.{ "peer", "frame" }, "Dispatch a borrowed frame synchronously; the caller retains ownership.");
    try emitFn(&b, gpa, "pancake_peer_feed_owned", &.{ "peer", "frame" }, "Transfer a managed frame into the inbound queue for `pancake_peer_step`.\nOwnership always transfers once peer, frame, and frame->bytes are non-NULL:\non failure the frame is released through its own callback and the caller's\nstruct is cleared, so a late pancake_managed_frame_release is a no-op. Only\nPANCAKE_ERR_NULL_POINTER leaves the caller owning the frame.");
    try emitFn(&b, gpa, "pancake_peer_recv_stream", &.{ "peer", "bytes", "len", "out_consumed" }, "Frame and dispatch one inbound frame from a byte-stream buffer, writing the\nbytes consumed into `out_consumed`. PANCAKE_ERR_WOULD_BLOCK (out_consumed 0)\nmeans the buffer holds only part of a frame — read more and retry; an empty\nbuffer (len == 0, bytes may be NULL) reports the same. The sans-I/O\nstream-input primitive: the caller owns the socket and buffer.");
    try emitFn(&b, gpa, "pancake_peer_step", &.{"peer"}, "Advance the peer: validate and apply queued inbound frames and encode\npending outbound work. No I/O happens here — drain\npancake_peer_take_outbound and pancake_peer_poll_event afterward.\nOr let pancake_peer_next_event drive and project in one call.");
    try emitFn(&b, gpa, "pancake_peer_take_outbound", &.{ "peer", "out_frame" }, "Take the next outbound frame as an owned managed frame, or\nPANCAKE_ERR_WOULD_BLOCK when the queue is empty. On PANCAKE_ERR_INTERNAL the\ndequeued frame could not be wrapped for C and was freed; it is not\nretrievable.");
    try emitFn(&b, gpa, "pancake_peer_poll_event", &.{ "peer", "out_event" }, "Take the next event (opaque frame in the negotiated codec), or\nPANCAKE_ERR_WOULD_BLOCK when none is queued.");
    try emitFn(&b, gpa, "pancake_peer_codec", &.{ "peer", "out_codec" }, "The codec the peer's session speaks, as a PANCAKE_CODEC_* value. Event and\noutbound frames are encoded in it, so a consumer that drains an event\nthrough the opaque pancake_peer_poll_event knows how to read the raw frame.");

    try section(&b, gpa, "Capability registration");
    try emitDoc(&b, gpa,
        \\The well-known bootstrap export position every OCapN peer answers `fetch`
        \\on. Use this name instead of re-deriving the magic 0.
    );
    try emitConst(&b, gpa, "PANCAKE_BOOTSTRAP_POSITION");
    try emitDoc(&b, gpa,
        \\The base of the reserved redeemed-handoff-token far-id range: a far id at
        \\or above this names a capability the host redeemed and routes to its
        \\exporter connection, never a wire import, so a token can never alias a
        \\partner's import. A host that keys per-import state (GC, caches) by far
        \\id uses this bound to tell the two apart. Emitted with the ULL suffix,
        \\the one constant too large for the plain-int convention above.
    );
    try line(&b, gpa, "#define PANCAKE_REDEEMED_TOKEN_BASE {d}ULL", .{c.PANCAKE_REDEEMED_TOKEN_BASE});
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
    try emitFn(&b, gpa, "pancake_peer_register_export", &.{ "peer", "export_position" }, "Register a local export position and GRANT it: deliveries to it are\nadmitted and surface as events immediately, without waiting for the\ncapability's first marshal. The deliberate make-this-addressable-now verb\nfor positions a partner learns out-of-band.");
    try emitFn(&b, gpa, "pancake_peer_next_export", &.{ "peer", "out_export_position" }, "Allocate the next free export position from the session's one export\nallocator and RESERVE it (unlike pancake_peer_next_answer, which only\nallocates), writing it into `out_export_position`. The partner can address\nthe reserved position only once the capability first marshals onto the\nwire, or after an explicit pancake_peer_register_export grant. A binding's\n`spawn` must take its position here: the same counter mints bootstrap and\nresolver exports, so a privately-counted position would eventually alias one.");
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
    try emitFn(&b, gpa, "pancake_peer_expect_partner_key", &.{ "peer", "key", "key_len" }, "Pin the partner's Ed25519 public key before their op:start-session is fed.\nA mismatch becomes PartnerKeyMismatch and aborts the session fail-closed\n(the dial-side identity pin, ADR-0075). `key` is borrowed and `key_len` must\nbe 32; anything else is refused with PANCAKE_ERR_INVALID_ARGUMENT.");

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
        \\
        \\The OCapN Struct has no PANCAKE_ARG_* kind and cannot cross this typed
        \\surface: sending one is refused with PANCAKE_ERR_UNSUPPORTED_VALUE, and an
        \\inbound deliver carrying a Struct lands in the PancakeAnyEvent `frame` arm
        \\as raw wire bytes (see pancake_peer_codec) rather than a projected argument.
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
        "", "aliases the enclosing PancakeAnyEvent's arena", "", "", "", "freed by pancake_any_event_release",
    });
    try b.appendSlice(gpa, "\n");
    try emitStruct(&b, gpa, c.PancakeHandoffGive, "PancakeHandoffGive", &.{
        "verbatim signed give; feed to pancake_peer_send_withdraw_gift",          "",
        "exporter ocapn:// URI, or NULL when the location is not a flat locator", "",
        "32-byte Ed25519 key the give is addressed to",                           "",
    });
    try b.appendSlice(gpa, "\n");
    try emitStruct(&b, gpa, c.PancakeResolve, "PancakeResolve", &.{
        "", "fulfill, break, or handoff", "", "", "", "set when resolution_kind is _HANDOFF", "freed by pancake_any_event_release",
    });
    try b.appendSlice(gpa, "\n");
    try emitStruct(&b, gpa, c.PancakeAnyEvent, "PancakeAnyEvent", &.{
        "the event's PANCAKE_EVENT_*",
        "which arm is live: PANCAKE_PROJECTION_*",
        "live when projection is _DELIVER",
        "live when projection is _RESOLVE",
        "live when projection is _FRAME: the originating wire bytes (see pancake_peer_codec)",
    });
    try b.appendSlice(gpa, "\n");
    try section(&b, gpa, "The event loop");
    try emitFn(&b, gpa, "pancake_peer_next_event", &.{ "peer", "out" }, "Drive the engine to idle, then take the next event, fully projected — the\none call a consumer's event loop needs. Driving first makes the loop's\nobvious shape the correct one: settling an answer can cascade (a resolve\ndrains a pipelined projection, whose own resolve fires a listener, which\nqueues a deliver), and each cascade step can mint fresh events and outbound\nframes; this call runs the engine to quiescence before it answers, so a\ncaller never re-derives a step-then-re-poll rule. Write the queued outbound\nframes (pancake_peer_take_outbound) when this reports no event, before\nparking on the next read. `kind` carries the event's PANCAKE_EVENT_* and\n`projection` names the live arm: a deliver projects into `deliver`, a\nresolve into `resolve` (including the PANCAKE_RESOLUTION_HANDOFF give), and\nevery other kind — or a deliver/resolve whose value the typed surface cannot\ncarry — lands in `frame` as the originating wire bytes in the negotiated\ncodec (pancake_peer_codec). Exactly one event is consumed per PANCAKE_OK.\nPANCAKE_ERR_WOULD_BLOCK when the engine is idle and no event is pending.\nRelease `out` with pancake_any_event_release exactly once.");
    try emitFn(&b, gpa, "pancake_any_event_release", &.{"event"}, "Release a polled PancakeAnyEvent: frees whichever arm `projection` names (the\ndeliver/resolve views or the owned frame) and zeroes the struct, so a repeat\nrelease — or releasing a zero-initialized struct — is a no-op.");
    try emitFn(&b, gpa, "pancake_peer_peek_event", &.{"peer"}, "The kind of the next event without consuming it: a positive PANCAKE_EVENT_*\nor PANCAKE_ERR_WOULD_BLOCK.");
    try emitFn(&b, gpa, "pancake_peer_send_deliver", &.{ "peer", "target", "args", "args_len", "has_answer", "answer" }, "Construct and queue an op:deliver. When `has_answer` is nonzero the call\nexpects a reply on `answer`, which must come from pancake_peer_next_answer\non this same peer (a privately-counted id eventually aliases a live answer).\nWhen `has_answer` is zero, `answer` is ignored.");
    try emitFn(&b, gpa, "pancake_peer_send_resolve", &.{ "peer", "answer", "resolution_kind", "fulfill", "break_message", "break_message_len" }, "Construct and queue an op:resolve settling `answer`.");
    try emitFn(&b, gpa, "pancake_peer_send_get", &.{ "peer", "receiver", "field", "field_len", "answer" }, "Queue an op:get projection (ADR-0050): export a fresh promise at `answer`\nthat resolves to the `field` member of whatever `receiver` resolves to.\n`receiver` is typically a _PROMISE (the answer position a prior send_deliver\nreturned), so the projection pipelines ahead of that answer settling; a _FAR\nreceiver projects an already-settled capability. The settlement arrives as a\nPANCAKE_EVENT_RESOLVE keyed on `answer`, which must come from\npancake_peer_next_answer on this peer. `field` is borrowed.");
    try emitFn(&b, gpa, "pancake_peer_send_index", &.{ "peer", "receiver", "index", "answer" }, "Queue an op:index projection (ADR-0050): export a fresh promise at `answer`\nthat resolves to element `index` of whatever `receiver` resolves to. Like\npancake_peer_send_get but for a List position. `answer` must come from\npancake_peer_next_answer on this peer.");
    try emitFn(&b, gpa, "pancake_peer_send_untag", &.{ "peer", "receiver", "tag", "tag_len", "answer" }, "Queue an op:untag projection (ADR-0052): export a fresh promise at `answer`\nthat resolves to the payload of whatever `receiver` resolves to, requiring a\nTagged record whose tag equals `tag` (breaks on a mismatched tag or\nwrong-shape value). `answer` must come from pancake_peer_next_answer on this\npeer; `tag` is borrowed.");
    try emitFn(&b, gpa, "pancake_peer_send_abort", &.{ "peer", "kind_name", "kind_name_len", "message", "message_len" }, "Queue an op:abort that tears the CapTP session down after pancake_peer_step\ncommits the frame to outbound. `kind_name` is an AbortKind wire label (e.g.\n\"GracefulShutdown\"); unknown labels are PANCAKE_ERR_INVALID_ARGUMENT.\n`message` is borrowed and copied onto the queued abort. After a successful\nstep the peer is no longer open (pancake_peer_session_is_open is false).");
    try emitFn(&b, gpa, "pancake_peer_send_gc_export", &.{ "peer", "positions", "deltas", "len" }, "Construct and queue an op:gc-export releasing wire-delta counts on imports\nthis peer holds: positions[i] is released by deltas[i], for `len` parallel\nentries (both borrowed; len == 0 is PANCAKE_ERR_INVALID_ARGUMENT).");
    try emitFn(&b, gpa, "pancake_peer_send_gc_answer", &.{ "peer", "answer" }, "Construct and queue an op:gc-answer releasing the answer position this peer\nno longer needs.");
    try emitFn(&b, gpa, "pancake_peer_send_withdraw_gift", &.{ "peer", "give", "give_len", "seed", "seed_len", "answer" }, "Recipient half of a three-party handoff (ADR-0009): build a signed\ndesc:handoff-receive embedding the verbatim `give` bytes and queue a\nwithdraw-gift op:deliver to the exporter's bootstrap (far object 0) under\n`answer`. The caller must already hold an open keyed session to the exporter\nnamed by the give's exporter-location, opened with the same 32-byte `seed`\nthe gift was deposited under (seed_len must be 32, the session must be open,\nelse PANCAKE_ERR_SESSION). The monotonic handoff-count the exporter requires\nto increase is minted internally by the peer's gift registry (0 for the first\nwithdrawal from a given exporter session, rising across reconnects when a\nshared registry is wired), so the caller never tracks it. The withdrawn\nreference arrives as a PANCAKE_EVENT_RESOLVE keyed on `answer`. `give` and\n`seed` are borrowed.");
    try emitFn(&b, gpa, "pancake_peer_partner_locator_raw", &.{ "peer", "out_ptr", "out_len" }, "Borrow the partner's verbatim location-record bytes from its op:start-session\ninto out_ptr/out_len (a NULL pointer and zero length when none were captured).\nA gifter embeds these as a give's exporter location so a peer comparing\nlocations matches byte-for-byte. The view aliases the session until release.");
    try emitFn(&b, gpa, "pancake_build_handoff_give", &.{ "seed", "seed_len", "recipient_key", "recipient_key_len", "exporter_locator_raw", "exporter_locator_raw_len", "exporter_session_key", "exporter_session_key_len", "gift_id", "gift_id_len", "out_give", "out_give_len" }, "Build the signed desc:handoff-give a gifter returns to a recipient, writing\nowned bytes into out_give/out_give_len (release with\npancake_handoff_give_bytes_release). `seed` is the gifter's 32-byte identity\nseed (the key it presents on the to-exporter session, which signs the give\nand must equal the deposit's provenance); seed_len must be 32. recipient_key\nis the recipient's session public key, exporter_locator_raw the exporter's\nverbatim location bytes, exporter_session_key the exporter's session public\nkey, gift_id the deposited gift's id. The gifter side and gifter-exporter\nsession name are derived from the keys. All inputs are borrowed.");
    try emitFn(&b, gpa, "pancake_handoff_give_bytes_release", &.{ "give", "give_len" }, "Release give bytes returned by pancake_build_handoff_give. NULL is a no-op.");
    try emitFn(&b, gpa, "pancake_encode_peer_locator", &.{ "transport", "transport_len", "designator", "designator_len", "direct_addresses", "direct_addresses_len", "out", "out_len" }, "Build the verbatim exporter location-record bytes a give names, writing owned\nbytes into out/out_len (release with pancake_peer_locator_bytes_release), the\nconstruct-it-yourself counterpart of pancake_peer_partner_locator_raw, for an\nexporter whose own session record carries no dial hint. transport/designator\nname the exporter; direct_addresses, when non-empty, adds the exporter's\ncomma-separated socket addresses as a direct-addresses hint, so a cross-process\nrecipient dials the exporter directly with no discovery service (an iroh\nexporter reachable only by address). A NULL or empty direct_addresses yields a\nhint-less location identical to the exporter's own session record, so a\ndiscovery-reachable or TCP exporter keeps using pancake_peer_partner_locator_raw\ninstead. The bytes are in the handoff codec (Syrup, as desc:handoff-give is);\nthe result feeds pancake_build_handoff_give as exporter_locator_raw. All inputs\nare borrowed.");
    try emitFn(&b, gpa, "pancake_peer_locator_bytes_release", &.{ "locator", "locator_len" }, "Release locator bytes returned by pancake_encode_peer_locator. NULL is a no-op.");
    try emitFn(&b, gpa, "pancake_peer_send_deposit_gift", &.{ "peer", "gift_id", "gift_id_len", "gifted_ref" }, "Deposit a gift with this (exporter) session: queue a deposit-gift op:deliver\nto the exporter's bootstrap object (far object 0) carrying the gift id and\nthe gifted reference. Fire-and-forget (no answer): the exporter records the\ngift and parks any withdraw-gift that arrives first until this deposit lands.\ngift_id is borrowed; gifted_ref is borrowed and cloned by the send.");
    try emitFn(&b, gpa, "pancake_peer_send_resolve_handoff_give", &.{ "peer", "answer", "give", "give_len" }, "Resolve `answer` (a question the recipient asked this gifter) with a signed\ndesc:handoff-give: queue an op:resolve whose fulfill carries `give` verbatim,\nso the encoder emits the exact bytes the gifter signed and the recipient\nredeems them transparently. `give` is borrowed for the call.");

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
    try emitFn(&b, gpa, "pancake_uri_format_peer", &.{ "transport", "transport_len", "designator", "designator_len", "hint_keys", "hint_key_lens", "hint_vals", "hint_val_lens", "hint_count", "out", "cap", "out_len" }, "Format a peer locator as an ocapn:// URI into `out`. Hints are parallel\nkey/value string arrays (hint_keys[i]/hint_key_lens[i] and the val pair) of\nhint_count entries; all inputs are borrowed. `out_len` always receives the\nfull URI length; a buffer too small is PANCAKE_ERR_BUFFER_TOO_SMALL (a NULL\nbuffer is PANCAKE_ERR_INVALID_ARGUMENT) with the length still reported, so\nsize with out_len then retry.");
    try emitFn(&b, gpa, "pancake_uri_format_sturdyref", &.{ "transport", "transport_len", "designator", "designator_len", "swissnum", "swissnum_len", "hint_keys", "hint_key_lens", "hint_vals", "hint_val_lens", "hint_count", "out", "cap", "out_len" }, "Format a sturdyref locator (peer plus swissnum) as an ocapn://.../s/<swiss>\nURI. Same hint-array and buffer contract as pancake_uri_format_peer;\n`swissnum` is borrowed.");
    try emitFn(&b, gpa, "pancake_locator_transport", &.{ "loc", "out_ptr", "out_len" }, "Borrow the locator's transport (\"tcp\", \"iroh\", \"inproc\", ...): the field a\ndispatcher reads to pick a netlayer. The view aliases the handle until\nrelease.");
    try emitFn(&b, gpa, "pancake_locator_designator", &.{ "loc", "out_ptr", "out_len" }, "Borrow the locator's designator — the transport-specific address (a TCP\nhost:port string, an iroh node id, an inproc designator).");
    try emitFn(&b, gpa, "pancake_locator_host_port", &.{ "loc", "out_host", "out_host_len", "out_port" }, "Split the locator's designator as host:port — the address grammar a socket\ntransport's designator carries. Last-colon split, bracketed IPv6 literals\nunwrapped ([::1]:9000 yields host ::1), decimal uint16 port; the one grammar\nthe native TCP netlayer dials through, so a consumer dialing with its own\nsockets validates the same way. PANCAKE_ERR_INVALID_ARGUMENT (see\npancake_last_error) when the designator does not carry the grammar. The host\nview aliases the handle until pancake_locator_release.");
    try emitFn(&b, gpa, "pancake_designator_host_port", &.{ "designator", "designator_len", "out_host", "out_host_len", "out_port" }, "Split a bare designator as host:port — same grammar as\npancake_locator_host_port, without minting a locator handle. A DIAL action\nalready carries the designator; redeem dials use this instead of\nformat→parse→host_port. PANCAKE_ERR_INVALID_ARGUMENT when the designator\ndoes not carry the grammar. The host view aliases designator for the call.");
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

    // Peer-waist tooth: every peer prototype must have landed in this header.
    try assertNamesEmitted(&b, "gen-header-ocapn", &peer_fn_names);
    return b.toOwnedSlice(gpa);
}

fn assertNamesEmitted(b: *Buf, comptime step: []const u8, comptime names: []const []const u8) !void {
    inline for (names) |name| {
        if (std.mem.indexOf(u8, b.items, " " ++ name ++ "(") == null) {
            std.debug.print(step ++ ": expected function `{s}` missing from generated header\n", .{name});
            return error.MissingEmittedFunction;
        }
    }
}
