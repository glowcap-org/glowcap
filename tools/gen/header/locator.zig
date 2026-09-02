//! Generates the archive-neutral borrowed locator layout.

const std = @import("std");
const cp = @import("c_abi_shared");
const header_emit = @import("header_emit.zig");

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/glowcap_locator.h", .generate = generate },
};
pub const step_name = "gen-header-locator";

const Spec = struct {
    pub const c = cp;
    pub const emitted_fns: []const []const u8 = &.{};
    pub const const_docs = [_]struct { name: []const u8, doc: []const u8 }{
        .{ .name = "GLOWCAP_HINT_STRING", .doc = "GlowcapLocatorHintView.kind: UTF-8 string bytes." },
        .{ .name = "GLOWCAP_HINT_BYTES", .doc = "GlowcapLocatorHintView.kind: opaque bytes." },
        .{ .name = "GLOWCAP_HINT_BOOLEAN", .doc = "GlowcapLocatorHintView.kind: boolean_value." },
        .{ .name = "GLOWCAP_HINT_INTEGER", .doc = "GlowcapLocatorHintView.kind: integer_value." },
        .{ .name = "GLOWCAP_HINTS_MAP", .doc = "GlowcapLocatorView.hint_wire_form: map spelling." },
        .{ .name = "GLOWCAP_HINTS_BOOLEAN_FALSE", .doc = "GlowcapLocatorView.hint_wire_form: boolean-false spelling." },
        .{ .name = "GLOWCAP_LOCATOR_VIEW_ABI_VERSION", .doc = "GlowcapLocatorView ABI version." },
    };
};

const E = header_emit.Emit(Spec);

fn generate(gpa: std.mem.Allocator) ![]u8 {
    var b: header_emit.Buf = .empty;
    errdefer b.deinit(gpa);
    try b.appendSlice(gpa,
        \\/* Generated from src/c_abi/shared/locator.zig.
        \\   Do not edit by hand: run `zig build gen-header-locator`.
        \\   This header defines the borrowed locator layout shared by OCapN,
        \\   the driver, and independently linked transport providers. */
        \\#ifndef GLOWCAP_LOCATOR_H
        \\#define GLOWCAP_LOCATOR_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\
    );
    inline for (.{
        "GLOWCAP_HINT_STRING",
        "GLOWCAP_HINT_BYTES",
        "GLOWCAP_HINT_BOOLEAN",
        "GLOWCAP_HINT_INTEGER",
        "GLOWCAP_HINTS_MAP",
        "GLOWCAP_HINTS_BOOLEAN_FALSE",
        "GLOWCAP_LOCATOR_VIEW_ABI_VERSION",
    }) |name| try E.emitConst(&b, gpa, name);
    try b.appendSlice(gpa, "\n");
    try E.emitStruct(&b, gpa, cp.GlowcapLocatorHintView, "GlowcapLocatorHintView", &.{
        "Borrowed hint name.", "", "GLOWCAP_HINT_*.", "Borrowed STRING/BYTES value.", "", "BOOLEAN value.", "INTEGER value.",
    });
    try E.emitStruct(&b, gpa, cp.GlowcapLocatorView, "GlowcapLocatorView", &.{
        "GLOWCAP_LOCATOR_VIEW_ABI_VERSION.", "sizeof(GlowcapLocatorView).", "Borrowed transport symbol.", "",
        "Borrowed designator.",              "",                            "Borrowed hint array.",       "",
        "GLOWCAP_HINTS_*.",
    });
    try b.appendSlice(gpa,
        \\
        \\/* Consume one callback-scoped complete locator view. Copy anything retained. */
        \\typedef int32_t (*GlowcapLocatorSinkFn)(void *sink_ctx, const GlowcapLocatorView *locator);
    );
    try b.appendSlice(gpa,
        \\
        \\#endif /* GLOWCAP_LOCATOR_H */
        \\
    );
    return b.toOwnedSlice(gpa);
}
