---
id: ADR-0252
status: accepted
date: 2026-10-16
tags: [captp, next, capnp, negotiation, handshake, codegen]
decision: "The hint tokens of a CapTP version or codec glowcap owns carry a fingerprint of the exact wire this build writes for it, generated from a corpus covering every message kind. A token this build does not write, known name or not, reads as the baseline on that axis, and an unknown feature name is dropped, so two builds whose own wires differ settle on v1.0 Syrup. Only an unreadable token is malformed."
supersedes: []
superseded_by: []
amends: [ADR-0003, ADR-0103]
amended_by: []
---

# ADR-0252 Own-wire identity in profile offers

## Context

ADR-0103 settles each session's profile from the preferences two hellos carry,
and falls back to the v1.0 Syrup baseline on any axis the pair cannot agree on.
Agreement was decided by name. The version hint said `glowcap-next` and the
Cap'n Proto codec hint said `0`, whatever the build's encoders wrote under
them.

ADR-0251 changed the `next` wire: `op:deliver` gained an inline resolver and a
listen mode, and `op:deliver-only` arrived. The names did not change. A Rooms
page running the earlier build and a server running the later one both offered
`glowcap-next`, settled on it, and then refused each other's frames as
`MalformedFrame` on every reconnect. The baseline fallback never ran, because
nothing told the two that they disagreed.

The private tracks are glowcap's alone: `next` is glowcap-to-glowcap
(ADR-0003), and no other implementation writes Cap'n Proto CapTP. Their shape
moves with every glowcap build during prerelease, so the name of a track says
less than the build that speaks it.

The reverse failure also existed. A token this build did not know, such as a
later build's version name or a feature added after this one, was refused as
`MalformedMessage`. That refused the hello outright where ADR-0103 promised
the baseline.

## Decision

`tools/gen/own_wire.zig` encodes one corpus under every (version, codec) pair
that `CaptpVersion.ownedByGlowcap` or `CodecId.ownedByGlowcap` claims, today
`next` in Syrup, `next` in Cap'n Proto, and `1.0` in Cap'n Proto. Each case
records its frame bytes, or the name of the error that refused it, and the
first 64 bits of SHA-256 over the record land in
`src/ocapn/model/own_wire.zig`. A `comptime` block refuses a corpus missing
any message kind, argument value kind, reference kind, handoff, or resolution.
Each case states its outcome under every version, and the generator fails
when a pair disagrees, so the record cannot decay into error names. A removed
operation, such as `op:get` under `next`, contributes its refusal, so
restoring it changes the fingerprint too. `zig build gen-own-wire-check`, part
of `check`, keeps the file fresh, so a change to what an owned encoder writes
cannot land with the old fingerprint.

The hint tokens carry it. The version hint for `next` is
`glowcap-next/<fingerprint>` and the Cap'n Proto codec hint is
`0/<fingerprint>`. `CaptpVersion.hintToken` and `CodecId.hintToken` write
them, and `fromHintToken` reads back only what this build writes. Both tokens
carry the one fingerprint over every owned pair, so a change to any owned
encoder changes both.
`CaptpVersion.wireString` stays `glowcap-next`, the name traces and
diagnostics use.

`session.validate.parsePreferenceHintsValidated` reads a version or codec
token this build does not write as the baseline on that axis, and drops a
feature name it does not know. What stays malformed is a token no build could
mean: a codec id that is not a decimal `u16`, an empty feature name, and a
known feature named twice. Duplicate hint names stay malformed, as ADR-0103
decides.

So two builds whose own wires differ settle on v1.0 Syrup and keep talking.
A build from before this decision reads the new tokens as malformed and
refuses at the hello, rather than settling on `next` and failing mid-session.
Version and codec stay independent axes, as ADR-0003 decides.

## Scope (what this does not decide)

- A change in meaning that leaves every corpus frame byte-identical goes
  unseen, and so does a change confined to a form the corpus does not reach
  (an optional field's other setting, say). Such a change adds a corpus case
  that shows it.
- Decoding is not fingerprinted. A decoder that starts refusing bytes an
  unchanged encoder writes is caught by the codec round-trip tests, not here.
- The v1.0 Syrup wire is OCapN's, and its fingerprint is the spec and the
  Goblins fixtures. It carries none.
- An application protocol above CapTP, such as Rooms', has its own
  compatibility boundary, and this does not decide it.

## Alternatives Considered

- **Tie Cap'n Proto to `next`.** Rejected because version and codec are
  independent axes (ADR-0003), and tests pin a v1.0 Cap'n Proto outcome.
- **A separate `glowcap/wire` hint.** Rejected because builds that predate it
  ignore it and still settle on `next` with a later build.
- **A revision number bumped by hand.** Rejected because it depends on someone
  remembering, and a forgotten bump is exactly the failure above.
- **Fingerprint the source of the codec modules.** Rejected because a refactor
  that writes the same bytes would split builds that agree, and a change
  outside those files that alters the bytes would go unseen.

## Consequences

- Two glowcap builds that write the same own wire agree on `next`. A peer
  whose own wire differs falls back to the baseline.
- Tests and fixtures that hand-wrote `glowcap-next` or `0` as a hint now take
  the token from `hintToken`. `conformance/ocapn-conformance/next_wire.py`
  reads the fingerprint from the generated file.
- ADR-0103's rule that a malformed `hint_features` value is refused now means
  an unreadable list, not an unknown name.

## Evidence and gate

- `test/engine/pairing/handshake_test.zig`: a partner on another build of the
  own wire settles on the baseline, with a pre-fingerprint token and with a
  different fingerprint.
- `test/session/lifecycle_test.zig` and `test/codec/syrup/decode_hints_test.zig`:
  a token this build does not write reads as the baseline, and an unreadable
  codec id stays malformed.
- `test/engine/negotiation_test.zig`: an unknown feature name is dropped.
- `test/model/model_test.zig`: owned tokens carry the fingerprint and baseline
  tokens do not.
- `zig build gen-own-wire-check`.
