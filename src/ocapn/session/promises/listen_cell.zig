//! Shared listen/settle cell helpers for the third-party import store.
//!
//! `PromiseListenCell` lives on `Session`; these functions are the one install /
//! take / peek / deinit spine `promises/imported.zig` calls, keeping the
//! third-party import store's listen/settle contract in a single place.

const std = @import("std");
const model = @import("model");
const session = @import("../mod.zig");

const Error = session.Error;
const PromiseListenCell = session.PromiseListenCell;
const ListenerEntry = session.ListenerEntry;

/// Append `listener` when under `max_listeners`; else `ListenerCapExceeded`.
pub fn installListener(
    cell: *PromiseListenCell,
    allocator: std.mem.Allocator,
    max_listeners: usize,
    listener: ListenerEntry,
) (Error || std.mem.Allocator.Error)!void {
    if (cell.listeners.len() >= max_listeners) return Error.ListenerCapExceeded;
    try cell.listeners.append(allocator, listener);
}

/// Hand the caller every listener, leaving the list empty.
pub fn takeListeners(cell: *PromiseListenCell, allocator: std.mem.Allocator) ![]ListenerEntry {
    return cell.listeners.take(allocator);
}

pub fn restoreListeners(cell: *PromiseListenCell, listeners: []ListenerEntry) void {
    cell.listeners.restoreOwned(listeners);
}

/// Borrow the stored resolution when present.
pub fn resolution(cell: *const PromiseListenCell) ?*const model.Resolution {
    if (cell.resolution) |*r| return r;
    return null;
}

/// Release listeners and any stored resolution. Safe to drop afterward.
pub fn deinit(allocator: std.mem.Allocator, cell: *PromiseListenCell) void {
    cell.listeners.deinit(allocator);
    if (cell.resolution) |r| model.freeResolution(allocator, r);
    cell.resolution = null;
}
