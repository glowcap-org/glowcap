# Documentation audit — stage one of the docs overhaul

Status: historical snapshot. This file records the state of every documentation
surface on 2026-06-11, as the first stage of a three-stage documentation
overhaul. It proposes actions; it does not perform them. Once the findings here
are acted on (or declined), this file is a record of why, not a description of
the tree.

Method: every authored Markdown file was read (90 files in scope after
excluding vendored `*/upstream/` trees and ignored `.local/`), every relative
link was mechanically resolved (474 targets), the incoming-link graph was
built, the `//!` headers of all 76 files under `src/` were checked, the public
doc comments on `Peer`, `Vat`, and `Connection` were assessed, and
`include/pancake.h` and every `b.step` description in `build.zig` were read.
The baseline `zig build check` was green before and during the audit.

## The headline

The repository's documentation is unusually honest — the audit found **zero
broken relative links, zero outright contradictions, and zero stale build-step
claims** across all 90 files. The `meta-check` gate is visibly doing its job.
The problems are different in kind: the README has grown into a reference
manual wearing a front door's clothes, the same load-bearing sentences are
maintained by hand in three or four places, the conceptual on-ramp for a
newcomer does not exist at all, and the living-state registry claims less than
the gate enforces while the diagram corpus claims more than the registry
records.

## Question 1 — Where is the same information stated more than once, and has it drifted?

The short answer: the copies have **not** drifted — yet — but only because the
project has been paying a manual synchronization tax that the stage-two
architecture should retire.

**The wire-path allocation budget** ("a steady-state deliver to a live export
costs exactly one heap allocation, the owned-frame copy the event model
requires") appears nearly word-for-word in `docs/vision.md:42-43`,
`docs/architecture.md:195-203`, and `docs/ladder.md:57-59`, each citing
`test/engine/alloc_budget_test.zig`. Three identical copies is intentional
consistency today and three-way drift tomorrow. One of these is the home; the
other two should become sentences with links.

**The 500k-connection target** appears in `README.md:543`,
`docs/vision.md:28-30`, and seven places in `docs/ladder.md`, with the
arithmetic (2 KiB × 500,000 sessions) living in the ladder. All aligned, all
careful to call it a budget rather than an achievement. Same cure: the ladder
owns the arithmetic, everyone else points.

**The build-step catalog** exists in four sizes: `.agents/rules/cli.md` is the
authoritative 33-step list, `README.md:547-567` shows ~18 steps,
`CONTRIBUTING.md:62-76` shows ~10, and `bindings/README.md` excerpts the
binding-relevant pair. Every documented step exists in `build.zig` (verified
against the `b.step` definitions, including the dynamically generated
per-language dogfood and interop steps). The one gap: the README's section is
titled "Build & gates" without saying it is a curated subset, so a reader has
no way to know fourteen more steps exist.

**The nine-verb application surface** (`connect`, `listen`, `fetch`,
`publish`, `spawn`, `send`, `tell`, `serve`, `close`) is enumerated twice in
the README (lines 100-101 and 276-280), again in `docs/vision.md:68-70`, and
again in `bindings/README.md`. Four enumerations of a list whose whole point
is that it is small and stable.

**The layer inventory** is the largest overlap: the README's "On The Wire
Today" section (lines 161-402) walks the same ground as
`docs/architecture.md`'s layer-ownership sections at similar depth. The README
copy is the drift risk, because architecture.md is where an agent or
contributor is told to look and the README is where a stranger actually looks.

**Demo and example descriptions** are tiered (README summary → examples/README
index → per-app README deep dive) and the tiers are consistent. This
duplication is healthy — each tier serves a different reader — and should
survive the overhaul.

## Question 2 — Where do documents contradict each other?

No outright contradictions were found. The careful pairs were checked
specifically: Null's fail-closed status (README vs roadmap — aligned, same
rationale), the projection-op status including untag's pending live gate
(README vs roadmap — aligned), griddle's not-implemented status (README vs
vision — aligned, and vision explicitly warns against narrating it as built),
the Goblins interop gate inventory (README vs ladder — aligned), and
`AGENTS.md` vs `CLAUDE.md` (byte-identical; CLAUDE.md is a symlink).

The nearest thing to a contradiction is **registry-versus-reality**, in both
directions:

- `docs/protocol-diagrams/README.md:21-24` declares itself a living-state
  surface ("the matching diagram updates in the same change"), but the
  doc-drift registry does not list it, and `tools/meta_check.zig`'s
  `checkLivingStateRegistry` only sweeps top-level `docs/*.md`. The corpus
  promises a discipline no gate holds.
- The registry *understates* the gate: `CONTRIBUTING.md` and
  `bindings/README.md` are mechanically checked by `meta_check` (link
  resolution, prerelease-language scan, command parity) yet absent from the
  living-state table, as are `SECURITY.md`, `examples/README.md`, and
  `.devcontainer/README.md`, all of which make present-tense state claims.

## Question 3 — What is missing entirely?

Three first hours were traced from the README, following links exactly as a
stranger would.

**Someone who just heard of OCapN** falls off a cliff at `README.md:9`, where
"codec-neutral," "CapTP," and "OCapN" arrive in one sentence, and the CapTP
link goes to erights.org — a site that assumes the E language and 1990s
capability literature. Nothing in this repository defines *capability*, *vat*,
*sturdyref*, *swiss number*, or *promise pipelining* for a reader who doesn't
already know them; `docs/vision.md` uses "capability" twenty-plus times
without ever saying what one is, and Spritely Goblins — the named conformance
authority — is never introduced as a thing. The missing documents are: a
conceptual explainer (what a capability is, why delegation/attenuation/
revocation beat ambient authority, what CapTP adds over a socket), a one-line-
per-term glossary, and a paragraph introducing Goblins and the OCapN group
with outbound links. The protocol-diagrams corpus is the natural anchor for
the explainer tier, but today it assumes the very vocabulary a newcomer lacks.

**Someone evaluating the C ABI from another language** eventually wins, but
slowly (~45 minutes). The artifacts and the header are excellent once found:
`include/pancake.h` documents ownership and release on essentially every
function and states its generated origin. What's missing is the route: the
README's Quick Start is Zig-only; no document says "build with `zig build`,
artifacts land in `zig-out/`, start from `examples/c/echo_peer.c`, here are
the ownership rules in one place, here is how to link from your build system."
`echo_peer.c` is a complete, well-narrated minimal consumer that nothing
routes a C evaluator toward. `pancake.h` itself would benefit from a short
orientation preamble (single-owner threading model, frame ownership in two
sentences, where the examples live) ahead of the constant tables. Also
relevant to stage three: **no autodoc build step exists today**, so there is
no generated API reference for either the Zig or C surface.

**A would-be contributor** has the best existing path. `CONTRIBUTING.md` is
real, well-structured, honest about review cadence, and links the right
read-first set; the devcontainer README is clear; LICENSE files are present
and correctly licensed; the test-placement table tells them exactly where
a new test goes. The remaining gaps are small: no guidance on running or
filtering a single test, no stated channel for questions, no
`docs/decisions/` index introducing the ADR corpus, and no
`bindings/rust/README.md` even though `bindings/README.md`'s table implies
per-binding docs and Deno/Python/Racket each have one.

## Question 4 — What exists but is orphaned?

The mechanical incoming-link graph found exactly **one fully orphaned file**:
`docs/decisions/adr/template.md` — referenced from nowhere, not even
`CONTRIBUTING.md`'s "write an ADR" paragraph. Everything else is reachable,
though some of it only barely:

- Three ADRs (0045 per-session footprint budget, 0047 in-memory netlayer,
  0052 untag responder) are cited by id in README/roadmap/architecture prose
  but never linked, so a reader must reconstruct the path by hand.
- `conformance/accountability-on-pancake/FRICTION.md`,
  `conformance/accountability-on-goblins/racket/doc/KERNEL.md`, and the
  sample-KEL fixture README are named in backticks in their siblings' tables
  but never linked.
- `docs/decisions/` has no README/index; the 33 ADRs (numbering gaps are
  historical and fine; all carry `accepted` status) are discoverable only via
  a directory listing or a citation.
- Registry orphanhood, distinct from link orphanhood, is covered under
  Question 2: the diagram corpus, CONTRIBUTING, SECURITY, and the subsystem
  contract READMEs live outside the living-state table.

## The diagram corpus and the naming question

The prompt asked whether `docs/captp-examples/` still carries its dishonest
name. It does not — the rename to **`docs/protocol-diagrams/`** already landed
(commit d5d4bf2), cleanly: zero stale references to the old name anywhere in
the tree, the corpus README's title and prose match the new name, and the
doc-voice rule already cites `docs/protocol-diagrams/**` as a bound surface.
No rename is proposed; that finding is closed.

The corpus itself is in good shape: all 39 Mermaid blocks across the seven
numbered files match the README's catalog count, none look malformed, internal
links all resolve, and the corpus is reachable from the root README's
Documentation section. Protocol attribution is honest — `wants-partial?` is
tagged `[goblins-canonical]` in both places it appears
(`03-promises-and-pipelining.md:4,89`), and the PreSpec `op:resolve` framing
is explicitly contextualized as pancake's profile shape rather than
spec-mandated (`02-deliver-and-resolve.md:6-14`). Two open items: the corpus
is not registered (Question 2), and there is one doc-voice violation — the
arrow-as-prose at `01-session-lifecycle.md:8` ("`Negotiating → Open → Draining
→ Closed`" used as a sentence connector rather than a diagram). No build step
parses the Mermaid blocks today; that gate is stage-three work.

## The README, specifically

646 lines, twelve sections, 25-35 minutes to read. The front-door material is
already there and already good — "What Is This?" (14 lines), Quick Start,
Examples (a genuinely pleasant narrative), Vision summary, Documentation
links, License. What buries it is the middle: **"On The Wire Today"
(lines 161-402, 241 lines, ~28 multi-line bullets)** is a feature inventory
that duplicates architecture.md's job at architecture.md's depth, and
**"Current Boundaries" (lines 403-545, 143 lines)** is good prose at reference
depth. Together they are 60% of the file. Under the stage-two architecture,
the inventory's content belongs in the explanation/reference tier with the
README keeping a half-dozen-line "what's shipped" summary and a link; the
boundaries prose mostly survives intact but moves.

## Source-embedded documentation (relevant to the stage-three reference tier)

This surface is strong. All 76 files under `src/` carry `//!` headers written
as prose, and spot-checked symbol references in them are current. Public doc
comments on `Connection` are at 100%, `Peer` and `Vat` methods at ~88-89%,
and existing comments state ownership and allocation rather than restating
names. The gaps worth noting for the reference build: `Peer.init`,
`Peer.initWithSession`, and `Peer.deinit` are undocumented, and the `Peer` and
`Vat` struct declarations themselves lack `///` introductions (their fields
are documented individually). The `build.zig` step descriptions read as a
coherent user-facing menu. `include/pancake.h` is the best-documented C
header most readers will have seen, minus the missing orientation preamble.

## Proposed actions, for selection

Numbered so decisions can be made per item. Items 1-4 are corrections, 5-9 are
gaps, 10-12 are structural and overlap with stage two.

1. **Register the diagram corpus** in the doc-drift living-state table and
   teach `checkLivingStateRegistry` (or the registry prose) about subdirectory
   corpora, so the corpus's self-declaration is gated rather than honorary.
2. **Reconcile the registry with the gate**: add `CONTRIBUTING.md`,
   `SECURITY.md`, `bindings/README.md`, `examples/README.md`, and
   `.devcontainer/README.md` to the living-state table (the first three are
   already partially gated by `meta_check`; the table should admit it).
3. **Fix the one doc-voice violation** in the diagram corpus
   (`01-session-lifecycle.md:8`, arrow-as-prose).
4. **De-orphan the stragglers**: link `template.md` from a new
   `docs/decisions/README.md` index (which also fixes ADR discoverability),
   turn the three prose-cited ADR ids into links, and link FRICTION.md /
   KERNEL.md / the sample-KEL README where they are already named.
5. **Write the conceptual on-ramp**: an explainer for capability / CapTP /
   OCapN / vat vocabulary, a one-line glossary, and an introduction to
   Spritely Goblins and the OCapN group with outbound links. This is Persona
   A's entire missing first hour and the largest single gap found.
6. **Write the C-consumer route**: a quickstart that goes build → artifacts →
   `echo_peer.c` → ownership rules in one place → linking guidance, plus an
   orientation preamble in the generated `pancake.h` (via
   `tools/header_gen.zig`, since the header is generated).
7. **Create `bindings/rust/README.md`** to match its three siblings.
8. **Small contributor patches**: how to run/filter one test, a
   where-to-ask-questions line, and a sentence in the README's build section
   admitting the list is curated with a pointer to the full catalog.
9. **Document the three `Peer` lifecycle methods** and add `///` intros to the
   `Peer`/`Vat` struct declarations — the only doc-comment gaps that matter
   for the generated reference.
10. **Collapse the hand-synchronized triplicates** (allocation budget, 500k
    arithmetic, nine-verb list, layer inventory) to one authoritative home
    each plus links — this is the core of stage two's "every topic gets
    exactly one authoritative location" and should be designed there, not
    patched piecemeal.
11. **Shrink the README to a front door** — the two middle sections (384
    lines) move into the stage-two architecture's explanation/reference tier.
    Stage two will present the disposition of every section.
12. **Stand up an autodoc build step** (Zig's generated documentation) as the
    API-reference input for the stage-three site; no such step exists today.
