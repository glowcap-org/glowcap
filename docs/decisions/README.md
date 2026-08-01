# Decision records

Settled design choices live under [`adr/`](adr/). Each record captures the
problem, the choice, and its consequences at the time the decision was made.
For the current design, read [`docs/architecture.md`](../architecture.md).
If the two disagree, the architecture page is current and the ADR is history.

The directory listing is the index. Gaps are intentional: superseded records
are removed or folded into the decision that replaced them, and the remaining
files are not renumbered.

Copy [`adr/template.md`](adr/template.md) for a new record. Changes to codec or
netlayer boundaries, session state, negotiation, wire semantics, protocol
vocabulary, or layer ownership need one. Accept the record before building code
against it; [`CONTRIBUTING.md`](../../CONTRIBUTING.md) has the review rules.

ADR frontmatter records replacement and refinement as different relations.
`supersedes` means the older decision is no longer living guidance; `amends`
means its substance remains accepted with a named correction. Both relations
are reciprocal through `superseded_by` and `amended_by`, and `meta-check`
rejects missing targets or one-sided links.
