//! Certification of a borrowed outbound argument tree (ADR-0246).
//!
//! A caller may lend a deliver's arguments as views instead of an owned
//! tree: the Host's values behind a sequence table, or a delivery a handler
//! forwards from the frame it arrived in. No inventory walked such a tree and
//! no pass rewrites it, so this walk holds it to what the inventory walk
//! certifies on an owned tree (`inventory.zig`): the nesting bound, struct
//! key uniqueness, and set element uniqueness. It also refuses a reference
//! or handoff anywhere in it, because a tree that names one needs lowering,
//! shortening, and a retain, which only the owned path gives it. The
//! certified tree then has nothing the session acts on, and the encoder
//! reads it once. The walk also measures the tree as the owned model
//! measures it, so admission charges freight before its frame exists, and
//! sizes its values with the codec's meter, so the encoder reads it once
//! (ADR-0253).

const std = @import("std");
const model = @import("model");
const session = @import("../mod.zig");
const passable = @import("passable.zig");
const set_uniqueness = @import("set_uniqueness.zig");

const Session = session.Session;
const Error = session.Error;

pub const FreightError = passable.SendArgError || model.view.ProjectError;

/// What certification learned about a freight tree.
pub const Freight = struct {
    /// The bytes an owned copy of the tree would retain, the measure
    /// `model.measureArgumentSliceOwnedBytes` gives an owned tree.
    owned_bytes: usize,
    /// The codec bytes of the tree's values as `Meter` sized them, outside
    /// the list they ride in, as `Inventory.wire_bytes` counts an owned tree.
    wire_bytes: usize,
};

/// Certify `args` as freight: values only, within the session's bounds,
/// and measure it for admission and for the encoder. A refusal commits
/// nothing. The set fold's scratch is the session's allocator, stack-first,
/// as the owned send path's fold uses.
pub fn certifyFreight(self: *Session, args: model.view.Args, comptime Meter: type) FreightError!Freight {
    var walk: Walk(Meter) = .{ .session = self };
    try walk.items(args, 0);
    if (walk.bytes == std.math.maxInt(usize) or walk.wire == std.math.maxInt(usize)) return error.MalformedView;
    return .{ .owned_bytes = walk.bytes, .wire_bytes = walk.wire };
}

fn Walk(comptime Meter: type) type {
    return struct {
        session: *Session,
        /// Both totals saturate as the inventory walk's do, refused once at
        /// the end.
        bytes: usize = 0,
        wire: usize = 0,

        const Self = @This();

        /// The nesting bound is the send-side threshold the inventory walk
        /// applies: a container's items sit one level deeper than it, an empty
        /// container included, so a borrowed tree and an owned tree refuse at
        /// the same depth.
        fn items(self: *Self, args: model.view.Args, depth: usize) FreightError!void {
            if (depth > self.session.limits.max_nesting_depth) return error.NestingTooDeep;
            // A run may come from a Host caller as well as a bounded wire frame.
            if (args.wordRun()) |run| {
                // A run whose charge saturates is refused before a word is read.
                self.bytes +|= (run.len / 8) *| @sizeOf(model.Argument);
                if (self.bytes == std.math.maxInt(usize)) return error.MalformedView;
                if (comptime Meter == session.inventory.NoMeter) return;
                var offset: usize = 0;
                while (offset < run.len) : (offset += 8)
                    self.wire +|= Meter.shallow(model.Argument{ .integer = std.mem.readInt(i64, run[offset..][0..8], .little) });
                return;
            }
            const count = try args.len();
            var visited: usize = 0;
            var it = args.iterator();
            while (try it.nextRef()) |item| {
                if (visited == count) return error.MalformedView;
                visited += 1;
                self.bytes +|= @sizeOf(model.Argument);
                try self.argument(item, depth);
            }
            if (visited != count) return error.MalformedView;
        }

        fn argument(self: *Self, arg: *const model.view.Argument, depth: usize) FreightError!void {
            self.wire +|= Meter.shallow(arg.*);
            switch (arg.*) {
                // Freight carries values only. A reference or handoff here is a
                // caller that vouched for a tree it did not scan, refused before
                // any authority is touched.
                .reference, .handoff => return error.MalformedMessage,
                .list => |list| try self.items(list, depth + 1),
                .set => |set| {
                    try self.items(set, depth + 1);
                    // A duplicate refuses here, pre-commit, as the owned path's
                    // fold does after shortening (`passable.certifySent`).
                    // Nothing in freight is shortened, so the fold runs on the
                    // tree as lent.
                    var compare_budget = model.equality.CompareBudget.init(self.session.limits.max_compare_visits);
                    try set_uniqueness.checkBorrowed(self.session.allocator, set, &compare_budget);
                },
                .tagged => |tagged| {
                    self.bytes +|= tagged.tag.len;
                    try self.items(tagged.value, depth + 1);
                },
                .@"struct" => |entries| {
                    if (depth + 1 > self.session.limits.max_nesting_depth) return error.NestingTooDeep;
                    const count = try entries.len();
                    var visited: usize = 0;
                    var it = entries.iterator();
                    while (try it.nextRef()) |entry| {
                        if (visited == count) return error.MalformedView;
                        visited += 1;
                        self.bytes +|= @sizeOf(model.StructEntry) +| entry.key.len;
                        self.wire +|= Meter.key(entry.key);
                        try self.argument(&entry.value, depth + 1);
                    }
                    if (visited != count) return error.MalformedView;
                    try passable.checkSentStructKeyUniqueness(self.session.allocator, entries);
                },
                .bytes, .symbol, .string, .keyword => |text| self.bytes +|= text.len,
                .@"error" => |err| self.bytes +|= err.message.len,
                .big_integer => |big| self.bytes +|= big.digits.len,
                .integer, .boolean, .float64, .void => {},
            }
        }
    };
}
