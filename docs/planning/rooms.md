# Rooms recursive resources

Status: active plan. Work on the remaining steps waits for maintainer review.
Delete it, with the [design contract](rooms-design.md), when the last step
lands and the [roadmap row](../roadmap.md#durable-applications) closes.

## What this is for

Rooms today is a directory of flat rooms. A room link is broad, reusable
authority. An invitation admits a fixed observer or participant. The member
session has its own grant ledger, and archive shares have another. Nothing
can be narrowed after it is given, and a limited recipient reconnects through
a link wider than what they were offered.

This plan makes every Rooms resource (a session, directory, room,
conversation, message, file, or archive) shareable in two ways. You can pass
the exact thing you hold, so the recipient uses your access with you. Or you
can create managed access: a narrower copy with its own scope that you can
edit, pause, and revoke, and that reconnects as itself. The design calls that
copy a facet, and the most it can ever be widened to is its ceiling. An
invitation becomes an offer, a thing you hand out that admits someone under
stated terms, kept apart from the access they hold once admitted.

On top of that the plan adds rooms inside rooms, conversations with replies
and branches, moving content between places without changing its audience by
accident, and one access editor that works the same on every kind of
resource.

The result is a chat application where showing someone one message never
shows them its room, where closing an invitation and revoking a member are
different acts, and where no ID, nickname, or failed check can select a
stronger path than the one you hold.

## Where things stand

- **Done.** Loam is the storage and access foundation Rooms runs on, and its
  managed access module ships with everything this plan needs: grants,
  scopes, ceilings, controls, receipts, and durable publication. The member
  session, which is the workspace one person keeps across their rooms, is
  already built on it. The [session guide](../rooms/session.md), the
  [effect contract](../rooms/session-effects.md), and the
  [page contract](../../apps/rooms/web/ui/README.md) describe it. Permission
  groups and presets exist for the session kind only.
- **Not built.** Room-owned grants and offers, the permission catalog for
  every kind, the content model (collections, conversations, messages,
  placements), reorganization, split directory access, the editor over every
  kind, and the proofs. The [design contract](rooms-design.md) says what each
  of these is.
- **Still running.** The mechanisms this plan replaces are live and tested:
  private room recovery keys, role generations, live invitations, nickname
  vouchers, the archive share ledger, and the session's own grant policy.
  Each is deleted in the step that replaces it. The list is under [where the
  code is](#where-the-code-is).
- **Not needed from Loam.** Loam commits several managed changes to one
  owner in one transaction, and every record this plan writes lives under one
  owner. Admission commits a grant, an endpoint, a publication, and a receipt
  for one room, and a move, split, or merge stays inside one owner. Content
  changes that span owners and a general operation journal are not
  implemented, and nothing here needs them. Placing an entry in another
  owner's room is two acknowledged acts, as the design contract says. Search,
  unread counts, and notifications read each owner's own change history.

## The decision

[ADR-0183](../decisions/adr/ADR-0183-rooms-scoped-sharing-and-recovery.md)
settles the shape. You share the exact reference you hold, or you issue a
facet that depends on your grant, carries a ceiling, and names its scope.
Offers are separate from the access they admit. One Loam transaction commits
content, grants, and recovery together, and authority commits before it is
exposed. The
[design contract](rooms-design.md) carries that decision down to the
objects, keys, methods, records, and budgets each step builds.

Two smaller calls are made here so the steps can start.

Public-room scrollback lives in a retention store of JSONL files under the
directory's state directory, and
[ADR-0216](../decisions/adr/ADR-0216-rooms-retention-lives-in-files-until-content-records-take-it-over.md)
decides that the content records this plan adds take it over. Once the
content seam lands, every room's lines are content records under the room's
owner, so the file store would be a copy with its own eviction policy. The
kept-lines limits become the public room's content quota and the file store
is deleted with the consumers in the consumer sweep. Everything durable in
Rooms then lives under its two state directories, and the stopped-volume,
one-host backup posture ADR-0216 records holds for both.

The capacity numbers in
[storage and budgets](rooms-design.md#storage-and-budgets) are proposed, not
measured. The room-grants seam registers them as refusals as written, and
the cost evidence in the proofs sweep moves them. A limit is a refusal
boundary with no migration cost, so measuring first would delay the seam for
numbers the proofs replace anyway.

## Steps

The steps alternate between two kinds. A **seam** opens a mechanism nobody
has built yet and needs a planner who reads the design first. It lands in a
few commits, and its test is the exit named below. A **sweep** applies a rule
the seam settled to a counted list of places, one commit per row, and a
cheaper executor can run it once the seam has landed and named the files it
touches. A step that replaces an old mechanism
deletes the old code, its fixtures, and its generated grammar in the same
commit, and updates the generated mirrors, the clients, the protocol docs,
the shipped inventory, and the known limitations with it.

1. **One policy catalog** (seam). Move the permission groups and presets out
   of the session kind into a Rooms-wide catalog over the permission keys.
   Make the terms generic over a kind marker that carries the kind's name and
   its supported keys, and filter groups and presets per kind as the
   [kind rule](rooms-design.md#operation-authority) says. Test: the browser
   metadata generator and the declaration proofs iterate the kinds, and the
   session's groups come out unchanged.
2. **Declare the kinds** (sweep). One module per row of "Keys by resource
   kind" in [operation authority](rooms-design.md#operation-authority), and
   one catalog row per preset in the
   [editor table](rooms-design.md#access-editor), each with a label and a
   one-sentence description in the voice of the session presets. Test: the
   regenerated metadata mirror and the Rust policy tests.
3. **Room-owned grants on Loam** (seam). A room issues and stores its own
   grants: offers, the receipts that admit someone, memberships that
   outlive a connection, facets that depend on a member's grant, and the
   line between a manager and a moderator. Reconnecting restores the exact
   grant, never a room link. The records are under
   [storage and budgets](rooms-design.md#storage-and-budgets) and the
   methods under [operation authority](rooms-design.md#operation-authority).
   Test: a helper admitted once can speak without inviting, loses file and
   topic powers on references they already hold, pauses, resumes, and
   reconnects under the same grant, and a retried receipt returns the same
   admission.
4. **Replace the methods** (sweep). One commit per row of "Methods to
   replace" in [operation authority](rooms-design.md#operation-authority):
   route callers to the new method and delete the old one with its generator
   grammar, clients, and fixtures. Test: the generated-protocol check, the
   server tests, the peer tests, and the terminal client tests.
5. **Content on managed containment** (seam). Conversations, messages, and
   the places a message can be shown become records that hang off the
   managed resource tree, so a message has one home and every other
   appearance is a placement that holds a capability to it. A branch
   remembers where it came from. Rename, move, split, merge, and archive
   run as one transaction that previews who gains or loses sight of the
   content, as the [content model](rooms-design.md#content-model) says.
   Test: a shared
   message survives restoration without exposing its siblings, a branch
   revocation survives restart, and a reparent that would widen an audience
   refuses without the audience-change control.
6. **Replace the consumers** (sweep). One commit per row of the table under
   [where the code is](#where-the-code-is), deleting the replaced owner in
   the same commit. Test: the tests that covered the old owner now cover the
   new one, and no code path recovers authority by name or ID.
7. **The editor over every kind** (seam). Room access inventory, item
   sharing, member-to-grant inspection, the invitation choice and acceptance
   page, and desktop client support, on the kind-generic permission fields
   described under [access editor](rooms-design.md#access-editor). Test: the
   page proofs cover preset replacement, Custom mode, a stale revision, a
   self-revocation, keyboard focus, and a narrow layout.
8. **Walkthroughs and cost evidence as proofs** (sweep). One commit per
   [walkthrough](rooms-design.md#walkthroughs) row and per path of the
   [cost evidence](rooms-design.md#storage-and-budgets) table, each proved
   through the shipped clients and server rather than a test harness, with
   the numbers recorded next to the code, and read by a second reviewer who
   did not write it before it counts as evidence.
9. **Directory access** (seam). Split the directory's public offer from its
   use and management facets, cover every directory verb and registration or
   signaling path, ship the directory editor and bootstrap configuration with
   clients and operating docs, and remove the unrestricted bootstrap. Test:
   creator access revokes while browsing continues under another grant,
   created rooms stay owned, and a room or direct conversation on the same
   transport continues through directory grant retirement.
10. **Conversation workflows and outside-peer evidence** (seam). A
    conversation view a person can use: scoped history, unread counts,
    search, notifications, and rename, split, merge, and move with the
    audience preview from the content seam. Then everything runs together: peered
    rooms, local and durable sessions, several views of one session, every
    shipped client, and both IRC edges. Test: a sharing scenario that
    visibly issues, narrows, passes, and revokes authority through the
    shipped clients, and a Goblins peer that observes both permitted and
    refused behavior.
11. **Audit and retire.** Check the composed product for overlooked recovery
    paths, duplicated policy, and stale assumptions. Reconcile the shipped
    inventory, the known limitations, the protocol pages, the operating
    guide, and the ADR links. Delete this plan and the design contract.
    Test: every row under [what done looks like](#what-done-looks-like) has
    recorded evidence or was removed from scope in the open.

### What done looks like

The last step is done when every row below has recorded evidence on the
implementation commit, or is removed from scope in the open. Each row is an
acceptance test for the whole, not for one step.

| Scenario | Evidence required |
| --- | --- |
| Allowed and denied operations | Every operation succeeds with its authority and is refused without it, through desktop and browser clients. |
| No public bypass | Refetching bootstrap, old entrances, or alternate verbs cannot recover withheld powers. Intentionally public access remains. |
| Exact scope | Foreign IDs, old generations, sibling grants, reused names, stale dialogs, and forged view records confer nothing. |
| Delegation | Copies share revocation. Children attenuate. A parent's restriction constrains its children, and its expansion cannot exceed a child's ceiling. Independent grants survive. |
| Offer admission | Concurrent claims, repeated receipts, cancelled waits, crashes, and lost replies produce exactly the recorded admission. One-visit and rejoin differ as advertised. |
| Live changes | Held topic, file, upload, line, history, naming, and watch references obey current rights. Promoted holders acquire new facets. |
| Change observation | Committed edits emit scoped events over CapTP. Failed edits emit none. Reconnect and overflow resynchronize. Missed events never preserve permission. |
| Pending effects | Revocation during storage, handoff, upload, introduction, signaling, or watch delivery prevents a later effect or disclosure. |
| Isolation | Revoking one grant does not close transport or retire unrelated memberships. |
| Persistence | Revoked branches stay dead. Edits preserve links. Uncertain writes fail closed. Receipts recover. Corrupt stores do not remint. |
| Resource pressure | Every limit refuses safely. Churn cannot bypass aggregates. Message admission stays within measured cost. |
| Editor | Preset replacement, Custom mode, lifecycle independence, stable issued policy. Scoped inventory, stale revisions, self-revocation, keyboard, narrow layouts. |
| Content | First use, message identity, branch, private branch, shared reply, reorganization, cross-owner placement, deep link, aggregates, continuity. |
| External consumers | Goblins and the shipped language and IRC clients observe both permitted and refused behavior on baseline CapTP. |

## Parallel work

The steps before the proofs sweep split into three lanes along the seams. Each
seam names the exact files its sweep touches before the sweep starts.

| Lane | Steps | Owns | Starts |
| --- | --- | --- | --- |
| 1. Policy and editor | 1, 2, then 7 | The policy catalog and kind modules in the Rust application crate, the browser metadata generator, the access editor in the web UI | Now. The editor also waits for room-owned grants. |
| 2. Room grants | 3, 4, then 9 | Room grant records and methods, the protocol generator, the directory | Now |
| 3. Content | 5, 6 | The history store, content records and placements, and the consumers under [where the code is](#where-the-code-is) | Now |

- The proofs sweep starts when lanes 1 to 3 are done. Conversation
  workflows and the audit follow in one lane, since they exercise everything
  together.
- Shared files: lane 2 alone edits the protocol generator. Every lane
  regenerates the protocol and metadata mirrors after a sync. Each lane
  edits only its own rows in the shipped inventory and the known
  limitations.
- Lanes 2 and 3 both add Loam records under the Rooms runtime. The
  room-grants seam and the content seam agree on separate files before
  either sweep begins.
- Validate every new check against an injected defect, including a stale
  cached right and a bootstrap bypass.

## Questions for you

- None open.

## Where the code is

- Permission groups and presets today: `content/session.rs` in
  `apps/rooms/rust/application/`, with `KIND` and `SUPPORTED` as the pattern
  each kind module copies. `apps/rooms/test/commands_test.ts` reads the
  session group keys by name.
- Protocol grammar: `tools/gen/rooms_protocol.zig`,
  `apps/rooms/lib/protocol_operator.ts`, `apps/rooms/lib/protocol_handover.ts`.
- Shared Loam record schemas: `src/loam/access/records/`.
- Web UI and page proofs: `apps/rooms/web/ui/`.
- Checks: `zig build rooms-rust-test`, `rooms-rust-browser-test`,
  `rooms-server-test`, `rooms-peers-test`, `rooms-terminal-client-test`,
  `gen-rooms-protocol-check`, `rooms-browser-metadata-check`,
  `rooms-web-proofs`, `goblins-rooms`, `goblins-rooms-irc`. A seam ends with
  `zig build check`, `runtime-check`, and `check-external`.
- Decisions: ADR-0183, ADR-0182 (saved references), ADR-0142 (nickname
  vouchers), ADR-0208 and ADR-0216 (retention store).

Consumers the consumer sweep replaces, under `apps/rooms/rust/`. Recovery
requires held source or result authority. An ID, nickname, or failed check
cannot select a stronger method.

| Current owner | Replacement |
| --- | --- |
| Private room recovery keys in `application/src/directory/creation.rs`, `application/src/session/checkpoint/commands/results.rs`, `services/src/server/rooms.rs`, `services/src/server/authority/queue/` | Bounded creation receipts with exact ownership results. Delete recovery-by-name and broad link minting. |
| Role generations in `services/src/server/authority.rs`, `services/src/server/document.rs`, `application/src/server/document.rs` | Shared endpoints and controls. Remove publication reconstruction and duplicate revocation ledgers. |
| Live invitation in `application/src/server/invitation.rs`, `services/src/server/invitations.rs`, `glowcap/src/client/invitation.rs` | Four-mode offers and atomic claims. Delete fixed observer or participant and connection-only admission state. |
| Rejoin in `runtime/src/session/managed/results/invitation.rs`, `application/src/session/checkpoint/` | Retain the exact accepted endpoint. No implicit room-link mint. |
| Nickname voucher in `services/src/server/registration.rs`, `application/src/server/directory/registry.rs`, `glowcap/src/client/directory/registration/` | Keep one-use continuity and authenticated comparison (ADR-0142). Add grant and generation checks. Never persist a voucher in a checkpoint. |
| Archive shares in `application/src/archive/shares/`, `runtime/src/archive/publications.rs`, `apps/rooms/lib/archive/durable_protocol.ts` | Managed exact-scope publications. Archive records stay content. |
| Operator state in `services/src/server/capabilities.rs`, `services/src/server/operations/` | Keep the separate operator front. Mediate attachment access with UseOperations. Never expose on a public root. |
| File-backed scrollback in `application/src/server/history.rs`, `services/src/server/history.rs`, `services/src/server/history/file.rs`, the `--history` option in `services/src/server/config.rs`, and the history text in `apps/rooms/operating.md` and `apps/rooms/shipped.md` | Content records under the room's owner, with the kept-lines limits as the room's content quota. Delete the index, the file backend, and the option. |
