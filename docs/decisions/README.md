# Decision records

Settled decisions live here as Architecture Decision Records, one file per
decision under [`adr/`](adr/). Each record is a terse memo: the context that
forced a choice, the decision, and the consequences the project accepts by
making it. ADRs are historical records — they describe the moment a decision
was made and are not rewritten when the code moves on. The living description
of the current shape is [`docs/architecture.md`](../architecture.md); when an
ADR and the architecture doc disagree, the architecture doc is current and the
ADR is history.

The directory listing is the index. Numbering has gaps because records from
earlier explorations were retired rather than renumbered; a gap is not a
missing file.

To write a new record, copy [`adr/template.md`](adr/template.md) and follow
the guidance in [`CONTRIBUTING.md`](../../CONTRIBUTING.md): a change that
affects codec or netlayer boundaries, the session state machine, negotiation,
wire capability semantics, vocabulary, or layer separation gets a record, and
the record flips to `accepted` before code is built against it.
