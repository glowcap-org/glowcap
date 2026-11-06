# @glowcap/relay

Carry an [OCapN](https://glowcap.org/protocol/) session through a WebSocket
relay when a peer cannot accept a socket directly. `noise-relay` encrypts the
session between peers. `keyed-relay` sends it in the clear. The relay forwards
bytes without parsing CapTP or holding capabilities.

## Install

```sh
deno add jsr:@glowcap/relay jsr:@glowcap/runtime
```

For a browser, start with the [prebuilt browser bundle](https://jsr.io/@glowcap/web).
It includes the relay client. The [relay guide](https://glowcap.org/relay/)
explains the routes and server setup.

## Embed an iroh relay

This function connects an accepted WebSocket to an iroh peer. Your HTTP
server owns the WebSocket upgrade, origin checks, connection limits, and
which peer locators it permits. Call the function as soon as the socket is
upgraded, and observe the returned promise for teardown failures.

```sh
deno add jsr:@glowcap/abi jsr:@glowcap/iroh
```

```ts
import { BINDING_RELAY_IDLE_TIMEOUT_MS, BINDING_RELAY_MAX_BYTES_PER_SESSION } from "@glowcap/abi";
import { denoIrohChannel, webSocketRelay } from "@glowcap/relay";

export function relayToPeer(socket: WebSocket, locator: string): Promise<void> {
	return webSocketRelay(
		socket,
		() => denoIrohChannel(locator, "discovery"),
		"iroh relay dial failed",
		{
			idleTimeoutMs: BINDING_RELAY_IDLE_TIMEOUT_MS,
			maxBytesPerSession: BINDING_RELAY_MAX_BYTES_PER_SESSION,
		},
	);
}
```

The iroh transport loads its C library on first use. The
[runtime installation guide](https://jsr.io/@glowcap/runtime#install) covers
the SDK download and Deno permissions. An iroh gateway can read traffic and
vouches for the far peer's identity. Use `noise-relay` when the gateway must
not read the session.

## Connect or accept peers

- Browser runtimes use `connector()` to dial `keyed-relay` or `noise-relay`.
- Deno runtimes use `provider()` to dial and `keyed.listen` or `noise.listen`
  to register an accepting peer at the relay's `/register` endpoint.
- Both support `ws://` and `wss://` routes, including DNS names.

## Resource limits

The pump waits for outbound writes and bounds queued inbound bytes. A slow
peer cannot make its queue grow without limit. Idle timeouts and byte caps
close both legs, preserving cleanup failures alongside the first error.

WebSocket messages are bounded by `MAX_RELAY_WEBSOCKET_MESSAGE_BYTES`,
<!-- value ../../../tools/gen/binding/policy.zig websocket_message_cap_bytes bytes -->1 MiB<!-- /value -->.
You can choose a smaller inbound budget. Text messages are refused. The
server still owns target admission and its total connection limit.

See the [API reference](https://jsr.io/@glowcap/relay/doc) for the byte-channel
and pump interfaces, or the [browser guide](https://glowcap.org/bindings/browser/)
for client configuration.

glowcap is built with AI coding assistants under
[maintainer direction](https://github.com/glowcap-org/glowcap/blob/main/PROVENANCE.md).
