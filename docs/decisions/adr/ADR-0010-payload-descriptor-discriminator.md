---
id: ADR-0010
status: accepted
date: 2026-05-08
tags: [codec, syrup, wire, references, goblins-parity]
decision: The payload-position descriptor decoder dispatches on the wire tag into a **receiver-perspective** model `Reference`, flipping between sender and receiver (`<desc:export>` lifts to a `near` ref (our local export), `<desc:import-object>` / `<desc:import-promise>` lift to a `far` ref whose `ImportKind` preserves the object/promise tag (our import), and `<desc:answer>` lifts to a `promise`. The flip is a fixed wire-tag relabel) table-blind, so the codec still owns no authority; the session validates the relabeled reference against the matching table.
supersedes: []
superseded_by: []
---

# ADR-0010 Payload-position descriptor discriminator

## Context

Four descriptor shapes appear in **payload position**: a `resolve:fulfill`
argument, an `op:listen` target or listener, an `op:deliver` arg. The OCapN
`CapTP Specification.md` (§ Descriptors) and Goblins's `outgoing-pre-marshall!`
(`goblins/ocapn/captp.rkt`) write each from the **sender's** table perspective:
`<desc:export N>` names an object that lives on the _receiver_ (the sender is
referring to something it imports); `<desc:import-object N>` /
`<desc:import-promise N>` name one of the _sender's_ own exports: an object the
sender hosts and the receiver should import: and carry whether that export is
object- or promise-shaped; `<desc:answer N>` names a still-pending answer.

Because the wire arm is the sender's, a descriptor that crosses the wire must be
**re-anchored to the receiver's perspective** on decode: the sender's export is
the receiver's import, and vice versa. Goblins does this in
`incoming-post-unmarshall!` (`<desc:export>` becomes `(hash-ref exports-pos2val pos)`,
a local refr; `<desc:import-*>` becomes `maybe-install-import!`, a remote refr); the
Rust core does it in `reference_from_payload_desc`
(`glowcap-codec-syrup/src/ocapn/references.rs`). glowcap's Zig codec matches
them.

The flip must turn each wire tag into one receiver-perspective model reference
**without consulting a session table** (codecs do not own authority): it is a
fixed wire-tag relabel, not a lookup: while keeping the object-vs-promise
nature of a promise-shaped reference intact.

Engages the First Principles
[_session state is authoritative_](../../../AGENTS.md#first-principles): the
codec relabels, the session validates: and _codecs parse and render but do not
own authority_.

## Decision

### Table-blind decode flip

`readReference` in
[`src/ocapn/codec/syrup/decode/values.zig`](../../../src/ocapn/codec/syrup/decode/values.zig)
maps each payload-position wire tag (the sender's perspective) to exactly one
receiver-perspective model `Reference`, consulting no table:

- `<desc:export N>` becomes `.near` (`NearRef{ export_id = N, kind = .object }`): the
  sender names _our_ export.
- `<desc:import-object N>` becomes `.far` (`FarRef{ import_id = N, kind = .object }`)
  the sender offers one of _its_ exports for us to import.
- `<desc:import-promise N>` becomes `.far`
  (`FarRef{ import_id = N, kind = .promise }`).
- `<desc:answer N>` becomes `.promise` (`PromiseRef{ answer_id = N }`).

The relabel is a fixed wire-tag-to-variant map, not a lookup: the decoder never
reads or mutates a table, so the codec still owns no authority. The Cap'n Proto
codec
([`src/ocapn/codec/capnp/decode.zig`](../../../src/ocapn/codec/capnp/decode.zig))
applies the identical flip on its own word-shaped wire (`RefKind.near` becomes `.far`,
`RefKind.far` becomes `.near`), so a reference decoded from either codec means the
same thing.

### The encoder is the mirror; the flip is an involution

The encode side
([`src/ocapn/codec/syrup/encode.zig`](../../../src/ocapn/codec/syrup/encode.zig);
the kind dispatch is in the Encode-side kind dispatch section below) is the
exact inverse: our `near` export becomes `<desc:import-object>` /
`<desc:import-promise>` (dispatching on `NearKind`), our `far` import becomes
`<desc:export>`, a `promise` becomes `<desc:answer>`. So a reference sent and echoed
back swaps arms: that swap **is** the perspective change, not a round-trip bug.
Two wire crossings restore the original arm, which is how the codec round-trip
tests assert byte stability.

### The reference shape carries the wire tag

[`src/ocapn/model/mod.zig`](../../../src/ocapn/model/mod.zig) gives `NearRef` a
`kind: NearKind { object, promise }` and `FarRef` a symmetric
`kind: ImportKind { object, promise }`, both defaulting `.object`. The decoder
fills `ImportKind` from the `import-object` / `import-promise` tag, so the
object-vs-promise distinction of an offered cap survives into the receiver's
import. `<desc:export>` carries no object/promise signal: the receiver's
session is the authority on its own export's kind: so a decoded `NearRef.kind`
is `.object`.

### The session validates in the receiver's perspective

Because the codec already re-anchored the reference,
[`src/ocapn/session/mod.zig`](../../../src/ocapn/session/mod.zig) validates each
arm against the table that arm names directly: an inbound `near` resolves
against the **export** table (it is one of ours), an inbound `far` against the
**import** table; the outbound path is the mirror (`near` to exports, `far` to
imports). An inbound `far` that names a not-yet-held import is an _introduction_
(a fresh cap the partner is handing us), so the session installs it rather than
rejecting: see `installIntroducedImports`. The partner's bootstrap export is
always reachable on an open session (ADR-0006). A genuine miss is
`InvalidReference`; the codec mutates no table.

### The far-kind is preserved across enliven

A resolved import's `ImportKind` is preserved verbatim. The sturdyref enliven
dedup cache in [`src/ocapn/session/mod.zig`](../../../src/ocapn/session/mod.zig)
stores `(import_id, kind)`, so a cache-hit short-circuit reconstructs the
`FarRef` with its wire-tag discriminator intact rather than collapsing it to
`.object`.

### Encode-side kind dispatch

This is the encode-side mirror of the decode flip above. `NearRef` carries a
`kind: NearKind { object, promise }` discriminant, and the Syrup
payload-reference encoder dispatches on it: `.object` emits
`<desc:import-object>` and `.promise` emits `<desc:import-promise>`. So a
stateless codec renders a promise-shaped local export (a vow, a
resolver-callback, or a handoff-imported promise) as a promise descriptor
instead of always object. The default is `.object`, so ordinary call sites stay
terse. This is an additive model widening with no profile-name bump.

## Scope (what this does not decide)

- **Promise-import bookkeeping.** The session has no concept of queuing against
  an import the way the inbound-answer table queues against an answer;
  `ImportKind.promise` on a decoded import is carried, not yet branched on.

## Alternatives Considered

- **A perspective-neutral, non-flipping bijection** (`<desc:export>` to `far`,
  `<desc:import-*>` to `near`, with the session resolving direction at
  validation). Rejected: it diverges from both reference implementations.
  Goblins (`incoming-post-unmarshall!`) and the Rust core
  (`reference_from_payload_desc`) both flip in the codec, so a non-flipping Zig
  codec would force every engine helper that reads a decoded arm to re-flip by
  hand (a footgun) and would not be byte-equivalent to a partner's understanding
  of the same frame. The flip is still table-blind, so the
  _codecs-do-not-own-authority_ principle holds either way; matching the
  wire-established convention wins.
- **Resolve perspective inside the decoder by table lookup** (consult the
  receiver's tables at decode). Rejected: codecs do not own authority. The flip
  is a fixed wire-tag relabel; the session still validates against the table the
  relabeled arm names.
- **One collapsed reference variant for all three import/export descriptors.**
  Rejected: it discards both the object-vs-promise nature and the near/far
  distinction the session needs to pick a table.
- **A view-only discriminator** (kind on the borrowed view only). Rejected: a
  caller holding an owned `Reference` would have no answer to "object or
  promise?". The kind is a semantic property, stored on the model.

## Consequences

- `NearRef` carries `NearKind`, `FarRef` carries `ImportKind`; both default
  `.object`, so ordinary call sites stay terse. A decoded import carries its
  object/promise kind; a decoded export defaults `.object` (the session owns its
  export's kind).
- The session validates an inbound `near` against exports and an inbound `far`
  against imports, surfacing `InvalidReference` on a genuine miss; an inbound
  `far` for an unheld import is installed as an introduction. The outbound path
  is the mirror.
- Both codecs flip identically, so a reference is codec-neutral: the Syrup and
  Cap'n Proto paths decode the same wire-perspective reference to the same
  receiver-perspective model arm.
- The sturdyref enliven cache preserves the resolved `ImportKind`.
- Scenarios under
  [`src/oracle/`](../../../src/oracle/mod.zig) exercise each payload
  descriptor in a fulfill argument, an `op:listen` slot, and an `op:deliver`
  arg; the byte shapes are pinned against the glowcap-authored Syrup oracle
  corpus under `zig build oracle-check`.

## Forward compatibility

`NearKind` and `ImportKind` are additive enums, so a future axis (transient
debug ref, handoff-arrived import) lands without breaking existing matches.
Because the kind rides the model field rather than the wire-label string, the
Syrup and Cap'n Proto codecs carry the same `kind` content through their
respective wire shapes: adding a codec adds a wire-tag-to-arm relabel, not a new
model concept.

## Notes

[ADR-0007](ADR-0007-promise-pipelining-substrate.md) owns `<desc:answer>`
(pipelining against an answer-pos) and relies on this dispatch to reach an
`op:get` / `op:index` receiver.
[ADR-0012](ADR-0012-sturdyref-shape-and-enliven.md) consumes the preserved
far-kind through the enliven cache.
