# Community review

This is the review brief for OCapN and Spritely Goblins maintainers. It states
the interop target, the evidence that runs, and the known differences from the
draft text or a live peer.

pancake pins the OCapN suite and Goblins source and runs both in the public
check workflow for main-branch pushes and pull requests. It has not asked to be
listed as an OCapN implementation. Because the repository is written largely
with LLM agents, it also sends no unsolicited patches, issues, or comments to
projects that may not want them. The policy is in
[`PROVENANCE.md`](../PROVENANCE.md).

## Vocabulary map

| Goblins / CapTP / OCapN | pancake |
| --- | --- |
| `mycapn` | Two roles: the product is a `Host`; the sans-io handoff router is `engine.Node`. Never one type equation. |
| CapTP session with one partner | Application-facing `Session`; the Host ABI's registered shell is `PancakeHostSession`. A byte stream is a `Connection` / transport `*Conn`, never the CapTP partner. |
| Goblins vow / OCapN promise / answer position | A Goblins vow is a passable eventual reference. pancake's `Vow` is a local host/actor observation and send-result handle over an OCapN promise. `desc:answer` names the sender-chosen session slot used for pipelining. These are related projections, not one type. |
| CapTP value-level sealer / unsealer | Not implemented as a pancake type. The unrelated `SealedChannel` is pancake's Noise-encrypted transport byte channel (ADR-0107). |

Two findings may be useful upstream: the draft, suite, and Goblins disagree on
the operand count for `op:listen`, and the draft's mapping-shaped locator hints
do not match the pinned Goblins string-or-false constructor contract. The
checked records are in
[`conformance/ocapn-findings/`](../conformance/ocapn-findings/README.md). It
will be reproduced by hand if an upstream maintainer asks for it.

## Interop Target

The Goblins-facing path is signed CapTP 1.0 over Syrup on cleartext TCP. That
is the default used by the C ABI, `driver.connect`, the upstream suite, and the
live Goblins checks.

TCP itself authenticates no durable peer identity. The fresh session key signs
the hello, so pancake can verify session continuity and signed handoff
payloads. Durable provenance comes only from an authenticated channel realizer
such as iroh, WebRTC signaling, or an embedder-supplied channel binding.

The pancake-native profile is a separate job. Native peers can negotiate
`"pancake-next"` with Cap'n Proto, and iroh supplies encrypted reachability.
Neither is a Goblins compatibility claim. The only outside CapTP
implementations exercised today are the upstream suite and Racket Goblins.

## Known gaps

- pancake has live coverage in all three handoff roles: gifter, recipient, and
  exporter. The exporter check now proves exact-object identity: the Goblins
  gifter primes the pancake-hosted actor, pancake replaces the alias with a
  decoy, and the Goblins recipient's withdrawn call must observe the primed
  original. Handoff over a transport other than TCP has one live row, and only
  in the exporter role: `goblins-rooms-dm-iroh`, where a browser redeems a give
  naming a Goblins vat on an iroh endpoint. The other two roles are TCP only.
- **Goblins indexes an exporter session by the complete locator.** pancake
  embeds the peer-owned advertised snapshot rather than reconstructing it at
  the handoff site. This is stable for Goblins Onion, whose locator is
  `(onion, service-id, #f)`. An iroh endpoint without reachability can update
  `direct-addresses`; the replacement snapshot applies to subsequent sessions
  and gifts. Goblins' full-value lookup remains worth an upstream report, but
  it is not a pancake architecture boundary.
- Every CapTP session uses a fresh signing key. Durable provenance
  comes only from authenticated channel realization: iroh supplies its QUIC
  endpoint id and WebRTC supplies the identity authorized by signaling. Raw
  keyed TCP and keyed relay report `unauthenticated`; matching the dialed key
  remains a target check, not proof.
- Relaying a foreign promise is live in the gifter role. Native pancake can
  also play the recipient through `listenTo`, but no live partner calls that
  path.
- Goblins can put canonical `op:get` and `op:index` frames on pancake's wire.
  The Goblins-side netlayer probe observes pancake's resolver-callback
  fulfillments for both projected answers. Goblins still has no public
  application-level API for sending those projection requests directly.
- A live Goblins vat accepts pancake's one-way `tell` form. The check sends
  two answerless `op:deliver` frames and reads the changed state back through
  an answered call.
- OCapN Null waits on an upstream representation decision. `op:untag` ships on
  1.0 and `pancake-next`; inbound support is unconditional, while a signed
  feature offer prevents Pancake from sending it to a silent Goblins peer.
  Only a live external-peer exercise waits on upstream support.

[Known limitations](boundaries.md) explains the effect on users. Open OCapN
and Goblins questions live in [upstream-watch](upstream-watch.md). The
[roadmap](roadmap.md) lists pancake-owned remaining work.

## Evidence

A **yes** in the CI column means the step appears in `ci/gates.sh` and runs in
the public [checks workflow](https://github.com/jimisaacs/pancake/actions/workflows/check.yml).
`zig build source-check` derives this column from that script, so a removed step
cannot remain marked as recurring evidence.

| Evidence | CI | Proves | Does not prove |
| -------- | -- | ------ | -------------- |
| `zig build check` (includes `oracle-check`) | yes | In-tree protocol scenarios, message-arm coverage, committed Syrup fixtures, Cap'n Proto goldens, resource budgets, and a complete six-peer handoff scenario. | A live outside peer or a fresh upstream Syrup run. |
| `zig build ocapn-conformance` | yes | The upstream suite's CapTP modules against the production Host stack, plus handshake refusal and a portable pre-setup abort check. | Future suite netlayers or transport recovery after abort; the raw upstream `tests.op_abort` rejects Linux TCP reset. |
| `zig build ocapn-findings-check` | yes | The pinned sources still disagree on `op:listen` arity and locator-hints typing. | Which form upstream should choose. |
| `zig build goblins-interop` | yes | A live Goblins session in both directions over Syrup/TCP. Covers handshake, bootstrap, calls, promise settlement, bignums, enlivenment, pipelining, answerless delivers, actor calls, and Goblins-written `op:get` / `op:index` requests that settle through resolver-callback fulfillments. | A public Goblins application API for outbound projections, live `op:untag`, or iroh. |
| `zig build goblins-iroh` | no | Live Goblins sessions both ways over the iroh netlayer this repository wrote for Goblins. | Recurring CI (needs cargo + racket), hole-punching, or non-TCP handoff roles beyond the on-demand rooms row below. |
| `zig build goblins-handoff` | yes | pancake redeems a Goblins give. | pancake as gifter or exporter. |
| `zig build goblins-gift` | yes | pancake mints a give that Goblins redeems. | pancake as recipient or exporter. |
| `zig build goblins-gift-hints` | yes | A hinted locator survives decode, re-encode, signature verification, and live Goblins redemption. | General route discovery or non-TCP handoff. |
| `zig build goblins-exporter` | yes | A Goblins pair deposits into and withdraws from pancake's gift registry, and the withdrawn object is the exact actor the gifter mutated, across an alias replacement. | Alias removal mid-flight, or handoff over a non-TCP transport. |
| `zig build goblins-relayed-give` | yes | A Goblins recipient reads a signed give from a listener notification, dials the exporter, and calls the withdrawn capability. | pancake receiving that live introduction through `listenTo`. |
| `zig build goblins-gc` | yes | Live inbound `op:gc-exports` after Goblins drops a near export. | Outbound GC, `op:gc-answers`, or binding finalizers. |
| `zig build goblins-rooms-dm` / `-iroh` | no | Three peers across two implementations take the three handoff roles: a pancake room gifts, a real Goblins vat exports, and a pancake browser peer redeems and reaches the vat off-room, over cleartext TCP and over iroh. The vat answers on the arriving connection, and starts a direct message of its own to a native pancake member. | Recurring evidence: it drives a real Chromium and the checks workflow installs no browser, so it is run on demand. The iroh row does not yet cover a Goblins recipient dialing a pancake exporter after a direct-address update. |
| Binding `*-goblins-interop` steps | yes | Deno, Python, Rust, and Racket dial Goblins through the C ABI, enliven a sturdyref, and call it. | Bun or any binding as listener. | <!-- ci-gate: bindings-goblins-interop -->
| `zig build deno-goblins-listen` | yes | Goblins dials a Deno binding and calls its published actor. | The other bindings as listener. |
| Binding `*-goblins-handoff` / `*-goblins-gift` | yes | Deno, Python, Rust, and Racket act as recipient and gifter against Goblins; each gifter lifts a delegated capability from an ordinary vendor reply, returns it twice in one nested value, and Goblins redeems and calls both gives directly. | Bun or live recursive Tagged/user-record interop, which pinned Goblins does not implement. | <!-- ci-gate: bindings-goblins-handoff, bindings-goblins-gift -->
| Introducing-session promise proxy | yes | In-tree Node and Host coverage projects complete nested object/promise settlements through Host identity under both codecs, with independent recipient pressure and one signed give per object occurrence. | pancake's `listenTo` path against a live outside partner. | <!-- ci-gate: check -->
| `zig build fuzz` | yes | Coverage-guided inputs exercise codecs, framing, sessions, handoff, locators, the host, actors, persistent collections, and completion-loop accounting. Saved crashes replay under `check`. | Agreement with the specification, unreached code, or a well-formed but wrong decode. The recurring search is shallow. |
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
- **`op:listen`.** V1.0 follows the suite and Goblins Boolean
  `wants_partial` form. Next follows OCapN PR 282's integer modes and mandatory
  shortening subscriptions. A live object export settles immediately; a bare
  unresolved promise export is refused. Third-party promise relay and native
  `listenTo` use the ordinary listen and settlement path.
- **Handshake refusal.** An invalid signature, pinned-key mismatch, or version
  mismatch sends a typed abort and closes the CapTP session, matching the draft
  and Goblins. A corrected hello requires a new session.
- **Settlement.** Goblins CapTP 1.0 uses an inline resolver callback. Next
  receives the same fulfill or break callback through the mandatory listen and
  sends no wire `op:resolve`.
- **Negotiation.** `op:start-session` carries the baseline version string;
  codec, version, and feature preferences travel in its signed locator hints.
  Peers settle those offers after both verified hellos arrive.
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
zig build goblins-gift-hints
zig build goblins-relayed-give
zig build goblins-gc
```

The live steps need Racket with Goblins; the suite needs `uv`. The devcontainer
provides both. Pin changes live in
[`.devcontainer/pins.sh`](../.devcontainer/pins.sh).

Report protocol-invariant breaks privately through
[`SECURITY.md`](../SECURITY.md).
