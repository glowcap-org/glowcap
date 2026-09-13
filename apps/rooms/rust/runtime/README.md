# rooms-runtime

This crate runs a Rooms session. It takes the policy in `rooms-application`
and the capability clients in `rooms-glowcap`, and it orders their effects on
whatever platform the embedding supplies: storage, clocks, entropy, tasks, and
transports. The native `rooms-session` binary and the browser page both embed
it, and neither one carries a second copy of the session's logic.

Read this page when you are embedding a session on a new platform, or when you
need to know which module owns an effect before you change it.

## What the embedding supplies

Every effect the session needs arrives through a trait the platform implements.
The crate never reaches for an OS or a browser API on its own.

| Trait | Module | What it supplies |
| --- | --- | --- |
| `Clock` | `clock` | Monotonic time and `sleep_until`, for deadlines and retries. |
| `WallClock` | `wall_clock` | Unix milliseconds for message timestamps, kept separate so a deadline never depends on a wall clock that can jump. |
| `Deadline`, `Tasks` | `rooms_glowcap::client` | A bounded wait and task custody. Dropping a task cancels it; detached background work is not allowed. |
| `Entropy` | `entropy` | Cryptographic bytes for identifiers and keys. Cloning a runtime handle never clones a generator. |
| `Documents`, `Document` | `documents` | Exclusive custody of the checkpoint and effects pair, and of single fixed-role documents such as grants and bridge secrets. |
| `archive::Backend`, `archive::Source` | `archive` | Committed archive storage and bounded file reads. |
| `Visualization` | `service` | The trace transport the session publishes its live picture through. |

`platform::Platform` names the bundle a room or direct-message effect needs:
`Clock`, `WallClock`, `Deadline`, and `Tasks` on one cloneable value. The
native crate satisfies it with `rooms_platform::HostPlatform`, the browser
crate with its own `platform::Platform`.

Two rules hold across every adapter. A storage adapter keeps admitted work
alive when its observer stops waiting, and recovery calls `finish_pending`
before it reloads, so an uncertain write stays uncertain instead of being
guessed. And storage errors keep their concrete platform type all the way up:
the session's own errors for policy, admission, and CapTP causes stay distinct
from them.

`documents::VolatileDocuments` is the one adapter this crate ships. It holds
the checkpoint and effects bytes in memory for its own lifetime, which is the
right owner for a tab-hosted session that lives exactly as long as its browser
Host. Workspace preferences and archive records have their own persistence.

## Opening a session

The embedding assembles the owners in this order. The native binary's
`session::peer` module is the worked example.

1. Open the documents and take the grants and bridge-secret documents.
2. `SessionCommands::open(documents, platform)` returns the command handle and
   its worker. Run the worker on the application's `LocalSet`.
3. Read the identity seed from the committed checkpoint and restore the Host
   from it. The runtime adopts that Host; it never creates one.
4. Open the transports and build `directories::connections::Connections`
   around the dial.
5. Open the archive backend.
6. Call `service::Session::open` with `Inputs` (platform, connections,
   locator, entropy, trace, report), the command pair, the grants document, the
   bridge-secret document, the archive, and any checkpoint to start from.

`Session::open` starts every worker, publishes the administrator capability,
and returns the published link. `Session::open_local` does the same without
publishing, for an embedding that prepares reachability first and calls
`publish` itself. If startup fails part way, the partially opened owners close
along the same path a full session does, and the error keeps both the primary
cause and any cleanup failure.

Closing a session disables held views, removes its root publication, and
drains its owners before joining the workers. The Host remains usable
afterward; closing a session removes only that session's publications.

## What each module owns

The modules are grouped by the effect they order. A reader should be able to
name the owner of a behavior from this list before opening a file.

**Session state and commands.** `session::state` restores and reconciles the
durable checkpoint. `session::commands` admits commands against a bounded
budget, orders their durable writes, and hands the effect ledger to the
platform; a caller that drops its reply abandons observation while the admitted
work stays owned. `session::retention` erases history before it commits the
checkpoint that disables it, so a recording cannot slip in between.
`session::projection` builds the bounded snapshot the fronts read.
`session::bridge_secrets` keeps IRC bridge secrets in their own document so
they never ride a checkpoint. `cleanup`
folds a cleanup failure onto the failure it followed, keeping the first cause
first.

**Directories.** `directories::connections` acquires one bounded connection
per transport and peer identity and shares it between clients through a weak
cache. `directories::session` owns connection attempts, discovery watches,
registered names, and reconnect vouchers. `directories::runtime` supervises
attempts and reconnects with the monotonic clock and retires an obsolete
generation with the checkpoint that replaced it, before the command that
caused it is acknowledged.

**Rooms.** `rooms` realizes every intended membership, joins by link,
publication, or name, installs newly acquired manager authority before a
membership becomes visible, and owns the message pumps, line capabilities, and
staged uploads. `rooms::offers` acknowledges handed rooms durably.
`rooms::peering` and `rooms::operations` realize publication leases and
checkpoint credentials against the exact current directory connection.
Operations fetches stop automatically retrying a refused or invalid credential
and resume when it is replaced. Failures that can clear in peer state retain
a one-second backoff; the session issue tells the member whether Rooms is
retrying or needs a replacement capability. Each pass consumes elapsed retry
deadlines before starting work. A late fetch outcome cannot override a held
capability or affect a replacement directory connection.

**Direct messages.** `direct::{routes, openings, publications, dispatch}` own
reciprocal routes, coalesced openings, the bounded inbox publication, and
notice execution. `direct::{events, outgoing, commands}` share message
admission, delegated edits, typing, file delivery, and durable command
completion with the room path. A local reopening confirms a fresh inbox offer
to the directory before reporting route readiness. A peer's fresh reciprocal
capability replaces its previous route, including across connections; a
concurrent outbound opening keeps the established route. The route owner
retains responsibility for closing superseded exporter connections until no
route uses them.
A route retains exact unregister evidence when its partner leaves. Cleanup
still waits for the binding's close budget and aborts an unanswered transport;
a timeout alone is expected for that departed registration. Other failures,
including a timeout without departure evidence, remain cleanup failures.

**Files.** `files::media_files` captures a selected file once and pins readers
to it; `files::media` leases each line's selection from that pool, so a file
read by a view, an edit, and a recording at the same time has one
materialization. `files::command_files` freezes and hashes the same storage
for delivery.

**Archive.** `archive` hosts the bounded record and file methods.
`archive::session` orders local recording, peer selection, and erasure over a
`Backend`. `archive::recording` admits a recording synchronously and returns a
receipt. `archive::shares` retains received shares and refuses a retired direct
context.

**Grants.** `grants` restores durable names from a fixed-role `Document`;
`grants::commands` orders a write, its publication, and the attached-view
notification before replying; `grants::publications` keeps the published
facets consulting the committed ledger on every call.

**The service.** `service` dispatches the session protocol through `Facet`,
owns attached views, and composes every worker above through `Session`.
Deferred replies, file reads, and attachment acknowledgements share a ceiling
of 256 tasks and retire when the facet closes.

## Where the proofs live

The native crate's tests drive these owners over real files and sockets. The
browser proof drives the same owners over `VolatileDocuments` and the
IndexedDB archive in Chromium, through `zig build rooms-rust-browser-test` and
`zig build rooms-rust-browser-host-test`. `rooms-contract-proofs` replays the
portable contract fixtures on both targets. The crate itself carries no
platform-specific test, because it has no platform.
