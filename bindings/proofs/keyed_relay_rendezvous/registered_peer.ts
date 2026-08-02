// The registered half of the keyed-relay rendezvous proof (ADR-0088): a
// non-listening peer that holds inbound sockets at the reference relay under
// its key designator and answers `greet` on a host-wide giftable. Every
// per-binding client cold-dials this peer's identity through the relay's
// `?rendezvous=` bridge; the keyed handshake runs end to end and the relay
// parses nothing.
//
// Headless on purpose: `serveRendezvous` is runtime-neutral stack code over
// the `WebSocket` global, so the same accept path a browser tab runs is proven
// here without a browser. Run by `harness.ts` with the relay's port as argv;
// prints `REGISTERED-PEER-READY <designator>` once the first registration is
// in flight.

import { Host, serveRendezvous } from "@pancake/stack";

const relayPort = Number(Deno.args[0]);
if (!Number.isInteger(relayPort) || relayPort <= 0) {
	console.error("usage: registered_peer.ts <relay-port>");
	Deno.exit(2);
}

const host = new Host();
host.publishGiftable("greeter", (verb, args) => {
	if (verb !== "greet") throw new Error(`greeter has no method ${verb}`);
	const who = typeof args[0] === "string" ? args[0] : "?";
	return `hello ${who}, cold-dialed by rendezvous`;
});

serveRendezvous(
	host,
	(id) => `ws://127.0.0.1:${relayPort}/register?id=${encodeURIComponent(id)}`,
	{ onError: (err) => console.error("registered peer: rendezvous error:", err) },
);

console.log(`REGISTERED-PEER-READY ${host.designator()}`);
