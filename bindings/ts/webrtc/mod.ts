// Public @pancake/webrtc surface (ADR-0089, Milestone 2 / phase 6): a browser
// WebRTC peer. The peer drives the signaling exchange (offer, answer, ICE) and
// presents the open `RTCDataChannel` as a byte `Channel` that `@pancake/web`'s
// wasm Host runs a keyed OCapN session over, the same seam the relay's WebSocket
// channel fills. Signaling is carried by an OCapN capability (a room), not this
// module. Two browsers introduced by a room speak directly over a DataChannel
// with the room out of the byte path; a browser and a native peer each run their
// own half (the native half is the `pancake_webrtc_*` sidecar).

export { rtcChannel } from "./channel.ts";
export { RtcPeer, type RtcPeerInit } from "./peer.ts";
