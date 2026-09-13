# Rooms in Rust

This workspace is the Rooms application: the policy every Rooms peer
applies, the clients that speak the Rooms protocol over glowcap, the shared
execution both the services and the browser run, the services themselves,
and the browser's Wasm adapter. One implementation runs in every place a
Rooms peer runs, so joining a room, sending a line, and recovering after a
lost connection mean the same thing in a terminal, on a server, and in a
tab.

## The crates

| Crate | Owns | Depends on |
| --- | --- | --- |
| `rooms-application` | Portable policy with no platform dependencies: documents and their bounds, the room protocol, files, the archive, the session, the server, the wire vocabularies | nothing |
| `rooms-glowcap` | The view over the Rust binding's decoded values, and the clients that speak the Rooms protocol over a session | `rooms-application`, the Rust binding |
| `rooms-runtime` | Shared execution over platform adapters: session commands, directory supervision, rooms, direct messages, media, archives, grants | `rooms-application`, `rooms-glowcap`, the Rust binding |
| `rooms-platform` | The host side of those adapters: Tokio, operating-system entropy, leased filesystem storage, listeners, TLS trust, WebSocket byte channels | the three above, the Rust binding |
| `rooms-services` | The room server, the session peer, the archive peer, the IRC bridge and front, the web front, and the interactive client | the four above |
| `rooms-browser` | The browser side of the adapters and the exports the page calls: session controllers, IndexedDB storage, WebRTC signaling, transports | `rooms-application`, `rooms-glowcap`, `rooms-runtime`, the Rust browser binding |
| `rooms-contract-proofs` | The application contracts replayed from recorded fixtures, natively and as browser Wasm | `rooms-application`; the Rust binding on both targets |

`rooms-application` decides; the other crates carry its decisions to a host.
A behavior that can be decided without a runtime belongs in the application
crate, with a fixture that proves it on both targets. The dependency
direction is held by `zig build source-check`: a service dependency never
enters a shared or platform crate, and no host platform dependency enters
the browser crate.
[ADR-0147](../../../docs/decisions/adr/ADR-0147-rooms-rust-application-boundary.md)
and [ADR-0148](../../../docs/decisions/adr/ADR-0148-rooms-host-platform-and-services.md)
record the boundary.

### rooms-application

- `documents`, `fields`, and `text` are the document contract: bounded
  fields, and text that keeps an isolated UTF-16 surrogate a JavaScript
  author wrote, so nothing is silently rewritten on the way through.
- `markdown` and `open_graph` interpret an authored message: one bounded
  Markdown tree gives both the rendered document and the link candidates,
  and a preview selection is a validated subset carried without trusting a
  web site's metadata.
- `grants` is the grant ledger: validation, revocation tombstones, the access
  a link is read for on every call, and the HMAC derivation of published
  names. Its storage adapter replaces the document atomically, and the
  ledger commits only after the write is acknowledged.
- `room` is the room protocol: the three access policies, line edit, refile,
  and withdraw, membership and stewardship, invitations, the inbox reader,
  and the client's view of history.
- `files` is the upload and media budget: one server-wide and one per room,
  64 KiB chunks, and the receiving budget a view or an archive charges
  before it takes a file.
- `archive` is the member archive: records and their identity, filters,
  blob digests, retention, merging across keepers, and shares.
- `session` is the shared session: the checkpoint and what each access level
  may see of it, the durable state with its effect ledger and result
  recovery, command admission, the facts that keep the checkpoint and the
  live rooms in agreement, and the snapshot an attached view receives.
- `bridge`, `direct`, `directory`, and `signaling` are the wire vocabularies,
  each with its bounded reader and writer.
- `server` is what a Rooms server hosts: the server document with its
  identity seed and room links (`document`, `links`), the directory, the
  live rooms with their members, lines, files, invitations, and entrances,
  history retention, operations (the journal, listener seats, the diagnostic
  snapshot, the operator inventories and pages), peering, IRC, and the live
  timeline. Connections are the adapter's keys and capabilities its tokens;
  every verb answers with the notices, releases, and history changes the
  adapter must perform, so the same decisions run under any host and a test
  reads them without a wire.
- `failure` reads and writes the Rooms failure codes.

### rooms-glowcap

`host_options` supplies the profile and feature offer a Rooms Host makes.
`Value` borrows a decoded argument and reads wire integers without a second
representation; `ArgumentView` finds the capabilities an argument carries
so a verb can refuse the ones it does not take. Each client under `client`
owns the reply validation for its verbs and the custody of what it retains:
a membership subscribes and waits for its seat, a line keeps its own
authority independent of the membership, a file transfer advances only on
acknowledgement, an invitation keeps one receipt across retries.
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
trust and `websocket` turns a WebSocket into a byte channel.

### rooms-services

Each service is one module and one binary: `server` (`rooms-server`),
`session` (`rooms-session`), `archive::peer` (`rooms-archive`), `web`
(`rooms-web`), `irc_bridge` and `irc_front`, and `chat` (`rooms-chat`). A
library module records what happens through a typed notice and a report the
binary installs; the binary decides where it goes. The server keeps history
in files or PostgreSQL through one shared index, the web front serves a
prepared browser generation and supervises the room server, and every
service takes `--transport=onion` with a running Tor's endpoints.
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
answer. `zig build rooms-rust-test` runs them natively, while `zig build
rooms-rust-browser-test` runs them in Wasm. The
[fixtures guide](proofs/fixtures/README.md) says what each file holds.

## Building and checking

`zig build rooms-rust-test` runs the application contracts and rides
`runtime-check`. `zig build rooms-rust-lint` is clippy with warnings denied. The
workspace's `Cargo.lock` is committed and every step passes `--locked`.
`rooms-peers-test` runs the installed services as processes (identity,
restart, signals), and `rooms-postgres-test` is the opt-in database check.
The wasm target and `wasm-bindgen` the browser build needs are installed by
the devcontainer image; `zig build rooms-browser-build` produces the
application module and its JavaScript glue, and every web launch and
deployment preparation depends on it.

Running a test binary by hand needs glowcap's shared libraries on the
loader path: from `apps/rooms/rust`,
`LD_LIBRARY_PATH=../../../zig-out/lib cargo test -p rooms-services --features processes`.

The [archive design page](archive.md) describes the member archive from
records to durable shares.
