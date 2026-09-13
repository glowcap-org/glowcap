//! The reflected FFI surface: every reflected symbol wired in each binding,
//! the coarse ABI-signature parity between hand-spelled sidecar surfaces,
//! sidecar steady-byte pins, and sidecar constant pins.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const containsAsSymbol = util.containsAsSymbol;
const extractBraceBlock = util.extractBraceBlock;

/// The iroh sidecar C ABI is spelled four times by hand — the Rust
/// definitions (`transports/iroh/src/lib.rs`), the C header
/// (`transports/iroh/include/glowcap_iroh_sidecar.h`), the Zig transport's
/// externs (`src/net/transport/iroh/sidecar.zig`), and the hermetic linker stub
/// (`tools/gen/stub/iroh_sidecar.zig`) — and the hermetic gate never links the
/// real sidecar, so a
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

/// One binding's generated driver FFI table and where its hand code lives. The
/// table `gen_ffi` declares every `glowcap_host_*` extern the binding can call;
/// a `glowcap_host_*` symbol that appears nowhere else in the binding's tree is
/// reflected but dead.
const ReflectedFfiBinding = struct {
    name: []const u8,
    /// The binding's subtree under `bindings/`, matched as an `entry.path` prefix.
    prefix: []const u8,
    /// The generated driver FFI declaration file, relative to `bindings/`. It is
    /// skipped while scanning for use: it declares the symbols, it does not wire
    /// them.
    gen_ffi: []const u8,
};

const reflected_ffi_bindings = [_]ReflectedFfiBinding{
    .{ .name = "rust", .prefix = "rust/", .gen_ffi = "rust/src/sys/host_fns_gen.rs" },
    .{ .name = "python", .prefix = "python/", .gen_ffi = "python/glowcap/_sigs_gen.py" },
    .{ .name = "ts", .prefix = "ts/", .gen_ffi = "ts/runtime/internal/ffi/host.ts" },
    .{ .name = "racket", .prefix = "racket/", .gen_ffi = "racket/private/ffi-host-gen.rkt" },
};

/// A driver FFI symbol reflected into a binding but deliberately not wired there,
/// named with the reason so the state reads as a decision rather than the
/// oversight a silently-dead generated symbol otherwise would.
const DeclaredDeferredFfi = struct {
    binding: []const u8,
    symbol: []const u8,
    reason: []const u8,
};

const declared_deferred_ffi = [_]DeclaredDeferredFfi{
    .{
        .binding = "rust",
        .symbol = "glowcap_host_session_take_outbound",
        .reason = "Rust uses take_packet for both stream and message transports. The reflected C ABI retains the narrower stream-only entry for its other consumers.",
    },
};

fn declaredDeferredReason(binding: []const u8, symbol: []const u8) ?[]const u8 {
    for (declared_deferred_ffi) |d| {
        if (std.mem.eql(u8, d.binding, binding) and std.mem.eql(u8, d.symbol, symbol)) return d.reason;
    }
    return null;
}

/// One reflected driver symbol and whether the binding wires it anywhere.
const ReflectedSymbol = struct { name: []const u8, seen: bool = false };

/// Every `glowcap_host_*` symbol a binding's generated driver FFI table declares
/// must be wired by that binding (referenced somewhere outside the declaration
/// file) or listed in `declared_deferred_ffi` with a reason. A symbol reflected
/// into the table but called nowhere is dead generated FFI: a capability the C
/// ABI hands the binding that the binding silently never exposes, and a
/// per-binding product gap the presence-needle checks above cannot see (the
/// module and its markers are all still there). A declared-deferred symbol that
/// becomes wired must drop its allowlist row, so the allowlist cannot rot into
/// rent.
pub fn checkBindingReflectedFfiWired(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var per_binding: [reflected_ffi_bindings.len]std.ArrayList(ReflectedSymbol) = undefined;
    for (&per_binding) |*p| p.* = .empty;
    defer for (&per_binding) |*p| {
        for (p.items) |e| gpa.free(e.name);
        p.deinit(gpa);
    };

    // 1. Collect the declared `glowcap_host_*` symbols per binding, from its
    //    generated driver FFI table.
    for (reflected_ffi_bindings, 0..) |b, bi| {
        const gen_path = try std.fmt.allocPrint(gpa, "bindings/{s}", .{b.gen_ffi});
        defer gpa.free(gen_path);
        const gen = root.readFileAlloc(io, gen_path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read generated FFI table for reflected-wired check with {s}", .{ gen_path, @errorName(err) });
            continue;
        };
        defer gpa.free(gen);
        const needle = "glowcap_host_";
        var rest = gen;
        while (std.mem.indexOf(u8, rest, needle)) |start| {
            const after = rest[start..];
            var end: usize = needle.len;
            while (end < after.len) : (end += 1) {
                const c = after[end];
                if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_')) break;
            }
            const sym = after[0..end];
            rest = after[end..];
            var already = false;
            for (per_binding[bi].items) |e| {
                if (std.mem.eql(u8, e.name, sym)) {
                    already = true;
                    break;
                }
            }
            if (!already) {
                // TypeScript's generated lazy loader is both declaration and
                // load policy: the fingerprint name appears once in the table
                // and once in the pre-call compatibility configuration. Other
                // generated symbols still need a hand-written consumer.
                const checked_in_loader = std.mem.endsWith(u8, sym, "_archive_fingerprint") and
                    std.mem.count(u8, gen, sym) > 1;
                try per_binding[bi].append(gpa, .{
                    .name = try gpa.dupe(u8, sym),
                    .seen = checked_in_loader,
                });
            }
        }
    }

    // 2. Walk the binding sources; a symbol is wired once it appears in any file
    //    other than its own declaration table.
    var dir = root.openDir(io, "bindings", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "bindings: failed to open for reflected-wired check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            try util.enterSourceDirectory(io, gpa, &walker, "bindings", entry);
            continue;
        }
        if (entry.kind != .file) continue;
        const is_source = std.mem.endsWith(u8, entry.path, ".rs") or
            std.mem.endsWith(u8, entry.path, ".py") or
            std.mem.endsWith(u8, entry.path, ".ts") or
            std.mem.endsWith(u8, entry.path, ".rkt");
        if (!is_source) continue;
        var bi_opt: ?usize = null;
        for (reflected_ffi_bindings, 0..) |b, bi| {
            if (std.mem.startsWith(u8, entry.path, b.prefix)) {
                bi_opt = bi;
                break;
            }
        }
        const bi = bi_opt orelse continue;
        if (std.mem.eql(u8, entry.path, reflected_ffi_bindings[bi].gen_ffi)) continue;
        const path = try std.fmt.allocPrint(gpa, "bindings/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for reflected-wired check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (per_binding[bi].items) |*e| {
            if (!e.seen and std.mem.indexOf(u8, contents, e.name) != null) e.seen = true;
        }
    }

    // 3. Every declared symbol is wired or declared-deferred; a declared-deferred
    //    symbol that is now wired must drop its allowlist row.
    for (reflected_ffi_bindings, 0..) |b, bi| {
        for (per_binding[bi].items) |e| {
            const deferred = declaredDeferredReason(b.name, e.name);
            if (e.seen) {
                if (deferred != null) {
                    try appendViolation(gpa, violations, "binding_spine.zig: `{s}` is now wired in the {s} binding but still listed declared-deferred; drop the allowlist row", .{ e.name, b.name });
                }
            } else if (deferred == null) {
                try appendViolation(gpa, violations, "bindings/{s}: `{s}` is reflected into the generated driver FFI table but wired nowhere in the binding; wire it or add a declared-deferred row (with a reason) in binding_spine.zig", .{ b.name, e.name });
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

/// Extract `glowcap_iroh_sidecar_*` declarations behind a fixed anchor —
/// Rust's `extern "C" fn ` (safe or unsafe) or Zig's `extern fn ` — into `out` as name ->
/// coarse signature. The return type runs from the closing parenthesis to `{`
/// (Rust, where a leading `->` is stripped) or `;` (Zig).
fn extractAnchoredAbi(
    arena: std.mem.Allocator,
    text: []const u8,
    anchor: []const u8,
    ret_end: u8,
    prefix: []const u8,
    out: *std.StringHashMap([]const u8),
) !void {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, anchor)) |start| {
        const name_start = start + anchor.len;
        var name_end = name_start;
        while (name_end < text.len and isAbiIdentChar(text[name_end])) name_end += 1;
        search = name_end;
        const name = text[name_start..name_end];
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        if (name_end >= text.len or text[name_end] != '(') continue;
        const params_end = std.mem.indexOfScalarPos(u8, text, name_end + 1, ')') orelse continue;
        const ret_stop = std.mem.indexOfScalarPos(u8, text, params_end + 1, ret_end) orelse continue;
        var ret_text = std.mem.trim(u8, text[params_end + 1 .. ret_stop], " \t\r\n");
        if (std.mem.startsWith(u8, ret_text, "->")) ret_text = ret_text[2..];
        const sig = try renderAbiSig(arena, text[name_end + 1 .. params_end], ret_text);
        try out.put(name, sig);
    }
}

/// Extract `glowcap_iroh_sidecar_*` declarations from the C header into `out`
/// as name -> coarse signature. Block comments are blanked first so prose
/// mentions of the function names cannot match; a declaration is a
/// `glowcap_iroh_sidecar_` identifier directly followed by `(`, with its return
/// type read backward to the previous `;`.
fn extractCHeaderAbi(
    arena: std.mem.Allocator,
    contents: []const u8,
    prefix: []const u8,
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
    while (std.mem.indexOfPos(u8, text, search, prefix)) |start| {
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

/// The first quoted string in `text` starting at `from`, or null when none
/// remains. Returns the bytes between the quotes.
fn nextQuotedString(text: []const u8, from: usize) ?[]const u8 {
    const open = std.mem.indexOfScalarPos(u8, text, from, '"') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, text, open + 1, '"') orelse return null;
    return text[open + 1 .. close];
}

/// One hand-spelled surface of a sidecar C ABI: its files (a Rust surface may
/// spread its exports across subject modules), the anchor before each
/// declaration (`null` for a C header, read backward to the previous `;`), and
/// the char the return type runs to. Diagnostics name a surface by its first
/// file.
const SidecarAbiSurface = struct { paths: []const []const u8, anchor: ?[]const u8, ret_end: u8 };

/// Hold every hand-spelled surface of a sidecar C ABI to the same function set,
/// arity, and coarse type shape. `prefix` is the shared symbol prefix
/// (`glowcap_iroh_sidecar_`, `glowcap_webrtc_sidecar_`); `label` names the
/// sidecar in the diagnostics. The iroh and webrtc checks are thin callers of
/// this one spine.
fn checkSidecarAbiParity(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    label: []const u8,
    prefix: []const u8,
    surfaces: []const SidecarAbiSurface,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const maps = try arena.alloc(std.StringHashMap([]const u8), surfaces.len);
    for (surfaces, 0..) |surface, idx| {
        maps[idx] = std.StringHashMap([]const u8).init(arena);
        for (surface.paths) |path| {
            const contents = root.readFileAlloc(io, path, arena, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for {s} ABI parity with {s}", .{ path, label, @errorName(err) });
                return;
            };
            if (surface.anchor) |anchor| {
                try extractAnchoredAbi(arena, contents, anchor, surface.ret_end, prefix, &maps[idx]);
            } else {
                try extractCHeaderAbi(arena, contents, prefix, &maps[idx]);
            }
        }
        if (maps[idx].count() == 0) {
            try appendViolation(gpa, violations, "{s}: found no {s} declarations, the {s} ABI parity scanner no longer matches this surface", .{ surface.paths[0], prefix, label });
            return;
        }
    }

    var names = std.StringHashMap(void).init(arena);
    for (maps) |*map| {
        var it = map.keyIterator();
        while (it.next()) |key| try names.put(key.*, {});
    }
    var name_it = names.keyIterator();
    while (name_it.next()) |key| {
        const name = key.*;
        for (surfaces, maps) |surface, *map| {
            if (map.get(name) == null) {
                try appendViolation(gpa, violations, "{s}: {s} sidecar ABI function `{s}` is missing from this surface", .{ surface.paths[0], label, name });
            }
        }
        const reference = maps[0].get(name) orelse continue;
        for (surfaces[1..], maps[1..]) |surface, *map| {
            const other = map.get(name) orelse continue;
            if (!std.mem.eql(u8, reference, other)) {
                try appendViolation(gpa, violations, "{s}: `{s}` is `{s}` here but `{s}` in {s}", .{ surface.paths[0], name, other, reference, surfaces[0].paths[0] });
            }
        }
    }
}

/// Hold the three hand-spelled surfaces of the iroh sidecar C ABI (ADR-0055)
/// to the same function set, arity, and coarse type shape.
pub fn checkIrohSidecarAbi(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try checkSidecarAbiParity(io, gpa, root, violations, "iroh", "glowcap_iroh_sidecar_", &.{
        .{
            .paths = &.{
                "transports/iroh/src/lib.rs",
                "transports/iroh/src/connect.rs",
                "transports/iroh/src/conn.rs",
                "transports/iroh/src/nonblocking.rs",
            },
            .anchor = "extern \"C\" fn ",
            .ret_end = '{',
        },
        .{ .paths = &.{"transports/iroh/include/glowcap_iroh_sidecar.h"}, .anchor = null, .ret_end = ';' },
        .{ .paths = &.{"src/net/transport/iroh/sidecar.zig"}, .anchor = "pub extern fn ", .ret_end = ';' },
        .{ .paths = &.{"tools/gen/stub/iroh_sidecar.zig"}, .anchor = "export fn ", .ret_end = '{' },
    });

    // Function parity sees the config as one pointer. Pin the pointed-to
    // representation separately so adding an endpoint knob cannot make a
    // shorter C caller or hermetic stub read beyond its object.
    try expectFileContains(io, gpa, root, violations, "transports/iroh/include/glowcap_iroh_sidecar.h", &.{
        "typedef struct glowcap_iroh_sidecar_endpoint_config {\n  uint32_t reachability;\n  uint64_t connect_timeout_ms;\n  uint64_t idle_timeout_ms;\n  uint32_t worker_threads;\n} glowcap_iroh_sidecar_endpoint_config;",
    });
    try expectFileContains(io, gpa, root, violations, "src/net/transport/iroh/sidecar.zig", &.{
        "pub const CEndpointConfig = extern struct {\n    reachability: u32,\n    connect_timeout_ms: u64,\n    idle_timeout_ms: u64,\n    worker_threads: u32,\n};",
    });
    try expectFileContains(io, gpa, root, violations, "tools/gen/stub/iroh_sidecar.zig", &.{
        "const EndpointConfig = extern struct {\n    reachability: u32,\n    connect_timeout_ms: u64,\n    idle_timeout_ms: u64,\n    worker_threads: u32,\n};",
    });
    try expectFileContains(io, gpa, root, violations, "transports/iroh/src/lib.rs", &.{
        "pub reachability: u32,\n\t/// Stream-establishment deadline in milliseconds, 0 for the default.\n\tpub connect_timeout_ms: u64,",
        "pub idle_timeout_ms: u64,\n\t/// Worker threads for this endpoint's runtime; 0 takes `WORKER_THREADS`.\n\tpub worker_threads: u32,",
    });
}

/// Hold the two hand-spelled surfaces of the webrtc sidecar C ABI (ADR-0089) to
/// the same function set, arity, and coarse type shape. The webrtc sidecar has no
/// private C header (its resident's `extern fn` block is the only C-side spelling
/// besides the Rust exports), so it is a two-surface parity, not three.
pub fn checkWebrtcSidecarAbi(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try checkSidecarAbiParity(io, gpa, root, violations, "webrtc", "glowcap_webrtc_sidecar_", &.{
        .{
            .paths = &.{
                "transports/webrtc/src/lib.rs",
                "transports/webrtc/src/signaling.rs",
                "transports/webrtc/src/conn.rs",
            },
            .anchor = "extern \"C\" fn ",
            .ret_end = '{',
        },
        .{ .paths = &.{"src/net/transport/webrtc/sidecar.zig"}, .anchor = "extern fn ", .ret_end = ';' },
    });
}

/// Hold the steady-buffer bound the Zig loop keeps and the Rust sidecar mirrors.
///
/// Both sides retain the same per-connection steady capacity and free the
/// burst above it (ADR-0042's posture, ADR-0057's sidecar). The two constants
/// live in different languages, so the 500k footprint budget could split
/// between them silently without the generated mirror: the sidecar's buffer is
/// per-connection too, and a number raised on one side is a withdrawal the
/// ladder never sees.
pub fn checkSidecarSteadyBytes(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const zig_path = "src/net/frame_stream.zig";
    const rust_path = "transports/iroh/src/lib.rs";
    const gen_path = "tools/gen/iroh_sidecar_constants.zig";
    const constants_path = "transports/iroh/src/constants_gen.rs";
    const zig_needle = "pub const steady_outbound_bytes: usize = 16 * 1024;";

    if (root.readFileAlloc(io, zig_path, gpa, .limited(1 << 20))) |contents| {
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, zig_needle) == null) {
            try appendViolation(gpa, violations, "{s}: `steady_outbound_bytes` moved off 16 KiB; re-weigh the ladder's per-connection budget and regenerate {s}", .{ zig_path, constants_path });
        }
    } else |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for steady-bytes parity with {s}", .{ zig_path, @errorName(err) });
    }

    try expectFileContains(io, gpa, root, violations, gen_path, &.{
        "const frame_stream = @import(\"frame_stream\");",
        "const steady_outbound_bytes = comptime frame_stream.steady_outbound_bytes;",
        "\\\\pub(crate) const NB_STEADY_BYTES: usize = {d};",
    });
    try expectFileContains(io, gpa, root, violations, constants_path, &.{
        "GENERATED by `zig build gen-iroh-sidecar-constants` from",
        "src/net/transport/iroh/policy.zig and src/net/frame_stream.zig.",
        "pub(crate) const NB_STEADY_BYTES: usize =",
    });
    try expectFileContains(io, gpa, root, violations, rust_path, &.{
        "const NB_STEADY_BYTES: usize = constants_gen::NB_STEADY_BYTES;",
    });
}

/// Iroh accepts are produced in the Rust sidecar and consumed by the Zig
/// completion backend. One policy value owns both queues so an accept-burst
/// footprint change cannot land on only one side of the sidecar seam.
pub fn checkIrohAcceptQueueBound(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try expectFileContains(io, gpa, root, violations, "src/net/transport/iroh/policy.zig", &.{
        "pub const accept_queue_bound: usize = 128;",
        "pub const read_chunk_bytes: usize = 64 * 1024;",
    });
    try expectFileContains(io, gpa, root, violations, "src/net/transport/iroh/backend.zig", &.{
        "const max_accept_stash = policy.accept_queue_bound;",
    });
    try expectFileContains(io, gpa, root, violations, "transports/iroh/src/constants_gen.rs", &.{
        "GENERATED by `zig build gen-iroh-sidecar-constants` from",
        "pub(crate) const ACCEPT_QUEUE_BOUND: usize =",
        "pub(crate) const READ_CHUNK_BYTES: usize =",
    });
    try expectFileContains(io, gpa, root, violations, "transports/iroh/src/lib.rs", &.{
        "mod constants_gen;",
        "const ACCEPT_QUEUE_BOUND: usize = constants_gen::ACCEPT_QUEUE_BOUND;",
        "const READ_CHUNK_BYTES: usize = constants_gen::READ_CHUNK_BYTES;",
    });
}

/// The sidecar crates held to exact pins and a committed lockfile. The iroh
/// sidecar wraps an external network stack (ADR-0055); the shared runtime
/// crate carries the tokio pin both sidecars build against and is tested on
/// its own with `--locked`.
const pinned_sidecar_crates = [_]struct { manifest: []const u8, lockfile: []const u8 }{
    .{ .manifest = "transports/iroh/Cargo.toml", .lockfile = "transports/iroh/Cargo.lock" },
    .{ .manifest = "transports/sidecar-common/Cargo.toml", .lockfile = "transports/sidecar-common/Cargo.lock" },
};

/// ADR-0055 commits the sidecar to reproducible dependency resolution: the
/// crate's `Cargo.lock` is checked in and every direct dependency in its
/// `Cargo.toml` is pinned to an exact `=x.y.z` version, making an intentional
/// bump visible in the manifest rather than only in the lockfile. This check
/// holds both halves for every crate in `pinned_sidecar_crates`, so the
/// discipline cannot drift off silently when a dependency is added or edited.
pub fn checkSidecarPins(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (pinned_sidecar_crates) |sidecar| {
        try checkCratePins(io, gpa, root, violations, sidecar.manifest, sidecar.lockfile);
    }
}

fn checkCratePins(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    manifest_path: []const u8,
    lockfile_path: []const u8,
) !void {
    root.access(io, lockfile_path, .{}) catch {
        try appendViolation(gpa, violations, "{s}: missing, the sidecar lockfile is deliberately committed (ADR-0055) so its gates resolve the same dependency tree on every machine", .{lockfile_path});
    };

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
