# @glowcap/tcp

`@glowcap/tcp` connects [`@glowcap/runtime`](https://jsr.io/@glowcap/runtime) to
[OCapN](https://glowcap.org/protocol/) peers over TCP, in three profiles:

| Profile | Locator | What it proves |
| --- | --- | --- |
| `noise-tcp` | `noise.locator(peerKey, host, port)` | Sealed end to end with Noise_XK. Finishing the handshake proves the peer's durable key. |
| `keyed-tcp` | `keyed.locator(peerKey, host, port)` | In the clear. The key names a dial target and proves nobody. |
| `tcp` | `locator(host, port)` | In the clear, for local development and peers that speak nothing else. |

Use `noise-tcp` for anything that leaves one machine. [Choosing a transport](https://glowcap.org/transports/choosing/)
compares the profiles with the other transports, and the [Noise page](https://glowcap.org/transports/noise/)
explains the sealed one.

## Install

```sh
deno add jsr:@glowcap/tcp jsr:@glowcap/runtime
```

The package loads the TCP C library on first use, which the runtime's C SDK download includes.
Deno needs `--allow-ffi --allow-read --allow-net`.

## Dial

```ts
import { Runtime } from "@glowcap/runtime";
import { noise, provider } from "@glowcap/tcp";

const peerKey = "<64 lowercase hex characters from the server>";
await using runtime = await Runtime.open({ providers: [provider()] });
await using session = await runtime.connect(noise.locator(peerKey, "127.0.0.1", 9099));
const greeter = await session.fetch("greeter");
console.log(await session.send(greeter, "greet", ["world"]));
```

## Listen

```ts
import type { Argument } from "@glowcap/runtime";
import { noise } from "@glowcap/tcp";

const seed = crypto.getRandomValues(new Uint8Array(32)); // keep it to keep the key
await using server = await noise.listen("127.0.0.1", 9099, { seed });
console.log(server.uri); // what partners dial, with the durable key

server.host.publish("greeter", (verb: string | null, args: Argument[]) => {
	if (verb !== "greet" || typeof args[0] !== "string") throw new Error("bad invocation");
	return `Hello, ${args[0]}`;
});
for await (const accepted of server) {
	await using session = accepted;
	await session.serve();
}
```

- `listen`, `keyed.listen`, and `noise.listen` return the same `Server`. Keyed and Noise
  listeners take an optional 32-byte `seed` that keeps the Host's identity across restarts.
- `ListenOptions` names an existing `host`, the `codec`, and `advertisedHost`, the name or
  address partners dial. A wildcard bind requires it, because a bind address is not a route.
- `options()` builds the per-operation keepalive and stream settings for `provider(config)`.

`@glowcap/tcp/transport` exposes the blocking frame transport (`Netlayer`, `Listener`,
`Connection`) for a program that runs its own loop. The [TypeScript guide](https://glowcap.org/bindings/ts/)
covers the session API these connections carry.

glowcap is built with AI coding assistants. The maintainer directs the work and is answerable for
what lands, as [How glowcap is built](https://github.com/glowcap-org/glowcap/blob/main/PROVENANCE.md)
explains.
