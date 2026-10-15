# glowcap — Agent Personas

Anonymous taste lenses for subagent reviews and rooms-team members. Catalog:
[`.agents/README.md` Personas](../README.md#personas).

## Lookup

Resolve each slug in order and stop at the first file that exists, so the
narrower source shadows the wider one:

1. `.agents/personas/<slug>.md`, this repository's own lenses
2. `.local/.agents/personas/<slug>.md`, a gitignored checkout-local overlay for
   lenses that must not be published
3. `${XDG_CONFIG_HOME:-$HOME/.config}/agents/personas/<slug>.md`, one set of
   lenses shared by every checkout on a machine

Only personas resolve this way. Rules and skills have one home, this
directory's siblings, and no other scaffolding may read checkout-local state.

**File shape:** YAML frontmatter with `slug:` matching the filename stem, a
`description` whose first sentence the agent index shows, and an optional
`title`, then a taste body the subagent applies.

**Hard rule for project personas:** committed files under `.agents/personas/`
are anonymous lenses only (slug + taste). A named person and a person-named
slug live in one of the two unpublished sources above, never in committed
scaffolding, because a lens that asks a subagent to read as a living person
states an opinion its subject never agreed to hold. `zig build source-check`
refuses person-channeling phrasing in a tracked project persona.

**Slug selection:** the operator names the slugs or points at files under the
paths above. Skills hardcode no celebrity defaults. When a slug is missing,
stop the run and tell the operator to install it or choose another:

```sh
ls .agents/personas 2>/dev/null
ls .local/.agents/personas 2>/dev/null
ls "${XDG_CONFIG_HOME:-$HOME/.config}/agents/personas" 2>/dev/null
# write <slug>.md files with frontmatter + taste body under any of the three
```
