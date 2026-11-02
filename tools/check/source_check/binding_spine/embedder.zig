//! Binding error codes: a host error code reaches a binding through its
//! generated constant, never as a bare literal on an error-context line.

const std = @import("std");
const source_tree = @import("../source_tree.zig");
const text_match = @import("../text_match.zig");
const violation_log = @import("../violation_log.zig");
const constants = @import("constants.zig");

const appendViolation = violation_log.appendViolation;
const expectFileContains = text_match.expectFileContains;
const fileContains = text_match.fileContains;
const containsAsSymbol = text_match.containsAsSymbol;
const extractBraceBlock = text_match.extractBraceBlock;
const readSourceSubject = source_tree.readSourceSubject;

/// Handwritten binding contexts that discuss, inspect, or raise an ABI error.
/// A negative integer on one of these lines restates generated ABI vocabulary.
const binding_error_context_patterns = [_][]const u8{
    "GLOWCAP_ERR_",
    "code()", // Rust Error::code()
    ".code", // Python and TypeScript error properties
    "exn:fail:glowcap-code",
    "from_code(-", // Rust: Error::from_code(sys::ERR_…)
    "GlowcapError(-", // Python / Deno: GlowcapError(_ERR_… / ERR-less mirror name)
    "(check -", // Racket: (check ERR-…)
};

/// Reject numeric error-code literals in handwritten binding claims and raise
/// sites. Generated constant files are the sole numeric mirrors of the C ABI,
/// binding code, tests, and docs must name those constants or typed errors.
pub fn checkBindingMagicErrorCodes(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "bindings", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "bindings: failed to open for magic-error-code check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            try source_tree.enterSourceDirectory(io, gpa, &walker, "bindings", entry);
            continue;
        }
        if (entry.kind != .file) continue;
        const is_source = std.mem.endsWith(u8, entry.path, ".rs") or
            std.mem.endsWith(u8, entry.path, ".py") or
            std.mem.endsWith(u8, entry.path, ".ts") or
            std.mem.endsWith(u8, entry.path, ".rkt");
        if (!is_source) continue;
        if (constants.isGeneratedBindingConstantFile(entry.path)) continue;
        const path = try std.fmt.allocPrint(gpa, "bindings/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for magic-error-code check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        var line_number: usize = 0;
        while (lines.next()) |line| {
            line_number += 1;
            var has_error_context = false;
            for (binding_error_context_patterns) |pattern| {
                if (std.mem.indexOf(u8, line, pattern) != null) {
                    has_error_context = true;
                    break;
                }
            }
            if (!has_error_context) continue;

            var search: usize = 0;
            while (std.mem.indexOfPos(u8, line, search, "-")) |minus| {
                search = minus + 1;
                if (search >= line.len) break;
                const digit = line[search];
                if (digit < '0' or digit > '9') continue;
                try appendViolation(gpa, violations, "{s}:{d}: numeric ABI error code (`-{c}…`) — name the generated constant or typed error instead", .{ path, line_number, digit });
                break;
            }
        }
    }
}
