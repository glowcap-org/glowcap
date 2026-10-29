//! Vat local time-travel (snapshot / restore / divergence): the S5 benchmark.
//!
//! The snapshot half of the glowcap-vs-Goblins suite (`bench/goblins/`).
//! snapshot/restore is a *local* `actors.Vat` API, not a wire conversation, and
//! it is not projected over the C ABI the Racket binding drives, so the two
//! runtimes are measured in-process, side by side: glowcap here in Zig, Goblins in
//! `bench/goblins/snapshot.rkt`. Because that pits Zig against
//! Racket/Chez, compare the *shape* of each cost and the *algorithmic tradeoff*,
//! not the absolute nanoseconds.
//!
//! Every number is the median of repeated samples taken after a warmup, the same
//! hygiene the wire suite and the Goblins half apply.
//!
//! Three axes (ADR-0015):
//!
//!   1. **Snapshot is O(objects), not O(bytes).** Sharing each actor's state box
//!      by refcount copies no state bytes, so snapshot time grows with the object
//!      count and stays flat as the bytes-per-object grow.
//!   2. **Restore** rebuilds the live heap from a snapshot after every actor has
//!      diverged. glowcap frees the rewound copies eagerly (no collector). The
//!      Goblins analog leaves that cleanup to its GC, measured with the
//!      difference named rather than hidden.
//!   3. **Divergence**: mutating structured state while a snapshot is
//!      outstanding, the workload that motivates time-travel. A glowcap
//!      *mutable* actor pays a copy-on-write of its whole state, O(N). A glowcap
//!      *persistent* actor (`become` + `PersistentMap`) path-copies, O(log N),
//!      the same shape as Goblins' immutable `bcom`. For large structured state
//!      the functional flavors win, glowcap offers both, so an actor that never
//!      snapshots pays nothing.
//!
//! Run `zig build bench-snapshot` for the full run (writes a report under
//! `zig-out/bench-reports/`). `--smoke` (used by `zig build check`) runs tiny
//! counts and skips the report.

const std = @import("std");
const glowcap = @import("glowcap");
const persistent = @import("loam_collections");

const actors = glowcap.actors;
const model = glowcap.ocapn.model;

const PMap = persistent.PersistentMap(u64);
/// A key never inserted, so `PMap.remove(absent_key)` is the cheap O(1) way to
/// hand each actor its own independently-owned reference to a shared base map.
const absent_key: u64 = std.math.maxInt(u64);

const max_samples = 32;

const Blob = struct {
    allocator: std.mem.Allocator,
    data: []u8,

    pub fn handle(self: *Blob, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        _ = turn;
        if (if (msg.verb) |method| method.len > 0 and method[0] == 't' else false) {
            self.data[0] +%= 1;
            return .{ .void = {} };
        }
        return .{ .integer = self.data[0] };
    }

    pub fn clone(self: *const Blob, allocator: std.mem.Allocator) std.mem.Allocator.Error!Blob {
        const data = try allocator.dupe(u8, self.data);
        return .{ .allocator = allocator, .data = data };
    }

    pub fn deinit(self: *Blob, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

const MapMut = struct {
    allocator: std.mem.Allocator,
    entries: []u64,

    pub fn handle(self: *MapMut, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        _ = turn;
        if (if (msg.verb) |method| method.len > 0 and method[0] == 't' else false) {
            self.entries[0] +%= 1;
            return .{ .void = {} };
        }
        return .{ .integer = @bitCast(self.entries[0]) };
    }

    pub fn clone(self: *const MapMut, allocator: std.mem.Allocator) std.mem.Allocator.Error!MapMut {
        const entries = try allocator.dupe(u64, self.entries);
        return .{ .allocator = allocator, .entries = entries };
    }

    pub fn deinit(self: *MapMut, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }
};

const MapPersistent = struct {
    pub const snapshot_persistent = true;
    map: PMap,

    pub fn handle(self: *const MapPersistent, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        if (if (msg.verb) |method| method.len > 0 and method[0] == 't' else false) {
            var next = try self.map.put(0, (self.map.get(0) orelse 0) +% 1);
            turn.become(MapPersistent, .{ .map = next }) catch |e| {
                next.deinit();
                return e;
            };
            return .{ .void = {} };
        }
        return .{ .integer = @bitCast(self.map.get(0) orelse 0) };
    }

    pub fn deinit(self: *MapPersistent, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.map.deinit();
    }
};

const Population = struct {
    vat: actors.Vat,
    refs: []actors.Ref,
    allocator: std.mem.Allocator,

    fn build(allocator: std.mem.Allocator, k: usize, m: usize) !Population {
        var vat = actors.Vat.init(allocator);
        errdefer vat.deinit();
        const refs = try allocator.alloc(actors.Ref, k);
        errdefer allocator.free(refs);
        for (refs) |*ref| {
            const data = try allocator.alloc(u8, m);
            @memset(data, 0);
            ref.* = vat.spawn(Blob, .{ .allocator = allocator, .data = data }) catch |e| {
                allocator.free(data);
                return e;
            };
        }
        return .{ .vat = vat, .refs = refs, .allocator = allocator };
    }

    fn deinit(self: *Population) void {
        self.vat.deinit();
        self.allocator.free(self.refs);
    }
};

const MapVat = struct {
    vat: actors.Vat,
    refs: []actors.Ref,
    allocator: std.mem.Allocator,

    fn buildMutable(allocator: std.mem.Allocator, k: usize, n: usize) !MapVat {
        var vat = actors.Vat.init(allocator);
        errdefer vat.deinit();
        const refs = try allocator.alloc(actors.Ref, k);
        errdefer allocator.free(refs);
        for (refs) |*ref| {
            const entries = try allocator.alloc(u64, n);
            @memset(entries, 0);
            ref.* = vat.spawn(MapMut, .{ .allocator = allocator, .entries = entries }) catch |e| {
                allocator.free(entries);
                return e;
            };
        }
        return .{ .vat = vat, .refs = refs, .allocator = allocator };
    }

    fn buildPersistent(allocator: std.mem.Allocator, k: usize, n: usize) !MapVat {
        var vat = actors.Vat.init(allocator);
        errdefer vat.deinit();
        // One base map of `n` entries; every actor takes its own ref to it via a
        // remove of an absent key (an O(1) refcount bump, no path copy), so setup
        // is O(n + k) rather than O(n * k).
        var base = PMap.init(allocator);
        {
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                const next = try base.put(i, i);
                base.deinit();
                base = next;
            }
        }
        defer base.deinit();
        const refs = try allocator.alloc(actors.Ref, k);
        errdefer allocator.free(refs);
        for (refs) |*ref| {
            var shared = try base.remove(absent_key);
            ref.* = vat.spawn(MapPersistent, .{ .map = shared }) catch |e| {
                shared.deinit();
                return e;
            };
        }
        return .{ .vat = vat, .refs = refs, .allocator = allocator };
    }

    fn deinit(self: *MapVat) void {
        self.vat.deinit();
        self.allocator.free(self.refs);
    }
};

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}

fn elapsed(start: i128, end: i128) u64 {
    return @intCast(@max(end - start, 0));
}

fn median(buf: []u64) u64 {
    std.mem.sort(u64, buf, {}, std.sort.asc(u64));
    return buf[buf.len / 2];
}

fn nsPerObject(ns: u64, k: usize) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(@max(k, 1)));
}

/// Median nanoseconds for one `snapshot()` over a fresh population of `k` actors
/// holding `m` bytes, a fresh vat each sample, since each is a first snapshot.
fn sampleSnapshot(io: std.Io, allocator: std.mem.Allocator, k: usize, m: usize, samples: usize, warmup: usize) !u64 {
    var w: usize = 0;
    while (w < warmup) : (w += 1) {
        var pop = try Population.build(allocator, k, m);
        var snap = try pop.vat.snapshot();
        snap.deinit();
        pop.deinit();
    }
    var buf: [max_samples]u64 = undefined;
    var i: usize = 0;
    while (i < samples) : (i += 1) {
        var pop = try Population.build(allocator, k, m);
        const start = nowNs(io);
        var snap = try pop.vat.snapshot();
        buf[i] = elapsed(start, nowNs(io));
        snap.deinit();
        pop.deinit();
    }
    return median(buf[0..samples]);
}

/// Median nanoseconds for one `restore()` after every actor has diverged: build,
/// snapshot, touch all (copy-on-write), then time the rewind.
fn sampleRestore(io: std.Io, allocator: std.mem.Allocator, k: usize, m: usize, samples: usize, warmup: usize) !u64 {
    var w: usize = 0;
    while (w < warmup) : (w += 1) {
        var pop = try Population.build(allocator, k, m);
        var snap = try pop.vat.snapshot();
        for (pop.refs) |ref| _ = try pop.vat.near(ref, .{ .verb = "t" });
        try pop.vat.restore(&snap);
        snap.deinit();
        pop.deinit();
    }
    var buf: [max_samples]u64 = undefined;
    var i: usize = 0;
    while (i < samples) : (i += 1) {
        var pop = try Population.build(allocator, k, m);
        var snap = try pop.vat.snapshot();
        for (pop.refs) |ref| _ = try pop.vat.near(ref, .{ .verb = "t" });
        const start = nowNs(io);
        try pop.vat.restore(&snap);
        buf[i] = elapsed(start, nowNs(io));
        snap.deinit();
        pop.deinit();
    }
    return median(buf[0..samples]);
}

/// Time one divergence pass: snapshot, then first-touch every actor (the
/// copy-on-write or `become` each pays to isolate the snapshot). Returns total ns.
fn divergeOnce(io: std.Io, pop: *MapVat) !u64 {
    var snap = try pop.vat.snapshot();
    defer snap.deinit();
    const start = nowNs(io);
    for (pop.refs) |ref| _ = try pop.vat.near(ref, .{ .verb = "t" });
    return elapsed(start, nowNs(io));
}

/// Median *per-actor* divergence cost over `k` map actors of `n` entries, for the
/// mutable (copy-on-write) or persistent (`become`) flavor.
fn sampleDiverge(io: std.Io, allocator: std.mem.Allocator, comptime persistent_flavor: bool, k: usize, n: usize, samples: usize, warmup: usize) !u64 {
    const build = struct {
        fn go(a: std.mem.Allocator, kk: usize, nn: usize) !MapVat {
            return if (persistent_flavor) MapVat.buildPersistent(a, kk, nn) else MapVat.buildMutable(a, kk, nn);
        }
    }.go;
    var w: usize = 0;
    while (w < warmup) : (w += 1) {
        var pop = try build(allocator, k, n);
        _ = try divergeOnce(io, &pop);
        pop.deinit();
    }
    var buf: [max_samples]u64 = undefined;
    var i: usize = 0;
    while (i < samples) : (i += 1) {
        var pop = try build(allocator, k, n);
        buf[i] = try divergeOnce(io, &pop);
        pop.deinit();
    }
    return median(buf[0..samples]) / @max(k, 1);
}

const SnapRow = struct { k: usize, m: usize, snapshot_ns: u64, restore_ns: u64 };
const ByteRow = struct { k: usize, m: usize, snapshot_ns: u64 };
const DivRow = struct { n: usize, k: usize, mutable_ns: u64, persistent_ns: u64 };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var smoke = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) smoke = true;
    }

    const samples: usize = if (smoke) 3 else 25;
    const warmup: usize = if (smoke) 1 else 7;
    const k_sweep: []const usize = if (smoke) &.{ 16, 64 } else &.{ 64, 256, 1024, 4096 };
    const m_sweep: []const usize = if (smoke) &.{ 64, 1024 } else &.{ 64, 1024, 16384 };
    const n_sweep: []const usize = if (smoke) &.{ 64, 1024 } else &.{ 64, 1024, 16384 };
    const fixed_m: usize = 256;
    const fixed_k: usize = if (smoke) 64 else 1024;
    const diverge_k: usize = if (smoke) 32 else 256;

    var by_objects: std.ArrayList(SnapRow) = .empty;
    defer by_objects.deinit(allocator);
    var by_bytes: std.ArrayList(ByteRow) = .empty;
    defer by_bytes.deinit(allocator);
    var diverge: std.ArrayList(DivRow) = .empty;
    defer diverge.deinit(allocator);

    for (k_sweep) |k| {
        const snap_ns = try sampleSnapshot(io, allocator, k, fixed_m, samples, warmup);
        const restore_ns = try sampleRestore(io, allocator, k, fixed_m, samples, warmup);
        try by_objects.append(allocator, .{ .k = k, .m = fixed_m, .snapshot_ns = snap_ns, .restore_ns = restore_ns });
        std.debug.print("snapshot_by_objects k={d} m={d} snapshot_ns={d} ns_per_object={d:.1} restore_ns={d}\n", .{ k, fixed_m, snap_ns, nsPerObject(snap_ns, k), restore_ns });
    }
    for (m_sweep) |m| {
        const snap_ns = try sampleSnapshot(io, allocator, fixed_k, m, samples, warmup);
        try by_bytes.append(allocator, .{ .k = fixed_k, .m = m, .snapshot_ns = snap_ns });
        std.debug.print("snapshot_by_bytes k={d} m={d} snapshot_ns={d} ns_per_object={d:.1}\n", .{ fixed_k, m, snap_ns, nsPerObject(snap_ns, fixed_k) });
    }
    for (n_sweep) |n| {
        const mut = try sampleDiverge(io, allocator, false, diverge_k, n, samples, warmup);
        const per = try sampleDiverge(io, allocator, true, diverge_k, n, samples, warmup);
        try diverge.append(allocator, .{ .n = n, .k = diverge_k, .mutable_ns = mut, .persistent_ns = per });
        std.debug.print("diverge n={d} k={d} glowcap_mutable_ns={d} glowcap_persistent_ns={d}\n", .{ n, diverge_k, mut, per });
    }

    if (smoke) return;

    try writeReport(allocator, io, .{
        .by_objects = by_objects.items,
        .by_bytes = by_bytes.items,
        .diverge = diverge.items,
    });
    std.debug.print("snapshot report written to zig-out/bench-reports/snapshot.md\n", .{});
}

const ReportData = struct {
    by_objects: []const SnapRow,
    by_bytes: []const ByteRow,
    diverge: []const DivRow,
};

fn appendFmt(b: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try b.appendSlice(gpa, s);
}

fn writeReport(gpa: std.mem.Allocator, io: std.Io, data: ReportData) !void {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);

    try b.appendSlice(gpa,
        \\# Vat local time-travel, snapshot / restore / divergence (S5)
        \\
        \\Generated by `zig build bench-snapshot`. The snapshot half of the
        \\glowcap-vs-Goblins suite, measured natively because snapshot/restore is a
        \\local `actors.Vat` API, not a wire conversation: the Goblins counterpart
        \\(`snapshot-whactormap` + `bcom`) is measured by `bench/goblins/snapshot.rkt`.
        \\Because this pits native Zig against native Racket, read the *shape* of each
        \\cost, not the absolute nanoseconds. Every number is a median over repeated
        \\warmed samples.
        \\
        \\## Snapshot scales with object count, flat in object size
        \\
        \\| objects (K) | bytes/object (M) | snapshot (ns) | ns/object | restore (ns) |
        \\| ---: | ---: | ---: | ---: | ---: |
        \\
    );
    for (data.by_objects) |s| {
        try appendFmt(&b, gpa, "| {d} | {d} | {d} | {d:.1} | {d} |\n", .{ s.k, s.m, s.snapshot_ns, nsPerObject(s.snapshot_ns, s.k), s.restore_ns });
    }

    try b.appendSlice(gpa,
        \\
        \\A snapshot shares state pointers, so growing the bytes per object should not
        \\grow the snapshot time, the proof it is O(objects), not O(bytes).
        \\
        \\| objects (K) | bytes/object (M) | snapshot (ns) | ns/object |
        \\| ---: | ---: | ---: | ---: |
        \\
    );
    for (data.by_bytes) |s| {
        try appendFmt(&b, gpa, "| {d} | {d} | {d} | {d:.1} |\n", .{ s.k, s.m, s.snapshot_ns, nsPerObject(s.snapshot_ns, s.k) });
    }

    try b.appendSlice(gpa,
        \\
        \\## Divergence: mutating structured state while a snapshot is outstanding
        \\
        \\Per-actor cost to isolate the first change to an `N`-entry actor after a
        \\snapshot. A mutable actor copies its whole table (copy-on-write, O(N)); a
        \\persistent actor path-copies with `become` (O(log N)), the same shape as
        \\Goblins' immutable `bcom`. The functional flavor wins as state grows.
        \\
        \\| entries (N) | mutable copy-on-write (ns/actor) | persistent become (ns/actor) |
        \\| ---: | ---: | ---: |
        \\
    );
    for (data.diverge) |d| {
        try appendFmt(&b, gpa, "| {d} | {d} | {d} |\n", .{ d.n, d.mutable_ns, d.persistent_ns });
    }

    try b.appendSlice(gpa, "\n");

    var dir = std.Io.Dir.cwd();
    try dir.createDirPath(io, "zig-out/bench-reports");
    try dir.writeFile(io, .{ .sub_path = "zig-out/bench-reports/snapshot.md", .data = b.items });
}
