# Decision records

Settled design choices live under [`adr/`](adr/). Each record captures the
problem, the choice, and its consequences at the time the decision was made.
For the current design, read [`docs/architecture.md`](../architecture.md).
If the two disagree, the architecture page is current and the ADR is history.

The directory listing is the index. A superseded record stays where it is. It
keeps its number, carries `status: superseded` and a `superseded_by` pointer in
its frontmatter, and opens with a short note under the title saying which of its
claims the replacement kept and which it dropped. Source comments and tests cite
records by number, so files are never renumbered. A gap in the numbering is a
record that no longer exists.

Copy [`adr/template.md`](adr/template.md) for a new or revised architectural
decision about codec or netlayer boundaries, session state, negotiation, wire
semantics, protocol vocabulary, or layer ownership. Accept the record before
building code against it. Fixes that restore documented behavior, tests, and
local refactoring within existing contracts need no new record.

A record states its standing in frontmatter and nowhere else. `status` is one of
`proposed`, `accepted`, or `superseded`, and `source-check` refuses any other
value, a missing `id` or `date`, an `id` that disagrees with the filename, and a
superseded record that names no replacement. Prose may say how far an accepted
record's implementation has come, but not with a `**Status:**` line in the body,
because the relation graph below reads only frontmatter.

ADR frontmatter records replacement and refinement as different relations.
`supersedes` means the older decision is no longer living guidance. `amends`
means its substance remains accepted with a named correction. Both relations
are reciprocal through `superseded_by` and `amended_by`, and `source-check`
rejects missing targets or one-sided links.
