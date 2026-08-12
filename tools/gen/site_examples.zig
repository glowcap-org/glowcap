//! Assemble SuperMD `code-tabs` from `site/examples/` snippets into site pages.
//!
//! Snippets are the single source of truth for first-call transport examples.
//! This tool splices them between begin/end marker fences in
//! `site/content/**/*.smd`. Each marker is an HTML comment inside its own
//! ` ```=html ` fence (SuperMD forbids bare HTML; `bench-site-report` uses the
//! same escape for the performance page).
//!
//!   zig build gen-site-examples         # rewrite markers in place
//!   zig build gen-site-examples-check   # fail when a page is stale (on check)

const std = @import("std");

const Tab = struct {
    label: []const u8,
    file: []const u8,
    fence: []const u8,
};

const session_transport_labels = [_][]const u8{ "tcp", "keyed-tcp", "noise-tcp", "iroh" };

const TabSet = union(enum) {
    uniform: struct {
        labels: []const []const u8,
        extension: []const u8,
        fence: []const u8,
    },
    exact: []const Tab,
};

const onion_tabs = [_]Tab{
    .{ .label = "ts", .file = "ts", .fence = "ts" },
    .{ .label = "python", .file = "python", .fence = "python" },
    .{ .label = "rust", .file = "rust", .fence = "rust" },
    .{ .label = "racket", .file = "racket", .fence = "scheme" },
};

const browser_tabs = [_]Tab{
    .{ .label = "keyed-tcp", .file = "keyed-tcp.ts", .fence = "ts" },
    .{ .label = "noise-tcp", .file = "noise-tcp.ts", .fence = "ts" },
};

const Slot = struct {
    /// Marker id, e.g. `dial:ts` → `<!-- site-examples:dial:ts -->`.
    id: []const u8,
    page: []const u8,
    /// Subdirectory under `site/examples/` (`dial`, `listen`, `onion`, `browser`).
    directory: []const u8,
    tabs: TabSet,
};

const slots = [_]Slot{
    .{ .id = "dial:zig", .page = "site/content/start.smd", .directory = "dial", .tabs = .{ .uniform = .{ .labels = &session_transport_labels, .extension = "zig", .fence = "zig" } } },
    .{ .id = "dial:ts", .page = "site/content/bindings/ts.smd", .directory = "dial", .tabs = .{ .uniform = .{ .labels = &session_transport_labels, .extension = "ts", .fence = "ts" } } },
    .{ .id = "listen:ts", .page = "site/content/bindings/ts.smd", .directory = "listen", .tabs = .{ .uniform = .{ .labels = &session_transport_labels, .extension = "ts", .fence = "ts" } } },
    .{ .id = "dial:python", .page = "site/content/bindings/python.smd", .directory = "dial", .tabs = .{ .uniform = .{ .labels = &session_transport_labels, .extension = "python", .fence = "python" } } },
    .{ .id = "listen:python", .page = "site/content/bindings/python.smd", .directory = "listen", .tabs = .{ .uniform = .{ .labels = &session_transport_labels, .extension = "python", .fence = "python" } } },
    .{ .id = "dial:rust", .page = "site/content/bindings/rust.smd", .directory = "dial", .tabs = .{ .uniform = .{ .labels = &session_transport_labels, .extension = "rust", .fence = "rust" } } },
    .{ .id = "listen:rust", .page = "site/content/bindings/rust.smd", .directory = "listen", .tabs = .{ .uniform = .{ .labels = &session_transport_labels, .extension = "rust", .fence = "rust" } } },
    .{ .id = "dial:racket", .page = "site/content/bindings/racket.smd", .directory = "dial", .tabs = .{ .uniform = .{ .labels = &session_transport_labels, .extension = "racket", .fence = "scheme" } } },
    .{ .id = "listen:racket", .page = "site/content/bindings/racket.smd", .directory = "listen", .tabs = .{ .uniform = .{ .labels = &session_transport_labels, .extension = "racket", .fence = "scheme" } } },
    .{ .id = "onion", .page = "site/content/transports/onion.smd", .directory = "onion", .tabs = .{ .exact = &onion_tabs } },
    .{ .id = "browser:dial", .page = "site/content/bindings/browser.smd", .directory = "browser", .tabs = .{ .exact = &browser_tabs } },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program name
    const mode = args.next() orelse "write";
    if (args.next() != null or
        (!std.mem.eql(u8, mode, "write") and !std.mem.eql(u8, mode, "check")))
    {
        std.debug.print("usage: gen-site-examples [write|check]\n", .{});
        std.process.exit(2);
    }
    const check_only = std.mem.eql(u8, mode, "check");

    var stale_slots: usize = 0;
    for (slots) |slot| {
        const block = try renderSlot(gpa, io, slot);
        defer gpa.free(block);
        const changed = try splicePage(gpa, io, slot, block, check_only);
        if (changed) stale_slots += 1;
    }
    if (check_only and stale_slots != 0) {
        std.debug.print("gen-site-examples-check: {d} slot(s) stale; run `zig build gen-site-examples`\n", .{stale_slots});
        std.process.exit(1);
    }
}

fn renderSlot(gpa: std.mem.Allocator, io: std.Io, slot: Slot) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "> []($block.attrs('code-tabs'))\n");
    switch (slot.tabs) {
        .uniform => |tabs| for (tabs.labels) |label| {
            const file = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ label, tabs.extension });
            defer gpa.free(file);
            try renderTab(gpa, io, &out, slot.directory, .{ .label = label, .file = file, .fence = tabs.fence });
        },
        .exact => |tabs| for (tabs) |tab| {
            try renderTab(gpa, io, &out, slot.directory, tab);
        },
    }
    // Drop the final trailing newline; the end fence sits on the next line.
    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
        _ = out.pop();
    }
    return try out.toOwnedSlice(gpa);
}

fn renderTab(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(u8),
    directory: []const u8,
    tab: Tab,
) !void {
    const path = try std.fmt.allocPrint(gpa, "site/examples/{s}/{s}", .{ directory, tab.file });
    defer gpa.free(path);

    const body = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 10));
    defer gpa.free(body);

    const label_line = try std.fmt.allocPrint(gpa, "> **{s}**\n", .{tab.label});
    defer gpa.free(label_line);
    try out.appendSlice(gpa, label_line);

    const fence_line = try std.fmt.allocPrint(gpa, "> ```{s}\n", .{tab.fence});
    defer gpa.free(fence_line);
    try out.appendSlice(gpa, fence_line);

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, body, "\n"), '\n');
    while (lines.next()) |line| {
        try out.append(gpa, '>');
        if (line.len != 0) {
            try out.append(gpa, ' ');
            try out.appendSlice(gpa, line);
        }
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, "> ```\n");
}

/// Begin/end are full `=html` fences so SuperMD accepts the HTML comments and
/// the spliced SuperMD `code-tabs` sit between those fences.
fn markerFence(gpa: std.mem.Allocator, kind: enum { begin, end }, id: []const u8) ![]u8 {
    return switch (kind) {
        .begin => try std.fmt.allocPrint(gpa, "```=html\n<!-- site-examples:{s} GENERATED by `zig build gen-site-examples`; edits are overwritten -->\n```", .{id}),
        .end => try std.fmt.allocPrint(gpa, "```=html\n<!-- /site-examples:{s} -->\n```", .{id}),
    };
}

fn splicePage(gpa: std.mem.Allocator, io: std.Io, slot: Slot, block: []const u8, check_only: bool) !bool {
    const begin = try markerFence(gpa, .begin, slot.id);
    defer gpa.free(begin);
    const end = try markerFence(gpa, .end, slot.id);
    defer gpa.free(end);

    const page = try std.Io.Dir.cwd().readFileAlloc(io, slot.page, gpa, .limited(2 << 20));
    defer gpa.free(page);

    const begin_at = std.mem.indexOf(u8, page, begin) orelse {
        std.debug.print("{s}: missing begin marker fence for `{s}`\n", .{ slot.page, slot.id });
        return error.MissingMarker;
    };
    const after_begin = begin_at + begin.len;
    const end_rel = std.mem.indexOf(u8, page[after_begin..], end) orelse {
        std.debug.print("{s}: missing end marker fence for `{s}`\n", .{ slot.page, slot.id });
        return error.MissingMarker;
    };
    const end_at = after_begin + end_rel;

    const expected = try std.fmt.allocPrint(gpa, "\n{s}\n", .{block});
    defer gpa.free(expected);
    const current = page[after_begin..end_at];
    if (std.mem.eql(u8, current, expected)) return false;

    if (check_only) {
        std.debug.print("{s}: site-examples:{s} is stale\n", .{ slot.page, slot.id });
        return true;
    }

    var rebuilt: std.ArrayList(u8) = .empty;
    defer rebuilt.deinit(gpa);
    try rebuilt.appendSlice(gpa, page[0..after_begin]);
    try rebuilt.appendSlice(gpa, expected);
    try rebuilt.appendSlice(gpa, page[end_at..]);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = slot.page, .data = rebuilt.items });
    std.debug.print("wrote {s} ({s})\n", .{ slot.page, slot.id });
    return true;
}
