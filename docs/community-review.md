# Community review

This is the review brief for OCapN and Spritely Goblins maintainers. It states
the interop target, the evidence that runs, and the known differences from the
draft text or a live peer.

pancake pins the OCapN suite and Goblins source and runs both on every push. It
has not asked to be listed as an OCapN implementation. Because the repository
is written largely with LLM agents, it also sends no unsolicited patches,
issues, or comments to projects that may not want them. The policy is in
[`PROVENANCE.md`](../PROVENANCE.md).

Two findings may be useful upstream: the draft, suite, and Goblins disagree on
the operand count for `op:listen`, and the draft's mapping-shaped locator hints
do not match the pinned Goblins string-or-false constructor contract. The
checked records are in
[`conformance/ocapn-findings/`](../conformance/ocapn-findings/README.md). It
will be reproduced by hand if an upstream maintainer asks for it.

## Interop target

The Goblins-facing path is authenticated CapTP 1.0 over Syrup and TCP. That is
the default used by the C ABI, `driver.connect`, the upstream suite, and the
live Goblins checks.

The pancake-native profile is a separate job. Native peers can negotiate
`"pancake-next"` with Cap'n Proto, and iroh supplies encrypted reachability.
Neither is a Goblins compatibility claim. The only outside CapTP
implementations exercised today are the upstream suite and Racket Goblins.

## Known gaps

- pancake has live coverage in all three handoff roles: gifter, recipient, and
  exporter. The exporter check now proves exact-object identity: the Goblins
  gifter primes the pancake-hosted actor, pancake replaces the alias with a
  decoy, and the Goblins recipient's withdrawn call must observe the primed
  original. There is no live handoff coverage over a transport other than TCP.
- CapTP sessions within one Host currently reuse one signing key. Moving to the
  fresh per-connection keys required by OCapN first needs
  [ADR-0097](decisions/adr/ADR-0097-captp-session-identity-attestation.md)'s
  explicit netlayer bindings. keyed-TCP and keyed-relay currently rely on key
  equality. iroh and WebRTC authenticate below CapTP but do not expose the
  remote endpoint or capability-authorized DTLS binding to Host verification.
- Relaying a foreign promise is live in the gifter role. Native pancake can
  also play the recipient through `listenTo`, but no live partner calls that
  path.
- Goblins can put canonical `op:get` and `op:index` frames on pancake's wire.
  No live Goblins vow observes pancake settling those projections.
- No live Goblins check sends a one-way `tell`.
- OCapN Null, live `op:untag`, and Goblins over iroh wait on upstream work.

[Known limitations](boundaries.md) explains the effect on users. The
[roadmap](roadmap.md) says what would close each gap.

## Evidence

A **yes** in the CI column means the step appears in `ci/gates.sh` and runs in
the public [checks workflow](https://github.com/jimisaacs/pancake/actions/workflows/check.yml).
`zig build meta-check` derives this column from that script, so a removed step
cannot remain marked as recurring evidence.

| Evidence | CI | Proves | Does not prove |
| -------- | -- | ------ | -------------- |
| `zig build check` (includes `oracle-check`) | yes | In-tree protocol scenarios, message-arm coverage, committed Syrup fixtures, Cap'n Proto goldens, resource budgets, and a complete six-peer handoff scenario. | A live outside peer or a fresh upstream Syrup run. |
| `zig build ocapn-conformance` | yes | The upstream suite's CapTP modules against the production Host stack, plus handshake refusal. | Future suite netlayers or transport recovery after abort. |
| `zig build ocapn-findings-check` | yes | The pinned sources still disagree on `op:listen` arity and locator-hints typing. | Which form upstream should choose. |
| `zig build goblins-interop` | yes | A live Goblins session in both directions over Syrup/TCP: handshake, bootstrap, calls, promise settlement, bignums, enlivenment, pipelining, and a Goblins call to a pancake actor. | A Goblins vow observing pancake's projection responders, live `op:untag`, or iroh. |
| `zig build goblins-handoff` | yes | pancake redeems a Goblins give. | pancake as gifter or exporter. |
| `zig build goblins-gift` | yes | pancake mints a give that Goblins redeems. | pancake as recipient or exporter. |
| `zig build goblins-exporter` | yes | A Goblins pair deposits into and withdraws from pancake's gift registry, and the withdrawn object is the exact actor the gifter mutated, across an alias replacement. | Alias removal mid-flight, or handoff over a non-TCP transport. |
| `zig build goblins-relayed-give` | yes | A Goblins recipient reads a signed give from a listener notification, dials the exporter, and calls the withdrawn capability. | pancake receiving that live introduction through `listenTo`. |
| `zig build goblins-gc` | yes | Live inbound `op:gc-exports` after Goblins drops a near export. | Outbound GC, `op:gc-answers`, or binding finalizers. |
| Binding `*-goblins-interop` steps | yes | Deno, Python, Rust, and Racket dial Goblins through the C ABI, enliven a sturdyref, and call it. | Bun or any binding as listener. | <!-- ci-gate: bindings-goblins-interop -->
| `zig build deno-goblins-listen` | yes | Goblins dials a Deno binding and calls its published actor. | The other bindings as listener. |
| Binding `*-goblins-handoff` / `*-goblins-gift` | yes | Deno, Python, Rust, and Racket act as recipient and gifter against Goblins; the gifter lifts the delegated capability from an ordinary vendor reply before handing it on. | Bun or native Zig's bidirectional path. | <!-- ci-gate: bindings-goblins-handoff, bindings-goblins-gift -->
| Introducing-session promise proxy | yes | In-tree Node and Host coverage for relaying a foreign promise and emitting one signed give per recipient. | pancake's `listenTo` path against a live partner. | <!-- ci-gate: check -->
| `zig build fuzz` | yes | Coverage-guided inputs exercise codecs, framing, sessions, handoff, locators, the host, actors, persistent collections, and completion-loop accounting. Saved crashes replay under `check`. | Agreement with the specification, unreached code, or a well-formed but wrong decode. The per-push search is shallow. |
| `zig build cli-test` / `pancake` | yes | CLI budgets, hang-proof dial, listen/call behavior, REPL, and MCP. | OCapN suite or Goblins behavior. | <!-- ci-gate: check -->

For a quick manual call over Syrup/TCP, use the [CLI walkthrough](cli.md).

## Divergences and watch items

- **Null.** pancake has no OCapN Null value. Unknown Syrup records remain
  tagged values until upstream encoding and Goblins marshalling agree.
- **Set and Keyword.** The draft model lists neither. Goblins marshals both,
  so pancake follows the Goblins wire, including canonical set order and
  duplicate refusal.
- **Projections.** `op:get`, `op:index`, and `op:untag` ship in-tree. The live
  limits are listed above.
- **Cap'n Proto.** It is a pancake-to-pancake codec. Handoff values carry the
  same structural locators, but their signatures still use the Syrup domain.
- **Start-session hints.** The suite requires non-empty locator hints to be
  consumed rather than rejected. Both codecs preserve them; Syrup also retains
  the original signed location record.
- **`op:listen`.** pancake follows the suite and Goblins three-operand form,
  including `wants_partial`. The draft sketches two operands. A live object
  export settles immediately; a bare unresolved promise export is refused.
  Third-party promise relay and native `listenTo` use the ordinary listen and
  settlement path.
- **Handshake refusal.** An invalid signature, pinned-key mismatch, or version
  mismatch sends a typed abort but leaves the session negotiating. The draft
  says the connection should be severed. Adapters may still close it, and a
  corrected hello must pass full verification.
- **Settlement.** Goblins CapTP 1.0 uses resolver-callback fulfill and break.
  The pancake-native profile carries both under `op:resolve`; draft discussion
  sometimes names a separate `op:break`.
- **Negotiation.** Codec and feature offers are shared out of band.
  `op:start-session` carries only the version string, so the live 1.0 checks say
  nothing about the pancake-native profile.
- **Suite TCP.** Goblins interop uses the `tcp` transport symbol. The upstream
  suite uses its own `tcp-testing-only` URLs.
- **Target equality.** A remote target reached directly and through handoff
  on the same live exporter session canonicalizes to one Host identity, and
  repeated sturdyref enlivenment on a session deduplicates. Two parallel
  sessions to the same peer are not claimed to converge; ADR-0097's fresh-key
  peer selection owns that.
- **Signature verification.** Production uses `foundation.crypto`. The
  accepting verifier in test support is available only to in-process tests.

## Reproduce

Initialize the submodules once:

```sh
bash conformance/bootstrap-submodules.sh
```

Then run:

```sh
zig build check
zig build ocapn-conformance
zig build ocapn-findings-check
zig build goblins-interop
zig build deno-goblins-listen
zig build goblins-handoff
zig build goblins-gift
zig build goblins-relayed-give
zig build goblins-gc
```

The live steps need Racket with Goblins; the suite needs `uv`. The devcontainer
provides both. Pin changes live in
[`.devcontainer/pins.sh`](../.devcontainer/pins.sh).

Report protocol-invariant breaks privately through
[`SECURITY.md`](../SECURITY.md).
