// The browser side of the iroh-relay proof, bundled through
// `browser-bundle.json` so its module graph is exactly a page's: the wasm
// peer, the runtime, and `@glowcap/iroh` mapped to the browser arm, with no dlopen
// anywhere. It dials the iroh locator through the ordinary `connect`, which
// lands in the browser arm's `_connectIroh` and rides the relay named by
// `init({ relayUrl })`. Argv: <wasm-path> <relay-port> <ocapn-uri>.

import { init } from "@glowcap/web";

const [wasmPath, relayPort, uri] = Deno.args;
if (!wasmPath || !relayPort || !uri) {
	console.error("usage: iroh_relay_probe <wasm-path> <relay-port> <ocapn-uri>");
	Deno.exit(2);
}

const runtime = await init({
	wasm: await Deno.readFile(wasmPath),
	relayUrl: (locator) => `ws://127.0.0.1:${relayPort}/relay?locator=${encodeURIComponent(locator)}`,
});

// The relay owns native iroh reachability; the browser Runtime owns the
// explicit byte connector selected at init.
const session = await runtime.connect(runtime.parseLocator(uri));
const greeter = await session.fetch("greeter");
const reply = await session.send(greeter, "greet", ["browser"]);
const expected = "hello browser over iroh relay";
if (reply !== expected) {
	console.error(`FAIL: expected "${expected}", got "${String(reply)}"`);
	Deno.exit(1);
}
console.log("IROH-RELAY-PROBE-OK");
await session.close();
Deno.exit(0);
