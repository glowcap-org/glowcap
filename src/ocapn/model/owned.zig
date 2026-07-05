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

pub fn cloneMessage(allocator: std.mem.Allocator, message: model.Message) std.mem.Allocator.Error!model.Message {
    return switch (message) {
        .abort => |abort| .{
            .abort = .{
                .kind = abort.kind,
                .message = try allocator.dupe(u8, abort.message),
            },
        },
        .deliver => |deliver| blk: {
            const target = try cloneReference(allocator, deliver.target);
            errdefer freeReference(allocator, target);
            const resolve_me_desc = if (deliver.resolve_me_desc) |reference|
                try cloneReference(allocator, reference)
            else
                null;
            errdefer if (resolve_me_desc) |reference| freeReference(allocator, reference);
            const args = try cloneArgumentSlice(allocator, deliver.args);
            errdefer freeArgumentSlice(allocator, args);

            break :blk .{
                .deliver = .{
                    .target = target,
                    .args = args,
                    .answer = deliver.answer,
                    .resolve_me_desc = resolve_me_desc,
                },
            };
        },
        .resolve => |resolve| .{
            .resolve = .{
                .answer = resolve.answer,
                .resolution = try cloneResolution(allocator, resolve.resolution),
            },
        },
        .gc_export => |gc_export| blk: {
            const positions = try allocator.dupe(u64, gc_export.positions);
            errdefer allocator.free(positions);
            const deltas = try allocator.dupe(u64, gc_export.deltas);
            break :blk .{ .gc_export = .{ .positions = positions, .deltas = deltas } };
        },
        .gc_answer => |gc_answer| .{
            .gc_answer = .{ .positions = try allocator.dupe(u64, gc_answer.positions) },
        },
        .handoff => |handoff| .{ .handoff = try cloneHandoff(allocator, handoff) },
        .start_session => |start_session| blk: {
            const session_pubkey = try allocator.dupe(u8, start_session.session_pubkey.bytes);
            errdefer allocator.free(session_pubkey);
            const acceptable_location = try clonePeerLocator(allocator, start_session.acceptable_location);
            errdefer freePeerLocator(allocator, acceptable_location);
            const acceptable_location_sig = try allocator.dupe(u8, start_session.acceptable_location_sig.bytes);
            break :blk .{
                .start_session = .{
                    .captp_version = start_session.captp_version,
                    .session_pubkey = .{ .bytes = session_pubkey },
                    .acceptable_location = acceptable_location,
                    .acceptable_location_sig = .{ .bytes = acceptable_location_sig },
                },
            };
        },
        .listen => |listen| blk: {
            const target = try cloneReference(allocator, listen.target);
            errdefer freeReference(allocator, target);
            const listener = try cloneReference(allocator, listen.listener);
            break :blk .{
                .listen = .{
                    .target = target,
                    .listener = listener,
                    .wants_partial = listen.wants_partial,
                },
            };
        },
        .get => |get| blk: {
            const receiver = try cloneReference(allocator, get.receiver);
            errdefer freeReference(allocator, receiver);
            const field = try allocator.dupe(u8, get.field);
            break :blk .{
                .get = .{
                    .receiver = receiver,
                    .field = field,
                    .answer = get.answer,
                },
            };
        },
        .index => |index| blk: {
            const receiver = try cloneReference(allocator, index.receiver);
            break :blk .{
                .index = .{
                    .receiver = receiver,
                    .index = index.index,
                    .answer = index.answer,
                },
            };
        },
        .untag => |untag| blk: {
            const receiver = try cloneReference(allocator, untag.receiver);
            errdefer freeReference(allocator, receiver);
            const tag = try allocator.dupe(u8, untag.tag);
            break :blk .{
                .untag = .{
                    .receiver = receiver,
                    .tag = tag,
                    .answer = untag.answer,
                },
            };
        },
    };
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
        .handoff => |handoff| freeHandoff(allocator, handoff),
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
        },
        .untag => |untag| {
            freeReference(allocator, untag.receiver);
            allocator.free(untag.tag);
        },
    }
}

pub fn cloneArgument(allocator: std.mem.Allocator, argument: model.Argument) std.mem.Allocator.Error!model.Argument {
    return switch (argument) {
        .bytes => |bytes| .{ .bytes = try allocator.dupe(u8, bytes) },
        .symbol => |symbol| .{ .symbol = try allocator.dupe(u8, symbol) },
        .reference => |reference| .{ .reference = try cloneReference(allocator, reference) },
        .@"error" => |err| .{ .@"error" = try cloneBreakReason(allocator, err) },
        .handoff => |handoff| .{ .handoff = try cloneHandoffBoxed(allocator, handoff.*) },
        .string => |string| .{ .string = try allocator.dupe(u8, string) },
        .list => |items| .{ .list = try cloneArgumentSlice(allocator, items) },
        .set => |items| .{ .set = try cloneArgumentSlice(allocator, items) },
        .tagged => |tagged| blk: {
            const tag = try allocator.dupe(u8, tagged.tag);
            errdefer allocator.free(tag);
            const value = try cloneArgumentSlice(allocator, tagged.value);
            break :blk .{ .tagged = .{ .tag = tag, .value = value } };
        },
        .keyword => |keyword| .{ .keyword = try allocator.dupe(u8, keyword) },
        .@"struct" => |entries| .{ .@"struct" = try cloneStructEntries(allocator, entries) },
        .big_integer => |big| .{ .big_integer = .{
            .negative = big.negative,
            .digits = try allocator.dupe(u8, big.digits),
        } },
        // POD arms own no heap storage; a new heap-carrying arm must add its
        // clone above, and this explicit list makes the omission a compile error.
        .integer, .boolean, .void, .float64 => argument,
    };
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

fn cloneStructEntries(allocator: std.mem.Allocator, entries: []const model.StructEntry) std.mem.Allocator.Error![]model.StructEntry {
    const cloned = try allocator.alloc(model.StructEntry, entries.len);
    errdefer allocator.free(cloned);

    var initialized: usize = 0;
    errdefer for (cloned[0..initialized]) |entry| {
        allocator.free(entry.key);
        freeArgument(allocator, entry.value);
    };

    for (entries, 0..) |entry, i| {
        const key = try allocator.dupe(u8, entry.key);
        errdefer allocator.free(key);
        cloned[i] = .{ .key = key, .value = try cloneArgument(allocator, entry.value) };
        initialized += 1;
    }

    return cloned;
}

fn freeStructEntries(allocator: std.mem.Allocator, entries: []const model.StructEntry) void {
    for (entries) |entry| {
        allocator.free(entry.key);
        freeArgument(allocator, entry.value);
    }
    allocator.free(entries);
}

pub fn cloneArgumentSlice(allocator: std.mem.Allocator, items: []const model.Argument) std.mem.Allocator.Error![]model.Argument {
    const cloned = try allocator.alloc(model.Argument, items.len);
    errdefer allocator.free(cloned);

    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |item| {
            freeArgument(allocator, item);
        }
    }

    for (items, 0..) |item, i| {
        cloned[i] = try cloneArgument(allocator, item);
        initialized += 1;
    }

    return cloned;
}

fn freeArgumentSlice(allocator: std.mem.Allocator, items: []const model.Argument) void {
    for (items) |item| {
        freeArgument(allocator, item);
    }
    allocator.free(items);
}

fn cloneResolution(allocator: std.mem.Allocator, resolution: model.Resolution) std.mem.Allocator.Error!model.Resolution {
    return switch (resolution) {
        .fulfill => |arg| .{ .fulfill = try cloneArgument(allocator, arg) },
        .@"break" => |err| .{ .@"break" = try cloneBreakReason(allocator, err) },
    };
}

pub fn freeResolution(allocator: std.mem.Allocator, resolution: model.Resolution) void {
    switch (resolution) {
        .fulfill => |arg| freeArgument(allocator, arg),
        .@"break" => |err| freeBreakReason(allocator, err),
    }
}

fn cloneBreakReason(allocator: std.mem.Allocator, err: model.BreakReason) std.mem.Allocator.Error!model.BreakReason {
    return .{ .message = try allocator.dupe(u8, err.message) };
}

fn freeBreakReason(allocator: std.mem.Allocator, err: model.BreakReason) void {
    allocator.free(err.message);
}

pub fn cloneReference(allocator: std.mem.Allocator, reference: model.Reference) std.mem.Allocator.Error!model.Reference {
    return switch (reference) {
        .near, .far => reference,
        .promise => |promise| .{ .promise = .{
            .answer_position = promise.answer_position,
            .path = try clonePipelinePath(allocator, promise.path),
        } },
        .sturdy => |sturdy| blk: {
            const peer = try clonePeerLocator(allocator, sturdy.peer);
            errdefer freePeerLocator(allocator, peer);
            const swissnum = try allocator.dupe(u8, sturdy.swissnum);
            break :blk .{ .sturdy = .{ .peer = peer, .swissnum = swissnum } };
        },
        .broken => |broken| .{ .broken = .{ .message = try allocator.dupe(u8, broken.message) } },
    };
}

pub fn freeReference(allocator: std.mem.Allocator, reference: model.Reference) void {
    switch (reference) {
        .sturdy => |sturdy| {
            freePeerLocator(allocator, sturdy.peer);
            allocator.free(sturdy.swissnum);
        },
        .broken => |broken| allocator.free(broken.message),
        .promise => |promise| freePipelinePath(allocator, promise.path),
        // Position-only arms own no heap storage; a new heap-carrying arm must
        // add its release above, and this explicit list makes the omission a
        // compile error.
        .near, .far => {},
    }
}

/// Deep-clone a `PipelinePath`: the `ops` slice plus each op's payload (a
/// `call`'s args, a `field`'s symbol). Free it with `freePipelinePath`. An empty
/// path clones to the shared empty slice and allocates nothing.
fn clonePipelinePath(allocator: std.mem.Allocator, path: model.PipelinePath) std.mem.Allocator.Error!model.PipelinePath {
    if (path.ops.len == 0) return .{};
    const ops = try allocator.alloc(model.PipelineOp, path.ops.len);
    errdefer allocator.free(ops);

    var initialized: usize = 0;
    errdefer {
        for (ops[0..initialized]) |op| {
            freePipelineOp(allocator, op);
        }
    }

    for (path.ops, 0..) |op, i| {
        ops[i] = try clonePipelineOp(allocator, op);
        initialized += 1;
    }
    return .{ .ops = ops };
}

fn freePipelinePath(allocator: std.mem.Allocator, path: model.PipelinePath) void {
    for (path.ops) |op| {
        freePipelineOp(allocator, op);
    }
    allocator.free(path.ops);
}

fn clonePipelineOp(allocator: std.mem.Allocator, op: model.PipelineOp) std.mem.Allocator.Error!model.PipelineOp {
    return switch (op) {
        .field => |field| .{ .field = try allocator.dupe(u8, field) },
        .call => |args| .{ .call = try cloneArgumentSlice(allocator, args) },
    };
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

/// Clone a `Handoff` into a fresh box for the owned `Argument.handoff` arm. We
/// allocate the box first, on purpose: if the clone then fails, we destroy the
/// empty box and leak nothing, and if the box itself can't be allocated, there's
/// nothing to clean up.
fn cloneHandoffBoxed(allocator: std.mem.Allocator, handoff: model.Handoff) std.mem.Allocator.Error!*model.Handoff {
    const boxed = try allocator.create(model.Handoff);
    errdefer allocator.destroy(boxed);
    boxed.* = try cloneHandoff(allocator, handoff);
    return boxed;
}

fn cloneHandoff(allocator: std.mem.Allocator, handoff: model.Handoff) std.mem.Allocator.Error!model.Handoff {
    return switch (handoff) {
        .give => |give| .{ .give = try cloneHandoffGive(allocator, give) },
        .receive => |receive| blk: {
            const receiving_session = try allocator.dupe(u8, receive.receiving_session);
            errdefer allocator.free(receiving_session);
            const receiving_side = try allocator.dupe(u8, receive.receiving_side);
            errdefer allocator.free(receiving_side);
            const signed_give = try cloneHandoffGive(allocator, receive.signed_give);
            errdefer freeHandoffGive(allocator, signed_give);
            const signature = try allocator.dupe(u8, receive.signature);
            break :blk .{
                .receive = .{
                    .receiving_session = receiving_session,
                    .receiving_side = receiving_side,
                    .handoff_count = receive.handoff_count,
                    .signed_give = signed_give,
                    .signature = signature,
                },
            };
        },
    };
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

fn cloneHandoffGive(allocator: std.mem.Allocator, give: model.HandoffGive) std.mem.Allocator.Error!model.HandoffGive {
    const recipient_key = try allocator.dupe(u8, give.recipient_key);
    errdefer allocator.free(recipient_key);
    const exporter_location = try allocator.dupe(u8, give.exporter_location);
    errdefer allocator.free(exporter_location);
    const gifter_exporter_session = try allocator.dupe(u8, give.gifter_exporter_session);
    errdefer allocator.free(gifter_exporter_session);
    const gifter_side = try allocator.dupe(u8, give.gifter_side);
    errdefer allocator.free(gifter_side);
    const gift_id = try allocator.dupe(u8, give.gift_id);
    errdefer allocator.free(gift_id);
    const signature = try allocator.dupe(u8, give.signature);
    errdefer allocator.free(signature);
    const raw_signed: ?[]const u8 = if (give.raw_signed) |raw| try allocator.dupe(u8, raw) else null;
    return .{
        .recipient_key = recipient_key,
        .exporter_location = exporter_location,
        .gifter_exporter_session = gifter_exporter_session,
        .gifter_side = gifter_side,
        .gift_id = gift_id,
        .signature = signature,
        .raw_signed = raw_signed,
    };
}

pub fn freeHandoffGive(allocator: std.mem.Allocator, give: model.HandoffGive) void {
    allocator.free(give.recipient_key);
    allocator.free(give.exporter_location);
    allocator.free(give.gifter_exporter_session);
    allocator.free(give.gifter_side);
    allocator.free(give.gift_id);
    allocator.free(give.signature);
    if (give.raw_signed) |raw| allocator.free(raw);
}

/// Make a deep copy of a `PeerLocator` (its transport, designator, and hint map).
/// Free it again with `freePeerLocator`. The engine reaches for this when it
/// needs to hold onto a locator past the frame it came in on: a borrowed
/// `op:start-session` or `desc:sturdyref` gets queued for sending, and it has to
/// outlive the borrowed frame.
fn clonePeerLocator(allocator: std.mem.Allocator, locator: model.PeerLocator) std.mem.Allocator.Error!model.PeerLocator {
    const transport = try allocator.dupe(u8, locator.transport);
    errdefer allocator.free(transport);
    const designator = try allocator.dupe(u8, locator.designator);
    errdefer allocator.free(designator);
    const hints = try cloneHints(allocator, locator.hints);
    return .{
        .transport = transport,
        .designator = designator,
        .hints = hints,
    };
}

pub fn freePeerLocator(allocator: std.mem.Allocator, locator: model.PeerLocator) void {
    allocator.free(locator.transport);
    allocator.free(locator.designator);
    freeHints(allocator, locator.hints);
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
