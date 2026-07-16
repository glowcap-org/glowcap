# Community review

This page is for a careful OCapN or Spritely Goblins read of pancake. It names
the interop target, what each evidence check proves, and the deliberate
asterisks.

Maintainers preparing a review use the
[`community-review` skill](../.agents/skills/community-review/SKILL.md).

## Interop target

The Goblins-facing wire path is authenticated CapTP v1.0 over Syrup, usually on
cleartext TCP (and the suite's `tcp-testing-only` netlayer). That is the success
criterion in [`vision.md`](vision.md) and the interop target in ADR-0003.
Live interop steps and the C ABI default (`pancake_peer_new`, Host/`driver.connect`)
stay on that path. In-process `pairing.paired()` is the *other* job: it settles
`Offer.native()` to `next` / `"pancake-next"` plus Cap'n Proto. Goblins-shaped
in-process fixtures use `pairing.pairedGoblins()` (or keyed Goblins offers).

Cap'n Proto is a second codec for pancake-to-pancake peers. iroh is a netlayer
for encrypted reachability. Neither is a Goblins parity claim. Goblins speaks
Syrup, and Goblins ships no iroh netlayer.

## Evidence matrix

| Evidence | Proves | Does not prove |
| -------- | ------ | -------------- |
| `zig build check` (includes `oracle-check`) | In-tree Zig scenarios, the message-arm registry, Syrup fixture parity versus the upstream encoder, and Cap'n Proto golden encode/decode lock (`test/codec/capnp_fixtures/`) | A live Goblins conversation |
| `zig build ocapn-conformance` | The suite's current CapTP modules against a pancake peer: `op_start_session`, `op_abort`, `op_deliver`, `op_listen`, `op_gc`, and `third_party_handoffs` | Netlayer modules (e.g. onion) or CapTP modules the suite adds later |
| `zig build goblins-interop` | A bidirectional live Syrup/TCP conversation with a real Goblins vat: handshake, bootstrap, deliver, V1.0 resolver-callback settlement (fulfill/break), engine-synthesized `op:listen` on projection answers, bootstrap miss→break, pancake-as-asker `op:index` / `op:get`, sturdyref enliven | Live `op:untag` (Goblins has no marshaller yet); Goblins-as-asker against pancake's get/index responders; Goblins over iroh; listen on an unresolved promise export without an answer row |
| `zig build goblins-handoff` | Recipient-side three-party handoff against Goblins (pancake redeems) | That pancake minted the give (see `goblins-gift`) |
| `zig build goblins-gift` | Gifter-side three-party handoff against Goblins (pancake mints; Goblins redeems) | That pancake redeemed (see `goblins-handoff`) |
| Binding `*-goblins-interop` steps | Client direction only: keyed handshake + bootstrap fetch + call over the C ABI (Rust, TypeScript, Python, Racket) | Zig listener / projection / enliven-dedup / break legs, demo apps, binding listen/hosting, or that a binding is the semantic source of truth |
| Binding `*-goblins-handoff` / `*-goblins-gift` | Binding as recipient (redeems a Goblins give) or binding as gifter (Goblins recipient redeems) | Native Zig bidirectional handoff (`goblins-handoff` / `goblins-gift`) |

## Divergences and watch items

These are named in [`boundaries.md`](boundaries.md) and [`roadmap.md`](roadmap.md).
They are summarized here so they are not surprises:

- **OCapN Null.** Not modeled as a passable arm. Inventing one would not
  interop until upstream encoding and Goblins marshalling settle. Unknown
  Syrup records project as `Tagged` (Goblins break/exception leniency); that
  is not a dedicated Null refuse.
- **Live `op:untag`.** The in-tree responder and fixtures ship. There is no live
  Goblins marshaller yet.
- **Cap'n Proto versus Syrup.** Cap'n Proto is a second codec. Do not debug
  Goblins against Cap'n Proto bytes. A Cap'n Proto session that flattens a
  handoff exporter locator to `transport:designator` cannot carry keyed dial
  hints the way a Syrup peer-record path can; that is not a Goblins parity
  claim.
- **Start-session locator hints.** The suite requires non-empty hints to be
  consumed, not rejected. Both codecs project entries through borrowed
  `PeerLocator.hint_list` (and `toOwned`); Syrup also keeps
  `acceptable_location_raw` for the signing domain.
- **`op:listen`.** Engine-synthesized V1.0 listen covers answer and promise
  projections, including promise targets named as `desc:export` (suite
  `op_listen`; ADR-0009). A live object export (no answer row) fires
  fulfill of that export immediately. An unresolved promise export without an
  answer row refuses loud (`UnexpectedMessage`) — remaining ADR-0007 boundary.
  Live Goblins settlement in `goblins-interop` is the V1.0 resolver-callback
  path; outbound projection listeners are engine-synthesized. The draft CapTP
  text sketches a 2-operand listen; Goblins-canonical / suite listen is
  3-operand (`wants_partial`); pancake follows the suite.
- **Settlement shape.** Draft CapTP discussion sometimes names a separate
  `op:break`; pancake CapTP v1.0 speaks Goblins resolver-callback fulfill/break.
  `pancake-next` folds fulfill/break under `op:resolve`.
- **Offers, codec, and `FeatureSet`.** Negotiated out of band
  (`Offer` / pairing / shared config). `op:start-session` carries only the
  captp-version string. Suite and Goblins interop do not prove Cap'n Proto or
  `"pancake-next"` as OCapN interop.
- **Two TCP symbols.** Live Goblins interop uses transport symbol `tcp`
  (`net.tcp`, Goblins `tcp-netlayer.rkt`). The upstream suite target uses
  `tcp-testing-only` URLs — not the Goblins parity path.
- **Cleartext TCP and keyed-tcp.** keyed-tcp pins the key holder. It does not
  encrypt the channel. Confidentiality is iroh's job.
- **Distributed GC.** Wire `gc-exports` / `gc-answers` ship (suite `op_gc`).
  Binding finalizer GC is opt-in and covers fetched far refs only. Live inbound
  export GC against a Goblins vat ships as `zig build goblins-gc`.
- **Bootstrap durability.** The default is ephemeral. `durable_bootstrap` fails
  closed until an embedder store exists.
- **Handoff signature verification.** The engine verifies via an injected
  `SignatureVerifier`; production paths use `foundation.crypto`. Test support
  exposes `testOnlyAcceptingVerifier` for in-process substrates. That is not a
  production default on an untrusted network.
- **Upstream watch.** Goblins over iroh, Null, live untag, draft `op:listen`
  arity, and settlement encoding stay parked until their flip conditions in
  [`roadmap.md`](roadmap.md) §1 and §3 trip. Do not invent that wire here.
- **In-tree Goblins evidence still open.** Export-side listen on an unresolved
  promise export: parked in [`roadmap.md`](roadmap.md) §3 with a flip
  condition. Native Zig recipient/gifter handoff and live Goblins GC all ship
  (`goblins-handoff` / `goblins-gift` / `goblins-gc`).

## Reproduce in one sitting

From the repository root, with submodules initialized
(`bash conformance/bootstrap-submodules.sh` once):

```sh
zig build check
zig build ocapn-conformance
zig build goblins-interop
zig build goblins-handoff
```

Live steps need Racket with Goblins (and `uv` for the upstream suite). The
devcontainer provides them; see [`CONTRIBUTING.md`](../CONTRIBUTING.md).

## Security

Report protocol-invariant breaks privately per [`SECURITY.md`](../SECURITY.md).
