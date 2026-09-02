//! Generates the Racket binding's FFI tables from each archive's annotated
//! symbol inventory.
//!
//! The split of truth: parameter and return *types* reflect from the real Zig
//! exports (`@typeInfo`, so a signature change regenerates a different file),
//! the inventory supplies order, the `racket_omit` rows, the `blocking` marks
//! (`#:blocking?`, so a parked FFI call does not freeze the place's green
//! threads), and the out-cell wrapper tier derives from `out_params` plus the
//! slot shape of each parameter: a one-pointer to a scalar or a pointer is a
//! fresh caller-owned cell the wrapper allocates, while a caller-provided
//! buffer stays an argument. A wrapper's remaining argument names come from
//! the generated C header. Each eager archive's output is a sibling module
//! the hand-authored `ffi-*.rkt` file re-provides; the iroh output exports
//! one table-building function the lazy hand loader calls with the opened
//! library and the config cstruct type, so the generated module stays below
//! the hand module that declares it. `zig build gen-binding-racket-ffi-check`
//! (part of `check`) holds the committed files against a fresh generation.

const std = @import("std");

const c = @import("c_abi");
const cd = @import("c_abi_host");
const cdr = @import("c_abi_driver");
const ci = @import("c_abi_net_transport_iroh");
const ct = @import("c_abi_net_transport_tcp");
const cin = @import("c_abi_net_transport_inproc");
const con = @import("c_abi_net_transport_onion");
const cw = @import("c_abi_net_transport_webrtc");
const cr = @import("c_abi_net_transport_relay");

const headerParamNames = @import("header_names.zig").headerParamNames;

pub const step_name = "gen-binding-racket-ffi";

const Output = @import("output").Output;

pub const outputs = [_]Output{
    .{ .path = "bindings/racket/private/ffi-ocapn-gen.rkt", .generate = generateOcapn },
    .{ .path = "bindings/racket/private/ffi-host-gen.rkt", .generate = generateHost },
    .{ .path = "bindings/racket/private/ffi-driver-gen.rkt", .generate = generateLoop },
    .{ .path = "bindings/racket/private/ffi-tcp-gen.rkt", .generate = generateTcp },
    .{ .path = "bindings/racket/private/ffi-inproc-gen.rkt", .generate = generateInproc },
    .{ .path = "bindings/racket/private/ffi-onion-gen.rkt", .generate = generateOnion },
    .{ .path = "bindings/racket/private/ffi-iroh-gen.rkt", .generate = generateIroh },
    .{ .path = "bindings/racket/private/ffi-webrtc-gen.rkt", .generate = generateWebrtc },
    .{ .path = "bindings/racket/private/ffi-relay-gen.rkt", .generate = generateRelay },
};

/// `module.GlowcapManagedFrame` → `GlowcapManagedFrame`.
const baseName = @import("reflect").baseName;

const render = @import("racket_ffi_render.zig");
fn generateOcapn(gpa: std.mem.Allocator) ![]u8 {
    return render.renderEager(gpa, .{
        .M = c,
        .archive = "glowcap_ocapn",
        .lib_var = "ocapn-lib",
        .definer = "define-glowcap",
        .fingerprint_stem = "ocapn",
        .fingerprint_constant = "OCAPN-ARCHIVE-FINGERPRINT",
        .check_fingerprint_at_load = false,
        .note =
        \\;; The raw `ffi/unsafe` table of libglowcap_ocapn, the core archive. The
        \\;; hand-written sibling (`ffi-ocapn.rkt`) owns the prose and re-provides
        \\;; this module together with the shared cstruct vocabulary.
        \\
        ,
        .header_path = "include/glowcap_ocapn.h",
    });
}

fn generateHost(gpa: std.mem.Allocator) ![]u8 {
    return render.renderEager(gpa, .{
        .M = cd,
        .archive = "glowcap_host",
        .lib_var = "host-lib",
        .definer = "define-host",
        .fingerprint_stem = "host",
        .fingerprint_constant = "HOST-ARCHIVE-FINGERPRINT",
        .check_fingerprint_at_load = false,
        .note =
        \\;; The raw `ffi/unsafe` table of the `glowcap_host_*` byte-fed host
        \\;; family, loaded from its symbol-disjoint libglowcap_host archive.
        \\;; The hand-written sibling (`ffi-host.rkt`) owns the prose and
        \\;; the bespoke pending-dial wrapper over the starred raw, and re-provides
        \\;; this module. The behavior/pump callback types and the plan/dial cstructs
        \\;; live in `ffi-shared.rkt`, the binding's types leaf.
        \\
        ,
        .hand_wrapped = &.{"glowcap_host_pending_dial"},
        .header_path = "include/glowcap_host.h",
        .specials = &.{
            .{ .T = cd.GlowcapHostBehavior, .spelling = "_GlowcapHostBehavior" },
            .{ .T = cd.GlowcapHostCtxFree, .spelling = "_pointer" },
            // The binding constructs and strongly retains one callback object
            // with `function-ptr`; accepting `_fpointer` here prevents every
            // installation call from minting a short-lived callback thunk.
            .{ .T = cd.GlowcapTraceCallback, .spelling = "_fpointer" },
        },
    });
}

fn generateLoop(gpa: std.mem.Allocator) ![]u8 {
    return render.renderEager(gpa, .{
        .M = cdr,
        .archive = "glowcap_driver",
        .lib_var = "loop-lib",
        .definer = "define-driver-loop",
        .fingerprint_stem = "driver",
        .fingerprint_constant = "DRIVER-ARCHIVE-FINGERPRINT",
        .check_fingerprint_at_load = false,
        .note =
        \\;; The raw `ffi/unsafe` table of the `glowcap_driver_*` loop family
        \\;; (ADR-0112), exported by symbol-disjoint libglowcap_driver. The
        \\;; hand-written sibling (`ffi-driver.rkt`) owns the prose
        \\;; and re-provides this module. The event and provider cstructs live
        \\;; in `ffi-shared.rkt`, the binding's types leaf.
        \\
        ,
        .header_path = "include/glowcap_driver.h",
    });
}

fn generateTcp(gpa: std.mem.Allocator) ![]u8 {
    return render.renderEager(gpa, .{
        .M = ct,
        .archive = "glowcap_net_transport_tcp",
        .lib_var = "tcp-lib",
        .definer = "define-glowcap-tcp",
        .extra_require = "ffi-tcp-types.rkt",
        .fingerprint_stem = "tcp",
        .fingerprint_constant = "TCP-ARCHIVE-FINGERPRINT",
        // Racket reads this synchronous call's thread-local diagnostic. Keep
        // the optional caller-buffer plumbing below the ergonomic wrappers.
        .hand_wrapped = &.{
            "glowcap_tcp_connect",
            "glowcap_tcp_accept",
            "glowcap_tcp_conn_read_frame",
            "glowcap_tcp_conn_write_frame",
            "glowcap_tcp_conn_release",
        },
        .note =
        \\;; The raw `ffi/unsafe` table of libglowcap_net_transport_tcp. The
        \\;; hand-written sibling (`ffi-tcp.rkt`) owns the prose and re-provides this
        \\;; module. The blocking rows (`#:blocking?`) park the calling thread on the
        \\;; socket; the mark keeps the runtime GC-cooperative during the park.
        \\
        ,
    });
}

fn generateInproc(gpa: std.mem.Allocator) ![]u8 {
    return render.renderEager(gpa, .{
        .M = cin,
        .archive = "glowcap_net_transport_inproc",
        .lib_var = "inproc-lib",
        .definer = "define-glowcap-inproc",
        .fingerprint_stem = "inproc",
        .fingerprint_constant = "INPROC-ARCHIVE-FINGERPRINT",
        // Racket consumes the calling-thread last-error slot; the optional
        // diagnostic outputs are worker-dispatch plumbing in other runtimes.
        .hand_wrapped = &.{
            "glowcap_inproc_connect",
            "glowcap_inproc_accept",
            "glowcap_inproc_conn_read_frame",
            "glowcap_inproc_conn_write_frame",
            "glowcap_inproc_listener_release",
        },
        .note =
        \\;; The raw `ffi/unsafe` table of libglowcap_net_transport_inproc. The
        \\;; hand-written sibling (`ffi-inproc.rkt`) owns the prose and re-provides
        \\;; this module. The blocking rows (`#:blocking?`) park the calling thread
        \\;; on the in-process pipes; the mark keeps the runtime GC-cooperative
        \\;; during the park.
        \\
        ,
    });
}

fn generateOnion(gpa: std.mem.Allocator) ![]u8 {
    return render.renderEager(gpa, .{
        .M = con,
        .archive = "glowcap_net_transport_onion",
        .lib_var = "onion-lib",
        .definer = "define-glowcap-onion",
        .fingerprint_stem = "onion",
        .fingerprint_constant = "ONION-ARCHIVE-FINGERPRINT",
        .hand_wrapped = &.{
            "glowcap_onion_netlayer_release",
            "glowcap_onion_connect",
            "glowcap_onion_listen",
            "glowcap_onion_listener_wait",
            "glowcap_onion_accept",
            "glowcap_onion_conn_read_frame",
            "glowcap_onion_conn_write_frame",
            "glowcap_onion_conn_release",
            "glowcap_onion_listener_release",
        },
        // `glowcap_onion_listen` writes five out-parameters, so its wrapper needs
        // the header's argument names to spell them.
        .header_path = "include/glowcap_net_transport_onion.h",
        .note =
        \\;; The raw `ffi/unsafe` table of libglowcap_net_transport_onion. The
        \\;; hand-written sibling (`ffi-onion.rkt`) owns the prose and re-provides
        \\;; this module. The blocking rows (`#:blocking?`) park the calling thread
        \\;; on a Tor circuit, which costs seconds rather than milliseconds; the mark
        \\;; keeps the runtime GC-cooperative during that park. The readiness rows
        \\;; carry no mark, because they return at once: park on the descriptor they
        \\;; hand back and the blocking rows are only entered when they will return.
        \\
        ,
    });
}

fn generateIroh(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\#lang racket/base
        \\;; GENERATED by `zig build gen-binding-racket-ffi` (the annotated symbol
        \\;; inventory in the archive's symbols.zig and each export's reflected
        \\;; signature) -- do not edit. `zig build gen-binding-racket-ffi-check`
        \\;; (part of `check`) fails when this is stale.
        \\;;
        \\;; The keyed table of libglowcap_net_transport_iroh. The archive is
        \\;; optional and loads lazily, so this module exports one table-building
        \\;; function the hand-written sibling (`ffi-iroh.rkt`) calls with the opened
        \\;; library and the config cstruct pointer type it declares — the generated
        \\;; module stays below the hand module, so no require cycle forms.
        \\;; Every row returns immediately; outbound dial completion arrives through
        \\;; the same request-correlated readiness stream as connection I/O.
        \\(require ffi/unsafe
        \\         "ffi-shared.rkt")
        \\(provide iroh-ffi-table)
        \\
        \\(define (iroh-ffi-table L _GlowcapIrohConfig-pointer)
        \\  (hasheq
    );
    inline for (ci.symbols.symbols) |row| {
        if (row.racket_omit == null) {
            const key = comptime irohKey(row.name);
            const sig = comptime render.funSig(ci, row, &.{});
            const slots = comptime render.slotIndexes(ci, row);
            if (comptime std.mem.eql(u8, row.name, "glowcap_iroh_netlayer_new")) {
                // Racket reads the calling thread's TLS diagnostic. Hide the
                // optional worker-dispatch outputs while retaining the usual
                // one-value constructor wrapper.
                try out.print(gpa,
                    \\
                    \\   '{s}
                    \\   (let ([raw (get-ffi-obj 'glowcap_iroh_netlayer_new L {s})])
                    \\     (lambda (seed seed-len config)
                    \\       (call/out _pointer #f
                    \\         (lambda (out)
                    \\           (call/without-diagnostic raw seed seed-len config out)))))
                , .{ key, sig });
            } else if (comptime std.mem.eql(u8, row.name, "glowcap_iroh_netlayer_release")) {
                try out.print(gpa,
                    \\
                    \\   '{s}
                    \\   (let ([raw (get-ffi-obj 'glowcap_iroh_netlayer_release L {s})])
                    \\     (lambda (netlayer)
                    \\       (call/without-diagnostic raw netlayer)))
                , .{ key, sig });
            } else if (slots.len == 0) {
                try out.print(gpa, "\n   '{s}\n   (get-ffi-obj '{s} L {s})", .{ key, row.name, sig });
            } else {
                // Every out-bearing iroh row has exactly one trailing cell.
                comptime std.debug.assert(slots.len == 1);
                const info = @typeInfo(@TypeOf(@field(ci, row.name))).@"fn";
                comptime std.debug.assert(slots[0] == info.param_types.len - 1);
                const cell = comptime render.slotCell(info.param_types[slots[0]].?).?;
                try out.print(gpa, "\n   '{s}\n   (wrap-out1 (get-ffi-obj '{s} L {s})\n              {s} {s})", .{ key, row.name, sig, cell.ctype, cell.init });
            }
        }
    }
    try out.appendSlice(gpa, "))\n");
    return out.toOwnedSlice(gpa);
}

/// `glowcap_iroh_netlayer_drain_ready` → `netlayer-drain-ready`.
fn irohKey(comptime name: []const u8) []const u8 {
    const stripped = name["glowcap_iroh_".len..];
    comptime var s: []const u8 = "";
    inline for (stripped) |ch| {
        s = s ++ &[_]u8{if (ch == '_') '-' else ch};
    }
    return s;
}

fn generateWebrtc(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\#lang racket/base
        \\;; GENERATED by `zig build gen-binding-racket-ffi` (the annotated symbol
        \\;; inventory in the archive's symbols.zig and each export's reflected
        \\;; signature) -- do not edit. `zig build gen-binding-racket-ffi-check`
        \\;; (part of `check`) fails when this is stale.
        \\;;
        \\;; The keyed table of libglowcap_net_transport_webrtc. The archive is
        \\;; optional and loads lazily, so this module exports one table-building
        \\;; function the hand-written sibling (`ffi-webrtc.rkt`) calls with the
        \\;; opened library and the config cstruct pointer type it declares -- the
        \\;; generated module stays below the hand module, so no require cycle
        \\;; forms. Every row returns immediately; the endpoint fd owns wakeups.
        \\(require ffi/unsafe
        \\         "ffi-shared.rkt")
        \\(provide webrtc-ffi-table)
        \\
        \\(define (webrtc-ffi-table L _GlowcapWebrtcConfig-pointer)
        \\  (hasheq
    );
    inline for (cw.symbols.symbols) |row| {
        if (row.racket_omit == null) {
            const key = comptime webrtcKey(row.name);
            const sig = comptime render.funSig(cw, row, &.{});
            const slots = comptime render.slotIndexes(cw, row);
            if (slots.len == 0) {
                try out.print(gpa, "\n   '{s}\n   (get-ffi-obj '{s} L {s})", .{ key, row.name, sig });
            } else {
                // Every out-bearing webrtc row has exactly one trailing cell.
                comptime std.debug.assert(slots.len == 1);
                const info = @typeInfo(@TypeOf(@field(cw, row.name))).@"fn";
                comptime std.debug.assert(slots[0] == info.param_types.len - 1);
                const cell = comptime render.slotCell(info.param_types[slots[0]].?).?;
                try out.print(gpa, "\n   '{s}\n   (wrap-out1 (get-ffi-obj '{s} L {s})\n              {s} {s})", .{ key, row.name, sig, cell.ctype, cell.init });
            }
        }
    }
    try out.appendSlice(gpa, "))\n");
    return out.toOwnedSlice(gpa);
}

fn webrtcKey(comptime name: []const u8) []const u8 {
    const stripped = name["glowcap_webrtc_".len..];
    comptime var s: []const u8 = "";
    inline for (stripped) |ch| {
        s = s ++ &[_]u8{if (ch == '_') '-' else ch};
    }
    return s;
}

fn generateRelay(gpa: std.mem.Allocator) ![]u8 {
    return render.renderEager(gpa, .{
        .M = cr,
        .archive = "glowcap_net_transport_relay",
        .lib_var = "relay-lib",
        .definer = "define-glowcap-relay",
        .fingerprint_stem = "relay",
        .fingerprint_constant = "RELAY-ARCHIVE-FINGERPRINT",
        .hand_wrapped = &.{"glowcap_relay_runtime_release"},
        .note =
        \\;; The raw `ffi/unsafe` table of libglowcap_net_transport_relay. The
        \\;; hand-written sibling (`ffi-relay.rkt`) owns the config mirror and
        \\;; re-provides this module. One package owns both keyed-relay and
        \\;; noise-relay; profile policy remains in the native driver.
        \\
        ,
        .header_path = "include/glowcap_net_transport_relay.h",
    });
}
