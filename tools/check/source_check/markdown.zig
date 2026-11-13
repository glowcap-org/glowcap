//! Markdown reading for source checks: a `## ` section body and the backtick
//! spans of its bullet lines.

const std = @import("std");

/// Returns the body of the `## <heading>` section of a Markdown document,
/// ending at the next `## ` heading or end of file. The slice points into
/// `contents`, so it shares its lifetime.
pub fn sectionBody(contents: []const u8, heading: []const u8) ?[]const u8 {
    const start = std.mem.find(u8, contents, heading) orelse return null;
    const after = contents[start + heading.len ..];
    const end = std.mem.find(u8, after, "\n## ") orelse after.len;
    return after[0..end];
}

/// Collects the first backtick span of every `- \`...\`` bullet line in
/// `section`. Spans are slices into `section`, so they share its lifetime.
pub fn collectBulletSpans(gpa: std.mem.Allocator, section: []const u8, out: *std.ArrayList([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, section, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "- `")) continue;
        const after_tick = trimmed["- `".len..];
        const close = std.mem.findScalar(u8, after_tick, '`') orelse continue;
        try out.append(gpa, after_tick[0..close]);
    }
}

test "sectionBody and collectBulletSpans read one registry section" {
    const gpa = std.testing.allocator;
    const doc =
        "# Title\n\n## Layer Ownership\n\n" ++
        "- `foundation`: bytes.\n" ++
        "- `ocapn/`: the protocol:\n" ++
        "  - `ocapn/model`: types.\n" ++
        "  prose continuation with `inline` span.\n\n" ++
        "## Next Section\n\n- `not-here`\n";
    const section = sectionBody(doc, "## Layer Ownership").?;

    var spans: std.ArrayList([]const u8) = .empty;
    defer spans.deinit(gpa);
    try collectBulletSpans(gpa, section, &spans);

    try std.testing.expectEqual(@as(usize, 3), spans.items.len);
    try std.testing.expectEqualStrings("foundation", spans.items[0]);
    try std.testing.expectEqualStrings("ocapn/", spans.items[1]);
    try std.testing.expectEqualStrings("ocapn/model", spans.items[2]);

    try std.testing.expect(sectionBody(doc, "## Absent") == null);
}
