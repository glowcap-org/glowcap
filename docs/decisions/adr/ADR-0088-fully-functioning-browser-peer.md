---
id: ADR-0088
status: accepted
date: 2026-07-20
tags: [browser, wasm, peer, relay, rendezvous, handoff]
decision: "A browser tab is a first-class OCapN peer. It dials, hosts objects, answers calls, and holds a bidirectional capability graph over every session it opens, including replying to a caller that cannot itself be dialed. The one capability a browser genuinely cannot have on its own is being cold-dialed by a stranger: a browser opens no listening socket, so a third party that names the browser as an exporter reaches it only through a relay rendezvous. Everything else is relay-less or relay-optional, and this ADR states which is which, with the hard reason for each, and names what is built versus what remains."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0113]
---

# ADR-0088 Fully functioning browser peer

## Decision

A browser tab is a first-class OCapN peer. It dials, hosts objects, answers
calls, and holds a bidirectional capability graph over every session it opens,
including replying to a caller that cannot itself be dialed. The one capability
a browser genuinely cannot have on its own is being cold-dialed by a stranger: a
browser opens no listening socket, so a third party that names the browser as an
exporter reaches it only through a relay rendezvous. Everything else is
relay-less or relay-optional, and this ADR states which is which, with the hard
reason for each, and names what is built versus what remains.

This ADR builds on the browser binding
([ADR-0070](ADR-0070-browser-binding-via-wasm.md)) and the byte-transparent
relay ([ADR-0086](ADR-0086-byte-transparent-relay.md)). It settles the
peer-completeness question those two leave open: given that a browser can hold a
keyed session and run a wasm Host, what does it take for the browser to be a
*full* peer, and where is the honest floor?

## What "fully functioning peer" means

An OCapN peer is not a client. A peer originates and receives capability
invocations symmetrically once a session exists, regardless of which side dialed.
The browser must therefore hold every one of these, and does:

1. **Dial a native server and run the keyed handshake end to end.** The browser
   cannot open a socket, so its bytes ride a WebSocket to a byte-transparent
   relay that forwards them to the target (`ADR-0086`). The handshake is
   signature-verified end to end; the relay never holds a capability. *Relay-
   necessary* on the transport, because only the relay can carry the browser's
   bytes onto the network — a hard platform limit, not a design choice. Built:
   `zig build rooms-web-page` drives the whole page as a browser peer.

2. **Host objects and answer inbound calls over a session it opened.** A native
   partner invokes a capability the browser exported and the wasm Host serves
   it. *Relay-less in substance:* the invocation rides the already-open session;
   the relay only moved the bytes of a session the browser itself opened. Built:
   `rooms-web-page` proves the native room calls back the browser's subscribe
   inbox.

3. **Reply to a caller on the connection the call arrived on, even when the
   caller never listens.** This is the crux of bidirectionality. A capability
   the browser hosts must be able to answer its caller without dialing back —
   because the caller may be another browser, or any peer behind a NAT. Built,
   and described in the next section.

4. **Redeem a three-party handoff and reach the introduced exporter directly.**
   The browser asks a room to introduce it to a member, redeems the
   `desc:handoff-give`, and dials the member over the relay's iroh path, with the
   room out of the message path. *Relay-necessary on the transport* (same byte-
   carrier reason as (1)); relay-less in the capability sense (the room never
   relays the DM). Built: `zig build rooms-web-dm` drives it from a real
   Chromium.

5. **Be cold-dialed by a peer that names the browser as an exporter.**
   The one capability with no relay-less form. A browser opens no listening
   socket — no TCP accept, no inbound QUIC — so a peer that holds a give naming
   the browser cannot open a fresh connection to it. It reaches the browser only
   if an intermediary already holds the browser's inbound socket and bridges the
   dial to it: a relay rendezvous keyed by the browser's identity. *Relay-
   necessary and irreducibly so.* Built for any peer on a shared relay:
   `zig build rooms-web-dm-tabs` drives one browser tab cold-dialing another by
   identity through the relay rendezvous, and `zig build rooms-web-dm-native`
   drives a native Deno peer cold-dialing the tab through the same leg. A
   redeemer on a *different* relay is not yet built, for the honest reason the
   cold-dial section below records.

Capabilities 1–4 make the browser a full peer for every session it opens.
Capability 5 is the reachability of a *listener*, which a browser is not; the
relay rendezvous is how a non-listener still gets named and reached.

## The reply primitive: a giftable answers its live caller

A capability published with `Host.publishGiftable` is bound to no single session
— the same object answers calls arriving on every connection, which is exactly
what a gifted `dm` inbox needs. But that unbound-ness is also why such an object
could not, before this ADR, reply to its caller: a `Session.spawn` actor closes
over its one connection, while a giftable has none to close over. The trampoline
gave a giftable's turn a null session, so the object had no way to name the
connection its call arrived on.

The fix is the ambient the turn already carries. The pump brackets the one
synchronous call a behavior fires inside — the inbound feed — with the arriving
`Session`, and a giftable's turn inherits it. A hosted object reads it through
`currentSession()`:

```ts
// The name is illustrative; the rooms app publishes one inbox per peer.
host.publishGiftable(inboxName, (verb, args) => {
	const [text, reply] = args; // `reply` is a Ref the caller passed
	const session = currentSession(); // the session this call arrived on
	if (session && reply instanceof Ref) {
		session.send(reply, "dm", [`re: ${text}`]); // answer over that session
	}
});
```

The reply rides the session the caller opened, so the caller never has to be
dialable. This is the receiver half of full bidirectionality, and it is C-ABI-
neutral TypeScript in the shared stack, so it covers both the browser (wasm
Host) and every native runtime (Deno, Bun) that runs the same `trampoline.ts`.
Built and proven: `zig build demo-rooms-dm-reply` stands a non-listening caller
up against a giftable that replies over the arriving session, asserting the
reply lands and that the giftable's host accepted exactly one session — no
dial back.

## The reply capability must ride the session it answers on

The reply above works because the reply capability the caller hands over is
hosted on the very session the call travels on. That is a real constraint, not
an accident, and it is the sharp edge of the redeemed-handoff case.

An OCapN near reference names an export position on one specific session's peer.
A raw model send still fails closed rather than writing that position onto a
different session. Owning Host values now take the sender-side completion from
ADR-0116: a foreign object becomes a signed inline give whose delayed
transaction retains the capability until publication. The raw refusal remains
the correct lower-tier contract; it is no longer a binding limitation.

**The completion, now shipped: surface the redeemed direct session.** A
three-party-handoff give is redeemed *eagerly* — the moment the introduce
answer's give resolves, the node stages the exporter dial, so the direct
exporter session is born while the introduce send is still in flight, before the
send's reply settles. `Session.sendRedeeming` awaits the introduce reply and
returns both it and the direct exporter `Session` (`via`) the redeemed route
routes to. The application hosts its reply inbox on `via` and sends the DM over
`via`, so the reply capability is a valid near export in the session the
redeemed route points to, and the member answers over that session's connection
with no dial back.
`via` is resolved from the reply's own token, not from watching which dial ran
during the send: `pancake_host_reference_exporter` maps the redeemed route to
the exporter session the node's routing table already holds. That makes the
attribution deterministic — it is correct with several redeems in flight at
once, and it resolves the exporter even when the reply reused a session a prior
redeem already dialed, a case that runs no fresh dial for a
which-dial-ran heuristic to observe. The rooms client's `DirectMessage`
opens on `via` and surfaces the member's replies; the browser renders them.
Built and proven end to end: `zig build rooms-web-dm` (a real Chromium sends a
DM and renders the member's reply) and its native, Chromium-free sibling
`zig build demo-rooms-dm-back`.

The route not taken (**cross-peer re-export of a locally hosted argument** — the
core re-exporting a near argument on the routed exporter peer instead of
refusing it) stays rejected: it moves a real cross-session decision into the
routing core for no gain over surfacing the session the application can host on
directly.

## Cold-dial: the relay rendezvous

Capability 5 — a third party cold-dialing the browser — has one shape, because a
browser cannot accept a connection. The relay must be the browser's inbound
address:

1. The browser opens a WebSocket to the relay and **registers** under its own
   keyed identity (the designator a `keyed-tcp` / iroh locator would name). The
   relay holds that socket in a rendezvous table keyed by identity. This is a
   new relay verb over the existing WebSocket, not a new transport.
2. The browser advertises a **relay-backed locator** for its giftables: a
   locator whose transport names the relay and whose designator is the browser's
   identity. A room that introduces the browser hands this locator on in the
   give.
3. A native peer redeeming that give **dials the relay locator**. The relay
   looks the identity up in its rendezvous table and bridges the native dial's
   bytes to the held browser socket — a second byte-transparent leg, the mirror
   of the browser-dials-native leg (`ADR-0086`). The keyed handshake then runs
   end to end between the native peer and the browser, through two relay legs,
   with the relay blind to both.

This stays inside `ADR-0086`'s contract: the relay still only moves opaque
bytes, still holds no capability, still parses no frame. What is new is the
rendezvous table (identity → held inbound socket) and the registration verb, and
the admission policy that governs which identities may register and be dialed —
app policy, above pancake, exactly as target admission already is. Backpressure,
idle reclaim, and the byte cap apply to a bridged pair unchanged.

A subtlety the crossed hellos force: the accept side sends its own signed
`op:start-session` the instant its socket opens, before any dialer bridges onto
it. So the relay buffers a held socket's inbound from the moment of registration
(`Rendezvous.register` wraps it as a buffering channel at once), and the browser
accept side waits for its register socket to open before it writes that hello.
Without both, the accept side's hello is dropped and the dialer waits forever.

**Registration admission is app policy, like the dial allow-list.** The relay is
byte-transparent, so it cannot verify that a registrant holds the private key for
the identity it registers. The keyed handshake still blocks impersonation — a
squatter that registered someone else's designator cannot complete the handshake,
so it can never *be* that peer. What a squatter can do is flood an identity's
registration queue, an availability lever the embedder governs exactly as it
governs which targets may be dialed. The rooms relay bounds it with a total
registration cap; a per-identity cap or a signed-challenge admission is the next
step a hardened deployment adds above pancake.

The honest limits, all recorded so they are not mistaken for gaps to close
silently:

- **Presence, not a mailbox.** A browser's registration lives only while its tab
  and WebSocket live, so a relay-backed locator is reachable only while the
  browser is present; it stores no messages for an absent browser. A held
  registration also carries its own liveness bound: the relay pings it and
  reclaims it if no pong lands within the idle timeout, so a browser that died
  without a clean close (a slept phone, a dropped network) never lingers as false
  presence a dialer would bridge onto and hang.
- **The locator separates identity from route.** The designator remains the
  browser's durable key. A `rendezvous-relay` string hint carries provider-owned
  route advice, so a dialer can reach a peer registered at a different relay.
  The route does not become peer identity and is not covered by the keyed
  handshake's target claim. A bare locator still uses deployment-local relay
  configuration.
- **The dialer needs locator route advice or a configured fallback.** The core
  classifies a `keyed-relay` locator as the `rendezvous` dial shape
  (`PANCAKE_DIAL_SHAPE_RENDEZVOUS`), and a binding's dial executor answers it
  by opening the WebSocket rendezvous leg the dialing host was configured
  with: `Host.setRendezvousUrl` in the TypeScript stack (browser or native,
  because `WebSocket` is a web-standard global), `Host.rendezvous_url` in the
  Python binding (the optional `websockets` extra), `set-host-rendezvous-url!`
  in the Racket binding (`net/rfc6455`), `Host::set_rendezvous_url` in the
  Rust binding, and natively the relay provider archive. Every binding prefers
  the locator hint and uses its Host mapping only when the hint is absent. A
  host with neither fails loud. `zig build bindings-keyed-relay-rendezvous`
  proves all four bindings and the installed CLI against a dead fallback. The
  same provider serves registration, so a native process with no listening
  socket can publish the complete routed locator too. Native scale embeddings
  can also put outbound keyed-relay
  rendezvous on `net.KeyedRelayLoop`, where TCP connect, WebSocket upgrade,
  control frames, reads, masked writes, and close are completion-backend state
  rather than a blocking resident dial. That adapter lends ordinary inbound
  payload directly from the platform's shared recv pool; only parser fragments
  and a coalesced next-frame tail enter its bounded spill, so a warmed relay
  session does not retain one platform-sized read buffer. Outbound writes keep
  the Loop-owned byte slice borrowed through one completion and mask one bounded
  FIN binary message at a time; WebSocket message boundaries remain invisible
  to the byte stream, and Ping/Close controls run between chunks. The
  generic provider carries both dial and registration through one endpoint
  runtime.
- **The relay is on the inbound path.** A deployment that does not trust its relay
  runs TLS to it and keeps the keyed CapTP end to end on top, as `ADR-0086`
  already prescribes.

**Status:** built for same-relay and cross-relay dialers. `zig build
rooms-web-dm-tabs` proves the browser-to-browser form (two tabs: one registers
its identity, the other redeems a room introduction by cold-dialing it, the
keyed session opens tab-to-tab through the relay off-room, and a reply rides
back over the arriving connection). `zig build rooms-web-dm-native` proves the
native form: a Deno peer on the dlopen stack redeems a room introduction and
cold-dials the tab. `zig build bindings-keyed-relay-rendezvous` proves each
native binding follows the locator's route instead of its dead local mapping.

## Status and proof matrix

| Capability | Relay posture | Status | Proof |
| --- | --- | --- | --- |
| Dial + keyed handshake | necessary (byte carrier) | shipped | `rooms-web-page` |
| Host + answer inbound over an open session | substance relay-less | shipped | `rooms-web-page` |
| Reply to a non-listening caller (giftable) | relay-less | shipped | `demo-rooms-dm-reply` |
| Redeem handoff + direct DM to a member | necessary (byte carrier) | shipped | `rooms-web-dm` |
| Redeemed-introduction back-channel reply | relay-less | shipped | `rooms-web-dm`, `demo-rooms-dm-back` |
| Cold-dialed by another browser (shared relay) | necessary (rendezvous) | shipped | `rooms-web-dm-tabs` |
| Cold-dialed by a native peer (shared relay) | necessary (rendezvous) | shipped | `rooms-web-dm-native` |
| Cold-dialed across relays | necessary (rendezvous) | shipped | `bindings-keyed-relay-rendezvous` |

## Alternatives Considered

**Declare the browser a client, not a peer.** Rejected: the browser already
answers inbound calls and redeems handoffs over sessions it opens; calling it a
client would misname a capability it demonstrably holds. The only true gap is
listener reachability, which the rendezvous names precisely.

**Make the relay a CapTP proxy so it can route inbound to the browser.** Rejected
for the same reasons `ADR-0086` rejected a proxy: it would parse frames, hold
capabilities, and couple the relay to the CapTP version. The rendezvous stays
byte-transparent — it matches an identity to a held socket and forwards bytes.

**Reply by dialing the caller back.** Rejected: it assumes the caller listens,
which is exactly what a browser (and any NAT'd peer) does not. Replying over the
arriving connection is the only form that works for a non-listening caller, and
it is what `currentSession()` enables.

## References

- Browser binding and wasm Host: [ADR-0070](ADR-0070-browser-binding-via-wasm.md).
- Byte-transparent relay contract: [ADR-0086](ADR-0086-byte-transparent-relay.md).
- Reply primitive: `currentSession()` in `bindings/ts/runtime/session.ts`, the
  arriving-session ambient in `bindings/ts/runtime/trampoline.ts` and
  `bindings/ts/runtime/pump.ts`; proof `apps/rooms/demos/dm_reply_demo.ts`.
- Redeemed-session surfacing: `Session.sendRedeeming` resolving `via` through
  `Host.exporterFor` (`bindings/ts/runtime/session.ts`, `bindings/ts/runtime/host.ts`),
  and the same verb in every other binding: `send_redeeming` in
  `bindings/rust/src/session.rs` and `bindings/python/pancake/_session.py`,
  `session-send-redeeming` in `bindings/racket/private/session.rkt`
  over the `pancake_host_reference_exporter` query, which the core answers with
  `Node.exporterPeerFor` / `Host.exporterSessionFor` from its routing table
  (`src/ocapn/engine/node.zig`, `src/driver/core/host.zig`,
  `src/c_abi/host/host.zig`); the rooms client's `DirectMessage`
  (`apps/rooms/lib/room_client.ts`); proofs `apps/rooms/demos/dm_back_demo.ts`
  (native), `apps/rooms/test/dm_reredeem_test.ts` (deterministic re-redeem
  attribution), and `apps/rooms/test/web_dm_test.ts` (browser).
- Cold-dial rendezvous: `Rendezvous` (identity → held buffering channel) and
  `webSocketChannel` in `@pancake/relay` (`bindings/ts/relay/rendezvous.ts`,
  `bindings/ts/relay/ws_relay.ts`); the accept side `serveRendezvous` and the
  shared WebSocket byte channel, runtime-neutral in the stack
  (`bindings/ts/runtime/rendezvous.ts`, `bindings/ts/runtime/websocket.ts`); the
  dial executor's `keyed-relay` intercept (`bindings/ts/runtime/dial.ts`) over
  the host's configured mapping (`Host.setRendezvousUrl`,
  `bindings/ts/runtime/host.ts`); the resident-less `keyed-relay` transport
  symbol (`src/ocapn/model/transport.zig`, `src/driver/core/vocab.zig`); the
  rooms relay endpoints and rooms UI wiring (`apps/rooms/web/relay.ts`,
  `apps/rooms/web/serve.ts`, `apps/rooms/web/ui/net.ts`); proofs
  `apps/rooms/test/web_dm_tabs_test.ts` (`zig build rooms-web-dm-tabs`) and
  `apps/rooms/test/web_dm_native_dial_test.ts`
  (`zig build rooms-web-dm-native`).
- Cross-runtime route proof: `bindings/proofs/keyed_relay_rendezvous/`, run by
  `zig build bindings-keyed-relay-rendezvous`; native registration proof:
  `zig build zig-keyed-relay-register`.
