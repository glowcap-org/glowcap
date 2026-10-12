---
name: community-review
description: >-
  Use before a real community review invite, or when asked to review glowcap
  from OCapN, Goblins, or FLOSS-reception concerns. Never name real people. Not
  for general refactoring (smell-annihilation) or implementation without a
  review ask.
---

# Community review preflight

Find the claim↔evidence mismatches and wire/host gaps a careful OCapN or
Goblins-facing read would hit, and the provenance objections a FLOSS reviewer
raises before reading any protocol code. Distrust the first soft answer when
prerelease has waived migration cost ([prerelease](../../rules/prerelease.md)).
Prefer a gate, a sharper boundary, or a closed Host/codec edge over a longer
apology.

**May name:** OCapN, Spritely, Goblins, and their public resources (spec, suite,
institute docs already linked from vision/README).

**Must not name or infer:** real people, “channel \<person\>", or an author roster.
Taste-reference engineer names stay out of scaffolding
([agent-scaffolding](../../rules/agent-scaffolding.md)). Speak of neighbors with
respect ([doc-voice](../../rules/doc-voice.md)).

## The loop

1. **SCOPE.** Fault / ideal / false constraint, one sentence each.
2. **REVIEW WITH INDEPENDENT LENSES.** Spawn one subagent per lens on the real
   tree. `provenance` runs on every review, plus `ocapn-wire` and
   `goblins-interop` when protocol substance is in scope. Order each: read code
   and docs; say where something is already right; invent no nits; propose, do
   not edit (unless the user asked to execute).
3. **SYNTHESIZE.** Keep candidates where the lenses agree. Where they disagree,
   decide and say why. Escalate what both call a real defect.
4. **EXECUTE** only when the user asked for implementation.
5. **GATE.** Match verification to the changed surface. A planning-only prose
   change runs `zig build source-check`; a protocol implementation runs
   `zig build check` (exit code, not skimmed output).
6. **DEFER.** Name non-moves with real reasons; park them on
   [`docs/roadmap.md`](../../../docs/roadmap.md) or
   [`docs/boundaries.md`](../../../docs/boundaries.md).

Live CapTP while reviewing: [glowcap-mcp](../glowcap-mcp/SKILL.md) ·
[glowcap-cli](../glowcap-cli/SKILL.md), never a throwaway Zig dialer.

## Lenses

### `ocapn-wire`

Review as someone steeped in the public OCapN protocol materials and suite, not as
any named person.

**Cares about:** CapTP wire semantics; upstream suite modules glowcap runs; oracle
arms; claim scope matching evidence; session / GC / handoff / sturdyref / passable
edges; [`SECURITY.md`](../../../SECURITY.md) invariants.

**Loads:**
- [`conformance/ocapn-conformance/`](../../../conformance/ocapn-conformance/)
- [`conformance/ocapn-spec/`](../../../conformance/ocapn-spec/)
- [`test/oracle/`](../../../test/oracle/)
- [`docs/boundaries.md`](../../../docs/boundaries.md), [`docs/shipped.md`](../../../docs/shipped.md)
- ADRs 0003, 0006, 0008, 0009/0056, 0012, 0046, 0083 under
  [`docs/decisions/adr/`](../../../docs/decisions/adr/)
- Public OCapN entry points already cited in-repo (e.g.
  [github.com/ocapn/ocapn](https://github.com/ocapn/ocapn))

**Out of scope:** Zig taste, C ABI ergonomics, and scale theater, unless they
change a wire claim.

### `goblins-interop`

Review as someone steeped in public [Spritely Goblins](https://spritely.institute/goblins/)
as the practical wire reference, not as any named person.

**Cares about:** bidirectional live conversation on authenticated Syrup/TCP; no
invented wire Goblins cannot speak; accurate handoff / bootstrap / sturdyref /
listen claims; an actor layer above CapTP that does not redefine CapTP.

**Loads:**
- [`docs/vision.md`](../../../docs/vision.md)
- [`interop/`](../../../interop/)
- [`conformance/goblins-peer/`](../../../conformance/goblins-peer/)
- Live gate inventory in shipped / `build.zig` (`goblins-interop`, `goblins-handoff`,
  binding variants)
- ADRs 0003, 0035, 0056, 0063; boundaries on Null, untag, iroh, bootstrap
- Public Spritely / Goblins resources already cited in-repo

**Out of scope:** Cap’n Proto and iroh except when first-read prose blurs them into
the Goblins interop claim.

### `provenance`

Review as a FLOSS contributor who has just learned how glowcap is built and is
deciding whether to take it seriously. This lens runs **first**, because a
reviewer who bounces here never reaches the wire.

The positions are public and settled, and glowcap argues with none of them:

- **Codeberg** bans projects that "mostly consist of
  code written by 'generative AI'-tools" (Terms of Use § 2 (1) 7, member vote,
  July 2026). glowcap falls within that wording. The
  [announcement](https://blog.codeberg.org/protecting-our-floss-commons-from-llms.html)
  also lists projects written and maintained with heavy LLM use among those that
  may no longer be welcome. Review as if the rule applies, because it does,
  and do not argue it down to a narrower reading than its text.
- **Zig** forbids LLM-assisted contributions outright, including issues and
  comments, because review is how it grows contributors.
- **OCapN** requires specifications, suite, official tooling, and surrounding
  communication to be human-authored; generated issues and pull requests are
  rejected. glowcap's implementation may use agents; its messages to OCapN
  may not.

**Cares about:**

1. **Disclosure is present and true.** [`PROVENANCE.md`](../../../PROVENANCE.md)
   states how the project is built, in the open, without spin, and every
   sentence in it is checkable. Concealment ends the conversation. Commit
   trailers corroborate assistance but are not the project's identity. A
   first-read page that hides the disclosure, or describes glowcap as
   AI-written instead of maintainer-directed and AI-assisted, does harm.
2. **Nothing generated leaks upstream.** No LLM-written patch, issue, or comment
   goes to a project that forbids it. A violation breaks a commitment
   `PROVENANCE.md` makes in public.
3. **External authority carries the claims.** The answer to "how do I know this
   is right" is the upstream OCapN suite
   (`ocapn-conformance`), the live Goblins peer (`goblins-interop`,
   `goblins-handoff`, `goblins-gift`), and budgets a reader can run, never
   "trust the author." Weigh how much of the evidence is *independent* versus
   in-tree tests agreeing with in-tree code, and say so.
4. **Resource honesty.** An automated project pushes often. Expensive CI belongs
   on a commercial mirror, not a donated forge.
5. **The maintainer is legible.** The policies distinguish whether a human
   directs the work and answers for it. Ask whether the repository shows that
   or only asserts it.

**Refuse:**

- Advising concealment: stripping `Co-Authored-By` trailers, rewriting history to
  hide provenance, or wording a disclosure to mislead.
- Treating the policies as an obstacle to route around instead of a position to
  meet. Name the policy and do not editorialize the community as unwelcome.
- Overclaiming a personal audit of every line, or putting the destination's
  ambition on a first-read page as a slogan. Responsibility is public;
  biography and rank are not.
- Defensive prose. State the fact and move to the evidence.

**Loads:** [`PROVENANCE.md`](../../../PROVENANCE.md),
[`CONTRIBUTING.md`](../../../CONTRIBUTING.md) (Continuous integration, License),
[`docs/community-review.md`](../../../docs/community-review.md) (the
proves / does-not-prove table), [`ci/gates.sh`](../../../ci/gates.sh) with
`.github/workflows/`, and the live check inventory in `build.zig`.

## Concrete output each lens must produce

Prioritized, most-impactful first:

- exact path (and line when code),
- before→after or deletion,
- principle served,
- blast radius,
- hard split: `do-now` / `own-pass` / `watch-upstream`.

Synthesize into remediations tagged `invite-blocking` | `packet-honesty` |
`roadmap-watch`. A `provenance` finding is `invite-blocking` by default. The
human-facing summary for invite prep lives in
[`docs/community-review.md`](../../../docs/community-review.md).

## On this codebase

- **Verification:** planning-only prose runs `zig build source-check`; protocol
  implementation runs `zig build check`. Focused: `zig build test`, `arch-check`,
  `source-check`, `oracle-check`; live `ocapn-conformance`, `goblins-interop`,
  `goblins-handoff`.
- **Layer bans:** `build.zig` `layer_table` + `arch-check` (`core = true` bans `std.Io`).
- **Prerelease posture:** [`.agents/rules/prerelease.md`](../../rules/prerelease.md).
- **Settled architecture:** [`docs/decisions/adr/`](../../../docs/decisions/adr/).
