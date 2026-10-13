# Dependencies

This page lists what glowcap depends on, grouped by where each dependency is
used. It names no versions. Each group links the file that pins them.

The `glowcap` Zig library has no dependencies beyond the Zig standard library.
Everything below serves a binding, a transport, an application, the
development environment, or a test.

## Toolchain

The development container installs these. Versions and checksums live in
[`.devcontainer/pins.sh`](../.devcontainer/pins.sh) and
[`.devcontainer/checksums.sh`](../.devcontainer/checksums.sh).

- **Zig**: builds the library, the C archives, the CLI, and every check. The
  pin is a Zig release, and `build.zig.zon` declares it as the minimum.
- **ZLS**: the Zig language server for editors. It is built from source
  against the pinned Zig.
- **Rust and rustup**: the Rust binding, the iroh and WebRTC transports, and
  Rooms.
- **Deno**: the TypeScript binding, Rooms' web client, ocapnviz, and the
  browser tests.
- **Bun**: runs the TypeScript binding's tests on a second JavaScript runtime.
- **Node and npm**: install the coding-agent tools the container offers.
- **Python and uv**: the Python binding and the OCapN test suite.
- **Racket and Spritely Goblins**: the reference peer for interop tests.
- **Playwright and Chromium**: browser tests for Rooms and ocapnviz.
- **Debian**: the container's base image.
- **Dev Container CLI**: starts and rebuilds the container from the host.
- **Coding agents**: Claude Code, Codex, Cursor Agent, and opencode, installed
  on first use. Serena gives them symbol-level navigation of the Zig code.

## Zig packages

[`build.zig.zon`](../build.zig.zon) fetches each one at a fixed commit and
checks its hash.

- **LMDB**: the on-disk store behind Loam's optional LMDB backend. It is
  compiled from OpenLDAP's unmodified C sources.
- **libvaxis**: the terminal UI behind the CLI's interactive REPL. It brings
  in zigimg (images) and uucode (Unicode tables). Only the CLI fetches it.
- **Zine**: the static site generator for the documentation site. It is
  declared in [`site/build.zig.zon`](../site/build.zig.zon).

## Rust crates

Each workspace pins its crates exactly in its `Cargo.toml`, and the
committed `Cargo.lock` files hold the rest.

- **tokio**: the async runtime for every Rust transport and for Rooms.
- **iroh**: QUIC connections behind the `iroh` netlayer.
- **webrtc**: data channels behind the `webrtc` netlayer.
- **hyper, rustls, and tokio-tungstenite**: Rooms' HTTP server, TLS, and
  WebSockets.
- **tokio-postgres**: Rooms' production database client.
- **markdown and html5ever**: Rooms' message rendering and link previews.
- **wasm-bindgen, js-sys, and web-sys**: Rooms' browser build and the
  browser storage proof.
- **serde and serde_json**: JSON in the Rust binding and Rooms.

## JavaScript packages

Deno's `deno.json` files pin these, and their `deno.lock` files hold the
rest.

- **React, React Router, Zustand, and Zod**: Rooms' web client.
- **Vite**: builds the Rooms web client and ocapnviz.
- **PixiJS, pixi-viewport, d3-force, and miniplex**: ocapnviz's rendering,
  layout, and entity model.
- **Playwright**: drives the browser tests.

## Python packages

Each project's `pyproject.toml` pins these, and its `uv.lock` holds the rest.

- **websockets**: the Python binding's optional rendezvous transport.
- **cryptography and stem**: the OCapN test suite's signing and Tor control.

## Reference sources

Git submodules under `conformance/` hold outside sources at pinned commits.
glowcap reads them and does not ship them.

- **OCapN specification**: the draft glowcap implements.
- **OCapN test suite**: the community's protocol tests.
- **Syrup**: the reference encoding and its test vectors.
- **Racket Goblins**: the peer that interop tests run against.

## Deployment images

Rooms' production deployment names these in its Dockerfile and Compose file.

- **Distroless**: the minimal base for the Rooms server image.
- **PostgreSQL**: the Rooms database.

## Updating

`.devcontainer/bin/update-pins.sh check` reports every pinned tool against its
upstream release. The [environment notes](../.devcontainer/README.md) list
the update procedure and the checks for every other group above.
