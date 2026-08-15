# Decision records

Settled design choices live under [`adr/`](adr/). Each record captures the
problem, the choice, and its consequences at the time the decision was made.
For the current design, read [`docs/architecture.md`](../architecture.md).
If the two disagree, the architecture page is current and the ADR is history.

The directory listing is the index. A superseded record stays where it is. It
keeps its number, carries `status: superseded` and a `superseded_by` pointer in
its frontmatter, and opens with a short note under the title saying which of its
claims the replacement kept and which it dropped. Keeping it is what lets the
relation graph below be checked at all, and the tree cites these records by
number from source comments and tests, so the number has to keep resolving.

The gaps in the numbering come from a single early consolidation that folded a
dozen records into their successors. Files are not renumbered, so a gap means a
record that no longer exists rather than one waiting to be written.

Copy [`adr/template.md`](adr/template.md) for a new record. Changes to codec or
netlayer boundaries, session state, negotiation, wire semantics, protocol
vocabulary, or layer ownership need one. Accept the record before building code
against it; [`CONTRIBUTING.md`](../../CONTRIBUTING.md) has the review rules.

A record states its standing in frontmatter and nowhere else. `status` is one of
`proposed`, `accepted`, or `superseded`, and `source-check` refuses any other
value, a missing `id` or `date`, an `id` that disagrees with the filename, and a
superseded record that names no replacement. Prose is free to expand on where an
accepted record's implementation stands, but a `**Status:**` line in the body is
not a second place to say it: a record whose standing lives only in prose is
invisible to the relation graph below, which is how five of them went unchecked.

ADR frontmatter records replacement and refinement as different relations.
`supersedes` means the older decision is no longer living guidance; `amends`
means its substance remains accepted with a named correction. Both relations
are reciprocal through `superseded_by` and `amended_by`, and `source-check`
rejects missing targets or one-sided links.
