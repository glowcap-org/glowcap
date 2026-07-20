# Decision records

Settled decisions live here as Architecture Decision Records, one file per
decision under [`adr/`](adr/). Each record is a terse memo: the context that
forced a choice, the decision, and the consequences the project accepts by
making it. Each record describes the moment its decision was made; we do not
rewrite a record to pretend a different choice was made. The living description
of the current shape is [`docs/architecture.md`](../architecture.md); when an
ADR and the architecture doc disagree, the architecture doc is current and the
ADR is history.

The set is pruned, not only grown. When the records get numerous, flatten
them: retire a record a later decision superseded, and fold a cluster of
related decisions into the single record that now carries them. Move any
still-live context into the keeper or into
[`docs/architecture.md`](../architecture.md) first, and fix every referrer in
the same change. The directory listing is
the index; numbering has gaps because retired and consolidated records are not
renumbered, so a gap is not a missing file.

To write a new record, copy [`adr/template.md`](adr/template.md) and follow the
guidance in [`CONTRIBUTING.md`](../../CONTRIBUTING.md): a change that affects
codec or netlayer boundaries, the session state machine, negotiation, wire
capability semantics, vocabulary, or layer separation gets a record, and the
record flips to `accepted` before code is built against it.
