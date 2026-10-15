//! The Host's values as borrowed views (ADR-0246). A `Value` tree an
//! application hands the Host becomes a `model.view.Args` sequence backed
//! by the values where they lie. The engine certifies and the codec
//! encodes those views; no owned argument tree is built to be thrown
//! away. A capability has no projection: it is the Host's opaque identity,
//! and only lowering under a session turns it into a wire reference, so a
//! tree that carries one takes the owned path (`carriesCapability`).

const std = @import("std");
const builtin = @import("builtin");

const model = @import("model");
const value_mod = @import("value.zig");

const view = model.view;
const Value = value_mod.Value;
const ProjectError = view.ProjectError;

/// `values` as a lazy argument sequence. Nothing is read until a consumer
/// walks it, and an element projects where it is read.
pub fn args(values: []const Value) view.Args {
    return .fromBacking(ctxOf(Value, values), &args_table.vtable);
}

/// `entries` as a lazy struct-entry sequence, keys and values borrowed.
pub fn structEntries(entries: []const Value.StructEntry) view.StructEntries {
    return .fromBacking(ctxOf(Value.StructEntry, entries), &entries_table.vtable);
}

/// One value as a view. A capability is `MalformedView`: the Host scans a
/// tree for one before lending it (`carriesCapability`), so a reader never
/// meets it on the freight path.
pub fn argument(value: *const Value) ProjectError!view.Argument {
    return switch (value.*) {
        .bytes => |b| .{ .bytes = b },
        .symbol => |s| .{ .symbol = s },
        .capability => error.MalformedView,
        .@"error" => |reason| .{ .@"error" = .{ .message = reason.message } },
        .string => |s| .{ .string = s },
        .integer => |i| .{ .integer = i },
        .integers => |words| .{ .list = integersView(words) },
        .boolean => |b| .{ .boolean = b },
        .list => |items| .{ .list = args(items) },
        .void => .{ .void = {} },
        .float64 => |f| .{ .float64 = f },
        .set => |items| .{ .set = args(items) },
        .tagged => |tagged| .{ .tagged = .{ .tag = tagged.tag, .value = args(tagged.value) } },
        .keyword => |k| .{ .keyword = k },
        .big_integer => |big| .{ .big_integer = big },
        .@"struct" => |entries| .{ .@"struct" = structEntries(entries) },
    };
}

/// A slice of integers as the list it means (ADR-0247): a run-backed view
/// where the host's words are the wire's, read where they lie, and one
/// element at a time on a big-endian host.
fn integersView(words: []const i64) view.Args {
    if (comptime builtin.cpu.arch.endian() == .little) return .fromRun(std.mem.sliceAsBytes(words));
    return .fromBacking(ctxOf(i64, words), &integers_table.vtable);
}

fn integerArgument(word: *const i64) ProjectError!view.Argument {
    return .{ .integer = word.* };
}

fn structEntry(entry: *const Value.StructEntry) ProjectError!view.StructEntry {
    return .{ .key = entry.key, .value = try argument(&entry.value) };
}

/// Whether any value in `values`, at any depth, is a capability. A tree
/// deeper than the Host copies is reported as carrying one, so the owned
/// path refuses it with its own reason.
pub fn carriesCapability(values: []const Value) bool {
    const Probe = struct {
        fn visit(_: void, _: value_mod.Capability) anyerror!void {
            return error.CapabilityFound;
        }
    };
    for (values) |*value| value.forEachCapability({}, Probe.visit) catch return true;
    return false;
}

/// The context lends the slice as its bytes and carries the element count
/// in `w0`, so a read recovers the slice without dividing the byte length.
fn ctxOf(comptime T: type, items: []const T) view.Args.Ctx {
    return .{ .bytes = std.mem.sliceAsBytes(items), .w0 = items.len };
}

fn itemsOf(comptime T: type, ctx: view.Args.Ctx) []const T {
    // The bytes are a slice of `T` the Host's caller owns, lent through the
    // context's byte region, so the cast restores the alignment they had.
    // An empty slice lends no pointer worth aligning.
    if (ctx.w0 == 0) return &.{};
    const items: [*]const T = @ptrCast(@alignCast(ctx.bytes.ptr));
    return items[0..@intCast(ctx.w0)];
}

/// The sequence readers for a slice of `T`, each element projected by
/// `project` where it is read.
fn Table(comptime Sequence: type, comptime T: type, comptime Elem: type, comptime project: fn (*const T) ProjectError!Elem) type {
    return struct {
        const vtable: Sequence.VTable = .{ .len = len, .at = at, .next = next, .tail = tail };

        fn len(ctx: view.Args.Ctx) ProjectError!usize {
            return itemsOf(T, ctx).len;
        }

        fn at(ctx: view.Args.Ctx, index: usize) ProjectError!Elem {
            const items = itemsOf(T, ctx);
            if (index >= items.len) return error.MalformedView;
            return project(&items[index]);
        }

        fn next(ctx: view.Args.Ctx, cursor: *u64, out: *Elem) ProjectError!bool {
            const items = itemsOf(T, ctx);
            if (cursor.* >= items.len) return false;
            out.* = try project(&items[@intCast(cursor.*)]);
            cursor.* += 1;
            return true;
        }

        fn tail(ctx: view.Args.Ctx, skip: usize) ProjectError!view.Args.Ctx {
            const items = itemsOf(T, ctx);
            if (skip > items.len) return error.MalformedView;
            return ctxOf(T, items[skip..]);
        }
    };
}

const args_table = Table(view.Args, Value, view.Argument, argument);
const integers_table = Table(view.Args, i64, view.Argument, integerArgument);
const entries_table = Table(view.StructEntries, Value.StructEntry, view.StructEntry, structEntry);
