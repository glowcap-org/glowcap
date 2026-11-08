# @glowcap/web

Run an [OCapN](https://glowcap.org/protocol/) peer in a browser. A page can host
objects, call other peers, and pass references over WebRTC or WebSocket.
The protocol core runs in WebAssembly.

## Try it

Download the [browser bundle for v0.1.6](https://github.com/glowcap-org/glowcap/releases/download/v0.1.6/glowcap-web-v0.1.6-browser.tar.gz).
It includes JavaScript, matching Wasm, and a complete two-peer WebRTC example.
Extract it into a new directory your web server serves, then open `index.html`.
For a local trial with Python installed:

```sh
mkdir glowcap-web
tar -xzf glowcap-web-v0.1.6-browser.tar.gz -C glowcap-web
cd glowcap-web
python3 -m http.server 8000 --bind 127.0.0.1
```

Open `http://127.0.0.1:8000`. The page calls a greeter over a real WebRTC
connection and prints `hello world over WebRTC`. Both peers live in the same
tab, so the example exchanges signaling messages directly between them.

## Use it in a page

Keep `glowcap.js` and `glowcap_host.wasm` together in your public files.
A module script can initialize the runtime directly:

```js
import { init, relay, webrtc } from "./glowcap.js";

const web = await init({
	wasm: fetch(new URL("./glowcap_host.wasm", import.meta.url)),
});
web.host.publish("greeter", (verb, args) => {
	if (verb !== "greet") throw new Error(`unknown method: ${verb}`);
	return `hello ${args[0]}`;
});
// Use web.runtime to connect, or webrtc.listener to accept peers.
// Call await web.close() when the page finishes using its runtime.
```

The bundle exports `init` and the `relay` and `webrtc` namespaces. `init`
returns the shared [runtime API](https://jsr.io/@glowcap/runtime), plus
`web.runtime` and its `web.host`. Call `web.openRuntime()` to create another
peer in the page. Use the supplied `example.js` for a complete connection.

Serve the page over HTTPS, or localhost during development. Serve Wasm as
`application/wasm` for streaming compilation. Other binary MIME types work
with buffered loading. Keep JavaScript and Wasm from the same bundle release.

## Connecting peers

A browser needs a WebSocket gateway to reach TCP or iroh peers.
[Noise relay](https://glowcap.org/relay/) seals the session between peers so
the gateway cannot read it. An iroh gateway can read traffic and vouches for
the far peer's identity.

WebRTC needs signaling to exchange offers, answers, and network candidates.
Across machines, your application must authenticate the peer keys carried by
signaling. The [WebRTC guide](https://glowcap.org/transports/webrtc/) covers
that contract and STUN/TURN configuration.

## TypeScript source

```sh
deno add jsr:@glowcap/web jsr:@glowcap/runtime
```

JSR publishes the TypeScript source. The release bundle above is the ready-to-serve
browser build. Its [entry](https://github.com/glowcap-org/glowcap/blob/main/bindings/ts/web/browser.ts)
and [bundling configuration](https://github.com/glowcap-org/glowcap/blob/main/bindings/ts/web/browser-bundle.json)
show how contributors build it with `zig build portable-pack`.

The [browser guide](https://glowcap.org/bindings/browser/) covers transports,
callbacks, and runtime lifetime. glowcap is built with AI coding assistants,
under [maintainer direction](https://github.com/glowcap-org/glowcap/blob/main/PROVENANCE.md).
