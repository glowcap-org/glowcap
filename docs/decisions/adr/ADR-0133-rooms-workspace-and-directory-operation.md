---
id: ADR-0133
status: accepted
date: 2026-08-25
tags: [rooms, browser, persistence, capabilities, operations]
decision: "The browser persists one bounded, versioned workspace document containing reconstructible user choices and projects it into fresh runtime sessions after reload. The Rooms operator capability separately inventories and acts on durable room links, nickname registrations, live sessions, room owners, trouble, and room moderator capabilities through stable targets."
supersedes: []
superseded_by: []
amends: [ADR-0127, ADR-0129, ADR-0131]
amended_by: [ADR-0134, ADR-0135]
---

# ADR-0133 Rooms workspace and directory operation

## Context

The browser previously remembered one recent room, locator, and nickname. Its same-tab reconnect path could re-enter
every room still present in memory, but a page reload started with no directories, conversations, selection, or drafts.
The member archive recorded direct messages even though its record vocabulary also supported room lines.

The Rooms operator capability had a second mismatch. Its name described application-wide authority while its contract
and browser pane managed only room moderator capabilities. Diagnostics could show room links, registrations, and
members, but those display rows were not safe mutation targets.

## Decision

The browser owns one versioned Rooms state bundle in local storage. Its independently versioned session section keeps
directory routes, names, rooms, direct conversations, drafts, selection, standings, and the capability vault. Its view
section keeps theme, notification, rail, roster, and panel preferences. The writer and parser share document and
category limits, so the app never writes a bundle its own parser would reject.

The document contains no live session, reference, room wrapper, promise, timer, file handle, object URL, roster, or
transfer state. It also contains no directory conversation: that view is this tab's, recreated when the address names
it, and it is a command surface for that directory rather than a chat. Boot validates and projects the document into
placeholder store rows before dialing. The network layer
then opens each directory, re-enters public rooms by name or publication, redeems private rooms through their retained
links, and acquires fresh direct routes when a conversation is used. A handed room with no durable link remains visible
as unrecoverable instead of being silently discarded.

The page directory is restored first while the browser still holds it. Giving it back records that directory's identity,
so a reload does not recreate it and moving a workspace bundle to another page does not suppress that page's directory.
The remaining directory order stays as the reader left it. A root-page open restores the saved active conversation. An
explicit room, direct-message, join, directory, or operations address reserves selection for that route, so reconnecting
rooms cannot replace it before the route acts. A reader's later room choice still takes the screen immediately.

The member archive records room and direct lines through the same ordered, bounded writer. Recovered room records are
the member's observed account. A room's retained history remains the room's own account. Both accounts stay separately
attributed because the current room protocol supplies no durable line identity that could merge them safely.

Archive selection and retention apply to that whole message account. The device target and a selected archive peer both
read and write room and direct lines. Turning retention off erases the device archive as one account; it only stops new
writes to a peer because the peer contract has no erase verb. This widens ADR-0131's original direct-message-only
browser selection.

The Rooms operator returns bounded, revisioned inventories for room links, nickname registrations, active sessions,
local and private room generations, pending and committed peering publications, IRC bridges, trouble, and room moderator
capabilities. Its initial response takes one synchronous revision across every category; later pages carry the revision
and an exact continuation cursor. Registrations and sessions carry server-minted session IDs, and room owners carry
generation IDs, so an action cannot hit a replacement that happens to reuse a display name. Disconnecting a session
retires its connection-scoped references through the existing session lifecycle. An operator watch becomes active only
after its first revision callback is delivered. Later callback refusal drops that watcher, so a dead observer cannot
occupy the bounded watcher table while appearing reactive.

Removing a durable room link persists a tombstone before removing the Host publication. Every linked-room behavior
checks the durable active state on each call, so removal stops already-enlivened references as well as later
redemptions. The tombstone records the retired generation. A later request for the same room advances that generation
and derives an unrelated room sturdyref, so the old capability remains dead while the room can be shared again. A
moderator sturdyref includes the room-link generation in its derivation, so reissuing the room cannot revive an old
moderator capability either. Room-owner removal delegates to the application owner that can complete the cleanup: local
membership custody, peering, or the IRC gateway. Trouble clearing acknowledges the bounded process journal. Scoped reset
operations cover links, registrations, sessions, rooms, and volatile runtime state. Factory reset rotates room authority
and clears its active and revoked publication registries before retiring runtime state; neither form erases message
history or server identity. Reset acknowledges existing trouble before retiring owners, so a failure caused by the reset
remains in the journal.

## Consequences

The workspace document can later move behind a user-held storage capability without changing what it means. Cross-device
synchronization and multi-tab conflict resolution remain separate because this decision establishes one document and one
browser writer, not a merge protocol.

Attachments in drafts are not reconstructed. The text remains addressed to its conversation, while live `File` handles
leave with the page that held them.

Arbitrary CapTP references are not globally enumerable or individually revocable. The operator page controls durable
publications registered for revocation and retires all session-scoped occurrences by disconnecting their owning session.
It separately inventories application-owned occurrences such as memberships, recent line authority, pending uploads,
registrations, signaling exchanges, and peering reservations. Releasing one updates that aggregate but cannot revoke a
copy already held by another peer. This inventory is rebuilt for each page or release; stable weak IDs never turn its
presentation rows into a second strong owner.

## Evidence

`apps/rooms/test/workspace_state_test.ts` checks the document's bounded schema, stable conversation IDs, and refusal of
partial authority and writer/parser round trips. The store and archive tests cover shared history recording and bounded
logs. The Rooms operator and room-link suites exercise the revisioned paging contract, exact room-owner cleanup, durable
link and moderator revocation, Host unpublication, restart behavior, current-reference release, watcher admission, and
factory reset.
