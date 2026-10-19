//! The browser binding's WebAssembly entry surface (ADR-0034).
//!
//! A freestanding `wasm32` module that exposes the byte-fed CapTP Host
//! (`libglowcap_host`, ADR-0022) and the shared `libglowcap_ocapn` vocabulary
//! to a JavaScript host that instantiates it in a browser. The Host is sans-io
//! and draws no entropy, so the browser drives it as a C embedder does:
//! feed inbound frames, drain outbound frames, honor the action queue, and
//! answer the two entropy seams, the `glowcap_host_new` seed and the
//! NEED_GIFT_ID action, from `crypto.getRandomValues`.
//!
//! This root exists only to force the `glowcap_*` (ocapn) and `glowcap_host_*`
//! export families into the wasm module and to add the two JS<->wasm linear-
//! memory primitives below, so the host can place `ptr + len` inputs into wasm
//! memory and reclaim them. It declares no CapTP surface of its own: every
//! capability decision stays in the core.

pub const std_options = @import("c_abi_shared").library_options;

const std = @import("std");
const shared = @import("c_abi_shared");
const driver = @import("c_abi_host");

comptime {
    // Pull both export families into the wasm module: the shared ocapn
    // vocabulary/uri/frame/peer surface and the byte-fed host family. The
    // library allocator resolves to the single-threaded wasm allocator on this
    // target (see `c_abi_shared.library_allocator`), so `glowcap_host_new`
    // works here without a caller-supplied `GlowcapContext`.
    const ocapn = @import("c_abi");
    for (ocapn.symbols.symbols) |symbol| _ = @field(ocapn, symbol.name);
    for (driver.symbols.symbols) |symbol| @export(&@field(driver, symbol.name), .{ .name = symbol.name });
}

/// Allocate `len` bytes in wasm linear memory and return the offset (0 on
/// failure or an empty request), from the same heap the library allocates its
/// handles on. The JS host writes an input here, passes `ptr + len` to a
/// `glowcap_*` call, then frees it with `glowcap_wasm_free` once the call
/// returns. The caller tracks `len`. Free must pass the same value.
///
/// The returned offset is 8-aligned, because an input the library reads as
/// words (a `GLOWCAP_ARG_INTEGERS` run) must be, and an out-parameter struct
/// such as `GlowcapManagedFrame` lands on its own alignment.
export fn glowcap_wasm_alloc(len: usize) usize {
    if (len == 0) return 0;
    const buf = shared.library_allocator.alignedAlloc(u8, wasm_block_alignment, len) catch return 0;
    return @intFromPtr(buf.ptr);
}

const wasm_block_alignment: std.mem.Alignment = .@"8";

/// Free a block from `glowcap_wasm_alloc`. `ptr`/`len` must match the values the
/// allocation returned and requested. A zero pointer or length is a no-op.
export fn glowcap_wasm_free(ptr: usize, len: usize) void {
    if (ptr == 0 or len == 0) return;
    const p: [*]align(wasm_block_alignment.toByteUnits()) u8 = @ptrFromInt(ptr);
    shared.library_allocator.free(p[0..len]);
}

// ── Layout self-description ──────────────────────────────────────────────
// The JS marshaller reads C structs by byte offset, and those offsets are
// target-specific: wasm32 pointers and `usize` are four bytes, so the layout
// differs from the 64-bit host mirror the generated `abi.ts` carries. Hand-copying
// the wasm32 numbers into JavaScript would reintroduce the untrustworthy mirror
// `abi.ts` exists to remove, for the one target `abi.ts` cannot reach. The
// module reports its own layout, reflected at the wasm32 target the browser
// loads. A field reorder regenerates these values instead of
// silently invalidating a copied constant.

/// FNV-1a over the spec name, the struct-identity word the descriptor leads
/// each block with. The JS decoders recompute it from the manifest prefix.
fn nameHash(comptime name: []const u8) u32 {
    var hash: u32 = 2166136261;
    for (name) |ch| {
        hash ^= ch;
        hash *%= 16777619;
    }
    return hash;
}

/// The structs `glowcap_wasm_abi_layout` reports, in canonical order. The
/// descriptor's blob is these structs concatenated in this exact order, and the
/// JS marshaller keys on this index.
///
/// The table itself lives in `c_abi_host` (`wasm_layout_manifest`), the one
/// authority this exporter and the TypeScript-manifest generator both walk,
/// so a struct cannot reach one mirror and miss the other. `zig build
/// wasm-abi-layout-check` still proves the built module against the
/// generated manifest end to end.
const layout_specs = driver.wasm_layout_manifest;

/// Total u32 words the descriptor writes: per struct, three header words
/// (name hash, size, field count) plus one offset word per field.
const layout_word_count: u32 = blk: {
    var n: u32 = 0;
    for (layout_specs) |spec| n += 3 + @typeInfo(spec.T).@"struct".field_names.len;
    break :blk n;
};

/// Report this module's wasm32 struct layout into `out` as little-endian u32
/// words and return the total word count the full descriptor needs.
///
/// The blob is `layout_specs` concatenated in canonical order. Each struct
/// contributes `[ name_hash, @sizeOf, field_count, off_0, … ]`: the FNV-1a
/// hash of its manifest prefix, then the size, the field count, and the
/// offsets in struct-declaration order. The return value is always the full
/// word count. When `cap` is smaller than that the descriptor writes nothing,
/// so a caller probes the size with `cap == 0` (a null `out` is fine then),
/// allocates `count * 4` bytes, and calls again.
export fn glowcap_wasm_abi_layout(out: [*]u32, cap: u32) u32 {
    if (cap < layout_word_count) return layout_word_count;
    var i: usize = 0;
    inline for (layout_specs) |spec| {
        const fields = @typeInfo(spec.T).@"struct".field_names;
        out[i] = comptime nameHash(spec.prefix);
        i += 1;
        out[i] = @sizeOf(spec.T);
        i += 1;
        out[i] = fields.len;
        i += 1;
        inline for (fields) |field_name| {
            out[i] = @offsetOf(spec.T, field_name);
            i += 1;
        }
    }
    return layout_word_count;
}

/// Report optional Loam layouts without changing the Host descriptor. Rust
/// consumers link the separate Loam archive. JavaScript loads only this type
/// description and fingerprint until it opts into a Loam execution front.
export fn glowcap_wasm_loam_abi_layout(out: [*]u32, cap: u32) u32 {
    const loam = @import("c_abi_loam");
    const count = comptime blk: {
        var n: u32 = 0;
        for (loam.contract_layouts) |spec| n += 3 + @typeInfo(spec.Type).@"struct".field_names.len;
        break :blk n;
    };
    if (cap < count) return count;
    var i: usize = 0;
    inline for (loam.contract_layouts) |spec| {
        const fields = @typeInfo(spec.Type).@"struct".field_names;
        out[i] = comptime nameHash(spec.stem);
        out[i + 1] = @sizeOf(spec.Type);
        out[i + 2] = fields.len;
        i += 3;
        inline for (fields) |field| {
            out[i] = @offsetOf(spec.Type, field);
            i += 1;
        }
    }
    return count;
}
export fn glowcap_wasm_loam_archive_fingerprint() u64 {
    return @import("c_abi_loam").GLOWCAP_LOAM_ARCHIVE_FINGERPRINT;
}

// ── Hosted-object callback seams ────────────────────────────────────────────
// A hosted object's behavior is a C function pointer (`GlowcapHostBehavior`)
// the vat calls on every deliver. A browser cannot hand wasm a distinct C
// function pointer per object, so every wasm-hosted object registers this one
// shared imported trampoline as its behavior and tells objects apart by the
// `ctx` argument. The JavaScript adapter supplies the behavior import and a
// separately typed hosted-free import. The latter drops the JS registry row
// exactly when the Zig actor loses its final root; retaining every displaced
// publication until Host close would turn alias churn into an unbounded leak.
// These are adapter seams only: the module adds no CapTP semantics, and the
// ctx→object ownership stays in the browser adapter (ADR-0034 Milestone 1).

/// The one behavior trampoline the browser adapter implements. Its signature
/// mirrors `GlowcapHostBehavior`. On wasm32 every pointer and `usize`
/// is an `i32`, so the seven parameters and the `i32` result are all `i32` on
/// the wire. The vat calls it through the same fn-pointer path a Zig host
/// uses. The vat borrows `verb`/`args` for the call and copies `out_reply`'s
/// payload the instant the trampoline returns, so the adapter keeps those bytes
/// valid across the return. Any non-OK return settles the answer broken.
extern "env" fn glowcap_behavior_trampoline(
    ctx: ?*anyopaque,
    turn: ?*driver.GlowcapHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const shared.GlowcapArgument,
    args_len: usize,
    out_reply: *shared.GlowcapArgument,
) callconv(.c) i32;

/// Notify the JavaScript adapter that Zig ownership of a hosted behavior
/// ended. Its signature mirrors `GlowcapHostCtxFree`.
extern "env" fn glowcap_hosted_free_trampoline(ctx: ?*anyopaque) callconv(.c) void;

/// Return the behavior function pointer the browser adapter registers when it
/// publishes or spawns a wasm-hosted object: the `__indirect_function_table`
/// index of `glowcap_behavior_trampoline`, passed as the `behavior` argument to
/// `glowcap_host_session_publish` / `glowcap_host_session_spawn` /
/// `glowcap_host_turn_spawn`. Taking the trampoline's address also references
/// the import so `wasm-ld` cannot dead-strip an as-yet-uncalled seam.
export fn glowcap_wasm_behavior_trampoline_addr() usize {
    return @intFromPtr(&glowcap_behavior_trampoline);
}

/// Return the function-table index registered as a hosted actor's `free`
/// callback. Keeping this distinct from behavior dispatch preserves both C
/// signatures and makes a mismatched adapter fail at instantiation.
export fn glowcap_wasm_hosted_free_trampoline_addr() usize {
    return @intFromPtr(&glowcap_hosted_free_trampoline);
}
