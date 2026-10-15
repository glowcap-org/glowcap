// Public @glowcap/webrtc surface (ADR-0089): a browser
// WebRTC peer. The peer drives the signaling exchange (offer, answer, ICE) and
// presents the open `RTCDataChannel` as an opaque packet channel. Signaling is
// carried by an OCapN capability (a room), not this module. Two browsers
// introduced by a room speak directly over a DataChannel with the room out of
// the byte path; a browser and an FFI peer each run their own half.

import type { Locator } from "@glowcap/runtime";
import { TRANSPORT_WEBRTC } from "@glowcap/abi";

/** Build the hint-free locator for a WebRTC peer's keyed identity. */
export function locator(designator: string): Locator {
	return {
		transport: TRANSPORT_WEBRTC,
		designator,
		hints: new Map(),
		hintWireForm: "boolean-false",
	};
}

export { rtcChannel } from "./channel.ts";
export { connector } from "./connector.ts";
export { acceptRemoteCandidate, type PeerOptions, type SignalingAuthority, type SignalingTarget } from "./exchange.ts";
export { type Listener, listener } from "./listener.ts";
export { RtcPeer, type RtcPeerInit } from "./peer.ts";
