---
type: static
description: How Rooms managed commands keep source admission, held targets, and recoverable outcomes across external effects.
sources:
  - resource: /apps/rooms/rust/application/src/content/session/
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

Recovery needs the caller's own pending-change or result authority plus
`ResolvePending`. An operation ID cannot select another grant's receipt.
Concurrent resumes share one sender. A changed request is refused, and
replay pressure cannot evict an unresolved receipt. A missing receipt
confirms the change never happened, and does not permit preparing or
resending it.

## Cancellation, source loss and shutdown

Cancelling a caller's wait releases only its observer. Committed work keeps
its targets and runs to settlement. Pausing or revoking the source stops any
further sending and protected disclosure, while the completed result stays
available to settle internally.

The executor tells a failure before the target admitted the change
(`unsent`) from a failure after it (`unknown`). The application receipt
decides whether the change took effect durably. If memory for the result is
refused temporarily, the completed reply is kept for a retry without sending the
change again. A reply too large, or with the wrong identity, settles as
unknown instead of retrying forever.

Shutdown drains workers before releasing their buffers. A failed close keeps
everything, including the original serving tasks, for another attempt. The
Host stays alive while settlement still needs it, and durable receipts stay
until they are explicitly retired.

## Atomic acquisition

Saving a whole workspace keeps the source, imported capabilities, expected
revision and the complete candidate across cancellation and retry. It needs
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
back no earlier authority. Adopting a created room appends it through the <!-- status-allow: runtime state or operation ordering -->
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

- Staging is confirmed before the post or refile. The post is acknowledged
  before the file is filled, in bounded pieces.
- If filling fails, the posted line stays, marked as having an incomplete
  file.
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
