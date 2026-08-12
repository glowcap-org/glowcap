//! Generates the archive-neutral borrowed locator layout.

const std = @import("std");
const cp = @import("c_abi_shared");
const header_emit = @import("header_emit.zig");

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/pancake_locator.h", .generate = generate },
};
pub const step_name = "gen-header-locator";

const Spec = struct {
    pub const c = cp;
    pub const emitted_fns: []const []const u8 = &.{};
    pub const const_docs = [_]struct { name: []const u8, doc: []const u8 }{
        .{ .name = "PANCAKE_HINT_STRING", .doc = "PancakeLocatorHintView.kind: UTF-8 string bytes." },
        .{ .name = "PANCAKE_HINT_BYTES", .doc = "PancakeLocatorHintView.kind: opaque bytes." },
        .{ .name = "PANCAKE_HINT_BOOLEAN", .doc = "PancakeLocatorHintView.kind: boolean_value." },
        .{ .name = "PANCAKE_HINT_INTEGER", .doc = "PancakeLocatorHintView.kind: integer_value." },
        .{ .name = "PANCAKE_HINTS_MAP", .doc = "PancakeLocatorView.hint_wire_form: map spelling." },
        .{ .name = "PANCAKE_HINTS_BOOLEAN_FALSE", .doc = "PancakeLocatorView.hint_wire_form: boolean-false spelling." },
        .{ .name = "PANCAKE_LOCATOR_VIEW_ABI_VERSION", .doc = "PancakeLocatorView ABI version." },
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
        \\#ifndef PANCAKE_LOCATOR_H
        \\#define PANCAKE_LOCATOR_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\
    );
    inline for (.{
        "PANCAKE_HINT_STRING",
        "PANCAKE_HINT_BYTES",
        "PANCAKE_HINT_BOOLEAN",
        "PANCAKE_HINT_INTEGER",
        "PANCAKE_HINTS_MAP",
        "PANCAKE_HINTS_BOOLEAN_FALSE",
        "PANCAKE_LOCATOR_VIEW_ABI_VERSION",
    }) |name| try E.emitConst(&b, gpa, name);
    try b.appendSlice(gpa, "\n");
    try E.emitStruct(&b, gpa, cp.PancakeLocatorHintView, "PancakeLocatorHintView", &.{
        "Borrowed hint name.", "", "PANCAKE_HINT_*.", "Borrowed STRING/BYTES value.", "", "BOOLEAN value.", "INTEGER value.",
    });
    try E.emitStruct(&b, gpa, cp.PancakeLocatorView, "PancakeLocatorView", &.{
        "PANCAKE_LOCATOR_VIEW_ABI_VERSION.", "sizeof(PancakeLocatorView).", "Borrowed transport symbol.", "",
        "Borrowed designator.",              "",                            "Borrowed hint array.",       "",
        "PANCAKE_HINTS_*.",
    });
    try b.appendSlice(gpa,
        \\
        \\/* Consume one callback-scoped complete locator view. Copy anything retained. */
        \\typedef int32_t (*PancakeLocatorSinkFn)(void *sink_ctx, const PancakeLocatorView *locator);
    );
    try b.appendSlice(gpa,
        \\
        \\#endif /* PANCAKE_LOCATOR_H */
        \\
    );
    return b.toOwnedSlice(gpa);
}
