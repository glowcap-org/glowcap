# apps/

First-party applications built entirely on the public application surface —
the same `connect` / `publish` / `fetch` / `send` / `serve` verbs the
bindings ship — never on `libpancake_*` internals. The cross-language demo
apps live here beside any product app that ships as its own binary. Each has a
dedicated `zig build` step: the accountability application runs inside
`zig build check`, while the cross-language demos run as siblings, since they
need extra language runtimes on PATH. The demo steps are listed in
[`examples/README.md`](../examples/README.md), which walks what each app
proves.

- [`rooms/`](rooms/): capability-secure chat, with the browser UI
  (`zig build demo-rooms`, `rooms-web`).
- [`tasks/`](tasks/): a shared task board (`zig build demo-tasks`).
- [`tools/`](tools/): the delegation/attenuation/revocation showcase for AI
  agent harnesses (`zig build demo-tools`).
- [`accountability-on-pancake/`](accountability-on-pancake/): signed-call
  accountability above pancake's runtime (`zig build accountability`).
- `_demo/`: plumbing the demo steps share.

## Not here

| Path | Role |
|------|------|
| [`cli/`](../cli/) | The installable `pancake` binary |
| [`examples/`](../examples/) | Teaching-sized, single-file walks |
| [`tools/`](../tools/) | Maintainer check steps, codegen, and operator scripts |

Layout decision: [ADR-0085](../docs/decisions/adr/ADR-0085-repository-product-and-devtool-layout.md),
amended to fold the demo apps in here rather than under `examples/`.
