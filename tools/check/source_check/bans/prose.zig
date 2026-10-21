//! Ban rows: prerelease prose, the human doc voice needles, and the diagram
//! wire vocabulary.

const bans = @import("../bans.zig");
const Ban = bans.Ban;
const Where = bans.Where;

/// High-precision transition phrases forbidden by the prerelease rule
/// from first-read surfaces (README.md, AGENTS.md, CONTRIBUTING.md, and every
/// top-level docs/*.md), case-insensitively. Temporal narration is checked
/// separately by static_docs, including its reasoned inline exceptions.
pub const prerelease_prose: []const Ban = prerelease_rows: {
    const phrases = [_][]const u8{ "renamed from", "pre-1.0", "pre-publication" };
    const scopes = [_]Where{
        .{ .files = &.{ "README.md", "AGENTS.md", "CONTRIBUTING.md" } },
        .{ .tree = .{ .dir = "docs", .suffixes = &.{".md"}, .recursive = false } },
    };
    var rows: []const Ban = &.{};
    for (scopes) |scope| {
        for (phrases) |phrase| {
            rows = rows ++ &[_]Ban{.{
                .where = scope,
                .kind = .forbid,
                .needles = &.{phrase},
                .insensitive = true,
                .check = "prerelease-prose",
                .why = "first-read surfaces describe the current shape, not its migration history (prerelease rule)",
            }};
        }
    }
    break :prerelease_rows rows;
};

/// Human first-read docs stay speech for people (doc-voice). ADRs and `.agents/**` are out of scope.
pub const human_doc_voice: []const Ban = voice_rows: {
    const phrases = [_]struct { needle: []const u8, why: []const u8 }{
        .{ .needle = "deliberately boring", .why = "self-awarded praise; state the surface plainly (doc-voice)" },
        .{ .needle = "boring on purpose", .why = "self-awarded praise; state the surface plainly (doc-voice)" },
        .{ .needle = "next audit", .why = "executor framing; write for a human re-read (doc-voice)" },
        .{ .needle = "honest exception", .why = "self-awarded praise on the project's own carve-out; name the exception plainly (doc-voice)" },
        .{ .needle = "honest scope", .why = "self-awarded praise; state the scope plainly (doc-voice)" },
        .{ .needle = "worth stating", .why = "throat-clearing; just state it (doc-voice)" },
        .{ .needle = "deliberately not", .why = "intent-adverb hedge; state the reason or drop the adverb (doc-voice)" },
        .{ .needle = "intentionally owns", .why = "intent-adverb hedge; state who owns it (doc-voice)" },
        // Insider words with no legitimate identifier spelling on these paths.
        .{ .needle = "hermetic", .why = "insider word; write \"in-tree\" or \"no network or external services\" (doc-voice)" },
        .{ .needle = "pre-1.0", .why = "prerelease: state the present boundary, not the transition producing it" },
        .{ .needle = "pre-publication", .why = "prerelease: state the present boundary, not the transition producing it" },
        .{ .needle = "This page is not", .why = "contrast-first opener; lead with what the page is (doc-voice)" },
        .{ .needle = "colour", .why = "American English on human first-read pages (doc-voice); write color" },
        .{ .needle = "recognise", .why = "American English on human first-read pages (doc-voice); write recognize" },
        .{ .needle = "behaviour", .why = "American English on human first-read pages (doc-voice); write behavior" },
    };
    var rows: []const Ban = &.{};
    for (bans.human_doc_voice_scopes) |scope| {
        for (phrases) |phrase| {
            rows = rows ++ &[_]Ban{.{
                .where = scope.where,
                .kind = .forbid,
                .needles = &.{phrase.needle},
                .insensitive = true,
                .on_missing = scope.on_missing,
                .check = "human-doc-voice",
                .why = phrase.why,
            }};
        }
        if (scope.ban_agents_links) {
            rows = rows ++ &[_]Ban{.{
                .where = scope.where,
                .kind = .forbid,
                .needles = &.{".agents/"},
                .on_missing = scope.on_missing,
                .check = "human-doc-voice",
                .why = "agent scaffolding stays under `.agents/**`; human docs state the rule in speech (doc-voice)",
            }};
        }
    }
    break :voice_rows rows;
};

/// Always-loaded scaffolding and first-read pages stay in protocol
/// vocabulary: untrusted inbound, peer-supplied, partner-chosen, malformed.
pub const inbound_vocabulary: []const Ban = inbound_rows: {
    const phrases = [_]struct { needle: []const u8, why: []const u8 }{
        .{ .needle = "attack", .why = "inbound vocabulary: write untrusted, peer-supplied, inject, or refuse (doc-voice)" },
        .{ .needle = "malicious", .why = "inbound vocabulary: write untrusted or uncooperative (doc-voice)" },
        .{ .needle = "hostile", .why = "inbound vocabulary: write untrusted, malformed, or uncooperative (doc-voice)" },
    };
    const scopes = [_]Where{
        .{ .file = "AGENTS.md" },
        .{ .file = "SECURITY.md" },
        .{ .tree = .{ .dir = ".agents", .suffixes = &.{".md"} } },
        .{ .tree = .{ .dir = "docs", .suffixes = &.{".md"}, .recursive = false } },
        .{ .tree = .{ .dir = "site/content", .suffixes = &.{".smd"} } },
    };
    var rows: []const Ban = &.{};
    for (scopes) |scope| {
        for (phrases) |phrase| {
            rows = rows ++ &[_]Ban{.{
                .where = scope,
                .kind = .forbid,
                .needles = &.{phrase.needle},
                .insensitive = true,
                .check = "inbound-vocabulary",
                .why = phrase.why,
            }};
        }
    }
    break :inbound_rows rows;
};

/// Diagram wire vocabulary: an op's target ("to ...") is a `desc:export` or
/// `desc:answer`: the spec's to-desc grammar. The import-side descriptors
/// introduce references. They are never a delivery target. The wrong spelling
/// reads plausibly and survived review once, so the gate holds it.
pub const diagram_wire_vocabulary: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "docs/protocol-diagrams", .suffixes = &.{".md"} } },
        .kind = .forbid,
        .needles = &.{"to desc:import-object"},
        .insensitive = true,
        .check = "diagram-wire-vocabulary",
        .why = "a deliver target is desc:export or desc:answer; desc:import-object only introduces (CapTP Specification, op:deliver to-desc)",
    },
    .{
        .where = .{ .tree = .{ .dir = "docs/protocol-diagrams", .suffixes = &.{".md"} } },
        .kind = .forbid,
        .needles = &.{"to desc:import-promise"},
        .insensitive = true,
        .check = "diagram-wire-vocabulary",
        .why = "a deliver target is desc:export or desc:answer; desc:import-promise only introduces (CapTP Specification, op:deliver to-desc)",
    },
};
