//! Cloning and freeing the `model.Message` tree. `clone*` makes an owned copy,
//! `free*` releases one.
//!
//! This lives in the model layer so that everyone who hangs onto a message after
//! its frame is gone plays by the same release rules. Mostly that's the session's
//! pipelining tables (ADR-0007): the per-answer call queue and the stored
//! resolutions own the messages they hold and free them on their own, without
//! reaching back up into the engine.
//!
//! Think of `free*` as the main line. Owned messages move into the outbound queue
//! and the pipelining tables, and each one is freed exactly once on the way out.
//! `clone*` is the single exception we call out by name: one boundary copy in
//! `Peer.sendCopying`, for callers holding borrowed or static data they want to
//! keep owning. Everything internal goes through `Peer.send` and never clones.
//! You'll also meet these as `model.cloneMessage` and `model.freeMessage`.

const std = @import("std");
const model = @import("mod.zig");

pub fn cloneMessage(allocator: std.mem.Allocator, message: model.Message) model.view.Error!model.Message {
    return model.view.Body.fromOwned(&message).toOwned(allocator);
}

pub fn freeMessage(allocator: std.mem.Allocator, message: model.Message) void {
    switch (message) {
        .abort => |abort| allocator.free(abort.message),
        .deliver => |deliver| {
            freeReference(allocator, deliver.target);
            if (deliver.resolve_me_desc) |reference| {
                freeReference(allocator, reference);
            }
            freeArgumentSlice(allocator, deliver.args);
        },
        .resolve => |resolve| freeResolution(allocator, resolve.resolution),
        .gc_export => |gc_export| {
            allocator.free(gc_export.positions);
            allocator.free(gc_export.deltas);
        },
        .gc_answer => |gc_answer| allocator.free(gc_answer.positions),
        .start_session => |start_session| {
            allocator.free(start_session.session_pubkey.bytes);
            freePeerLocator(allocator, start_session.acceptable_location);
            allocator.free(start_session.acceptable_location_sig.bytes);
        },
        .listen => |listen| {
            freeReference(allocator, listen.target);
            freeReference(allocator, listen.listener);
        },
        .get => |get| {
            freeReference(allocator, get.receiver);
            allocator.free(get.field);
        },
        .index => |index| {
            freeReference(allocator, index.receiver);
            switch (index.index) {
                .integer => {},
                .big_integer => |big| allocator.free(big.digits),
            }
        },
        .untag => |untag| {
            freeReference(allocator, untag.receiver);
            allocator.free(untag.tag);
        },
    }
}

pub fn cloneArgument(allocator: std.mem.Allocator, argument: model.Argument) model.view.Error!model.Argument {
    return model.view.Argument.fromOwned(&argument).toOwned(allocator);
}

pub fn freeArgument(allocator: std.mem.Allocator, argument: model.Argument) void {
    switch (argument) {
        .bytes => |bytes| allocator.free(bytes),
        .symbol => |symbol| allocator.free(symbol),
        .reference => |reference| freeReference(allocator, reference),
        .@"error" => |err| freeBreakReason(allocator, err),
        .handoff => |handoff| {
            freeHandoff(allocator, handoff.*);
            allocator.destroy(handoff);
        },
        .string => |string| allocator.free(string),
        .list => |items| freeArgumentSlice(allocator, items),
        .set => |items| freeArgumentSlice(allocator, items),
        .tagged => |tagged| {
            allocator.free(tagged.tag);
            freeArgumentSlice(allocator, tagged.value);
        },
        .keyword => |keyword| allocator.free(keyword),
        .@"struct" => |entries| freeStructEntries(allocator, entries),
        .big_integer => |big| allocator.free(big.digits),
        // POD arms own no heap storage; a new heap-carrying arm must add its
        // release above, and this explicit list makes the omission a compile error.
        .integer, .boolean, .void, .float64 => {},
    }
}

fn freeStructEntries(allocator: std.mem.Allocator, entries: []const model.StructEntry) void {
    for (entries) |entry| {
        allocator.free(entry.key);
        freeArgument(allocator, entry.value);
    }
    allocator.free(entries);
}

pub fn cloneArgumentSlice(allocator: std.mem.Allocator, items: []const model.Argument) model.view.Error![]model.Argument {
    return model.view.Args.fromOwnedSlice(items).toOwnedSlice(allocator);
}

/// Requested payload bytes an owned clone of `items` allocates, excluding
/// allocator metadata and alignment padding. Queue admission uses this before
/// cloning, so a refused actor message mutates no queue and allocates nothing.
/// The walk mirrors `cloneArgumentSlice`/`freeArgumentSlice` exhaustively; a new
/// heap-carrying model arm must state its charge here or fail to compile.
pub fn measureArgumentSliceOwnedBytes(items: []const model.Argument) model.view.ProjectError!usize {
    var total: usize = 0;
    try addProduct(&total, items.len, @sizeOf(model.Argument));
    for (items) |item| try measureArgument(&total, item, 0);
    return total;
}

/// Requested payload bytes an owned `Message` retains, excluding allocator
/// metadata and alignment padding.  Engine outbound admission calls this once
/// when a message enters its staged queue; the charge travels with that queue
/// row until encoding, so later admission checks never rescan the payload.
pub fn measureMessageOwnedBytes(message: model.Message) model.view.ProjectError!usize {
    var total: usize = @sizeOf(model.Message);
    switch (message) {
        .deliver => |deliver| {
            try measureReference(&total, deliver.target, 0);
            try addProduct(&total, deliver.args.len, @sizeOf(model.Argument));
            for (deliver.args) |arg| try measureArgument(&total, arg, 0);
            if (deliver.resolve_me_desc) |reference| try measureReference(&total, reference, 0);
        },
        .resolve => |resolve| try measureResolution(&total, resolve.resolution),
        .gc_export => |gc| {
            try addProduct(&total, gc.positions.len, @sizeOf(u64));
            try addProduct(&total, gc.deltas.len, @sizeOf(u64));
        },
        .gc_answer => |gc| try addProduct(&total, gc.positions.len, @sizeOf(u64)),
        .start_session => |start| {
            try addBytes(&total, start.session_pubkey.bytes.len);
            try measurePeerLocator(&total, start.acceptable_location);
            try addBytes(&total, start.acceptable_location_sig.bytes.len);
        },
        .abort => |abort| try addBytes(&total, abort.message.len),
        .listen => |listen| {
            try measureReference(&total, listen.target, 0);
            try measureReference(&total, listen.listener, 0);
        },
        .get => |get| {
            try measureReference(&total, get.receiver, 0);
            try addBytes(&total, get.field.len);
        },
        .index => |index| {
            try measureReference(&total, index.receiver, 0);
            switch (index.index) {
                .integer => {},
                .big_integer => |big| try addBytes(&total, big.digits.len),
            }
        },
        .untag => |untag| {
            try measureReference(&total, untag.receiver, 0);
            try addBytes(&total, untag.tag.len);
        },
    }
    return total;
}

fn measureResolution(total: *usize, resolution: model.Resolution) model.view.ProjectError!void {
    switch (resolution) {
        .fulfill => |value| try measureArgument(total, value, 0),
        .@"break" => |reason| try addBytes(total, reason.message.len),
    }
}

fn measureArgument(total: *usize, argument: model.Argument, depth: usize) model.view.ProjectError!void {
    if (depth > model.max_value_depth) return error.MalformedView;
    switch (argument) {
        .bytes => |bytes| try addBytes(total, bytes.len),
        .symbol => |symbol| try addBytes(total, symbol.len),
        .reference => |reference| try measureReference(total, reference, depth),
        .@"error" => |err| try addBytes(total, err.message.len),
        .handoff => |handoff| {
            try addBytes(total, @sizeOf(model.Handoff));
            try measureHandoff(total, handoff.*);
        },
        .string => |string| try addBytes(total, string.len),
        .list => |items| try measureArgumentSlice(total, items, depth + 1),
        .set => |items| try measureArgumentSlice(total, items, depth + 1),
        .tagged => |tagged| {
            try addBytes(total, tagged.tag.len);
            try measureArgumentSlice(total, tagged.value, depth + 1);
        },
        .keyword => |keyword| try addBytes(total, keyword.len),
        .big_integer => |big| try addBytes(total, big.digits.len),
        .@"struct" => |entries| {
            try addProduct(total, entries.len, @sizeOf(model.StructEntry));
            for (entries) |entry| {
                try addBytes(total, entry.key.len);
                try measureArgument(total, entry.value, depth + 1);
            }
        },
        .integer, .boolean, .void, .float64 => {},
    }
}

fn measureArgumentSlice(total: *usize, items: []const model.Argument, depth: usize) model.view.ProjectError!void {
    if (depth > model.max_value_depth) return error.MalformedView;
    try addProduct(total, items.len, @sizeOf(model.Argument));
    for (items) |item| try measureArgument(total, item, depth);
}

fn measureReference(total: *usize, reference: model.Reference, depth: usize) model.view.ProjectError!void {
    switch (reference) {
        .near, .far => {},
        .broken => |broken| try addBytes(total, broken.message.len),
        .sturdy => |sturdy| {
            try addBytes(total, @sizeOf(model.SturdyRef));
            try measurePeerLocator(total, sturdy.peer);
            try addBytes(total, sturdy.swissnum.len);
        },
        .promise => |promise| {
            try addProduct(total, promise.path.ops.len, @sizeOf(model.PipelineOp));
            for (promise.path.ops) |op| switch (op) {
                .field => |field| try addBytes(total, field.len),
                .call => |args| try measureArgumentSlice(total, args, depth + 1),
            };
        },
    }
}

fn measureHandoff(total: *usize, handoff: model.Handoff) model.view.ProjectError!void {
    switch (handoff) {
        .give => |give| try measureHandoffGive(total, give),
        .receive => |receive| {
            try addBytes(total, receive.receiving_session.len);
            try addBytes(total, receive.receiving_side.len);
            try measureHandoffGive(total, receive.signed_give);
            try addBytes(total, receive.signature.len);
        },
    }
}

fn measureHandoffGive(total: *usize, give: model.HandoffGive) model.view.ProjectError!void {
    try addBytes(total, give.recipient_key.len);
    try measurePeerLocator(total, give.exporter);
    try addBytes(total, give.gifter_exporter_session.len);
    try addBytes(total, give.gifter_side.len);
    try addBytes(total, give.gift_id.len);
    try addBytes(total, give.signature.len);
    if (give.raw_signed) |raw| try addBytes(total, raw.len);
}

fn measurePeerLocator(total: *usize, locator: model.PeerLocator) model.view.ProjectError!void {
    try addBytes(total, locator.transport.len);
    try addBytes(total, locator.designator.len);
    try addProduct(total, locator.hints.entries.len, @sizeOf(model.HintEntry));
    for (locator.hints.entries) |entry| {
        try addBytes(total, entry.name.len);
        switch (entry.value) {
            .string => |string| try addBytes(total, string.len),
            .bytes => |bytes| try addBytes(total, bytes.len),
            .boolean, .integer => {},
        }
    }
}

fn addProduct(total: *usize, count: usize, size: usize) model.view.ProjectError!void {
    const bytes = std.math.mul(usize, count, size) catch return error.MalformedView;
    try addBytes(total, bytes);
}

fn addBytes(total: *usize, bytes: usize) model.view.ProjectError!void {
    total.* = std.math.add(usize, total.*, bytes) catch return error.MalformedView;
}

pub fn freeArgumentSlice(allocator: std.mem.Allocator, items: []const model.Argument) void {
    for (items) |item| {
        freeArgument(allocator, item);
    }
    allocator.free(items);
}

pub fn freeResolution(allocator: std.mem.Allocator, resolution: model.Resolution) void {
    switch (resolution) {
        .fulfill => |arg| freeArgument(allocator, arg),
        .@"break" => |err| freeBreakReason(allocator, err),
    }
}

/// Copy an owned resolution into a second durable store (a session import row).
/// The fire owner keeps `resolution`; the caller moves the return into
/// `recordRelayedResolution` or frees it. Named for the introducing-session
/// proxy's one-home-listen → N recipient stores path — not a free-floating
/// fan-out API (see memory.md).
pub fn materializeResolutionForStore(allocator: std.mem.Allocator, resolution: model.Resolution) model.view.Error!model.Resolution {
    return model.view.Resolution.fromOwned(&resolution).toOwned(allocator);
}

fn freeBreakReason(allocator: std.mem.Allocator, err: model.BreakReason) void {
    allocator.free(err.message);
}

pub fn cloneReference(allocator: std.mem.Allocator, reference: model.Reference) model.view.Error!model.Reference {
    return model.view.Reference.fromOwned(&reference).toOwned(allocator);
}

pub fn freeReference(allocator: std.mem.Allocator, reference: model.Reference) void {
    switch (reference) {
        .sturdy => |sturdy| {
            freePeerLocator(allocator, sturdy.peer);
            allocator.free(sturdy.swissnum);
            allocator.destroy(sturdy);
        },
        .broken => |broken| allocator.free(broken.message),
        .promise => |promise| freePipelinePath(allocator, promise.path),
        // Position-only arms own no heap storage; a new heap-carrying arm must
        // add its release above, and this explicit list makes the omission a
        // compile error.
        .near, .far => {},
    }
}

fn freePipelinePath(allocator: std.mem.Allocator, path: model.PipelinePath) void {
    for (path.ops) |op| {
        freePipelineOp(allocator, op);
    }
    allocator.free(path.ops);
}

/// Free one owned `PipelineOp`: a `field`'s symbol or a `call`'s argument
/// slice. `freePipelinePath` and the view layer's path materialization both
/// release through this single definition.
pub fn freePipelineOp(allocator: std.mem.Allocator, op: model.PipelineOp) void {
    switch (op) {
        .field => |field| allocator.free(field),
        .call => |args| freeArgumentSlice(allocator, args),
    }
}

pub fn freeHandoff(allocator: std.mem.Allocator, handoff: model.Handoff) void {
    switch (handoff) {
        .give => |give| {
            freeHandoffGive(allocator, give);
        },
        .receive => |receive| {
            allocator.free(receive.receiving_session);
            allocator.free(receive.receiving_side);
            freeHandoffGive(allocator, receive.signed_give);
            allocator.free(receive.signature);
        },
    }
}

pub fn freeHandoffGive(allocator: std.mem.Allocator, give: model.HandoffGive) void {
    allocator.free(give.recipient_key);
    freePeerLocator(allocator, give.exporter);
    allocator.free(give.gifter_exporter_session);
    allocator.free(give.gifter_side);
    allocator.free(give.gift_id);
    allocator.free(give.signature);
    if (give.raw_signed) |raw| allocator.free(raw);
}

pub fn freePeerLocator(allocator: std.mem.Allocator, locator: model.PeerLocator) void {
    allocator.free(locator.transport);
    allocator.free(locator.designator);
    freeHints(allocator, locator.hints);
}

pub fn clonePeerLocator(allocator: std.mem.Allocator, locator: model.PeerLocator) std.mem.Allocator.Error!model.PeerLocator {
    const transport = try allocator.dupe(u8, locator.transport);
    errdefer allocator.free(transport);
    const designator = try allocator.dupe(u8, locator.designator);
    errdefer allocator.free(designator);
    const hints = try cloneHints(allocator, locator.hints);
    return .{ .transport = transport, .designator = designator, .hints = hints };
}

pub fn cloneHints(allocator: std.mem.Allocator, hints: model.Hints) std.mem.Allocator.Error!model.Hints {
    const entries = try allocator.alloc(model.HintEntry, hints.entries.len);
    errdefer allocator.free(entries);

    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |entry| {
            freeHintEntry(allocator, entry);
        }
    }

    for (hints.entries, 0..) |entry, i| {
        entries[i] = try cloneHintEntry(allocator, entry);
        initialized += 1;
    }

    return .{
        .entries = entries,
        .wire_form = hints.wire_form,
    };
}

pub fn freeHints(allocator: std.mem.Allocator, hints: model.Hints) void {
    for (hints.entries) |entry| {
        freeHintEntry(allocator, entry);
    }
    allocator.free(hints.entries);
}

fn cloneHintEntry(allocator: std.mem.Allocator, entry: model.HintEntry) std.mem.Allocator.Error!model.HintEntry {
    const name = try allocator.dupe(u8, entry.name);
    errdefer allocator.free(name);
    return .{
        .name = name,
        .value = try cloneHintValue(allocator, entry.value),
    };
}

pub fn freeHintEntry(allocator: std.mem.Allocator, entry: model.HintEntry) void {
    allocator.free(entry.name);
    freeHintValue(allocator, entry.value);
}

pub fn cloneHintValue(allocator: std.mem.Allocator, value: model.HintValue) std.mem.Allocator.Error!model.HintValue {
    return switch (value) {
        .string => |string| .{ .string = try allocator.dupe(u8, string) },
        .bytes => |bytes| .{ .bytes = try allocator.dupe(u8, bytes) },
        .boolean, .integer => value,
    };
}

pub fn freeHintValue(allocator: std.mem.Allocator, value: model.HintValue) void {
    switch (value) {
        .string => |string| allocator.free(string),
        .bytes => |bytes| allocator.free(bytes),
        .boolean, .integer => {},
    }
}
