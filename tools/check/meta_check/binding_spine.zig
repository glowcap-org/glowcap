//! The binding production-spine needle checks.
//!
//! The Rust, TypeScript, Python, and Racket bindings hand-mirror one product
//! spine — host-action drains, the embedder pump and trampoline, the promise /
//! gc / dial / listen choreography, the iroh readiness-loop convergence, and
//! the sidecar ABI pins — and these checks hold the four mirrors to the same
//! shape until generation retires each needle family (the generated-constants
//! tier already covers the value families). Wired by the meta-check driver
//! (`tools/check/meta_check.zig`).

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const fileContains = util.fileContains;
const firstIntIn = util.firstIntIn;

const ConstantsFile = struct {
    path: []const u8,
    /// Racket states constants as `(define NAME INT)`; the other three as a
    /// `NAME … = … INT` assignment per line.
    racket: bool = false,
};

const binding_constants_files = [_]ConstantsFile{
    .{ .path = "bindings/rust/src/abi_constants.rs" },
    .{ .path = "bindings/python/pancake/_constants.py" },
    .{ .path = "bindings/ts/stack/internal/constants.ts" },
    .{ .path = "bindings/racket/private/constants.rkt", .racket = true },
    // The per-binding iroh FFI mirrors of the `PANCAKE_IROH_*` transport
    // constants, held against include/pancake_net_transport_iroh.h.
    .{ .path = "bindings/rust/src/sys/iroh.rs" },
    .{ .path = "bindings/python/pancake/_ffi_iroh.py" },
    .{ .path = "bindings/racket/private/ffi-iroh.rkt", .racket = true },
};

/// The per-binding spellings of "raise this ABI error code". A numeric literal
/// at one of these sites bypasses the constant mirror that
/// `checkBindingConstants` keeps honest, so the code can drift from
/// `pancake_ocapn.h` without any gate noticing. Error sites must name the mirrored
/// constant; the literal lives in the constants file alone.
const binding_error_raise_patterns = [_][]const u8{
    "from_code(-", // Rust: Error::from_code(sys::ERR_…)
    "PancakeError(-", // Python / Deno: PancakeError(_ERR_… / ERR-less mirror name)
    "(check -", // Racket: (check ERR-…)
};

/// The iroh sidecar C ABI is spelled three times by hand — the Rust
/// definitions (`transports/iroh/src/lib.rs`), the C header
/// (`transports/iroh/include/pancake_iroh_sidecar.h`), and the Zig resident's
/// externs (`src/net/transport/iroh.zig`) — and the hermetic gate never links
/// them, so a
/// drifted spelling would surface only as a crash in the cargo-equipped
/// `iroh-interop` run, or not at all for a silent width change. The coarse
/// shape below is the strongest contract three syntaxes share.
const CoarseAbiType = enum {
    ptr,
    word,
    iword,
    int32,
    uint32,
    none,
    unknown,

    fn label(self: CoarseAbiType) []const u8 {
        return switch (self) {
            .ptr => "ptr",
            .word => "usize",
            .iword => "isize",
            .int32 => "i32",
            .uint32 => "u32",
            .none => "void",
            .unknown => "?",
        };
    }
};

/// Apex for ADR-0076 iroh convergence: CapTP fan-out must not re-grow inside
/// the iroh resident. The resident supplies the netlayer + completion
/// `Backend` only; serving is `driver.Bridge` + Host. A reintroduced
/// `LoopHost` / `driver_core` / `actors` import fails the gate instead of
/// shipping a second diverging serve spine.
pub fn checkIrohLoopConvergence(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const path = "src/net/transport/iroh.zig";
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for iroh-loop-convergence check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    const forbidden = [_]struct { needle: []const u8, reason: []const u8 }{
        .{ .needle = "LoopHost", .reason = "CapTP scale must stay on `driver.Bridge` + Host, not a resident-local serve loop" },
        .{ .needle = "@import(\"driver_core\")", .reason = "the iroh resident must not import the serve core; Bridge owns CapTP" },
        .{ .needle = "@import(\"actors\")", .reason = "the iroh resident must not mint vats; Bridge + Host own CapTP" },
    };
    for (forbidden) |entry| {
        if (std.mem.indexOf(u8, contents, entry.needle) != null) {
            try appendViolation(gpa, violations, "{s}: forbidden `{s}` — {s}", .{ path, entry.needle, entry.reason });
        }
    }
    if (std.mem.indexOf(u8, contents, "pub const Backend") == null) {
        try appendViolation(gpa, violations, "{s}: missing `pub const Backend` — iroh scale must expose a completion Backend (ADR-0057/0076)", .{path});
    }
}

/// The iroh `BindingClientRow` tables (`iroh_loop_clients`,
/// `iroh_handoff_clients`, `iroh_reach_clients`) each feed a `bindings-iroh-*`
/// aggregate. A binding silently missing from one of these tables would still
/// build — the aggregate degrades to whichever rows remain — so the gap is
/// invisible to `zig build check` unless something demands every step name
/// explicitly. This holds the closed binding set (deno/python/rust/racket) the
/// sibling `iroh_redeem_clients` and `keyed_tcp_restart_clients` tables already
/// carry.
pub fn checkIrohBindingAggregatesComplete(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const path = "build.zig";
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for iroh-binding-aggregate check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    const families = [_]struct {
        marker: []const u8,
        steps: []const []const u8,
    }{
        .{
            .marker = "iroh_loop_clients = [_]BindingClientRow{",
            .steps = &.{ "deno-iroh-loop", "python-iroh-loop", "rust-iroh-loop", "racket-iroh-loop" },
        },
        .{
            .marker = "iroh_handoff_clients = [_]BindingClientRow{",
            .steps = &.{ "deno-iroh-handoff", "python-iroh-handoff", "rust-iroh-handoff", "racket-iroh-handoff" },
        },
        .{
            .marker = "iroh_reach_clients = [_]BindingClientRow{",
            .steps = &.{ "deno-iroh-reachability", "python-iroh-reachability", "rust-iroh-reachability", "racket-iroh-reachability" },
        },
    };

    for (families) |family| {
        const block = extractBraceBlock(contents, family.marker) orelse {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — cannot find the iroh binding-client row table", .{ path, family.marker });
            continue;
        };
        for (family.steps) |step| {
            var buf: [64]u8 = undefined;
            const needle = std.fmt.bufPrint(&buf, "\"{s}\"", .{step}) catch continue;
            if (std.mem.indexOf(u8, block, needle) == null) {
                try appendViolation(gpa, violations, "{s}: `{s}` is missing a `{s}` row — every iroh binding aggregate must carry deno, python, rust, and racket", .{ path, family.marker, step });
            }
        }
    }
}

/// Every per-binding ABI constant mirror restates discriminants and return codes
/// from the generated headers by hand. The headers themselves cannot drift (the
/// parity tests reflect them from the Zig c_abi source), but the mirror files
/// can. This parses each mirror's numeric values and asserts they match the
/// matching `#define PANCAKE_…` value, so a hand-edit that desyncs a constant
/// fails the gate instead of waiting for a live conversation to touch it.
///
/// The header values come from every generated header, not just the ocapn
/// base, so the driver archive's `PANCAKE_HOST_*` and the iroh archive's
/// `PANCAKE_IROH_*` mirrors are held too. The mirror
/// files span both the ocapn constant files and the per-binding iroh FFI files
/// (`binding_constants_files`), and `lookupHeaderConst` tolerates the `PANCAKE_`
/// or leading-`_` prefix a private FFI mirror spells its names with.
pub fn checkBindingConstants(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const headers = [_][]const u8{
        "include/pancake_ocapn.h",
        "include/pancake_driver.h",
        "include/pancake_net_transport_tcp.h",
        "include/pancake_net_transport_inproc.h",
        "include/pancake_net_transport_iroh.h",
    };
    // The header buffers back the `header_vals` key slices, so keep them alive
    // for the whole check.
    var header_buffers: std.ArrayList([]u8) = .empty;
    defer {
        for (header_buffers.items) |buf| gpa.free(buf);
        header_buffers.deinit(gpa);
    }

    // Map every header's `#define PANCAKE_<NAME> <int>` value, keyed by the name
    // after the `PANCAKE_` prefix. Mirrors drop `ERR_` from `WOULD_BLOCK`, so
    // each `ERR_<X>` also registers a bare `<X>` alias.
    var header_vals = std.StringHashMap(i64).init(gpa);
    defer header_vals.deinit();
    for (headers) |header_path| {
        const header = root.readFileAlloc(io, header_path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for constant-mirror check with {s}", .{ header_path, @errorName(err) });
            continue;
        };
        try header_buffers.append(gpa, header);
        var rest = header;
        const needle = "#define PANCAKE_";
        while (std.mem.indexOf(u8, rest, needle)) |start| {
            const after = rest[start + needle.len ..];
            const line_end = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
            const line = after[0..line_end];
            rest = after[line_end..];

            const name_end = std.mem.indexOfAny(u8, line, " \t") orelse continue;
            const name = line[0..name_end];
            const value = firstIntIn(line[name_end..]) orelse continue;
            try header_vals.put(name, value);
            if (std.mem.startsWith(u8, name, "ERR_")) try header_vals.put(name["ERR_".len..], value);
        }
    }

    var norm_buf: [128]u8 = undefined;
    for (binding_constants_files) |file| {
        const contents = root.readFileAlloc(io, file.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for constant-mirror check with {s}", .{ file.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        if (file.racket) {
            var rest = contents;
            while (std.mem.indexOf(u8, rest, "(define ")) |start| {
                const after = rest[start + "(define ".len ..];
                rest = after;
                const name_end = std.mem.indexOfAny(u8, after, " \t") orelse continue;
                const raw_name = after[0..name_end];
                const value = firstIntIn(after[name_end..]) orelse continue;
                try compareConstant(gpa, violations, file.path, &header_vals, raw_name, value, &norm_buf);
            }
        } else {
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |raw_line| {
                const trimmed = std.mem.trim(u8, raw_line, " \t");
                if (std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "#")) continue;
                const eq = std.mem.indexOfScalar(u8, raw_line, '=') orelse continue;
                var lhs = raw_line[0..eq];
                if (std.mem.indexOfScalar(u8, lhs, ':')) |colon| lhs = lhs[0..colon];
                const lhs_trimmed = std.mem.trim(u8, lhs, " \t");
                const name_start = if (std.mem.lastIndexOfAny(u8, lhs_trimmed, " \t")) |sp| sp + 1 else 0;
                const raw_name = lhs_trimmed[name_start..];
                if (raw_name.len == 0) continue;
                // The value is the first integer up to a `;` or `//` comment.
                var rhs = raw_line[eq + 1 ..];
                if (std.mem.indexOfScalar(u8, rhs, ';')) |semi| rhs = rhs[0..semi];
                if (std.mem.indexOf(u8, rhs, "//")) |c| rhs = rhs[0..c];
                const value = firstIntIn(rhs) orelse continue;
                try compareConstant(gpa, violations, file.path, &header_vals, raw_name, value, &norm_buf);
            }
        }
    }
}

fn compareConstant(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    header_vals: *std.StringHashMap(i64),
    raw_name: []const u8,
    value: i64,
    norm_buf: *[128]u8,
) !void {
    if (raw_name.len > norm_buf.len) return;
    var name = norm_buf[0..raw_name.len];
    for (raw_name, 0..) |c, i| name[i] = if (c == '-') '_' else std.ascii.toUpper(c);
    const expected = lookupHeaderConst(header_vals, name) orelse return; // no header counterpart (e.g. struct sizes)
    if (expected != value) {
        try appendViolation(gpa, violations, "{s}: constant {s} = {d} drifts from header PANCAKE_… = {d}", .{ path, raw_name, value, expected });
    }
}

/// Look up a mirror constant's expected header value, tolerating the two prefix
/// conventions a private FFI mirror uses: an iroh Rust mirror spells the full
/// `PANCAKE_IROH_EV_*`, a Python one spells `_IROH_EV_*`, while the header keys
/// are stripped of `PANCAKE_`. The direct hit is tried first; a prefix strip
/// only ever turns a would-be silent skip into a match, never an existing match
/// into a miss.
fn lookupHeaderConst(header_vals: *std.StringHashMap(i64), name: []const u8) ?i64 {
    if (header_vals.get(name)) |v| return v;
    if (std.mem.startsWith(u8, name, "PANCAKE_")) {
        if (header_vals.get(name["PANCAKE_".len..])) |v| return v;
    }
    if (std.mem.startsWith(u8, name, "_")) {
        if (header_vals.get(name[1..])) |v| return v;
    }
    return null;
}

/// Every `PANCAKE_HOST_ACTION_*` kind must appear in each binding's host-action
/// drain. The Zig embedders share one skeleton (`driver_core.drainActions`);
/// the four language bindings each hand-roll the executor arm set in a named
/// `action` module (decode/types are generated). Grep-level: the header's
/// action name must appear as `HOST_ACTION_<NAME>` (or `HOST-ACTION-<NAME>` in
/// Racket) in the action module. A new kind without a binding arm fails
/// `zig build meta-check`.
///
/// Racket's drain `case` arms use lowercase kebab symbols (`[(close)`, …);
/// those must appear in `action.rkt` (otherwise a decode-only module still
/// passes while the drain silently drops the new kind).
pub fn checkBindingHostActionDrains(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const header_path = "include/pancake_driver.h";
    const header = root.readFileAlloc(io, header_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for host-action drain check with {s}", .{ header_path, @errorName(err) });
        return;
    };
    defer gpa.free(header);

    var action_names: std.ArrayList([]const u8) = .empty;
    defer action_names.deinit(gpa);
    const needle = "#define PANCAKE_HOST_ACTION_";
    var rest = header;
    while (std.mem.indexOf(u8, rest, needle)) |start| {
        const after = rest[start + needle.len ..];
        const name_end = std.mem.indexOfAny(u8, after, " \t\r\n") orelse after.len;
        const name = after[0..name_end];
        if (name.len != 0) try action_names.append(gpa, name);
        rest = after[name_end..];
    }
    if (action_names.items.len == 0) {
        try appendViolation(gpa, violations, "{s}: no PANCAKE_HOST_ACTION_* constants found for drain check", .{header_path});
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
        // stays in action.* (ticket-only dial, flush, …). Union of paths must
        // cover every PANCAKE_HOST_ACTION_*.
        .{
            .paths = &.{
                "bindings/ts/stack/action.ts",
                "bindings/ts/stack/internal/host_action.ts",
            },
            .sep = '_',
        },
        .{
            .paths = &.{
                "bindings/python/pancake/_action.py",
                "bindings/python/pancake/_host_action_gen.py",
            },
            .sep = '_',
            .variant_path = "bindings/python/pancake/_host_action_gen.py",
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
                    try appendViolation(gpa, violations, "{s}: host-action drain missing `{s}` arm (from PANCAKE_HOST_ACTION_{s})", .{ vpath, variant, name });
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
                try appendViolation(gpa, violations, "{s}: host-action drain missing `{s}` (from PANCAKE_HOST_ACTION_{s})", .{ label, token, name });
            }

            if (drain.racket_symbol_path) |sym_path| {
                const contents = sym_contents orelse continue;
                // `'kebab-name` — hash key in `host-dispatch-action!` handlers.
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
                    try appendViolation(gpa, violations, "{s}: host-action drain missing `{s}` handler (from PANCAKE_HOST_ACTION_{s})", .{ sym_path, symbol, name });
                }
            }
        }
    }
}

/// Binding spine Pass 2: each binding keeps a named `action` module for
/// decode+execute, imports the generated HostAction decode, and does not
/// hand-roll a kind switch in the Host file. Grep-level — catches silent
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
            .path = "bindings/ts/stack/action.ts",
            .decode_import = "decodeHostAction",
            .markers = &.{
                "dispatchHostAction",
                "runDialTicket",
                "flushOutbound",
                "pancake_host_provide_gift_id",
                "settleVow",
                "closeTransport",
            },
        },
        .{
            .path = "bindings/python/pancake/_action.py",
            .decode_import = "decode",
            .markers = &.{
                "dispatch",
                "run_dial_ticket",
                "flush_outbound",
                "pancake_host_provide_gift_id",
                "settle_vow",
                "close_transport",
            },
        },
        .{
            .path = "bindings/rust/src/action.rs",
            .decode_import = "host_action_gen",
            .markers = &.{
                "host_action_gen::dispatch",
                "run_dial_ticket",
                "flush_outbound",
                "pancake_host_provide_gift_id",
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
                "drain-outbound!",
                "host-provide-gift-id!",
                "settle-vow!",
                "session-close!",
            },
        },
    };
    // Generated dispatch inventory must stay live in each language's gen file.
    try expectFileContains(io, gpa, root, violations, "bindings/ts/stack/internal/host_action.ts", &.{
        "dispatchHostAction",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/python/pancake/_host_action_gen.py", &.{
        "async def dispatch",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/rust/src/host_action_gen.rs", &.{
        "pub async fn dispatch",
        "trait HostActionHandlers",
    });
    // Generated inventory must stay live — allow(dead_code) on dispatch is a half-land.
    if (try fileContains(io, gpa, root, "bindings/rust/src/host_action_gen.rs", "#[allow(dead_code)]")) {
        try appendViolation(gpa, violations, "bindings/rust/src/host_action_gen.rs: #[allow(dead_code)] must stay deleted — action.rs must call dispatch", .{});
    }
    try expectFileContains(io, gpa, root, violations, "bindings/racket/private/host-action-gen.rkt", &.{
        "host-dispatch-action!",
    });
    // Ticket-only DIAL: each dial module borrows the pending view (no URI re-parse).
    try expectFileContains(io, gpa, root, violations, "bindings/ts/stack/dial.ts", &.{
        "pancake_host_pending_dial",
        "runDialTicket",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/python/pancake/_dial.py", &.{
        "pancake_host_pending_dial",
        "run_dial_ticket",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/rust/src/dial.rs", &.{
        "pancake_host_pending_dial",
        "run_dial_ticket",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/racket/private/dial.rkt", &.{
        "pancake_host_pending_dial",
        "run-dial!",
    });
    // Shared codec order spine: both encode paths must import codec_order.
    try expectFileContains(io, gpa, root, violations, "src/ocapn/codec/syrup/encode.zig", &.{
        "@import(\"codec_order\")",
    });
    try expectFileContains(io, gpa, root, violations, "src/ocapn/codec/capnp/encode.zig", &.{
        "@import(\"codec_order\")",
    });
    // Stale ticket-only DIAL contract prose must not return in the C header
    // sources. The generated include/pancake_driver.h needs no row of its
    // own: `gen-header-driver-check` holds it byte-identical to these two.
    for ([_][]const u8{
        "action's transport",
        "the same pieces a DIAL action carries",
        "dial the exporter at locator",
        "at locator, then report",
        "fields stay zeroed for layout stability",
    }) |needle| {
        if (try fileContains(io, gpa, root, "tools/gen/header/driver.zig", needle)) {
            try appendViolation(gpa, violations, "tools/gen/header/driver.zig: stale DIAL prose `{s}` — ticket-only; pendingDial owns the URI", .{needle});
        }
        if (try fileContains(io, gpa, root, "src/c_abi/driver/mod.zig", needle)) {
            try appendViolation(gpa, violations, "src/c_abi/driver/mod.zig: stale DIAL prose `{s}` — ticket-only; drop dead locator fields", .{needle});
        }
    }
    // Dead dial-view fields must stay deleted on PancakeHostAction (parts live
    // on PancakePendingDial only — no verbatim locator field).
    try expectFileContains(io, gpa, root, violations, "src/c_abi/driver/mod.zig", &.{
        \\pub const PancakeHostAction = extern struct {
        \\    kind: u32,
        \\    ticket: u64,
        \\    session: ?*PancakeHostSession,
        \\    value: shared.PancakeArgument,
        \\    message: ?[*]const u8,
        \\    message_len: usize,
        \\};
    });
    try expectFileContains(io, gpa, root, violations, "src/c_abi/driver/mod.zig", &.{
        \\pub const PancakePendingDial = extern struct {
        \\    transport: ?[*]const u8,
        \\    transport_len: usize,
        \\    designator: ?[*]const u8,
        \\    designator_len: usize,
        \\    hint: ?[*]const u8,
        \\    hint_len: usize,
        \\};
    });
    // Verbatim locator must stay deleted from pending dial views (parts alone).
    if (try fileContains(io, gpa, root, "src/ocapn/engine/node.zig", "pub const PendingDialView = struct {\n        locator:")) {
        try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: PendingDialView must not carry locator — transport/designator/hint only", .{});
    }
    if (try fileContains(io, gpa, root, "src/c_abi/driver/host.zig", ".locator = view.locator")) {
        try appendViolation(gpa, violations, "src/c_abi/driver/host.zig: pancake_host_pending_dial must not fill a locator field", .{});
    }
    // One TCP host:port admission; DialResolver / planDial compose it.
    try expectFileContains(io, gpa, root, violations, "src/ocapn/model/uri.zig", &.{
        "pub fn tcpConnectHostPort",
        "pub fn firstDirectAddress",
    });
    try expectFileContains(io, gpa, root, violations, "src/net/transport/tcp.zig", &.{
        "tcpConnectHostPort",
    });
    try expectFileContains(io, gpa, root, violations, "src/driver/core/dial_plan.zig", &.{
        "tcpConnectHostPort",
        "peer_id:",
    });
    // TS pump-hooks layout comes from gen-ts-abi, not a hand mirror in action.ts.
    try expectFileContains(io, gpa, root, violations, "bindings/ts/stack/internal/abi.ts", &.{
        "HOST_PUMP_HOOKS_SIZE",
        "HOST_PUMP_HOOKS_DIAL_OFF",
    });
    if (try fileContains(io, gpa, root, "bindings/ts/stack/action.ts", "const HOST_PUMP_HOOKS_SIZE")) {
        try appendViolation(gpa, violations, "bindings/ts/stack/action.ts: HOST_PUMP_HOOKS_* must come from abi.ts (gen-ts-abi)", .{});
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
        "bindings/ts/stack/internal/host_action.ts",
        "bindings/python/pancake/_host_action_gen.py",
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
        .{ .path = "bindings/ts/stack/host.ts", .banned = "HOST_ACTION_" },
        .{ .path = "bindings/python/pancake/_host.py", .banned = "HOST_ACTION_" },
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

/// Binding spine Pass 3a: each binding keeps a named `promise` module for the
/// RemotePromise / session-vow handle and pipelined projection. Grep-level —
/// catches silent deletes, not wrong semantics.
pub fn checkBindingPromiseSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const mods = [_]struct {
        path: []const u8,
        markers: []const []const u8,
    }{
        .{
            .path = "bindings/ts/stack/promise.ts",
            .markers = &.{ "class RemotePromise", "index(", "untag(", "get(", "awaitMinted", "fetchLike", "promiseFor", "sendFar", "pancake_host_vow_index", "pancake_host_vow_untag", "pancake_host_vow_get" },
        },
        .{
            .path = "bindings/python/pancake/_promise.py",
            .markers = &.{ "class RemotePromise", "def index", "def untag", "def get", "_await_minted", "_fetch_like", "def _promise_for", "def _send_far", "pancake_host_vow_get" },
        },
        .{
            .path = "bindings/rust/src/promise.rs",
            .markers = &.{ "struct RemotePromise", "fn index", "fn untag", "fn get", "pancake_host_vow_index", "pancake_host_vow_get", "await_minted", "fetch_like", "fn send_promise" },
        },
        .{
            .path = "bindings/racket/private/promise.rkt",
            .markers = &.{ "session-vow", "settle-vow!", "session-index", "session-untag", "session-get", "pancake_host_vow_index", "pancake_host_vow_get", "await-vow", "blocking-fetch", "session-far-send", "pancake_host_session_send", "pancake_host_session_tell", "pancake_host_vow_send" },
        },
    };
    for (mods) |mod| {
        root.access(io, mod.path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — promise veneer module (binding spine Pass 3a)", .{mod.path});
            continue;
        };
        const contents = root.readFileAlloc(io, mod.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for promise-spine check with {s}", .{ mod.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (mod.markers) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: promise module missing `{s}`", .{ mod.path, needle });
            }
        }
    }

    // Fetch/enliven mint→await bodies and far-send promise factories live in
    // promise (Pass 4b / 4d), not session.
    const banned = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/ts/stack/session.ts", .needle = "async #fetchLike" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "#promiseFor(" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "async def _fetch_like" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "async def _await_minted" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "def _promise_for" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "async fn await_minted" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "async fn fetch_like" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "fn send_promise" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (await-vow" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (blocking-fetch" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (session-far-send" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "pancake_host_session_send" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "pancake_host_session_tell" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "pancake_host_vow_send" },
    };
    for (banned) |b| {
        const contents = root.readFileAlloc(io, b.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for promise-fetch ban with {s}", .{ b.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, b.needle) != null) {
            try appendViolation(gpa, violations, "{s}: `{s}` belongs in promise, not session (Pass 4b/4d)", .{ b.path, b.needle });
        }
    }
}

/// Binding spine Pass 5 (Rust): `Ref` / `Caretaker` / `SessionShared` live in
/// `session_shared.rs`, not `session.rs`. Grep-level.
pub fn checkBindingRustConnSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const path = "bindings/rust/src/session_shared.rs";
    root.access(io, path, .{}) catch {
        try appendViolation(gpa, violations, "{s}: file must exist — Rust session_shared module (binding spine Pass 5)", .{path});
        return;
    };
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for rust session_shared check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);
    for ([_][]const u8{ "pub struct Ref", "pub struct Caretaker", "pub(crate) struct SessionShared", "fn tell(" }) |needle| {
        if (std.mem.indexOf(u8, contents, needle) == null) {
            try appendViolation(gpa, violations, "{s}: session_shared module missing `{s}`", .{ path, needle });
        }
    }
    const banned = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/rust/src/session.rs", .needle = "pub struct Ref" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "pub struct Caretaker" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "pub(crate) struct SessionShared" },
    };
    for (banned) |b| {
        const session = root.readFileAlloc(io, b.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for rust session_shared ban with {s}", .{ b.path, @errorName(err) });
            continue;
        };
        defer gpa.free(session);
        if (std.mem.indexOf(u8, session, b.needle) != null) {
            try appendViolation(gpa, violations, "{s}: `{s}` belongs in session_shared.rs, not session (Pass 5)", .{ b.path, b.needle });
        }
    }
}

/// Binding spine Pass 3b: each binding keeps a named `gc` module for ADR-0063
/// distributed GC (opt-in track + drain). Grep-level.
pub fn checkBindingGcSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const mods = [_]struct {
        path: []const u8,
        markers: []const []const u8,
    }{
        .{
            .path = "bindings/ts/stack/gc.ts",
            .markers = &.{ "class ConnGc", "interface GcHandle", "pancake_host_gc_release", "trackImport(", "drainGc(", "bind(" },
        },
        .{
            .path = "bindings/python/pancake/_gc.py",
            .markers = &.{ "class ConnGc", "class GcHandle", "def bind_session", "pancake_host_gc_release", "def track_import", "def drain_gc", "def bind" },
        },
        .{
            .path = "bindings/rust/src/gc.rs",
            .markers = &.{ "struct ImportGuard", "pancake_host_gc_release", "fn drain", "fn track_import" },
        },
        .{
            .path = "bindings/racket/private/gc.rkt",
            .markers = &.{ "session-with-gc!", "track-import!", "drain-gc!", "pancake_host_gc_release" },
        },
    };
    for (mods) |mod| {
        root.access(io, mod.path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — GC veneer module (binding spine Pass 3b)", .{mod.path});
            continue;
        };
        const contents = root.readFileAlloc(io, mod.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for gc-spine check with {s}", .{ mod.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (mod.markers) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: gc module missing `{s}`", .{ mod.path, needle });
            }
        }
    }

    // Track/drain bodies live in gc, not session (Pass 3b).
    const banned = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/ts/stack/session.ts", .needle = "#trackImport(" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "#drainGc(" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "pancake_host_gc_release" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "def _track_import" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "def _drain_gc" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "def _on_import_dropped" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "pancake_host_gc_release" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "fn track_import" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "pancake_host_gc_release" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "pancake_host_gc_release" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (track-import!" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (drain-gc!" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (session-with-gc!" },
    };
    for (banned) |b| {
        const contents = root.readFileAlloc(io, b.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for gc-session ban with {s}", .{ b.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, b.needle) != null) {
            try appendViolation(gpa, violations, "{s}: `{s}` belongs in gc, not session (Pass 3b)", .{ b.path, b.needle });
        }
    }

    // Python ConnGc must not poke Session privates — GcHandle owns the seam.
    const py_gc = "bindings/python/pancake/_gc.py";
    const py_gc_contents = root.readFileAlloc(io, py_gc, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for GcHandle check with {s}", .{ py_gc, @errorName(err) });
        return;
    };
    defer gpa.free(py_gc_contents);
    for ([_][]const u8{ "session._host", "session._loop", "session._released", "getattr(session", "._s._" }) |needle| {
        if (std.mem.indexOf(u8, py_gc_contents, needle) != null) {
            try appendViolation(gpa, violations, "{s}: `{s}` — ConnGc must use GcHandle, not Session privates", .{ py_gc, needle });
        }
    }

    // Python owning modules must use Session/Host binding-internal seams
    // (raw/host/gc/hosted/…), not underscore reach-ins — the same class of
    // smell as the pre-fix ConnGc getattr path.
    const py_seam = [_]struct { path: []const u8, needles: []const []const u8 }{
        .{ .path = "bindings/python/pancake/_pump.py", .needles = &.{ "session._", "host._" } },
        .{ .path = "bindings/python/pancake/_promise.py", .needles = &.{"session._"} },
        .{ .path = "bindings/python/pancake/_trampoline.py", .needles = &.{"session._"} },
        .{ .path = "bindings/python/pancake/_action.py", .needles = &.{ "host._", "conn._" } },
        .{ .path = "bindings/python/pancake/_host.py", .needles = &.{"conn._"} },
    };
    for (py_seam) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for private-reach ban with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (row.needles) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: `{s}` — use binding-internal Session/Host seams, not privates", .{ row.path, needle });
            }
        }
    }
}

/// Binding spine Pass 3c: each binding keeps a named `dial` module for the
/// unified dial executor (plan_dial + connect + redeem). Grep-level.
pub fn checkBindingDialSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const mods = [_]struct {
        path: []const u8,
        markers: []const []const u8,
    }{
        .{
            .path = "bindings/ts/stack/dial.ts",
            .markers = &.{ "dialParsedLocator", "pancake_host_plan_dial", "dialExporter", "function connect" },
        },
        .{
            .path = "bindings/python/pancake/_dial.py",
            .markers = &.{ "dial_parsed_locator", "pancake_host_plan_dial", "dial_exporter", "async def connect" },
        },
        .{
            .path = "bindings/rust/src/dial.rs",
            .markers = &.{ "dial_parsed_locator", "pancake_host_plan_dial", "dial_exporter", "pub async fn connect" },
        },
        .{
            .path = "bindings/racket/private/dial.rkt",
            .markers = &.{ "dial-parsed-locator", "pancake_host_plan_dial", "dial-exporter", "(define (connect" },
        },
    };
    for (mods) |mod| {
        root.access(io, mod.path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — dial module (binding spine Pass 3c)", .{mod.path});
            continue;
        };
        const contents = root.readFileAlloc(io, mod.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for dial-spine check with {s}", .{ mod.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (mod.markers) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: dial module missing `{s}`", .{ mod.path, needle });
            }
        }
    }
}

/// Binding spine Pass 3d: each binding keeps a named `listen` module for
/// Server / listen / keyed-tcp hosting. Grep-level.
pub fn checkBindingListenSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const mods = [_]struct {
        path: []const u8,
        markers: []const []const u8,
    }{
        .{
            .path = "bindings/ts/stack/listen.ts",
            .markers = &.{ "class Server", "class KeyedTcpServer", "function listen", "listenKeyedTcp", "establishAccepted", "socketAddrDesignator" },
        },
        .{
            .path = "bindings/python/pancake/_listen.py",
            .markers = &.{ "class Server", "class KeyedTcpServer", "async def listen", "listen_keyed_tcp", "establish_accepted", "socket_addr_designator" },
        },
        .{
            .path = "bindings/rust/src/listen.rs",
            .markers = &.{ "struct Server", "KeyedTcpServer", "pub async fn listen", "listen_keyed_tcp", "establish_accepted", "socket_addr_designator" },
        },
        .{
            .path = "bindings/racket/private/listen.rkt",
            .markers = &.{ "(struct server", "listen-keyed-tcp", "(define (listen", "(define (accept", "establish-accepted-session", "socket-addr-designator" },
        },
    };
    for (mods) |mod| {
        root.access(io, mod.path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — listen module (binding spine Pass 3d)", .{mod.path});
            continue;
        };
        const contents = root.readFileAlloc(io, mod.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for listen-spine check with {s}", .{ mod.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (mod.markers) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: listen module missing `{s}`", .{ mod.path, needle });
            }
        }
    }
    // Session must not re-export dial/listen — the barrel owns that graph.
    const reexport_bans = [_]struct {
        path: []const u8,
        banned: []const []const u8,
    }{
        .{
            .path = "bindings/ts/stack/session.ts",
            .banned = &.{ "export { connect }", "from \"./dial.ts\"", "from \"./listen.ts\"", "export { RemotePromise }" },
        },
        .{
            .path = "bindings/racket/private/session.rkt",
            .banned = &.{
                "(all-from-out \"dial.rkt\")",
                "(all-from-out \"listen.rkt\")",
                "(all-from-out \"action.rkt\")",
                "(all-from-out \"pump.rkt\")",
                "(all-from-out \"async.rkt\")",
                "(all-from-out \"host.rkt\")",
                "(all-from-out \"promise.rkt\")",
                "(all-from-out \"gc.rkt\")",
            },
        },
        .{
            .path = "bindings/rust/src/session.rs",
            .banned = &.{ "pub use crate::promise::", "pub use crate::dial::", "pub use crate::listen::" },
        },
        .{
            .path = "bindings/python/pancake/_session.py",
            .banned = &.{ "from ._dial import", "from ._listen import", "async def connect", "class Server", "class KeyedTcpServer" },
        },
    };
    for (reexport_bans) |entry| {
        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for dial/listen re-export ban with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (entry.banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — dial/listen/promise re-exports belong on the barrel, not session", .{ entry.path, needle });
            }
        }
    }
}

/// CapTP embedder pump (ADR-0072 / Pass-1 spine gate): each binding keeps a
/// named `pump` module for the conn byte path, mid-turn conn_release parking
/// in the session close path, and the C reference example that compiles the
/// same choreography. Grep-level — catches silent deletes, not wrong order.
pub fn checkBindingEmbedderPump(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const pump_paths = [_][]const u8{
        "bindings/ts/stack/pump.ts",
        "bindings/python/pancake/_pump.py",
        "bindings/rust/src/pump.rs",
        "bindings/racket/private/pump.rkt",
    };
    for (pump_paths) |path| {
        root.access(io, path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — EmbedderPump module (binding spine Pass 1)", .{path});
            continue;
        };
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for embedder-pump check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        const markers = [_][]const u8{
            "pancake_host_session_feed_bytes",
            "take_outbound",
            "break_far_vows",
        };
        for (markers) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: pump missing `{s}` — conn byte choreography", .{ path, needle });
            }
        }
        // Feed-refusal / last_abort: the FFI reader lives in pump (Pass 1b).
        if (std.mem.indexOf(u8, contents, "pancake_host_session_last_abort") == null and
            std.mem.indexOf(u8, contents, "last_abort") == null and
            std.mem.indexOf(u8, contents, "last-abort") == null)
        {
            try appendViolation(gpa, violations, "{s}: pump missing last_abort/last-abort — feed-refusal path", .{path});
        }
        // Post-feed action kick / drain (one-loop rule after feed_bytes).
        const kick_ok = std.mem.indexOf(u8, contents, "kickActions") != null or
            std.mem.indexOf(u8, contents, "kick_actions") != null or
            std.mem.indexOf(u8, contents, "drain-host-actions!") != null;
        if (!kick_ok) {
            try appendViolation(gpa, violations, "{s}: pump missing post-feed action kick/drain (kickActions / kick_actions / drain-host-actions!)", .{path});
        }
        // Feed refusal must use the shared drain, not a private take_outbound
        // flush — the same spine as a steady FLUSH (bindings/README checklist).
        const private_refusal_flush = [_][]const u8{
            "await flushOutbound(h)",
            "flush_outbound(shared).await",
            "await flush_outbound(session)",
        };
        for (private_refusal_flush) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: feed-refusal must not private-flush via `{s}` — use kick_actions / kickActions / drain-effects", .{ path, needle });
            }
        }
        // EOF / break_far_vows must drain FAIL completions (shared spine). Match
        // the FFI *call* (`…break_far_vows(`) so module-doc mentions do not fire.
        // Kick may appear just before (Racket `with-breaking-drain`) or after.
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, contents, search_from, "pancake_host_session_break_far_vows(")) |break_at| {
            const lo = if (break_at > 400) break_at - 400 else 0;
            const hi = @min(contents.len, break_at + 800);
            const window = contents[lo..hi];
            const kick_near = std.mem.indexOf(u8, window, "kickActions") != null or
                std.mem.indexOf(u8, window, "kick_actions") != null or
                std.mem.indexOf(u8, window, "drain-host-actions!") != null or
                std.mem.indexOf(u8, window, "with-breaking-drain") != null;
            if (!kick_near) {
                try appendViolation(gpa, violations, "{s}: pancake_host_session_break_far_vows without nearby action kick/drain — EOF must settle FAIL completions", .{path});
            }
            search_from = break_at + 1;
        }
        // Keyed handshake loop lives in pump (Pass 4a), not session.
        const hs_ok = std.mem.indexOf(u8, contents, "runHandshake") != null or
            std.mem.indexOf(u8, contents, "_run_handshake") != null or
            std.mem.indexOf(u8, contents, "run_handshake") != null or
            std.mem.indexOf(u8, contents, "run-handshake!") != null;
        if (!hs_ok) {
            try appendViolation(gpa, violations, "{s}: pump missing handshake runner (runHandshake / _run_handshake / run_handshake / run-handshake!)", .{path});
        }
        // The handshake closed-message is one cross-language string: a pump
        // that respells it ships a divergent consumer-facing error.
        if (std.mem.indexOf(u8, contents, "connection closed during the OCapN handshake") == null) {
            try appendViolation(gpa, violations, "{s}: pump missing the canonical handshake closed-message (`connection closed during the OCapN handshake`)", .{path});
        }
    }

    // Handshake error string must not live in session files — pump owns the loop.
    const handshake_msg = "connection closed during the OCapN handshake";
    const session_paths = [_][]const u8{
        "bindings/ts/stack/session.ts",
        "bindings/python/pancake/_session.py",
        "bindings/rust/src/session.rs",
        "bindings/racket/private/session.rkt",
    };
    for (session_paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for handshake-spine check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, handshake_msg) != null) {
            try appendViolation(gpa, violations, "{s}: handshake closed-message belongs in pump, not session", .{path});
        }
        // last_abort FFI reader lives in pump (Pass 1b); Session may wrap.
        if (std.mem.indexOf(u8, contents, "pancake_host_session_last_abort") != null) {
            try appendViolation(gpa, violations, "{s}: pancake_host_session_last_abort belongs in pump, not session", .{path});
        }
        // break_far_vows FFI lives in pump; Session may wrap the drain window.
        if (std.mem.indexOf(u8, contents, "pancake_host_session_break_far_vows") != null) {
            try appendViolation(gpa, violations, "{s}: pancake_host_session_break_far_vows belongs in pump, not session", .{path});
        }
    }

    const park = [_]struct { path: []const u8, inside: []const u8, park: []const u8 }{
        .{ .path = "bindings/ts/stack/session.ts", .inside = "insideTurn", .park = "parkRelease" },
        .{ .path = "bindings/python/pancake/_session.py", .inside = "_inside_turn", .park = "park_release" },
        .{ .path = "bindings/rust/src/session_shared.rs", .inside = "inside_turn", .park = "park_session_release" },
        .{ .path = "bindings/racket/private/session.rkt", .inside = "inside-turn?", .park = "host-park-release!" },
    };
    for (park) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for mid-turn park check with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, row.inside) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — mid-turn park gate", .{ row.path, row.inside });
        }
        if (std.mem.indexOf(u8, contents, row.park) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — mid-turn park gate", .{ row.path, row.park });
        }
        if (std.mem.indexOf(u8, contents, "pancake_host_session_release") == null) {
            try appendViolation(gpa, violations, "{s}: missing pancake_host_session_release — close path", .{row.path});
        }
    }

    const cref = "examples/c/host_embedder_pump.c";
    root.access(io, cref, .{}) catch {
        try appendViolation(gpa, violations, "{s}: file must exist — C reference embedder pump", .{cref});
        return;
    };
    const cref_contents = root.readFileAlloc(io, cref, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for C reference pump check with {s}", .{ cref, @errorName(err) });
        return;
    };
    defer gpa.free(cref_contents);
    for ([_][]const u8{
        "pancake_host_session_feed_bytes",
        "pancake_host_next_action",
        "pancake_host_session_take_outbound",
        "pancake_host_session_last_abort",
        "pancake_host_session_break_far_vows",
    }) |needle| {
        if (std.mem.indexOf(u8, cref_contents, needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — normative embedder choreography", .{ cref, needle });
        }
    }

    // Zig-facing shared drain (ADR-0072 fifth amendment) — authority for the
    // one-loop switch tests rewire onto; must not silently disappear.
    const zig_pump = "src/c_abi/driver/embedder_pump.zig";
    root.access(io, zig_pump, .{}) catch {
        try appendViolation(gpa, violations, "{s}: file must exist — Zig embedder_pump (ADR-0072 fifth)", .{zig_pump});
        return;
    };
    const zig_pump_contents = root.readFileAlloc(io, zig_pump, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for Zig embedder_pump check with {s}", .{ zig_pump, @errorName(err) });
        return;
    };
    defer gpa.free(zig_pump_contents);
    for ([_][]const u8{ "drainHost", "drainHosts", "pancake_host_next_action" }) |needle| {
        if (std.mem.indexOf(u8, zig_pump_contents, needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — shared C-ABI drain helper", .{ zig_pump, needle });
        }
    }

    // The dlopen binding action modules drain via pancake_host_pump_drain
    // (ADR-0072 sixth). Ban hand-rolled pancake_host_next_action pop loops in
    // those modules — the C symbol may still appear in FFI loaders and
    // comments outside action/.
    const action_mods = [_][]const u8{
        "bindings/python/pancake/_action.py",
        "bindings/rust/src/action.rs",
        "bindings/racket/private/action.rkt",
    };
    for (action_mods) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for pump_drain adoption check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "pancake_host_pump_drain") == null) {
            try appendViolation(gpa, violations, "{s}: missing pancake_host_pump_drain — action module must use the shared C drain", .{path});
        }
        if (std.mem.indexOf(u8, contents, "pancake_host_next_action") != null) {
            try appendViolation(gpa, violations, "{s}: pancake_host_next_action in action module — use pancake_host_pump_drain (no hand-rolled pop loop)", .{path});
        }
    }

    // The TypeScript action module is the exception, by contract: it also runs
    // under the wasm adapter (ADR-0070), whose single callback seam is the
    // behavior trampoline, so a hooks-buffer drain cannot exist there. It
    // drains through the canonical pancake_host_next_action pop instead (one
    // spine for dlopen and wasm) and must not mint a per-drain callback.
    {
        const path = "bindings/ts/stack/action.ts";
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for next_action drain check with {s}", .{ path, @errorName(err) });
            return;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "pancake_host_next_action") == null) {
            try appendViolation(gpa, violations, "{s}: missing pancake_host_next_action; the TS action module drains by pop (wasm has no hooks seam)", .{path});
        }
        if (std.mem.indexOf(u8, contents, "pancake_host_pump_drain") != null) {
            try appendViolation(gpa, violations, "{s}: pancake_host_pump_drain in the TS action module; hooks buffers cannot run under the wasm adapter", .{path});
        }
        if (std.mem.indexOf(u8, contents, "makeCallback") != null) {
            try appendViolation(gpa, violations, "{s}: makeCallback in the TS action module; the drain must not mint per-drain native callbacks", .{path});
        }
    }
}

/// Behavior trampoline spine (Pass 5): each binding keeps a named trampoline
/// module, mid-turn latch, reply keep, and turn verbs; hop cap lives in the
/// constant homes (mirrored against PANCAKE_MAX_LOCAL_FORWARD_HOPS).
pub fn checkBindingEmbedderTrampoline(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const mods = [_]struct { path: []const u8, markers: []const []const u8 }{
        .{
            .path = "bindings/ts/stack/trampoline.ts",
            .markers = &.{ "chaseLocalForwards", "runHosted", "sendLocal", "tellLocal", "tellFar", "dispatchSend", "dispatchTell", "caretakerProxy", "attenuateProxy", "spawnHosted", "publishHosted", "function registerActor", "currentTurn", "lastReplyKeep", "pancake_host_turn_break", "pancake_host_turn_forward", "pancake_host_turn_spawn", "MAX_LOCAL_FORWARD_HOPS", "FORWARD_CYCLE_MESSAGE" },
        },
        .{
            .path = "bindings/python/pancake/_trampoline.py",
            .markers = &.{ "_chase_local_forwards", "_run_hosted", "_send_local", "_tell_local", "_tell_far", "_dispatch_send", "_dispatch_tell", "_caretaker_proxy", "_attenuate_proxy", "_spawn_hosted", "_publish_hosted", "def _register_actor", "_current_turn", "_last_reply_keep", "pancake_host_turn_break", "pancake_host_turn_forward", "pancake_host_turn_spawn", "MAX_LOCAL_FORWARD_HOPS", "FORWARD_CYCLE_MESSAGE" },
        },
        .{
            .path = "bindings/rust/src/trampoline.rs",
            .markers = &.{ "chase_local_forwards", "run_hosted", "run_local_send", "caretaker_proxy", "attenuate_proxy", "CURRENT_TURN", "LAST_REPLY_KEEP", "pancake_host_turn_break", "pancake_host_turn_forward", "pancake_host_turn_spawn", "MAX_LOCAL_FORWARD_HOPS", "FORWARD_CYCLE_MESSAGE" },
        },
        .{
            .path = "bindings/racket/private/trampoline.rkt",
            .markers = &.{ "settle-turn-reply", "chase-local-actor-forwards", "session-send-local", "await-local-vow", "dispatch-send", "dispatch-send-promise", "dispatch-tell", "caretaker-behavior", "attenuate-behavior", "caretaker-proxy", "attenuate-proxy", "revoke-caretaker!", "register-hosted-actor!", "pancake_host_session_spawn", "pancake_host_session_publish", "current-turn", "last-reply-keep", "pancake_host_turn_break", "pancake_host_turn_forward", "pancake_host_turn_spawn", "FORWARD-CYCLE-MESSAGE" },
        },
    };
    // Racket's chase lives in vat.rkt (shared by $, drive, and the trampoline).
    {
        const vat_path = "bindings/racket/private/vat.rkt";
        if (root.readFileAlloc(io, vat_path, gpa, .limited(2 << 20))) |contents| {
            defer gpa.free(contents);
            for ([_][]const u8{ "chase-local-actor-forwards", "forward-cycle", "hop-broke", "MAX-LOCAL-FORWARD-HOPS", "FORWARD-CYCLE-MESSAGE" }) |needle| {
                if (std.mem.indexOf(u8, contents, needle) == null) {
                    try appendViolation(gpa, violations, "{s}: missing `{s}` — shared local-forward chase", .{ vat_path, needle });
                }
            }
        } else |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for shared-chase check with {s}", .{ vat_path, @errorName(err) });
        }
    }
    for (mods) |mod| {
        root.access(io, mod.path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — trampoline module (binding spine Pass 5)", .{mod.path});
            continue;
        };
        const contents = root.readFileAlloc(io, mod.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for trampoline-spine check with {s}", .{ mod.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (mod.markers) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: trampoline missing `{s}`", .{ mod.path, needle });
            }
        }
        // Hop cap must come from the constant home, not a raw 256 literal.
        if (std.mem.indexOf(u8, contents, "= 256") != null or
            std.mem.indexOf(u8, contents, "=256") != null or
            std.mem.indexOf(u8, contents, " 256)") != null)
        {
            try appendViolation(gpa, violations, "{s}: raw hop-cap literal — use MAX_LOCAL_FORWARD_HOPS / MAX-LOCAL-FORWARD-HOPS", .{mod.path});
        }
    }

    // Local send/tell arms and ADR-0064 proxy factories live in trampoline
    // (Pass 4c / 4e), not session.
    const banned = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/ts/stack/session.ts", .needle = "#sendLocal" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "throw new Error(\"Revoked\")" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "throw new Error(\"Attenuated\")" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "def _send_local" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "raise ValueError(\"Revoked\")" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "raise ValueError(\"Attenuated\")" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "async fn run_local_send" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "fn run_hosted(" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "Break(\"Revoked\"" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "Break(\"Attenuated\"" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (session-send-local" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (await-local-vow" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(error \"Revoked\")" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(error \"Attenuated\")" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(spawn (caretaker-behavior" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(spawn (attenuate-behavior" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(hash-set! (vat-revocables" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "pancake_host_session_send" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "pancake_host_vow_send" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "pancake_host_session_send" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "pancake_host_vow_send" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "pancake_host_session_spawn" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "pancake_host_session_publish" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "pancake_host_session_spawn" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "pancake_host_session_publish" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "pancake_host_session_spawn" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "pancake_host_session_publish" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (register-hosted-actor!" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "#registerActor" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "def _register_actor" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "class _SessionGcHandle" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "pancake_host_session_tell" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "pancake_host_session_tell" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "pancake_host_vow_index" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "pancake_host_vow_untag" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "return sendLocal(" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "await tellLocal(" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "return sendFar(" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "return _send_local(" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "await _tell_local(" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "return _send_far(" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "await _tell_far(" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "tell_local(" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "tell_wire(" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(session-send-local c" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(apply <-np resolved" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(await-vow c (session-far-send" },
    };
    for (banned) |b| {
        const contents = root.readFileAlloc(io, b.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for trampoline-factory ban with {s}", .{ b.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, b.needle) != null) {
            try appendViolation(gpa, violations, "{s}: `{s}` belongs in promise/trampoline, not session (Pass 4c/4e/4f)", .{ b.path, b.needle });
        }
    }

    // Constant homes must carry the hop cap. The reflected value lives in each
    // binding's generated constant module (`zig build gen-binding-constants`),
    // re-exported through the hand-kept home; the presence check names the
    // generated module that reflects it.
    const const_homes = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/python/pancake/_constants_gen.py", .needle = "MAX_LOCAL_FORWARD_HOPS" },
        .{ .path = "bindings/rust/src/abi_constants_gen.rs", .needle = "MAX_LOCAL_FORWARD_HOPS" },
        .{ .path = "bindings/racket/private/constants-gen.rkt", .needle = "MAX-LOCAL-FORWARD-HOPS" },
        .{ .path = "bindings/ts/abi/constants.ts", .needle = "MAX_LOCAL_FORWARD_HOPS" },
    };
    for (const_homes) |home| {
        const contents = root.readFileAlloc(io, home.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for trampoline hop-cap check with {s}", .{ home.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, home.needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — trampoline hop-cap mirror", .{ home.path, home.needle });
        }
    }

    // C example must exercise the opt-in pump drain.
    const cref = "examples/c/host_embedder_pump.c";
    const cref_contents = root.readFileAlloc(io, cref, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for pump_drain check with {s}", .{ cref, @errorName(err) });
        return;
    };
    defer gpa.free(cref_contents);
    if (std.mem.indexOf(u8, cref_contents, "pancake_host_pump_drain") == null) {
        try appendViolation(gpa, violations, "{s}: missing pancake_host_pump_drain — C checklist must use the opt-in wrapper", .{cref});
    }
}

/// Living-state honesty for the embedder-spine inventory: shipped.md and
/// bindings/README.md must name every Pass-1..5 module, declare the split
/// complete, and name the handshake pump + trampoline / opt-in callback pump.
/// Also refuse the retired Racket API name `set-node-redeem-reachability`
/// anywhere under bindings/ (the live export is `set-host-redeem-reachability!`).
pub fn checkBindingEmbedderSpineDocs(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const docs = [_]struct { path: []const u8, needles: []const []const u8 }{
        .{
            .path = "docs/shipped.md",
            .needles = &.{
                "named `pump`",
                "named `action`",
                "named `promise`",
                "promiseFor",
                "sendFar",
                "named `gc`",
                "named `dial`",
                "named `listen`",
                "embedder-spine module split is complete",
                "trampoline",
                "caretaker",
                "named `session_shared`",
                "embedder_pump",
                "pancake_host_pump_drain",
                "handshake",
            },
        },
        .{
            .path = "bindings/README.md",
            .needles = &.{
                "**pump module**",
                "**action module**",
                "named **promise**",
                "promiseFor",
                "sendFar",
                "**gc** module",
                "named **dial**",
                "named **listen**",
                "**trampoline** module",
                "embedder-spine module split is complete",
                "trampoline",
                "caretaker/attenuate",
                "spawn/publish",
                "**session_shared** module",
                "embedder_pump",
                "pancake_host_pump_drain",
                "handshake",
            },
        },
    };
    for (docs) |doc| {
        const contents = root.readFileAlloc(io, doc.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for embedder-spine doc check with {s}", .{ doc.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (doc.needles) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — embedder-spine living-state inventory", .{ doc.path, needle });
            }
        }
    }

    const banned = "set-node-redeem-reachability";
    const bind_roots = [_][]const u8{
        "bindings/python",
        "bindings/rust/src",
        "bindings/ts",
        "bindings/racket",
        "bindings/README.md",
    };
    const exts = [_][]const u8{ ".py", ".rs", ".ts", ".rkt", ".md" };
    for (bind_roots) |bind_root| {
        if (std.mem.endsWith(u8, bind_root, ".md")) {
            const contents = root.readFileAlloc(io, bind_root, gpa, .limited(2 << 20)) catch continue;
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, banned) != null) {
                try appendViolation(gpa, violations, "{s}: retired API `{s}` — use set-host-redeem-reachability!", .{ bind_root, banned });
            }
            continue;
        }
        var dir = root.openDir(io, bind_root, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            var ok_ext = false;
            for (exts) |ext| {
                if (std.mem.endsWith(u8, entry.path, ext)) {
                    ok_ext = true;
                    break;
                }
            }
            if (!ok_ext) continue;
            const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ bind_root, entry.path });
            defer gpa.free(full);
            const contents = root.readFileAlloc(io, full, gpa, .limited(2 << 20)) catch continue;
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, banned) != null) {
                try appendViolation(gpa, violations, "{s}: retired API `{s}` — use set-host-redeem-reachability!", .{ full, banned });
            }
        }
    }
}

/// Reject numeric error-code literals at binding raise sites. Scans every
/// binding source file (skipping generated trees) for a raise pattern followed
/// by a digit — `from_code(-9)` fails, `from_code(sys::ERR_IO)` passes.
pub fn checkBindingMagicErrorCodes(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "bindings", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "bindings: failed to open for magic-error-code check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOf(u8, entry.path, "target/") != null) continue;
        if (std.mem.indexOf(u8, entry.path, "__pycache__/") != null) continue;
        const is_source = std.mem.endsWith(u8, entry.path, ".rs") or
            std.mem.endsWith(u8, entry.path, ".py") or
            std.mem.endsWith(u8, entry.path, ".ts") or
            std.mem.endsWith(u8, entry.path, ".rkt");
        if (!is_source) continue;
        const path = try std.fmt.allocPrint(gpa, "bindings/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for magic-error-code check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (binding_error_raise_patterns) |pattern| {
            var search: usize = 0;
            while (std.mem.indexOfPos(u8, contents, search, pattern)) |start| {
                search = start + pattern.len;
                if (search >= contents.len) break;
                const c = contents[search];
                if (c < '0' or c > '9') continue;
                const line = 1 + std.mem.count(u8, contents[0..start], "\n");
                try appendViolation(gpa, violations, "{s}:{d}: numeric error code at a raise site (`{s}{c}…`) — name the mirrored ABI constant instead", .{ path, line, pattern, c });
            }
        }
    }
}

/// Map one parameter or return spelling onto the coarse ABI shape. Works on
/// the whole parameter text in all three syntaxes ("size_t out_cap",
/// "out_cap: usize", "node_id: [*]const u8"): any pointer marker wins, then
/// the scalar width tokens. An unmapped spelling classifies `unknown`, which
/// never equals itself across surfaces, new types must be added here
/// consciously, not slip through.
fn classifyAbiType(text: []const u8) CoarseAbiType {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0 or std.mem.eql(u8, t, "void")) return .none;
    if (std.mem.indexOfScalar(u8, t, '*') != null) return .ptr;
    if (std.mem.indexOf(u8, t, "intptr_t") != null) return .iword;
    if (std.mem.indexOf(u8, t, "isize") != null) return .iword;
    if (std.mem.indexOf(u8, t, "size_t") != null) return .word;
    if (std.mem.indexOf(u8, t, "usize") != null) return .word;
    // `uint32_t` contains `int32_t` as a substring, so the unsigned width must
    // be classified before the signed one.
    if (std.mem.indexOf(u8, t, "uint32_t") != null) return .uint32;
    if (std.mem.indexOf(u8, t, "u32") != null) return .uint32;
    if (std.mem.indexOf(u8, t, "int32_t") != null) return .int32;
    if (std.mem.indexOf(u8, t, "i32") != null) return .int32;
    if (std.mem.indexOf(u8, t, "void") != null) return .none;
    return .unknown;
}

/// Render a parameter list and return type as the canonical coarse signature,
/// e.g. `ptr,usize->isize`. Parameter lists in this ABI carry no nested
/// parentheses, so a top-level comma split is exact.
fn renderAbiSig(arena: std.mem.Allocator, params_text: []const u8, ret_text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const trimmed_params = std.mem.trim(u8, params_text, " \t\r\n");
    if (trimmed_params.len != 0 and !std.mem.eql(u8, trimmed_params, "void")) {
        var it = std.mem.splitScalar(u8, trimmed_params, ',');
        var first = true;
        while (it.next()) |param| {
            // Rust's multi-line declarations end with a trailing comma; an
            // empty segment is that comma, not a parameter.
            if (std.mem.trim(u8, param, " \t\r\n").len == 0) continue;
            if (!first) try out.append(arena, ',');
            first = false;
            try out.appendSlice(arena, classifyAbiType(param).label());
        }
    }
    try out.appendSlice(arena, "->");
    try out.appendSlice(arena, classifyAbiType(ret_text).label());
    return out.items;
}

fn isAbiIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
}

/// Extract `pancake_iroh_sidecar_*` declarations behind a fixed anchor —
/// Rust's `pub extern "C" fn ` or Zig's `extern fn ` — into `out` as name ->
/// coarse signature. The return type runs from the closing parenthesis to `{`
/// (Rust, where a leading `->` is stripped) or `;` (Zig).
fn extractAnchoredAbi(
    arena: std.mem.Allocator,
    text: []const u8,
    anchor: []const u8,
    ret_end: u8,
    out: *std.StringHashMap([]const u8),
) !void {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, anchor)) |start| {
        const name_start = start + anchor.len;
        var name_end = name_start;
        while (name_end < text.len and isAbiIdentChar(text[name_end])) name_end += 1;
        search = name_end;
        const name = text[name_start..name_end];
        if (!std.mem.startsWith(u8, name, "pancake_iroh_sidecar_")) continue;
        if (name_end >= text.len or text[name_end] != '(') continue;
        const params_end = std.mem.indexOfScalarPos(u8, text, name_end + 1, ')') orelse continue;
        const ret_stop = std.mem.indexOfScalarPos(u8, text, params_end + 1, ret_end) orelse continue;
        var ret_text = std.mem.trim(u8, text[params_end + 1 .. ret_stop], " \t\r\n");
        if (std.mem.startsWith(u8, ret_text, "->")) ret_text = ret_text[2..];
        const sig = try renderAbiSig(arena, text[name_end + 1 .. params_end], ret_text);
        try out.put(name, sig);
    }
}

/// Extract `pancake_iroh_sidecar_*` declarations from the C header into `out`
/// as name -> coarse signature. Block comments are blanked first so prose
/// mentions of the function names cannot match; a declaration is a
/// `pancake_iroh_sidecar_` identifier directly followed by `(`, with its return
/// type read backward to the previous `;`.
fn extractCHeaderAbi(
    arena: std.mem.Allocator,
    contents: []const u8,
    out: *std.StringHashMap([]const u8),
) !void {
    const text = try arena.dupe(u8, contents);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "/*")) |open| {
        const close = std.mem.indexOfPos(u8, text, open + 2, "*/") orelse break;
        @memset(text[open .. close + 2], ' ');
        i = close + 2;
    }
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, "pancake_iroh_sidecar_")) |start| {
        var name_end = start;
        while (name_end < text.len and isAbiIdentChar(text[name_end])) name_end += 1;
        search = name_end;
        if (start > 0 and isAbiIdentChar(text[start - 1])) continue;
        if (name_end >= text.len or text[name_end] != '(') continue;
        const params_end = std.mem.indexOfScalarPos(u8, text, name_end + 1, ')') orelse continue;
        const ret_start = if (std.mem.lastIndexOfScalar(u8, text[0..start], ';')) |semi| semi + 1 else 0;
        const sig = try renderAbiSig(arena, text[name_end + 1 .. params_end], text[ret_start..start]);
        try out.put(text[start..name_end], sig);
    }
}

/// Find the `{ ... }` block opened by the `{`-terminated `marker`, matching
/// braces so a nested struct literal inside the block cannot close it early.
/// Returns the interior (excluding the outer braces), or `null` when the
/// marker is absent or its brace never closes.
fn extractBraceBlock(text: []const u8, marker: []const u8) ?[]const u8 {
    std.debug.assert(std.mem.endsWith(u8, marker, "{"));
    const start = std.mem.indexOf(u8, text, marker) orelse return null;
    const open = start + marker.len - 1;
    var depth: usize = 1;
    var i = open + 1;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return text[open + 1 .. i];
            },
            else => {},
        }
    }
    return null;
}

/// The first quoted string in `text` starting at `from`, or null when none
/// remains. Returns the bytes between the quotes.
fn nextQuotedString(text: []const u8, from: usize) ?[]const u8 {
    const open = std.mem.indexOfScalarPos(u8, text, from, '"') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, text, open + 1, '"') orelse return null;
    return text[open + 1 .. close];
}

/// Hold the three hand-spelled surfaces of the iroh sidecar C ABI (ADR-0055)
/// to the same function set, arity, and coarse type shape.
pub fn checkIrohSidecarAbi(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const surfaces = [_]struct { path: []const u8, anchor: ?[]const u8, ret_end: u8 }{
        .{ .path = "transports/iroh/src/lib.rs", .anchor = "pub extern \"C\" fn ", .ret_end = '{' },
        .{ .path = "transports/iroh/include/pancake_iroh_sidecar.h", .anchor = null, .ret_end = ';' },
        .{ .path = "src/net/transport/iroh.zig", .anchor = "extern fn ", .ret_end = ';' },
    };
    var maps: [surfaces.len]std.StringHashMap([]const u8) = undefined;
    for (surfaces, 0..) |surface, idx| {
        maps[idx] = std.StringHashMap([]const u8).init(arena);
        const contents = root.readFileAlloc(io, surface.path, arena, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for iroh ABI parity with {s}", .{ surface.path, @errorName(err) });
            return;
        };
        if (surface.anchor) |anchor| {
            try extractAnchoredAbi(arena, contents, anchor, surface.ret_end, &maps[idx]);
        } else {
            try extractCHeaderAbi(arena, contents, &maps[idx]);
        }
        if (maps[idx].count() == 0) {
            try appendViolation(gpa, violations, "{s}: found no pancake_iroh_sidecar_ declarations, the ABI parity scanner no longer matches this surface", .{surface.path});
            return;
        }
    }

    var names = std.StringHashMap(void).init(arena);
    for (&maps) |*map| {
        var it = map.keyIterator();
        while (it.next()) |key| try names.put(key.*, {});
    }
    var name_it = names.keyIterator();
    while (name_it.next()) |key| {
        const name = key.*;
        var sigs: [surfaces.len]?[]const u8 = undefined;
        for (&maps, 0..) |*map, idx| sigs[idx] = map.get(name);
        for (surfaces, sigs) |surface, sig| {
            if (sig == null) {
                try appendViolation(gpa, violations, "{s}: iroh sidecar ABI function `{s}` is missing from this surface", .{ surface.path, name });
            }
        }
        const reference = sigs[0] orelse continue;
        for (surfaces[1..], sigs[1..]) |surface, sig| {
            const other = sig orelse continue;
            if (!std.mem.eql(u8, reference, other)) {
                try appendViolation(gpa, violations, "{s}: `{s}` is `{s}` here but `{s}` in {s}", .{ surface.path, name, other, reference, surfaces[0].path });
            }
        }
    }
}

/// ADR-0055 commits the sidecar to reproducible dependency resolution: the
/// crate wraps an external network stack, so `transports/iroh/Cargo.lock` is
/// checked in and every direct dependency in its `Cargo.toml` is pinned to an
/// exact `=x.y.z` version, making an intentional bump visible in the manifest
/// rather than only in the lockfile. This check holds both halves so the
/// discipline cannot drift off silently when a dependency is added or edited.
pub fn checkIrohSidecarPins(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    root.access(io, "transports/iroh/Cargo.lock", .{}) catch {
        try appendViolation(gpa, violations, "transports/iroh/Cargo.lock: missing, the sidecar lockfile is deliberately committed (ADR-0055) so iroh gates resolve the same dependency tree on every machine", .{});
    };

    const manifest_path = "transports/iroh/Cargo.toml";
    const contents = root.readFileAlloc(io, manifest_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for sidecar pin check with {s}", .{ manifest_path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var pins_seen: usize = 0;
    var in_dep_section = false;
    var in_dotted_dep_table = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            // Every dependency table carries the word: `[dependencies]`,
            // `[dev-dependencies]`, `[build-dependencies]`, dotted and
            // target-specific forms alike.
            in_dep_section = std.mem.indexOf(u8, line, "dependencies") != null;
            // In a dotted table like `[dependencies.iroh]` the dependency is
            // the table itself, so only its `version` key carries the pin.
            in_dotted_dep_table = in_dep_section and std.mem.indexOf(u8, line, "dependencies.") != null;
            continue;
        }
        if (!in_dep_section) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (in_dotted_dep_table and !std.mem.eql(u8, key, "version")) continue;
        // An inline table names its version explicitly; a plain string dep is
        // the version itself. Anything else (git, path, no version) escapes
        // the registry pin and fails the same way.
        const version = if (std.mem.indexOf(u8, line, "version")) |v|
            nextQuotedString(line, v)
        else
            nextQuotedString(line, eq);
        const pinned = if (version) |spec| spec.len > 1 and spec[0] == '=' else false;
        if (!pinned) {
            try appendViolation(gpa, violations, "{s}: dependency `{s}` is not pinned to an exact `=x.y.z` version — the sidecar's direct dependencies are pinned exactly (ADR-0055)", .{ manifest_path, key });
            continue;
        }
        pins_seen += 1;
    }
    if (pins_seen == 0) {
        try appendViolation(gpa, violations, "{s}: found no pinned dependencies — the sidecar pin scanner no longer matches this manifest", .{manifest_path});
    }
}
