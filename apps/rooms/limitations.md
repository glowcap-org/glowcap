---
type: static
description: The limits of the Rooms application itself, one short section each, and what to do inside them.
audience: human
sources:
  - resource: /apps/rooms/rust/application/src/
  - resource: /apps/rooms/rust/services/src/
---

# Rooms limitations

These are the limits of Rooms itself. The library's limits, including
transports and browser reachability, are in
[known limitations](../../docs/boundaries.md). [Operating Rooms](operating.md)
explains the server these limits belong to.

## Platforms

Rooms runs on Linux and macOS hosts and in Chromium-class browsers. One Rust
implementation runs every Rooms service and the browser application, and
TypeScript draws the page.

Windows and file locking on other filesystems are untested. Tor check
coverage is listed in [stability](../../docs/stability.md#checks-by-area).
No end-to-end Rooms throughput or latency result is published. The
[session cost report](../../bench/rooms/session-costs.md) records component
measurements.

[Install glowcap](host.md#install) says how the macOS packages are signed and
what to do when macOS refuses one.

## One host per deployment

Everything durable, kept messages included, lives in the directory and session
state volumes. Back each up as one unit while the stack is stopped. Rooms
cannot snapshot a running store, and one directory's rooms cannot be spread
across hosts.

## Unread messages

If a client stops reading, it can hold up to
<!-- value rust/application/src/room/inbox/queue.rs MAX_MESSAGES -->256<!-- /value --> unread messages, then gets an error and must subscribe again.
Cancelling, overflowing, replacing, or leaving releases the files attached to
its unread messages. The browser client keeps a read pending during ordinary
use.

## Sessions instead of accounts

No login or server account owns a shared session. Holding the session link,
which is a secret, is what lets you attach, and each part you delegate can be
revoked on its own.

## What a shared session keeps

Every view attached to a session shares its network identity and its state:
directories, archive choice, capabilities, peering, history, live files,
operator actions, listener and IRC administration, and visualizer
publication. Browser `File` handles and object URLs stay on the device that
made them. A browser tab keeps its session in IndexedDB, and a reload
restores the saved grants and links. A reference tied to a connection still
needs the peer that issued it to be reachable.

## Bridge passwords

A browser's local session forgets a bridge password on reload, and a session
adopted into a shared session arrives without it, so the member answers the
bridge once more. Secrets stay private and never enter ordinary
views or exports, as
[the managed sessions decision](../../docs/decisions/adr/ADR-0045-managed-rooms-sessions.md)
records, and [Operating Rooms](operating.md#the-session-service) says where
the password is stored.

## Attachments and shares

- A live attachment stays available only while its room or direct
  conversation, and its session, are open. A member archive the reader chose
  may keep the same message's bytes and serve them after a restart through its
  own scoped capability. The session stores neither copy, and it never records that an
  archive kept one.
- Room-link invitations are saved with the session. A browser session and a
  shared session both keep the link until the reader accepts or dismisses it.
- Received archive shares last only while the session runs. A live share ends
  with its session or after one read. A durable offer's link is served by this
  browser tab. The reminder on the conversation card is not saved, so a
  restart forgets the reminder and leaves the share in force.

## One-shot invitations

An invitation is a link that lets one person into a room, once. It does not
tell that person the room's entry link. A room holds
at most <!-- value rust/application/src/server/rooms.rs MAX_ROOM_INVITATIONS -->64<!-- /value --> live invitations, and an IRC bridge holds the same number.
An invitation ends when someone is admitted with it, when the member who made
it leaves, or when the room closes. A server restart does not keep
invitations. If the answer to a claim is lost, the same receipt can claim again
and still admits one person, and a different receipt is refused as already
claimed.

## Retries

The session keeps the operation ID and result of its last
<!-- value rust/application/src/content/session/custody.rs MAX_EFFECTS -->8<!-- /value --> finished changes, and a change that has not finished is never
dropped to make room. The browser never retries an uncertain send, edit,
withdrawal, operator change, listener change, or IRC change on its own. A
change replayed by hand after it has left those may happen twice.
Private-room and durable-authority changes keep a pending result and a
recovery key until they resolve.

## Delivery receipts

A room's senders share each reader's unread allowance
([Unread messages](#unread-messages)) and
<!-- value rust/application/src/room/inbox/queue.rs MAX_MESSAGE_BYTES bytes -->2 MiB<!-- /value --> across pending text and unread messages. Receipts keep order and
match each answer to its send, but a retry is still unsafe. An upload is
reused without a second read only when its source cannot change, it was
acknowledged, and the media cache took it. A streaming source or a full cache
means an ordinary read.
[ADR-0044](../../docs/decisions/adr/ADR-0044-member-owned-archives.md)
records the contract and its measured costs.

## Keeping a room

Joining with `open` or `enter`, or holding a room's entrance, gives no right to
keep the room. Creating a managed room returns a manager link you can pass on.
It controls the room's registered public name, its entry links, and its
moderators.

- The live room still disappears when empty. Its registration holds the name,
  and entering by that name brings the room back. An entry link grants no
  management.
- If every copy of the manager is lost, the directory operator has to recover
  one. Passing the manager on gives the other holder management too, and you
  keep yours.
- Revoking an entry link blocks later admission through every old copy, and
  members who already subscribed stay.
- An entry link lets its holder in to post. Moderating a room leaves a link
  told while it was open working, so revoke the link to close that way in.
- The current manager can unregister the room. That retires its public
  entrance and moves it to private access while its room link, moderator,
  manager, and existing memberships remain. Another room can then take the
  public name, so registering this room again may meet a name collision.

## Two tabs on one local session

Each tab writes the session to IndexedDB on its own. Import and clear tell
the other tabs, but edits made at the same time are not merged. When several
browsers or tabs must change the same session, attach them all to one
shared session.

## Links in a room subject

A member can set a room subject that holds an `ocapn://` link to an object, and
every reader sees the link. The browser and terminal clients offer it to copy
and do not redeem it or draw the object, so you take part through whatever
client that object comes with. The room passes the link on unchanged, so
whoever sets it decides what holding it allows.

## Directory listings

A watch starts from at most <!-- value rust/application/src/directory.rs MAX_ROWS -->256<!-- /value --> current room publications. Past that, the
client receives a truncation event and keeps receiving later changes. A list
returns up to <!-- value rust/application/src/directory.rs MAX_ROWS -->256<!-- /value --> rooms a page. A room that closes between pages does not
shift the rest, and a room open for the whole walk is listed exactly once. A
room that opens behind the cursor shows up on the next walk or in a watch.

## IRC

IRC is an application adapter. Rooms does not link IRC servers to each other,
CapTP does not run over IRC, and IRC carries neither edits nor file and room
offers.

- The bridge mirrors one channel into an ordinary Rooms directory and is
  read-only unless the operator chooses two-way mode with TLS and SASL
  credentials. Two-way posts use the bridge's registered nick and a visible
  `<nick>` prefix. IRC sends no acknowledgement for a channel message, so a
  TCP failure at the wrong moment may repeat or lose the last message, even
  though the queue survives a write failure the bridge sees.
- The IRC server maps only existing room names IRC can address. It fixes a
  nickname for the connection, because Rooms grants names per capability and
  cannot rename across several memberships at once. Rooms names outside IRC's
  alphabet get aliases that hold for the connection, and the server says so.
- Messages, subjects, and file links that do not fit IRC are reported
  instead of cut short or dropped. `LIST` leaves out, with a notice, foreign
  room publications that carry no member count and Rooms names IRC cannot
  address.
