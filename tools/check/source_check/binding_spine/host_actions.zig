//! The host-action spine: every binding drains every action arm, through the
//! one shared drain shape.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const fileContains = util.fileContains;
const containsAsSymbol = util.containsAsSymbol;
const extractBraceBlock = util.extractBraceBlock;

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

/// Binding spine Pass 2: each binding keeps a named `action` module for
/// decode+execute, imports the generated HostAction decode, and does not
/// hand-roll a kind switch in the Host file. Grep-level, catches silent
/// deletes and decode drift back into host.*.
pub fn checkBindingHostActionSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const action_mods = [_]struct {
        path: []const u8,
        decode_import: []const u8,
        /// Executor markers that must appear in the action module (I/O arms).
        markers: []const []const u8,
    }{
        .{
            .path = "bindings/ts/runtime/action.ts",
            .decode_import = "decodeHostAction",
            .markers = &.{
                "dispatchHostAction",
                "runDialTicket",
                "requestFlush",
                "glowcap_host_provide_gift_id",
                "settleVow",
                "closeAfterFlush",
            },
        },
        .{
            .path = "bindings/python/glowcap/_action.py",
            .decode_import = "decode",
            .markers = &.{
                "dispatch",
                "run_dial_ticket",
                "request_flush",
                "glowcap_host_provide_gift_id",
                "settle_vow",
                "close_after_flush",
            },
        },
        .{
            .path = "bindings/rust/src/action.rs",
            .decode_import = "host_action_gen",
            .markers = &.{
                "host_action_gen::dispatch",
                "run_dial_ticket",
                "writer::request_flush",
                "glowcap_host_provide_gift_id",
                "settle_vow",
                "close_transport",
            },
        },
        .{
            .path = "bindings/racket/private/action.rkt",
            .decode_import = "host-decode-action!",
            .markers = &.{
                "host-dispatch-action!",
                "run-dial!",
                "outbound-request!",
                "outbound-close-after-flush!",
                "host-provide-gift-id!",
                "settle-vow!",
                "session-close!",
            },
        },
    };
    // Generated dispatch inventory must stay live in each language's gen file.
    try expectFileContains(io, gpa, root, violations, "bindings/ts/runtime/internal/host_action.ts", &.{
        "dispatchHostAction",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/python/glowcap/_host_action_gen.py", &.{
        "async def dispatch",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/rust/src/host_action_gen.rs", &.{
        "pub async fn dispatch",
        "trait HostActionHandlers",
    });
    // Generated inventory must stay live, allow(dead_code) on dispatch is a half-land.
    if (try fileContains(io, gpa, root, "bindings/rust/src/host_action_gen.rs", "#[allow(dead_code)]")) {
        try appendViolation(gpa, violations, "bindings/rust/src/host_action_gen.rs: #[allow(dead_code)] must stay deleted — action.rs must call dispatch", .{});
    }
    try expectFileContains(io, gpa, root, violations, "bindings/racket/private/host-action-gen.rkt", &.{
        "host-dispatch-action!",
    });
    // Ticket-only DIAL: each binding clones the complete pending locator before
    // reporting the ticket (no URI re-parse or hint projection).
    try expectFileContains(io, gpa, root, violations, "bindings/ts/runtime/dial.ts", &.{
        "glowcap_host_pending_dial",
        "runDialTicket",
        "OwnedLocator.cloneView",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/python/glowcap/_dial.py", &.{
        "glowcap_host_pending_dial",
        "run_dial_ticket",
        "_OwnedLocator.clone_view",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/rust/src/dial.rs", &.{
        "glowcap_host_pending_dial",
        "run_dial_ticket",
        "OwnedLocator::clone_view",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/racket/private/dial.rkt", &.{
        "glowcap_host_pending_dial",
        "run-dial!",
        "call-with-owned-locator-handle",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/racket/private/ffi-host.rkt", &.{
        "glowcap_host_pending_dial",
        "glowcap_locator_clone",
    });
    // Shared codec order spine: both encode paths must import codec_order.
    try expectFileContains(io, gpa, root, violations, "src/ocapn/codec/syrup/canonical_collection.zig", &.{
        "@import(\"codec_order\")",
    });
    try expectFileContains(io, gpa, root, violations, "src/ocapn/codec/capnp/encode_arguments.zig", &.{
        "@import(\"codec_order\")",
    });
    // Stale locator-bearing or ticket-only DIAL prose must not return in the C
    // header
    // sources. The generated include/glowcap_host.h needs no row of its
    // own: `gen-header-host-check` holds it byte-identical to these two.
    for ([_][]const u8{
        "action's transport",
        "the same pieces a DIAL action carries",
        "dial the exporter at locator",
        "at locator, then report",
        "fields stay zeroed for layout stability",
        "A DIAL action carries only ticket",
    }) |needle| {
        if (try fileContains(io, gpa, root, "tools/gen/header/host.zig", needle)) {
            try appendViolation(gpa, violations, "tools/gen/header/host.zig: stale DIAL prose `{s}` — HostAction carries ticket + route_index; pendingDial owns the locator", .{needle});
        }
        if (try fileContains(io, gpa, root, "src/c_abi/host/mod.zig", needle)) {
            try appendViolation(gpa, violations, "src/c_abi/host/mod.zig: stale DIAL prose `{s}` — HostAction carries ticket + route_index; drop dead locator fields", .{needle});
        }
    }
    // Dead dial-view fields stay deleted on GlowcapHostAction; the complete
    // locator remains on the pending Node row and is projected on demand.
    try expectFileContains(io, gpa, root, violations, "src/c_abi/host/mod.zig", &.{
        \\pub const GlowcapHostAction = extern struct {
        \\    kind: u32,
        \\    ticket: u64,
        \\    route_index: usize,
        \\    session: ?*GlowcapHostSession,
        \\    value: shared.GlowcapArgument,
        \\    message: ?[*]const u8,
        \\    message_len: usize,
        \\    /// CLOSE: GLOWCAP_OK or GLOWCAP_ERR_TIMEOUT. FAIL: GLOWCAP_ERR_BROKEN or
        \\    /// GLOWCAP_ERR_CLOSED. Zero for every other kind.
        \\    result: i32,
        \\};
    });
    try expectFileContains(io, gpa, root, violations, "src/ocapn/engine/node.zig", &.{
        "pub const PendingDialView = redeem_dials.PendingDialView;",
    });
    try expectFileContains(io, gpa, root, violations, "src/ocapn/engine/node/redeem/dials.zig", &.{
        "pub const PendingDialView = struct",
        "demanded_partner_key: ?crypto.PeerKey",
    });
    try expectFileContains(io, gpa, root, violations, "src/c_abi/host/host.zig", &.{
        "hint_storage: ?[*]c.GlowcapLocatorHintView",
        "out_locator: ?*c.GlowcapLocatorView",
        "out_hint_count: ?*usize",
    });
    try expectFileContains(io, gpa, root, violations, "src/c_abi/host/plan.zig", &.{
        "shared.locator_adapter.project(view.locator, hints)",
    });
    try expectFileContains(io, gpa, root, violations, "src/c_abi/host/symbols.zig", &.{
        ".{ .name = \"glowcap_host_pending_dial\", .out_params = &.{ 3, 5, 6 } }",
        ".{ .name = \"glowcap_host_dialed\", .out_params = &.{4} }",
    });
    for ([_][]const u8{
        "src/c_abi/host/mod.zig",
        "bindings/racket/private/ffi-shared.rkt",
        "bindings/rust/src/sys/host.rs",
    }) |path| {
        if (try fileContains(io, gpa, root, path, "GlowcapPendingDial")) {
            try appendViolation(gpa, violations, "{s}: fixed fragment pending-dial struct must stay deleted — project GlowcapLocatorView", .{path});
        }
    }
    // One TCP host:port admission; DialResolver / planDial compose it.
    try expectFileContains(io, gpa, root, violations, "src/ocapn/model/uri.zig", &.{
        "pub fn tcpConnectHostPort",
        "pub fn firstDirectAddress",
    });
    try expectFileContains(io, gpa, root, violations, "src/net/transport/tcp/addressing.zig", &.{
        "model.uri.connectHostPort",
    });
    try expectFileContains(io, gpa, root, violations, "src/driver/core/dial_plan.zig", &.{
        "tcpConnectHostPort",
        "peer_id:",
    });
    // TS pump-hooks layout comes from gen-ts-abi, not a hand mirror in action.ts.
    try expectFileContains(io, gpa, root, violations, "bindings/ts/runtime/internal/abi.ts", &.{
        "HOST_PUMP_HOOKS_SIZE",
        "HOST_PUMP_HOOKS_DIAL_OFF",
    });
    if (try fileContains(io, gpa, root, "bindings/ts/runtime/action.ts", "const HOST_PUMP_HOOKS_SIZE")) {
        try appendViolation(gpa, violations, "bindings/ts/runtime/action.ts: HOST_PUMP_HOOKS_* must come from abi.ts (gen-ts-abi)", .{});
    }
    for (action_mods) |mod| {
        root.access(io, mod.path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — HostAction action module (binding spine Pass 2)", .{mod.path});
            continue;
        };
        const contents = root.readFileAlloc(io, mod.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for host-action spine check with {s}", .{ mod.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, mod.decode_import) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — must use generated HostAction decode", .{ mod.path, mod.decode_import });
        }
        for (mod.markers) |marker| {
            if (std.mem.indexOf(u8, contents, marker) == null) {
                try appendViolation(gpa, violations, "{s}: host-action executor missing `{s}`", .{ mod.path, marker });
            }
        }
    }

    const generated = [_][]const u8{
        "bindings/ts/runtime/internal/host_action.ts",
        "bindings/python/glowcap/_host_action_gen.py",
        "bindings/rust/src/host_action_gen.rs",
        "bindings/racket/private/host-action-gen.rkt",
    };
    for (generated) |path| {
        root.access(io, path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — generated HostAction decode (run `zig build gen-binding-host-action`)", .{path});
        };
    }

    // Host files must not hand-roll a kind decode switch: no HOST_ACTION_* /
    // HOST-ACTION-* discriminant match outside the action + generated modules.
    const hosts = [_]struct { path: []const u8, banned: []const u8 }{
        .{ .path = "bindings/ts/runtime/host.ts", .banned = "HOST_ACTION_" },
        .{ .path = "bindings/ts/runtime/host/state.ts", .banned = "HOST_ACTION_" },
        .{ .path = "bindings/ts/runtime/host/lifecycle.ts", .banned = "HOST_ACTION_" },
        .{ .path = "bindings/ts/runtime/host/application.ts", .banned = "HOST_ACTION_" },
        .{ .path = "bindings/ts/runtime/host/drive.ts", .banned = "HOST_ACTION_" },
        .{ .path = "bindings/python/glowcap/_host/__init__.py", .banned = "HOST_ACTION_" },
        .{ .path = "bindings/python/glowcap/_host/finalizer.py", .banned = "HOST_ACTION_" },
        .{ .path = "bindings/python/glowcap/_host/lifecycle.py", .banned = "HOST_ACTION_" },
        .{ .path = "bindings/python/glowcap/_host/progress.py", .banned = "HOST_ACTION_" },
        .{ .path = "bindings/python/glowcap/_host/publication.py", .banned = "HOST_ACTION_" },
        .{ .path = "bindings/rust/src/host.rs", .banned = "HOST_ACTION_" },
        .{ .path = "bindings/racket/private/host.rkt", .banned = "HOST-ACTION-" },
    };
    for (hosts) |host| {
        const contents = root.readFileAlloc(io, host.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for host-action decode-ban check with {s}", .{ host.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, host.banned) != null) {
            try appendViolation(gpa, violations, "{s}: must not hand-decode HostAction (`{s}` belongs in the action module / generated decode)", .{ host.path, host.banned });
        }
    }
}
