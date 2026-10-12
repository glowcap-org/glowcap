---
id: ADR-0010
status: accepted
date: 2026-05-08
tags: [codec, syrup, wire, references, goblins-parity]
decision: The payload-position descriptor decoder dispatches on the wire tag into a **receiver-perspective** model `Reference`, flipping between sender and receiver (`<desc:export>` lifts to a `near` ref (our local export), `<desc:import-object>` / `<desc:import-promise>` lift to a `far` ref whose `ImportKind` preserves the object/promise tag (our import), and `<desc:answer>` lifts to a `promise`. The flip is a fixed wire-tag relabel) table-blind, so the codec still owns no authority. The session validates the relabeled reference against the matching table.
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
referring to something it imports). `<desc:import-object N>` /
`<desc:import-promise N>` name one of the _sender's_ exports (an object the
sender hosts and the receiver should import) and carry whether that export is
object- or promise-shaped. `<desc:answer N>` names a still-pending answer.

Because the wire arm is the sender's, a descriptor is re-anchored to the
receiver's perspective on decode: the sender's export is the receiver's import,
and vice versa. Goblins does this in
`incoming-post-unmarshall!` (`<desc:export>` becomes `(hash-ref exports-pos2val pos)`,
a local refr, `<desc:import-*>` becomes `maybe-install-import!`, a remote refr). The
Rust core does it in `reference_from_payload_desc`
(`glowcap-codec-syrup/src/ocapn/references.rs`). glowcap's Zig codec matches
them.

The flip turns each wire tag into one receiver-perspective model reference
without consulting a session table, since codecs own no authority. It keeps the
object-vs-promise nature of a promise-shaped reference.

## Decision

### Table-blind decode flip

`readReference` in
[`src/ocapn/codec/syrup/decode/values.zig`](../../../src/ocapn/codec/syrup/decode/values.zig)
maps each payload-position wire tag (the sender's perspective) to one
receiver-perspective model `Reference`, consulting no table:

- `<desc:export N>` becomes `.near` (`NearRef{ export_id = N, kind = .object }`): the
  sender names _our_ export.
- `<desc:import-object N>` becomes `.far` (`FarRef{ import_id = N, kind = .object }`)
  the sender offers one of _its_ exports for us to import.
- `<desc:import-promise N>` becomes `.far`
  (`FarRef{ import_id = N, kind = .promise }`).
- `<desc:answer N>` becomes `.promise` (`PromiseRef{ answer_id = N }`).

The relabel is a fixed wire-tag-to-variant map. The decoder never reads or
mutates a table. The Cap'n Proto codec
([`src/ocapn/codec/capnp/decode.zig`](../../../src/ocapn/codec/capnp/decode.zig))
applies the same flip on its word-shaped wire (`RefKind.near` becomes `.far`,
`RefKind.far` becomes `.near`), so a reference decoded from either codec means
the same thing.

### The encoder is the mirror. The flip is an involution

The encode side
([`src/ocapn/codec/syrup/encode.zig`](../../../src/ocapn/codec/syrup/encode.zig),
the kind dispatch is in the Encode-side kind dispatch section below) is the
inverse: our `near` export becomes `<desc:import-object>` /
`<desc:import-promise>` (dispatching on `NearKind`), our `far` import becomes
`<desc:export>`, a `promise` becomes `<desc:answer>`. So a reference sent and
echoed back swaps arms. The swap is the perspective change. Two wire crossings
restore the original arm, which is how the codec round-trip tests assert byte
stability.

### The reference shape carries the wire tag

[`src/ocapn/model/mod.zig`](../../../src/ocapn/model/mod.zig) gives `NearRef` a
`kind: NearKind { object, promise }` and `FarRef` a symmetric
`kind: ImportKind { object, promise }`, both defaulting `.object`. The decoder
fills `ImportKind` from the `import-object` / `import-promise` tag, so the
object-vs-promise distinction of an offered cap survives into the receiver's
import. `<desc:export>` carries no object/promise signal: the receiver's
session is the authority on its export's kind, so a decoded `NearRef.kind` is
`.object`.

### The session validates in the receiver's perspective

Because the codec already re-anchored the reference,
[`src/ocapn/session/mod.zig`](../../../src/ocapn/session/mod.zig) validates each
arm against the table that arm names: an inbound `near` resolves against the
export table (it is one of ours), an inbound `far` against the import table. The
outbound path is the mirror (`near` to exports, `far` to imports). An inbound
`far` that names a not-yet-held import is an _introduction_ (a fresh cap the
partner is handing us), so the session installs it: see
`installIntroducedImports`. The partner's bootstrap export is always reachable
on an open session (ADR-0006). A miss is `InvalidReference`.

### The far-kind is preserved across enliven

The sturdyref enliven dedup cache in
[`src/ocapn/session/mod.zig`](../../../src/ocapn/session/mod.zig) stores
`(import_id, kind)`, so a cache hit reconstructs the `FarRef` with its wire-tag
discriminator instead of collapsing it to `.object`.

### Encode-side kind dispatch

`NearRef` carries a `kind: NearKind { object, promise }` discriminant, and the
Syrup payload-reference encoder dispatches on it: `.object` emits
`<desc:import-object>` and `.promise` emits `<desc:import-promise>`. So a
stateless codec renders a promise-shaped local export (a vow, a
resolver-callback, or a handoff-imported promise) as a promise descriptor
instead of always object. The widening is additive and bumps no profile name.

## Scope (what this does not decide)

- **Promise-import bookkeeping.** This record owns the wire discriminator.
  [ADR-0111](ADR-0111-next-promise-listeners.md) later gave next-profile promise
  imports their session-owned shortening and settling listeners. Inbound
  answer queues remain a separate authority.

## Alternatives Considered

- **A perspective-neutral, non-flipping bijection** (`<desc:export>` to `far`,
  `<desc:import-*>` to `near`, with the session resolving direction at
  validation). Rejected: Goblins (`incoming-post-unmarshall!`) and the Rust core
  (`reference_from_payload_desc`) both flip in the codec, so a non-flipping Zig
  codec would force every engine helper that reads a decoded arm to re-flip by
  hand. The flip is table-blind, so codecs own no authority either way.
- **Resolve perspective inside the decoder by table lookup** (consult the
  receiver's tables at decode). Rejected: codecs own no authority. The session
  validates against the table the relabeled arm names.
- **One collapsed reference variant for all three import/export descriptors.**
  Rejected: it loses the object-vs-promise nature and the near/far distinction
  the session needs to pick a table.
- **A view-only discriminator** (kind on the borrowed view only). Rejected: a
  caller holding an owned `Reference` could not tell object from promise.
  The kind is a semantic property, so the model stores it.

## Consequences

- `NearRef` carries `NearKind`, `FarRef` carries `ImportKind`. Both default
  `.object`, so ordinary call sites stay terse. A decoded import carries its
  object/promise kind. A decoded export defaults `.object` (the session owns its
  export's kind).
- The session validates an inbound `near` against exports and an inbound `far`
  against imports, surfacing `InvalidReference` on a genuine miss. An inbound
  `far` for an unheld import is installed as an introduction. The outbound path
  is the mirror.
- Both codecs flip identically: the Syrup and Cap'n Proto paths decode the same
  wire-perspective reference to the same receiver-perspective model arm.
- The sturdyref enliven cache preserves the resolved `ImportKind`.
- Scenarios under
  [`src/oracle/`](../../../src/oracle/mod.zig) exercise each payload
  descriptor in a fulfill argument, an `op:listen` slot, and an `op:deliver`
  arg. The byte shapes are pinned against the glowcap-authored Syrup oracle
  corpus under `zig build oracle-check`.

## Forward compatibility

`NearKind` and `ImportKind` are additive enums, so a future axis (transient
debug ref, handoff-arrived import) lands without breaking existing matches.
The kind rides the model field, not the wire-label string, so adding a codec
adds a wire-tag-to-arm relabel and no new model concept.

## Notes

[ADR-0007](ADR-0007-promise-pipelining-substrate.md) owns `<desc:answer>`
(pipelining against an answer-pos) and relies on this dispatch to reach an
`op:get` / `op:index` receiver.
[ADR-0012](ADR-0012-sturdyref-shape-and-enliven.md) consumes the preserved
far-kind through the enliven cache.
