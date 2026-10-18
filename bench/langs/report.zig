//! Report rendering for the per-language consumer-cost bench: the terminal
//! comparison, the markdown artifact, and the SVG charts written under
//! `zig-out/bench-reports/`. Measurement stays in `orchestrator.zig`. This file
//! only renders the rows it produced.

const std = @import("std");
const Io = std.Io;

const o = @import("orchestrator.zig");
const Ctx = o.Ctx;
const Row = o.Row;
const Skip = o.Skip;
const out = o.out;
const reports_dir = o.reports_dir;

// ── Reporting ────────────────────────────────────────────────────────────────
const INK = "#3a3027";
const INK_SOFT = "#6b5d4d";
const PAPER = "#fff9ee";
const RULE = "#e7d4b7";
const GOBLINS_COLOR = "#257f88";
const lang_colors = [_][]const u8{ "#c76f18", "#4f8a5b", "#9c4f96", "#3f6fa3", "#b8762a", "#737373" };

pub fn report(ctx: *Ctx, rows: []const Row, skipped: []const Skip) !void {
    const mode_str: []const u8 = if (ctx.smoke) "smoke" else "full";

    // Terminal summary.
    var term: std.ArrayList(u8) = .empty;
    defer term.deinit(ctx.gpa);
    try term.appendSlice(ctx.gpa, "glowcap per-language consumer cost\n");
    var pin_buf: [12]u8 = undefined;
    const pin_text: []const u8 = if (ctx.pin) |p| try std.fmt.bufPrint(&pin_buf, "{d},{d}", .{ p[0], p[1] }) else "no";
    try term.print(ctx.gpa, "mode={s} lat_n={d} tput_n={d} conns={d} cold_samples={d} local_n={d} pin={s}\n\n", .{ mode_str, ctx.lat_n, ctx.tput_n, ctx.conns, ctx.cold_samples, ctx.local_n, pin_text });
    for (rows) |r| {
        try term.print(ctx.gpa, "  {s} ({s})  p50={s}ms p99={s}ms p999={s}ms mean={s}ms rps={s} setup={s}ms/conn per_conn={s}kB cold={s}ms local={s}ns local_p99={s}ns via_host={s}ns via_p99={s}ns via/local={s}\n", .{ r.name, r.runtime, r.p50, r.p99, r.p999, r.mean, r.rps, r.conn_ms, r.per_conn_kb, r.cold_ms, r.local_in_ns, r.local_in_p99_ns, r.local_via_ns, r.local_via_p99_ns, r.local_ratio });
    }
    try out(ctx.io, "{s}", .{term.items});

    try std.Io.Dir.cwd().createDirPath(ctx.io, reports_dir);
    const stamp: i64 = @intCast(@divFloor(std.Io.Clock.now(.real, ctx.io).nanoseconds, 1_000_000_000));

    try writeArtifact(ctx, stamp, "txt", term.items);

    if (skipped.len != 0) {
        var s: std.ArrayList(u8) = .empty;
        defer s.deinit(ctx.gpa);
        // The reason rides with the name: a missing runtime and a client that
        // will not build are both "skipped" here, and only one of them is fine.
        for (skipped) |sk| try s.print(ctx.gpa, "{s}\t{s}\n", .{ sk.def.name, sk.why.reason() });
        try writeNamed(ctx, try std.fmt.allocPrint(ctx.arena, "langs-compare-{d}-skipped.txt", .{stamp}), s.items);
    }

    if (rows.len != 0) {
        try writeSvg(ctx, rows, stamp, "latency", "Latency p50 (ms, lower is better)", "ms", .p50, 2);
        try writeSvg(ctx, rows, stamp, "throughput", "Throughput (req/s, higher is better)", "req/s", .rps, 0);
        try writeSvg(ctx, rows, stamp, "cold", "Cold start (ms, lower is better)", "ms", .cold_ms, 1);
    }

    try writeArtifact(ctx, stamp, "md", try renderMarkdown(ctx, rows, mode_str, stamp));

    try out(ctx.io, "\nartifacts: {s}/langs-compare-{d}.{{txt,md,*.svg}}\n", .{ reports_dir, stamp });
}

fn writeArtifact(ctx: *Ctx, stamp: i64, ext: []const u8, data: []const u8) !void {
    try writeNamed(ctx, try std.fmt.allocPrint(ctx.arena, "langs-compare-{d}.{s}", .{ stamp, ext }), data);
}

fn writeNamed(ctx: *Ctx, name: []const u8, data: []const u8) !void {
    const path = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ reports_dir, name });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = data });
}

const Field = enum { p50, rps, cold_ms };

fn fieldValue(r: Row, f: Field) f64 {
    const s = switch (f) {
        .p50 => r.p50,
        .rps => r.rps,
        .cold_ms => r.cold_ms,
    };
    return std.fmt.parseFloat(f64, s) catch 0;
}

/// A stable color per client: the reference row is teal, every other row draws
/// from the language palette in roster order (the Racket `palette-for` rule).
fn paletteColor(rows: []const Row, idx: usize) []const u8 {
    var pool: usize = 0;
    for (rows, 0..) |r, i| {
        if (std.mem.eql(u8, r.name, "goblins-ref")) {
            if (i == idx) return GOBLINS_COLOR;
        } else {
            if (i == idx) return lang_colors[pool % lang_colors.len];
            pool += 1;
        }
    }
    return lang_colors[0];
}

fn writeSvg(ctx: *Ctx, rows: []const Row, stamp: i64, name: []const u8, title: []const u8, y_label: []const u8, field: Field, precision: usize) !void {
    const W = 760;
    const H = 430;
    const ml = 72;
    const mr = 24;
    const mt = 56;
    const mb = 96;
    const pw: f64 = W - ml - mr;
    const ph: f64 = H - mt - mb;
    const x0: f64 = ml;
    const y1: f64 = mt + ph;

    const nbars = @max(1, rows.len);
    const slot = pw / @as(f64, @floatFromInt(nbars));
    const bw = slot * 0.6;
    var maxv: f64 = 0.0001;
    for (rows) |r| maxv = @max(maxv, fieldValue(r, field));

    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(ctx.gpa);
    const a = ctx.gpa;
    const ymid: f64 = mt + ph / 2.0;
    try s.print(a, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {d} {d}\" font-family=\"system-ui,-apple-system,sans-serif\" role=\"img\">\n", .{ W, H });
    try s.print(a, "<rect width=\"{d}\" height=\"{d}\" fill=\"{s}\" rx=\"10\"/>\n", .{ W, H, PAPER });
    try s.print(a, "<text x=\"{d}\" y=\"30\" text-anchor=\"middle\" font-size=\"18\" font-weight=\"700\" fill=\"{s}\">{s}</text>\n", .{ W / 2, INK, title });
    try s.print(a, "<text x=\"18\" y=\"{d}\" text-anchor=\"middle\" font-size=\"12\" fill=\"{s}\" transform=\"rotate(-90 18 {d})\">{s}</text>\n", .{ ymid, INK_SOFT, ymid, y_label });
    try s.print(a, "<line x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\" stroke=\"{s}\" stroke-dasharray=\"3 3\"/>\n", .{ x0, mt, x0 + pw, mt, RULE });
    try s.print(a, "<line x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\" stroke=\"{s}\" stroke-width=\"1.5\"/>\n", .{ x0, y1, x0 + pw, y1, INK });
    try s.print(a, "<text x=\"{d}\" y=\"{d}\" text-anchor=\"end\" font-size=\"11\" fill=\"{s}\">", .{ x0 - 8, mt + 4, INK_SOFT });
    try fmtNum(&s, a, maxv, precision);
    try s.appendSlice(a, "</text>\n");
    try s.print(a, "<text x=\"{d}\" y=\"{d}\" text-anchor=\"end\" font-size=\"11\" fill=\"{s}\">0</text>\n", .{ x0 - 8, y1 + 4, INK_SOFT });
    for (rows, 0..) |r, i| {
        const v = fieldValue(r, field);
        const cx = x0 + slot * (@as(f64, @floatFromInt(i)) + 0.5);
        const bx = cx - bw / 2.0;
        const by = y1 - (v / maxv) * ph;
        const color = paletteColor(rows, i);
        try s.print(a, "<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\" rx=\"2\"/>\n", .{ bx, by, bw, @max(0, y1 - by), color });
        try s.print(a, "<text x=\"{d}\" y=\"{d}\" text-anchor=\"middle\" font-size=\"10\" fill=\"{s}\">", .{ cx, by - 4, INK });
        try fmtNum(&s, a, v, precision);
        try s.appendSlice(a, "</text>\n");
        try s.print(a, "<text x=\"{d}\" y=\"{d}\" text-anchor=\"middle\" font-size=\"11\" fill=\"{s}\">{s}</text>\n", .{ cx, y1 + 18, INK, r.name });
    }
    try s.appendSlice(a, "</svg>\n");

    try writeNamed(ctx, try std.fmt.allocPrint(ctx.arena, "langs-compare-{d}-{s}.svg", .{ stamp, name }), s.items);
}

fn fmtNum(s: *std.ArrayList(u8), a: std.mem.Allocator, v: f64, precision: usize) !void {
    switch (precision) {
        0 => try s.print(a, "{d:.0}", .{v}),
        1 => try s.print(a, "{d:.1}", .{v}),
        else => try s.print(a, "{d:.2}", .{v}),
    }
}

fn renderMarkdown(ctx: *Ctx, rows: []const Row, mode: []const u8, stamp: i64) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    const a = ctx.arena;
    try s.appendSlice(a, "# glowcap per-language consumer cost\n\n");
    try s.print(a, "Mode **{s}** \u{b7} latency n={d} \u{b7} throughput n={d} \u{b7} connections={d} \u{b7} cold-start samples={d} \u{b7} local n={d}. One native Zig host, the client language swapped per row, over real loopback TCP.\n\n", .{ mode, ctx.lat_n, ctx.tput_n, ctx.conns, ctx.cold_samples, ctx.local_n });
    try s.appendSlice(a, "> Each row is a whole consumer stack: runtime, that language's binding, the app rewritten in it, and its garbage collector, over one glowcap host. A faster row means that whole stack was faster on this one machine on this one day. Reproduce with `zig build bench-langs`, then read the [benchmark guide](../../bench/langs/README.md) and [methodology](../../bench/langs/methodology.md).\n\n");
    try s.appendSlice(a, "## Results\n\n");
    try s.appendSlice(a, "| client | runtime | p50 ms | p99 ms | p999 ms | mean ms | req/s | setup ms/conn | mem kB/conn | cold ms | local ns/turn | local p99 ns | via-host ns/turn | via-host p99 ns | via/local |\n");
    try s.appendSlice(a, "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n");
    for (rows) |r| {
        try s.print(a, "| {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} |\n", .{ r.name, r.runtime, r.p50, r.p99, r.p999, r.mean, r.rps, r.conn_ms, r.per_conn_kb, r.cold_ms, r.local_in_ns, r.local_in_p99_ns, r.local_via_ns, r.local_via_p99_ns, r.local_ratio });
    }
    try s.print(a, "\n## Latency — p50, milliseconds (lower is better)\n\n![latency p50](langs-compare-{d}-latency.svg)\n", .{stamp});
    try s.print(a, "\n## Throughput — requests/second (higher is better)\n\n![throughput](langs-compare-{d}-throughput.svg)\n", .{stamp});
    try s.print(a, "\n## Cold start — milliseconds, spawn through one completed task-board unit (lower is better)\n\n![cold start](langs-compare-{d}-cold.svg)\n\n", .{stamp});
    return s.items;
}
