# Community review

This page is for a careful OCapN or Spritely Goblins read of pancake. It names
the interop target, what each evidence check proves, and the deliberate
asterisks.

Maintainers: read the evidence matrix below, run the named build steps, and cite
file and line for any claim.

## Destination vs today

[`vision.md`](vision.md) describes a complete Goblins-facing CapTP conversation
with no gaps. The evidence matrix below is what ships today. When you invite a
reviewer, name these open items first, then point at the matrix.

- A foreign **promise** introduced on one session and fulfilled on another is
  proven only in-tree. Live Goblins has not yet introduced an unresolved vow
  that way. Object gift and redeem steps do not cover this path.
- Goblins can send `op:get` / `op:index` toward pancake on the wire, but a live
  Goblins client vow that settles those projections is still unfinished.
- OCapN Null, live `op:untag`, and Goblins over iroh wait on upstream work.
  See [`roadmap.md`](roadmap.md) §1 and §3. Do not invent that wire here.

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
| `zig build check` (includes `oracle-check`) | In-tree Zig scenarios, the message-arm registry, Syrup fixtures whose committed bytes come from the upstream Syrup encoder, and Cap'n Proto goldens. Whole-conversation driven traces cover abort, deliver/resolve, bootstrap-fetch, listen/resolve, the projection trio with its synthesized listens, the gc pair's release accounting, and the full three-party handoff — six peers on three keyed sessions, real Ed25519 certificates verified at withdraw, the early withdraw parked until its deposit lands, and a direct call through the redeemed capability | A live Goblins conversation; a fresh upstream-encoder run (that is the sibling `zig build fixture-gen-check`, needs racket) |
| `zig build ocapn-conformance` | The suite CapTP modules against a pancake peer, plus the short handshake-abort probe | Netlayer modules the suite adds later |
| `zig build goblins-interop` | A live Syrup/TCP conversation with a real Goblins vat both ways: handshake, bootstrap, deliver, fulfill/break, bignum, pancake asking Goblins with `op:index` / `op:get`, sturdyref enliven, pipelined call, Goblins calling a published pancake actor, Goblins listening on a live pancake object export, Struct- and list-shaped pancake replies settling a Goblins vow, and pancake accepting canonical `op:get` / `op:index` frames a Goblins netlayer wrote (arrival asserted in the inbound answer table) | A Goblins client vow that settles `op:get` / `op:index` against pancake; live `op:untag`; Goblins over iroh |
| `zig build goblins-handoff` | Recipient-side three-party handoff (pancake redeems a Goblins give) | That pancake minted the give (see `goblins-gift`) |
| `zig build goblins-gift` | Gifter-side three-party handoff (pancake mints; Goblins redeems) | That pancake redeemed (see `goblins-handoff`) |
| `zig build goblins-gc` | Live inbound `op:gc-exports` from Goblins after echo drops a near export | Binding finalizer GC, outbound export release, or `op:gc-answers` |
| Binding `*-goblins-interop` steps | Client direction only: keyed handshake, `enliven`/dedup, and an echo call over the C ABI | Listener, projection, or break legs; that a binding is the semantic source of truth |
| `zig build deno-goblins-listen` | Deno `Host`/`listen` publishes an actor; a Goblins vat dials it | Other bindings as listener |
| Binding `*-goblins-handoff` / `*-goblins-gift` | Binding as recipient or gifter against Goblins | Native Zig bidirectional handoff |
| Introducing-session promise proxy | In-tree Node/Host coverage for foreign-promise listen and relay | A live Goblins introducer that returns an unresolved foreign vow |
| `zig build cli-test` / `pancake` | Product CapTP shell: budgets, hang-proof dial, listen/call goldens, REPL/MCP (ADR-0084) | Suite modules, Goblins conversation, or rooms/iroh demos |

For a quick product poke on Syrup/TCP (not matrix evidence): see [`docs/cli.md`](cli.md).
Room presence is `pancake app rooms-peer` / `rooms-peer`; iroh stays on its own steps.

## Divergences and watch items

These are named in [`boundaries.md`](boundaries.md) and [`roadmap.md`](roadmap.md).
They are summarized here so they are not surprises:

- **OCapN Null.** Not modeled as a passable arm. Inventing one would not
  interop until upstream encoding and Goblins marshalling settle. Unknown
  Syrup records project as `Tagged` (Goblins break/exception leniency); that
  is not a dedicated Null refuse.
- **Set and Keyword.** The draft Model.md lists no Set container and no
  Keyword atom. Goblins marshals both over Syrup (`captp.rkt`), and pancake
  follows that wire: sets refuse duplicate elements and encode in canonical
  byte order; keywords ride the Goblins `<kw …>` record.
- **Live `op:untag`.** The in-tree responder and fixtures ship. There is no live
  Goblins marshaller yet.
- **Cap'n Proto versus Syrup.** Cap'n Proto is a second codec. Do not debug
  Goblins against Cap'n Proto bytes. Cap'n Proto handoff gives carry a
  structural peer locator (hints included); that is pancake-to-pancake
  completeness, not a Goblins parity claim.
- **Start-session locator hints.** The suite requires non-empty hints to be
  consumed, not rejected. Both codecs project entries through
  `view.BorrowedHints` (and `toOwned`); Syrup also keeps
  `acceptable_location_raw` for the signing domain.
- **`op:listen`.** Engine-synthesized V1.0 listen covers answer and promise
  projections, including promise targets named as `desc:export` (suite
  `op_listen`; ADR-0009). A live object export fulfills that export
  immediately. A bare unresolved promise export is refused
  (`InvalidReference`), because pancake exports no free-standing resolvable
  promise (ADR-0007). Third-party-backed promise exports admit CapTP-normal
  `<desc:export>` listen onto the relayed-resolution row. Home listen for
  foreign **promise** fulfills is in-tree; live Goblins proof of that
  introducer path is still open. `goblins-interop` settles via the V1.0
  resolver-callback path, and proves Goblins listening on a live pancake
  **object** export (`pancake-export-listen.rkt`). Draft CapTP sketches a
  2-operand listen; Goblins and the suite use 3-operand (`wants_partial`).
  pancake follows the suite.
- **Handshake-refusal abort does not sever.** The spec draft's `op:abort` text
  says the connection should be severed. pancake's three handshake refusals
  (invalid signature, pinned-key mismatch, version mismatch) emit the typed
  abort and keep the session negotiating (ADR-0083's named exception), so the
  same byte stream may carry a corrected hello. An engine scenario in
  `pairing_test` pins it. Every hello verifies in full, so the retry grants
  nothing a first valid hello would not; severing the transport after an abort
  is the adapter's call.
- **Settlement shape.** Draft CapTP discussion sometimes names a separate
  `op:break`; pancake CapTP v1.0 speaks Goblins resolver-callback fulfill/break.
  `pancake-next` folds fulfill/break under `op:resolve`.
- **Offers, codec, and `FeatureSet`.** Negotiated out of band
  (`Offer` / pairing / shared config). `op:start-session` carries only the
  captp-version string. Suite and Goblins interop do not prove Cap'n Proto or
  `"pancake-next"` as OCapN interop.
- **Two TCP symbols.** Live Goblins interop uses transport symbol `tcp`
  (`net.tcp`, Goblins `tcp-netlayer.rkt`). The upstream suite target uses
  `tcp-testing-only` URLs, not the Goblins parity path.
- **Cleartext TCP and keyed-tcp.** keyed-tcp pins the key holder. It does not
  encrypt the channel. Confidentiality is iroh's job.
- **Distributed GC.** Wire `gc-exports` / `gc-answers` ship (suite `op_gc`).
  Binding finalizer GC is opt-in and covers fetched far refs only. Live inbound
  export GC against Goblins is `zig build goblins-gc`.
- **Bootstrap durability.** The default is ephemeral. `durable_bootstrap` fails
  closed until an embedder store exists.
- **Handoff signature verification.** The engine verifies via an injected
  `SignatureVerifier`. Production paths use `foundation.crypto`. Test support
  exposes `testOnlyAcceptingVerifier` for in-process substrates. That is not a
  production default on an untrusted network.

## Reproduce in one sitting

`zig build check` holds the in-tree scenarios and compiles the interop drivers.
It is not a live Goblins or suite run. For that, run the sibling steps below.
Pin Goblins with `GOBLINS_VERSION` in [`.devcontainer/pins.sh`](../.devcontainer/pins.sh).

From the repository root, with submodules initialized once
(`bash conformance/bootstrap-submodules.sh`):

```sh
zig build check
zig build ocapn-conformance
zig build goblins-interop
zig build deno-goblins-listen
zig build goblins-handoff
zig build goblins-gift
zig build goblins-gc
```

Live steps need Racket with Goblins, and `uv` for the upstream suite. The
devcontainer provides them; see [`CONTRIBUTING.md`](../CONTRIBUTING.md).

## Security

Report protocol-invariant breaks privately per [`SECURITY.md`](../SECURITY.md).
