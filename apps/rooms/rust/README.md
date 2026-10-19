# Rooms in Rust

This workspace is the whole Rooms application: the rules every peer follows,
the clients that speak the Rooms protocol over glowcap, the code the services
and the browser share, the services themselves, and the browser's Wasm
adapter. One implementation runs everywhere a Rooms peer runs, so joining a
room, sending a line, and recovering from a lost connection mean the same
thing in a terminal, on a server, and in a tab.

## The crates

| Crate | Owns | Depends on |
| --- | --- | --- |
| `rooms-application` | Portable policy with no platform dependencies: documents and their bounds, the room protocol, files, the archive, the session, the server, the wire vocabularies | nothing |
| `rooms-glowcap` | The view over the Rust binding's decoded values, and the clients that speak the Rooms protocol over a session | `rooms-application`, the Rust binding |
| `rooms-runtime` | Shared execution over platform adapters: managed receipt execution, source-dependent supervision, direct messages, media and archives | `rooms-application`, `rooms-glowcap`, the Rust binding |
| `rooms-platform` | The host side of those adapters: Tokio, operating-system entropy, leased filesystem storage, listeners, TLS trust, WebSocket byte channels, WebRTC signaling through a directory | the three above, the Rust binding |
| `rooms-services` | The room server, the session peer, the archive peer, the IRC bridge and IRC server, the web server, and the interactive client | the four above |
| `rooms-product` | Private executable entry points, workspace and roster supervision, and process proofs | `rooms-services` and its lower layers |
| `rooms-browser` | The browser side of the adapters and the exports the page calls: session controllers, IndexedDB storage, WebRTC signaling, transports | `rooms-application`, `rooms-glowcap`, `rooms-runtime`, the Rust browser binding |
| `rooms-contract-proofs` | The application contracts replayed from recorded fixtures, on the host and as browser Wasm | `rooms-application` and the Rust binding on both targets |

`rooms-application` decides. The other crates carry its decisions to a host.
A behavior that can be decided without a runtime belongs in the application
crate, with a fixture that proves it on both targets. `zig build source-check` enforces the dependency
direction: a service dependency never
enters a shared or platform crate, and no host platform dependency enters
the browser crate.
[ADR-0045](../../../docs/decisions/adr/ADR-0045-managed-rooms-sessions.md)
and [ADR-0045](../../../docs/decisions/adr/ADR-0045-managed-rooms-sessions.md)
record the boundary.

### rooms-application

- `documents`, `fields`, and `text` are the document contract: bounded
  fields, and text that keeps an isolated UTF-16 surrogate a JavaScript
  author wrote, so nothing is silently rewritten on the way through.
- `markdown` and `open_graph` interpret an authored message: one bounded
  Markdown tree gives both the rendered document and the link candidates,
  and a preview selection is a validated subset carried without trusting a
  web site's metadata.
- `room` is the room protocol: the three access policies, line edit, refile,
  and withdraw, membership and stewardship, invitations, the inbox reader,
  and the client's view of history.
- `files` is the upload and media budget: one server-wide and one per room,
  fixed-size chunks (`CHUNK_BYTES`), and the receiving budget a view or an
  archive charges before it takes a file.
- `archive` is the member archive: records and their identity, filters,
  blob digests, retention, merging across keepers, and shares.
- `content::session` declares the managed workspace, held-storage and effect schemas,
  permission requirements, presets and typed result routing. Shared Loam owns
  grant semantics. `rooms-runtime::session::managed` owns receipt execution and
  worker supervision. The [session guide](../../../docs/rooms/session.md) maps
  the production consumers.
- `bridge`, `direct`, `directory`, and `signaling` are the wire vocabularies,
  each with its bounded reader and writer.
- `server` is what a Rooms server hosts:
  - the server document, with its identity seed and room links (`document`,
    `links`)
  - the directory, and the live rooms with their members, lines, files,
    invitations, and entrances
  - history retention
  - operations: the change log, listener seats, the diagnostic snapshot, and the
    operator inventories and pages
  - peering, IRC, and the live timeline

  Connections and capabilities appear here only as the adapter's
  keys and tokens. Every verb returns the notices, releases, and history
  changes the adapter must carry out, so the same decisions run under any
  host, and a test can read them without a network.
- `failure` reads and writes the Rooms failure codes.

### rooms-glowcap

`host_options` supplies the profile and feature offer a Rooms Host makes.
`Value` borrows a decoded argument and reads wire integers without converting
them to another form. `ArgumentView` finds the capabilities an argument
carries, so a verb can refuse ones it does not accept. Each client under
`client` validates the replies to its verbs and owns what it keeps:

- a membership subscribes and waits for its seat
- a line keeps its own authority, separate from the membership
- a file transfer advances only when acknowledged
- an invitation keeps one receipt across retries

`client::session` is the attached-session client: snapshots, watch delivery,
commands, checkpoint replacement, files, grants, and archive shares. The
clients take their deadlines and task spawning from the caller, so they run
under Tokio and in the browser alike.

### rooms-runtime

The [runtime guide](runtime/README.md) is the embedder's page: the tree,
the platform traits an embedder implements, and the lifecycle.

### rooms-platform

`execution` is the `HostPlatform`: clocks, task handles, fresh identifiers,
and wall time. `storage` leases a state directory to one process and
replaces files atomically. `serving` opens listeners on the transports a
peer may realize, including onion through a running Tor. `tls` loads system
trust and `websocket` turns a WebSocket into a byte channel. `signaling`
carries a WebRTC dial's offer, answer and candidates through the directory
that introduced the peer, for the binding's WebRTC provider.

### rooms-services

Each service is one module and one binary: `server` (`rooms-server`),
`session` (`rooms-session`), `archive::peer` (`rooms-archive`), `web`
(`rooms-web`), `irc_bridge` and `irc_server` (the IRC server), and `chat` (`rooms-chat`).

- A library module reports what happens through a typed notice and a report
  the binary installs. The binary decides where reports go.
- The server keeps history in files behind one shared index.
- The web server serves a prepared browser build and supervises the room
  server.
- Every service accepts `--transport=onion`, given a running Tor's endpoints.
- The session's optional `session::control` view accepts local commands and
  owns a bounded log of unread events. Its disk worker cannot block a
  Rooms turn, and an observer failure does not stop the application.
- The private command layer under `src/bin/rooms-session/commands` builds
  individual and roster operations on that interface. The Zig CLI owns
  argument parsing, help, and completion, and neither Rust executable
  reimplements Rooms protocol behavior.

[Operating Rooms](../operating.md) says how each is run.

### rooms-browser

The [browser guide](browser/README.md) names the exports the page
constructs and how bytes and strings cross the Wasm boundary.
`lib/application_data.ts` is generated from the application crate's shared
limits and boot capabilities. `web/ui/application_data.ts` re-exports that
catalog beside the browser-only draft timing. Generate both with:

```sh
cargo run --manifest-path apps/rooms/rust/Cargo.toml -p rooms-application --example browser_metadata
```

`zig build rooms-browser-metadata-check` holds them fresh.

### rooms-contract-proofs

Each proof replays a recorded fixture through a Rust type and checks the
answer. `zig build rooms-rust-test` runs them in a process, while `zig build
rooms-rust-browser-test` runs them in Wasm. The
[fixtures guide](proofs/fixtures/README.md) says what each file holds.

## Building and checking

- `zig build rooms-rust-test` runs the application contracts and is part of
  `runtime-check`.
- `zig build rooms-rust-lint` runs clippy, the Rust linter, and treats warnings
  as errors.
- `rooms-peers-test` runs the installed services as processes (identity,
  restart, signals).
- The workspace's `Cargo.lock` is committed and every step passes `--locked`.
- The devcontainer image installs the wasm target and the `wasm-bindgen` the
  browser build needs. `zig build rooms-browser-build` produces the application
  module and its JavaScript glue, and every web launch and deployment
  preparation depends on it.

Browser checks use the workspace's `browser-proof` profile for Wasm and non-Wasm
fixtures, with optimization level 1, no LTO, and 16 codegen units. Deployment
builds keep the `release` profile.

- Non-Wasm fixtures have a separate Cargo target directory and install as
  `zig-out/libexec/rooms-web-proof` and `rooms-server-proof`. Their sibling
  layout preserves shared-library discovery.
- Managed room and sharing journeys link `rooms-browser` directly. Fixture
  contracts link their own module. Each has separate generated glue and
  artifacts.
- Non-Wasm tests consume libraries without unused shared-library links.
- Channel proofs supply their module and start `rooms-web` with
  browser asset preparation disabled.

Running a test binary by hand needs glowcap's shared libraries on the loader
path. From `apps/rooms/rust`:

```sh
LD_LIBRARY_PATH=../../../zig-out/lib cargo test -p rooms-services --features processes
```

Process tests live in `rooms-product`. `zig build rooms-peers-test rooms-web-test`
supplies their installed runtimes and prepared assets. `zig build rooms-build`
stages the complete installation, including private runtimes under `libexec`
and prepared browser assets.

The [archive design page](archive.md) describes the member archive from
records to durable shares.
