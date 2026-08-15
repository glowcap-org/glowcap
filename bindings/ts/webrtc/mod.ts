// Public @pancake/webrtc surface (ADR-0089, Milestone 2 / phase 6): a browser
// WebRTC peer. The peer drives the signaling exchange (offer, answer, ICE) and
// presents the open `RTCDataChannel` as a byte `Channel` that `@pancake/web`'s
// wasm Host runs a keyed OCapN session over, the same seam the relay's WebSocket
// channel fills. Signaling is carried by an OCapN capability (a room), not this
// module. Two browsers introduced by a room speak directly over a DataChannel
// with the room out of the byte path; a browser and a native peer each run their
// own half (the native half is the `pancake_webrtc_*` sidecar).

import type { Locator } from "@pancake/runtime";
import { TRANSPORT_WEBRTC } from "@pancake/abi";

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
export { acceptRemoteCandidate, connector, type SignalingAuthority } from "./connector.ts";
export { RtcPeer, type RtcPeerInit } from "./peer.ts";
