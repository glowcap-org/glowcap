# Persistence as a capability

Status: historical — the plan is complete. Browser reconstruction, room
retention, the member archive, the archive peer, facets, handover, session
sharing, grants, and the combined archive view all shipped;
[ADR-0144](../decisions/adr/ADR-0144-combined-archive-views.md) owns the
coalescing rule this plan left open. The operational description lives in
[`apps/rooms/operating.md`](../../apps/rooms/operating.md#storage-and-room-history).

Rooms forgets by default, not unconditionally. An operator can retain the last
lines of listed public rooms in memory, state-directory files, or PostgreSQL;
private rooms never record. A browser keeps bounded room and direct-message
text plus attachment metadata and bytes in
IndexedDB when the reader leaves the visible history switch on. These are
local policies. The browser implements the archive object below and can project
it on a live session. A standalone peer hosts the same object behind a durable
sturdyref. Settings can select that whole-archive authority for
direct-message reads and writes. A conversation card can hand the other member
a live read-only facet or a durable archive-peer share, including a room or
standing account whose scope is independent of that DM. The server retention path does
not implement the archive object. The member archive retains attachment bytes;
room-owned server history still keeps only file captions.

The temptation is to start with storage: pick a database, write the lines
into it, read them back. That answers the wrong question first. What a member
can *fetch* is a product feature, and until Rooms is designed with those
features in it there is nothing to store honestly. So this page names the reads
first, then the shape that serves them.

## The reads

Four things a member should be able to come back to. They are separate
features, and a design that serves one does not automatically serve the next.

**Where I was.** The browser keeps one versioned state bundle with a session
checkpoint, view-local preferences, and an explicitly exportable capability
vault. It can reconstruct that bundle locally or attach to a durable session
capability so several views mutate one owner instead of reconstructing several
peers from the same file.

**What was said here.** A retained public room answers its bounded tail to a
current member. The member archive also records the room lines that reached
this browser as a separately attributed observed account.

**What was said between us.** A direct message is a session between two members
and the room server never carries a byte of it. Each browser now keeps its own
bounded text through the archive object or an explicitly selected peer. The
page can hand the other member a read-only facet for that direct conversation.

**What was attached.** An archived line retains each file's bounded name, media
type, size, image dimensions, and archive-minted content digest. The digest is
data; the scoped blob capability returned by the archive is the authority to
read its bytes.

## History belongs to whoever holds a reference to it

Everything a member is granted in Rooms today comes back as a reference. A room
reference is the authority to speak in that room. A line reference is the
authority to edit or withdraw that line, and it went to whoever posted it, so
neither verb asks who is calling. Possession already answered the question.

That is also what makes the authority passable. A member can hand a line's
reference on, and a room could keep a copy to give whoever it wants moderating,
without either side learning what a moderator is.

Shareable persistence is the same kind of thing. An **archive** is an object
that keeps what it is told and hands back what it kept, and holding a reference
to one is the whole of the authority to use it. Nothing about it is a property
of the room.

That has a consequence, because it is the point where
this design parts company with the obvious one. Two members standing in the
same room can hold different histories, and neither is wrong. A room does not
have a past; the people in it have pasts. Somebody who was never in the room
sees nothing, unless a member hands them a reference to their own record of it.

## One kind of archive, narrowed

The question of what to persist at — a directory, a room, a direct message —
does not need three answers. It needs one archive and the ability to hand out a
narrowed reference to it.

An archive reference is scoped, and a scoped reference can be narrowed but
never widened. A reference to my whole archive reaches everything it holds. Ask
it for the part covering one directory and it hands back a reference that
reaches that directory and nothing else, and asking that one for a single room
narrows it again. Reading and writing are also separate references, so I can
give somebody the ability to read this room's record without the ability to add
to it.

This is what makes the granularity question answer itself. My directory record,
my record of one room, and my record of one direct line are the same object seen
through three references, and each of them is a thing I can keep, drop, or hand
over on its own.

## Where an archive runs

The archive is an ordinary OCapN object, so where it runs is not an
architectural question. It is a question of whose reference you are holding.

**In the tab.** The browser keeps its own store and exposes it as an archive.
No network, works offline, and it ends with the browser profile. This is the
one that makes the reads above true for a single reader on a single device, and
it needs no server anywhere.

**A peer you run.** `zig build rooms-archive -- --state=<directory>` hosts the
native Rust archive at a durable sturdyref. It uses discovery-backed authenticated iroh by
default and can use cleartext TCP for local inspection. Ordinary OCapN code can dial and hand
on its reference. Settings selects this peer as the direct-message
recorder, so a second device holding the same whole-archive sturdyref can read
what it kept. A direct-conversation card narrows from that selected recorder
before sharing, so the recipient never receives the whole sturdyref.

**Offered by a directory.** A room server can host an archive and hand its
reference out, which is the shape people mean by a central database. It is not
a different design. It is one archive that happened to be handed to everybody,
and it stops being central the moment a member prefers their own.

So distributed, local, and central are three deployments of one interface, and
a member can hold several at once. That is the answer to "which one should
Rooms have": it should have the seam, and let the reference decide.

## Selecting a recorder

The archive-peer form accepts one whole-archive sturdyref and validates it before
changing where the member's room and direct-message history goes. Remembering that bearer in the
browser is a separate opt-in. A target change drains work already assigned to
the old recorder and does not copy its records into the new one.

A tab holding only a peer archive declines archive writes while the peer is
unreachable and tells the reader that the selected recorder is unavailable. It
never silently creates a second device-store history. Retry or an explicit
return to this browser chooses the next destination. This custody and offline
posture is recorded in
[ADR-0131](../decisions/adr/ADR-0131-browser-archive-peer-selection.md).

## A personal archive is fed by the member's tab

Every line a member sees arrives at their tab, because the tab renders it. So
the tab would feed a personal archive; the room need not participate in that
member-owned record. This is distinct from the shipped room-owned retention
policy, which the room itself serves to current members.

That is what makes this work for direct messages, which the room never sees,
and it means the first version needs no change to the room server. It also
fixes the meaning of what is stored: an archive holds a record of what one
member saw, not an authority on what happened. It cannot be consulted about who
is in a room or whether a line was withdrawn, because it was never the thing
that knew.

## What the contract keeps

Three kinds of record, matching the reads:

- **Workspace intent.** Which directories and rooms to reconstruct, plus the
  exact nickname requested on each directory. A live grant remains the
  directory's runtime fact rather than a claim made by the document.
- **Lines.** What was said, keyed by recorder source, conversation generation,
  and stable record identity, with the sender, time, and any edit or withdrawal
  that followed. A reconnect-local room line number is never the durable key.
- **Attachments.** Bounded metadata is part of the line record. Blob bytes stay
  behind the archive capability, under a separate aggregate byte ceiling, and
  are fetched lazily rather than riding history pages.

## Identity and attribution constraints

A directory nickname is an address within one live namespace, not a durable
person identity. The directory may grant it to somebody else after its holder
leaves. The shipped device-local DM history therefore presents recovered lines
as messages associated with that directory name and warns that its holder may
have changed. It is context, not identity evidence.

A shareable archive cannot make a stronger claim from the same input. Each
recorder must mint an opaque conversation generation and keep its own source
identity beside that generation. An authenticated durable peer identity may be
attached when the realized channel proved one, but it remains evidence rather
than the record's primary key. A fresh session key, an unauthenticated locator
claim, or a nickname must never merge two generations.

This also fixes how an archive read enters the interface. Recovered records
stand under their archive source and generation; they do not become an
unmarked continuation of the live conversation. Two archives can report the
same room or directory name without either report being silently treated as
the other.

## Sharing, and what it costs

Handing somebody an archive reference is handing them what it reaches, for as
long as they hold it. Ordinary OCapN attenuation applies: give a read-only
reference, give one narrowed to a single room, and pass it through a forwarder
if it has to be revocable later.

It is worth being blunt in the interface about what that means, the way the
operations capabilities already are about a swiss number sitting readably in a
browser profile. A read reference to a room's record is a reference to
everything that was said in front of the member who kept it.

## Open questions

These are the parts that remain open after the bounded `put`/`read` contract in
[ADR-0129](../decisions/adr/ADR-0129-member-owned-archive-capability.md).

**Merging — settled by [ADR-0144](../decisions/adr/ADR-0144-combined-archive-views.md).**
Two of my devices writing to one archive, or my archive plus one somebody gave
me, produce records about the same room from more than one source. The archive
keeps source and conversation generation in every key, and the combined view
coalesces by those keys without rewriting them: one coordinate shows one
record, lifecycle state outranks, and the current write target breaks the
remaining tie.

**Trust — settled by the same record.** A record somebody hands me is their
account of a room, and it stands under a divider naming its source and
keeper, never as live traffic. The reader chooses among accounts by reading
or discarding each offered share.

## Where to start

The order below builds the least first and keeps every step useful on its own.
The shipped retention paths prove the storage policies, not these capability
rungs.

1. **Shipped — name the capability reads in the interface.** A held archive
   reads standings and room or direct-message lines as one member recorded
   them, independently of the room's retention policy.
2. **Shipped — the archive interface, and the tab's own implementation.** One
   object answers bounded `put` and `read`, backed by the browser's existing
   IndexedDB database. Every record retains recorder source and conversation
   generation, and pre-contract rows remain device-local rather than receiving
   invented provenance.
3. **Shipped — the archive as a peer.** The same interface runs on a durable
   v1/Syrup Host. Its required state directory retains identity, authority, and
   a bounded synced revision log, while iroh gives the ordinary deployment an
   authenticated encrypted channel.
4. **Shipped — explicit recorder selection.** The archive-peer form validates a
   whole-archive sturdyref before an ordered swap. Remembering the bearer is
   opt-in, and an unavailable selection declines writes without device fallback.
5. **Shipped — direct-line attenuation and handover.** `narrow` intersects
   exact filters and cannot restore removed write authority. The conversation
   card hands the other member a read-only facet for that line; the receiver
   explicitly reads it once or gives it back, with bounded custody and separate
   attribution.
6. **Shipped — room and standing handover, durable offers, hash homes.** A
   room card names a member and hands a facet over a DM without stealing
   selection. Standing records are a kind of their own. Independently
   revocable durable offers are Host publications from the archive peer's
   share ledger; the tab recorder refuses that mint. A content digest is a
   seventh filter dimension that authorizes `blob(digest)` only inside the
   held facet.

The memory archive remains the focused contract implementation. The standalone
peer proves the same behavior across the live wire and a process restart. The
combined view of several archive accounts ships per
[ADR-0144](../decisions/adr/ADR-0144-combined-archive-views.md).
