---
id: ADR-NNNN
status: proposed
date: YYYY-MM-DD
tags: []
decision: "<one-line statement of the decision>"
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-NNNN <Title>

## Context

<What forced the decision? Which boundary, codec, vocabulary term, or principle
does it sit on? Keep terse. Name which
[First Principles](../../../AGENTS.md#first-principles) the decision engages,
settles, relaxes, or clarifies. Cite OCapN behavior, Goblins fixtures, or Zig
scenarios as evidence; do not cite Rust implementation as the oracle.>

## Decision

<The settled choice, in one paragraph. Mirrors the `decision:` frontmatter line;
expanded with the why-this-and-not-the-alternatives summary. Cite the Zig
modules that own it (`src/...`).>

## Scope (what this does not decide)

<Explicitly name what stays unimplemented or deferred. State the present
boundary ("X is not implemented"), not a roadmap.>

## Alternatives Considered

- **Option A**: <one line>. Rejected because <one line>.
- **Option B**: <one line>. Rejected because <one line>.

## Consequences

<What changes downstream in the Zig tree? Which modules, tests, fixtures, or
arch-gate rules does this create or constrain?>

## Forward compatibility

<Optional. Use when the decision shapes a future wire-profile bump or a reserved
seam (e.g. the Cap'n Proto codec slot) downstream contributors must plan
against. Omit if self-contained.>

## Notes

<Optional. Cross-references to other ADRs only.>
