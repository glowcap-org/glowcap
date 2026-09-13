//! Durable-pin writers: every writer of a pinned constant names the one
//! authority it mirrors.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;

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
/// field name `durable_pin` may appear only in the aggregate that declares it
/// and the identity owner that implements its verbs. That covers a field
/// write, a flag write inside the pin, and a read that would let a caller
/// re-derive a verdict of its own — which the
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
        /// The `glowcap_host_*` prototype a foreign realizer speaks through,
        /// checked present in `include/glowcap_host.h` — the actual public
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
            .declared_in = "src/ocapn/engine/peer/identity.zig",
            .speakers = &.{
                "src/net/transport/iroh/stream.zig",
                "src/driver/bridge.zig",
                "src/driver/host_runtime/connections.zig",
                "src/driver/host_runtime/opens.zig",
                "src/driver/host_runtime/resident_pump.zig",
                "src/driver/core/host/session.zig",
                "src/driver/core/host/session/ingress.zig",
                "src/c_abi/host/session.zig",
                "interop/webrtc_common.zig",
            },
            .standing = "it realized the connection, or it carries the testimony of an embedder that did",
            .foreign = .{ .entry = "glowcap_host_session_bind_verified_channel_key" },
        },
        .{
            .call = "durable_pin",
            .declaration = "durable_pin: DurablePin = .{}",
            .declared_in = "src/ocapn/engine/mod.zig",
            .speakers = &.{
                "src/ocapn/engine/mod.zig",
                "src/ocapn/engine/peer/identity.zig",
            },
            .standing = "the aggregate declares the pin and the identity module owns all its verbs, so no other reader or writer can re-derive provenance",
            .foreign = .{ .none_because = "it is the state the verbs write, not a fact anyone states; C reads the verdict through glowcap_host_session_partner_identity" },
        },
    };
    const roots = [_][]const u8{ "src", "cli", "interop", "apps", "examples", "bench", "bindings", "tools" };
    // This file spells the needles it searches for, so it would otherwise
    // report itself. Naming the exemption is the honest version of that.
    const this_check = "tools/check/source_check/captp_product/pins.zig";

    // A rename that emptied a speaker list would leave the rule holding
    // nothing, which is the failure mode this check exists to prevent. So both
    // halves are confirmed present rather than assumed: the declaration, and
    // one call per speaker.
    const public_header = "include/glowcap_host.h";
    const header_source = root.readFileAlloc(io, public_header, gpa, .limited(4 << 20)) catch null;
    defer if (header_source) |source| gpa.free(source);

    for (verbs) |verb| {
        const declaring_source = root.readFileAlloc(io, verb.declared_in, gpa, .limited(4 << 20)) catch null;
        defer if (declaring_source) |source| gpa.free(source);
        if (declaring_source == null or std.mem.indexOf(u8, declaring_source.?, verb.declaration) == null) {
            try appendViolation(
                gpa,
                violations,
                "{s}: missing `{s}`. The ADR-0105 durable-pin verb moved or was renamed, so update `checkDurablePinWriters` in tools/check/source_check/captp_product/pins.zig with it",
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
                "{s}: listed as the only caller of `{s}` but never calls it. Either it stopped being one, or the list in tools/check/source_check/captp_product/pins.zig is stale",
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
                    "{s}: no `{s}`, so a realizer outside this tree cannot state what `{s}` states. A binding owns its own sockets and proves its own connections; leaving it mute means every session it hosts is weighed on what the partner volunteered. Publish the entry point, or record in `checkDurablePinWriters` in tools/check/source_check/captp_product/pins.zig why no embedder can hold this fact",
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
            const contents = root.readFileAlloc(io, entry.name, gpa, .limited(4 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: cannot be read for the pin-parity check ({s})", .{ entry.name, @errorName(err) });
                continue;
            };
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

        var walker = try dir.walkSelectively(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) {
                try util.enterSourceDirectory(io, gpa, &walker, tree, entry);
                continue;
            }
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
            // Vendored trees carry no glowcap rule; skipping by name keeps the
            // walk from reading a dependency's sources.
            if (std.mem.indexOf(u8, entry.path, "node_modules/") != null) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ tree, entry.path });
            defer gpa.free(path);
            if (std.mem.eql(u8, path, this_check)) continue;
            const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: cannot be read for the pin-parity check ({s})", .{ path, @errorName(err) });
                continue;
            };
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
                    "{s}: names `{s}`, but that fact is only one layer's to state (ADR-0105), and that layer is the one where {s}. Either this file has that standing and belongs in `verbs` in tools/check/source_check/captp_product/pins.zig, or it should be naming the identity it dialed instead (`demandPartnerDurableKey`), or reading through `demandedPartnerKey` / `verifiedChannelKey` / `partnerDurableProvenance`.",
                    .{ path, verb.call, verb.standing },
                );
            }
        }
    }
}
