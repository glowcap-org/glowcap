# @glowcap/relay

The byte-transparent relay a glowcap embedder runs so a peer that cannot open a socket itself, such
as a browser, can hold a CapTP session with another peer. The relay forwards the raw session bytes
without parsing them, so the keyed or Noise handshake and session authority run end to end and the
relay holds no capability. The contract every runtime's relay obeys is
[ADR-0086](../../../docs/decisions/adr/ADR-0086-byte-transparent-relay.md). This package is its
TypeScript implementation.

## The five parts

A relay in any runtime is assembled from five pieces. This package ships the pump and WebSocket
wiring, which work across JavaScript runtimes. The embedder supplies the other three pieces.

1. **A raw byte channel** to the target: `read() → Uint8Array | null`,
   `write(bytes) → Promise<void>`, and `close() → Promise<void>`. Calling `close` more than once is
   safe. For an iroh target, `@glowcap/iroh` supplies the channel through
   `dialLocatorForRelay`. A TCP target uses the runtime's own socket. One channel request makes one
   dial attempt. Retry belongs to the
   embedding application's connection lifecycle.
2. **The pump**, `relayBytes(source, sink, channel, config, closeSource)`: moves bytes between the
   two legs with an idle timeout, a byte cap, and awaited-write backpressure. If either leg fails,
   it closes both before returning and preserves any close error alongside the first I/O error.
3. **A WebSocket adapter**, `webSocketRelay(socket, getChannel, dialFailReason,
   config, options?)`: wires
   an accepted WebSocket to the pump. It buffers the browser's first handshake bytes while the
   target connection opens, bounds that queue, and slows outbound reads when the
   socket's send buffer. The embedder supplies the accepted socket from its own HTTP server.
4. **A dial dispatcher** from the embedder. This reference opens a socket for `?to=host:port` and an
   iroh channel for `?locator=<uri>`. It loads iroh only for the locator path. The production Rooms
   relay uses `glowcap_host_plan_dial` instead so its target allow-list and dial plan cannot disagree
   (ADR-0086).
5. **Config:** `{ idleTimeoutMs, maxBytesPerSession }`. The embedding app separately decides which
   targets it permits.

## Usage

```ts
import { BINDING_RELAY_IDLE_TIMEOUT_MS, BINDING_RELAY_MAX_BYTES_PER_SESSION } from "@glowcap/abi";
import { webSocketRelay } from "@glowcap/relay";
import { dialLocatorForRelay, Reachability } from "@glowcap/iroh";

// Inside the runtime's WebSocket-upgrade handler, once the app has admitted the
// target, hand the accepted socket and a far-side dial to the pump:
webSocketRelay(
	socket,
	() => dialLocatorForRelay(locator, Reachability.Discovery),
	"iroh relay dial failed",
	{
		idleTimeoutMs: BINDING_RELAY_IDLE_TIMEOUT_MS,
		maxBytesPerSession: BINDING_RELAY_MAX_BYTES_PER_SESSION,
	},
);
```

Browser and other managed-WebSocket runtimes compose `connector()`. It accepts
both `keyed-relay` and `noise-relay`. The connector moves bytes, while the
byte-fed Host applies Noise sealing from the locator's transport profile. Relay
routes are validated before WebSocket I/O. Both managed and native runtimes may
use `ws://` or `wss://` with DNS names. Native runtimes instead compose
`provider()` for dialing and `keyed.listen` / `noise.listen` (or the underlying
`listenKeyed` / `listenNoise`) for listening. The listener
registers held inbound sockets at the relay's `/register` endpoint and
announces a locator carrying the dial route, one registration route per
driver loop.

## Backpressure

Flow control is end to end only if both legs block their producer. The target leg blocks through the
byte channel, either a socket write or the iroh channel's `WOULD_BLOCK`. The browser-bound leg has no
drain event, so `webSocketRelay` holds its next read until the socket's `bufferedAmount` falls below
a high-water mark. A relay in another runtime must gate the browser-bound leg the same way. Python
uses `websockets`' awaited `send`, while Rust uses `SinkExt::poll_ready`. ADR-0086 requires that
backpressure, and `zig build bindings-relay` tests it directly by stalling
a reader through each runtime's relay and fails if the far sender is not backpressured.

The browser-to-relay direction has the opposite problem. An accepted WebSocket can deliver the first
handshake bytes before the target connection opens, and browser WebSockets cannot be paused. The
adapter installs handlers immediately, but accepts inbound messages only while its byte budget has
room. Overflow closes the WebSocket with code 1009 instead of growing process memory.

The relay adapter names and enforces a `MAX_RELAY_WEBSOCKET_MESSAGE_BYTES` bound of 1 MiB. A smaller
`inboundHighWaterBytes` is allowed for a deployment, but a larger one is refused. This limit applies
to a reassembled WebSocket message. The relay does not parse it or add another CapTP frame limit.
Text messages are refused with WebSocket code 1003. Only binary `ArrayBuffer` messages enter
the byte channel.

## Scaling

The relay holds no CapTP session state, so each connection costs runtime and socket overhead rather
than glowcap session buffers. `zig build relay-scaling` (`test/scaling_bench.ts`) opens thousands of
connections through the reference relay and divides the resident-memory increase by that count. The
measured cost is about 80 KiB per connection. Each connection also uses two file descriptors, so a
large deployment needs enough memory and a matching descriptor limit. The check fails if a change
adds a large per-connection buffer. Reaching the core's roughly 2 KiB session cost would require a
native completion-loop relay, which is a different implementation.
