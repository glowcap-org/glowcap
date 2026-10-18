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
//! `clone*` is the single exception we call out by name: the boundary copy in
//! `Peer.sendBorrowed`, for the kinds the queue keeps when a caller lends
//! borrowed or static data. Everything internal goes through `Peer.send` and
//! never clones.
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
/// The walk mirrors `cloneArgumentSlice`/`freeArgumentSlice` exhaustively. A new
/// heap-carrying model arm must state its charge here or fail to compile.
pub fn measureArgumentSliceOwnedBytes(items: []const model.Argument) model.view.ProjectError!usize {
    var total: usize = 0;
    addProduct(&total, items.len, @sizeOf(model.Argument));
    for (items) |item| try measureArgument(&total, item, 0);
    return settled(total);
}

/// Requested payload bytes an owned `Reference` retains, excluding allocator
/// metadata and the inline union itself. Long-lived owners use this before
/// adoption so a bounded row count cannot hide variable-size reference trees.
pub fn measureReferenceOwnedBytes(reference: model.Reference) model.view.ProjectError!usize {
    var total: usize = 0;
    measureReference(&total, reference);
    return settled(total);
}

/// Requested payload bytes an owned `Message` retains, excluding allocator
/// metadata and alignment padding.  Engine outbound admission calls this once
/// when a message enters its staged queue. The charge travels with that queue
/// row until encoding, so later admission checks never rescan the payload.
pub fn measureMessageOwnedBytes(message: model.Message) model.view.ProjectError!usize {
    var total = try measureMessageEnvelopeBytes(message);
    switch (message) {
        .deliver => |deliver| addBytes(&total, try measureArgumentSliceOwnedBytes(deliver.args)),
        .resolve => |resolve| try measureResolution(&total, resolve.resolution),
        else => {},
    }
    return settled(total);
}

/// Bytes a `Message` retains outside the tree it carries: its own value, the
/// references it names at the top, and every kind's scalar payload. A
/// deliver's argument tree and a resolve's resolution are measured apart,
/// by the session's inventory walk on the outbound path.
pub fn measureMessageEnvelopeBytes(message: model.Message) model.view.ProjectError!usize {
    var total: usize = @sizeOf(model.Message);
    switch (message) {
        .deliver => |deliver| {
            measureReference(&total, deliver.target);
            if (deliver.resolve_me_desc) |reference| measureReference(&total, reference);
        },
        .resolve => {},
        .gc_export => |gc| {
            addProduct(&total, gc.positions.len, @sizeOf(u64));
            addProduct(&total, gc.deltas.len, @sizeOf(u64));
        },
        .gc_answer => |gc| addProduct(&total, gc.positions.len, @sizeOf(u64)),
        .start_session => |start| {
            addBytes(&total, start.session_pubkey.bytes.len);
            measurePeerLocator(&total, &start.acceptable_location);
            addBytes(&total, start.acceptable_location_sig.bytes.len);
        },
        .abort => |abort| addBytes(&total, abort.message.len),
        .listen => |listen| {
            measureReference(&total, listen.target);
            measureReference(&total, listen.listener);
        },
        .get => |get| {
            measureReference(&total, get.receiver);
            addBytes(&total, get.field.len);
        },
        .index => |index| {
            measureReference(&total, index.receiver);
            switch (index.index) {
                .integer => {},
                .big_integer => |big| addBytes(&total, big.digits.len),
            }
        },
        .untag => |untag| {
            measureReference(&total, untag.receiver);
            addBytes(&total, untag.tag.len);
        },
    }
    return settled(total);
}

/// Requested payload bytes retained by one owned semantic resolution. The
/// inline union is included so callers can charge a resolution without
/// manufacturing a wire `op:resolve` message around it.
pub fn measureResolutionOwnedBytes(resolution: model.Resolution) model.view.ProjectError!usize {
    var total: usize = @sizeOf(model.Resolution);
    try measureResolution(&total, resolution);
    return settled(total);
}

fn measureResolution(total: *usize, resolution: model.Resolution) model.view.ProjectError!void {
    switch (resolution) {
        .fulfill => |value| try measureArgument(total, value, 0),
        .@"break" => |reason| addBytes(total, reason.message.len),
    }
}

fn measureArgument(total: *usize, argument: model.Argument, depth: usize) model.view.ProjectError!void {
    if (depth > model.max_value_depth) return error.MalformedView;
    addShallowOwnedBytes(total, argument);
    switch (argument) {
        .list, .set => |items| try measureArgumentSlice(total, items, depth + 1),
        .tagged => |tagged| try measureArgumentSlice(total, tagged.value, depth + 1),
        .@"struct" => |entries| for (entries) |entry| try measureArgument(total, entry.value, depth + 1),
        else => {},
    }
}

/// Bytes `argument` retains outside its children: a leaf's payload, or a
/// container's own slice and keys.
pub inline fn addShallowOwnedBytes(total: *usize, argument: model.Argument) void {
    switch (argument) {
        inline else => |*payload, tag| addShallowOwnedBytesOf(tag, total, payload),
    }
}

/// `addShallowOwnedBytes` for one kind known at compile time, with the
/// payload read where it lies. The session's inventory walk
/// (`session/inventory.zig`) dispatches on the tag once and resolves this
/// measure, the wire meter, and the descent from it, so one arm table
/// serves both measures without a second dispatch per argument.
pub inline fn addShallowOwnedBytesOf(comptime tag: std.meta.Tag(model.Argument), total: *usize, payload: anytype) void {
    switch (tag) {
        .bytes, .symbol, .string, .keyword => addBytes(total, payload.len),
        .reference => measureReference(total, payload.*),
        .@"error" => addBytes(total, payload.message.len),
        .handoff => {
            addBytes(total, @sizeOf(model.Handoff));
            measureHandoff(total, payload.*);
        },
        .list, .set => addArgumentSliceOwnedBytes(total, payload.len),
        .tagged => {
            addBytes(total, payload.tag.len);
            addArgumentSliceOwnedBytes(total, payload.value.len);
        },
        .big_integer => addBytes(total, payload.digits.len),
        .@"struct" => {
            addProduct(total, payload.len, @sizeOf(model.StructEntry));
            for (payload.*) |entry| addBytes(total, entry.key.len);
        },
        .integer, .boolean, .void, .float64 => {},
    }
}

/// The slice an argument vector itself occupies.
pub fn addArgumentSliceOwnedBytes(total: *usize, len: usize) void {
    addProduct(total, len, @sizeOf(model.Argument));
}

fn measureArgumentSlice(total: *usize, items: []const model.Argument, depth: usize) model.view.ProjectError!void {
    if (depth > model.max_value_depth) return error.MalformedView;
    for (items) |item| try measureArgument(total, item, depth);
}

fn measureReference(total: *usize, reference: model.Reference) void {
    switch (reference) {
        .near, .far, .routed => {},
        .broken => |broken| addBytes(total, broken.message.len),
        .sturdy => |sturdy| {
            addBytes(total, @sizeOf(model.SturdyRef));
            measurePeerLocator(total, &sturdy.peer);
            addBytes(total, sturdy.swissnum.len);
        },
        .promise => {},
    }
}

/// A handoff is read where it lies: its box is about 200 bytes, and every
/// argument's measure shares this function's frame.
fn measureHandoff(total: *usize, handoff: *const model.Handoff) void {
    switch (handoff.*) {
        .give => |*give| measureHandoffGive(total, give),
        .receive => |*receive| {
            addBytes(total, receive.receiving_session.len);
            addBytes(total, receive.receiving_side.len);
            measureHandoffGive(total, &receive.signed_give);
            addBytes(total, receive.signature.len);
        },
    }
}

fn measureHandoffGive(total: *usize, give: *const model.HandoffGive) void {
    addBytes(total, give.recipient_key.len);
    measurePeerLocator(total, &give.exporter);
    addBytes(total, give.gifter_exporter_session.len);
    addBytes(total, give.gifter_side.len);
    addBytes(total, give.gift_id.len);
    addBytes(total, give.signature.len);
    if (give.raw_signed) |raw| addBytes(total, raw.len);
}

fn measurePeerLocator(total: *usize, locator: *const model.PeerLocator) void {
    addBytes(total, locator.transport.len);
    addBytes(total, locator.designator.len);
    addProduct(total, locator.hints.entries.len, @sizeOf(model.HintEntry));
    for (locator.hints.entries) |entry| {
        addBytes(total, entry.name.len);
        switch (entry.value) {
            .string => |string| addBytes(total, string.len),
            .bytes => |bytes| addBytes(total, bytes.len),
            .boolean, .integer => {},
        }
    }
}

/// A measure saturates instead of checking every addition: the address
/// space bounds what a live tree can add, and a total that reaches the
/// ceiling names a tree no process holds, which `settled` refuses once.
fn addProduct(total: *usize, count: usize, size: usize) void {
    addBytes(total, count *| size);
}

fn addBytes(total: *usize, bytes: usize) void {
    total.* +|= bytes;
}

/// A measure's one refusal: a saturated total is malformed, as an
/// overflowing addition was.
fn settled(total: usize) model.view.ProjectError!usize {
    if (total == std.math.maxInt(usize)) return error.MalformedView;
    return total;
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

/// Copy an owned resolution into a second durable store (a recipient's answer
/// row). The fire owner keeps `resolution`. The caller settles the return or
/// frees it. Named for the introducing-session proxy's one-home-listen to N
/// recipient stores path, not a free-floating fan-out API (see memory.md).
pub fn materializeResolutionForStore(allocator: std.mem.Allocator, resolution: model.Resolution) model.view.Error!model.Resolution {
    return model.view.Resolution.fromOwned(&resolution).toOwned(allocator);
}

fn freeBreakReason(allocator: std.mem.Allocator, err: model.BreakReason) void {
    allocator.free(err.message);
}

pub fn cloneReference(allocator: std.mem.Allocator, reference: model.Reference) model.view.Error!model.Reference {
    if (reference == .routed) return reference;
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
        // Position-only arms own no heap storage; a new heap-carrying arm must
        // add its release above, and this explicit list makes the omission a
        // compile error.
        .near, .far, .routed, .promise => {},
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
