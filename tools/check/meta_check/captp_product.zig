//! The CapTP product-surface checks.
//!
//! The live-product vocabulary held honest: transport symbols and designator
//! schemes in lockstep with `model.transport` and the residents, the
//! application-surface verb inventory across every binding and the skills,
//! the CapTP CLI/MCP skill authorities and agent dogfood routing, the CapTP
//! vocabulary map (ADR-0079), the CLI deadline and listen-stop contracts, the
//! lab UX honesty rows, and the Racket conformance-script paren balance.
//! Wired by the meta-check driver (`tools/check/meta_check.zig`).

const std = @import("std");
const bans = @import("bans.zig");
const util = @import("util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;

/// The transport-agnosticism phrase bans live in `meta_check/bans.zig`
/// (`transport_vocabulary`); this keeps only the resident-count heuristic,
/// whose violation message names the fix (`keyed-tcp` in the enumeration)
/// rather than the matched needle. It shares the scanned path list with
/// those rows.
pub fn checkTransportVocabulary(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (bans.transport_vocabulary_paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for transport-vocabulary check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        // Resident enumerations that still say "three" without keyed-tcp.
        if (std.mem.indexOf(u8, contents, "three residents") != null or
            std.mem.indexOf(u8, contents, "Three residents") != null or
            std.mem.indexOf(u8, contents, "All three residents") != null or
            std.mem.indexOf(u8, contents, "three real residents") != null or
            std.mem.indexOf(u8, contents, "Three ship today") != null or
            std.mem.indexOf(u8, contents, "walks all three") != null)
        {
            if (std.mem.indexOf(u8, contents, "keyed-tcp") == null) {
                try appendViolation(
                    gpa,
                    violations,
                    "{s}: netlayer resident count omits `keyed-tcp` — list `tcp`, `keyed-tcp`, `inproc`, and iroh",
                    .{path},
                );
            }
        }
    }
}

/// The model's designator-scheme policy must agree with each transport
/// resident's `designator_scheme`; the driver wrapper must delegate to that
/// policy rather than restating it.
pub fn checkDesignatorSchemeSync(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const Transport = struct {
        name: []const u8,
        path: []const u8,
    };
    const transports = [_]Transport{
        .{ .name = "tcp", .path = "src/net/transport/tcp.zig" },
        .{ .name = "keyed-tcp", .path = "src/net/transport/tcp_keyed.zig" },
        .{ .name = "inproc", .path = "src/net/transport/inproc.zig" },
        .{ .name = "iroh", .path = "src/net/transport/iroh.zig" },
        .{ .name = "webrtc", .path = "src/net/transport/webrtc.zig" },
        .{ .name = "keyed-relay", .path = "src/net/transport/keyed_relay.zig" },
    };

    const vocab_path = "src/driver/core/vocab.zig";
    const vocab = root.readFileAlloc(io, vocab_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for designator-scheme sync with {s}", .{ vocab_path, @errorName(err) });
        return;
    };
    defer gpa.free(vocab);

    const vocab_body = fnBody(vocab, "pub fn designatorSchemeForTransport") orelse {
        try appendViolation(gpa, violations, "{s}: missing `pub fn designatorSchemeForTransport`", .{vocab_path});
        return;
    };
    if (std.mem.indexOf(u8, vocab_body, "return model.transport.designatorScheme(transport);") == null) {
        try appendViolation(gpa, violations, "{s}: designatorSchemeForTransport must delegate to model.transport.designatorScheme", .{vocab_path});
    }

    const policy_path = "src/ocapn/model/transport.zig";
    const policy = root.readFileAlloc(io, policy_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read designator-scheme policy with {s}", .{ policy_path, @errorName(err) });
        return;
    };
    defer gpa.free(policy);
    const fn_body = fnBody(policy, "pub fn designatorScheme") orelse {
        try appendViolation(gpa, violations, "{s}: missing `pub fn designatorScheme`", .{policy_path});
        return;
    };

    for (transports) |t| {
        const policy_scheme = designatorSchemeFromPolicyBody(fn_body, t.name);
        const resident = root.readFileAlloc(io, t.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for designator-scheme sync with {s}", .{ t.path, @errorName(err) });
            continue;
        };
        defer gpa.free(resident);

        const resident_scheme = designatorSchemeFromResident(resident);
        if (!std.mem.eql(u8, policy_scheme, resident_scheme)) {
            try appendViolation(
                gpa,
                violations,
                "designator-scheme mismatch for `{s}`: model.transport.designatorScheme → .{s}, but {s} resident declaration → .{s}",
                .{ t.name, policy_scheme, t.path, resident_scheme },
            );
        }
    }

    // Every explicit policy arm must name a shipped transport.
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, fn_body, search, "transport, ")) |at| {
        const after = fn_body[at + "transport, ".len ..];
        const end = std.mem.indexOfScalar(u8, after, ')') orelse break;
        const field = std.mem.trim(u8, after[0..end], " \t\r\n");
        const name = transportNameFromField(field) orelse {
            try appendViolation(gpa, violations, "{s}: designatorScheme names unknown transport constant `{s}`", .{ policy_path, field });
            search = at + 1;
            continue;
        };
        var known = false;
        for (transports) |t| {
            if (std.mem.eql(u8, t.name, name)) {
                known = true;
                break;
            }
        }
        if (!known) {
            try appendViolation(
                gpa,
                violations,
                "{s}: designatorScheme names unknown transport `{s}` — add a netlayer resident or drop the arm",
                .{ policy_path, name },
            );
        }
        search = at + 1;
    }

    // Residents must alias `transport_name` to `model.transport.*` (one symbol table).
    for (transports) |t| {
        const resident = root.readFileAlloc(io, t.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for transport_name alias check with {s}", .{ t.path, @errorName(err) });
            continue;
        };
        defer gpa.free(resident);
        const field = transportSymbolField(t.name);
        var alias_buf: [96]u8 = undefined;
        const alias = std.fmt.bufPrint(&alias_buf, "model.transport.{s}", .{field}) catch continue;
        if (std.mem.indexOf(u8, resident, alias) == null) {
            try appendViolation(gpa, violations, "{s}: `transport_name` must alias `{s}` — one model.transport symbol table", .{ t.path, alias });
        }
    }
}

/// A dial target and an authenticated far end are separate facts. Only code
/// that realized the connection may state the latter (ADR-0105, ADR-0109).
///
/// `engine.Peer.bindVerifiedChannelKey` says what the code that realized the
/// connection verified about the byte channel's far end. It is made by
/// supplying the verified key, so a caller that cannot name one cannot make
/// it, and the call belongs to a transport resident or the loop bridge that
/// adopts its connections. Never to a session, a codec, a policy table, or an
/// application driver that merely knows who it meant to reach.
///
/// `demandPartnerDurableKey` is deliberately unpoliced: naming the
/// identity you dialed is any dialer's to do, and separating it from channel
/// proof is the point of the split.
///
/// The verbs are the whole story only while nothing reaches the state
/// behind them, so the last row is containment rather than a call ban: the
/// field name `durable_pin` may appear in the file that declares it and
/// nowhere else. That covers a field write, a flag write inside the pin, and a
/// read that would let a caller re-derive a verdict of its own — which the
/// previous spelling, a ban on one assignment form, did not: the pin's fields
/// are public, so `peer.durable_pin.?.remote_proved = true` matched no needle
/// and wrote evidence from anywhere. Reads go through the accessors beside the
/// verbs.
///
/// Every Zig tree a caller could live in is scanned, including `bindings/` and
/// the repository root, because the tempting place to reach for a proof is an
/// interop or app driver rather than `src/`. Tests are exempt as a class:
/// proving what these verbs do is their job, and they reach for them
/// deliberately.
///
/// It replaces the transport-to-mechanism mirror check, whose invariant went
/// away with the table: a transport symbol names an address grammar, not what
/// authenticated a partner.
///
/// Each verb also names how a *foreign* realizer states the same fact, because
/// a realizer is not always in this tree. A binding that owns its own sockets
/// realizes its own connections, and an evidence verb only native code can
/// speak is a hole: the session is weighed on what the partner volunteered
/// while a stronger proof sat unread one layer down. That is not hypothetical —
/// it is how a binding-hosted iroh listener under-reported every accepted
/// session, and no generated-mirror check could see it, because those compare
/// symbols that exist and this one did not. So a verb either names the C entry
/// point that carries it, checked present in the public header, or says why no
/// embedder can hold the fact.
pub fn checkDurablePinWriters(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // A binding owns its own sockets, so it realizes its own connections and
    // has evidence of its own to state. Either the public C header carries an
    // entry point for it, or no embedder can hold the fact and this says why.
    const Foreign = union(enum) {
        /// The `pancake_host_*` prototype a foreign realizer speaks through,
        /// checked present in `include/pancake_host.h` — the actual public
        /// surface, so an export the inventory forgot to publish still fails.
        entry: []const u8,
        /// Why an absent entry point is the design rather than the gap.
        none_because: []const u8,
    };
    const Verb = struct {
        /// The needle, not the bare symbol: prose that names a verb is how a
        /// layering rule gets explained, and explaining it is not calling it.
        call: []const u8,
        declaration: []const u8,
        declared_in: []const u8,
        /// The only files that may speak this fact, by full repository-relative
        /// path so a directory rename shows up as a violation rather than
        /// passing on a basename.
        speakers: []const []const u8,
        /// What those files have that nobody else does, quoted at whoever
        /// tripped the check.
        standing: []const u8,
        /// How a realizer outside this tree states the same fact.
        foreign: Foreign,
    };
    const verbs = [_]Verb{
        .{
            .call = ".bindVerifiedChannelKey(",
            .declaration = "pub fn bindVerifiedChannelKey(",
            .declared_in = "src/ocapn/engine/mod.zig",
            .speakers = &.{
                "src/net/transport/iroh.zig",
                "src/net/transport/webrtc.zig",
                "src/driver/bridge.zig",
                "src/driver/core/host.zig",
                "src/c_abi/host/session.zig",
            },
            .standing = "it realized the connection, or it carries the testimony of an embedder that did",
            .foreign = .{ .entry = "pancake_host_session_bind_verified_channel_key" },
        },
        .{
            .call = "durable_pin",
            .declaration = "durable_pin: DurablePin = .{}",
            .declared_in = "src/ocapn/engine/mod.zig",
            .speakers = &.{"src/ocapn/engine/mod.zig"},
            .standing = "it declares the pin, so every write goes through the verbs beside it and every read through the accessors beside them",
            .foreign = .{ .none_because = "it is the state the verbs write, not a fact anyone states; C reads the verdict through pancake_host_session_partner_identity" },
        },
    };
    const roots = [_][]const u8{ "src", "cli", "interop", "apps", "examples", "bench", "bindings", "tools" };
    // This file spells the needles it searches for, so it would otherwise
    // report itself. Naming the exemption is the honest version of that.
    const this_check = "tools/check/meta_check/captp_product.zig";

    // A rename that emptied a speaker list would leave the rule holding
    // nothing, which is the failure mode this check exists to prevent. So both
    // halves are confirmed present rather than assumed: the declaration, and
    // one call per speaker.
    const public_header = "include/pancake_host.h";
    const header_source = root.readFileAlloc(io, public_header, gpa, .limited(4 << 20)) catch null;
    defer if (header_source) |source| gpa.free(source);

    for (verbs) |verb| {
        const declaring_source = root.readFileAlloc(io, verb.declared_in, gpa, .limited(4 << 20)) catch null;
        defer if (declaring_source) |source| gpa.free(source);
        if (declaring_source == null or std.mem.indexOf(u8, declaring_source.?, verb.declaration) == null) {
            try appendViolation(
                gpa,
                violations,
                "{s}: missing `{s}`. The ADR-0105 durable-pin verb moved or was renamed, so update `checkDurablePinWriters` in tools/check/meta_check/captp_product.zig with it",
                .{ verb.declared_in, verb.declaration },
            );
        }
        for (verb.speakers) |speaker| {
            const source = root.readFileAlloc(io, speaker, gpa, .limited(4 << 20)) catch null;
            defer if (source) |contents| gpa.free(contents);
            if (source != null and std.mem.indexOf(u8, source.?, verb.call) != null) continue;
            try appendViolation(
                gpa,
                violations,
                "{s}: listed as the only caller of `{s}` but never calls it. Either it stopped being one, or the list in tools/check/meta_check/captp_product.zig is stale",
                .{ speaker, verb.call },
            );
        }
        switch (verb.foreign) {
            .none_because => {},
            .entry => |entry| {
                const published = header_source != null and
                    std.mem.indexOf(u8, header_source.?, entry) != null;
                if (published) continue;
                try appendViolation(
                    gpa,
                    violations,
                    "{s}: no `{s}`, so a realizer outside this tree cannot state what `{s}` states. A binding owns its own sockets and proves its own connections; leaving it mute means every session it hosts is weighed on what the partner volunteered. Publish the entry point, or record in `checkDurablePinWriters` in tools/check/meta_check/captp_product.zig why no embedder can hold this fact",
                    .{ public_header, entry, verb.call },
                );
            },
        }
    }

    // The repository root's own `.zig` files (`build.zig` and its siblings) are
    // a tree the walk below cannot reach, and a build script is exactly the
    // kind of place a shortcut gets wired.
    if (root.openDir(io, ".", .{ .iterate = true }) catch null) |top| {
        var dir = top;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
            const contents = root.readFileAlloc(io, entry.name, gpa, .limited(4 << 20)) catch continue;
            defer gpa.free(contents);
            for (verbs) |verb| {
                if (std.mem.indexOf(u8, contents, verb.call) == null) continue;
                try appendViolation(
                    gpa,
                    violations,
                    "{s}: names `{s}`, but that fact is only one layer's to state (ADR-0105), and that layer is the one where {s}",
                    .{ entry.name, verb.call, verb.standing },
                );
            }
        }
    }

    for (roots) |tree| {
        var dir = root.openDir(io, tree, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for the durable-pin writer check with {s}", .{ tree, @errorName(err) });
            continue;
        };
        defer dir.close(io);

        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
            // Vendored trees carry no pancake rule; skipping by name keeps the
            // walk from reading a dependency's sources.
            if (std.mem.indexOf(u8, entry.path, "node_modules/") != null) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ tree, entry.path });
            defer gpa.free(path);
            if (std.mem.eql(u8, path, this_check)) continue;
            const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch continue;
            defer gpa.free(contents);

            for (verbs) |verb| {
                if (std.mem.indexOf(u8, contents, verb.call) == null) continue;
                var allowed = false;
                for (verb.speakers) |speaker| {
                    if (std.mem.eql(u8, path, speaker)) allowed = true;
                }
                if (allowed) continue;
                try appendViolation(
                    gpa,
                    violations,
                    "{s}: names `{s}`, but that fact is only one layer's to state (ADR-0105), and that layer is the one where {s}. Either this file has that standing and belongs in `verbs` in tools/check/meta_check/captp_product.zig, or it should be naming the identity it dialed instead (`demandPartnerDurableKey`), or reading through `demandedPartnerKey` / `verifiedChannelKey` / `partnerDurableProvenance`.",
                    .{ path, verb.call, verb.standing },
                );
            }
        }
    }
}

/// Every member of `driver_core.HostError` is classified by name somewhere, so
/// none of them reaches a C embedder as `PANCAKE_ERR_INTERNAL`.
///
/// There are two tables that classify by name, and either will do. The C
/// adapter's own `errToCode` names the host-tier refusals, and
/// `engine.abort_projection.classify` names the protocol failures the adapter
/// forwards to through `shared.feedErrorToCode`. A member in neither falls
/// through both `else` arms to `.foreign`, and the embedder is told the library
/// has a bug when what happened is that it misused a verb. Nothing in the
/// language notices, because an `else` makes each switch exhaustive whatever
/// the error set holds.
///
/// All three sources are read rather than assumed, so a rename that emptied one
/// fails here instead of passing on an empty set: the error set must have
/// members, and both switches must be found.
pub fn checkHostErrorCodeMap(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const declaring = "src/driver/core/host.zig";
    const mapping = "src/c_abi/host/common.zig";
    const projection = "src/ocapn/engine/abort_projection.zig";

    const host_source = root.readFileAlloc(io, declaring, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for the HostError code-map check with {s}", .{ declaring, @errorName(err) });
        return;
    };
    defer gpa.free(host_source);
    const map_source = root.readFileAlloc(io, mapping, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for the HostError code-map check with {s}", .{ mapping, @errorName(err) });
        return;
    };
    defer gpa.free(map_source);
    const projection_source = root.readFileAlloc(io, projection, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for the HostError code-map check with {s}", .{ projection, @errorName(err) });
        return;
    };
    defer gpa.free(projection_source);

    const set_open = "pub const HostError = error{";
    const set_start = std.mem.indexOf(u8, host_source, set_open) orelse {
        try appendViolation(gpa, violations, "{s}: `{s}` not found — update `checkHostErrorCodeMap` in tools/check/meta_check/captp_product.zig", .{ declaring, set_open });
        return;
    };
    const set_body_start = set_start + set_open.len;
    // The set ends at the first `};` in column zero after it, the spelling every
    // top-level declaration in this tree closes with.
    const set_end_rel = std.mem.indexOf(u8, host_source[set_body_start..], "\n};") orelse {
        try appendViolation(gpa, violations, "{s}: `HostError` has no closing brace line — update `checkHostErrorCodeMap` in tools/check/meta_check/captp_product.zig", .{declaring});
        return;
    };
    const set_body = host_source[set_body_start .. set_body_start + set_end_rel];

    const switch_open = "pub fn errToCode(err: anyerror) i32 {";
    const switch_start = std.mem.indexOf(u8, map_source, switch_open) orelse {
        try appendViolation(gpa, violations, "{s}: `{s}` not found — update `checkHostErrorCodeMap` in tools/check/meta_check/captp_product.zig", .{ mapping, switch_open });
        return;
    };
    const switch_end_rel = std.mem.indexOf(u8, map_source[switch_start..], "\n}") orelse map_source.len - switch_start;
    const switch_body = map_source[switch_start .. switch_start + switch_end_rel];

    const classify_open = "pub fn classify(";
    const classify_start = std.mem.indexOf(u8, projection_source, classify_open) orelse {
        try appendViolation(gpa, violations, "{s}: `{s}` not found — update `checkHostErrorCodeMap` in tools/check/meta_check/captp_product.zig", .{ projection, classify_open });
        return;
    };
    const classify_end_rel = std.mem.indexOf(u8, projection_source[classify_start..], "\n}") orelse projection_source.len - classify_start;
    const classify_body = projection_source[classify_start .. classify_start + classify_end_rel];

    var members: usize = 0;
    var lines = std.mem.splitScalar(u8, set_body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        // Members are the bare `Name,` lines; doc comments and blank lines are
        // everything else in there.
        if (line.len < 2 or !std.mem.endsWith(u8, line, ",")) continue;
        if (std.mem.startsWith(u8, line, "//")) continue;
        const name = line[0 .. line.len - 1];
        if (name.len == 0 or !std.ascii.isUpper(name[0])) continue;
        var identifier = true;
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c)) identifier = false;
        }
        if (!identifier) continue;
        members += 1;

        var needle_buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "error.{s},", .{name}) catch continue;
        var alt_buf: [128]u8 = undefined;
        const alt = std.fmt.bufPrint(&alt_buf, "error.{s} ", .{name}) catch continue;
        if (std.mem.indexOf(u8, switch_body, needle) != null) continue;
        if (std.mem.indexOf(u8, switch_body, alt) != null) continue;
        if (std.mem.indexOf(u8, classify_body, needle) != null) continue;
        if (std.mem.indexOf(u8, classify_body, alt) != null) continue;
        try appendViolation(
            gpa,
            violations,
            "{s}: `HostError.{s}` is named neither in `errToCode` in {s} nor in `classify` in {s}, so it falls through both to PANCAKE_ERR_INTERNAL and tells an embedder the library has a bug. Give it the return code its siblings have.",
            .{ declaring, name, mapping, projection },
        );
    }
    if (members == 0) {
        try appendViolation(
            gpa,
            violations,
            "{s}: the HostError code-map check parsed no members, so it is holding nothing — update `checkHostErrorCodeMap` in tools/check/meta_check/captp_product.zig",
            .{declaring},
        );
    }
}

fn fnBody(source: []const u8, decl: []const u8) ?[]const u8 {
    const fn_start = std.mem.indexOf(u8, source, decl) orelse return null;
    const after_fn = source[fn_start..];
    const body_open = std.mem.indexOfScalar(u8, after_fn, '{') orelse return null;
    const body = after_fn[body_open..];
    const body_close = std.mem.indexOfScalar(u8, body, '}') orelse return null;
    return body[0 .. body_close + 1];
}

fn transportNameFromField(field: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, field, "tcp")) return "tcp";
    if (std.mem.eql(u8, field, "keyed_tcp")) return "keyed-tcp";
    if (std.mem.eql(u8, field, "inproc")) return "inproc";
    if (std.mem.eql(u8, field, "iroh")) return "iroh";
    if (std.mem.eql(u8, field, "webrtc")) return "webrtc";
    if (std.mem.eql(u8, field, "keyed_relay")) return "keyed-relay";
    return null;
}

fn designatorSchemeFromPolicyBody(fn_body: []const u8, transport: []const u8) []const u8 {
    // Match the model policy's `transport, NAME)` arms, plus the former driver
    // forms so this diagnostic remains useful while a move is incomplete.
    var buf: [128]u8 = undefined;
    const policy_needle = std.fmt.bufPrint(&buf, "transport, {s})", .{transportSymbolField(transport)}) catch return "address";
    if (schemeReturnAfterNeedle(fn_body, policy_needle)) |scheme| return scheme;
    const model_needle = std.fmt.bufPrint(&buf, "transport, model.transport.{s})", .{transportSymbolField(transport)}) catch return "address";
    if (schemeReturnAfterNeedle(fn_body, model_needle)) |scheme| return scheme;
    const lit_needle = std.fmt.bufPrint(&buf, "transport, \"{s}\")", .{transport}) catch return "address";
    if (schemeReturnAfterNeedle(fn_body, lit_needle)) |scheme| return scheme;
    return "address";
}

fn transportSymbolField(transport: []const u8) []const u8 {
    if (std.mem.eql(u8, transport, "tcp")) return "tcp";
    if (std.mem.eql(u8, transport, "keyed-tcp")) return "keyed_tcp";
    if (std.mem.eql(u8, transport, "inproc")) return "inproc";
    if (std.mem.eql(u8, transport, "iroh")) return "iroh";
    if (std.mem.eql(u8, transport, "keyed-relay")) return "keyed_relay";
    return transport;
}

fn schemeReturnAfterNeedle(fn_body: []const u8, needle: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, fn_body, needle) orelse return null;
    const after = fn_body[at + needle.len ..];
    if (std.mem.indexOf(u8, after, "return .key")) |k| {
        if (std.mem.indexOf(u8, after, "return .address")) |a| {
            if (a < k) return "address";
        }
        if (std.mem.indexOf(u8, after, "\nif ")) |next_if| {
            if (k < next_if) return "key";
        } else return "key";
    }
    if (std.mem.indexOf(u8, after, "return .address")) |_| return "address";
    return null;
}

/// Read a resident's explicit `designator_scheme`, preferring the Netlayer
/// vtable and accepting a direct declaration for a signaling-only resident.
/// Absence means the VTable default (`.address`).
fn designatorSchemeFromResident(source: []const u8) []const u8 {
    // Prefer the first Netlayer.VTable literal; keyed-tcp/iroh set `.key`
    // there. Listener vtables may repeat the same field and must not confuse
    // an address-scheme resident.
    const markers = [_][]const u8{
        "const resident_vtable: Netlayer.VTable",
        "const resident_vtable: net.netlayer.Netlayer.VTable",
        "const netlayer_vtable = Netlayer.VTable",
        "const netlayer_vtable: Netlayer.VTable",
    };
    var vtable_region: ?[]const u8 = null;
    for (markers) |marker| {
        if (std.mem.indexOf(u8, source, marker)) |at| {
            const rest = source[at..];
            const open = std.mem.indexOfScalar(u8, rest, '{') orelse continue;
            const close = std.mem.indexOfScalar(u8, rest[open..], '}') orelse continue;
            vtable_region = rest[open .. open + close + 1];
            break;
        }
    }
    const region = vtable_region orelse source;
    if (std.mem.indexOf(u8, region, ".designator_scheme = .key") != null) return "key";
    if (std.mem.indexOf(u8, region, ".designator_scheme = .address") != null) return "address";
    if (std.mem.indexOf(u8, source, "pub const designator_scheme: net.netlayer.DesignatorScheme = .key") != null) return "key";
    if (std.mem.indexOf(u8, source, "pub const designator_scheme: net.netlayer.DesignatorScheme = .address") != null) return "address";
    return "address";
}

/// The reference relays (the Deno, Python, and Racket rows of the
/// `bindings-relay` matrix) must load the iroh binding lazily, only on the
/// `?locator=` dial path, so a `?to=`-only run links no iroh FFI and the
/// à-la-carte archive split holds (ADR-0059, ADR-0086). Rust pins this at
/// compile time (`#[cfg(feature = "iroh")]`); the other three defer the import
/// by hand, so this keeps that convention a build-checked invariant rather than
/// trusting three hand-written import sites. The rooms production relay is out
/// of scope — it links the full stack deliberately.
pub fn checkReferenceRelayIrohLazy(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const why = "load the iroh binding lazily on the `?locator=` dial path so a TCP-only relay links no iroh FFI (ADR-0086)";

    // Deno: the `@pancake/iroh` specifier may appear only inside a dynamic
    // `import(...)`; a static `from "@pancake/iroh"` would load iroh eagerly.
    const deno_paths = [_][]const u8{ "bindings/ts/relay/serve.ts", "bindings/ts/relay/deno_channels.ts" };
    for (deno_paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for reference-relay-iroh-lazy check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "\"@pancake/iroh\"") != null and
                std.mem.indexOf(u8, line, "import(") == null)
            {
                try appendViolation(gpa, violations, "{s}: static import of `@pancake/iroh` — {s}", .{ path, why });
            }
        }
    }

    // Python: the `pancake.iroh` import must be indented (inside the dial
    // function), never at module scope (column 0).
    py: {
        const path = "bindings/python/relay.py";
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for reference-relay-iroh-lazy check with {s}", .{ path, @errorName(err) });
            break :py;
        };
        defer gpa.free(contents);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            const is_import = std.mem.startsWith(u8, trimmed, "from pancake.iroh") or
                std.mem.startsWith(u8, trimmed, "import pancake.iroh");
            if (is_import and trimmed.len == line.len) {
                try appendViolation(gpa, violations, "{s}: module-scope `pancake.iroh` import — {s}", .{ path, why });
            }
        }
    }

    // Racket: the iroh companion is named by its literal only on the
    // `define-runtime-path` line; the lazy `dynamic-require` calls reach it
    // through the `iroh-companion-path` variable. Any other line naming the
    // literal is a static require that loads iroh eagerly.
    rkt: {
        const path = "bindings/racket/relay.rkt";
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for reference-relay-iroh-lazy check with {s}", .{ path, @errorName(err) });
            break :rkt;
        };
        defer gpa.free(contents);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "pancake-iroh") != null and
                std.mem.indexOf(u8, line, "define-runtime-path") == null)
            {
                try appendViolation(gpa, violations, "{s}: static reference to the `pancake-iroh` companion — {s}", .{ path, why });
            }
        }
    }
}

/// The rooms production relay funnels every dial through the shared
/// `classifyRelayTarget` (over `pancake_host_plan_dial`), so its SSRF allow-list
/// sorts a target exactly as the dial that follows: one classified value gates
/// admission (`relayAllowed`) and drives the dial (`relayToTarget`). The
/// reference relays' local `?to=` / `?locator=` parameter dispatch must not leak
/// into the production path, where dialing a raw parameter would bypass the
/// classifier and the allow-list and reopen the SSRF hole (ADR-0086).
pub fn checkProductionRelayClassifierLockstep(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const web = "apps/rooms/web/serve.ts";
    const server = "apps/rooms/web/relay.ts";
    // The reference relays' two-parameter dispatch; forbidden in the production
    // path, which dials only a classified `?target=` and bridges `?rendezvous=`.
    const params = [_][]const u8{ ".get(\"to\")", ".get(\"locator\")" };

    web_blk: {
        const contents = root.readFileAlloc(io, web, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for production-relay-classifier check with {s}", .{ web, @errorName(err) });
            break :web_blk;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "classifyRelayTarget(") == null) {
            try appendViolation(gpa, violations, "{s}: the production relay must classify its dial target through `classifyRelayTarget` (the plan_dial SSRF chokepoint) (ADR-0086)", .{web});
        }
        for (params) |param| {
            if (std.mem.indexOf(u8, contents, param) != null) {
                try appendViolation(gpa, violations, "{s}: reads a `{s}` parameter — the reference-relay dispatch; the production relay dials only a classified `?target=` (ADR-0086 SSRF lockstep)", .{ web, param });
            }
        }
    }

    srv_blk: {
        const contents = root.readFileAlloc(io, server, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for production-relay-classifier check with {s}", .{ server, @errorName(err) });
            break :srv_blk;
        };
        defer gpa.free(contents);
        for (params) |param| {
            if (std.mem.indexOf(u8, contents, param) != null) {
                try appendViolation(gpa, violations, "{s}: reads a `{s}` parameter — the reference-relay dispatch; the production relay dials only a classified `?target=` (ADR-0086 SSRF lockstep)", .{ server, param });
            }
        }
    }
}

/// Every Racket script under `conformance/goblins-peer/racket/` must read as
/// balanced s-expressions. The hermetic gate cannot run Goblins, so a script
/// with an unclosed paren ships silently, and every live step that spawns it
/// watches a dialer die at parse. Reader-level only: strings, `;` line
/// comments, and `#\` char literals are skipped; this is not an expander.
pub fn checkRacketScriptBalance(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const dir_path = "conformance/goblins-peer/racket";
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for paren-balance check with {s}", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".rkt")) continue;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for paren-balance check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (racketParenImbalance(contents)) |imbalance| {
            try appendViolation(gpa, violations, "{s}: unbalanced s-expressions (net depth {d} at end of file) — a script that cannot read parks every live step that spawns it", .{ path, imbalance });
        }
    }
}

/// Net open-parens at end of file (positive: unclosed openers; negative: an
/// extra closer, reported at first dip), or null when balanced. Treats (),
/// [], {} uniformly and skips strings, `;` comments, and `#\` char literals.
fn racketParenImbalance(contents: []const u8) ?isize {
    var depth: isize = 0;
    var i: usize = 0;
    while (i < contents.len) : (i += 1) {
        switch (contents[i]) {
            ';' => while (i < contents.len and contents[i] != '\n') {
                i += 1;
            },
            '"' => {
                i += 1;
                while (i < contents.len) : (i += 1) {
                    if (contents[i] == '\\') {
                        i += 1;
                        continue;
                    }
                    if (contents[i] == '"') break;
                }
            },
            '#' => if (i + 1 < contents.len and contents[i + 1] == '\\') {
                i += 2;
            },
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                depth -= 1;
                if (depth < 0) return depth;
            },
            else => {},
        }
    }
    return if (depth == 0) null else depth;
}

/// The application-surface verbs the vision promises in every binding and on the
/// native driver. Each surface that introduces the vocabulary must list all of
/// them; a dropped verb is a silently second-class surface.
const application_surface_verbs = [_][]const u8{
    "connect", "listen", "fetch", "publish", "spawn", "send", "tell", "serve", "close",
};

/// The binding overview is the one human-facing enumeration of the shared
/// application vocabulary. Tutorials can teach a smaller path without
/// pretending to be an API checklist.
const application_surface_files = [_][]const u8{
    "bindings/README.md",
};

/// Whether `verb` appears as an inline-code token in `contents`, tolerating the
/// three ways the surfaces write it: bare (`connect`), as a call
/// (`connect(locator)`), or as a method on a receiver (`conn.tell(ref, …)`).
/// A trailing `(…)` and a leading `recv.` are stripped before comparison.
fn mentionsVerbInCode(contents: []const u8, verb: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, contents, i, '`')) |open| {
        const after = open + 1;
        const close = std.mem.indexOfScalarPos(u8, contents, after, '`') orelse return false;
        var span = contents[after..close];
        if (std.mem.indexOfScalar(u8, span, '(')) |paren| span = span[0..paren];
        if (std.mem.lastIndexOfScalar(u8, span, '.')) |dot| span = span[dot + 1 ..];
        if (std.mem.eql(u8, span, verb)) return true;
        i = close + 1;
    }
    return false;
}

/// Gate that every living-state surface listing the application vocabulary names
/// all nine verbs. This is the check the prose restatements collapse toward: when
/// a verb is added or renamed, this fails until every surface is updated, so the
/// list cannot silently drift on one surface (as it did when `listen` and `tell`
/// went missing from the examples index).
pub fn checkApplicationSurfaceVerbs(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (application_surface_files) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for application-surface verb check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (application_surface_verbs) |verb| {
            if (!mentionsVerbInCode(contents, verb)) {
                try appendViolation(gpa, violations, "{s}: application-surface verb `{s}` is missing, the nine-verb vocabulary (connect, listen, fetch, publish, spawn, send, tell, serve, close) must be complete on every surface that lists it", .{ path, verb });
            }
        }
    }
}

/// CapTP leaf names from `cli/registry.zig`'s `commands` table.
/// Command rows put `.name` / `.help` on consecutive lines; positional structs
/// keep both on one line — that difference is how we avoid collecting `locator`.
fn collectCaptpRegistryNames(
    gpa: std.mem.Allocator,
    registry_src: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const start = std.mem.indexOf(u8, registry_src, "pub const commands") orelse return;
    const end_marker = std.mem.indexOfPos(u8, registry_src, start, "\n};") orelse registry_src.len;
    const block = registry_src[start..end_marker];
    var line_start: usize = 0;
    while (line_start < block.len) {
        const nl = std.mem.indexOfScalarPos(u8, block, line_start, '\n') orelse block.len;
        const line = std.mem.trim(u8, block[line_start..nl], " \t");
        if (std.mem.startsWith(u8, line, ".name = \"")) {
            const after = ".name = \"".len;
            if (std.mem.indexOfScalarPos(u8, line, after, '"')) |q| {
                const name = line[after..q];
                var next = if (nl < block.len) nl + 1 else block.len;
                while (next < block.len) {
                    const nnl = std.mem.indexOfScalarPos(u8, block, next, '\n') orelse block.len;
                    const next_line = std.mem.trim(u8, block[next..nnl], " \t");
                    if (next_line.len == 0) {
                        next = if (nnl < block.len) nnl + 1 else block.len;
                        continue;
                    }
                    if (std.mem.startsWith(u8, next_line, ".help =")) {
                        try out.append(gpa, name);
                    }
                    break;
                }
            }
        }
        line_start = if (nl < block.len) nl + 1 else block.len;
    }
}

/// True when a markdown table is a CapTP verb inventory (header names Verb or
/// Command) and lists some registry leaves (≥3) but not all. Session-model
/// tables that mention `` `call` `` inline are not inventories.
fn captpVerbTableIsPartial(skill: []const u8, names: []const []const u8) bool {
    var line_start: usize = 0;
    var in_inventory = false;
    var hit: usize = 0;
    var seen: [64]bool = .{false} ** 64;
    while (line_start < skill.len) {
        const nl = std.mem.indexOfScalarPos(u8, skill, line_start, '\n') orelse skill.len;
        const line = skill[line_start..nl];
        const is_row = line.len > 0 and line[0] == '|';
        if (is_row) {
            const lower_buf_len = @min(line.len, 256);
            var lower_buf: [256]u8 = undefined;
            for (line[0..lower_buf_len], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
            const lower = lower_buf[0..lower_buf_len];
            if (!in_inventory) {
                if (std.mem.indexOf(u8, lower, "verb") != null or std.mem.indexOf(u8, lower, "command") != null) {
                    in_inventory = true;
                }
            } else {
                var cell_start: usize = 0;
                while (cell_start < line.len) {
                    if (line[cell_start] != '|') {
                        cell_start += 1;
                        continue;
                    }
                    const after_bar = cell_start + 1;
                    const next_bar = std.mem.indexOfScalarPos(u8, line, after_bar, '|') orelse line.len;
                    const cell = std.mem.trim(u8, line[after_bar..next_bar], " \t");
                    if (cell.len >= 3 and cell[0] == '`' and cell[cell.len - 1] == '`') {
                        const span = cell[1 .. cell.len - 1];
                        for (names, 0..) |name, ni| {
                            if (ni >= seen.len) break;
                            if (std.mem.eql(u8, span, name) and !seen[ni]) {
                                seen[ni] = true;
                                hit += 1;
                            }
                        }
                    }
                    cell_start = next_bar;
                }
            }
        } else if (in_inventory) {
            if (hit >= 3 and hit < names.len) return true;
            in_inventory = false;
            hit = 0;
            seen = .{false} ** 64;
        }
        line_start = if (nl < skill.len) nl + 1 else skill.len;
    }
    if (in_inventory and hit >= 3 and hit < names.len) return true;
    return false;
}

/// The pancake-mcp skill defers the tool catalog to MCP `tools/list` / registry.
/// Refuse a partial default-catalog inventory and unimplemented env overrides.
pub fn checkPancakeMcpSkillAuthority(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const skill_path = ".agents/skills/pancake-mcp/SKILL.md";
    const skill = root.readFileAlloc(io, skill_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ skill_path, @errorName(err) });
        return;
    };
    defer gpa.free(skill);

    if (std.mem.indexOf(u8, skill, "tools/list") == null) {
        try appendViolation(gpa, violations, "{s}: CapTP MCP catalog authority must point at `tools/list`", .{skill_path});
    }
    if (std.mem.indexOf(u8, skill, "Use pancake to write pancake") == null) {
        try appendViolation(gpa, violations, "{s}: must state dogfood destination `Use pancake to write pancake`", .{skill_path});
    }
    if (std.mem.indexOf(u8, skill, "PANCAKE_MCP_TOOLS") != null) {
        try appendViolation(gpa, violations, "{s}: forbids unimplemented `PANCAKE_MCP_TOOLS` — catalog is `--tools` only", .{skill_path});
    }
    // Hand-maintained default inventory (second catalog) — body or description.
    if (std.mem.indexOf(u8, skill, "everyday CapTP (dial, probe") != null or
        std.mem.indexOf(u8, skill, "dial, probe, call, tell, fetch, publish, info") != null or
        std.mem.indexOf(u8, skill, "dial/probe/call/tell/fetch/publish/info/close") != null)
    {
        try appendViolation(gpa, violations, "{s}: do not enumerate default MCP tools — discover via `tools/list` / registry", .{skill_path});
    }
}

/// Work / smell-annihilation / skill indexes must not funnel MCP through pancake-cli.
pub fn checkCaptpAgentDogfoodRouting(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const must_name_mcp = [_][]const u8{
        ".agents/skills/work/SKILL.md",
        ".agents/skills/smell-annihilation/SKILL.md",
        ".agents/skills/rooms-peer/SKILL.md",
        ".agents/skills/rooms-team/SKILL.md",
        ".agents/skills/community-review/SKILL.md",
    };
    for (must_name_mcp) |path| {
        const text = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP dogfood routing with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(text);
        if (std.mem.indexOf(u8, text, "pancake-mcp") == null) {
            try appendViolation(gpa, violations, "{s}: CapTP dogfood routing must name `pancake-mcp` (MCP is not under pancake-cli)", .{path});
        }
    }

    const indexes = [_][]const u8{
        ".agents/README.md",
        ".agents/skills/README.md",
    };
    for (indexes) |path| {
        const text = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP dogfood routing with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(text);
        // retire-by: the next rewrite of the skill indexes it guards —
        // retire the `argv, REPL, MCP` prose needle in that same diff.
        if (std.mem.indexOf(u8, text, "argv, REPL, MCP") != null) {
            try appendViolation(gpa, violations, "{s}: pancake-cli blurb must not claim MCP — MCP lives on pancake-mcp", .{path});
        }
    }

    const rooms_team_script = ".agents/skills/rooms-team/scripts/team.sh";
    root.access(io, rooms_team_script, .{}) catch |err| {
        try appendViolation(gpa, violations, "{s}: rooms-team skill requires companion script ({s})", .{ rooms_team_script, @errorName(err) });
    };
    const rooms_lead_watch = ".agents/skills/rooms-team/scripts/lead-watch.sh";
    root.access(io, rooms_lead_watch, .{}) catch |err| {
        try appendViolation(gpa, violations, "{s}: rooms-team skill requires lead wake pager ({s})", .{ rooms_lead_watch, @errorName(err) });
    };
    const rooms_team_skill = root.readFileAlloc(io, ".agents/skills/rooms-team/SKILL.md", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, ".agents/skills/rooms-team/SKILL.md: failed to read for companion refs with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(rooms_team_skill);
    if (std.mem.indexOf(u8, rooms_team_skill, "ops.md") == null or
        std.mem.indexOf(u8, rooms_team_skill, "gotchas.md") == null or
        std.mem.indexOf(u8, rooms_team_skill, "strategies.md") == null)
    {
        try appendViolation(gpa, violations, ".agents/skills/rooms-team/SKILL.md: must link ops.md, gotchas.md, and strategies.md", .{});
    }
    // Multi-surface / per-peer pending floors — prose that must not vanish when
    // the skill is edited; the hermetic one-wake golden holds the CLI half.
    if (std.mem.indexOf(u8, rooms_team_skill, "Multi-surface wake") == null) {
        try appendViolation(gpa, violations, ".agents/skills/rooms-team/SKILL.md: must keep Multi-surface wake (DM then room before peers)", .{});
    }
    if (std.mem.indexOf(u8, rooms_team_skill, "Pending is per-peer") == null) {
        try appendViolation(gpa, violations, ".agents/skills/rooms-team/SKILL.md: must keep Pending is per-peer (member dismisses own copy)", .{});
    }
    if (std.mem.indexOf(u8, rooms_team_skill, "DM-first is order") == null) {
        try appendViolation(gpa, violations, ".agents/skills/rooms-team/SKILL.md: must keep DM-first is order (not permission to ignore room)", .{});
    }
    // Positive member instruction to park lead-owned room is the wedge mode.
    if (std.mem.indexOf(u8, rooms_team_skill, "leave pending for the lead") != null) {
        try appendViolation(gpa, violations, ".agents/skills/rooms-team/SKILL.md: must not instruct members to leave pending for the lead", .{});
    }
}

/// The pancake-cli skill defers the CapTP catalog to `pancake help`. Gate the
/// authority pointer and refuse a partial verb-inventory table (second catalog).
pub fn checkPancakeCliSkillAuthority(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const skill_path = ".agents/skills/pancake-cli/SKILL.md";
    const skill = root.readFileAlloc(io, skill_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ skill_path, @errorName(err) });
        return;
    };
    defer gpa.free(skill);

    const has_help = std.mem.indexOf(u8, skill, "pancake help") != null or
        std.mem.indexOf(u8, skill, "help ocapn") != null;
    if (!has_help) {
        try appendViolation(gpa, violations, "{s}: CapTP catalog authority must point at `pancake help` / `help ocapn` (not a second verb table)", .{skill_path});
    }

    const registry_src = root.readFileAlloc(io, "cli/registry.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "cli/registry.zig: failed to read for pancake-cli skill check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(registry_src);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    try collectCaptpRegistryNames(gpa, registry_src, &names);
    if (names.items.len < 5) {
        try appendViolation(gpa, violations, "cli/registry.zig: expected CapTP leaf `.name = \"…\"` rows for pancake-cli skill check", .{});
        return;
    }
    if (captpVerbTableIsPartial(skill, names.items)) {
        try appendViolation(gpa, violations, "{s}: CapTP verb table is incomplete — enumerate every registry leaf or defer to `pancake help` (no second catalog)", .{skill_path});
    }
}

/// CapTP vocabulary (ADR-0079): structural resurrection guards only.
/// Deleted file paths, deleted `pub` symbols, and binding export maps that a
/// compiler would not catch. Prose tombstones for the rename ("multi-connection
/// node", "native-Zig Connection", …) were pruned once the rename shipped —
/// see the gate-accretion rule in `.agents/rules/agent-scaffolding.md`.
pub fn checkCaptpVocabulary(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // Deleted file names must stay deleted (renamed in ADR-0079).
    const deleted_paths = [_]struct { path: []const u8, reason: []const u8 }{
        .{ .path = "src/driver/connected_vat.zig", .reason = "BlockingSession lives in blocking_session.zig (ADR-0079)" },
        .{ .path = "test/driver/connected_vat_test.zig", .reason = "blocking_session_test.zig (ADR-0079)" },
        .{ .path = "bindings/ts/stack/connection.ts", .reason = "Session lives in session.ts (ADR-0079)" },
        .{ .path = "bindings/python/pancake/_connection.py", .reason = "Session lives in _session.py (ADR-0079)" },
        .{ .path = "bindings/rust/src/connection.rs", .reason = "Session lives in session.rs (ADR-0079)" },
        .{ .path = "bindings/racket/private/connection.rkt", .reason = "Session lives in session.rkt (ADR-0079)" },
    };
    for (deleted_paths) |entry| {
        if (root.access(io, entry.path, .{})) |_| {
            try appendViolation(gpa, violations, "{s}: file must stay deleted — {s}", .{ entry.path, entry.reason });
        } else |_| {}
    }

    // Resurrected symbols / exports — not prose.
    const SymbolBan = struct { path: []const u8, needle: []const u8, reason: []const u8 };
    const symbol_bans = [_]SymbolBan{
        .{ .path = "src/driver/core/host.zig", .needle = "pub fn hasSelfDesignator", .reason = "unused; callers use setSelfDesignator + selfDesignator" },
        .{ .path = "src/driver/core/host.zig", .needle = "pub fn vowConn", .reason = "unused; C ABI / bindings use vowConnClosing path, not ConnId lookup" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "pub fn execNodeAction", .reason = "host_pump-private; only called inside host_pump" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "pub fn dialActionFields", .reason = "host_pump-private; only called inside host_pump" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "fn queueFlushAction", .reason = "collapsed into queueUniqueConnAction" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "fn queueCloseAction", .reason = "collapsed into queueUniqueConnAction" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "pub fn queueUniqueConnAction", .reason = "host_pump-private; only called inside host_pump" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "pub fn drainWork", .reason = "host_pump-private; only called from finishVerb" },
        .{ .path = "src/net/mod.zig", .needle = "pub const FrameError = frame_stream.FrameError", .reason = "frame_stream-internal; not a net barrel export" },
        .{ .path = "src/net/mod.zig", .needle = "pub const drainWholeFrames = frame_stream.drainWholeFrames", .reason = "frame_stream-internal; not a net barrel export" },
        .{ .path = "src/driver/core/mod.zig", .needle = "pub const requiresDirectAddressesHint = vocab.requiresDirectAddressesHint", .reason = "use vocab.requiresDirectAddressesHint; not a driver_core barrel export" },
        .{ .path = "src/driver/core/mod.zig", .needle = "pub const DialPlanError = dial_plan.Error", .reason = "unused barrel export; dial_plan.Error stays module-local" },
        .{ .path = "src/driver/core/mod.zig", .needle = "pub const DialReach = dial_plan.Reach", .reason = "unused barrel export; dial_plan.Reach stays module-local" },
        .{ .path = "test/support/wait.zig", .needle = "pub const Signal = struct", .reason = "unused; use untilFlag" },
        .{ .path = "test/support/wait.zig", .needle = "pub const PublishedAddr = struct", .reason = "unused; no adopters" },
        .{ .path = "src/driver/mod.zig", .needle = "pub const Node = engine.Node", .reason = "driver.Node re-export deleted (ADR-0079)" },
        .{ .path = "src/driver/core/served.zig", .needle = "fn bindForeign", .reason = "use bindExport; bindForeign deleted (ADR-0079)" },
        .{ .path = "src/driver/core/served.zig", .needle = "fn spawnForeign", .reason = "spawnHosted (ADR-0079)" },
        .{ .path = "src/net/transport/tcp.zig", .needle = "pub const Locator = struct", .reason = "tcp.DialResolver (ADR-0079)" },
        .{ .path = "src/net/transport/iroh.zig", .needle = "pub const Locator = struct", .reason = "iroh.DialResolver (ADR-0079)" },
        .{ .path = "src/c_abi/shared/mod.zig", .needle = "pub const HostAllocator", .reason = "ContextAllocator (ADR-0079)" },
        .{ .path = "src/driver/blocking_session.zig", .needle = "pub const ConnectedVat", .reason = "BlockingSession (ADR-0079)" },
        .{ .path = "src/actors/vat/mod.zig", .needle = "pub const ForeignActor", .reason = "HostedActor (ADR-0079)" },
        .{ .path = "src/actors/vat/mod.zig", .needle = "fn spawnForeign", .reason = "spawnHosted (ADR-0079)" },
        .{ .path = "src/actors/vat/boxed.zig", .needle = "const ForeignBlock", .reason = "HostedBlock (ADR-0079)" },
        .{ .path = "src/ocapn/engine/pairing.zig", .needle = "pub fn pairedWithOffers", .reason = "use pairedNegotiated + negotiate" },
        .{ .path = "src/ocapn/engine/negotiation.zig", .needle = "pub fn offerForTarget", .reason = "test-local interop offer helper" },
        .{ .path = "src/ocapn/engine/negotiation.zig", .needle = "pub const InteropTarget", .reason = "test-local interop offer helper" },
        .{ .path = "src/ocapn/engine/negotiation.zig", .needle = "pub const CodecId = model.CodecId", .reason = "use model.CodecId" },
        .{ .path = "src/ocapn/engine/negotiation.zig", .needle = "pub fn sharesProfile", .reason = "removed; tests map negotiate null locally" },
        .{ .path = "bindings/ts/stack/mod.ts", .needle = "export { Node }", .reason = "export Host (ADR-0079)" },
        .{ .path = "bindings/ts/stack/mod.ts", .needle = "export { Connection }", .reason = "export Session (ADR-0079)" },
        .{ .path = "bindings/rust/src/lib.rs", .needle = "pub use host::Node", .reason = "pub use host::Host (ADR-0079)" },
        .{ .path = "bindings/rust/src/lib.rs", .needle = "pub use session::Connection", .reason = "pub use session::Session (ADR-0079)" },
        .{ .path = "bindings/python/pancake/__init__.py", .needle = "\"Node\"", .reason = "__all__ exports Host (ADR-0079)" },
        .{ .path = "bindings/python/pancake/__init__.py", .needle = "\"Connection\"", .reason = "__all__ exports Session (ADR-0079)" },
        .{ .path = "bindings/racket/pancake.rkt", .needle = "make-fresh-node", .reason = "make-fresh-host (ADR-0079)" },
        .{ .path = "bindings/racket/private/host.rkt", .needle = "(define (make-fresh-node", .reason = "make-fresh-host (ADR-0079)" },
        // Internal-vocabulary rule: a CapTP session is a `Session`, never a
        // `Conn`. conn/connection names only a byte stream, so the byte-fed
        // host tier must not respell its per-partner session as the byte-stream
        // `Conn` it once collided with in the same C ABI (ADR-0079 amendment).
        .{ .path = "include/pancake_host.h", .needle = "PancakeHostConn", .reason = "PancakeHostSession — a CapTP session is not a byte-stream Conn (ADR-0079)" },
        .{ .path = "include/pancake_host.h", .needle = "pancake_host_conn_", .reason = "pancake_host_session_* — a CapTP session is not a byte-stream conn (ADR-0079)" },
        .{ .path = "src/c_abi/host/mod.zig", .needle = "PancakeHostConn", .reason = "PancakeHostSession (ADR-0079)" },
        .{ .path = "src/c_abi/host/mod.zig", .needle = "pancake_host_conn_", .reason = "pancake_host_session_* (ADR-0079)" },
        .{ .path = "src/driver/core/host.zig", .needle = "pub const Conn ", .reason = "driver_core.Session — the byte-fed CapTP session is a Session (ADR-0079)" },
        // A public host-verb / PancakeHostAction field must not name a session
        // pointer `conn` — the exact conn-means-session residue review caught.
        .{ .path = "include/pancake_host.h", .needle = "PancakeHostSession *conn", .reason = "name the session-pointer param/field `session`, not `conn` (ADR-0079)" },
        .{ .path = "include/pancake_host.h", .needle = "out_conn", .reason = "name the out-session param `out_session`, not `out_conn` (ADR-0079)" },
        // Item-2 part 3: the byte-fed session type is `HostSession`, its id is
        // `PeerId` (the engine routes to Peers), and the Host releases sessions.
        .{ .path = "src/driver/core/host.zig", .needle = "pub const Session = struct", .reason = "the byte-fed CapTP session type is HostSession, never Session/Conn (ADR-0079)" },
        .{ .path = "src/driver/core/host.zig", .needle = "pub fn releaseConn", .reason = "releaseSession — the Host releases a HostSession, not a conn (ADR-0079)" },
        .{ .path = "src/ocapn/engine/node.zig", .needle = "pub const ConnId", .reason = "PeerId — the engine's routing id keys Peers, not byte-stream conns (ADR-0079)" },
        // Item-2 part 4: the Node registers/routes Peers, not conns — it returns
        // a PeerId and installs an engine.Peer.
        .{ .path = "src/ocapn/engine/node.zig", .needle = "pub fn registerConn", .reason = "registerPeer — the Node registers a Peer, not a byte-stream conn (ADR-0079)" },
        .{ .path = "src/ocapn/engine/node.zig", .needle = "conns:", .reason = "the Node's Peer table is `peers`, not `conns` (ADR-0079)" },
    };
    for (symbol_bans) |ban| {
        const contents = root.readFileAlloc(io, ban.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP vocabulary check with {s}", .{ ban.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, ban.needle) != null) {
            try appendViolation(gpa, violations, "{s}: contains `{s}` — {s}", .{ ban.path, ban.needle, ban.reason });
        }
    }

    // The driver family must carry the renamed session type / symbol — the
    // positive half of the internal-vocabulary rule (ADR-0079 amendment).
    const driver_header = root.readFileAlloc(io, "include/pancake_host.h", gpa, .limited(4 << 20)) catch return;
    defer gpa.free(driver_header);
    for ([_][]const u8{ "PancakeHostSession", "pancake_host_session_" }) |needle| {
        if (std.mem.indexOf(u8, driver_header, needle) == null) {
            try appendViolation(gpa, violations, "include/pancake_host.h: missing `{s}` — the byte-fed CapTP session family (ADR-0079)", .{needle});
        }
    }

    // Item-2 part 3 positive half: the Zig type / id renames landed.
    const positive = [_]struct { path: []const u8, needle: []const u8, what: []const u8 }{
        .{ .path = "src/driver/core/host.zig", .needle = "pub const HostSession", .what = "the byte-fed CapTP session Zig type (aligns with PancakeHostSession)" },
        .{ .path = "src/ocapn/engine/node.zig", .needle = "pub const PeerId", .what = "the engine's Peer routing id (was ConnId)" },
        .{ .path = "src/ocapn/engine/node.zig", .needle = "pub fn registerPeer", .what = "the Node registers Peers (was registerConn)" },
    };
    for (positive) |p| {
        const contents = root.readFileAlloc(io, p.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP vocabulary positive check with {s}", .{ p.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, p.needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — {s} (ADR-0079)", .{ p.path, p.needle, p.what });
        }
    }
}

/// Product CLI CapTP waits must be finite (ADR-0081). An `.unbounded` budget
/// parks forever on a silent peer — the hang that wedged `cli-test` and left
/// zombie test binaries back when unbounded was a silent default.
pub fn checkCliCaptpDeadlines(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try expectFileContains(io, gpa, root, violations, "cli/ocapn/mod.zig", &.{
        "pub fn sessionOpts()",
        "default_handshake_timeout_ms",
        "default_settle_timeout_ms",
        "HandshakeTimedOut",
        "sessionOpts()",
    });
    try expectFileContains(io, gpa, root, violations, "test/cli/session_cases.zig", &.{
        "sessionOpts()",
        "HandshakeTimedOut",
        ".handshake = .{ .ms = 200 }",
    });
    try expectFileContains(io, gpa, root, violations, "test/cli/captp_cases.zig", &.{
        "cmdListen",
        "cmdCall",
        "publish",
        "greeter",
        "requestStop while accepting",
        "requestStop while serving",
    });
    try expectFileContains(io, gpa, root, violations, "test/cli/all.zig", &.{
        "captp_cases.zig",
    });

    var dir = root.openDir(io, "cli", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "cli/: failed to open for CapTP-deadline check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "cli/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP-deadline check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        var line_no: usize = 1;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| : (line_no += 1) {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "//")) continue;
            // `SessionOptions` has no default budget, so the compiler already
            // refuses an omitted one everywhere. What it cannot refuse is the
            // budget that says forever out loud, which is right for an
            // in-process pair and wrong on a product path and in an example a
            // reader copies.
            if (std.mem.indexOf(u8, line, ".handshake = .unbounded") != null or
                std.mem.indexOf(u8, line, ".settle = .unbounded") != null)
            {
                try appendViolation(gpa, violations, "{s}:{d}: an unbounded CapTP budget parks forever on a silent peer; name a finite `.{{ .ms = N }}` (cli/ has `sessionOpts()`)", .{ path, line_no });
            }
        }
    }
}

/// A teaching surface must not demonstrate the unbounded wait.
///
/// The compiler refuses an omitted budget (`SessionOptions` has no default),
/// and a `.ms` of zero or less times out immediately, so the one spelling left
/// that waits forever is `.unbounded`. `cli/` is already refused it above,
/// because there it is a hang. In an example it is worse than a hang: a reader
/// copies it.
///
/// This asserts the positive — every call that opens a session names a budget
/// — rather than matching the shape of a bad one. A first attempt looked for
/// `, .{})` on the call's own line and so was blind to every real call in the
/// tree, all of which wrap their arguments across lines.
///
/// Blank out every comment, keeping the source's byte offsets so reported line
/// numbers still point at the right place. Zig has no block comments, so this
/// is `//` to end of line, skipping the ones inside a string literal — a locator
/// like `"tcp://host"` is not the start of a comment, and a naive scan that
/// thinks it is truncates the argument list it was meant to read.
fn blankComments(src: []u8) void {
    var i: usize = 0;
    while (i < src.len) {
        switch (src[i]) {
            '"' => {
                i += 1;
                while (i < src.len and src[i] != '"') : (i += 1) {
                    if (src[i] == '\\') i += 1;
                }
                i += 1;
            },
            '\'' => {
                i += 1;
                while (i < src.len and src[i] != '\'') : (i += 1) {
                    if (src[i] == '\\') i += 1;
                }
                i += 1;
            },
            '/' => {
                if (i + 1 < src.len and src[i + 1] == '/') {
                    while (i < src.len and src[i] != '\n') : (i += 1) src[i] = ' ';
                } else i += 1;
            },
            else => i += 1,
        }
    }
}

/// Whether the value expression at the start of `value` is a bounded budget: a
/// positive integer, a `.{ .ms = <positive> }` budget literal, or a named
/// constant resolving to either.
///
/// The whole expression is read, not just its first token. "starts with a
/// nonzero digit" accepts `10_000 - 10_000` and `10_000 * 0`, which are the
/// zero this refuses wearing a disguise, so the digits must run all the way to
/// the delimiter that ends the expression. An identifier is resolved once
/// against the file's own top-level constants: a named, documented budget is
/// the form an example *should* teach, and a check that only accepted literals
/// would push every example toward a magic number. `.unbounded` has no arm
/// here on purpose: it is the value this check exists to refuse.
fn valuePositive(file: []const u8, value_expr: []const u8, allow_name: bool) bool {
    // What may legally follow the value: the end of an argument, of a struct
    // initializer, of a call, or of a declaration.
    const ends = struct {
        fn at(text: []const u8) bool {
            const rest = std.mem.trimStart(u8, text, " \t\r\n");
            return rest.len == 0 or rest[0] == ',' or rest[0] == '}' or rest[0] == ')' or rest[0] == ';';
        }
    }.at;
    const value = std.mem.trimStart(u8, value_expr, " \t\r\n");
    var digits: usize = 0;
    var nonzero = false;
    while (digits < value.len) : (digits += 1) {
        const ch = value[digits];
        if (ch == '_') continue;
        if (!std.ascii.isDigit(ch)) break;
        if (ch != '0') nonzero = true;
    }
    if (digits > 0) {
        if (!nonzero) return false;
        return ends(value[digits..]);
    }

    // The `driver.Budget` literal the buffer-explicit constructors take:
    // `.{ .ms = N }`, bounded exactly when N is.
    if (std.mem.startsWith(u8, value, ".{")) {
        const inner = value[2..];
        const ms = std.mem.indexOf(u8, inner, ".ms") orelse return false;
        const after_ms = std.mem.trimStart(u8, inner[ms + ".ms".len ..], " \t\r\n");
        if (after_ms.len == 0 or after_ms[0] != '=') return false;
        return valuePositive(file, after_ms[1..], allow_name);
    }
    if (!allow_name) return false;

    // An identifier, resolved against `const <name> ... = <literal>;`. One hop
    // only: a constant defined in terms of another constant is past what a
    // grep-shaped check should pretend to evaluate, and it fails closed.
    var name_len: usize = 0;
    while (name_len < value.len and (std.ascii.isAlphanumeric(value[name_len]) or value[name_len] == '_')) name_len += 1;
    if (name_len == 0) return false;
    if (!ends(value[name_len..])) return false;
    const name = value[0..name_len];

    var probe: usize = 0;
    while (std.mem.indexOfPos(u8, file, probe, "const ")) |c| {
        probe = c + "const ".len;
        if (!std.mem.startsWith(u8, file[probe..], name)) continue;
        const after = file[probe + name.len ..];
        if (after.len == 0 or std.ascii.isAlphanumeric(after[0]) or after[0] == '_') continue;
        const eq = std.mem.indexOfScalar(u8, after, '=') orelse continue;
        // Only across the declaration's own type annotation, never past a
        // newline into some later statement.
        if (std.mem.indexOfScalar(u8, after[0..eq], '\n') != null) continue;
        if (valuePositive(file, after[eq + 1 ..], false)) return true;
    }
    return false;
}

/// Whether `args` initializes `field` to a positive value.
///
/// The match must be a field initializer of exactly this name: a field whose
/// name merely ends in the one being looked for is a different field, and
/// accepting it is how a check reports coverage it does not have.
fn initializedPositive(file: []const u8, args: []const u8, field: []const u8) bool {
    var probe: usize = 0;
    while (std.mem.indexOfPos(u8, args, probe, field)) |f| {
        probe = f + field.len;
        // `.handshake`, not `my_handshake` and not a longer name this one is
        // a prefix of.
        if (f == 0 or args[f - 1] != '.') continue;
        if (probe < args.len and (std.ascii.isAlphanumeric(args[probe]) or args[probe] == '_')) continue;
        const after_name = std.mem.trimStart(u8, args[probe..], " \t\r\n");
        if (after_name.len == 0 or after_name[0] != '=') continue;
        if (valuePositive(file, after_name[1..], true)) return true;
    }
    return false;
}

/// Whether the last argument of `args` is a positive value.
///
/// The buffer-explicit constructors take their handshake budget positionally,
/// not as a field, so the field-shaped test above cannot see them at all. They
/// are the openers that most need seeing: `acceptTcp` does not choose who
/// connects to it, so an unbounded budget there is a stranger holding the
/// accept for as long as it likes.
fn lastArgumentPositive(file: []const u8, args: []const u8) bool {
    // `zig fmt` requires a trailing comma once an argument list wraps, so the
    // last comma of a multi-line call is followed by nothing. Trim it, or the
    // check reports a violation the moment an example is reformatted.
    const list = std.mem.trimEnd(u8, args, " \t\r\n,");
    // The last top-level comma, so a nested call's arguments do not split this
    // one.
    var depth: usize = 0;
    var last: ?usize = null;
    for (list, 0..) |ch, i| switch (ch) {
        '(', '[', '{' => depth += 1,
        ')', ']', '}' => depth -|= 1,
        ',' => if (depth == 0) {
            last = i;
        },
        else => {},
    };
    const at = last orelse return false;
    return valuePositive(file, list[at + 1 ..], true);
}

/// The argument list of a call whose opener ends at `at`, found by matching
/// parens. Skips string and character literals, because a `(` inside a locator
/// string would otherwise unbalance the walk and silently widen the result to
/// the rest of the file — where some *other* call's budget could satisfy this
/// one.
fn callArguments(contents: []const u8, at: usize) []const u8 {
    var depth: usize = 1;
    var i = at;
    while (i < contents.len and depth != 0) {
        switch (contents[i]) {
            '"', '\'' => {
                const quote = contents[i];
                i += 1;
                while (i < contents.len and contents[i] != quote) : (i += 1) {
                    if (contents[i] == '\\') i += 1;
                }
                i += 1;
            },
            '(' => {
                depth += 1;
                i += 1;
            },
            ')' => {
                depth -= 1;
                i += 1;
            },
            else => i += 1,
        }
    }
    // Unbalanced. Return nothing rather than the rest of the file: a span that
    // ran to the end would let some other call's budget satisfy this one, which
    // is the check passing for a reason that has nothing to do with the call it
    // was looking at. Empty reads as "no budget named", which is a violation.
    if (depth != 0) return contents[0..0];
    return contents[at..i -| 1];
}

pub fn checkExampleCaptpDeadlines(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // Two shapes, because the surface has two. The owning constructors take a
    // `SessionOptions` with both budgets as fields; the buffer-explicit ones
    // take the handshake budget positionally, and their settle budget is set on
    // the returned session afterwards.
    const positional_openers = [_][]const u8{ "driver.connectTcp(", "driver.acceptTcp(", "driver.connectUri(" };
    var dir = root.openDir(io, "examples/zig", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "examples/zig: failed to open for CapTP-deadline check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "examples/zig/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP-deadline check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        blankComments(contents);
        // The compiler refuses an omitted budget everywhere now, so what is
        // left to hold here is the one that says forever out loud. An example
        // is copied, so it must not be the place a reader learns that spelling.
        {
            var line_no: usize = 1;
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |line| : (line_no += 1) {
                if (std.mem.indexOf(u8, line, ".handshake = .unbounded") != null or
                    std.mem.indexOf(u8, line, ".settle = .unbounded") != null)
                {
                    try appendViolation(gpa, violations, "{s}:{d}: an unbounded CapTP budget waits forever on a silent peer, and a reader copies this line; name a finite `.{{ .ms = N }}`", .{ path, line_no });
                }
            }
        }
        for (positional_openers) |opener| {
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, contents, at, opener)) |hit| {
                at = hit + opener.len;
                const args = callArguments(contents, at);
                if (lastArgumentPositive(contents, args)) continue;
                const line_no = std.mem.count(u8, contents[0..hit], "\n") + 1;
                try appendViolation(gpa, violations, "{s}:{d}: `{s}` opens a session without a bounded handshake budget in its last argument — `.unbounded` waits forever, and a reader copies this line", .{ path, line_no, opener });
            }
            // The settle budget is not an argument of these: it is a field
            // that defaults to `.unbounded` on the session they return, so the
            // compiler forces nothing and an example that never sets it
            // teaches the unbounded wait silently. This is file-scoped on
            // purpose and the message says so — binding an assignment to the
            // session a particular call returned means tracking the binding it
            // was stored in, which is more Zig parsing than a scaffolding
            // check should pretend to do. What it holds is that the file names
            // one at all. `initializedPositive` alone: a field assignment on a
            // session (`session.settle = .{ .ms = 10_000 };`) has the same
            // leading dot as a struct initializer, so it matches, and the
            // value grammar still refuses `.unbounded` and a non-positive
            // `.ms`.
            if (std.mem.indexOf(u8, contents, opener) != null and
                !initializedPositive(contents, contents, "settle"))
            {
                try appendViolation(gpa, violations, "{s}: uses `{s}` and nowhere in the file sets a bounded `settle` budget, so every wait after the handshake waits forever", .{ path, opener });
            }
        }
    }
}

/// Ctrl+C on `ocapn listen` must poll `waitAcceptable` rather than close the
/// listen FD from another thread (Zig Threaded Io panics on that BADF).
pub fn checkCliListenStopWake(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try expectFileContains(io, gpa, root, violations, "cli/operability/signals.zig", &.{
        "accept-after-close",
        "must not close a listen FD",
        "pub const poll_ms",
    });
    try expectFileContains(io, gpa, root, violations, "cli/ocapn/mod.zig", &.{
        "waitAcceptable",
        "serveUntilStop",
        "signals.poll_ms",
    });
    try expectFileContains(io, gpa, root, violations, "src/net/netlayer.zig", &.{
        "waitAcceptable",
    });
    try expectFileContains(io, gpa, root, violations, "test/cli/captp_cases.zig", &.{
        "requestStop while accepting",
        "requestStop while serving",
    });
    // Tombstones: close-from-watcher and CapTP self-dial wake both regress BADF
    // or invent stop-path CapTP cost the poll seat already forbids.
    const tombstones = [_]struct { path: []const u8, needle: []const u8, why: []const u8 }{
        .{ .path = "cli/ocapn/mod.zig", .needle = "Closable", .why = "Closable closed the listen FD from the stop watcher (BADF panic); use waitAcceptable" },
        .{ .path = "cli/ocapn/mod.zig", .needle = "parked_in_accept", .why = "CapTP self-dial wake retired; poll Listener.waitAcceptable against the stop latch" },
        .{ .path = "cli/operability/signals.zig", .needle = "Closable", .why = "Closable name retired; StopWatch is MCP's stdin closer, not listen wake" },
    };
    for (tombstones) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for listen-stop check with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, row.needle) != null) {
            try appendViolation(gpa, violations, "{s}: forbidden needle `{s}` — {s}", .{ row.path, row.needle, row.why });
        }
    }
}

/// CapTP lab chrome/docs must match live keys: listen is argv-only; F1 (not
/// prompt `?`) opens the help modal; no stub search theater; no product-taste
/// names in `cli/repl` module headers.
pub fn checkCaptpLabUxHonesty(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const tombstones = [_]struct { path: []const u8, needle: []const u8, why: []const u8 }{
        .{ .path = "cli/repl/panes.zig", .needle = "dial or listen", .why = "empty-session chrome must invite dial only (listen is argv-only)" },
        .{ .path = "cli/repl/panes.zig", .needle = "F1 / ?", .why = "help modal must not claim prompt ? opens it (F1 does; ? is tip at prompt)" },
        .{ .path = "docs/cli.md", .needle = "dial` / `listen` inside", .why = "lab starts with dial inside; listen stays argv-only" },
        .{ .path = ".agents/skills/pancake-cli/SKILL.md", .needle = "dial/listen inside", .why = "skill session table: dial inside; listen argv-only" },
        .{ .path = "cli/repl/tui.zig", .needle = "Claude Code", .why = "taste as structure, not product names in committed headers" },
        .{ .path = "cli/repl/tui.zig", .needle = "stub — use Ctrl-O", .why = "search stub theater deleted; do not reintroduce" },
        .{ .path = "cli/repl/ecs/intent.zig", .needle = "search_start", .why = "search stub intents deleted until a real search mode exists" },
        .{ .path = "cli/repl/ecs/intent.zig", .needle = "hover_at", .why = "dead hover intent deleted; mouse handles hits inline" },
        .{ .path = "cli/argv.zig", .needle = "ocapn_flags", .why = "pre-tree CapTP argv helpers deleted; tree/registry own parse" },
        .{ .path = "cli/argv.zig", .needle = "peelGlobals", .why = "pre-tree CapTP argv helpers deleted; cmd/mod owns globals" },
        .{ .path = "cli/mcp/mod.zig", .needle = "\"version\":\"0.1.0\"", .why = "MCP serverInfo.version must come from build_options, not a hard-coded literal" },
        .{ .path = "cli/mcp/mod.zig", .needle = "Content-Length", .why = "MCP stdio is NDJSON per the MCP transport spec; LSP Content-Length framing breaks Cursor/Claude" },
        .{ .path = "cli/mcp/mod.zig", .needle = "\"]}}}\"", .why = "tools/list closes with ]}} (array+result+root); an extra brace makes Cursor drop the catalog" },
        .{ .path = "cli/registry.zig", .needle = "if (std.mem.eql(u8, cmd.name, \"listen\")) continue", .why = "use leafVisible; no ad-hoc listen skip lists" },
        .{ .path = "cli/cmd/tree.zig", .needle = "held; not yet on the wire", .why = "rooms-peer --dm ships via directory introduce; help must not claim held" },
        // retire-by: the rooms-peer rename holding stable for a month —
        // retire the bot/rooms-bot rename rows below in that diff.
        .{ .path = "cli/cmd/tree.zig", .needle = ".name = \"bot\"", .why = "rooms presence leaf is rooms-peer, not bot" },
        .{ .path = "cli/cmd/tree.zig", .needle = "Application fronts (bot)", .why = "app short_help names rooms-peer, not bot" },
        .{ .path = "build.zig", .needle = "rooms-bot", .why = "install/run step is rooms-peer" },
        .{ .path = "cli/app/rooms_peer/peer.zig", .needle = "remaining milestone", .why = "DM introduce/tell shipped; do not reintroduce a silent skip" },
        .{ .path = "cli/app/rooms_peer/verbs.zig", .needle = "not-implemented", .why = "reply --dm writes outbox; not a not-implemented stub" },
        .{ .path = "cli/app/rooms_peer/verbs.zig", .needle = "BotFailed", .why = "rooms-peer soft fail is PeerFailed/UsageFailed" },
        .{ .path = "cli/app/rooms_peer/supervise.zig", .needle = "botCliPrefix", .why = "prefix helper is peerCliPrefix" },
        .{ .path = "cli/app/rooms_peer/peer.zig", .needle = "BotState", .why = "daemon state type is PeerState" },
        .{ .path = ".agents/skills/rooms-peer/SKILL.md", .needle = "rooms-bot", .why = "skill vocabulary is rooms-peer" },
        .{ .path = ".agents/skills/rooms-peer/SKILL.md", .needle = "One bot per nick", .why = "skill rules say one peer per nick" },
    };
    for (tombstones) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP lab UX check with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, row.needle) != null) {
            try appendViolation(gpa, violations, "{s}: forbidden needle `{s}` — {s}", .{ row.path, row.needle, row.why });
        }
    }
    try expectFileContains(io, gpa, root, violations, "cli/repl/panes.zig", &.{
        "F1       this help",
        "dial an ocapn:// locator",
    });
    try expectFileContains(io, gpa, root, violations, "cli/registry.zig", &.{
        "leafVisible",
        "flagVisibleMcp",
        "argv_only",
        "mcp_hide",
    });
    try expectFileContains(io, gpa, root, violations, "cli/app/rooms_peer/peer.zig", &.{
        "registerWithDirectory",
        "startIntroduce",
        "offerInboxFor",
    });
}

test "collectCaptpRegistryNames takes Command rows only" {
    const gpa = std.testing.allocator;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    const src =
        \\pub const commands = [_]Command{
        \\    .{
        \\        .name = "listen",
        \\        .help = "Bind",
        \\        .positionals = &[_]Positional{.{ .name = "locator", .help = "uri" }},
        \\    },
        \\    .{
        \\        .name = "dial",
        \\        .help = "Dial",
        \\    },
        \\};
    ;
    try collectCaptpRegistryNames(gpa, src, &names);
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("listen", names.items[0]);
    try std.testing.expectEqualStrings("dial", names.items[1]);
}

test "captpVerbTableIsPartial catches incomplete inventory tables" {
    const names = [_][]const u8{ "listen", "dial", "probe", "call" };
    try std.testing.expect(captpVerbTableIsPartial(
        "| Verb | Role |\n| --- | --- |\n| `listen` | host |\n| `dial` | dial |\n| `probe` | poke |\n",
        &names,
    ));
    try std.testing.expect(!captpVerbTableIsPartial(
        "| Verb | Role |\n| --- | --- |\n| `listen` | host |\n| `dial` | dial |\n| `probe` | poke |\n| `call` | act |\n",
        &names,
    ));
    try std.testing.expect(!captpVerbTableIsPartial(
        "| Front | Shape |\n| --- | --- |\n| argv | `call` / `tell` / `fetch` / `probe` |\n",
        &names,
    ));
    try std.testing.expect(!captpVerbTableIsPartial("defer to `pancake help`", &names));
}

test "mentionsVerbInCode matches bare, call, and receiver-method phrasings" {
    // Bare token, as the README and vision write it.
    try std.testing.expect(mentionsVerbInCode("the `connect` verb dials", "connect"));
    // As a call with arguments, as bindings/README's table writes it.
    try std.testing.expect(mentionsVerbInCode("| `listen(host, port)` | accept |", "listen"));
    // As a method on a receiver, the other bindings/README phrasing.
    try std.testing.expect(mentionsVerbInCode("call `conn.tell(ref, verb, args)`", "tell"));
    try std.testing.expect(mentionsVerbInCode("`conn.serve()` runs the loop", "serve"));
    // Absent: prose mention outside code is not enough, and a different verb
    // inside code does not satisfy the missing one.
    try std.testing.expect(!mentionsVerbInCode("you can tell it to stop", "tell"));
    try std.testing.expect(!mentionsVerbInCode("only `conn.close()` here", "serve"));
}

/// Hold the CLI to one JSON string escaper.
///
/// There were two, written a minute apart by two changes that each thought they
/// were the only one. When the first was taught to handle bytes that are not
/// text, the second kept writing unparseable JSON — and the second was the one
/// recording what room members send, which is the least trusted input the CLI
/// has. A duplicate escaper does not announce itself: both compile, both look
/// right, and they disagree only on input nobody tests by hand.
/// A `pub const X` in the driver root must not name something other than
/// `driver_core.X` when the core also declares `X`.
///
/// Every other re-export in that root (`Served`, `Error`, `Settled`,
/// `Identity`, `Capability`) forwards the core's type, so a reader learns the
/// rule "driver.X is driver_core.X" and then meets one that is not. The
/// owning face was `driver.Host` shadowing `driver_core.Host` until ADR-0090's
/// follow-up renamed it `PollHost`; nothing but this check stops the next one.
/// Textual on purpose: the two roots are separate modules, so a reflection
/// check would have to import both into the scaffolding build.
pub fn checkDriverRootShadow(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const driver_src = root.readFileAlloc(io, "src/driver/mod.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/driver/mod.zig: failed to read for the shadow check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(driver_src);
    const core_src = root.readFileAlloc(io, "src/driver/core/mod.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/driver/core/mod.zig: failed to read for the shadow check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(core_src);

    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, driver_src, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const decl = "pub const ";
        if (!std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), decl)) continue;
        const after = std.mem.trimStart(u8, line, " \t")[decl.len..];
        const eq = std.mem.indexOfScalar(u8, after, '=') orelse continue;
        const name = std.mem.trim(u8, after[0..eq], " \t");
        if (name.len == 0) continue;
        const value = std.mem.trim(u8, after[eq + 1 ..], " \t;");
        // Does the core declare this name too?
        var core_decl_buf: [128]u8 = undefined;
        if (name.len + decl.len > core_decl_buf.len) continue;
        const core_decl = std.fmt.bufPrint(&core_decl_buf, "pub const {s} =", .{name}) catch continue;
        if (std.mem.indexOf(u8, core_src, core_decl) == null) continue;
        // It does. The driver root's value must forward it.
        var want_buf: [160]u8 = undefined;
        const want = std.fmt.bufPrint(&want_buf, "driver_core.{s}", .{name}) catch continue;
        if (std.mem.eql(u8, value, want)) continue;
        try appendViolation(gpa, violations, "src/driver/mod.zig:{d}: `pub const {s}` shadows `driver_core.{s}` with `{s}`; every other re-export in this root forwards the core's type, so a name that does not must not reuse the core's spelling (ADR-0090 renamed the owning face `PollHost` for this reason)", .{ line_no, name, name, value });
    }
}

pub fn checkSingleJsonEscaper(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const definition = "fn writeJsonString(";
    var found: std.ArrayList([]const u8) = .empty;
    defer {
        for (found.items) |path| gpa.free(path);
        found.deinit(gpa);
    }

    var dir = root.openDir(io, "cli", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "cli/: cannot open it to check the JSON escaper ({s})", .{@errorName(err)});
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const source = dir.readFileAlloc(io, entry.path, gpa, .limited(4 << 20)) catch continue;
        defer gpa.free(source);
        if (std.mem.indexOf(u8, source, definition) == null) continue;
        try found.append(gpa, try gpa.dupe(u8, entry.path));
    }

    if (found.items.len > 1) {
        for (found.items) |path| {
            try appendViolation(gpa, violations, "cli/{s}: defines `writeJsonString`, and so does another file under cli/. Keep one and alias it, so a fix to escaping reaches every caller.", .{path});
        }
    }
}

test "initializedPositive accepts only a bounded budget that closes its own initializer" {
    // The budget-literal shape every real call in the tree uses now.
    try std.testing.expect(initializedPositive("", ".{ .handshake = .{ .ms = 10_000 } }", "handshake"));
    try std.testing.expect(initializedPositive("", ".{\n    .settle = .{ .ms = 5000 },\n}", "settle"));

    // The unbounded spelling, and the expired zero, however spelled.
    try std.testing.expect(!initializedPositive("", ".{ .handshake = .unbounded }", "handshake"));
    try std.testing.expect(!initializedPositive("", ".{ .handshake = .{ .ms = 0 } }", "handshake"));
    try std.testing.expect(!initializedPositive("", ".{ .handshake = .{ .ms = 0_000 } }", "handshake"));
    try std.testing.expect(!initializedPositive("", ".{}", "handshake"));

    // A positive-looking first token that is not the value. Reading the digits
    // and stopping is how a check convinces itself an unbounded wait is bounded.
    try std.testing.expect(!initializedPositive("", ".{ .handshake = .{ .ms = 10_000 - 10_000 } }", "handshake"));
    try std.testing.expect(!initializedPositive("", ".{ .handshake = .{ .ms = 10 * factor } }", "handshake"));

    // A different field whose name merely ends in this one.
    try std.testing.expect(!initializedPositive("", ".{ .my_handshake = .{ .ms = 10_000 } }", "handshake"));
    try std.testing.expect(!initializedPositive("", ".{ .handshake_hint = .{ .ms = 10_000 } }", "handshake"));
}

test "lastArgumentPositive survives the trailing comma zig fmt requires" {
    try std.testing.expect(lastArgumentPositive("", "a, b, .{ .ms = 10_000 }"));
    // The same call, wrapped, which is how every real one is written.
    try std.testing.expect(lastArgumentPositive("", "\n    a,\n    b,\n    .{ .ms = 10_000 },\n"));
    try std.testing.expect(!lastArgumentPositive("", "\n    a,\n    b,\n    .unbounded,\n"));
    try std.testing.expect(!lastArgumentPositive("", "\n    a,\n    b,\n    .{ .ms = 0 },\n"));
    // A named budget resolved against the file's own constants, the form an
    // example should teach.
    const file = "const handshake_budget: driver.Budget = .{ .ms = 10_000 };";
    try std.testing.expect(lastArgumentPositive(file, "a, b, handshake_budget"));
    const unbounded_file = "const handshake_budget: driver.Budget = .unbounded;";
    try std.testing.expect(!lastArgumentPositive(unbounded_file, "a, b, handshake_budget"));
}

test "callArguments fails closed on an unbalanced call" {
    // The opener is at index 8; the call never closes. Returning the rest of
    // the file here is how a budget belonging to some later call comes to
    // satisfy this one.
    const src = "x = open(a, b\n.handshake = .{ .ms = 5 },\n";
    try std.testing.expectEqual(@as(usize, 0), callArguments(src, 9).len);
    const closed = "x = open(a, .handshake = .{ .ms = 5 })";
    try std.testing.expect(callArguments(closed, 9).len > 0);
}

test "a settle budget assigned on the session is read, and an unbounded one refused" {
    const positive = "var s = driver.connectTcp(a, b, .{ .ms = 9 });\ns.settle = .{ .ms = 10_000 };";
    try std.testing.expect(initializedPositive(positive, positive, "settle"));
    const unbounded = "var s = driver.connectTcp(a, b, .{ .ms = 9 });\ns.settle = .unbounded;";
    try std.testing.expect(!initializedPositive(unbounded, unbounded, "settle"));
}

test "blankComments erases comments without mistaking a locator for one" {
    var src = "a // gone\n.handshake = .{ .ms = 1 },".*;
    blankComments(&src);
    try std.testing.expect(std.mem.indexOf(u8, &src, "gone") == null);
    try std.testing.expect(initializedPositive(&src, &src, "handshake"));

    // The `//` inside a string is not a comment: treating it as one would blank
    // the rest of the argument list, and the budget in it would read as absent.
    var uri = "\"tcp://host\", .{ .handshake = .{ .ms = 9 } }".*;
    blankComments(&uri);
    try std.testing.expect(initializedPositive(&uri, &uri, "handshake"));

    // And a budget that only appears in a comment is not a budget.
    var commented = "// .handshake = .{ .ms = 9 }\n.{}".*;
    blankComments(&commented);
    try std.testing.expect(!initializedPositive(&commented, &commented, "handshake"));
}

/// One rooms peer's spelling of the fleet's wire profile.
///
/// A room is a closed fleet of pancake peers, so it runs on pancake's own
/// profile rather than the interop floor. That profile is one fact, and five
/// languages each have to spell it: a peer that names only half of it, or
/// names last week's half, opens a session every other member refuses. The
/// failure is a live `CaptpVersionMismatch` in a step that has to bring five
/// runtimes up before it can report anything, so the spelling is checked here
/// instead.
const RoomsProfileSpelling = struct {
    path: []const u8,
    /// How this language writes the Cap'n Proto codec and the Syrup floor.
    capnp: []const u8,
    syrup: []const u8,
    /// How it writes the `pancake-next` version and the 1.0 floor.
    next: []const u8,
    v1_0: []const u8,
};

const rooms_profile_authority = "apps/rooms/lib/protocol.ts";

const rooms_profile_spellings = [_]RoomsProfileSpelling{
    .{
        .path = "apps/rooms/lib/profile.zig",
        .capnp = ".capnp",
        .syrup = ".syrup",
        .next = ".next",
        .v1_0 = ".v1_0",
    },
    .{
        .path = "apps/rooms/clients/python/room_client.py",
        .capnp = "\"capnp\"",
        .syrup = "\"syrup\"",
        .next = "\"next\"",
        .v1_0 = "\"v1_0\"",
    },
    .{
        .path = "apps/rooms/clients/racket/room-client.rkt",
        .capnp = "'capnp",
        .syrup = "'syrup",
        .next = "'next",
        .v1_0 = "'v1_0",
    },
    .{
        .path = "apps/rooms/clients/rust/room.rs",
        .capnp = "Codec::Capnp",
        .syrup = "Codec::Syrup",
        .next = "CaptpVersion::Next",
        .v1_0 = "CaptpVersion::V1_0",
    },
};

/// Every rooms peer offers the same CapTP version and codec.
///
/// `apps/rooms/lib/protocol.ts` decides; the four sibling spellings follow.
/// The check is parity rather than a pinned constant, so moving the fleet to a
/// different profile stays a one-line edit in the authority — it just cannot
/// be a one-line edit, because this fails until the others move with it.
pub fn checkRoomsWireProfile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const authority = root.readFileAlloc(io, rooms_profile_authority, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read the rooms wire-profile authority with {s}", .{ rooms_profile_authority, @errorName(err) });
        return;
    };
    defer gpa.free(authority);

    const wants_capnp = std.mem.indexOf(u8, authority, "CODEC = \"capnp\"") != null;
    const wants_next = std.mem.indexOf(u8, authority, "CAPTP_VERSION = \"next\"") != null;
    if (!wants_capnp and std.mem.indexOf(u8, authority, "CODEC = \"syrup\"") == null) {
        try appendViolation(gpa, violations, "{s}: names no `CODEC` the sibling peers can follow; the fleet's codec is decided here", .{rooms_profile_authority});
        return;
    }
    if (!wants_next and std.mem.indexOf(u8, authority, "CAPTP_VERSION = \"v1_0\"") == null) {
        try appendViolation(gpa, violations, "{s}: names no `CAPTP_VERSION` the sibling peers can follow; the fleet's CapTP version is decided here", .{rooms_profile_authority});
        return;
    }

    for (rooms_profile_spellings) |peer| {
        const source = root.readFileAlloc(io, peer.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for the rooms wire-profile check with {s}", .{ peer.path, @errorName(err) });
            continue;
        };
        defer gpa.free(source);
        // Raw source, not comment-stripped: these are language literals
        // (`Codec::Syrup`, `'syrup`, `.v1_0`), and prose that describes the
        // profile has no reason to spell one. Four languages' comment syntaxes
        // would need four strippers to buy nothing.
        const code = source;

        const want_codec = if (wants_capnp) peer.capnp else peer.syrup;
        const wrong_codec = if (wants_capnp) peer.syrup else peer.capnp;
        if (std.mem.indexOf(u8, code, want_codec) == null) {
            try appendViolation(gpa, violations, "{s}: does not name `{s}`, the codec {s} decides for every rooms peer; a peer on the other codec cannot open a session with the fleet", .{ peer.path, want_codec, rooms_profile_authority });
        }
        if (std.mem.indexOf(u8, code, wrong_codec) != null) {
            try appendViolation(gpa, violations, "{s}: still names `{s}` after {s} moved the fleet's codec; the two spellings have drifted apart", .{ peer.path, wrong_codec, rooms_profile_authority });
        }

        const want_version = if (wants_next) peer.next else peer.v1_0;
        const wrong_version = if (wants_next) peer.v1_0 else peer.next;
        if (std.mem.indexOf(u8, code, want_version) == null) {
            try appendViolation(gpa, violations, "{s}: does not name `{s}`, the CapTP version {s} decides for every rooms peer; the codec alone is half a profile and the handshake refuses on the other half", .{ peer.path, want_version, rooms_profile_authority });
        }
        if (std.mem.indexOf(u8, code, wrong_version) != null) {
            try appendViolation(gpa, violations, "{s}: still names `{s}` after {s} moved the fleet's CapTP version; the two spellings have drifted apart", .{ peer.path, wrong_version, rooms_profile_authority });
        }
    }
}

/// The directories under `apps/rooms` whose TypeScript mints peers.
const rooms_peer_dirs = [_][]const u8{
    "apps/rooms/demos",
    "apps/rooms/test",
    "apps/rooms/server",
    "apps/rooms/web",
    "apps/rooms/web/ui",
    "apps/rooms/lib",
};

/// Every rooms peer is minted through `lib/locator.ts`.
///
/// A peer comes into being by dialing or by being dialed, and both halves have
/// to wear the fleet's profile. `new Host()` and `listen(host, port)` each hand
/// back the v1.0 Syrup floor instead, and the session that peer opens is then
/// refused as a malformed frame — a message that points at the codec rather
/// than at the line that minted the host. That mistake was made four times in
/// one afternoon across demos, tests, and the server, which is what a
/// convention rather than a check buys. `roomsHost` and `roomsListen` are the
/// two front doors; a peer that genuinely wants the floor (proving pancake
/// meets an interop partner there) says so on the line with
/// `rooms-profile-exempt:` and a reason.
pub fn checkRoomsPeerMinting(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const authority = "apps/rooms/lib/locator.ts";
    for (rooms_peer_dirs) |dir_path| {
        var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = dir.iterate();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".ts") and !std.mem.endsWith(u8, entry.name, ".tsx")) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.name });
            defer gpa.free(path);
            // The authority is where both front doors are built, so it is the
            // one file allowed to reach the raw constructors.
            if (std.mem.eql(u8, path, authority)) continue;
            const source = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch continue;
            defer gpa.free(source);

            var line_no: usize = 0;
            var lines = std.mem.splitScalar(u8, source, '\n');
            while (lines.next()) |line| {
                line_no += 1;
                if (std.mem.indexOf(u8, line, "rooms-profile-exempt:") != null) continue;
                // `listenIroh(` / `listenKeyedTcp(` / `roomsListen(` do not
                // contain this token, so the match is the bare function alone.
                if (std.mem.indexOf(u8, line, "new Host(") != null) {
                    try appendViolation(gpa, violations, "{s}:{d}: mints a peer with `new Host(` — a default Host speaks the v1.0 Syrup floor and the room refuses its frames; mint it through `roomsHost` in {s}", .{ path, line_no, authority });
                }
                // A qualified `listen` belongs to something else — `Deno.listen`
                // opens a socket, and a socket has no CapTP profile to get
                // wrong. Only the bare call mints a pancake peer.
                const bare_listen = if (std.mem.indexOf(u8, line, "listen(")) |at|
                    at == 0 or line[at - 1] != '.'
                else
                    false;
                if (bare_listen and std.mem.indexOf(u8, line, "function listen(") == null) {
                    try appendViolation(gpa, violations, "{s}:{d}: accepts peers with the bare `listen(` — its default host speaks the v1.0 Syrup floor; accept through `roomsListen` in {s}", .{ path, line_no, authority });
                }
            }
        }
    }
}
