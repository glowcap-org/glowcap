# @pancake/webrtc

Browser-to-browser transport for the pancake JavaScript/TypeScript runtime: a
WebRTC peer that drives the signaling exchange (offer, answer, ICE) and presents
the open `RTCDataChannel` as a byte channel. [`@pancake/web`](../web/README.md)
runs a keyed OCapN session over that channel the same way it runs over a relay
WebSocket.

Signaling is an OCapN capability (for example a room), not this module. Two
browsers introduced by a room speak directly over a DataChannel with the room
out of the byte path. A browser and a native peer each run their own half; the
native half is the `pancake_webrtc_*` sidecar.

```ts
import { RtcPeer } from "@pancake/webrtc";

const peer = new RtcPeer({ offerer: true });
// Exchange createOffer / setRemoteAnswer (and ICE) through a signaling capability.
await peer.waitOpen();
const channel = peer.channel();
// Hand `channel` to @pancake/web / the Host byte seam.
```

The public surface is [`mod.ts`](mod.ts): `RtcPeer` and `rtcChannel`.
`zig build webrtc-browser-to-browser` holds two Chromium peers on one path.
