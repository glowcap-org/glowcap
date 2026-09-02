//! Borrowed C views into owned locator and sturdyref handles.

const std = @import("std");

const model = @import("model");
const c = @import("../mod.zig");
const shared = @import("c_abi_shared");
const locator_abi = shared.locator;
const ownership = @import("ownership.zig");

const GLOWCAP_OK = c.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = c.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = c.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_NOT_FOUND = c.GLOWCAP_ERR_NOT_FOUND;

fn writeView(bytes: []const u8, out_ptr: ?*?[*]const u8, out_len: ?*usize) i32 {
    const p = out_ptr orelse return GLOWCAP_ERR_NULL_POINTER;
    const l = out_len orelse return GLOWCAP_ERR_NULL_POINTER;
    p.* = if (bytes.len == 0) null else bytes.ptr;
    l.* = bytes.len;
    return GLOWCAP_OK;
}

pub fn glowcap_locator_transport(loc: ?*c.GlowcapLocator, out_ptr: ?*?[*]const u8, out_len: ?*usize) i32 {
    const payload = ownership.locFromOpaque(loc) orelse return GLOWCAP_ERR_NULL_POINTER;
    return writeView(payload.transport, out_ptr, out_len);
}

pub fn glowcap_locator_designator(loc: ?*c.GlowcapLocator, out_ptr: ?*?[*]const u8, out_len: ?*usize) i32 {
    const payload = ownership.locFromOpaque(loc) orelse return GLOWCAP_ERR_NULL_POINTER;
    return writeView(payload.designator, out_ptr, out_len);
}

pub fn glowcap_locator_host_port(
    loc: ?*c.GlowcapLocator,
    out_host: ?*?[*]const u8,
    out_host_len: ?*usize,
    out_port: ?*u16,
) i32 {
    const payload = ownership.locFromOpaque(loc) orelse return GLOWCAP_ERR_NULL_POINTER;
    return glowcap_designator_host_port(
        payload.designator.ptr,
        payload.designator.len,
        out_host,
        out_host_len,
        out_port,
    );
}

pub fn glowcap_designator_host_port(
    designator: ?[*]const u8,
    designator_len: usize,
    out_host: ?*?[*]const u8,
    out_host_len: ?*usize,
    out_port: ?*u16,
) i32 {
    const designator_ptr = designator orelse return GLOWCAP_ERR_NULL_POINTER;
    const port_slot = out_port orelse return GLOWCAP_ERR_NULL_POINTER;
    const split = model.uri.splitHostPort(designator_ptr[0..designator_len]) catch {
        shared.setLastError("designator is not host:port: {s}", .{designator_ptr[0..designator_len]});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    };
    const rc = writeView(split.host, out_host, out_host_len);
    if (rc != GLOWCAP_OK) return rc;
    port_slot.* = split.port;
    return GLOWCAP_OK;
}

pub fn glowcap_sturdyref_swissnum(
    sturdyref: ?*c.GlowcapSturdyRef,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) i32 {
    const payload = ownership.sturdyFromOpaque(sturdyref) orelse return GLOWCAP_ERR_NULL_POINTER;
    return writeView(payload.swissnum, out_ptr, out_len);
}

pub fn glowcap_locator_hint(
    loc: ?*c.GlowcapLocator,
    key: ?[*]const u8,
    key_len: usize,
    out_hint: ?*shared.GlowcapLocatorHintView,
) i32 {
    const payload = ownership.locFromOpaque(loc) orelse return GLOWCAP_ERR_NULL_POINTER;
    const key_ptr = key orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_hint orelse return GLOWCAP_ERR_NULL_POINTER;
    const k = key_ptr[0..key_len];
    for (payload.hints.items, payload.hint_views.items) |entry, hint_view| {
        if (std.mem.eql(u8, entry.name, k)) {
            slot.* = hint_view;
            return GLOWCAP_OK;
        }
    }
    return GLOWCAP_ERR_NOT_FOUND;
}

pub fn glowcap_locator_hint_count(loc: ?*c.GlowcapLocator, out_count: ?*usize) i32 {
    const payload = ownership.locFromOpaque(loc) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_count orelse return GLOWCAP_ERR_NULL_POINTER;
    slot.* = payload.hints.items.len;
    return GLOWCAP_OK;
}

pub fn glowcap_locator_hint_at(
    loc: ?*c.GlowcapLocator,
    idx: usize,
    out_hint: ?*shared.GlowcapLocatorHintView,
) i32 {
    const payload = ownership.locFromOpaque(loc) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_hint orelse return GLOWCAP_ERR_NULL_POINTER;
    if (idx >= payload.hint_views.items.len) {
        shared.setLastError("locator: HintIndexOutOfBounds", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    slot.* = payload.hint_views.items[idx];
    return GLOWCAP_OK;
}

pub fn glowcap_locator_hint_wire_form(
    loc: ?*c.GlowcapLocator,
    out_wire_form: ?*u32,
) i32 {
    const payload = ownership.locFromOpaque(loc) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_wire_form orelse return GLOWCAP_ERR_NULL_POINTER;
    slot.* = switch (payload.wire_form) {
        .map => locator_abi.GLOWCAP_HINTS_MAP,
        .boolean_false => locator_abi.GLOWCAP_HINTS_BOOLEAN_FALSE,
    };
    return GLOWCAP_OK;
}
