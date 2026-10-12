---
id: ADR-0049
status: accepted
date: 2026-06-11
tags: [model, codec, passable, integer, goblins-interop]
decision: The OCapN Integer is complete. `model.Argument.integer` stays the `i64` fast path. Magnitudes outside `i64` ride a new `big_integer` arm carrying the sign plus the canonical decimal magnitude as bytes. Decode picks the arm canonically, both codecs and the C ABI refuse non-canonical values symmetrically, and big-integer equality is bytewise.
supersedes: []
superseded_by: []
---

# ADR-0049 Arbitrary-precision Integer

## Context

The OCapN Integer is arbitrary-precision (Model.md § Integer), and Goblins
marshals Racket bignums. glowcap modelled `integer` as `i64` and refused a
magnitude outside that range at decode, the last missing atom of the passable
set. The design question is which bytes represent the magnitude in the
codec-neutral model. Syrup carries decimal digits on the wire. A binary (limb)
representation would force a decimal-to-binary conversion inside the Syrup
codec, which allocates on the zero-copy borrowed-view path and brings bignum
arithmetic into the tree.

## Decision

- **The model carries the sign plus the canonical decimal magnitude.**
  `model.BigInteger` is `negative: bool` + `digits: []const u8`. Canonical means
  non-empty ASCII `0-9`, no leading zero, magnitude outside `i64`
  (`BigInteger.isCanonical`, the type's invariant). Both wire codecs carry these
  bytes: Syrup as the integer's digit run, Cap'n Proto as a data field with the
  sign on the discriminant word. The borrowed view borrows the digits from the
  frame on both codecs, and no conversion or bignum arithmetic exists in the
  tree.
- **The arm split is canonical, so equality is bytewise.** Decode produces
  `integer` for every value in the `i64` range (including both bounds, with
  `minInt`'s magnitude the one asymmetry) and `big_integer` only outside it.
  Two arms never represent one arithmetic value, so Pass Invariant Equality over
  big integers is sign + digit bytes, with no cross-arm case.
- **Refusal is symmetric (ADR-0003).** A non-canonical big integer (leading
  zeros, non-digits, or a magnitude that belongs to the `integer` arm) is a
  malformed frame on decode and an unsupported argument on encode, in both
  codecs and at the C ABI boundary (`GLOWCAP_ARG_BIG_INTEGER`, which reuses
  `bytes`/`bytes_len` for digits and `boolean` for the sign). Only canonical
  bytes cross any boundary.
- **Arithmetic is the application's job.** glowcap transports and compares the
  value and does not compute with it. A consumer parses the digits into its own
  bignum type.

## Scope (what this does not decide)

- OCapN Null stays unmodeled: Goblins has no Null marshalling and the upstream
  encoding is unsettled (ADR-0046). Unknown Syrup records project as `Tagged`,
  with no dedicated Null refusal.
- The protocol-position integers (export/answer positions, list indexes, wire
  deltas) stay `u64`/`i64`. Arbitrary precision applies to the passable value
  space only.

## Consequences

- The passable data model is complete except Null.
- `model.Argument` stays the same size: the arm is 24 bytes against the 80-byte
  reference arm that sizes the union.
- The proof chain: layer unit tests, cross-codec equivalence, byte parity
  against the upstream Racket Syrup encoder (`op_deliver_arg_big_integer.bin`,
  `prim_integer_big_neg.bin`), and the live `goblins-interop` echo, which
  round-trips 2^100 through a real Racket bignum in both directions.
