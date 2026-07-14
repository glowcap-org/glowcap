//! The OCapN locator-to-URI grammar, in both directions, for C.
//!
//! This is the one C surface over `model.uri` — the `ocapn://<designator>.<transport>[/s/<swiss>][?hints]`
//! bootstrap form a peer or sturdyref address travels in. It is core OCapN
//! vocabulary, not a transport feature: the grammar is transport-agnostic, so a
//! TCP-only binding reaches it the same as the iroh companion library, and no binding
//! hand-rolls a percent codec. Pure Zig, no I/O, no new artifact — it lands in
//! `libpancake_ocapn`'s `pancake_ocapn.h`.
//!
//! The split mirrors the core module it fronts. `model.uri` is the grammar —
//! the verbs that turn a string into a structure and back; `model.PeerLocator` / `SturdyRef` are the values
//! it produces (the noun). So the verbs are `pancake_uri_*` (parse/format) and
//! the nouns are `pancake_locator_*` accessors over one opaque handle. A
//! sturdyref *is* a locator in OCapN (`model.SturdyRef` embeds a `PeerLocator`
//! plus a swissnum), so one `PancakeLocator` carries both: a parsed peer has a
//! zero-length swissnum, a parsed sturdyref has the swiss bytes, and the
//! accessors are shared.
//!
//! Parsing/formatting (here) is separate from dialing (a transport's `connect`):
//! a binding parses a URI, reads `transport`, then calls the matching transport.

const std = @import("std");

const model = @import("model");

const c = @import("mod.zig");
const ctx = @import("context.zig");

const PancakeLocator = c.PancakeLocator;

const setLastError = c.setLastError;

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_NOT_FOUND = c.PANCAKE_ERR_NOT_FOUND;
const PANCAKE_ERR_BUFFER_TOO_SMALL = c.PANCAKE_ERR_BUFFER_TOO_SMALL;

/// What a parse returns: the owned `model.uri` value plus the allocator that
/// minted it, so `pancake_locator_release` frees through the same policy. A peer
/// URI leaves `swissnum` empty and `is_sturdyref` false; a sturdyref fills both.
const LocatorPayload = struct {
    allocator: std.mem.Allocator,
    peer: model.PeerLocator,
    swissnum: []const u8,
    is_sturdyref: bool,
};

fn locFromOpaque(loc: ?*PancakeLocator) ?*LocatorPayload {
    const ptr = loc orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Map a `model.uri` parse failure to a C code. A grammar failure is a bad
/// input argument (the bytes are not an OCapN URI), with the concrete reason in
/// `pancake_last_error`; only allocation faults are internal.
fn parseErrToCode(err: model.uri.Error) i32 {
    return switch (err) {
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        else => blk: {
            setLastError("uri parse: {s}", .{@errorName(err)});
            break :blk PANCAKE_ERR_INVALID_ARGUMENT;
        },
    };
}

// ── Parse: string → owned locator handle ─────────────────────────────────────

/// Parse an `ocapn://` peer URI into an owned locator handle. The bytes are
/// borrowed for the call. Returns PANCAKE_ERR_INVALID_ARGUMENT (see
/// pancake_last_error) for a malformed URI. Release with pancake_locator_release.
pub export fn pancake_uri_parse_peer(uri: ?[*]const u8, uri_len: usize, out_locator: ?*?*PancakeLocator) i32 {
    const uri_ptr = uri orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_locator orelse return PANCAKE_ERR_NULL_POINTER;
    const alloc = ctx.library_allocator;

    const peer = model.uri.parsePeer(alloc, uri_ptr[0..uri_len]) catch |err| return parseErrToCode(err);
    const payload = alloc.create(LocatorPayload) catch {
        model.uri.freePeer(alloc, peer);
        return PANCAKE_ERR_INTERNAL;
    };
    payload.* = .{ .allocator = alloc, .peer = peer, .swissnum = &.{}, .is_sturdyref = false };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Parse an `ocapn://…/s/<swiss>` sturdyref URI into an owned locator handle
/// carrying its swissnum. Same borrow, error, and release contract as
/// pancake_uri_parse_peer.
pub export fn pancake_uri_parse_sturdyref(uri: ?[*]const u8, uri_len: usize, out_locator: ?*?*PancakeLocator) i32 {
    const uri_ptr = uri orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_locator orelse return PANCAKE_ERR_NULL_POINTER;
    const alloc = ctx.library_allocator;

    const sturdyref = model.uri.parseSturdyref(alloc, uri_ptr[0..uri_len]) catch |err| return parseErrToCode(err);
    const payload = alloc.create(LocatorPayload) catch {
        model.uri.freeSturdyref(alloc, sturdyref);
        return PANCAKE_ERR_INTERNAL;
    };
    payload.* = .{ .allocator = alloc, .peer = sturdyref.peer, .swissnum = sturdyref.swissnum, .is_sturdyref = true };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Release a locator handle and the parse allocations it owns. NULL is a no-op.
pub export fn pancake_locator_release(loc: ?*PancakeLocator) void {
    const payload = locFromOpaque(loc) orelse return;
    const alloc = payload.allocator;
    model.uri.freePeer(alloc, payload.peer);
    if (payload.is_sturdyref) alloc.free(payload.swissnum);
    alloc.destroy(payload);
}

// ── Locator accessors: borrowed views into the handle ────────────────────────

/// Write a borrowed view (pointer + length) into the out-params. The view aliases
/// the handle and is valid until pancake_locator_release; an empty view reports a
/// NULL pointer and zero length.
fn writeView(bytes: []const u8, out_ptr: ?*?[*]const u8, out_len: ?*usize) i32 {
    const p = out_ptr orelse return PANCAKE_ERR_NULL_POINTER;
    const l = out_len orelse return PANCAKE_ERR_NULL_POINTER;
    p.* = if (bytes.len == 0) null else bytes.ptr;
    l.* = bytes.len;
    return PANCAKE_OK;
}

/// The string bytes of a hint value. Parsing always yields `string` hints; any
/// other arm (which a parse never produces) reports absent so a defensive caller
/// is never handed a misread view.
fn hintBytes(value: model.HintValue) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

/// Borrow the locator's transport (e.g. "tcp", "iroh"), the field a dispatcher
/// reads to pick a netlayer.
pub export fn pancake_locator_transport(loc: ?*PancakeLocator, out_ptr: ?*?[*]const u8, out_len: ?*usize) i32 {
    const payload = locFromOpaque(loc) orelse return PANCAKE_ERR_NULL_POINTER;
    return writeView(payload.peer.transport, out_ptr, out_len);
}

/// Borrow the locator's designator, the transport-specific address (a TCP
/// host:port string, an iroh node id, an inproc designator).
pub export fn pancake_locator_designator(loc: ?*PancakeLocator, out_ptr: ?*?[*]const u8, out_len: ?*usize) i32 {
    const payload = locFromOpaque(loc) orelse return PANCAKE_ERR_NULL_POINTER;
    return writeView(payload.peer.designator, out_ptr, out_len);
}

/// Split the locator's designator as `host:port` — the address grammar a socket
/// transport's designator carries — writing a borrowed host view and the decimal
/// port. The split is `model.uri.splitHostPort`, the same grammar the native TCP
/// netlayer dials through: last-colon split, bracketed IPv6 literals unwrapped
/// (`[::1]:9000` yields host `::1`), decimal `u16` port. A consumer dialing with
/// its own sockets stops re-deriving that split per language, which is where the
/// copies had already drifted. When the designator bytes are already known
/// without a locator handle, prefer `pancake_designator_host_port`.
/// PANCAKE_ERR_INVALID_ARGUMENT (see pancake_last_error) when the designator
/// does not carry the grammar. The host view aliases the handle until
/// pancake_locator_release.
pub export fn pancake_locator_host_port(
    loc: ?*PancakeLocator,
    out_host: ?*?[*]const u8,
    out_host_len: ?*usize,
    out_port: ?*u16,
) i32 {
    const payload = locFromOpaque(loc) orelse return PANCAKE_ERR_NULL_POINTER;
    return pancake_designator_host_port(
        payload.peer.designator.ptr,
        payload.peer.designator.len,
        out_host,
        out_host_len,
        out_port,
    );
}

/// Split a bare designator (or a `direct-addresses` hint entry) as
/// `host:port` — same grammar as `pancake_locator_host_port`, without minting
/// a peer URI or a locator handle. A DIAL action already carries the
/// designator; redeem dials call this instead of format→parse→host_port. The
/// host view aliases `designator` for the call; copy it before mutating that
/// buffer.
pub export fn pancake_designator_host_port(
    designator: ?[*]const u8,
    designator_len: usize,
    out_host: ?*?[*]const u8,
    out_host_len: ?*usize,
    out_port: ?*u16,
) i32 {
    const designator_ptr = designator orelse return PANCAKE_ERR_NULL_POINTER;
    const port_slot = out_port orelse return PANCAKE_ERR_NULL_POINTER;
    const split = model.uri.splitHostPort(designator_ptr[0..designator_len]) catch {
        setLastError("designator is not host:port: {s}", .{designator_ptr[0..designator_len]});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    const rc = writeView(split.host, out_host, out_host_len);
    if (rc != PANCAKE_OK) return rc;
    port_slot.* = split.port;
    return PANCAKE_OK;
}

/// Borrow the locator's swissnum: zero-length for a peer URI, the swiss bytes for
/// a sturdyref. The discriminator a C caller reads instead of a second handle type.
pub export fn pancake_locator_swissnum(loc: ?*PancakeLocator, out_ptr: ?*?[*]const u8, out_len: ?*usize) i32 {
    const payload = locFromOpaque(loc) orelse return PANCAKE_ERR_NULL_POINTER;
    return writeView(payload.swissnum, out_ptr, out_len);
}

/// Borrow the value of the hint named by `key` (e.g. "direct-addresses").
/// PANCAKE_ERR_NOT_FOUND when no hint carries that key. `key` is borrowed.
pub export fn pancake_locator_hint(
    loc: ?*PancakeLocator,
    key: ?[*]const u8,
    key_len: usize,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) i32 {
    const payload = locFromOpaque(loc) orelse return PANCAKE_ERR_NULL_POINTER;
    const key_ptr = key orelse return PANCAKE_ERR_NULL_POINTER;
    const k = key_ptr[0..key_len];
    for (payload.peer.hints.entries) |entry| {
        if (std.mem.eql(u8, entry.name, k)) {
            const bytes = hintBytes(entry.value) orelse return PANCAKE_ERR_NOT_FOUND;
            return writeView(bytes, out_ptr, out_len);
        }
    }
    return PANCAKE_ERR_NOT_FOUND;
}

/// The number of hints on the locator (for index enumeration with
/// pancake_locator_hint_at).
pub export fn pancake_locator_hint_count(loc: ?*PancakeLocator, out_count: ?*usize) i32 {
    const payload = locFromOpaque(loc) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_count orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = payload.peer.hints.entries.len;
    return PANCAKE_OK;
}

/// Borrow the key and value of hint `idx` (0-based). PANCAKE_ERR_INVALID_ARGUMENT
/// when idx is out of range. Both views alias the handle until release.
pub export fn pancake_locator_hint_at(
    loc: ?*PancakeLocator,
    idx: usize,
    out_key: ?*?[*]const u8,
    out_key_len: ?*usize,
    out_val: ?*?[*]const u8,
    out_val_len: ?*usize,
) i32 {
    const payload = locFromOpaque(loc) orelse return PANCAKE_ERR_NULL_POINTER;
    if (idx >= payload.peer.hints.entries.len) return PANCAKE_ERR_INVALID_ARGUMENT;
    const entry = payload.peer.hints.entries[idx];
    const bytes = hintBytes(entry.value) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    const key_rc = writeView(entry.name, out_key, out_key_len);
    if (key_rc != PANCAKE_OK) return key_rc;
    return writeView(bytes, out_val, out_val_len);
}

// ── Format: structure → string ───────────────────────────────────────────────

const BuildError = error{ OutOfMemory, NullPointer };

/// Borrow the i-th string from a parallel (pointers, lengths) pair. A zero
/// length is the empty string; a non-zero length behind a NULL pointer is a
/// caller bug, refused rather than dereferenced.
fn viewAt(arr: [*]const ?[*]const u8, lens: [*]const usize, i: usize) BuildError![]const u8 {
    const len = lens[i];
    if (len == 0) return &.{};
    const ptr = arr[i] orelse return error.NullPointer;
    return ptr[0..len];
}

/// Build a borrowed `HintEntry` slice from the parallel key/value string arrays.
/// The entries view the caller's bytes for the call only; the slice itself is
/// owned and must be freed. An empty set returns an empty slice (no allocation).
fn buildHints(
    alloc: std.mem.Allocator,
    keys: ?[*]const ?[*]const u8,
    key_lens: ?[*]const usize,
    vals: ?[*]const ?[*]const u8,
    val_lens: ?[*]const usize,
    count: usize,
) BuildError![]model.HintEntry {
    if (count == 0) return &.{};
    const ks = keys orelse return error.NullPointer;
    const kls = key_lens orelse return error.NullPointer;
    const vs = vals orelse return error.NullPointer;
    const vls = val_lens orelse return error.NullPointer;

    const entries = try alloc.alloc(model.HintEntry, count);
    errdefer alloc.free(entries);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        entries[i] = .{ .name = try viewAt(ks, kls, i), .value = .{ .string = try viewAt(vs, vls, i) } };
    }
    return entries;
}

fn buildErrToCode(err: BuildError) i32 {
    return switch (err) {
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        error.NullPointer => PANCAKE_ERR_NULL_POINTER,
    };
}

fn writeErrToCode(err: model.uri.Error) i32 {
    return switch (err) {
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        else => blk: {
            setLastError("uri format: {s}", .{@errorName(err)});
            break :blk PANCAKE_ERR_INVALID_ARGUMENT;
        },
    };
}

/// Copy the rendered URI into the caller's buffer. `out_len` always receives the
/// full length (so a too-small buffer can be retried); a NULL buffer or a buffer
/// smaller than the URI is PANCAKE_ERR_BUFFER_TOO_SMALL with the length reported.
fn copyOut(rendered: []const u8, out: ?[*]u8, cap: usize, out_len: ?*usize) i32 {
    const l = out_len orelse return PANCAKE_ERR_NULL_POINTER;
    l.* = rendered.len;
    const dest = out orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    if (cap < rendered.len) return PANCAKE_ERR_BUFFER_TOO_SMALL;
    @memcpy(dest[0..rendered.len], rendered);
    return PANCAKE_OK;
}

/// Format a peer locator as an `ocapn://` URI into `out`. Hints are parallel
/// key/value string arrays of `hint_count` entries; all inputs are borrowed.
/// `out_len` receives the full URI length; a buffer too small is
/// PANCAKE_ERR_BUFFER_TOO_SMALL (a NULL buffer is PANCAKE_ERR_INVALID_ARGUMENT)
/// with the length still reported.
pub export fn pancake_uri_format_peer(
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    hint_keys: ?[*]const ?[*]const u8,
    hint_key_lens: ?[*]const usize,
    hint_vals: ?[*]const ?[*]const u8,
    hint_val_lens: ?[*]const usize,
    hint_count: usize,
    out: ?[*]u8,
    cap: usize,
    out_len: ?*usize,
) i32 {
    const t = transport orelse return PANCAKE_ERR_NULL_POINTER;
    const d = designator orelse return PANCAKE_ERR_NULL_POINTER;
    const alloc = ctx.library_allocator;

    const entries = buildHints(alloc, hint_keys, hint_key_lens, hint_vals, hint_val_lens, hint_count) catch |err| return buildErrToCode(err);
    defer if (entries.len > 0) alloc.free(entries);

    const locator = model.PeerLocator{
        .transport = t[0..transport_len],
        .designator = d[0..designator_len],
        .hints = .{ .entries = entries, .wire_form = .map },
    };
    const rendered = model.uri.writePeer(alloc, locator) catch |err| return writeErrToCode(err);
    defer alloc.free(rendered);
    return copyOut(rendered, out, cap, out_len);
}

/// Format a sturdyref locator (peer + swissnum) as an `ocapn://…/s/<swiss>` URI.
/// Same hint-array and buffer contract as pancake_uri_format_peer; `swissnum` is
/// borrowed.
pub export fn pancake_uri_format_sturdyref(
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    swissnum: ?[*]const u8,
    swissnum_len: usize,
    hint_keys: ?[*]const ?[*]const u8,
    hint_key_lens: ?[*]const usize,
    hint_vals: ?[*]const ?[*]const u8,
    hint_val_lens: ?[*]const usize,
    hint_count: usize,
    out: ?[*]u8,
    cap: usize,
    out_len: ?*usize,
) i32 {
    const t = transport orelse return PANCAKE_ERR_NULL_POINTER;
    const d = designator orelse return PANCAKE_ERR_NULL_POINTER;
    const sw = swissnum orelse return PANCAKE_ERR_NULL_POINTER;
    const alloc = ctx.library_allocator;

    const entries = buildHints(alloc, hint_keys, hint_key_lens, hint_vals, hint_val_lens, hint_count) catch |err| return buildErrToCode(err);
    defer if (entries.len > 0) alloc.free(entries);

    const sturdyref = model.SturdyRef{
        .peer = .{
            .transport = t[0..transport_len],
            .designator = d[0..designator_len],
            .hints = .{ .entries = entries, .wire_form = .map },
        },
        .swissnum = sw[0..swissnum_len],
    };
    const rendered = model.uri.writeSturdyref(alloc, sturdyref) catch |err| return writeErrToCode(err);
    defer alloc.free(rendered);
    return copyOut(rendered, out, cap, out_len);
}
