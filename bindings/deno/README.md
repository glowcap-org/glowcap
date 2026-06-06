# bindings/deno

A [Deno](https://deno.com) consumer of the Zig `libpancake` C ABI, loaded
through `Deno.dlopen`. See [`../README.md`](../README.md) for the shipped C ABI
surface and how the bindings are gated.

## The API

[`pancake.ts`](pancake.ts) is the idiomatic Deno API over the C ABI. The raw
`Deno.dlopen` FFI is private; what you use is a `Peer` class (disposable),
discriminated-union value types, and typed events. Integers are `bigint`, floats
are `number`:

```ts
using peer = new Peer();
peer.registerImport(5n);
peer.sendDeliver(far(5n), [42n, new Uint8Array([1, 2])], 9n);
peer.step();
const frame = peer.takeOutbound();
// ...and poll() returns a typed { kind: "deliver" | "resolve" | "other", ... }
```

[`zig_smoke.ts`](zig_smoke.ts) is the consumer `zig build bindings` runs: it
drives a real OCapN round-trip through that API (construct a call, read a
delivery's args). Deno's FFI needs `--allow-ffi --allow-read`; the build step
passes them and resolves the shared library relative to `zig-out/`.

```sh
zig build bindings        # builds libpancake, runs every binding consumer
```
