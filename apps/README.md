# apps/

First-party applications live here. They use the same public
`connect`/`publish`/`fetch`/`send`/`serve` API as the language bindings, not
private `libpancake_*` calls.

- [`rooms/`](rooms/): capability-secure chat, with the browser UI
  (`zig build demo-rooms`, `rooms-web`).
- [`tasks/`](tasks/): a shared task board (`zig build demo-tasks`).
- [`tools/`](tools/): the delegation/attenuation/revocation showcase for AI
  agent harnesses (`zig build demo-tools`).
- [`accountability-on-pancake/`](accountability-on-pancake/): signed-call
  accountability above pancake's runtime (`zig build accountability`).
- `_demo/`: plumbing the demo steps share.

Each app has its own build step. The accountability app runs in
`zig build check`; demos run separately because they need other language
runtimes. [`examples/README.md`](../examples/README.md) explains what each
one demonstrates.

## How the cross-language demos run

Rooms, Tasks, and Tools share one convention:

- Deno starts the server and coordinates the run.
- The Zig client always joins.
- Python, Racket, and Rust join when their runtimes are on `PATH`; missing
  optional runtimes are reported and skipped.
- `-Dport=9099` chooses a port instead of using an available one.
- `-Dattach=true` runs the clients against an existing server and leaves it
  running.

These demos are not part of `zig build check` because they depend on external
runtimes. Individual app guides list their exceptions and extra requirements.

## Nearby, but different

| Path | Role |
|------|------|
| [`cli/`](../cli/) | The installable `pancake` binary |
| [`examples/`](../examples/) | Teaching-sized, single-file walks |
| [`tools/`](../tools/) | Maintainer check steps, codegen, and operator scripts |

See [ADR-0085](../docs/decisions/adr/ADR-0085-repository-product-and-devtool-layout.md)
for the layout decision.
