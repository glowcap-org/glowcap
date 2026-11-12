---
type: living
description: What each part of Rooms does.
sources: []
---

# What Rooms ships

Rooms is a chat application built on glowcap. The [Rooms page](README.md) is
the way in, and [operating Rooms](operating.md) covers its grants, services, and limits.

- *One implementation.* A single Rust implementation owns room and directory policy, durable authority, the session
  and its recovery, files, archives, operations, peering, IRC, and the bounded CommonMark message rendering. It runs
  as the room server, the session service, the archive service, the web server, and the two IRC edges. In the
  browser it runs as Wasm, linked with glowcap's Zig Host in one module, and React renders what Rust observes.
- *Session declarations.* `rooms-application::content` owns the versioned codecs for the workspace, the storage a
  session holds, and effects, plus permission requirements, presets and browser metadata. Shared Loam checks
  dependencies and whether a declaration applies to a session.
  The [session graph trace](rust/proofs/src/session_storage/mod.rs) checks recovery when a commit or abort has an
  unknown outcome, reloads, and receipt replay. The [foreign trace](rust/proofs/src/session_foreign/mod.rs) fills
  the store to its page limit, restores it cold, and survives a full reload of the source page while the peer that
  exported it stays up. The [session guide](../../docs/rooms/session.md) describes production ownership and recovery.
- *Browser workspace.* The exported `RoomsManagedApplication` opens the tab's IndexedDB workspace with separate
  use and management handles. It keeps commands, uploads and management edits until they settle, acquires storage
  atomically, and mediates readers and observations. Prepared lifecycle edits recover their exact mutation receipts on retry.
  The main chat page and Rust session process use this managed owner, with the same codecs, admission and receipt recovery.
- *Incoming calls.* A directory or room action selects its exact live inbox and the grant that started it.
  - Each inbox has its own worker. It checks admission again before delivering a call, shares one bounded
    queue with the rest of the session, and drains pending calls before it closes.
  - The main page supervises directories, rooms, and direct lines on its own. A known connection failure is
    reported before restoring waits, and healthy neighbors keep running.
  - Watching the peer that exported a direct line starts before the line is ready, and keeps going if the
    workspace refuses to expire it.
  - An ended route displays **Closed** and keeps its draft and history. Current room rosters remove departed
    members independently of their directory registration and direct conversations.
- *Direct openings.* One directory call waits for the exact registration's inbox, and the client allows
  that wait plus redemption. Waiting for a signaling route has its own bound, and the directory bounds how
  many calls wait. The [session guide](../../docs/rooms/session.md) holds each bound.
  The managed command is admitted once and retains one receipt through acquisition and recovery.
- *Work admission.* Configurable process-local budgets cover peer work, validated shared grant ancestry,
  receiving direct callbacks and expensive HTTP starts. Refusals preserve drafts and exact effect outcomes.
  Reconnects retain debt, and cleanup has its own allowance and its own incoming-call storage.
  The [admission guide](../../docs/rooms/admission.md) owns configuration and attribution.
- *Messages.* A message keeps its authored source on the wire and in archives. Raw HTML stays inert, remote images
  never load on their own, and links may use only approved schemes. A message can preview at most five validated
  URLs, which readers fetch through a same-origin service that refuses unsafe redirects and private addresses.
- *Room subject.* A room's subject is a description, and it may also link an object by its sturdyref. The room
  parses the link before it accepts the subject, shares it with every reader, and never calls the object, which its
  setter hosts. A linked subject survives a server restart, and a later member can redeem the link and call the
  object ([proof](rust/services/src/server/tests/rooms/subject_link.rs)). The browser shows the link to copy.
- *Sending.* A Rust room sender rebuilds its ordered receipt from retained text, and releases rejected requests even
  after the caller cancels. It reuses acknowledged, immutable upload bytes for local display and recording, while
  other members still receive the complete message.
- *Pending work.* A user action stays owned until it settles and its result arrives.
  - Shared controls delay progress decoration and announce a delayed wait.
  - Draft sync keeps local text and a persistent refusal.
  - Line edits project over the accepted line until their one explicit outcome.
  - **Session settings** opens the list of kept receipts, and local reads and acquisitions keep their declared
    bounds.
  - Correlated room echoes preserve optimistic bubble identity.

  The [UI contract](web/ui/README.md#failures-and-pending-work) names timing, budgets and recovery behavior.
- *History.* Rooms keep their last lines in files under the state directory, behind one index that applies the limits before a write.
- *Failure reporting.* Operations credentials follow the retry class of their failure, and IRC numerics follow stable
  failure codes. Direct-message cleanup tells a departed registration apart from a partner whose close stalled.
  A room change whose acknowledgment cannot be read stays unknown, because only a refused send proves the change
  did not happen. A live proof applies one policy change, then returns a malformed reply, and checks that the
  change is still reported as unknown.
- *Sessions and skills.* `glowcap apps rooms session` exposes the Rooms session through the Zig command tree. The
  individual and team skills share its lifecycle and local inbox. They observe every joined room and DM and keep each
  event until it is acknowledged. One `session listen` consumer delivers each event once per run, replays
  unacknowledged events after a restart, and stays quiet between changes. A failed inbox observer reports its gap
  without stopping other views of the session. The process proofs cover several rooms, private replies, restarting
  with unread events, and a browser DM over a DataChannel.
- *Session WebRTC.* Started with `--dial-transports=webrtc`, the session process reaches a WebRTC browser member
  directly, signaling through the room that introduced it, and answers a member's offer that a room it belongs to
  delivers. It gathers candidates through `--ice-servers`.
- *Direct-message routes.* **Direct message connection** in Settings is a preference whose default is marked.
  **Fastest**, on a page with a Rooms server, lists the member under one identity route naming WebRTC and the
  server's sealed relay, which a dialing Host races, keeping the first to prove the key
  (`zig build rooms-web-dm-fastest`, with every non-proxied UDP route disabled). The server embeds the route a
  member registered in every handoff it mints for that member's inbox, and the member's own hello names WebRTC
  with the relay as advice. On a page with no server, Fastest is browser to browser, the one route the page
  has, and the section says so instead of drawing choices.
- *Chosen routes.* **Browser to browser** advertises WebRTC with the relay as the route the Host tries after
  the direct attempt fails, within a bounded time (`zig build rooms-web-dm-fallback`). **Through the server**
  advertises the relay alone. The conversation card's **Path** fact names the route the open line runs over,
  read from its live session.
- *Packaging.* The [glowcap product package](host.md) includes the CLI, the private Rooms runtimes, the
  prepared browser application, and both skills. `glowcap-pack` serves the browser assets and repeats the process
  proof from an extracted installation, with no checkout tooling or library-path overrides. `glowcap-package-test`
  checks the package and image inventories and the archive publication fixtures, including checksum failures, rename
  failures, and termination signals. These checks do not claim that any archive or release has been published.
- *Addresses.* A join, room, or directory URL names its room and destination after `#`.
  Reload and browser history preserve them, and HTTP requests to the page host omit them.
  Session-attachment offers preserve those fields in the same fragment.
- *Published page.* `rooms-web --export-static` writes the page as plain files for a static host at one base path,
  and the website publishes that export at `/rooms/app/`. A browser uses one Rooms server: the one that served the
  page, one a link offers and the reader accepts, or one chosen in Settings. A Rooms server admits the published
  page by default and other pages through `--allow-origin`, and every printed link names the address
  `--http-public` gives it.
- *Page with no server.* The server is the browser's way to addresses it cannot open itself. An address it can
  open, such as a directory's sealed relay door, is reached with no server, and the directory's card says the
  route the connection took. When that door does not answer, the join card names the relay, or the browser
  standing between the page and it. An act that needs a server on a page with none asks for one before it does
  anything, saying which door failed when one did, and the act picks up once the server is saved. Typing a held
  directory's address through another of its doors re-routes the directory through that door, and it keeps its
  home mark, nickname, and registration.
- *Declared listeners.* `rooms-server` and `rooms-web` announce any listener transport
  [Operating Rooms](operating.md) lists with `--transport=<transport>`, and take `--listen=<transport>[,<name>=<value>...]` once per transport beside it.
  Every declared door is open before the server is ready, and `/locator` then names the directory by its key
  with the doors listed, sealed routes first. A relay door registers at this
  server's own relay unless `GLOWCAP_ROOMS_RELAY_URL` or the `relay` option names another.
- *Running from a checkout.* The checkout launcher builds the product if it is missing, then runs the complete staged
  installation without build tools. After editing source, run `glowcap-install` explicitly. The runtime proof exercises
  this path without a binary override.
