//! Documented aggregate membership checked against build-graph wiring.

const std = @import("std");
const util = @import("../../util.zig");

const appendViolation = util.appendViolation;

/// The run step an inline `b.step("N", …).dependOn(&run.step);` wires, or null.
/// The search stops at the end of that statement so a later declaration cannot
/// supply unrelated wiring.
fn inlineWiredRunStep(build_src: []const u8, decl_at: usize) ?[]const u8 {
    const rest = build_src[decl_at..];
    const stmt_end = std.mem.indexOfScalar(u8, rest, ';') orelse return null;
    const stmt = rest[0..stmt_end];
    const marker = ".dependOn(&";
    const rel = std.mem.indexOf(u8, stmt, marker) orelse return null;
    const tail = stmt[rel + marker.len ..];
    const stop = std.mem.indexOfScalar(u8, tail, ')') orelse return null;
    if (stop == 0) return null;
    return tail[0..stop];
}

const claim_docs = [_][]const u8{ "docs/build-steps.md", ".agents/rules/cli.md" };

/// Require each documented `check` or `runtime-check` membership claim to have
/// matching build wiring.
pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const build_src = util.readBuildStepSources(io, gpa, root) catch |err|
        return appendViolation(gpa, violations, "build.zig + tools/build: failed to read for the gated-step check with {s}", .{@errorName(err)});
    defer gpa.free(build_src);
    if (std.mem.indexOf(u8, build_src, "runtime_gate.finalize(check_step);") == null) {
        try appendViolation(gpa, violations, "tools/build: `runtime-check` must finalize against `check` after every registrar has wired both gates", .{});
    }
    for (claim_docs) |path| {
        const doc_src = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for the gated-step check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(doc_src);
        try claimsIn(gpa, violations, path, doc_src, build_src);
    }
}

fn claimsIn(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    rule_path: []const u8,
    rule_src: []const u8,
    build_src: []const u8,
) !void {
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, rule_src, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        if (!std.mem.startsWith(u8, line, "zig build ")) continue;
        if (std.mem.indexOf(u8, line, "part of check-external") != null) continue;
        const runtime = std.mem.indexOf(u8, line, "part of runtime-check") != null or
            std.mem.indexOf(u8, line, "rides runtime-check") != null or
            std.mem.indexOf(u8, line, "runs under runtime-check") != null;
        const isolated = std.mem.indexOf(u8, line, "part of check") != null or
            std.mem.indexOf(u8, line, "rides check") != null or
            std.mem.indexOf(u8, line, "runs under check") != null;
        if (!runtime and !isolated) continue;
        const gate_name = if (runtime) "runtime-check" else "check";
        const wire_prefix = if (runtime) "runtime_gate.add(" else "check_step.dependOn(";

        const after = line["zig build ".len..];
        var end: usize = 0;
        while (end < after.len and (std.ascii.isAlphanumeric(after[end]) or after[end] == '-')) end += 1;
        const name = after[0..end];
        if (name.len == 0) continue;

        var decl_buf: [160]u8 = undefined;
        const needle = std.fmt.bufPrint(&decl_buf, "= b.step(\"{s}\",", .{name}) catch {
            try appendViolation(gpa, violations, "build.zig: step \"{s}\" overflows a wiring-check needle buffer; grow the buffer", .{name});
            continue;
        };
        var table_buf: [220]u8 = undefined;
        const table_row = std.fmt.bufPrint(&table_buf, ".check_step_name = \"{s}\"", .{name}) catch {
            try appendViolation(gpa, violations, "build.zig: step \"{s}\" overflows a wiring-check needle buffer; grow the buffer", .{name});
            continue;
        };
        if (!runtime and std.mem.indexOf(u8, build_src, table_row) != null) continue;

        var runtime_row_buf: [220]u8 = undefined;
        const runtime_row = std.fmt.bufPrint(&runtime_row_buf, ".step_name = \"{s}\"", .{name}) catch {
            try appendViolation(gpa, violations, "build.zig: step \"{s}\" overflows a runtime-table needle buffer; grow the buffer", .{name});
            continue;
        };
        if (runtime) {
            if (std.mem.indexOf(u8, build_src, runtime_row)) |row_at| {
                const row_end = std.mem.indexOfScalar(u8, build_src[row_at..], '\n') orelse build_src.len - row_at;
                const row = build_src[row_at .. row_at + row_end];
                if (std.mem.indexOf(u8, row, ".runtime_gated = true") != null and
                    std.mem.indexOf(u8, build_src, "if (demo.runtime_gated) runtime_gate.add(&run.step)") != null) continue;
            }
        }

        var inline_buf: [180]u8 = undefined;
        const inline_decl = std.fmt.bufPrint(&inline_buf, "b.step(\"{s}\",", .{name}) catch {
            try appendViolation(gpa, violations, "build.zig: step \"{s}\" overflows a wiring-check needle buffer; grow the buffer", .{name});
            continue;
        };
        const at = std.mem.indexOf(u8, build_src, needle) orelse {
            if (std.mem.indexOf(u8, build_src, inline_decl)) |inline_at| {
                if (inlineWiredRunStep(build_src, inline_at)) |run_step| {
                    var same_buf: [220]u8 = undefined;
                    const same = std.fmt.bufPrint(&same_buf, "{s}&{s})", .{ wire_prefix, run_step }) catch {
                        try appendViolation(gpa, violations, "build.zig: run step `{s}` overflows a wiring-check needle buffer; grow the buffer", .{run_step});
                        continue;
                    };
                    if (std.mem.indexOf(u8, build_src, same) != null) continue;
                }
            }
            try appendViolation(gpa, violations, "{s}:{d}: `zig build {s}` is documented as part of {s}, but the build sources declare no such step", .{ rule_path, line_no, name, gate_name });
            continue;
        };
        const line_start = if (std.mem.lastIndexOfScalar(u8, build_src[0..at], '\n')) |nl| nl + 1 else 0;
        var decl = std.mem.trimStart(u8, build_src[line_start..at], " \t");
        decl = if (std.mem.startsWith(u8, decl, "const ")) decl["const ".len..] else decl;
        decl = std.mem.trimEnd(u8, decl, " \t");
        if (decl.len == 0) continue;

        var buf: [220]u8 = undefined;
        const by_var = std.fmt.bufPrint(&buf, "{s}{s})", .{ wire_prefix, decl }) catch {
            try appendViolation(gpa, violations, "build.zig: step variable `{s}` overflows a wiring-check needle buffer; grow the buffer", .{decl});
            continue;
        };
        if (std.mem.indexOf(u8, build_src, by_var) != null) continue;
        var buf2: [220]u8 = undefined;
        const by_amp = std.fmt.bufPrint(&buf2, "{s}&{s}", .{ wire_prefix, decl }) catch {
            try appendViolation(gpa, violations, "build.zig: step variable `{s}` overflows a wiring-check needle buffer; grow the buffer", .{decl});
            continue;
        };
        if (std.mem.indexOf(u8, build_src, by_amp) != null) continue;
        if (!runtime and std.mem.indexOf(u8, build_src, table_row) != null) continue;
        if (inlineWiredRunStep(build_src, at)) |run_step| {
            var buf3: [220]u8 = undefined;
            const same = std.fmt.bufPrint(&buf3, "{s}&{s})", .{ wire_prefix, run_step }) catch {
                try appendViolation(gpa, violations, "build.zig: run step `{s}` overflows a wiring-check needle buffer; grow the buffer", .{run_step});
                continue;
            };
            if (std.mem.indexOf(u8, build_src, same) != null) continue;
        }

        try appendViolation(gpa, violations, "{s}:{d}: `zig build {s}` says it is part of {s}, but the build sources do not wire it to that gate", .{ rule_path, line_no, name, gate_name });
    }
}

test "runtime-check claims require runtime gate wiring" {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |item| gpa.free(item);
        violations.deinit(gpa);
    }

    const docs = "zig build rooms-test # process proof; part of runtime-check\n";
    const wired =
        \\const rooms_step = b.step("rooms-test", "test");
        \\runtime_gate.add(rooms_step);
    ;
    try claimsIn(gpa, &violations, "fixture.md", docs, wired);
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);

    const unwired = "const rooms_step = b.step(\"rooms-test\", \"test\");";
    try claimsIn(gpa, &violations, "fixture.md", docs, unwired);
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);

    for (violations.items) |item| gpa.free(item);
    violations.clearRetainingCapacity();
    const table_wired =
        \\const demos = [_]Demo{
        \\    .{ .step_name = "rooms-test", .runtime_gated = true },
        \\};
        \\if (demo.runtime_gated) runtime_gate.add(&run.step);
    ;
    try claimsIn(gpa, &violations, "fixture.md", docs, table_wired);
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
