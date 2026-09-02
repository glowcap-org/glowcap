// The registered half of the keyed-relay rendezvous proof (ADR-0088): a
// non-listening peer that holds inbound sockets at the reference relay under
// its key designator and answers `greet` on a host-wide giftable. Every
// per-binding client cold-dials this peer's identity through the relay's
// `?rendezvous=` bridge; the keyed handshake runs end to end and the relay
// parses nothing.
//
// Headless on purpose: `serveRendezvous` is runtime-neutral stack code over
// the `WebSocket` global, so the same accept path a browser tab runs is proven
// here without a browser. Run by `harness.ts` with the relay URL as argv;
// prints `REGISTERED-PEER-READY <designator>` once the first registration is
// open and held by the relay.

import { formatLocatorUri, Host, serveRendezvous, TRANSPORT_KEYED_RELAY } from "@glowcap/runtime";

const relayUrl = new URL(Deno.args[0] ?? "");
if ((relayUrl.protocol !== "ws:" && relayUrl.protocol !== "wss:") || relayUrl.pathname !== "/relay") {
	console.error("usage: registered_peer.ts <ws-or-wss-relay-url>");
	Deno.exit(2);
}

const host = new Host();
host.publishGiftable("greeter", (verb, args) => {
	if (verb !== "greet") throw new Error(`greeter has no method ${verb}`);
	const who = typeof args[0] === "string" ? args[0] : "?";
	return `hello ${who}, cold-dialed by rendezvous`;
});

const rendezvous = serveRendezvous(
	host,
	TRANSPORT_KEYED_RELAY,
	{
		registerUrl: (id) => {
			const register = new URL("/register", relayUrl);
			register.searchParams.set("id", id);
			return register.href;
		},
		relayUrl: relayUrl.href,
	},
	{ onError: (err) => console.error("registered peer: rendezvous error:", err) },
);

await rendezvous.ready();
console.log(`REGISTERED-PEER-READY ${formatLocatorUri(rendezvous.locator)}`);
