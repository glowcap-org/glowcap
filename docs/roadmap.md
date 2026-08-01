# Remaining work

This page contains unfinished work only. [What ships](shipped.md) covers the
present, [known limitations](boundaries.md) covers their consequences, and
[the ladder](ladder.md) tracks progress toward 1.0.

The sections follow dependency rather than priority. Work waiting on another
project comes first; work pancake can finish by itself comes later.

## Capability identity closure

The order below is a dependency, not a menu. ADR-0099, ADR-0098 steps 1–2,
one Vat per Host, exact-target gifts, and the capability-handle ABI migration are
green.

- **Finish the native owning capability facade.** The C ABI, Wasm, and language
  bindings expose only opaque Host-scoped identities. Several native
  `driver.Session` convenience verbs still accept actor or wire references.
  Finish ADR-0096 by moving those verbs onto the same Host identity boundary.
- **Unpublish host-wide aliases.** A Host can publish or replace an alias but
  cannot remove it. Add the alias-removal API first: removal changes discovery
  only, while issued references and deposited gifts keep the exact actor. Its
  scenario is a prerequisite for the evidence item below.
- **Define actor roots and reclaim unreachable Host actors.** Local actor boxes
  currently live until Host teardown even after their last opaque capability
  row disappears. Specify roots across aliases, exact gifts, Port projections,
  queued turns, and application retains; then collect without letting session
  closure impersonate actor ownership.
- **Close the exact-gift evidence matrix.** The production Host proves that a
  mutated deposited actor survives alias replacement and withdrawal over a
  second exporter Port, including state changed through the first Port and
  observed through the second. Add the remaining unnamed-target, cross-Port
  `become`, unpublish, binding, and live Goblins mutation cases required by
  ADR-0096.
- **Durable publication namespace.** Finish
  [ADR-0098](decisions/adr/ADR-0098-sturdyref-peer-authority.md): retain the
  authority checks above, then split mutable aliases from randomly minted
  durable swiss names with a reserved versioned namespace.
- **Per-session CapTP identity, after upstream alignment.** Follow
  [ADR-0097](decisions/adr/ADR-0097-captp-session-identity-attestation.md) last.
  Draw a fresh signing key for every connection and keep durable peer identity
  separate. Expose iroh's authenticated endpoint id and WebRTC's
  capability-authorized DTLS binding. Replace the equality pin for keyed-TCP
  and keyed-relay only after the locator-hints shape has an upstream proposal
  and the live foreign decode evidence can pass.

## Waiting on upstream

- **OCapN Null.** Goblins does not marshal Null, and its upstream encoding is
  unsettled. Once those agree, add the model arm, codec round trips, and a live
  Goblins check. Until then, unknown Syrup records remain tagged values.
- **Live `op:untag`.** The responder and fixtures ship, but Goblins has no live
  marshaller for the operation. Add the outside-peer check when it does.
- **`op:listen` arity.** The draft shows two operands; Goblins and the upstream
  suite use a third, `wants_partial`. pancake follows the working
  implementations. The checked discrepancy lives in
  [the findings corpus](../conformance/ocapn-findings/README.md).
- **Locator hints type.** The draft describes hints as a mapping, while the
  pinned Goblins constructor accepts only false or a string. The checked
  discrepancy lives beside the `op:listen` finding. Resolve that boundary
  before a credential-bearing locator is an interoperability claim.
- **Settlement encoding.** Draft discussion sometimes names a separate
  `op:break`. Goblins CapTP 1.0 uses resolver-callback fulfill and break, while
  the pancake-native profile carries both under `op:resolve`. Revisit the
  native profile when the specification and Goblins converge.
- **Goblins over iroh.** The pancake iroh transport is complete enough for
  native peers and bindings, but Goblins ships no iroh netlayer. Extend the
  live interop checks if that changes.
- **Native Zig QUIC.** pancake uses iroh rather than implementing QUIC. The
  decision reopens when iroh's protocols stabilize and a production Zig QUIC
  stack exists ([ADR-0055](decisions/adr/ADR-0055-iroh-netlayer-sidecar.md)).

## Platforms and reachability

- **Windows and IOCP.** There is no Windows runtime check or IOCP backend.
  Windows support needs the backend behind the existing completion-loop
  contract, then live tests and release artifacts.
- **macOS runtime CI.** The kqueue path is cross-compiled on every push but
  never executed. A macOS runner closes this gap.
- **Cold-dialing browsers.** Browser-to-browser dial works through one shared
  relay. Native-to-browser dial needs a native rendezvous adapter. Cross-relay
  dial needs locators that carry a usable route as well as the peer identity
  ([ADR-0088](decisions/adr/ADR-0088-fully-functioning-browser-peer.md)).
- **Standalone WebRTC dial.** WebRTC works after signaling has opened a
  DataChannel. A bare `webrtc` locator still has nowhere to send its offer.
  Closing that gap needs a rendezvous the Host can reach without already
  holding a signaling capability. The endpoint already multiplexes peers through
  one readiness fd; what remains is the generic Host adapter which consumes those
  events and owns signaling-aware session adoption. Until that adapter exists,
  pancake does not claim WebRTC handoff redemption: the existing live checks
  prove signaling and an ordinary keyed session after the channel opens
  ([ADR-0089](decisions/adr/ADR-0089-webrtc-datachannel-netlayer.md)).

## Scale and release

- **A live 500,000-session measurement.** The core and host have checked memory
  budgets, and the TCP and iroh loops serve many connections. The target is not
  achieved until a live run at that scale records its machine, command, memory,
  and result in [the ladder](ladder.md).
- **Published C archives.** `zig build release-pack` and the release workflow
  exist, but no versioned assets are live. Publication requires green packages
  for every target, the `releases_published` switch in
  [`bindings/c-abi-resolve.json`](../bindings/c-abi-resolve.json), and a
  cold-cache smoke against the real release URL. The full checklist is in the
  [packaging guide](../bindings/PACKAGING.md#publishing-c-archives-flip-checklist).

## Product work

- **griddle and ocapnviz.** `pancake griddle` reserves the command name, but the
  deterministic simulator does not exist. ocapnviz, the browser viewer for its
  protocol timeline, is also unbuilt. They should share one timeline schema
  rather than grow a second CapTP stack
  ([plan](planning/observability-family.md)).
- **A2A over CapTP.** The proposed agent-to-agent facade composes the existing
  Host and session verbs; it adds no new wire semantics. It remains a design,
  not a product surface
  ([plan](planning/pancake-a2a-on-captp-design.md)).

## Protocol cleanup

- **Typed reserved position ranges.** Import and answer positions are distinct
  types, but two sub-ranges inside them are still separated by arithmetic:
  imports at and above 2^60 are reserved for handoff tokens, and answers at and
  above 2^63 for engine-generated answers. Inbound values in either band are
  refused, so this fails closed today. ADR-0091 proposes classifying each range
  once where a wire integer becomes a position; the migration is not scheduled
  ([ADR-0091](decisions/adr/ADR-0091-reserved-position-bands.md)).
