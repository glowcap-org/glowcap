//! Ban rows: prerelease prose, the human doc voice needles, and the diagram
//! wire vocabulary.

const bans = @import("../bans.zig");
const Ban = bans.Ban;
const Where = bans.Where;

/// High-precision transition phrases forbidden by the prerelease rule
/// from first-read surfaces (README.md, AGENTS.md, CONTRIBUTING.md, and every
/// top-level docs/*.md), case-insensitively. Softer tells ("previously",
/// "originally") have honest uses, so they stay governed by the prose rule
/// alone.
pub const prerelease_prose: []const Ban = prerelease_rows: {
    const phrases = [_][]const u8{ "formerly", "renamed from", "pre-1.0", "pre-publication" };
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
        .{ .needle = "CapTP sticky note", .why = "CapTP vocabulary cheat-sheets live in the architecture agent rule, not human docs (doc-voice)" },
        .{ .needle = "Meta scaffolding", .why = "agent scaffolding vocabulary belongs under `.agents/`, not human inventory (doc-voice)" },
        .{ .needle = "deliberately boring", .why = "self-awarded praise; state the surface plainly (doc-voice)" },
        .{ .needle = "boring on purpose", .why = "self-awarded praise; state the surface plainly (doc-voice)" },
        .{ .needle = "next audit", .why = "executor framing; write for a human re-read (doc-voice)" },
        .{ .needle = "honest exception", .why = "self-awarded praise on the project's own carve-out; name the exception plainly (doc-voice)" },
        .{ .needle = "honest scope", .why = "self-awarded praise; state the scope plainly (doc-voice)" },
        .{ .needle = "worth stating", .why = "throat-clearing; just state it (doc-voice)" },
        .{ .needle = "deliberately not", .why = "intent-adverb hedge; state the reason or drop the adverb (doc-voice)" },
        .{ .needle = "tcp tab is the copy-paste first call", .why = "testing-only tcp does not occupy a first-call lead (doc-voice first-impression)" },
        .{ .needle = "only the `pancake-next` profile speaks it", .why = "op:untag is accepted on 1.0; pancake sends it only when the partner advertises the feature (shipped.md)" },
        .{ .needle = "takes no part", .why = "theatrical restatement; say who does what (doc-voice)" },
        .{ .needle = "visible boundary", .why = "scaffold leftover; name the fact in speech (doc-voice)" },
        .{ .needle = "listen-oriented", .why = "scaffold leftover; write the ordinary path (doc-voice)" },
        .{ .needle = "before the mechanism existed", .why = "prerelease transition narration; describe present behavior (doc-voice)" },
        .{ .needle = "intentionally owns", .why = "intent-adverb hedge; state who owns it (doc-voice)" },
        // Insider words with no legitimate identifier spelling on these paths.
        .{ .needle = "living-state", .why = "insider word; write \"docs kept in step with today's code\" (doc-voice)" },
        .{ .needle = "hermetic", .why = "insider word; write \"in-tree\" or \"no network or external services\" (doc-voice)" },
        .{ .needle = "pre-1.0", .why = "prerelease: state the present boundary, not the transition producing it" },
        .{ .needle = "pre-publication", .why = "prerelease: state the present boundary, not the transition producing it" },
        .{ .needle = "This page is not", .why = "contrast-first opener; lead with what the page is (doc-voice)" },
        .{ .needle = "stands behind what lands", .why = "overclaim of personal audit; landings say the maintainer is answerable (doc-voice, PROVENANCE.md)" },
        .{ .needle = "best networking library", .why = "destination ambition is the work's shape, not a first-read slogan (project-values)" },
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

/// Diagram wire vocabulary: an op's target ("to ...") is a `desc:export` or
/// `desc:answer` — the spec's to-desc grammar. The import-side descriptors
/// introduce references; they are never a delivery target. The wrong spelling
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
