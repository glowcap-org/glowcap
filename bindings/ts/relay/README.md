# @pancake/relay

The byte-transparent relay a pancake embedder runs so a peer that cannot open a socket itself, such
as a browser, can hold a CapTP session with another peer. The relay forwards the raw session bytes
without parsing them, so the keyed or Noise handshake and session authority run end to end and the
relay holds no capability. The contract every runtime's relay obeys is
[ADR-0086](../../../docs/decisions/adr/ADR-0086-byte-transparent-relay.md); this package is its
TypeScript reference implementation.

## The five parts

A relay in any runtime is assembled from five pieces. This package ships the two that are agnostic
across JavaScript runtimes (the pump and the WebSocket wiring); the other three are the embedder's,
and the same five shapes appear in every language's relay.

1. **A raw byte channel** to the target — `read() → Uint8Array | null`,
   `write(bytes) → Promise<void>`, `close() → Promise<void>` (one idempotent release barrier): the `RelayChannel` type. For an iroh
   target it comes from `@pancake/iroh`'s `dialLocatorForRelay`; for a TCP target it is the
   runtime's own socket.
2. **The pump**, `relayBytes(source, sink, channel, config, closeSource)`: moves bytes between the
   two legs with pair-atomic teardown, an idle timeout, a byte cap, and awaited-write backpressure.
   It joins both close barriers before returning and preserves close refusals after the first I/O failure.
3. **A WebSocket adapter**, `webSocketRelay(socket, getChannel, dialFailReason,
   config, options?)`: wires
   an accepted WebSocket to the pump, buffering the browser's first handshake bytes across the async
   dial, admitting those early inbound bytes under a bounded queue, and gating outbound flow on the
   socket's send buffer. The embedder supplies the accepted socket from its own HTTP server.
4. **A dial dispatcher** (the embedder's): open the matching channel for the target. This reference
   relay dispatches on which query parameter the browser set — `?to=host:port` opens a socket,
   `?locator=<uri>` an iroh channel — and deliberately stays dependency-light, reading no locator
   grammar and loading iroh only on the `?locator=` path (a `source-check` gate holds that lazy load).
   Routing classification through the shared core `pancake_host_plan_dial` would link the capability
   core for one bit the parameter already carries, so only the production rooms relay
   (`apps/rooms/web/relay.ts`) does that, to keep its SSRF allow-list in lockstep with the dial it
   admits (ADR-0086).
5. **Config** — `{ idleTimeoutMs, maxBytesPerSession }`. The embedding app supplies which targets
   may be dialed separately, as policy.

## Usage

```ts
import { BINDING_RELAY_IDLE_TIMEOUT_MS, BINDING_RELAY_MAX_BYTES_PER_SESSION } from "@pancake/abi";
import { webSocketRelay } from "@pancake/relay";
import { dialLocatorForRelay, Reachability } from "@pancake/iroh";

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
both `keyed-relay` and `noise-relay`; the connector moves bytes, while the
byte-fed Host applies Noise sealing from the locator's transport profile. Relay
routes are validated before WebSocket I/O and may use `ws://` or `wss://` with
DNS names, on the managed and native sides alike. Native runtimes instead
compose `provider()` for dialing, and `keyed.listen` / `noise.listen` (or the
underlying `listenKeyed` / `listenNoise`) for the accepting half: the listener
registers held inbound sockets at the relay's `/register` endpoint and
announces a locator carrying the dial route, one registration route per
driver loop.

## Backpressure

Flow control is end to end only if both legs block their producer. The target leg blocks through the
byte channel (a socket write, or the iroh channel's `WOULD_BLOCK`). The browser-bound leg has no
drain event, so `webSocketRelay` holds its next read until the socket's `bufferedAmount` falls below
a high-water. A relay in another runtime must gate the browser-bound leg the same way (Python
`websockets`' awaited `send`, Rust `SinkExt::poll_ready`); ADR-0086 makes that gate a non-optional
contract clause, and the cross-runtime matrix asserts it directly: `zig build bindings-relay` stalls
a reader through each runtime's relay and fails if the far sender is not backpressured.

The browser-to-relay direction has the opposite problem: an accepted WebSocket can deliver the first
handshake bytes before the far-side dial finishes, and browser WebSockets cannot be paused. The
adapter installs handlers synchronously, but admits inbound messages only while its byte budget has
room; overflow closes the WebSocket with code 1009 instead of growing process memory.

The relay adapter names and enforces a `MAX_RELAY_WEBSOCKET_MESSAGE_BYTES` bound of 1 MiB. A smaller
`inboundHighWaterBytes` is allowed for a deployment, but a larger one is refused. This is a
WebSocket transport-message bound: the WebSocket implementation reassembles fragments before
delivering `message`, and the relay deliberately does not parse or impose a second CapTP frame
bound. Text messages are refused with WebSocket code 1003; only binary `ArrayBuffer` messages enter
the byte channel.

## Scaling

The relay holds no CapTP session state, so one more relayed connection costs only runtime and socket
overhead, not pancake buffers. `zig build relay-scaling` (`test/scaling_bench.ts`) measures that cost the
way `bench-peer-scaling` measures the core's: it stands up the real reference relay, opens thousands
of live relayed connections through it, and divides the resident-memory delta by the count. The
figure is about 80 KiB per connection, so a host serves tens of thousands of connections per
gigabyte of RAM, and with both the RAM (tens of gigabytes) and a raised file-descriptor limit to
match (each connection is two descriptors), hundreds of thousands. The run also proves the relay
holds thousands of connections at once and fails if a change gives each connection a fat buffer. A
lower per-connection cost would take a native completion-loop relay rather than a JavaScript one,
the same way the core reaches ~2 KiB per session; that is a separate build.
