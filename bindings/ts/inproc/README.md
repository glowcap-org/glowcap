# @glowcap/inproc

`@glowcap/inproc` connects two [OCapN](https://glowcap.org/protocol/) peers inside one process
through in-process pipes, with no socket and no kernel transport. It exists for tests and
examples that need two [`@glowcap/runtime`](https://jsr.io/@glowcap/runtime) peers without a
network. Use [`@glowcap/tcp`](https://jsr.io/@glowcap/tcp) or another transport package to reach
a peer in another process.

## Install

```sh
deno add jsr:@glowcap/inproc jsr:@glowcap/runtime
```

The package loads the in-process C library on first use, which the runtime's C SDK download
includes. Deno needs `--allow-ffi --allow-read`.

## Use

A listener binds a string designator, any opaque token, and a dialer names that designator.
The lifecycle matches TCP: make the netlayer, bind a listener or dial a connection, release the
connections, then release the netlayer.

```ts
import { Netlayer } from "@glowcap/inproc";

await using net = new Netlayer();
await using listener = net.listen("rooms");
await using client = await net.connect("rooms");
await using server = await listener.accept();
await client.writeFrame(frame);
const got = await server.readFrame();
```

`locator(designator)` builds the matching `inproc` locator for a Runtime. The raw methods are
asynchronous on Deno, which moves a blocking call off the JavaScript event loop. Bun's FFI runs
the call on the event loop, so the raw transport refuses construction there.

glowcap is built with AI coding assistants. The maintainer directs the work and is answerable for
what lands, as [How glowcap is built](https://github.com/glowcap-org/glowcap/blob/main/PROVENANCE.md)
explains.
