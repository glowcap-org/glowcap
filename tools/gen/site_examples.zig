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
const model = @import("model");

const Tab = struct {
    label: []const u8,
    file: []const u8,
    fence: []const u8,
    part: ExamplePart = .full,
    planned: bool = false,
};

const ExamplePart = enum { full, setup, common };

const common_marker = "From here, the CapTP workflow is transport-independent.";

const Binding = enum { zig, ts, browser, python, rust, racket };

const Direction = enum { dial, listen };

const Example = struct {
    file: []const u8,
    fence: []const u8,
};

const Surface = struct {
    supported: bool = false,
    planned: bool = false,
    example: ?Example = null,
};

const Cell = struct {
    binding: Binding,
    transport: model.transport.Known,
    dial: Surface = .{},
    listen: Surface = .{},
};

// This is the only support and snippet inventory. Supported examples are
// checked product claims; planned examples render only on transport pages and
// carry an explicit planned marker until the managed public surface lands.
const matrix = [_]Cell{
    .{ .binding = .zig, .transport = .tcp, .dial = .{ .supported = true, .example = .{ .file = "dial/tcp.zig", .fence = "zig" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/tcp.zig", .fence = "zig" } } },
    .{ .binding = .zig, .transport = .keyed_tcp, .dial = .{ .supported = true, .example = .{ .file = "dial/keyed-tcp.zig", .fence = "zig" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/keyed-tcp.zig", .fence = "zig" } } },
    .{ .binding = .zig, .transport = .noise_tcp, .dial = .{ .supported = true, .example = .{ .file = "dial/noise-tcp.zig", .fence = "zig" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/noise-tcp.zig", .fence = "zig" } } },
    .{ .binding = .zig, .transport = .iroh, .dial = .{ .supported = true, .example = .{ .file = "dial/iroh.zig", .fence = "zig" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/iroh.zig", .fence = "zig" } } },
    .{ .binding = .zig, .transport = .onion, .dial = .{ .supported = true, .example = .{ .file = "dial/onion.zig", .fence = "zig" } }, .listen = .{ .supported = true, .example = .{ .file = "onion/zig.zig", .fence = "zig" } } },
    .{ .binding = .zig, .transport = .keyed_relay, .dial = .{ .supported = true, .example = .{ .file = "dial/keyed-relay.zig", .fence = "zig" } } },
    .{ .binding = .zig, .transport = .noise_relay, .dial = .{ .supported = true, .example = .{ .file = "dial/noise-relay.zig", .fence = "zig" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/noise-relay.zig", .fence = "zig" } } },
    .{ .binding = .zig, .transport = .webrtc, .dial = .{ .supported = true, .example = .{ .file = "dial/webrtc.zig", .fence = "zig" } } },
    .{ .binding = .zig, .transport = .inproc, .dial = .{ .supported = true, .example = .{ .file = "dial/inproc.zig", .fence = "zig" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/inproc.zig", .fence = "zig" } } },
    // ADR-0125's id has route-bundle core vocabulary but no
    // provider archive or managed Session example yet.
    .{ .binding = .zig, .transport = .id },

    .{ .binding = .ts, .transport = .tcp, .dial = .{ .supported = true, .example = .{ .file = "dial/tcp.ts", .fence = "ts" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/tcp.ts", .fence = "ts" } } },
    .{ .binding = .ts, .transport = .keyed_tcp, .dial = .{ .supported = true, .example = .{ .file = "dial/keyed-tcp.ts", .fence = "ts" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/keyed-tcp.ts", .fence = "ts" } } },
    .{ .binding = .ts, .transport = .noise_tcp, .dial = .{ .supported = true, .example = .{ .file = "dial/noise-tcp.ts", .fence = "ts" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/noise-tcp.ts", .fence = "ts" } } },
    .{ .binding = .ts, .transport = .iroh, .dial = .{ .supported = true, .example = .{ .file = "dial/iroh.ts", .fence = "ts" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/iroh.ts", .fence = "ts" } } },
    .{ .binding = .ts, .transport = .onion, .dial = .{ .supported = true, .example = .{ .file = "dial/onion.ts", .fence = "ts" } }, .listen = .{ .supported = true, .example = .{ .file = "onion/ts.ts", .fence = "ts" } } },
    .{ .binding = .ts, .transport = .keyed_relay, .dial = .{ .supported = true, .example = .{ .file = "dial/keyed-relay.ts", .fence = "ts" } } },
    .{ .binding = .ts, .transport = .noise_relay, .dial = .{ .supported = true, .example = .{ .file = "dial/noise-relay.ts", .fence = "ts" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/noise-relay.ts", .fence = "ts" } } },
    .{ .binding = .ts, .transport = .webrtc, .dial = .{ .supported = true, .example = .{ .file = "dial/webrtc.ts", .fence = "ts" } } },

    // The browser runtime owns WebSocket connectors for tcp/keyed-tcp and an
    // iroh relay connector. @glowcap/relay's keyed/noise connector and the
    // WebRTC connector are browser-safe. noise-tcp still needs a raw socket.
    .{ .binding = .browser, .transport = .tcp, .dial = .{ .supported = true, .example = .{ .file = "browser/tcp.ts", .fence = "ts" } } },
    .{ .binding = .browser, .transport = .keyed_tcp, .dial = .{ .supported = true, .example = .{ .file = "browser/keyed-tcp.ts", .fence = "ts" } } },
    .{ .binding = .browser, .transport = .iroh, .dial = .{ .supported = true, .example = .{ .file = "browser/iroh.ts", .fence = "ts" } } },
    .{ .binding = .browser, .transport = .keyed_relay, .dial = .{ .supported = true, .example = .{ .file = "browser/keyed-relay.ts", .fence = "ts" } } },
    .{ .binding = .browser, .transport = .noise_relay, .dial = .{ .supported = true, .example = .{ .file = "browser/noise-relay.ts", .fence = "ts" } } },
    .{ .binding = .browser, .transport = .webrtc, .dial = .{ .supported = true, .example = .{ .file = "browser/webrtc.ts", .fence = "ts" } } },

    .{ .binding = .python, .transport = .tcp, .dial = .{ .supported = true, .example = .{ .file = "dial/tcp.python", .fence = "python" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/tcp.python", .fence = "python" } } },
    .{ .binding = .python, .transport = .keyed_tcp, .dial = .{ .supported = true, .example = .{ .file = "dial/keyed-tcp.python", .fence = "python" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/keyed-tcp.python", .fence = "python" } } },
    .{ .binding = .python, .transport = .noise_tcp, .dial = .{ .supported = true, .example = .{ .file = "dial/noise-tcp.python", .fence = "python" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/noise-tcp.python", .fence = "python" } } },
    .{ .binding = .python, .transport = .iroh, .dial = .{ .supported = true, .example = .{ .file = "dial/iroh.python", .fence = "python" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/iroh.python", .fence = "python" } } },
    .{ .binding = .python, .transport = .onion, .dial = .{ .supported = true, .example = .{ .file = "dial/onion.python", .fence = "python" } }, .listen = .{ .supported = true, .example = .{ .file = "onion/python.python", .fence = "python" } } },
    .{ .binding = .python, .transport = .keyed_relay, .dial = .{ .supported = true, .example = .{ .file = "dial/keyed-relay.python", .fence = "python" } } },
    .{ .binding = .python, .transport = .noise_relay, .dial = .{ .supported = true, .example = .{ .file = "dial/noise-relay.python", .fence = "python" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/noise-relay.python", .fence = "python" } } },
    .{ .binding = .python, .transport = .webrtc, .dial = .{ .supported = true, .example = .{ .file = "dial/webrtc.python", .fence = "python" } } },

    .{ .binding = .rust, .transport = .tcp, .dial = .{ .supported = true, .example = .{ .file = "dial/tcp.rust", .fence = "rust" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/tcp.rust", .fence = "rust" } } },
    .{ .binding = .rust, .transport = .keyed_tcp, .dial = .{ .supported = true, .example = .{ .file = "dial/keyed-tcp.rust", .fence = "rust" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/keyed-tcp.rust", .fence = "rust" } } },
    .{ .binding = .rust, .transport = .noise_tcp, .dial = .{ .supported = true, .example = .{ .file = "dial/noise-tcp.rust", .fence = "rust" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/noise-tcp.rust", .fence = "rust" } } },
    .{ .binding = .rust, .transport = .iroh, .dial = .{ .supported = true, .example = .{ .file = "dial/iroh.rust", .fence = "rust" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/iroh.rust", .fence = "rust" } } },
    .{ .binding = .rust, .transport = .onion, .dial = .{ .supported = true, .example = .{ .file = "dial/onion.rust", .fence = "rust" } }, .listen = .{ .supported = true, .example = .{ .file = "onion/rust.rust", .fence = "rust" } } },
    .{ .binding = .rust, .transport = .keyed_relay, .dial = .{ .supported = true, .example = .{ .file = "dial/keyed-relay.rust", .fence = "rust" } } },
    .{ .binding = .rust, .transport = .noise_relay, .dial = .{ .supported = true, .example = .{ .file = "dial/noise-relay.rust", .fence = "rust" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/noise-relay.rust", .fence = "rust" } } },
    .{ .binding = .rust, .transport = .webrtc, .dial = .{ .supported = true, .example = .{ .file = "dial/webrtc.rust", .fence = "rust" } } },

    .{ .binding = .racket, .transport = .tcp, .dial = .{ .supported = true, .example = .{ .file = "dial/tcp.racket", .fence = "scheme" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/tcp.racket", .fence = "scheme" } } },
    .{ .binding = .racket, .transport = .keyed_tcp, .dial = .{ .supported = true, .example = .{ .file = "dial/keyed-tcp.racket", .fence = "scheme" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/keyed-tcp.racket", .fence = "scheme" } } },
    .{ .binding = .racket, .transport = .noise_tcp, .dial = .{ .supported = true, .example = .{ .file = "dial/noise-tcp.racket", .fence = "scheme" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/noise-tcp.racket", .fence = "scheme" } } },
    .{ .binding = .racket, .transport = .iroh, .dial = .{ .supported = true, .example = .{ .file = "dial/iroh.racket", .fence = "scheme" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/iroh.racket", .fence = "scheme" } } },
    .{ .binding = .racket, .transport = .onion, .dial = .{ .supported = true, .example = .{ .file = "dial/onion.racket", .fence = "scheme" } }, .listen = .{ .supported = true, .example = .{ .file = "onion/racket.racket", .fence = "scheme" } } },
    .{ .binding = .racket, .transport = .keyed_relay, .dial = .{ .supported = true, .example = .{ .file = "dial/keyed-relay.racket", .fence = "scheme" } } },
    .{ .binding = .racket, .transport = .noise_relay, .dial = .{ .supported = true, .example = .{ .file = "dial/noise-relay.racket", .fence = "scheme" } }, .listen = .{ .supported = true, .example = .{ .file = "listen/noise-relay.racket", .fence = "scheme" } } },
    .{ .binding = .racket, .transport = .webrtc, .dial = .{ .supported = true, .example = .{ .file = "dial/webrtc.racket", .fence = "scheme" } } },
    // Racket exposes raw in-process frame connections, not a managed Session
    // listener/dial pair, so it is outside this application-level matrix.
    .{ .binding = .racket, .transport = .inproc },
};

// The binding pages follow the same deployment order as Choosing a transport:
// production paths first, then trusted-network paths, then testing-only paths.
// One ordered tabset keeps every transport visible without inventing a
// miscellaneous family around whichever symbols remain.
const binding_transports = [_]model.transport.Known{
    .iroh,
    .webrtc,
    .noise_tcp,
    .noise_relay,
    .onion,
    .keyed_tcp,
    .keyed_relay,
    .tcp,
    .inproc,
};
const noise_transports = [_]model.transport.Known{ .noise_tcp, .noise_relay };
const relay_transports = [_]model.transport.Known{ .noise_relay, .keyed_relay };
// Listen on the relay page is the sealed path. Keyed registration is the same
// constructor with a different profile, not a second full program.
const relay_listen_transports = [_]model.transport.Known{.noise_relay};
const iroh_transports = [_]model.transport.Known{.iroh};
const onion_transports = [_]model.transport.Known{.onion};
const webrtc_transports = [_]model.transport.Known{.webrtc};

comptime {
    @setEvalBranchQuota(10_000);
    const known = std.enums.values(model.transport.Known);
    for (matrix) |cell| {
        var matches: usize = 0;
        for (matrix) |other| {
            if (cell.binding == other.binding and cell.transport == other.transport) matches += 1;
        }
        if (matches != 1) @compileError("site example matrix contains a duplicate cell");
        for ([_]Surface{ cell.dial, cell.listen }) |surface| {
            if (surface.supported and surface.planned)
                @compileError("a site-example surface cannot be both supported and planned");
            if ((surface.supported or surface.planned) != (surface.example != null))
                @compileError("a supported or planned site-example surface must have its example");
        }
    }
    for (known) |transport| {
        var has_cell = false;
        for (matrix) |cell| {
            if (cell.transport == transport) has_cell = true;
        }
        if (!has_cell) @compileError("site example matrix omits a known transport");
    }
}

const Slot = struct {
    id: []const u8,
    page: []const u8,
    direction: Direction,
    axis: union(enum) { binding: Binding, transport: []const model.transport.Known },
};

const slots = [_]Slot{
    .{ .id = "dial:zig", .page = "site/content/start.smd", .direction = .dial, .axis = .{ .binding = .zig } },
    .{ .id = "listen:zig", .page = "site/content/start.smd", .direction = .listen, .axis = .{ .binding = .zig } },
    .{ .id = "dial:ts", .page = "site/content/bindings/ts.smd", .direction = .dial, .axis = .{ .binding = .ts } },
    .{ .id = "listen:ts", .page = "site/content/bindings/ts.smd", .direction = .listen, .axis = .{ .binding = .ts } },
    .{ .id = "dial:browser", .page = "site/content/bindings/browser.smd", .direction = .dial, .axis = .{ .binding = .browser } },
    .{ .id = "dial:python", .page = "site/content/bindings/python.smd", .direction = .dial, .axis = .{ .binding = .python } },
    .{ .id = "listen:python", .page = "site/content/bindings/python.smd", .direction = .listen, .axis = .{ .binding = .python } },
    .{ .id = "dial:rust", .page = "site/content/bindings/rust.smd", .direction = .dial, .axis = .{ .binding = .rust } },
    .{ .id = "listen:rust", .page = "site/content/bindings/rust.smd", .direction = .listen, .axis = .{ .binding = .rust } },
    .{ .id = "dial:racket", .page = "site/content/bindings/racket.smd", .direction = .dial, .axis = .{ .binding = .racket } },
    .{ .id = "listen:racket", .page = "site/content/bindings/racket.smd", .direction = .listen, .axis = .{ .binding = .racket } },
    .{ .id = "dial:noise", .page = "site/content/transports/noise.smd", .direction = .dial, .axis = .{ .transport = &noise_transports } },
    .{ .id = "listen:noise", .page = "site/content/transports/noise.smd", .direction = .listen, .axis = .{ .transport = &noise_transports } },
    .{ .id = "dial:iroh", .page = "site/content/transports/iroh.smd", .direction = .dial, .axis = .{ .transport = &iroh_transports } },
    .{ .id = "listen:iroh", .page = "site/content/transports/iroh.smd", .direction = .listen, .axis = .{ .transport = &iroh_transports } },
    .{ .id = "dial:onion", .page = "site/content/transports/onion.smd", .direction = .dial, .axis = .{ .transport = &onion_transports } },
    .{ .id = "listen:onion", .page = "site/content/transports/onion.smd", .direction = .listen, .axis = .{ .transport = &onion_transports } },
    .{ .id = "dial:relay", .page = "site/content/relay.smd", .direction = .dial, .axis = .{ .transport = &relay_transports } },
    .{ .id = "listen:relay", .page = "site/content/relay.smd", .direction = .listen, .axis = .{ .transport = &relay_listen_transports } },
    .{ .id = "dial:webrtc", .page = "site/content/transports/webrtc.smd", .direction = .dial, .axis = .{ .transport = &webrtc_transports } },
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

    switch (slot.axis) {
        .binding => |binding| {
            try renderBindingGroup(gpa, io, &out, slot, binding);
        },
        .transport => |transports| {
            for (transports, 0..) |transport, i| {
                if (i != 0) try out.appendSlice(gpa, "\n\n");
                try renderTransportGroup(gpa, io, &out, slot, transport, transports.len > 1);
            }
        },
    }
    return try out.toOwnedSlice(gpa);
}

fn renderBindingGroup(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(u8),
    slot: Slot,
    binding: Binding,
) !void {
    if (bindingGroupHasExamples(binding, slot.direction, &binding_transports)) {
        try out.appendSlice(gpa, "> []($block.attrs('code-tabs'))\n");
    }
    for (binding_transports) |transport| {
        const cell = findCell(binding, transport) orelse continue;
        const surface = surfaceFor(cell, slot.direction);
        if (surface.supported) if (surface.example) |example| {
            try renderTab(gpa, io, out, .{
                .label = transport.metadata().symbol,
                .file = example.file,
                .fence = example.fence,
                .part = .setup,
            });
        };
    }
    trimTrailingNewline(out);
    try renderBindingCommon(gpa, io, out, binding, slot.direction);
}

fn renderTransportGroup(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(u8),
    slot: Slot,
    transport: model.transport.Known,
    show_heading: bool,
) !void {
    const one = [_]model.transport.Known{transport};
    const group_slot = Slot{
        .id = slot.id,
        .page = slot.page,
        .direction = slot.direction,
        .axis = .{ .transport = &one },
    };
    var group: std.ArrayList(u8) = .empty;
    defer group.deinit(gpa);

    if (slotHasExamples(group_slot)) try group.appendSlice(gpa, "> []($block.attrs('code-tabs'))\n");
    // Supported tabs first so a transport's lead is a working surface, not a
    // planned stub. `std.enums.values` follows declaration order (Zig, then
    // TypeScript), which put WebRTC's planned Zig tab in front of TypeScript.
    inline for (.{ false, true }) |want_planned| {
        for (std.enums.values(Binding)) |binding| {
            const cell = findCell(binding, transport) orelse continue;
            const surface = surfaceFor(cell, slot.direction);
            if (surface.planned != want_planned) continue;
            if (surface.example) |example| {
                try renderTab(gpa, io, &group, .{
                    .label = bindingLabel(binding),
                    .file = example.file,
                    .fence = example.fence,
                    .part = .setup,
                    .planned = surface.planned,
                });
            }
        }
    }
    trimTrailingNewline(&group);

    if (show_heading) {
        try out.print(gpa, "## {s}", .{transportGroupLabel(slot.id, transport)});
        if (group.items.len != 0) try out.appendSlice(gpa, "\n\n");
    }
    try out.appendSlice(gpa, group.items);
}

fn trimTrailingNewline(out: *std.ArrayList(u8)) void {
    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') _ = out.pop();
}

fn bindingGroupHasExamples(
    binding: Binding,
    direction: Direction,
    transports: []const model.transport.Known,
) bool {
    for (transports) |transport| {
        if (findCell(binding, transport)) |cell| {
            const surface = surfaceFor(cell, direction);
            if (surface.supported and surface.example != null) return true;
        }
    }
    return false;
}

fn transportGroupLabel(slot_id: []const u8, transport: model.transport.Known) []const u8 {
    if (std.mem.endsWith(u8, slot_id, ":relay")) {
        return switch (transport) {
            .noise_relay => "Noise",
            .keyed_relay => "Keyed",
            else => unreachable,
        };
    }
    return switch (transport) {
        .noise_tcp => "TCP",
        .noise_relay => "Relay",
        else => transport.metadata().symbol,
    };
}

fn slotHasExamples(slot: Slot) bool {
    switch (slot.axis) {
        .binding => |binding| for (std.enums.values(model.transport.Known)) |transport| {
            if (findCell(binding, transport)) |cell| {
                const surface = surfaceFor(cell, slot.direction);
                if (surface.supported and surface.example != null) return true;
            }
        },
        .transport => |transports| for (transports) |transport| for (std.enums.values(Binding)) |binding| {
            if (findCell(binding, transport)) |cell| {
                if (surfaceFor(cell, slot.direction).example != null) return true;
            }
        },
    }
    return false;
}

fn findCell(binding: Binding, transport: model.transport.Known) ?*const Cell {
    for (&matrix) |*cell| {
        if (cell.binding == binding and cell.transport == transport) return cell;
    }
    return null;
}

fn surfaceFor(cell: *const Cell, direction: Direction) Surface {
    return switch (direction) {
        .dial => cell.dial,
        .listen => cell.listen,
    };
}

fn bindingLabel(binding: Binding) []const u8 {
    return switch (binding) {
        .zig => "Zig",
        .ts => "TypeScript",
        .browser => "Browser",
        .python => "Python",
        .rust => "Rust",
        .racket => "Racket",
    };
}

fn renderTab(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(u8),
    tab: Tab,
) !void {
    const path = try std.fmt.allocPrint(gpa, "site/examples/{s}", .{tab.file});
    defer gpa.free(path);

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 10));
    defer gpa.free(source);
    const body = try examplePart(source, tab.part);

    const suffix: []const u8 = if (tab.planned) " (planned)" else "";
    const label_line = try std.fmt.allocPrint(gpa, "> **{s}{s}**\n", .{ tab.label, suffix });
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

fn renderBindingCommon(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(u8),
    binding: Binding,
    direction: Direction,
) !void {
    var canonical: ?[]u8 = null;
    defer if (canonical) |body| gpa.free(body);
    var canonical_file: []const u8 = "";
    var fence: []const u8 = "";

    for (binding_transports) |transport| {
        const cell = findCell(binding, transport) orelse continue;
        const surface = surfaceFor(cell, direction);
        if (!surface.supported) continue;
        const example = surface.example orelse continue;
        const path = try std.fmt.allocPrint(gpa, "site/examples/{s}", .{example.file});
        defer gpa.free(path);
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 10));
        defer gpa.free(source);
        const body = try examplePart(source, .common);
        if (canonical) |expected| {
            if (!std.mem.eql(u8, expected, body)) {
                std.debug.print(
                    "{s} and {s} must have the same transport-independent continuation\n",
                    .{ canonical_file, example.file },
                );
                return error.InconsistentCommonExample;
            }
        } else {
            canonical = try gpa.dupe(u8, body);
            canonical_file = example.file;
            fence = example.fence;
        }
    }

    const body = canonical orelse return;
    if (out.items.len != 0) try out.appendSlice(gpa, "\n\n");
    try out.appendSlice(gpa, "From here, the CapTP workflow is the same for every transport:\n\n");
    try out.print(gpa, "```{s}\n{s}\n```", .{ fence, body });
}

fn examplePart(source: []const u8, part: ExamplePart) ![]const u8 {
    if (part == .full) return std.mem.trim(u8, source, "\n");
    const marker_at = std.mem.indexOf(u8, source, common_marker) orelse {
        std.debug.print("site example has no common-workflow marker\n", .{});
        return error.MissingCommonMarker;
    };
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..marker_at], '\n')) |at| at + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, source, marker_at, '\n') orelse source.len;
    return switch (part) {
        .full => unreachable,
        .setup => std.mem.trim(u8, source[0..line_start], "\n"),
        .common => std.mem.trim(u8, source[@min(line_end + 1, source.len)..], "\n"),
    };
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
