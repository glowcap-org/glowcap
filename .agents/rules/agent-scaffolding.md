---
description: "The scaffolding is a public API whose consumers are agents. Living-state discipline, the scaffolding gate, the ratchet, and the budget. Load before changing anything under .agents/, AGENTS.md, overlays, hooks, or skills."
alwaysApply: true
---

# pancake — Agent Scaffolding

The scaffolding — `AGENTS.md`, everything under `.agents/`, the `.claude/` and
`.cursor/` overlays, the hooks, the skills — is a public API whose consumers
are agents. Every value this project holds about public surfaces therefore
applies to it, and applies harder, because the consumers act on what the
surface says, every session, at machine speed. A stale README misleads a
reader who might notice. A stale rule instructs an executor who won't. A
rough edge in code becomes a rough edge in one contribution; a rough edge in
a rule becomes a rough edge in every contribution that follows. The rest of
this rule is not new policy. It is the project's existing values pointed at
the surface that delivers them.

## The scaffolding is living-state

Every rule, every README under `.agents/`, every skill body, every hook doc
is a living-state surface under the doc-drift rubric, registered in the
doc-drift living-state table. A rule that cites a path is claiming the path
exists. A rule that shows a command is claiming the command works. A rule
that describes a convention is claiming the convention holds. When the state
moves, the claim moves in the same diff — aligned, removed, or stripped of
its state claim. No fourth outcome, and no follow-up PR.

## The scaffolding has a gate

Code answers to `zig build check`; the scaffolding answers to the same
invocation. The gate verifies, mechanically, every claim it can reach.
`tools/meta_check.zig` is the complete inventory — read it before assuming a
claim is unchecked. The shape of what it holds:

- Both overlay schemes are complete and unbroken — the `.claude/rules`
  directory symlink resolves to `.agents/rules`, and every
  `.agents/rules/<name>.md` has a live `.cursor/rules/<name>.mdc` symlink.
  A canonical rule without its overlay is silently unloaded — the failure
  mode is invisible at exactly the moment it matters.
- The indexes and the directories agree in both directions. An unindexed
  rule or skill is undiscoverable; an indexed ghost is a broken promise. The
  same holds for build steps (every documented `zig build` command is a real
  step, every step is documented), for relative links across `.agents/**`,
  `AGENTS.md`, and the docs corpus, and for the doc-drift living-state
  registry (every top-level doc registered, every registered path real).

The gate also creates a standing pressure: **a rule sentence that could be a
check is a TODO for a check.** When a check lands, the prose that asserted
the same thing shrinks to a pointer. Over time the rules should get shorter
and the gate should get longer. That is the intended direction of travel —
it is "make the correct path the easy path," applied to the rules
themselves, because a build step holds the line without asking anyone to
remember it.

## The ratchet

Every session ends with one question: what did this session learn that the
scaffolding didn't already teach? If the answer is non-empty, the lesson
lands before the session does, and it lands at the strongest layer that can
hold it:

1. **A build check**, if the lesson is mechanically checkable.
2. **A fixture or conformance scenario**, if the lesson is semantic.
3. **A rule line**, only when neither of the above fits — and then the
   sharpest line that carries it, placed in the rule that owns the surface.
4. **A deletion**, when the lesson is that an existing line no longer earns
   its load.

A correction from the human is always a ratchet event: the session that
receives it encodes it, or explains in the handoff why it couldn't. The
measure of a session is not only whether the task completed but whether the
floor is higher for the next agent than it was for this one.

## The budget

Every rule line is context every future session must carry, so every line
pays rent. Additions displace or compress; they do not merely accumulate. A
rule that outgrows a single attentive read splits by responsibility, the way
a module would. Prefer one sentence with teeth over five with hedges —
bullet accretion is the drift mode of scaffolding, and it kills documents
slowly: the load-bearing lines drown, the voice flattens, and agents start
skimming the very text that was supposed to stop them from skimming. Pruning
is not maintenance deferred from the ratchet; it is half the ratchet.

## Taste lives here as structure, not as names

Engineering-taste references belong in prompts and plans; committed files
carry the taste as shape — explicit protocol vocabulary, honest allocation
and lifetime surfaces, sharp module boundaries, a gate that bites. If a
prompt's standard is worth keeping, this rule and the gate are where it
keeps, expressed as a consequence an agent can act on, never as a name an
agent is asked to impersonate.

## Scaffolding litmus

Before changing the scaffolding, ask:

- Does this make the next agent's first correct action more likely?
- Could the gate enforce this instead of prose? Then wire the gate.
- Does this line earn its tokens in every session that loads it?
- Would the gate notice if this claim drifted?
- Is the floor higher when this diff lands than it was before?
