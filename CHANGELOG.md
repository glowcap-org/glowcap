# Changelog

Every release lists what changed for people using glowcap, in the form
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) describes. The
release notes on each [GitHub release](https://github.com/glowcap-org/glowcap/releases)
open with that version's section, so a release needs its section here first.
glowcap is alpha software, and a minor or patch version can change APIs, ABIs,
and storage formats before 1.0.

## [Unreleased]

## [0.1.6] - 2026-11-08

### Added

- `rooms-server --listen=<transport>[,<name>=<value>...]` (or
  `GLOWCAP_ROOMS_LISTEN`) opens another listener to the same directory, once
  per transport, and the server starts only once every declared listener is
  open. The address it prints then names the directory by its key with every
  listener listed.
- The Rooms page reaches a directory through a sealed relay listener the
  directory declares, with no Rooms server chosen, and the directory's card
  says the route the connection took.

### Changed

- Every exported symbol of the nine `@glowcap` JSR packages carries a doc
  comment, including the generated C ABI constants and struct layouts, so
  each package's documentation score on jsr.io reports no undocumented
  symbol.
- A page with no Rooms server asks for one only for an address the browser
  cannot open itself, and says which listener failed when one did. A relay
  that does not answer is named on the join card.
- Every ask for a Rooms server says what the act needs one for. The needs
  are an address this browser cannot open on its own, the home directory a
  blank address means, a link other people reach this browser through, and
  direct messages in the mode that goes through the server.
- Attaching to a session, holding a management control, taking an archive
  peer, and holding an operations capability judge the pasted link by its
  doors, so a session shared from another browser attaches with no Rooms
  server. The ask comes only for a link this browser cannot open on its own,
  and a break on the way to a session reached through its relay door names
  that relay.
- A blank directory address on a page with no Rooms server is refused on its
  own field instead of asking for a server.
- The Session tab offers its unfinished-changes list only while a change is
  unfinished, and Reachability no longer shows this browser's own address,
  which nothing on the page accepted.
- `rooms-web` serves its page before its directory is up, so the directory's
  relay listeners can register with it, and `/locator` waits for the directory
  instead of answering that there is none.
- `GLOWCAP_ROOMS_SESSION_STATE` serves the shared workspace the way
  `--session-state` does, and the option wins when both are set.

### Fixed

- `rooms-web` took the last of a repeated option and dropped the rest without
  a word, so `--allow-origin` given twice let only the second page in. It now
  reads its options the way every other Rooms command does. A repeated option,
  an unknown one, or a port named both as an option and positionally is
  refused by name. `--allow-origin` repeated extends the list, the same as one
  comma-separated list. The defaults `zig build rooms-web` and `rooms-dev`
  supply arrive as environment, so an option typed after `--` is the only one
  of its name. `rooms-dev` names the backend options it owns instead of letting
  `rooms-web` refuse them as repeats.
- A call forwarded inside a Rooms server across a Loam hop kept no delivering
  session, so the directory card showed no transport and direct messages from
  different senders counted as one sender. `current_session()` in the Rust
  binding now names that session.

## [0.1.5] - 2026-11-07

### Added

- The Rooms page is published at https://glowcap.org/rooms/app/ with the
  website. A Rooms server lets that page use it unless `--allow-origin` (or
  `GLOWCAP_RELAY_ALLOW_ORIGINS`) lists other pages. The link it prints under
  **open the page** opens the page with this server. The page names the
  browser's local network permission when that is what stands in the way.
- `--http-public` (or `GLOWCAP_ROOMS_HTTP_PUBLIC`) names the address browsers
  reach a Rooms server at, so the links a deployed server prints are ones
  other people can open.
- The Rooms server card in Settings shows the server's address to copy.
- The theme chosen on the website or in the Rooms page it publishes is one
  choice: both keep it under the same browser key. A presentation export
  still carries it with the other view preferences.
- Joining a room, connecting to a directory, or messaging someone from a page
  with no Rooms server asks for one in place, the way Attach does, and the
  page comes back to that act once the server is saved.
- `rooms-web --export-static=<directory> --base=<path>` writes the page as
  plain files for any static host. It replaces only an export it wrote, and
  a failed export leaves the one in place untouched.
- A session's home directory is chosen in Settings. A room joined without a
  directory address opens there, the choice is offered again after a Rooms
  server restart, and a home that stopped answering stays visible.

### Changed

- The release workflow points the Racket package catalog at each release's
  binding archive and installs the package from the catalog, so a release
  reaches Racket users without a maintainer editing the catalog entry.
- `--allow-origin=` with an empty value lets no other page in, and an option
  given without its value names the form the help shows.
- A session opens without a relay, and a page that did not open says why,
  with **Reload** on a tab that has chosen no session.
- Closing a Rust browser channel answers only a failure to retire the socket
  itself. A channel that failed earlier closes cleanly, and that first failure
  stays the answer to its reads and writes.

## [0.1.4] - 2026-11-06

### Added

- A browser bundle with prebuilt JavaScript, matching Wasm, and a complete WebRTC
  example. Serve its files directly without a compiler or repository checkout.
- Prebuilt WebAssembly libraries that the Rust crate downloads when building
  for the browser.

### Changed

- Reduce event-queue overhead while preserving capacity reserved for promise
  retirement.

### Fixed

- Refresh build command environments on every invocation so release checks
  use newly installed tools and the current GitHub step settings.
- Load browser Wasm from ordinary binary responses as well as streaming Wasm
  responses, and report HTTP errors before trying to compile them.
- Complete package setup examples, correct browser relay routes, and use
  installed Racket collection imports.
- Verify newly published JSR packages without waiting for Deno's dependency
  age window. The release check imports all nine packages and keeps the age
  policy for third-party dependencies.
- Resume partial release uploads with the original checksums, attestations,
  and release notes.
- Ship the Racket binding as a release archive. The catalog can install it
  without checking out repository symlinks that Racket refuses to extract.

## [0.1.3] - 2026-11-06

The release build failed before publication. Its changes ship in 0.1.4.

## [0.1.2] - 2026-11-05

### Added

- Build-time interface generation feeds the Tasks client from authored Tasks
  and shared Loam definitions. Rust calls check declared replies and keep
  prepared mutation requests for explicit replay. Creation and read handlers
  in Zig check their declared arguments and results.
- Generated Rust and TypeScript callers preserve positional calls, named
  methods, omitted arguments and explicit undefined values. Both decode lists,
  tuples and tagged records. TypeScript keeps arbitrary bigint integers and
  checks text bounds in UTF-8 bytes.
- Interface text supports rooted imports and positional containers. The
  compiler checks the complete authored bundle against independent Syrup
  descriptions. These are qualified projections, not a general-purpose
  interface compiler or an adopted language.
- Rust `Ref::retain_for` owns a capability independently of the original
  reference's explicit release. Prepared Rust calls retain their target and
  reference arguments before acquiring a mutation sequence.
- Product and C SDK archives include the original license and attribution
  texts for their bundled Rust and JavaScript dependencies.

### Changed

- Zig event consumers use `Event.kind()` instead of `Event.tag` and access
  wire data only on wire events. For cross-session promise forwarding, custom
  `Node` embeddings install `Node.pipeline_projection` and dispatch callable
  deliveries and retirement events in FIFO order. `Host` handles both.
- Zig driver callers replace `AcceptIdentity` with `Identity`. Keyed
  identities use `.keyed = key` instead of a secret/designator struct. The
  unused designator override and `dialedDesignator` helper are removed.
  Caller-supplied iroh endpoints must share the Host's identity seed.

### Fixed

- Calls queued on a promise keep working when it settles to an object on
  another session. Forwarded capability replies retain their references until
  their owners release them. If allocation failure prevents even a failure
  reply, the source session closes rather than leaving the call pending.
- Callbacks can claim a reference's session when an ordinary Host call drives
  the callback outside `step`. A released session cannot be reclaimed while
  its teardown is pending.
- The Racket iroh connector uses its Host's identity for the endpoint. The
  Goblins iroh adapter checks claimed locators against authenticated endpoints
  even with tracing disabled.
- The Goblins Rooms peer rejects calls and late introductions to a DM inbox
  after its registration ends, including when someone reuses the nickname.
- A refused TypeScript `Host.close` leaves the Host usable and keeps later
  errors visible.
- Rooms link previews reject non-public special-purpose IPv6 destinations
  and the local-use NAT64 prefix.
- Goblins comparison runs stop on failed or stalled children instead of
  retrying failed samples or counting them as successful measurements. The
  performance pages contain a complete fresh run and label language
  throughput in task-board units.
- Build-step documentation checks use the same reference graph regardless
  of the caller's optimization flags.
- The Racket catalog setup uses a Git source URL, so the package manager
  checks out the selected release and its binding directory instead of
  treating the GitHub page as a package download directory.
- TypeScript packages imported over HTTP load their bundled release settings
  without treating the module URL as a local file path. Published JSR imports
  can use the versioned SDK cache and automatic downloads.
- Generated TypeScript calls support checked `await` while preserving raw
  pipelining. The export name `then` is refused, but a wire method can still be
  named `then`.
- The interface CLI refuses output paths that name an input or import, including
  symlink aliases. It writes output atomically and preserves existing regular
  file permissions. Invalid targets, selections and API names report contextual
  errors without a Zig trace.
- Tasks clients in Rust, TypeScript, Python and Racket order mutations per client
  while allowing reads to proceed independently. Overlapping identical actions
  no longer collapse into one receipt.
- A failed first watcher poll in TypeScript, Python or Racket attempts
  cancellation and preserves the original failure alongside any cleanup error.
- Rust and TypeScript clean up discarded references in generated and internal
  replies, and after failed fetch/enliven calls, when automatic release is
  disabled. Successful manual results keep their existing release policy.
  JavaScript aliases retain their shared finalizer lifetime.
- A failed session open or handshake keeps its original error when channel
  cleanup also fails. Cleanup runs once and remains visible beside that error.
- The portable deadline wrapper reaps children that exit during group signalling
  on macOS, while preserving real signal-permission failures.
- Pending calls settle with their original failure when progress or close
  fails. Cleanup failures preserve the primary construction error.
- Rooms and its test processes use the ports their children actually bind,
  avoiding races from choosing a free port before starting a listener. Room
  selection waits for directory registration before opening the session.
- The TypeScript argument encoder rejects sparse arrays instead of silently
  converting missing slots into integer zero.
- The C SDK archive ships the WebRTC transport's shared library and header
  beside the iroh one, so the Rust crate's `webrtc` feature links against the
  release SDK instead of failing to find `libglowcap_net_transport_webrtc`.
- Every `@glowcap/*` package publishes to JSR. The runtime's generated FFI
  loaders and the relay's serve entry reach their own package by relative path,
  which JSR requires, and the browser import maps carry the file entry that
  keeps the Wasm adapter in place of the C library loader.
- The package pages on crates.io, PyPI, JSR, and the Racket catalog read as
  package home pages: each opens with the package name and install line, leaves
  the package only through absolute links, and keeps contributor checks in the
  repository. Every `@glowcap/*` package ships a README, and `source-check`
  holds both rules.
  First-run examples name their server and runtime requirements. The Zig
  package's README links work without a repository checkout.

## [0.1.1] - 2026-10-31

### Added

- Rust, Python, TypeScript, and Racket packages are published from the release
  tag: `glowcap` on crates.io and PyPI, `@glowcap/*` on JSR, and `glowcap` in
  the Racket catalog. Each downloads the C libraries of its version on first
  use and verifies them against the release checksums.
- Release notes carry a platform download table, verification and install
  steps, a package install section, and this changelog's entry for the version.
- Every release archive, the checksum file, and the Rooms container image
  carry a build provenance attestation that `gh attestation verify` checks
  against this repository. The provenance bundle of each download is published
  beside it for offline checks, and the image's software bill of materials is
  attested with the image.
- The C SDK archive ships a README with a runnable C example.

### Changed

- A binding outside a checkout downloads its own version unless
  `GLOWCAP_SKIP_DOWNLOAD` is set. Inside a checkout it uses `zig-out` and
  downloads only with `GLOWCAP_DOWNLOAD`. The contract's `releases_published`
  switch is gone.
- Release archives omit empty directories, and their README and provenance
  links resolve from an extracted archive.

### Fixed

- A release whose archive or image job was skipped is refused instead of
  publishing nothing. Publication can be recovered from the signed tag's
  original run without rebuilding or moving the tag.

## [0.1.0] - 2026-10-31

### Added

- The first tagged release: CapTP 1.0 over Syrup with signed sessions, the
  Zig library and C ABI, the Rust, TypeScript, Python, and Racket bindings,
  Loam transactional storage with durable actors, the `glowcap` CLI, and the
  Rooms application with its container image. [What ships](docs/shipped.md)
  describes the release in full.

[Unreleased]: https://github.com/glowcap-org/glowcap/compare/v0.1.6...HEAD
[0.1.6]: https://github.com/glowcap-org/glowcap/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/glowcap-org/glowcap/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/glowcap-org/glowcap/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/glowcap-org/glowcap/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/glowcap-org/glowcap/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/glowcap-org/glowcap/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/glowcap-org/glowcap/releases/tag/v0.1.0
