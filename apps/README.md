# apps/

First-party product apps that ship as their own binaries. They consume the
public `pancake` module the same way [`cli/`](../cli/) does, and they are not
part of `libpancake_*`.

This directory is empty until an app lands here (for example ocapnviz). Put a
new product app in its own subdirectory under `apps/`, with a dedicated
`zig build` step that fails when the app drifts.

## Not here

| Path | Role |
|------|------|
| [`cli/`](../cli/) | The installable `pancake` binary |
| [`examples/apps/`](../examples/apps/) | Demos and showcases |
| [`tools/`](../tools/) | Maintainer check steps, codegen, and operator scripts |

Layout decision: [ADR-0085](../docs/decisions/adr/ADR-0085-repository-product-and-devtool-layout.md).
