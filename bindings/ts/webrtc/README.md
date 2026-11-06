# @glowcap/webrtc

Connect [OCapN](https://glowcap.org/protocol/) peers over WebRTC. Each keyed
session runs over one ordered, reliable DataChannel. Browsers use the browser
WebRTC API. Deno uses the WebRTC library included in glowcap's C SDK.

## Try it in a browser

The [browser bundle](https://github.com/glowcap-org/glowcap/releases/download/v0.1.4/glowcap-web-v0.1.4-browser.tar.gz)
contains prebuilt JavaScript, Wasm, and a complete WebRTC example. Extract it,
serve its directory, and open `index.html`. The
[browser package](https://jsr.io/@glowcap/web) has the commands.

`example.js` defines both peers, their signaling, and a greeter call. Its
signaling stays inside one page. A real application supplies signaling over
an authenticated channel, such as an existing CapTP session.

## Add WebRTC to your application

```sh
deno add jsr:@glowcap/webrtc jsr:@glowcap/runtime jsr:@glowcap/web
```

This browser helper takes your signaling implementation and matching Wasm as
explicit inputs. It returns one runtime and a listener using that runtime's
Host. Close both when your application stops.

```ts
import { init, type WasmSource } from "@glowcap/web";
import { connector, listener, type SignalingAuthority } from "@glowcap/webrtc";

export async function openPeer(wasm: WasmSource, signaling: SignalingAuthority) {
	const web = await init({ wasm, connectors: [connector(signaling)] });
	return {
		runtime: web.runtime,
		answering: listener(web.runtime.host, signaling),
	};
}
```

For Deno, run with `deno run --allow-all app.ts`. The C SDK downloads on
first use. The [runtime installation guide](https://jsr.io/@glowcap/runtime#install)
lists prerequisites. Use `provider` from `@glowcap/webrtc/driver` in
`Runtime.open({ providers: [provider(signaling)] })`. Its `listen(signaling)`
function opens an answering peer. Deno peers on the same machine need
`includeLoopbackCandidates: true` in the provider and listener configuration.

## Signaling and ownership

`SignalingAuthority` carries offers, answers, and network candidates. `offer`
resolves with the answer. `answer` and `candidate` send messages, while
`onCandidate` subscribes to remote candidates. Route candidates by exchange
ID, including candidates that arrive before their subscriber exists.

Pass authenticated incoming offers to `answering.provideOffer(peerKey, sdp)`.
Iterating the listener yields accepted sessions. Serve each session and
close it when finished. Use `failExchange` to cancel an accept whose offerer
went quiet. A refusal after `provideOffer` returns is recorded on the Host,
where `Host.takeFailures()` reads it.

The peer key is an authority claim, so signaling must bind that key to the
party sending the offer. Across networks, pass `iceServers` to the browser
connector and listener. It accepts a list or a function that fetches fresh
STUN/TURN configuration for each connection.

The [WebRTC guide](https://glowcap.org/transports/webrtc/) and
[API reference](https://jsr.io/@glowcap/webrtc/doc) cover the full contract.
glowcap is built with AI coding assistants under
[maintainer direction](https://github.com/glowcap-org/glowcap/blob/main/PROVENANCE.md).
