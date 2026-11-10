# Changelog

Every release lists what changed for people using glowcap, in the form
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) describes. The
release notes on each [GitHub release](https://github.com/glowcap-org/glowcap/releases)
open with that version's section, so a release needs its section here first.
glowcap is alpha software, and a minor or patch version can change APIs, ABIs,
and storage formats before 1.0.

## [Unreleased]

### Changed

- Zig's `HostRuntime.tcpBackendStatus()` reports the Linux completion backend
  selected for its stream stack and the reason for falling back to epoll.
- Documentation describes the published alpha, explains release pinning and
  upgrade precautions, and removes completed publication setup from the
  roadmap. The website's source quick start uses the checked `main` branch.
- Public guides explain Rooms connections, sharing, and upgrade recovery, and
  correct binding and storage contracts. Detailed Zig actor integration lives
  in the Loam actor guide beside its lifetime rules.
- The Rooms operations guide keeps long options and links in scrollable
  examples so they do not widen the page on phones.
- Direct messages between browsers try WebRTC and the Rooms server at once
  and keep the first route that opens, which is often the server. This is
  **Fastest**, the default in Settings under **Direct message connection**,
  on a page with a Rooms server. On a page with no server the route is
  browser to browser, and the section says so instead of offering choices.
  **Browser to browser** prefers a direct route and **Through the server**
  uses only the server. The server embeds the route you
  registered in every introduction it makes for you, so the route you chose
  is the one others dial.
- A browser whose Rooms data was created before this release keeps
  **Browser to browser**. Choose **Fastest** in Settings to race both routes.
- A direct message that finds no route on a page with no Rooms server opens
  **Choose a Rooms server**, which saves the conversation to return to.

### Fixed

- A direct message in **Browser to browser** mode opens through the Rooms
  server within a few seconds when WebRTC finds no route. The direct attempt
  waited for the browser to report a failed connection, which a network that
  yields no candidates never does, so the introduction gave up before the
  server route was tried. The signaling exchange now gives up after ten
  seconds on every side, the browser, the server, and the Deno and Rust
  clients, and the answering browser ends an attempt that found no route
  without reporting a failure. The conversation card's **Path** fact now
  names the route the open line took instead of the saved choice.

## [0.1.6] - 2026-11-10

### Added

- `glowcap apps rooms page` prints the link that opens the Rooms page with
  the running server filled in. `rooms-web --page-link` and the server's
  `/page` route answer the same link, and `deployment up` prints it first.

- `rooms-server` and `rooms-web` announce any of the seven listener
  transports with `--transport=<transport>`. A relay transport registers at
  `--relay=<ws-url>` or `GLOWCAP_ROOMS_RELAY_URL`, and under `rooms-web` at
  that server's own relay. `--relay-public=<ws-url>` names that relay as
  peers dial it when a port forward or a proxy gives it another address, and
  `rooms-web --http-public=<url>` does the same for its own relay. The
  installed `glowcap apps rooms` commands take the same listener options,
  `serve` with `--listen` and the shared session's as `--session-<option>`,
  and `session start` keeps every one of them in its settings.

- `rooms-web --session-transport=<transport>` chooses the shared session's
  announced listener the same way, and `--session-<option>` passes any other
  `rooms-session` option to it. A relay listener registers at that server's
  own relay unless `--session-relay` names one, an onion listener publishes
  through the private Tor the server runs, and the page is offered the
  session through any listener a browser can open.

- A relay listener whose configuration names a relay alias advertises the
  alias in its `rendezvous-relay` hint. Behind a port forward or a proxy,
  peers dial the route they reach while the listener's own register socket
  opens at the route it reaches.

- The relay admits dials of one registered directory at the rate its peer
  may register, so a tighter registration bound throttles the whole directory.

- A relay that cannot complete a dial closes the browser's socket with the
  cause, and the page's channel reports that cause instead of a bare
  connection close.

- `rooms-server --listen=<transport>[,<name>=<value>...]` (or
  `GLOWCAP_ROOMS_LISTEN`) opens another listener to the same directory, once
  per transport, and the server starts only once every declared listener is
  open. The address it prints then names the directory by its key with every
  listener listed.

- The Rooms page reaches a directory through a sealed relay listener the
  directory declares, with no Rooms server chosen, and the directory's card
  says the route the connection took.

### Changed

- `--capabilities=all`, or `--capabilities=<name>[,<name>...]`, tells
  `rooms-server` and `rooms-web` which operator capabilities to mint, with
  `GLOWCAP_ROOMS_CAPABILITIES` as the variable. It replaces the six flags
  `--admin-listeners`, `--diagnostics`, `--operator`, `--peering`, `--irc`, and
  `--trace` and their variables, so name the capabilities you want in one list.
  A deployment or script that set those variables mints nothing until it
  names the capabilities in `GLOWCAP_ROOMS_CAPABILITIES`. Reading the kept
  capabilities again is `glowcap apps rooms capabilities`, or
  `rooms-web --print-capabilities`, which takes the locators from the running
  web server, from `--url`, or from `GLOWCAP_ROOMS_LOCATOR`. `rooms-server`
  no longer reads them, and `glowcap apps rooms directory capabilities` is
  gone.

- The shared session writes its use link to `use.sturdyref` and its management
  link to `management.sturdyref` in the state directory, the names every page
  gives those links. The managed deployment's readiness file is
  `/run/rooms-session/use.sturdyref`. Both files are rewritten at every start,
  so an existing state directory needs no change.

- Four Rooms page names changed. The Settings tab **Reachability** is
  **Connection**. The Operations tab **Directory** is **Operator**. The
  Settings act **Delete local session** is **Empty this session**, since it
  empties the open session and the browser stays on it, and the shared
  session's **Reset shared session** is **Empty this session for everyone**
  for the same reason.

- Rooms page copy says link, session, and message where it said capability,
  workspace, and line. On a room card, the **Capabilities** tab is **Links**,
  and every button on it grants, revokes, or discards a link.

- The Rooms deployment's managed Compose file holds only the settings every
  deployment shares. Every setting a host chooses lives in
  `docker-compose.override.yml`: the public address, allowed pages, trusted
  proxies, trace routes, TURN, and admission overrides. The example override
  shows public hosting behind an HTTPS proxy. A variable exported in the
  shell that runs `deployment up` does not reach the services: move it
  into the override.

- `glowcap apps rooms deployment reset directory` names the unit that was
  `state`, and `deployment up` prints the directory locator and the shared
  session's use link and management link under those names.

- **Delete browser data** in the Rooms page also forgets every Rooms
  preference this browser kept: the chosen server, other tabs' session
  choices, and the theme. Other open Rooms tabs reload.

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
  peer, and holding an operator capability judge the pasted link by the
  listeners its address names, so a session shared from another browser
  attaches with no Rooms server. The ask comes only for a link this browser
  cannot open on its own, and a break on the way to a session reached through
  its relay listener names that relay.

- A blank directory address on a page with no Rooms server is refused on its
  own field instead of asking for a server.

- The Session tab offers its unfinished-changes list only while a change is
  unfinished, and the Connection tab drops this browser's own address,
  which nothing on the page accepted.

- `rooms-web` serves its page before its directory is up, so the directory's
  relay listeners can register with it, and `/locator` waits for the directory
  instead of answering that there is none.

- `GLOWCAP_ROOMS_SESSION_STATE` serves the shared session the way
  `--session-state` does, and the option wins when both are set.

- The host bindings in Rust, TypeScript, and Racket name a transport they have
  no connector for as `UnknownTransport`, the name the Zig host uses for the
  same condition, so one reader recognizes it from every binding.

- A C ABI content registration holds up to 128 methods, where it held 64. A
  registration over the cap is refused with `GLOWCAP_ERR_INVALID_ARGUMENT`
  and the last error `loam: TooManyMethods`, so a too-long method table is
  told apart from a missing callback.

- `rooms-web` prints one block at startup: the addresses first, then the
  links to keep private under their own heading. A directory it runs hands
  its `ROOMS-*` links to that block, and a restarted directory prints its
  new links under the same heading. The directory's work budgets and their
  counts read on the operator page under **Work budgets**. The HTTP,
  browser, and session budgets come from your own arguments and are not
  printed.

- The operator page's **Rooms and their links** section lists every room
  someone is in and every room a link or a saved record stands for,
  including rooms nobody is in, one line per room with a tag for each link
  that stands. **Links…** opens a card for that room where each link is
  issued, copied, and revoked. **Forget room** removes the room entirely:
  its members, every link, its subject, its kept messages, its name, and its
  settings. An IRC bridge's row takes no manager link and cannot be
  forgotten here, and says so. A room's row carries each link itself in
  place of an issued flag, and issuing a link answers the row as data, so
  nothing enters the session's storage. The factory reset says that it
  clears manager links too.

- Anyone in a room can take its manager link or moderator link there,
  however they came in, and the room card's links tab says so. A room
  answers its identity digest and its manager's identity to anyone in it,
  which is how a link is checked against the room. A digest opens nothing.

- Commands answer where you typed them. `/link`, `/moderator`, `/kick`,
  `/subject`, `/msg`, and `/invite` say the link, the refusal, or the way in,
  in the conversation. `/link <room>` for another room you are in answers in
  place, and for one you are not in says to join it first. `/invite` in a
  room you joined by name says the room is not yours to hand on and names
  the way in.

- `/msg` and `/invite` to a name nobody registered say so. `/whois` in a
  direct message answers about the person on the other end. Sending a third
  line while two are still on their way says so.

- Commands take exactly their arguments. `/msg`, `/invite`, `/kick`,
  `/whois`, `/ignore`, and `/unignore` take one name, with or without `@`,
  and the completion list sends on the first Enter when the argument is
  written out. `/leave`, `/clear`, `/details`, `/members`, `/help`,
  `/directories`, `/quit`, and `/delete` take none. A line that looks like a
  command but names none, such as `/ignored` or `/msg@bob`, is refused with
  a pointer to `/help`. Text that cannot be a command, such as `/etc/hosts`,
  is still a message.
- `/link <room>` names a listed room you are in and answers the link you
  hold for it. A link is created from inside the room itself.
- A page opened without the **Share keys and links** permission says so
  where a link would show, in the room card's links tab and from `/link`.

### Fixed

- Every Rooms tab, including a reloaded one, shows and shares the address
  each directory was dialed through instead of its bare identity. A page
  opened with any access link reads that address, never the link's secret.

- Under `rooms-web`, the directory and the shared session dial the server's
  own relay at the address `--http-public` names, which reaches both of
  them. `rooms-web` refuses `--relay-public` and `--session-relay-public`
  for a peer on its own relay. An address given to one peer left the other
  dialing the relay's bound address, and a shared session in a container
  then answered a directory join with a bare `PromiseBroken`. Both options
  still apply to a peer whose `--relay` or `--session-relay` names another
  relay.

- A saved directory, room, or direct conversation the shared session refuses
  to start is reported once as a standing refusal when its code says the
  condition clears only with a change. It is started again only on an
  explicit retry or a changed row, and the session's recovery timer rests
  while only such refusals stand. A saved address on a transport the session
  does not dial is one such refusal, `saved-transport-unavailable`. Before,
  the session dialed the address on every recovery wake and told the operator
  a bare `RestorationFailed: UnknownTransport` every few seconds. Enter the
  directory's current address on its card to re-route it.

- The page frees a change the session refused and reports the reason, for
  every kind of change it submits. Before, it listed such a change as gone
  through, with a **Finish** that resubmitted it. A change that went through
  but could not be shown here can be let go, and stays saved in the
  session. A change nothing settled is listed with its outcome unknown and
  can be let go.

- **New access** and **Prepare control** from a held management control ask
  for a Rooms server only when the control is this browser's own, whose links
  lead here. Any other control, such as one for a session attached by its own
  address, publishes the access at the session it manages.

- A sturdyref naming a peer by its key through a sealed listener, such as a
  directory's bare `noise-relay` address, redeems over the sealed session
  whatever listener the peer's hello advertised. Before, the Rooms page
  failed such a join with `PeerIdentityMismatch`.

- A directory address typed on the join card re-routes a directory the
  session already holds. The capability is fetched through the listeners the
  typed address names and replaces the held one under the same id, and a
  directory that was your home directory stays it. Before, the held route was
  kept whatever was typed, so a page with no Rooms server asked for one when
  that route needed a server. The held route typed again changes the nickname
  at most.

- A `keyed-tcp` or `noise-tcp` directory under `rooms-web` is forwarded to
  from the page the server serves. Before, the server announced no local
  endpoint for those listeners and the relay answered `directory forwarding
  unavailable`.

- Saving an operator capability whose address names the directory by a
  key its listener does not prove (`keyed-relay`, `keyed-tcp`) says so and
  names the listeners that prove it, where it showed a bare
  `PeerIdentityUnverified`.

- The relay transport and the Rooms server reject TLS certificate paths
  through the distrusted emSign intermediates (rustls-webpki 0.103.16,
  RUSTSEC-2026-0382).

- `rooms-web` took the last of a repeated option and dropped the rest without
  a word, so `--allow-origin` given twice let only the second page in. It
  reads its options the way every other Rooms command does. A repeated option,
  an unknown one, or a port named both as an option and positionally is
  refused by name. `--allow-origin` repeated extends the list, the same as one
  comma-separated list. The defaults `zig build rooms-web` and `rooms-dev`
  supply arrive as environment, so an option typed after `--` is the only one
  of its name. `rooms-dev` names the backend options it owns instead of letting
  `rooms-web` refuse them as repeats.

- A forwarded call inside a Rooms server kept no delivering
  session, so the directory card showed no transport and direct messages from
  different senders counted as one sender. `current_session()` in the Rust
  binding names that session.

- `/join` with the link of a room you are already in keeps that one row in
  the sidebar and your place in it, and the link becomes the room's way
  back in after a restart. It added a second row for the same room.

- The operator page lists a room nobody is in while a link or its record
  stands, issues its manager link there, and **Forget room** removes it. A
  room nobody was in kept refusing a revoked manager link with no row to
  see, a manager link could be made only from inside the room, and a room
  made through a manager link kept its row after every link was revoked.

- Closing a room from the operator page reaches every member's sidebar: the
  row drops its roster, shows that you are not in the room, and the room
  says an operator removed it. The row looked unchanged.

- The operator page's resets and row removals keep the operator's own
  nickname and connection. A factory reset took the name away, which left
  the page unable to act under it.

- The operator page's **Browser trouble** list shows a failure nobody has
  worded exactly as the browser reported it. It added advice to try again
  when no action had been taken.

- A room handed to you by `/invite` showed an empty room link, and revoking
  it failed with a code. The room card now says the room was handed to you,
  that `/invite` hands it on, and that a room manager can create a link.
  `/link` from such a room says the same, and a manager creates the link
  from there.

- `/leave #other` left the room you were in. `/kick`, `/moderator`, and
  `/link` showed a generic failure notice with the reason lost. A manager or
  moderator link taken by someone who entered by name or by invitation was
  refused with a code and no words.
- `/invite` sends the room link when you hold one, so the invited person
  keeps the room across a refresh. It handed a live reference that ended
  with the page.
- **Forget room** refuses before anything changes when the history writer
  is busy. It could drop the room's links and keep its messages. Its kept
  messages are deleted under the name as stored, so a room forgotten by a
  name in another case leaves no file behind.
- An IRC bridge's row offers no manager link and no **Forget room**. It
  offered both, and the server refused each after the press.
- The operator page shows **Work budgets** when it holds the diagnostics
  capability too. It showed them only without the operator capability.
- Closing the links card after **Forget room** leaves focus on the list
  instead of dropping it.

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
