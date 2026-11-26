---
type: static
description: How Rooms managed commands keep source admission, held targets, and recoverable outcomes across external effects.
sources:
  - resource: /apps/rooms/rust/application/src/content/session/
  - resource: /apps/rooms/rust/runtime/src/session/
  - resource: /apps/rooms/rust/proofs/src/session_executor.rs
---

# Rooms session admission and effect execution

When a session posts a line, joins a room or changes a grant, the answer can
be lost. Each such change records who made it and what it targets before it
runs, so its outcome can be found again after a crash. The
[session guide](session.md) says which code owns each part.

## Admission and receipts

`content::session::requirements` declares which permissions each change
needs. Before a change is sent, its `EffectReceipt` records the original
source, the resource incarnation, the exact target fields and the canonical
request. Typed storage resolves each selected target once. Local calls and
calls over the wire use the same executor, and a local owner holds explicit
root use and control capabilities.

The shared Host keeps an owned continuation for each change: a bounded reply
allowance and the right to complete or cancel it. The change is sent only
once its receipt is confirmed committed. If the commit aborts, the
reservation is discarded. If the commit outcome is unknown, the reservation
waits for recovery. A borrowed callback cannot outlive its turn.

Sending, recovery and protected delivery all recheck the original source and
its authority over the target. Replacing a conversation or a storage slot
cannot redirect pending work. A returned capability is kept exactly as it
came back, and a replay cannot mint a new one. A malformed acknowledgment
leaves the outcome unknown even if the change did happen upstream.

Reading back a receipt's original request needs the rights its effect needs
now, and only the source that sent it gets an answer. A source whose rights were
narrowed below its effect's since sending is refused. Resuming its executor
also needs `ResolvePending`. An operation ID cannot select another grant's
receipt.
Concurrent resumes share one sender. A changed request is refused.

`held-effects` lists the operations of the caller's own receipts that replay
pressure cannot evict: those unresolved, and those committed whose result is
not adopted yet. It takes no argument and needs only an attached access, so it
names no status and no other source's receipt. An access whose rights were
narrowed learns from it only that its own request still holds a place. A
client uses it to find a request that reached the session after the call that
sent it ended.

## The receipt window

The session keeps at most <!-- value ../../apps/rooms/rust/application/src/content/session/custody.rs MAX_EFFECTS -->8<!-- /value --> receipts for all its sources.
A new request takes a place by evicting the oldest receipt with a known
outcome, or else the oldest unknown one. A receipt that holds a place is never
evicted: one unresolved, one whose committed result is not adopted yet, or one
an executor still holds. When no receipt can leave, the request is refused
with class `receipts-full` before it runs.

Eviction is the only way a receipt leaves. A missing receipt therefore says
nothing about whether the change happened. A client never sends that
operation again, because a request sent after its receipt left runs again.

A source gives a receipt back with a release, which never deletes it. A
released receipt holds no place and answers for its operation until it is
evicted, so the same request sent again is answered from it and never runs. A
release answers one of three words:

| Answer | What the session did |
| --- | --- |
| `released` | Released it now or earlier. An unresolved receipt settles as unknown for good, an unadopted result is forfeited, and a paused executor is retired. |
| `running` | Nothing. The executor still runs, and every run settles, pauses, or stops within <!-- value ../../apps/rooms/rust/application/src/content/session/effects.rs RUNNING_BOUND_MS milliseconds -->120 seconds<!-- /value -->, except a room upload filling its files after its post, which settles when its fill ends, and a history erasure, which runs until it completes. An executor of the asking source whose commit has not settled, running or paused, answers `running` too, with no receipt held yet, because the commit may install. Another source learns nothing of it. |
| `kept` | Nothing. The source already adopted the result, so the receipt holds no place. |

A history erasure has no executor. Its receipt runs while the session's record names it as the pending erasure, including between a failed attempt and its retry, and it ends only when the erasure completes. A failing archive therefore costs two things. The receipt holds one of the <!-- value ../../apps/rooms/rust/application/src/content/session/custody.rs MAX_EFFECTS -->8<!-- /value --> places, and a release answers `running` with no time bound. Each failed attempt reaches the session's trouble report with its cause, and closing the session fails until the erasure completes.

Releasing a receipt whose result is not adopted forfeits the line's edit and
withdraw authority with it, so a client gives one back only for a result it
can never keep: a conversation that is gone, authority that changed, no room
for another kept line, or a receipt that does not decode. When keeping fails
for a reason that clears with time, such as a lost connection, a peer's
failure, a paused access, or a workspace that moved on every attempt, the
client holds the receipt and keeps the result later.

A paused executor runs again only when its source resumes it. One whose
receipt has already settled, or whose commit is confirmed never to have
landed, is retired at the next admission and frees its place. A request
whose commit has not settled holds a place no `held-effects` row names, until
the commit installs a receipt or is confirmed absent.

## Cancellation, source loss and shutdown

Cancelling a caller's wait releases only its observer. Committed work keeps
its targets and runs to settlement. Pausing or revoking the source stops any
further sending and protected disclosure, while the completed result stays
available to settle internally.

The executor distinguishes a failure before the target admitted the change
(`unsent`) from a failure after admission (`unknown`). The application receipt
decides whether the change took effect durably. If memory for the result is
refused temporarily, the completed reply is kept for a retry without sending the
change again. A reply too large, or with the wrong identity, settles as
unknown instead of retrying forever.

Shutdown drains workers before releasing their buffers. A close that fails
keeps what is left, including paused requests and the original serving
tasks, for another attempt. Its last step waits for running requests and
retires every paused one, because no source can resume one after the session
closes, and the paused request's receipt stays. Only closing credential
retention can fail after that, and such a close has already retired them. The
Host stays alive while settlement still needs it.

## Atomic acquisition

Acquisition is saving a whole workspace in one step. It keeps the source,
imported capabilities, expected revision and the complete candidate across
cancellation and retry. It needs
`ManageCustody` and `ReplaceWorkspace`. A stale revision returns a conflict
before any capability is saved or content changes. An unknown reply keeps the
original candidate. Only a confirmed conflict allows preparing it again, a
bounded number of times, through the same source.

Saving a result adopts its seat, subject, file and initiating endpoint fields
together with the request. An invalid selection imports nothing. An exact
replay changes no revision, and edits made in between refuse the kept
candidate. Receipt targets keep their own references when workspace storage
is released.

An occupied slot accepts only the same capability, with its checked role and
generation. Releasing local fields needs no working upstream grant and brings
back no earlier authority. Adopting a created room appends it through the
receipt's exact directory target and leaves unrelated fields alone. If that
directory was removed or replaced, adoption is refused.

## Exact upstream operations

Application dispatch declarations validate arguments and pick the role.
Entry, RoomAccess and RoomControl stay separate targets. Moderation, policy
edits and unregistration use the selected management capability, and missing
moderation authority never falls back to entry. `ensureRoomLink` uses
RoomControl and saves the RoomAccess it returns apart from the descriptive
coordinates.

Discovery and introductions keep the selected directory and name. Direct
conversations keep the actual inbox, source, arguments and registration
witness, and an interrupted observation or settlement keeps those same
targets. The upstream conversation's identity and generation decide history
and line identity. Session permissions add a check of their own. They never
replace the room's membership or authorship checks.

## Files and mediated readers

A room upload keeps the original RoomFiles, the optional Line and the source
blobs before anything is sent.

- Staging is confirmed before the post or refile. Staging and the post are
  one observation, and one that expires pauses the job, because nothing is
  known yet. A file staged before the pause can expire while the job waits. The post is acknowledged before the files are filled, in bounded
  pieces.
- After the post's acknowledgement the job never pauses and its receipt is
  never left unresolved by the fill. It fills in rounds, one piece of every
  unfinished file each, and a round that does not finish within <!-- value ../../apps/rooms/rust/application/src/content/session/effects.rs FILL_ROUND_MS milliseconds -->14 seconds<!-- /value --> ends the fill. The room restarts every file's lease at the post and renews it when a write crosses a multiple of the piece size or finishes the file. A file whose pieces come whole waits less than two rounds between them, which is less than the lease of <!-- value ../../apps/rooms/rust/application/src/files.rs UPLOAD_IDLE_MS milliseconds -->30 seconds<!-- /value -->, so a fill that keeps its rounds loses no such file to its lease, however long the whole takes.
- A source that answers with less than a piece may cross no multiple for several rounds, and the room then ends that file's lease after its idle time. The first round starts when the post's answer reaches the session. If that takes longer than the lease less one round, a first write can reach the room after its lease expires. The room then refuses it and the fill ends with the files incomplete. The settling step that follows can still pause like any request.
- If filling fails, the posted line stays and the receipt settles committed
  with its files marked incomplete and the cause: the room's own words for
  a write it refused, or that a round did not finish in time. A cause the Rooms catalog names keeps its code first.
- The worker keeps the whole fill through an interruption, including an
  append still waiting for acknowledgment.
- Sender leases hold the sources until settlement. Expiry and reads already
  in flight have their own lifetimes.

Direct delivery lends shared read access to the admitted sources, then sends
one direct post or refile. That access outlives the worker that created it,
and allows only the declared read methods and capability results. Delivery
copies no file bytes and reads no source itself.

History, archive and file readers keep their exact upstream targets and the
original session source, and every chunk and protected result rechecks both.
Choosing an archive needs `ReadArchive`, and files also need `ReadFile`.
Releasing a reader stops disclosure from a read already in flight. Forwarding
budgets for whole pages and blobs come from application limits and shared
sizing, with bounded temporary storage for results.

## Observation

Snapshots, watches and local observation pass the same source check. The
runtime builds one snapshot per tick and projects it for each checked source.
A registration keeps its exact receiver, authenticated cursor and the right
to cancel. Narrowing a policy or losing the source invalidates cached lines,
previews, roster and unread counts. Delivery queued after that loss reveals
only status. Cancelling one receiver cannot retire another.

## Evidence

The shared Zig delivery tests check exact arguments and replies, rollback of
a failed turn, Host retirement, forwarding, deferred refusal and
cancellation. The C and Rust continuation limits on count, bytes, target
references and reply capacity come from that same owner.

The [runtime executor scenarios](../../apps/rooms/rust/proofs/src/session_executor.rs)
run the same contracts on Linux and Chromium. They cover pause and revoke
during a wait, replacement before polling, wrong recovery grants, duplicate
resumes, lost replies, refused construction or refill, and replaying a cold
unresolved change without another upstream act. The SQLite and IndexedDB tests
reopen real storage and keep the foreign exporter. The production page tests
add saving results, shared-session recovery, files and management.
