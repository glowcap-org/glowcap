# pancake — Agent Personas

Anonymous taste lenses for subagent reviews and rooms-team members. Catalog:
[`.agents/README.md` Personas](../README.md#personas).

## Lookup

User resources for `.agents/` live under
`${XDG_CONFIG_HOME:-$HOME/.config}/agents/` (personas are one leaf). Resolve
each slug in order (project shadows user):

1. `.agents/personas/<slug>.md` when present
2. else `${XDG_CONFIG_HOME:-$HOME/.config}/agents/personas/<slug>.md`

**File shape:** YAML frontmatter with `slug:` matching the filename stem;
optional `title` / `summary`; then a markdown taste body the subagent applies.

**Hard rule for project personas:** committed files under `.agents/personas/`
are anonymous lenses only (slug + taste). Named people and person-named slugs
live only in user XDG (or untracked local files) — never in committed
scaffolding. `zig build meta-check` refuses person-channeling phrasing in
tracked project personas.

**Slug selection:** the operator names the slugs (or points at files under the
paths above). Skills do not hardcode celebrity defaults. Missing slug → stop
and tell the operator to install or choose another:

```sh
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/agents/personas"
ls "${XDG_CONFIG_HOME:-$HOME/.config}/agents/personas"
ls .agents/personas 2>/dev/null
# write <slug>.md files with frontmatter + taste body under either path
```
