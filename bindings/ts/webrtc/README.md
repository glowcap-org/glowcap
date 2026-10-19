# @glowcap/webrtc

Use this package to connect two peers directly over WebRTC, for example two browsers. A browser
dials and listens with `RtcPeer`, and Deno does the same through the WebRTC C library. Each keyed
session runs over one `RTCDataChannel`, with one CapTP frame per packet.

WebRTC peers cannot find each other alone. Your application supplies signaling, the exchange of
offers, answers, and network candidates that sets up the connection, usually through an OCapN
capability such as a room. Once the channel opens, bytes flow directly between the peers. The same
`SignalingAuthority` serves every side: `offer` sends an offer
and resolves with the answer, `answer` sends an answer, `candidate` sends a
local candidate, and `onCandidate` subscribes the far peer's candidates. Every
call names its exchange by id. `offer`, `answer`, and `onCandidate` also
receive a `SignalingTarget` whose `designator` names the peer, and `candidate`
takes only the id.

## Dial and listen in a browser

`connector(signaling, options?)` lets a `@glowcap/web` Runtime dial a `webrtc`
locator. `listener(host, signaling, options?)` answers offers for a Host and
advertises the Host's key as its `webrtc` locator.

```ts
import { connector, listener, locator } from "@glowcap/webrtc";

const runtime = await stack.openRuntime({ connectors: [connector(signaling)] });
const session = await runtime.connect(locator(designator));

await using answering = listener(stack.host, signaling);
answering.provideOffer(offererDesignator, offerSdp);
for await (const accepted of answering) {
	await accepted.serve();
}
```

- `provideOffer` takes the offerer's key, which the accepted session names as its authenticated
  partner. It refuses an offer when the listener is closed, the key is malformed, or too many
  accepts are in flight. A failure after it returns ends that accept and is recorded on the Host,
  where `Host.takeFailures()` reads it (see the [runtime README](../runtime/README.md#the-transports)).
- `failExchange` gives up an accept whose offerer went quiet.
- Pass `iceServers` in `options` as a list, or as a function that fetches short-lived TURN
  credentials for each connection. ICE servers help two peers find a route to each other.

The public API is [`mod.ts`](mod.ts). `zig build webrtc-browser-to-browser`
runs two Chromium peers, one dialing and one listening.

## Dial and listen from Deno

`@glowcap/webrtc/driver` is the Deno entry. `provider(signaling, config?)` lets
`runtime.connect(locator(designator))` dial a `webrtc` locator on the driver
loop. The C library makes the offer and gathers candidates, and your
`SignalingAuthority` carries them. Here a target's `introducer` is the
designator of the session that handed over the reference the dial follows, or
`null` when the application started the dial itself or accepted the peer.

```ts
import { Runtime } from "@glowcap/runtime";
import { locator } from "@glowcap/webrtc";
import { provider } from "@glowcap/webrtc/driver";

const runtime = await Runtime.open({
	providers: [provider(signaling, { iceServers: [{ urls: "stun:stun.example:3478" }] })],
});
const session = await runtime.connect(locator(designator));
```

`listen(signaling, config?, options?)` makes a Host that answers. Its
designator is the Host's own key, so a peer dials `locator(server.designator)`.
Hand each inbound offer to `server.provideOffer(designator, sdp)`. The library
answers through `signaling.answer` before the call returns, and the exchange id
it gives back names the accept for `server.failExchange(exchange)` when the
offerer goes quiet. Pass a 32-byte `seed` or an existing `host` in `options`,
never both. Iterating the server yields each accepted `Session` once its
channel opens, with the offerer's key as its authenticated partner.

```ts
import { listen } from "@glowcap/webrtc/driver";

await using server = await listen(signaling);
const exchange = server.provideOffer(offererDesignator, offerSdp);
for await (const session of server) {
	await session.serve();
}
```

The entry loads the WebRTC C library on first use (`zig build webrtc-abi`), so the browser API in
`mod.ts` never imports it. Failures behave as follows:

- A dial whose answer never arrives fails at the handshake deadline.
- When `offer` or `candidate` rejects, the dial is given up and fails at the driver's next step. The
  error is recorded on the loop's Host.
- An answer the library refuses gives the dial up the same way.
- An `answer` that throws refuses the offer, and one whose promise rejects gives the accept up.

Candidates route by exchange id, so a dial to a peer and that peer's own offer run side by side
as two exchanges in a browser and in Deno alike. When two peers dial each other at once, CapTP
keeps one of the two sessions. Your signaling object must key its candidate handlers by exchange
id and never by designator. Two peers on one machine need
`includeLoopbackCandidates: true`. `zig build deno-webrtc-driver-provider`
dials the Zig answerer and accepts the Zig offerer this way.
