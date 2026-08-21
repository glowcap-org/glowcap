# Persistence as a capability

Status: active plan. Nothing here has shipped. It argues a shape for Rooms and
names what would have to be decided to build it.

Rooms forgets. Restart the server and every room is empty; reload a tab and the
conversation on screen is gone. That is written down as a deliberate default in
[`apps/rooms/README.md`](../../apps/rooms/README.md) and in the header of
`apps/rooms/server/state.ts`, and for a chat application it is a strange one.

The temptation is to answer it with storage: pick a database, write the lines
into it, read them back. That answers the wrong question first. What a member
can *fetch* is a product feature, and until Rooms is designed with those
features in it there is nothing to store honestly. So this page names the reads
first, then the shape that serves them.

## The reads

Four things a member should be able to come back to. They are separate
features, and a design that serves one does not automatically serve the next.

**Where I was.** The directories I hold, the rooms I had joined on each, and
the name I was using there. Rooms already keeps a thin version of this: the
browser remembers `rooms.nick`, `rooms.room`, and `rooms.locator`, and the join
card answers from them. That is one device's worth, and it is not shareable.

**What was said here.** Arriving in a room I have been in before, I see the tail
of what I saw last time, above whatever has happened since.

**What was said between us.** A direct message is a session between two members
and the room server never carries a byte of it, so nothing but the two ends can
possibly keep it.

**What was attached.** A file somebody posted is a blob with its own size and
its own lifetime, and it is worth deciding separately from the lines.

## History belongs to whoever holds a reference to it

Everything a member is granted in Rooms today comes back as a reference. A room
reference is the authority to speak in that room. A line reference is the
authority to edit or withdraw that line, and it went to whoever posted it, so
neither verb asks who is calling. Possession already answered the question.

That is also what makes the authority passable. A member can hand a line's
reference on, and a room could keep a copy to give whoever it wants moderating,
without either side learning what a moderator is.

Persistence is the same kind of thing. An **archive** is an object that keeps
what it is told and hands back what it kept, and holding a reference to one is
the whole of the authority to use it. Nothing about it is a property of the
room.

That has a consequence worth stating plainly, because it is the point where
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

**A peer you run.** An archive with a locator, dialed like any other peer.
Because it is a peer, its reference can be handed to somebody else, which is
how a second device of mine gets my history and how a friend gets a copy of a
room they missed. Nothing about this peer is special to Rooms: it hosts one
object and answers two verbs.

**Offered by a directory.** A room server can host an archive and hand its
reference out, which is the shape people mean by a central database. It is not
a different design. It is one archive that happened to be handed to everybody,
and it stops being central the moment a member prefers their own.

So distributed, local, and central are three deployments of one interface, and
a member can hold several at once. That is the answer to "which one should
Rooms have": it should have the seam, and let the reference decide.

## The member's tab is the writer

Every line a member sees arrives at their tab, because the tab renders it. So
the tab is what feeds the archive, and the room is not involved at all.

That is what makes this work for direct messages, which the room never sees,
and it means the first version needs no change to the room server. It also
fixes the meaning of what is stored: an archive holds a record of what one
member saw, not an authority on what happened. It cannot be consulted about who
is in a room or whether a line was withdrawn, because it was never the thing
that knew.

## What would be kept

Three kinds of record, matching the reads:

- **Standing.** Which directories, which rooms on each, and the name held there.
  Small, changes rarely, and it is the one that makes a reload feel like coming
  back rather than starting.
- **Lines.** What was said, keyed by the conversation and the room's own line
  number, with the sender, the time, and any edit or withdrawal that followed.
- **Attachments.** The blobs, which are large enough to deserve their own
  policy. An archive could keep only the fact that a file was posted and let the
  bytes go, and that may be the right default.

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

These are the parts that are not decided, and each of them can change the shape
above.

**Merging.** Two of my devices writing to one archive, or my archive plus one
somebody gave me, produce records about the same room from more than one
source. Room lines carry the room's own number, so those merge cleanly. Direct
messages have no server to number them, so they need a key of their own, and
the honest candidate is the sender's identity plus their own count.

**Eviction.** An archive is bounded like everything else in this application.
Rooms already trims its scrollback at `MAX_SCROLLBACK` and hands what falls off
to a release seam. An archive needs the same discipline and a stated answer for
what happens when it is full.

**Offline writes.** A tab holding only a peer archive cannot write while the
peer is unreachable. Either it queues, which is a second store, or it declines,
which the reader has to be told about.

**Blobs.** Whether an archive keeps file bytes at all, and if so whether it
serves them back as the same kind of attachment reference the room hands out.

**Trust.** A record somebody hands me is their account of a room, not the
room's. The interface should not let a shared archive's lines look
indistinguishable from lines this tab watched arrive.

## Where to start

The order below builds the least first and keeps every step useful on its own.

1. **Name the reads in the interface.** Decide what a returning member sees,
   with no persistence behind it. This is the product work, and everything
   after it is implementation.
2. **The archive interface, and the tab's own implementation.** One object, two
   verbs, backed by the browser's own store. This makes the reads real for one
   reader on one device and proves the seam without a network.
3. **The archive as a peer.** The same interface over CapTP, which is what
   makes it shareable and what makes a second device possible.
4. **Attenuation and handover.** Narrowed and read-only references, and the
   interface for giving one away.

A test archive that keeps its records in memory would serve steps two through
four, the way the in-process transport already serves the transport tests.
