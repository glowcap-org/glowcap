# @glowcap/webrtc

Browser-to-browser transport for the glowcap JavaScript/TypeScript runtime: a
WebRTC peer that drives the signaling exchange (offer, answer, ICE) and presents
the open `RTCDataChannel` as an opaque packet channel. The Host session's
transport profile treats each WebRTC packet as one bare CapTP codec frame.

Signaling is an OCapN capability (for example a room) and not part of this module. Two
browsers introduced by a room speak directly over a DataChannel, with the room
out of the byte path. A browser and a non-browser peer each run their own half, and the
non-browser half is the `glowcap_webrtc_*` sidecar.

```ts
import { RtcPeer } from "@glowcap/webrtc";

const peer = new RtcPeer({ offerer: true });
// Exchange createOffer / setRemoteAnswer (and ICE) through a signaling capability.
await peer.waitOpen();
const channel = peer.channel();
// Hand `channel` to @glowcap/web / the Host transport-packet seam.
```

The public surface is [`mod.ts`](mod.ts): `RtcPeer` and `rtcChannel`.
`zig build webrtc-browser-to-browser` runs two Chromium peers over one DataChannel.
