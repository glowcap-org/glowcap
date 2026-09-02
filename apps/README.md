# apps/

First-party applications live here. They use the same public
`connect`/`publish`/`fetch`/`send`/`serve` API as the language bindings, not
private `libglowcap_*` calls.

- [`rooms/`](rooms/): capability-secure chat. The browser UI
  (`zig build rooms-web`) rides encrypted iroh; `demo-rooms` is the
  cross-language room without a browser.
- [`tasks/`](tasks/): a shared task board (`zig build demo-tasks`).
- [`tools/`](tools/): the delegation/attenuation/revocation showcase for AI
  agent harnesses (`zig build demo-tools`).
- [`accountability-on-glowcap/`](accountability-on-glowcap/): signed-call
  accountability above glowcap's runtime (`zig build accountability`).
- [`ocapnviz/`](ocapnviz/): the OCapN topology visualizer. It runs on its own
  Deno toolchain (see its README). `zig build ocapnviz-test` runs the suite and
  is part of `zig build check` when deno is present; `zig build ocapnviz-check`
  also type-checks, formats, and lints. `scripts/griddle-import.ts` converts a
  `glowcap griddle run` timeline into a document its Play mode replays.
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
| [`cli/`](../cli/) | The installable `glowcap` binary |
| [`examples/`](../examples/) | Teaching-sized, single-file walks |
| [`tools/`](../tools/) | Maintainer check steps, codegen, and operator scripts |

See [ADR-0085](../docs/decisions/adr/ADR-0085-repository-product-and-devtool-layout.md)
for the layout decision.
