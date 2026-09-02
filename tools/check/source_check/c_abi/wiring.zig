//! Host wiring lockstep: the host-action arm table, the host plugin APIs a
//! binding must consume, the host-pump import allowlist, and the rule that no
//! ADR number rides in a runtime string.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const fileContains = util.fileContains;
const firstIntIn = util.firstIntIn;
const parseJsonFile = util.parseJsonFile;
const getField = util.getField;
const jsonStringEquals = util.jsonStringEquals;

/// HostAction / C embedder_pump arm parity: a new action kind must fail the
/// build rather than silently drop from either switch spine. Node actions have
/// their independent product lockstep check in `captp_product/node_actions.zig`.
pub fn checkHostActionArmLockstep(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const header_path = "include/glowcap_host.h";
    const header = root.readFileAlloc(io, header_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for HostAction arm lockstep with {s}", .{ header_path, @errorName(err) });
        return;
    };
    defer gpa.free(header);

    var action_names: std.ArrayList([]const u8) = .empty;
    defer action_names.deinit(gpa);
    const needle = "#define GLOWCAP_HOST_ACTION_";
    var rest = header;
    while (std.mem.indexOf(u8, rest, needle)) |start| {
        const after = rest[start + needle.len ..];
        const name_end = std.mem.indexOfAny(u8, after, " \t\r\n") orelse after.len;
        const name = after[0..name_end];
        if (name.len != 0) try action_names.append(gpa, name);
        rest = after[name_end..];
    }
    if (action_names.items.len == 0) {
        try appendViolation(gpa, violations, "{s}: no GLOWCAP_HOST_ACTION_* for HostAction arm lockstep", .{header_path});
        return;
    }

    const zig_action = root.readFileAlloc(io, "src/driver/core/host/action.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/driver/core/host/action.zig: failed to read for HostAction arm lockstep with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(zig_action);
    // Zig HostAction tags (snake) must match header constants (SCREAMING).
    const zig_tags = [_][]const u8{ "dial", "cancel_dial", "flush", "close", "need_gift_id", "settled", "failed", "resume_work" };
    if (action_names.items.len != zig_tags.len) {
        try appendViolation(gpa, violations, "HostAction arm lockstep: header has {d} GLOWCAP_HOST_ACTION_* but Zig HostAction expects {d} tags", .{ action_names.items.len, zig_tags.len });
    }
    for (zig_tags) |tag| {
        if (std.mem.indexOf(u8, zig_action, tag) == null) {
            try appendViolation(gpa, violations, "src/driver/core/host/action.zig: missing HostAction tag `{s}`", .{tag});
        }
    }

    const embedder = root.readFileAlloc(io, "src/c_abi/host/embedder_pump.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/c_abi/host/embedder_pump.zig: failed to read for HostAction arm lockstep with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(embedder);
    for (action_names.items) |name| {
        var token_buf: [96]u8 = undefined;
        const token = std.fmt.bufPrint(&token_buf, "GLOWCAP_HOST_ACTION_{s}", .{name}) catch {
            try appendViolation(gpa, violations, "HostAction arm lockstep: action name `{s}` too long", .{name});
            continue;
        };
        if (std.mem.indexOf(u8, embedder, token) == null) {
            // SETTLE and FAIL share the complete arm in embedder_pump.
            if (std.mem.eql(u8, name, "SETTLE") or std.mem.eql(u8, name, "FAIL")) {
                if (std.mem.indexOf(u8, embedder, "GLOWCAP_HOST_ACTION_SETTLE") != null and
                    std.mem.indexOf(u8, embedder, "GLOWCAP_HOST_ACTION_FAIL") != null) continue;
            }
            try appendViolation(gpa, violations, "src/c_abi/host/embedder_pump.zig: missing drain arm for `{s}`", .{token});
        }
    }
}

/// ADR-0009 introducing-session promise proxy: production callers stay wired
/// on Node/Host. One settlement spine: Node enters through the escrow-backed
/// `applyRelayedResolutionGuaranteed`. The deleted Peer queue
/// (`relayResolution` / `drainRelayedResolutions`) must not return under src/.
pub fn checkUnwiredHostPluginApis(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const rows = [_]struct { call_needle: []const u8, def_path: []const u8 }{
        .{ .call_needle = ".applyRelayedResolutionGuaranteed(", .def_path = "src/ocapn/engine/peer/settlement.zig" },
        .{ .call_needle = ".installThirdPartyImport(", .def_path = "src/ocapn/session/promises/imported.zig" },
    };
    for (rows) |row| {
        if (!try srcHasCallOutsideDef(io, gpa, root, violations, row.call_needle, row.def_path)) {
            try appendViolation(gpa, violations, "host-plugin API `{s}` lost its production caller under src/ — Node promise proxy must keep calling it", .{row.call_needle});
        }
    }

    // Deleted queue spine must not reappear under production src/.
    if (try srcHasCallOutsideDef(io, gpa, root, violations, ".relayResolution(", "src/ocapn/engine/mod.zig")) {
        try appendViolation(gpa, violations, "deleted Peer.relayResolution reappeared under src/ — settle via applyRelayedResolutionGuaranteed only", .{});
    }
    if (try srcHasCallOutsideDef(io, gpa, root, violations, "drainRelayedResolutions(", "src/ocapn/engine/cross_peer.zig")) {
        try appendViolation(gpa, violations, "deleted drainRelayedResolutions reappeared under src/ — settle via applyRelayedResolution only", .{});
    }
    // Relayed path moves; a public/production resolution deep-clone must not return.
    const clone_ban_paths = [_]struct { path: []const u8, why: []const u8 }{
        .{ .path = "src/ocapn/model/owned.zig", .why = "cloneResolution must stay deleted — relayed settlement moves (memory.md)" },
        .{ .path = "src/ocapn/model/mod.zig", .why = "cloneResolution export must stay deleted — relayed settlement moves (memory.md)" },
        .{ .path = "src/ocapn/engine/node.zig", .why = "public cloneResolution must stay deleted — proxy uses materializeResolutionForStore (memory.md)" },
        .{ .path = "src/ocapn/engine/node/proxies/settlement.zig", .why = "proxy settlement must materialize once, never deep-clone per recipient (memory.md)" },
    };
    for (clone_ban_paths) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for cloneResolution ban with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "cloneResolution") != null) {
            try appendViolation(gpa, violations, "{s}: `{s}`", .{ row.path, row.why });
        }
    }
    try expectFileContains(io, gpa, root, violations, "src/ocapn/model/owned.zig", &.{
        "materializeResolutionForStore",
    });
    try expectFileContains(io, gpa, root, violations, "src/ocapn/engine/node.zig", &.{
        "proxyForeignPromiseFulfill",
        "consumeProjectedProxyListenerFire",
        "claimProjectedProxyListenerFire",
        "projectProxyListenerFire",
        "isProxyHomeListener",
        "proxy_by_listener",
        "pub const PendingDialView = redeem_dials.PendingDialView;",
        "pub const pendingDial = redeem_dials.pendingDial;",
        "pub const stageDial = dial_staging.stage;",
    });
    try expectFileContains(io, gpa, root, violations, "src/ocapn/engine/node/redeem/dials.zig", &.{
        "pub fn pendingDial",
        "by_identity",
    });
    try expectFileContains(io, gpa, root, violations, "src/ocapn/engine/node/redeem/dials/admission.zig", &.{
        "unparseable exporter locator",
    });
    try expectFileContains(io, gpa, root, violations, "src/ocapn/engine/node/redeem/dials/staging.zig", &.{
        "actions.claimTicketRange",
        "pub const PreparedStage",
    });
    try expectFileContains(io, gpa, root, violations, "src/ocapn/engine/node/redeem/plan.zig", &.{
        "pub fn parse",
        "UnparseableExporterLocator",
    });
    try expectFileContains(io, gpa, root, violations, "src/ocapn/engine/node/proxies/admission.zig", &.{
        "foreignPromiseFulfill",
        "installThirdPartyImport",
        "session_not_open",
    });
    try expectFileContains(io, gpa, root, violations, "src/ocapn/engine/node/proxies/settlement.zig", &.{
        "materializeResolutionForStore",
        "applyRelayedResolution",
    });
    // Ticket-only dial state: dial parts live on the pending row alone.
    if (try fileContains(io, gpa, root, "src/ocapn/engine/node/redeem/dials.zig", "allocator.dupe(u8, exporter_locator)")) {
        try appendViolation(gpa, violations, "src/ocapn/engine/node/redeem/dials.zig: acceptGive must not dupe the verbatim exporter URI — pending row owns parts only", .{});
    }
    // Zig dual borrow API must stay deleted — one pendingDial view.
    for ([_][]const u8{ "pub fn pendingDialLocator", "pub fn pendingDialParts", "PendingDialParts" }) |needle| {
        for ([_][]const u8{
            "src/ocapn/engine/node.zig",
            "src/ocapn/engine/node/redeem/dials.zig",
        }) |path| {
            if (try fileContains(io, gpa, root, path, needle)) {
                try appendViolation(gpa, violations, "{s}: `{s}` must stay deleted — use pendingDial / PendingDialView", .{ path, needle });
            }
        }
    }
    // Named materialize is for the proxy fire owner only — not a free fan-out API.
    if (try srcHasCallOutsideAllowlist(io, gpa, root, violations, "materializeResolutionForStore(", &.{
        "src/ocapn/engine/node/proxies/settlement.zig",
        "src/ocapn/model/owned.zig",
    })) {
        try appendViolation(gpa, violations, "materializeResolutionForStore called outside proxy settlement — one recipient materialization per fire (memory.md)", .{});
    }
    // Withdrawal preparation owns one resolution payload. Re-wrapping it in a
    // complete Message would clone the same tree a second time before the
    // typed answer settlement queue takes ownership.
    if (try fileContains(io, gpa, root, "src/ocapn/engine/bootstrap.zig", "cloneMessage")) {
        try appendViolation(gpa, violations, "src/ocapn/engine/bootstrap.zig: cloneMessage must stay deleted — prepared withdraw owns one resolution clone", .{});
    }
    // Enliven: session owns swissnum; Host bridge keys on answer only.
    for ([_][]const u8{
        "mintEnlivenVow(session, swissnum,",
        "mintEnlivenVow(self, session, swissnum,",
        ".swissnum = owned",
        "swissnum: []const u8,\n    vow_id",
        "swissnum: []u8,\n    vow_id",
    }) |needle| {
        if (try fileContains(io, gpa, root, "src/driver/core/enliven.zig", needle)) {
            try appendViolation(gpa, violations, "src/driver/core/enliven.zig: EnlivenListener/mintEnlivenVow must not own swissnum — session pending row owns it", .{});
            break;
        }
    }
    // Cap'n Proto set encode-once: deleted 2N helpers must not return.
    for ([_][]const u8{ "canonicalSetOrder", "encodeArgumentKey" }) |needle| {
        if (try fileContains(io, gpa, root, "src/ocapn/codec/capnp/encode.zig", needle)) {
            try appendViolation(gpa, violations, "src/ocapn/codec/capnp/encode.zig: `{s}` must stay deleted — use encodeArgumentSetList", .{needle});
        }
    }
    try expectFileContains(io, gpa, root, violations, "src/ocapn/codec/capnp/encode.zig", &.{
        "encodeArgumentSetList",
    });
    try expectFileContains(io, gpa, root, violations, "src/driver/core/host/interception.zig", &.{
        "isProxyHomeListener",
        "claimProxyListenerFire",
    });
    try expectFileContains(io, gpa, root, violations, "src/driver/core/enliven.zig", &.{
        "pendingEnlivenSwissnum",
    });
    try expectFileContains(io, gpa, root, violations, "test/engine/relay_resolution_test.zig", &.{
        "applyRelayedResolution",
        "installThirdPartyImport",
        "desc:export",
    });
    try expectFileContains(io, gpa, root, violations, "test/all_test.zig", &.{
        "relay_resolution_test.zig",
        "equality_test.zig",
    });
    try expectFileContains(io, gpa, root, violations, "test/model/equality_test.zig", &.{
        "view equality and hash agree with the owned spine",
    });
    try expectFileContains(io, gpa, root, violations, "test/engine/node/proxy_test.zig", &.{
        "proxyForeignPromiseFulfill",
        "consumeProjectedProxyListenerFire",
        "session_not_open",
        "multi-introduce",
    });
    // Route-exact HostAction.dial: the pending row owns the complete locator;
    // the action carries only the stable key needed to select that route.
    if (try fileContains(io, gpa, root, "src/driver/core/host/pump.zig", "fn dialActionFields")) {
        try appendViolation(gpa, violations, "src/driver/core/host/pump.zig: dialActionFields must stay deleted — HostAction.dial owns only ticket and route_index", .{});
    }
    if (try fileContains(io, gpa, root, "src/driver/core/host/action.zig", "locator: []const u8")) {
        try appendViolation(gpa, violations, "src/driver/core/host/action.zig: HostAction.dial must not carry locator — use pendingDial", .{});
    }
    if (try fileContains(io, gpa, root, "src/driver/core/host/action.zig", "glowcap_host_pending_dial_*")) {
        try appendViolation(gpa, violations, "src/driver/core/host/action.zig: stale pending_dial_* plural — use glowcap_host_pending_dial", .{});
    }
    try expectFileContains(io, gpa, root, violations, "src/driver/core/handoff.zig", &.{
        "pub fn pendingDial",
        "PendingDialView",
    });
    try expectFileContains(io, gpa, root, violations, "src/c_abi/host/host.zig", &.{
        "glowcap_host_pending_dial",
        "GlowcapLocatorHintView",
        "GlowcapLocatorView",
    });
    try expectFileContains(io, gpa, root, violations, "src/c_abi/host/plan.zig", &.{
        "locator_adapter.project",
        "inst.core.pendingDial",
    });
    if (try fileContains(io, gpa, root, "src/c_abi/host/mod.zig", "GlowcapPendingDial")) {
        try appendViolation(gpa, violations, "src/c_abi/host/mod.zig: fixed fragment pending-dial struct must stay deleted — shared GlowcapLocatorView is the ABI vocabulary", .{});
    }
    // Dual C pending-dial exports must stay deleted — one complete locator projection.
    for ([_][]const u8{ "glowcap_host_pending_dial_locator", "glowcap_host_pending_dial_parts" }) |needle| {
        if (try fileContains(io, gpa, root, "src/c_abi/host/host.zig", needle)) {
            try appendViolation(gpa, violations, "src/c_abi/host/host.zig: `{s}` must stay deleted — use glowcap_host_pending_dial", .{needle});
        }
        if (try fileContains(io, gpa, root, "include/glowcap_host.h", needle)) {
            try appendViolation(gpa, violations, "include/glowcap_host.h: `{s}` must stay deleted — use glowcap_host_pending_dial", .{needle});
        }
    }
    // Redeem dial must not re-parse the pending URI on Host/Bridge.
    if (try fileContains(io, gpa, root, "src/driver/core/host/pump.zig", "dialDesignatorForReuse")) {
        try appendViolation(gpa, violations, "src/driver/core/host/pump.zig: dialDesignatorForReuse must stay deleted — pendingDial owns the designator", .{});
    }
    if (try fileContains(io, gpa, root, "src/driver/bridge.zig", "parsePeer(bridge.allocator")) {
        try appendViolation(gpa, violations, "src/driver/bridge.zig: Exec.dial must not parsePeer — use pendingDial", .{});
    }
    try expectFileContains(io, gpa, root, violations, "src/driver/bridge.zig", &.{
        "OutboundConnect",
        "pending_connects",
        "connectOutbound",
        ".{ .redeem = .{ .ticket = d.ticket, .route_index = d.route_index } }",
    });
    try expectFileContains(io, gpa, root, violations, "src/driver/bridge_connect.zig", &.{
        "pub const RedeemAttempt = struct",
        "ticket: engine.Node.PendingId",
        "route_index: usize",
        "redeem: RedeemAttempt",
        "app_dial: model.PeerLocator",
        "model.clonePeerLocator(allocator, locator)",
        "model.freePeerLocator(allocator, locator)",
    });
    if (try fileContains(io, gpa, root, "src/driver/bridge.zig", "const PendingDial = struct")) {
        try appendViolation(gpa, violations, "src/driver/bridge.zig: PendingDial must stay deleted — use OutboundConnect", .{});
    }
    for ([_][]const u8{ "DialKind", "submitPendingDial", "submitRedeemDial", "pending_dials:", "pending dial parts missing" }) |needle| {
        if (try fileContains(io, gpa, root, "src/driver/bridge.zig", needle)) {
            try appendViolation(gpa, violations, "src/driver/bridge.zig: `{s}` must stay deleted — OutboundConnect + acceptGive own the invariant", .{needle});
        }
    }
    if (try fileContains(io, gpa, root, "tools/gen/header/host.zig", "Empty transport/designator means")) {
        try appendViolation(gpa, violations, "tools/gen/header/host.zig: empty-parts-as-unparseable prose must stay deleted — acceptGive fails unparseable closed", .{});
    }
    try expectFileContains(io, gpa, root, violations, "src/ocapn/engine/node/redeem/plan.zig", &.{
        "UnparseableExporterLocator",
    });
    // Pending dial paths own typed hints as well as transport and designator;
    // one teardown spine must release the complete shape.
    try expectFileContains(io, gpa, root, violations, "src/ocapn/model/route_bundle.zig", &.{
        "fn deinitPath(allocator: std.mem.Allocator, path: Path) void",
        "model.freeHints(allocator, path.hints);",
        "self.deinitPaths(allocator);",
    });
    try expectFileContains(io, gpa, root, violations, "src/ocapn/engine/node/redeem/dials.zig", &.{
        "entry.plan.deinitPaths(self.allocator);",
    });
    // Host dial harness must borrow the dial view, not re-parse the locator.
    if (try fileContains(io, gpa, root, "test/driver/core_host/vow_test.zig", "parsePeer(allocator, pending)")) {
        try appendViolation(gpa, violations, "test/driver/core_host/vow_test.zig: dial arm must use pendingDial, not parsePeer", .{});
    }
    // Session inspect walks live in inspect.zig; Session method forwards stay deleted.
    try expectFileContains(io, gpa, root, violations, "src/ocapn/session/inspect.zig", &.{
        "forEachExport",
        "ExportView",
    });
    if (try fileContains(io, gpa, root, "src/ocapn/session/mod.zig", "pub fn forEachExport")) {
        try appendViolation(gpa, violations, "src/ocapn/session/mod.zig: Session.forEachExport must stay deleted — use inspect.forEachExport", .{});
    }
    try expectFileContains(io, gpa, root, violations, "test/all_test.zig", &.{
        "inspect_test.zig",
    });
    try expectFileContains(io, gpa, root, violations, "test/session/inspect_test.zig", &.{
        "session inspect walks export and import rows",
        "inspect.forEachExport",
    });
    // Redeem path must open from pendingDial parts, not re-parse parked.locator.
    if (try fileContains(io, gpa, root, "test/driver/core_host/redeem_test.zig", "parsePeer(allocator, parked.locator)")) {
        try appendViolation(gpa, violations, "test/driver/core_host/redeem_test.zig: redeem must use pendingDial parts, not parsePeer(parked.locator)", .{});
    }
    // O(1) crossed-hellos tiebreak: must use the transport-qualified dial
    // target index, not a full sessions scan (ADR-0012 scale).
    const ch_src = root.readFileAlloc(io, "src/driver/core/crossed_hellos.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/driver/core/crossed_hellos.zig: failed to read for tiebreak index check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(ch_src);
    if (std.mem.indexOf(u8, ch_src, "fn tiebreakInbound")) |fn_start| {
        const body = ch_src[fn_start..];
        const body_end = std.mem.indexOf(u8, body, "\n}\n") orelse body.len;
        const tiebreak = body[0..body_end];
        if (std.mem.indexOf(u8, tiebreak, "valueIterator") != null) {
            try appendViolation(gpa, violations, "src/driver/core/crossed_hellos.zig: tiebreakInbound must not scan sessions.valueIterator — use dialed_by_target", .{});
        }
        if (std.mem.indexOf(u8, tiebreak, "dialed_by_target") == null) {
            try appendViolation(gpa, violations, "src/driver/core/crossed_hellos.zig: tiebreakInbound must consult dialed_by_target", .{});
        }
    } else {
        try appendViolation(gpa, violations, "src/driver/core/crossed_hellos.zig: tiebreakInbound missing", .{});
    }
}

/// `host/pump.zig` is Host-private pump mechanics: only the Host core's own
/// responsibility files may import it. Cross-file `pub fn` stays for Zig module
/// visibility; this gate is what keeps the boundary from rotting into a second
/// public API.
pub fn checkHostPumpImportGate(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // The Host core is the `src/driver/core/` directory: `host.zig` and the
    // siblings split out of it, each still implementing `Host` verbs behind
    // decl aliases. The pump is private to that directory as a whole — the
    // list stopped naming files when every slice of the split was adding one.
    const host_core_dir = "src/driver/core/";
    const needle = "@import(\"host/pump.zig\")";
    var dir = root.openDir(io, "src", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "src: failed to open for host_pump import gate with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(path);
        if (std.mem.startsWith(u8, path, host_core_dir)) continue;
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for host_pump import gate with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, needle) != null) {
            try appendViolation(gpa, violations, "{s}: imports host/pump.zig — only the Host core's own files may (Host private pump)", .{path});
        }
    }
}

/// ADR names belong in docs and comments, never in strings that can reach a
/// panic message, CapTP abort text, log line, or other runtime surface.
pub fn checkNoAdrInRuntimeStrings(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const roots = [_][]const u8{ "src", "interop" };
    for (roots) |rel| {
        var dir = root.openDir(io, rel, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for ADR-runtime-string check with {s}", .{ rel, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, entry.path });
            defer gpa.free(path);
            const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for ADR-runtime-string check with {s}", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            var line_no: usize = 1;
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |line| : (line_no += 1) {
                if (zigLineHasAdrInStringLiteral(line)) {
                    try appendViolation(gpa, violations, "{s}:{d}: ADR citation in a string literal — keep ADR names in comments/docs, not panic/abort/log text", .{ path, line_no });
                }
            }
        }
    }
}

/// Like `srcHasCallOutsideDef`, but allows a small set of definition/call sites.
fn srcHasCallOutsideAllowlist(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    call_needle: []const u8,
    allow: []const []const u8,
) !bool {
    var dir = root.openDir(io, "src", .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(path);
        var allowed = false;
        for (allow) |a| {
            if (std.mem.eql(u8, path, a)) {
                allowed = true;
                break;
            }
        }
        if (allowed) continue;
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot be read for the C-ABI wiring check ({s})", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "//")) continue;
            if (std.mem.indexOf(u8, line, call_needle) != null) return true;
        }
    }
    return false;
}

fn srcHasCallOutsideDef(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    call_needle: []const u8,
    def_path: []const u8,
) !bool {
    var dir = root.openDir(io, "src", .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(path);
        if (std.mem.eql(u8, path, def_path)) continue;
        if (std.mem.eql(u8, path, "src/ocapn/session/mod.zig") and
            std.mem.eql(u8, call_needle, ".installThirdPartyImport("))
            continue;
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot be read for the C-ABI wiring check ({s})", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "//")) continue;
            if (std.mem.indexOf(u8, line, call_needle) != null) return true;
        }
    }
    return false;
}

/// True when a double-quoted Zig string literal on `line` contains `ADR-`.
/// Line comments (`//`) outside strings are ignored. Multiline strings and
/// character literals are out of scope (ADR citations do not live there).
fn zigLineHasAdrInStringLiteral(line: []const u8) bool {
    var i: usize = 0;
    var in_string = false;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (!in_string) {
            if (c == '/' and i + 1 < line.len and line[i + 1] == '/') return false;
            if (c == '"') {
                in_string = true;
            }
            continue;
        }
        if (c == '\\') {
            i += 1; // skip escaped byte
            continue;
        }
        if (c == '"') {
            in_string = false;
            continue;
        }
        if (c == 'A' and i + 4 <= line.len and std.mem.eql(u8, line[i..][0..4], "ADR-")) {
            return true;
        }
    }
    return false;
}

test "zigLineHasAdrInStringLiteral ignores comments and flags string literals" {
    try std.testing.expect(!zigLineHasAdrInStringLiteral("// (ADR-0082) comment only"));
    try std.testing.expect(!zigLineHasAdrInStringLiteral("const x = 1; // (ADR-0001)"));
    try std.testing.expect(zigLineHasAdrInStringLiteral("@panic(\"needs store (ADR-0082)\");"));
    try std.testing.expect(zigLineHasAdrInStringLiteral(".message = \"cap (ADR-0025)\","));
    try std.testing.expect(!zigLineHasAdrInStringLiteral(".message = \"cap exceeded\","));
}
