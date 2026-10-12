# rooms-browser

This crate is the Rooms application compiled for the browser. It runs the same
`rooms-runtime` session the native `rooms-session` binary runs, on browser
platform APIs, and exposes that session to the page through `wasm-bindgen`.
The React page under `web/ui` is presentation only: every decision about a
workspace, a directory, a room, or a line is made in Rust and handed back.

The whole crate is gated on `wasm32`. On any other target it compiles to an
empty library, so a workspace-wide `cargo` command still succeeds.

## What the page gets

The exports fall into two layers, and the first
layer opens no Host, so a page can admit its saved state and choose a
controller before it owns a runtime.

**Setup, before any Host exists** (`entry.rs`). Address inspection and stable
identity helpers use the same parsers as the process services. They validate
routes without enlivening authority or installing a JavaScript ABI adapter.

**A running application** (`attached/managed.rs`).
`RoomsManagedApplication` owns the tab's IndexedDB workspace, continuously
driven executor and Host. It exposes separate use and control handles, retained
commands and atomic acquisitions. Local, published and remotely attached
workspaces share the same typed application contract. React projects admitted
intent/activity and submits reader gestures through these handles.

The constructor accepts an optional third argument: a JSON string containing
an object of string values for the four admission settings in the
[admission guide](../../../../docs/rooms/admission.md). It validates policy before
opening the application. For example, `JSON.stringify({"admission-rates":"message=20/80"})`
selects a local message rate. Omitted settings use the shared defaults. Saved
intent cannot change policy while an application is running. A remotely attached
workspace keeps its server's policy.

`RoomsManagedBlob` and managed archive/history readers retain exact source and
upstream custody. `RoomsBrowserFileView` and `RoomsBrowserSource` carry bounded
file display and upload sources across the UI boundary. Selected source leases
stay owned through committed upload settlement. The
[session guide](../../../../docs/rooms/session.md) maps startup, publication,
reconnect, management and recovery.

**Persistence** (`storage/`).


- `storage::Session` opens the managed Loam Store with strict IndexedDB durability
  and an exclusive Web Lock. Bootstrap metadata fences delayed writers.
- `storage::Credentials` keeps private bridge answers under that same owner.
- `storage::Database` opens the `rooms-history` IndexedDB schema, and
  `storage::Archive` implements the shared archive backend on top of it.
  Replacing a record, blob positions, byte accounting, and the revision
  counter all commit in one transaction. A retained write checks its
  recording epoch in that same transaction, so an older tab cannot refill
  history that was erased.
- `RoomsBrowserArchive` performs **Delete browser data**. It closes the
  recorder and deletes the whole database, including the device identity.
  It finishes its cleanup even if the caller stops waiting.
- Blob staging hashes 64 KiB chunks before building an immutable `Blob`. A
  cache of verified blobs holds at most 32 blobs and 64 MiB.

## What the platform supplies

`platform::Platform` gives `rooms-runtime` monotonic time from
`performance.now`, task custody on the page's local executor, and entropy from
`crypto.getRandomValues`. A tab-hosted session persists its managed workspace,
capability fields, grants and effect receipts in IndexedDB. Live workers and
callbacks have one document lifetime. A reload restores the graph and starts a
fresh Host lifetime before exposing access. Preferences and archive records
retain separate storage owners.

`transport::open` composes one glowcap `Runtime` around the application's
Host. `WebFront::deployment` names the page's own native web server and
forwards complete TCP, keyed and Noise TCP, iroh, and onion locators through
it, keeping their routing hints. For iroh, the web server itself authenticates the
remote QUIC peer, so that route relies on the deployment for its key proof.
The other forwarded profiles are given no stand-in proof. Relay routes selected by
locator use `glowcap::browser::relay`.

`signaling` carries WebRTC signaling over one held Rooms directory connection
per attempt.

- `signaling::connector` picks a directory from the application's own
  inventory. It refuses a directory that belongs to another Host or another
  introducing session.
- `signaling::Listener::open` registers an answering inbox and returns once
  the directory accepts it. Drive `Listener::serve` inside the Host's
  `LocalSet`, and it hands each established session to the application.
- The listener accepts at most 32 pending offers and 64 candidates per offer.
  Each offer gets a fresh ICE configuration within a 30-second preparation
  deadline.
- A dialing exchange is tied to the target key it expects. An inbound offer
  names an exchange, not a caller key, so the accepting side never invents a
  verified identity.

`ice::Source::deployment` reads the native web server's `/ice` endpoint. Concurrent
readers share one request and each receives its own configuration object. A
later attempt refreshes credentials rather than caching them. Fetch and
validation failures are reported as they are, with no fallback server list.

## Building and checking it

`zig build rooms-browser-build` compiles the module and its generated
JavaScript glue. Every native web build and deployment preparation depends on
it, and the running `rooms-web` serves the module by content hash while
keeping the previous generation for pages already loading. After a Rust change
during development, rebuild and the web server notices the new content.

`lib/application_data.ts`, `web/ui/application_data.ts`, and
`lib/failure_data.ts` are generated from the Rust limits, boot capability
catalog, browser timing, and failure definitions by the `browser_metadata`
example in `rooms-application`. `zig build
rooms-browser-metadata-check` refuses a stale copy. Regenerate with:

```sh
cargo run --manifest-path apps/rooms/rust/Cargo.toml -p rooms-application --example browser_metadata
```

`zig build rooms-browser-test` exercises the production exports in Deno and
Chromium. `zig build rooms-rust-browser-host-test` drives the transport,
signaling, and ICE parts against the native `rooms-web` directory in
Chromium. It covers:

- explicit dials and three-party handoffs
- calls in both directions over keyed and Noise relay registrations
- native TCP and iroh forwarding to distinct rooms
- shutdown while an ICE request is pending
These scenarios check socket closure and callback retirement. The managed
session executor has separate LMDB/IndexedDB contracts through
`rooms-rust-test` and `rooms-session-executor-browser-test`. Production page
journeys establish reload, shared-session attachment, retained results, scoped
erasure and current-source management.
