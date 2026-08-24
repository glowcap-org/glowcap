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
//! the nouns are distinct `PancakeLocator` and `PancakeSturdyRef` handles. A
//! sturdyref embeds a peer locator plus authority-bearing swiss bytes; keeping
//! those types distinct prevents a peer-view operation from silently dropping
//! the swissnum.
//!
//! Parsing/formatting (here) is separate from dialing (a transport's `connect`):
//! a binding parses a URI, reads `transport`, then calls the matching transport.

const std = @import("std");

const model = @import("model");

const c = @import("mod.zig");
const shared = @import("c_abi_shared");
const locator_abi = shared.locator;
const locator_adapter = shared.locator_adapter;
const ctx = @import("context.zig");
const accessors = @import("uri/accessors.zig");
const format = @import("uri/format.zig");
const ownership = @import("uri/ownership.zig");

const PancakeLocator = c.PancakeLocator;
const PancakeSturdyRef = c.PancakeSturdyRef;
const PancakeContext = c.PancakeContext;

const setLastError = c.setLastError;

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const LocatorPayload = ownership.LocatorPayload;
const locFromOpaque = ownership.locFromOpaque;
const sturdyFromOpaque = ownership.sturdyFromOpaque;
const adoptPeer = ownership.adoptPeer;
const adoptSturdyRef = ownership.adoptSturdyRef;

/// Map a `model.uri` parse failure to a C code. A grammar failure is a bad
/// input argument (the bytes are not an OCapN URI), with the concrete reason in
/// `pancake_last_error`; only allocation faults are internal.
fn parseErrToCode(err: model.uri.Error) i32 {
    return switch (err) {
        error.OutOfMemory => blk: {
            setLastError("uri parse: OutOfMemory", .{});
            break :blk PANCAKE_ERR_INTERNAL;
        },
        else => blk: {
            setLastError("uri parse: {s}", .{@errorName(err)});
            break :blk PANCAKE_ERR_INVALID_ARGUMENT;
        },
    };
}

// ── Parse: string to owned locator handle ─────────────────────────────────────

/// Parse an `ocapn://` peer URI into an owned locator handle. The bytes are
/// borrowed for the call. Returns PANCAKE_ERR_INVALID_ARGUMENT (see
/// pancake_last_error) for a malformed URI. Release with pancake_locator_release.
fn uriParsePeerIn(allocator: std.mem.Allocator, uri: ?[*]const u8, uri_len: usize, out_locator: ?*?*PancakeLocator) i32 {
    const uri_ptr = uri orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_locator orelse return PANCAKE_ERR_NULL_POINTER;
    const peer = model.uri.parsePeer(allocator, uri_ptr[0..uri_len]) catch |err| return parseErrToCode(err);
    const payload = adoptPeer(allocator, peer) catch {
        setLastError("uri parse: OutOfMemory", .{});
        return PANCAKE_ERR_INTERNAL;
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

pub export fn pancake_uri_parse_peer(uri: ?[*]const u8, uri_len: usize, out_locator: ?*?*PancakeLocator) i32 {
    shared.lastErrorClear();
    return uriParsePeerIn(ctx.library_allocator, uri, uri_len, out_locator);
}

pub export fn pancake_uri_parse_peer_in(
    context: ?*PancakeContext,
    uri: ?[*]const u8,
    uri_len: usize,
    out_locator: ?*?*PancakeLocator,
) i32 {
    shared.lastErrorClear();
    const context_payload = ctx.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    return uriParsePeerIn(context_payload.allocator(), uri, uri_len, out_locator);
}

/// Parse an `ocapn://…/s/<swiss>` sturdyref URI into an owned locator handle
/// carrying its swissnum. Same borrow, error, and release contract as
/// pancake_uri_parse_peer. `captp_version` selects the profile-specific
/// swissnum path spelling; an unknown value is refused rather than guessed.
fn uriParseSturdyrefIn(
    allocator: std.mem.Allocator,
    captp_version: u32,
    uri: ?[*]const u8,
    uri_len: usize,
    out_sturdyref: ?*?*PancakeSturdyRef,
) i32 {
    const uri_ptr = uri orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_sturdyref orelse return PANCAKE_ERR_NULL_POINTER;
    const profile = shared.captpVersionFromC(captp_version) orelse {
        shared.setLastError("uri: captp_version must be a PANCAKE_CAPTP_* value", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    const sturdyref = model.uri.parseSturdyrefForProfile(
        allocator,
        profile,
        uri_ptr[0..uri_len],
    ) catch |err| return parseErrToCode(err);
    const payload = adoptSturdyRef(allocator, sturdyref) catch {
        setLastError("sturdyref parse: OutOfMemory", .{});
        return PANCAKE_ERR_INTERNAL;
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

pub export fn pancake_uri_parse_sturdyref(
    captp_version: u32,
    uri: ?[*]const u8,
    uri_len: usize,
    out_sturdyref: ?*?*PancakeSturdyRef,
) i32 {
    shared.lastErrorClear();
    return uriParseSturdyrefIn(ctx.library_allocator, captp_version, uri, uri_len, out_sturdyref);
}

pub export fn pancake_uri_parse_sturdyref_in(
    context: ?*PancakeContext,
    captp_version: u32,
    uri: ?[*]const u8,
    uri_len: usize,
    out_sturdyref: ?*?*PancakeSturdyRef,
) i32 {
    shared.lastErrorClear();
    const context_payload = ctx.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    return uriParseSturdyrefIn(context_payload.allocator(), captp_version, uri, uri_len, out_sturdyref);
}

/// Release a locator handle and the parse allocations it owns. NULL is a no-op.
pub export fn pancake_locator_release(loc: ?*PancakeLocator) void {
    const payload = locFromOpaque(loc) orelse return;
    payload.deinit();
}

/// Release a sturdyref and its embedded peer locator. NULL is a no-op.
pub export fn pancake_sturdyref_release(sturdyref: ?*PancakeSturdyRef) void {
    const payload = sturdyFromOpaque(sturdyref) orelse return;
    payload.deinit();
}

fn requiredSlice(ptr: ?[*]const u8, len: usize) ![]const u8 {
    if (len == 0) return error.InvalidArgument;
    return (ptr orelse return error.NullPointer)[0..len];
}

fn optionalSlice(ptr: ?[*]const u8, len: usize) ![]const u8 {
    if (len == 0) return &.{};
    return (ptr orelse return error.NullPointer)[0..len];
}

fn locatorErrToCode(err: anyerror) i32 {
    return switch (err) {
        error.NullPointer => PANCAKE_ERR_NULL_POINTER,
        error.OutOfMemory => blk: {
            setLastError("locator: OutOfMemory", .{});
            break :blk PANCAKE_ERR_INTERNAL;
        },
        else => blk: {
            setLastError("locator: {s}", .{@errorName(err)});
            break :blk PANCAKE_ERR_INVALID_ARGUMENT;
        },
    };
}

/// Construct one owned peer locator. The handle owns all subsequently added
/// hints and projects a stable borrowed view until its next mutation.
fn locatorNewIn(
    allocator: std.mem.Allocator,
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    hint_wire_form: u32,
    out_locator: ?*?*PancakeLocator,
) i32 {
    const slot = out_locator orelse return PANCAKE_ERR_NULL_POINTER;
    const t = requiredSlice(transport, transport_len) catch |err| return locatorErrToCode(err);
    const d = requiredSlice(designator, designator_len) catch |err| return locatorErrToCode(err);
    const wire_form: model.Hints.WireForm = switch (hint_wire_form) {
        locator_abi.PANCAKE_HINTS_MAP => .map,
        locator_abi.PANCAKE_HINTS_BOOLEAN_FALSE => .boolean_false,
        else => return locatorErrToCode(error.InvalidHintWireForm),
    };
    model.validatePeerLocator(.{
        .transport = t,
        .designator = d,
        .hints = .{ .entries = &.{}, .wire_form = wire_form },
    }) catch |err| return locatorErrToCode(err);
    const owned_transport = allocator.dupe(u8, t) catch return locatorErrToCode(error.OutOfMemory);
    const owned_designator = allocator.dupe(u8, d) catch {
        allocator.free(owned_transport);
        return locatorErrToCode(error.OutOfMemory);
    };
    const entries = allocator.alloc(model.HintEntry, 0) catch {
        allocator.free(owned_designator);
        allocator.free(owned_transport);
        return locatorErrToCode(error.OutOfMemory);
    };
    const payload = adoptPeer(allocator, .{
        .transport = owned_transport,
        .designator = owned_designator,
        .hints = .{ .entries = entries, .wire_form = wire_form },
    }) catch return locatorErrToCode(error.OutOfMemory);
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

pub export fn pancake_locator_new(
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    hint_wire_form: u32,
    out_locator: ?*?*PancakeLocator,
) i32 {
    shared.lastErrorClear();
    return locatorNewIn(ctx.library_allocator, transport, transport_len, designator, designator_len, hint_wire_form, out_locator);
}

pub export fn pancake_locator_new_in(
    context: ?*PancakeContext,
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    hint_wire_form: u32,
    out_locator: ?*?*PancakeLocator,
) i32 {
    shared.lastErrorClear();
    const context_payload = ctx.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    return locatorNewIn(context_payload.allocator(), transport, transport_len, designator, designator_len, hint_wire_form, out_locator);
}

/// Clone one versioned borrowed locator view into an OCapN-owned handle.
fn locatorCloneIn(
    allocator: std.mem.Allocator,
    view: ?*const shared.PancakeLocatorView,
    out_locator: ?*?*PancakeLocator,
) i32 {
    const source = view orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_locator orelse return PANCAKE_ERR_NULL_POINTER;
    const peer = locator_adapter.cloneView(allocator, source) catch |err| return locatorErrToCode(err);
    const payload = adoptPeer(allocator, peer) catch return locatorErrToCode(error.OutOfMemory);
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

pub export fn pancake_locator_clone(
    view: ?*const shared.PancakeLocatorView,
    out_locator: ?*?*PancakeLocator,
) i32 {
    shared.lastErrorClear();
    return locatorCloneIn(ctx.library_allocator, view, out_locator);
}

pub export fn pancake_locator_clone_in(
    context: ?*PancakeContext,
    view: ?*const shared.PancakeLocatorView,
    out_locator: ?*?*PancakeLocator,
) i32 {
    shared.lastErrorClear();
    const context_payload = ctx.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    return locatorCloneIn(context_payload.allocator(), view, out_locator);
}

/// Borrow the handle's complete stable view. It remains valid until the next
/// hint addition or release.
pub export fn pancake_locator_borrow_view(
    loc: ?*const PancakeLocator,
    out_view: ?*?*const shared.PancakeLocatorView,
) i32 {
    shared.lastErrorClear();
    const payload = locFromOpaque(@constCast(loc)) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_view orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = &payload.view;
    return PANCAKE_OK;
}

/// Borrow the embedded peer locator view without discarding the sturdyref's
/// swissnum. The sturdyref remains the owner of both views.
pub export fn pancake_sturdyref_borrow_locator(
    sturdyref: ?*const PancakeSturdyRef,
    out_view: ?*?*const shared.PancakeLocatorView,
) i32 {
    shared.lastErrorClear();
    const payload = sturdyFromOpaque(@constCast(sturdyref)) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_view orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = &payload.locator.view;
    return PANCAKE_OK;
}

fn appendHint(payload: *LocatorPayload, name: []const u8, value: model.HintValue) !void {
    try model.validateLocatorHintAddition(payload.peer(), name);
    try payload.hints.ensureUnusedCapacity(payload.allocator, 1);
    try payload.hint_views.ensureUnusedCapacity(payload.allocator, 1);
    const owned_name = try payload.allocator.dupe(u8, name);
    errdefer payload.allocator.free(owned_name);
    const owned_value = try model.cloneHintValue(payload.allocator, value);
    errdefer model.freeHintValue(payload.allocator, owned_value);
    payload.hints.appendAssumeCapacity(.{ .name = owned_name, .value = owned_value });
    payload.refreshView() catch |err| {
        // Projection is the commit point for a C-visible mutation. Keep the
        // previously borrowed view authoritative if validation ever grows a
        // new refusal: the just-appended ownership is still ours to undo, and
        // no library-side invariant is allowed to terminate the process.
        const appended = payload.hints.pop().?;
        model.freeHintEntry(payload.allocator, appended);
        payload.hint_views.shrinkRetainingCapacity(payload.hints.items.len);
        return err;
    };
}

fn addBytesHint(
    loc: ?*PancakeLocator,
    name: ?[*]const u8,
    name_len: usize,
    value: ?[*]const u8,
    value_len: usize,
    comptime kind: enum { string, bytes },
) i32 {
    const payload = locFromOpaque(loc) orelse return PANCAKE_ERR_NULL_POINTER;
    const n = requiredSlice(name, name_len) catch |err| return locatorErrToCode(err);
    const bytes = optionalSlice(value, value_len) catch |err| return locatorErrToCode(err);
    const hint_value: model.HintValue = switch (kind) {
        .string => .{ .string = bytes },
        .bytes => .{ .bytes = bytes },
    };
    appendHint(payload, n, hint_value) catch |err| return locatorErrToCode(err);
    return PANCAKE_OK;
}

pub export fn pancake_locator_add_string(
    loc: ?*PancakeLocator,
    name: ?[*]const u8,
    name_len: usize,
    value: ?[*]const u8,
    value_len: usize,
) i32 {
    shared.lastErrorClear();
    return addBytesHint(loc, name, name_len, value, value_len, .string);
}

pub export fn pancake_locator_add_bytes(
    loc: ?*PancakeLocator,
    name: ?[*]const u8,
    name_len: usize,
    value: ?[*]const u8,
    value_len: usize,
) i32 {
    shared.lastErrorClear();
    return addBytesHint(loc, name, name_len, value, value_len, .bytes);
}

pub export fn pancake_locator_add_boolean(
    loc: ?*PancakeLocator,
    name: ?[*]const u8,
    name_len: usize,
    value: u8,
) i32 {
    shared.lastErrorClear();
    const payload = locFromOpaque(loc) orelse return PANCAKE_ERR_NULL_POINTER;
    const n = requiredSlice(name, name_len) catch |err| return locatorErrToCode(err);
    if (value > 1) return locatorErrToCode(error.InvalidBoolean);
    appendHint(payload, n, .{ .boolean = value == 1 }) catch |err| return locatorErrToCode(err);
    return PANCAKE_OK;
}

pub export fn pancake_locator_add_integer(
    loc: ?*PancakeLocator,
    name: ?[*]const u8,
    name_len: usize,
    value: i64,
) i32 {
    shared.lastErrorClear();
    const payload = locFromOpaque(loc) orelse return PANCAKE_ERR_NULL_POINTER;
    const n = requiredSlice(name, name_len) catch |err| return locatorErrToCode(err);
    appendHint(payload, n, .{ .integer = value }) catch |err| return locatorErrToCode(err);
    return PANCAKE_OK;
}

// ── Locator accessors: borrowed views into the handle ────────────────────────

pub export fn pancake_locator_transport(loc: ?*PancakeLocator, out_ptr: ?*?[*]const u8, out_len: ?*usize) i32 {
    shared.lastErrorClear();
    return accessors.pancake_locator_transport(loc, out_ptr, out_len);
}

pub export fn pancake_locator_designator(loc: ?*PancakeLocator, out_ptr: ?*?[*]const u8, out_len: ?*usize) i32 {
    shared.lastErrorClear();
    return accessors.pancake_locator_designator(loc, out_ptr, out_len);
}

pub export fn pancake_locator_host_port(loc: ?*PancakeLocator, out_host: ?*?[*]const u8, out_host_len: ?*usize, out_port: ?*u16) i32 {
    shared.lastErrorClear();
    return accessors.pancake_locator_host_port(loc, out_host, out_host_len, out_port);
}

pub export fn pancake_designator_host_port(designator: ?[*]const u8, designator_len: usize, out_host: ?*?[*]const u8, out_host_len: ?*usize, out_port: ?*u16) i32 {
    shared.lastErrorClear();
    return accessors.pancake_designator_host_port(designator, designator_len, out_host, out_host_len, out_port);
}

pub export fn pancake_sturdyref_swissnum(sturdyref: ?*PancakeSturdyRef, out_ptr: ?*?[*]const u8, out_len: ?*usize) i32 {
    shared.lastErrorClear();
    return accessors.pancake_sturdyref_swissnum(sturdyref, out_ptr, out_len);
}

pub export fn pancake_locator_hint(loc: ?*PancakeLocator, key: ?[*]const u8, key_len: usize, out_hint: ?*shared.PancakeLocatorHintView) i32 {
    shared.lastErrorClear();
    return accessors.pancake_locator_hint(loc, key, key_len, out_hint);
}

pub export fn pancake_locator_hint_count(loc: ?*PancakeLocator, out_count: ?*usize) i32 {
    shared.lastErrorClear();
    return accessors.pancake_locator_hint_count(loc, out_count);
}

pub export fn pancake_locator_hint_at(loc: ?*PancakeLocator, idx: usize, out_hint: ?*shared.PancakeLocatorHintView) i32 {
    shared.lastErrorClear();
    return accessors.pancake_locator_hint_at(loc, idx, out_hint);
}

pub export fn pancake_locator_hint_wire_form(loc: ?*PancakeLocator, out_wire_form: ?*u32) i32 {
    shared.lastErrorClear();
    return accessors.pancake_locator_hint_wire_form(loc, out_wire_form);
}

// ── Format: structure to string ───────────────────────────────────────────────

const BuildError = error{ OutOfMemory, NullPointer, TooManyHints };

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
    if (count > model.max_locator_hint_count) return error.TooManyHints;
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
        error.OutOfMemory => blk: {
            setLastError("uri hints: OutOfMemory", .{});
            break :blk PANCAKE_ERR_INTERNAL;
        },
        error.NullPointer => PANCAKE_ERR_NULL_POINTER,
        error.TooManyHints => PANCAKE_ERR_INVALID_ARGUMENT,
    };
}

/// Format a peer locator as an `ocapn://` URI into `out`. Hints are parallel
/// key/value string arrays of `hint_count` entries; all inputs are borrowed.
/// `out_len` receives the full URI length; a buffer too small is
/// PANCAKE_ERR_BUFFER_TOO_SMALL with the length still reported. A null output is
/// allowed only with `cap == 0` to query the size.
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
    shared.lastErrorClear();
    if (out_len == null) return PANCAKE_ERR_NULL_POINTER;
    if (out == null and cap != 0) {
        setLastError("uri format: out is null with nonzero capacity", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
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
    return format.peer(locator, out, cap, out_len);
}

/// Format a sturdyref locator (peer + swissnum) as an `ocapn://…/s/<swiss>` URI.
/// Same hint-array and buffer contract as pancake_uri_format_peer; `swissnum` is
/// borrowed. `captp_version` selects the profile-specific swissnum spelling;
/// an unknown value is refused rather than guessed.
pub export fn pancake_uri_format_sturdyref(
    captp_version: u32,
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
    shared.lastErrorClear();
    if (out_len == null) return PANCAKE_ERR_NULL_POINTER;
    if (out == null and cap != 0) {
        setLastError("uri format: out is null with nonzero capacity", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    const profile = shared.captpVersionFromC(captp_version) orelse {
        shared.setLastError("uri: captp_version must be a PANCAKE_CAPTP_* value", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
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
    return format.sturdyref(profile, sturdyref, out, cap, out_len);
}
