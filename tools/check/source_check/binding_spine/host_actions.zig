//! The host-action drains: every binding handles every action the header
//! declares.

const std = @import("std");
const text_match = @import("../text_match.zig");
const violation_log = @import("../violation_log.zig");

const appendViolation = violation_log.appendViolation;
const expectFileContains = text_match.expectFileContains;
const fileContains = text_match.fileContains;
const containsAsSymbol = text_match.containsAsSymbol;
const extractBraceBlock = text_match.extractBraceBlock;

/// Every `GLOWCAP_HOST_ACTION_*` kind must appear in each binding's host-action
/// drain. The Zig embedders share one skeleton (`driver_core.drainActions`),
/// the four language bindings each hand-roll the executor arm set in a named
/// `action` module (decode/types are generated). Grep-level: the header's
/// action name must appear as `HOST_ACTION_<NAME>` (or `HOST-ACTION-<NAME>` in
/// Racket) in the action module. A new kind without a binding arm fails
/// `zig build source-check`.
///
/// Racket's drain `case` arms use lowercase kebab symbols (`[(close)`, …),
/// those must appear in `action.rkt` (otherwise a decode-only module still
/// passes while the drain silently drops the new kind).
pub fn checkBindingHostActionDrains(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const header_path = "include/glowcap_host.h";
    const header = root.readFileAlloc(io, header_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for host-action drain check with {s}", .{ header_path, @errorName(err) });
        return;
    };
    defer gpa.free(header);

    var action_names: std.ArrayList([]const u8) = .empty;
    defer action_names.deinit(gpa);
    const needle = "#define GLOWCAP_HOST_ACTION_";
    var rest = header;
    while (std.mem.indexOf(u8, rest, needle)) |start| {
        const after = rest[start + needle.len ..];
        const name_end = std.mem.indexOfAny(u8, after, " \t\r\n") orelse after.len;
        const name = after[0..name_end];
        if (name.len != 0) try action_names.append(gpa, name);
        rest = after[name_end..];
    }
    if (action_names.items.len == 0) {
        try appendViolation(gpa, violations, "{s}: no GLOWCAP_HOST_ACTION_* constants found for drain check", .{header_path});
        return;
    }

    const drains = [_]struct {
        paths: []const []const u8,
        sep: u8,
        /// When set, each action must also appear as `[(kebab-name)` in this file
        /// (Racket's symbol-form drain switch).
        racket_symbol_path: ?[]const u8 = null,
        /// When set, each action must appear as `HostAction::<Pascal>` (Rust) or
        /// `case <Pascal>` (Python) in this file. Gen-only kind tokens do not
        /// satisfy the executor gate.
        variant_path: ?[]const u8 = null,
        /// Prefix before the PascalCase variant (`HostAction::` or `case `).
        variant_prefix: []const u8 = "",
    }{
        // Kind inventory may live in the generated dispatch file; executor I/O
        // stays in action.* (route-exact dial, flush, …). Union of paths must
        // cover every GLOWCAP_HOST_ACTION_*.
        .{
            .paths = &.{
                "bindings/ts/runtime/action.ts",
                "bindings/ts/runtime/internal/host_action.ts",
            },
            .sep = '_',
        },
        .{
            .paths = &.{
                "bindings/python/glowcap/_action.py",
                "bindings/python/glowcap/_host_action_gen.py",
            },
            .sep = '_',
            .variant_path = "bindings/python/glowcap/_host_action_gen.py",
            .variant_prefix = "case ",
        },
        .{
            .paths = &.{
                "bindings/rust/src/action.rs",
                "bindings/rust/src/host_action_gen.rs",
            },
            .sep = '_',
            .variant_path = "bindings/rust/src/host_action_gen.rs",
            .variant_prefix = "HostAction::",
        },
        .{
            .paths = &.{
                "bindings/racket/private/action.rkt",
                "bindings/racket/private/host-action-gen.rkt",
            },
            .sep = '-',
            .racket_symbol_path = "bindings/racket/private/action.rkt",
        },
    };

    var token_buf: [128]u8 = undefined;
    var symbol_buf: [128]u8 = undefined;
    var variant_buf: [128]u8 = undefined;
    for (drains) |drain| {
        var contents_list: std.ArrayList([]u8) = .empty;
        defer {
            for (contents_list.items) |buf| gpa.free(buf);
            contents_list.deinit(gpa);
        }
        for (drain.paths) |path| {
            const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for host-action drain check with {s}", .{ path, @errorName(err) });
                continue;
            };
            try contents_list.append(gpa, contents);
        }
        if (contents_list.items.len == 0) continue;

        const label = drain.paths[0];
        const sym_contents: ?[]u8 = if (drain.racket_symbol_path) |sym_path| blk: {
            break :blk root.readFileAlloc(io, sym_path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for host-action symbol-arm check with {s}", .{ sym_path, @errorName(err) });
                break :blk null;
            };
        } else null;
        defer if (sym_contents) |buf| gpa.free(buf);

        const variant_contents: ?[]u8 = if (drain.variant_path) |vpath| blk: {
            break :blk root.readFileAlloc(io, vpath, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for host-action variant check with {s}", .{ vpath, @errorName(err) });
                break :blk null;
            };
        } else null;
        defer if (variant_contents) |buf| gpa.free(buf);

        for (action_names.items) |name| {
            if (drain.variant_path) |vpath| {
                const contents = variant_contents orelse continue;
                // `HostAction::NeedGiftId` / `case NeedGiftId` from NEED_GIFT_ID.
                const prefix = drain.variant_prefix;
                if (prefix.len + name.len > variant_buf.len) {
                    try appendViolation(gpa, violations, "{s}: host-action name `{s}` too long for variant buffer", .{ header_path, name });
                    continue;
                }
                @memcpy(variant_buf[0..prefix.len], prefix);
                var n: usize = prefix.len;
                var cap = true;
                for (name) |c| {
                    if (c == '_') {
                        cap = true;
                        continue;
                    }
                    variant_buf[n] = if (cap) std.ascii.toUpper(c) else std.ascii.toLower(c);
                    n += 1;
                    cap = false;
                }
                const variant = variant_buf[0..n];
                if (std.mem.indexOf(u8, contents, variant) == null) {
                    try appendViolation(gpa, violations, "{s}: host-action drain missing `{s}` arm (from GLOWCAP_HOST_ACTION_{s})", .{ vpath, variant, name });
                }
                continue;
            }

            // `HOST{sep}ACTION{sep}` + name with `_` rewritten to `sep`.
            const prefix = "HOST";
            const mid = "ACTION";
            var n: usize = 0;
            const need = prefix.len + 1 + mid.len + 1 + name.len;
            if (need > token_buf.len) {
                try appendViolation(gpa, violations, "{s}: host-action name `{s}` too long for drain-token buffer", .{ header_path, name });
                continue;
            }
            @memcpy(token_buf[n..][0..prefix.len], prefix);
            n += prefix.len;
            token_buf[n] = drain.sep;
            n += 1;
            @memcpy(token_buf[n..][0..mid.len], mid);
            n += mid.len;
            token_buf[n] = drain.sep;
            n += 1;
            for (name) |c| {
                token_buf[n] = if (c == '_') drain.sep else c;
                n += 1;
            }
            const token = token_buf[0..n];
            var found = false;
            for (contents_list.items) |contents| {
                if (std.mem.indexOf(u8, contents, token) != null) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try appendViolation(gpa, violations, "{s}: host-action drain missing `{s}` (from GLOWCAP_HOST_ACTION_{s})", .{ label, token, name });
            }

            if (drain.racket_symbol_path) |sym_path| {
                const contents = sym_contents orelse continue;
                // `'kebab-name`: hash key in `host-dispatch-action!` handlers.
                if (1 + name.len > symbol_buf.len) {
                    try appendViolation(gpa, violations, "{s}: host-action name `{s}` too long for racket-symbol buffer", .{ header_path, name });
                    continue;
                }
                symbol_buf[0] = '\'';
                for (name, 0..) |c, i| {
                    symbol_buf[1 + i] = if (c == '_') '-' else std.ascii.toLower(c);
                }
                const symbol = symbol_buf[0 .. 1 + name.len];
                if (std.mem.indexOf(u8, contents, symbol) == null) {
                    try appendViolation(gpa, violations, "{s}: host-action drain missing `{s}` handler (from GLOWCAP_HOST_ACTION_{s})", .{ sym_path, symbol, name });
                }
            }
        }
    }
}
