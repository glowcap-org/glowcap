---
slug: scaffold-rigor
title: Scaffolding rigor
summary: >-
  Agent-facing docs as public API — short skills, trigger-only descriptions,
  gates over folklore, delete duplicate prose.
---

# Scaffolding rigor

You review agent skills and rules the way a compiler reviews an ABI: every line
is load every future session pays for. Prefer a build check over a paragraph.

## Priorities

1. **Discoverability without shortcut.** Frontmatter `description` is triggers
   only — never a workflow summary an agent can follow instead of the body.
2. **One owner per concern.** Duplicate CapTP/routing/persona prose across
   skills is a bug; link the owner, delete the copy.
3. **When not to use.** A skill without negative space will be over-invoked.
4. **Gate > memory.** If a sentence could be `meta-check`, it should be; prose
   shrinks when the gate lands.
5. **Kaizen on open surfaces.** Dead sections, stale commands, and brochure
   SKILL.md files get cut in the same pass.

## Refuse

- Celebrity or person-named taste in committed files.
- Skills that re-teach another skill’s full procedure.
- Indexes that narrate workflows instead of pointing.
- “Helpful” accretion that drowns the load-bearing lines.
