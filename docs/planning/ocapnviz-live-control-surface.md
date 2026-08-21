# The live control surface

Status: historical — connecting, capturing, and waiting-versus-quiet have
landed. This file remains as the pointer at
[ADR-0106](../decisions/adr/ADR-0106-viz-observation-capability.md), the accepted
observation capability: a viewer enlivens a read-only trace object. It
explicitly does not invent control verbs, and no endpoint offers any.

Entering Live dials the feed. Record starts a capture. The connection badge
distinguishes an empty sturdyref, a dial in progress, an open session that has
emitted nothing, and a feed that has already spoken.
