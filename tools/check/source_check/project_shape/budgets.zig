//! Footprint budget quotes: every documented byte number equals the
//! constant that owns it.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const sectionBody = util.sectionBody;
const collectBulletSpans = util.collectBulletSpans;

/// One doc quote of a budget number, anchored to the exact phrase that makes
/// the claim. Anchoring matters: a bare search for the number anywhere in the
/// file is satisfied by any incidental mention of the same number, so a quote
/// could read 112 while an unrelated line said 128 and a naive check would
/// pass — which is precisely the drift this exists to catch.
const BudgetQuote = struct {
    path: []const u8,
    /// The phrase that makes the claim; the number must follow it directly.
    anchor: []const u8,
    /// Text required immediately after the number (`" bytes"`, `")"`, "`").
    suffix: []const u8 = " bytes",
};

/// One footprint budget: a source declaration whose decimal literal is the
/// authority, and every prose surface that quotes the number.
const BudgetFact = struct {
    /// Names the number in violation messages.
    label: []const u8,
    source_path: []const u8,
    decl: []const u8,
    quotes: []const BudgetQuote,
};

const budget_facts = [_]BudgetFact{
    .{
        .label = "per-connection slot overhead",
        .source_path = "src/net/completion/loop.zig",
        .decl = "const conn_slot_overhead_bytes: usize = ",
        .quotes = &.{
            .{ .path = "docs/ladder.md", .anchor = "| Completion-loop slot beyond its embedded peer | exactly " },
            .{ .path = "bench/peer_scaling_bench.zig", .anchor = "(`Conn`) adds " },
            .{ .path = ".agents/rules/memory.md", .anchor = "`conn_slot_overhead_bytes` (", .suffix = ")" },
        },
    },
    .{
        .label = "Host-session budget",
        .source_path = "src/driver/core/host.zig",
        .decl = "pub const host_session_struct_budget_bytes = ",
        .quotes = &.{
            .{ .path = "docs/ladder.md", .anchor = "| Host session shell | at most " },
            .{ .path = ".agents/rules/memory.md", .anchor = "The Host session ceiling is " },
            .{ .path = "docs/decisions/adr/ADR-0096-host-scoped-capability-identity.md", .anchor = "`HostSession` ceiling is " },
            .{ .path = "docs/decisions/adr/ADR-0098-sturdyref-peer-authority.md", .anchor = "the `HostSession` shell is " },
            .{ .path = "docs/decisions/adr/ADR-0099-shared-vat-scheduling.md", .anchor = "per-session `HostSession` ceiling is " },
        },
    },
    .{
        .label = "peer session struct budget",
        .source_path = "src/ocapn/engine/mod.zig",
        .decl = "pub const peer_session_struct_budget_bytes = ",
        .quotes = &.{
            .{ .path = ".agents/rules/memory.md", .anchor = "(`peer_session_struct_budget_bytes`, ", .suffix = ")" },
            .{ .path = "docs/ladder.md", .anchor = "| `engine.Peer` inline state | at most ", .suffix = " bytes |" },
        },
    },
    .{
        .label = "steady queue retention",
        .source_path = "src/ocapn/engine/mod.zig",
        .decl = "const steady_queue_bytes = ",
        .quotes = &.{
            .{ .path = ".agents/rules/memory.md", .anchor = "`steady_queue_bytes = ", .suffix = "`" },
        },
    },
    .{
        .label = "recv-scratch retention",
        .source_path = "src/ocapn/session/mod.zig",
        .decl = "const steady_recv_scratch_bytes: usize = ",
        .quotes = &.{
            .{ .path = ".agents/rules/memory.md", .anchor = "`steady_recv_scratch_bytes = ", .suffix = "`" },
        },
    },
    .{
        .label = "keyed-relay adapter state",
        .source_path = "test/net/keyed_relay_completion_test.zig",
        .decl = "const keyed_relay_connection_state_bytes: usize = ",
        .quotes = &.{
            .{ .path = "docs/ladder.md", .anchor = "| Completion-backed keyed-relay adapter state | exactly ", .suffix = " bytes per relay leg |" },
            .{ .path = ".agents/rules/memory.md", .anchor = "adapter state at exactly " },
        },
    },
    .{
        .label = "sealing completion-adapter state",
        .source_path = "test/net/noise_relay_test.zig",
        .decl = "const noise_connection_state_bytes: usize = ",
        .quotes = &.{
            .{ .path = "docs/ladder.md", .anchor = "| Sealing completion-adapter state (`noise-relay`) | exactly ", .suffix = " bytes per sealed leg, on top of the leg it wraps |" },
        },
    },
};

/// Each footprint budget is one number with one authoritative declaration,
/// quoted by the docs a reader actually opens (`docs/ladder.md` step 2, the
/// memory rule, the deciding ADRs). A constant moved once while its quotes did
/// not, so the prose said 112 while the build asserted 128 and nothing
/// noticed. Every quote in `budget_facts` is therefore derived from the source
/// declaration rather than written down again.
pub fn checkFootprintBudgetQuotes(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (budget_facts) |fact| {
        const source = root.readFileAlloc(io, fact.source_path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot read it to derive the {s} ({s})", .{ fact.source_path, fact.label, @errorName(err) });
            continue;
        };
        defer gpa.free(source);

        const at = std.mem.indexOf(u8, source, fact.decl) orelse {
            try appendViolation(gpa, violations, "{s}: `{s}…` is gone, so nothing derives the {s} the docs quote", .{ fact.source_path, fact.decl, fact.label });
            continue;
        };
        const rest = source[at + fact.decl.len ..];
        var digits: usize = 0;
        while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
        if (digits == 0) {
            try appendViolation(gpa, violations, "{s}: `{s}` is not followed by a decimal literal", .{ fact.source_path, fact.decl });
            continue;
        }
        const number = rest[0..digits];

        for (fact.quotes) |quote| {
            const contents = root.readFileAlloc(io, quote.path, gpa, .limited(4 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: cannot read it to check the {s} ({s})", .{ quote.path, fact.label, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            const claim = std.mem.indexOf(u8, contents, quote.anchor) orelse {
                try appendViolation(gpa, violations, "{s}: has no `{s}…` phrase stating the {s}, so nothing here is anchored to {s}", .{ quote.path, quote.anchor, fact.label, fact.source_path });
                continue;
            };
            const stated = contents[claim + quote.anchor.len ..];
            const needle = try std.fmt.allocPrint(gpa, "{s}{s}", .{ number, quote.suffix });
            defer gpa.free(needle);
            if (!std.mem.startsWith(u8, stated, needle)) {
                const shown = stated[0..@min(stated.len, 20)];
                try appendViolation(gpa, violations, "{s}: states the {s} as `{s}…`, but {s} asserts `{s}`", .{ quote.path, fact.label, shown, fact.source_path, needle });
            }
        }
    }
}
