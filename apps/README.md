# apps/

First-party applications live here. They use the same public
`connect`/`publish`/`fetch`/`send`/`serve` API as the language bindings and
call no private `libglowcap_*` functions.

- [`rooms/`](rooms/): capability-secure chat. A server hands clients room and
  inbox capabilities. The browser UI (`zig build rooms-web`) runs over
  encrypted iroh. `zig build demo-rooms` puts Zig and Deno clients in one room
  without a browser, plus Rust, Python, and Racket clients when those runtimes
  are installed.
- [`tasks/`](tasks/): a shared task board saved in Loam, whose lists and tasks
  are each a capability and survive a restart (`zig build demo-tasks`).
- [`tools/`](tools/): a coordinator grants AI agents tool capabilities,
  narrows them to read-only use, and revokes them (`zig build demo-tools`).
- [`accountability-on-glowcap/`](accountability-on-glowcap/): signed caller
  identity and an audit log around an ordinary capability call. `zig build
  accountability` runs the Zig version, and `zig build demo-accountability`
  adds Deno and Python callers.
- [`ocapnviz/`](ocapnviz/): the OCapN topology visualizer. It runs on its own
  Deno toolchain (see its README). `zig build ocapnviz-test` runs the suite and
  is part of `zig build runtime-check`. `zig build ocapnviz-check` also
  type-checks, formats, and lints. `scripts/griddle-import.ts` converts a
  `glowcap griddle run` timeline into a document its Play mode replays.
- `_demo/`: code the demo steps share.

Each app has its own build step. The accountability application and the
bounded Deno application suites run in `zig build runtime-check`. Demos run
separately. [`examples/README.md`](../examples/README.md) explains what each
one demonstrates.

## How the cross-language demos run

Rooms, Tasks, and Tools share one convention:

- Deno coordinates the run and starts the server.
- The Zig client always joins.
- Python, Racket, and Rust join when their runtimes are on `PATH`. Missing
  optional runtimes are reported and skipped.
- `-Dport=9099` chooses a port instead of using an available one.
- `-Dattach=true` runs the clients against an existing server and leaves it
  running. Tasks has no attach mode, because its board's name is a secret
  that only a server the demo starts announces.

These demos are not part of `zig build check` because they depend on external
runtimes. Individual app guides list their exceptions and extra requirements.

## Related directories

| Path | Role |
|------|------|
| [`cli/`](../cli/) | The installable `glowcap` binary |
| [`examples/`](../examples/) | Small single-file walkthroughs |
| [`tools/`](../tools/) | Maintainer build checks, code generators, and operator scripts |

See [ADR-0085](../docs/decisions/adr/ADR-0085-repository-product-and-devtool-layout.md)
for the layout decision.
