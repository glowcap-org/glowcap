# What Rooms ships

Rooms is a chat application built on glowcap. The [Rooms page](README.md) is the way in, and
[operating Rooms](operating.md) covers its grants, services, and limits. This page lists what each part does
today.

- *One implementation.* A single Rust implementation owns room and directory policy, durable authority, the session
  and its recovery, files, archives, operations, peering, IRC, and the bounded CommonMark message rendering. It runs
  as the room server, the session service, the archive service, the web front, and the two IRC edges. In the
  browser it runs as Wasm, linked with glowcap's Zig Host in one module, and React renders what Rust observes.
- *Managed session declarations.* `rooms-application::content` owns versioned workspace, custody and effect codecs,
  permission requirements, presets and browser metadata. Shared Loam checks dependencies and session applicability.
  The [session graph trace](rust/proofs/src/session_storage/mod.rs) checks unknown commit/abort recovery, reloads and receipt replay.
  The [foreign trace](rust/proofs/src/session_foreign/mod.rs) cold restores 3,592 distinct fields in 64 pages
  under derived quotas and across a full source-page reload with a surviving exporter. The [session guide](../../docs/rooms/session.md) describes production ownership and recovery.
- *Managed browser workspace.* The exported `RoomsManagedApplication` opens the tab's IndexedDB owner with separate
  use and management handles, retained commands/uploads and management edits, atomic custody acquisition,
  mediated readers and observations. Prepared lifecycle edits recover their exact mutation receipts on retry.
  The main chat page and Rust session process use this managed owner, with the same codecs, admission and receipt recovery.
- *Managed callback custody.* Directory and room intent select their exact live inbox and initiating grant.
  An owned inbox worker checks current admission before delivery, shares a bounded session queue budget,
  and drains pending calls before closing. The main page consumes automatic directory, room and direct supervision.
  Known connection failures are reported before restoration waits, preserving healthy siblings and exact source authority.
- *Messages.* A message keeps its authored source on the wire and in archives. Raw HTML stays inert, remote images
  never load on their own, and links may use only approved schemes. A message can preview at most five validated
  URLs, which readers fetch through a same-origin service that refuses unsafe redirects and private addresses.
- *Sending.* A Rust room sender rebuilds its ordered receipt from retained text, and releases rejected requests even
  after the caller cancels. It reuses acknowledged, immutable upload bytes for local display and recording, while
  other members still receive the complete message.
- *History.* Room history is stored in files or PostgreSQL behind one index.
- *Failure reporting.* Operations credentials follow the retry class of their failure, and IRC numerics follow stable
  failure codes. Direct-message cleanup tells a departed registration apart from a partner whose close stalled.
  Room effects retain uncertainty after unusable acknowledgments; only refused dispatch proves absence.
  A live manager proof applies one policy change before returning a malformed reply and preserves that distinction.
- *Sessions and skills.* `glowcap apps rooms session` exposes the Rooms session through the Zig command tree. The
  individual and team skills share its lifecycle and local inbox. They observe every joined room and DM and keep each
  event until it is acknowledged. One `session listen` consumer delivers each event once per run, replays
  unacknowledged events after a restart, and stays quiet between changes. A failed inbox observer reports its gap
  without stopping other views of the session. The process proof covers several rooms, private replies, and
  restarting with unread events.
- *Packaging.* The [glowcap product package](host.md) includes the CLI, the private Rooms runtimes, the
  prepared browser application, and both skills. `glowcap-pack` serves the browser assets and repeats the process
  proof from an extracted installation, with no checkout tooling or library-path overrides. `glowcap-package-test`
  checks the package and image inventories and the archive publication fixtures, including checksum failures, rename
  failures, and termination signals. These checks do not claim that any archive or release has been published.
- *Running from a checkout.* The checkout launcher builds the product if it is missing, then runs the complete staged
  installation without build tools. After editing source, run `rooms-build` explicitly. The runtime proof exercises
  this path without a binary override.
