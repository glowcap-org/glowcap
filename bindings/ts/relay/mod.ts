// @pancake/relay — the byte-transparent relay a pancake embedder runs to carry a
// keyed CapTP session for a peer that cannot open a socket itself (a browser).
//
// The relay never parses frames and never holds a capability: the keyed
// handshake and session authority ride through end to end (ADR-0086). `relayBytes`
// is the transport-agnostic pump; `webSocketRelay` adapts an upgraded WebSocket
// (the browser's byte pipe) to it. A caller supplies the far-side dial — iroh's
// `dialLocatorForRelay` (@pancake/iroh) or a plain socket connect — and its own
// policy for which targets may be dialed.
//
//   import { webSocketRelay } from "@pancake/relay";
//   webSocketRelay(socket, () => dialLocatorForRelay(locator, reach), reason, config);

export { type ByteSink, type ByteSource, relayBytes, type RelayChannel, type RelayConfig } from "./relay.ts";
export {
	MAX_RELAY_WEBSOCKET_MESSAGE_BYTES,
	RelayDialFailed,
	relayFailureLogger,
	webSocketChannel,
	webSocketRelay,
} from "./ws_relay.ts";
// The two far-side dials a Deno relay opens (a raw TCP socket, an iroh byte
// channel), one hardened copy each, shared by the reference relay and an
// embedding app relay.
export { denoIrohChannel, denoTcpChannel, type IrohReach } from "./deno_channels.ts";
// The cold-dial rendezvous (ADR-0088): let a peer that cannot be dialed register
// its identity and be reached through the relay by another peer.
export { isRendezvousDesignator, Rendezvous } from "./rendezvous.ts";
export {
	connector,
	installProvider,
	type NativeTrust,
	type NativeTrustSummary,
	provider,
	type RelayOptions,
} from "./transport.ts";
export { dialUrl, routeFromLocator } from "./route.ts";
export { listenKeyed, listenNoise, type RelayListenOptions } from "./listen.ts";

import { keyed as keyedRoute, noise as noiseRoute } from "./route.ts";
import { listenKeyed as listenKeyedProfile, listenNoise as listenNoiseProfile } from "./listen.ts";

/** The identity-addressed cleartext relay profile: locator and registered
 * accept. */
export const keyed = {
	...keyedRoute,
	listen: listenKeyedProfile,
};

/** The Noise_XK-sealed relay profile, the same way. */
export const noise = {
	...noiseRoute,
	listen: listenNoiseProfile,
};

/** This package's two profiles, in its own words (`ProfileInfo`). */
export const profiles = [
	{
		transport: "keyed-relay",
		summary:
			"Held sockets registered at a WebSocket relay, in the clear; peers reach this peer through the relay without it opening a port.",
		reference: "",
		referenceName: "",
		takes: [{ name: "relay", kind: "url", hint: "" }],
	},
	{
		transport: "noise-relay",
		summary: "The same relay pipe with the Noise_XK seal over it; the relay forwards only ciphertext.",
		reference: "https://noiseprotocol.org/",
		referenceName: "Noise",
		takes: [{ name: "relay", kind: "url", hint: "" }],
	},
] as const satisfies readonly import("@pancake/runtime/transport").ProfileInfo[];
