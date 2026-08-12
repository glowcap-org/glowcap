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

export {
	type ByteSink,
	type ByteSource,
	relayBytes,
	type RelayChannel,
	type RelayConfig,
} from "./relay.ts";
export { MAX_RELAY_WEBSOCKET_MESSAGE_BYTES, webSocketChannel, webSocketRelay } from "./ws_relay.ts";
// The two far-side dials a Deno relay opens (a raw TCP socket, an iroh byte
// channel), one hardened copy each, shared by the reference relay and an
// embedding app relay.
export { denoIrohChannel, denoTcpChannel, type IrohReach } from "./deno_channels.ts";
// The cold-dial rendezvous (ADR-0088): let a peer that cannot be dialed register
// its identity and be reached through the relay by another peer.
export { isRendezvousDesignator, Rendezvous } from "./rendezvous.ts";
