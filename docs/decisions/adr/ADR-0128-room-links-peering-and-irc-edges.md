---
id: ADR-0128
status: accepted
date: 2026-08-25
tags: [rooms, capabilities, sturdyrefs, handoff, locators, irc]
decision: "A room is the addressable unit of Rooms: every room can be named by one sturdyref that redeems into the room capability, a tab holds sessions on several directories that each own their nicknames and direct lines, directories peer by handing rooms through the ordinary three-party handoff, and IRC enters only as two application adapters at the edge, never as a netlayer or a server link."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0139]
---

# ADR-0128 Room links, directory peering, and the IRC edges

[ADR-0139](ADR-0139-rooms-entrances-memberships-and-registration.md) refines
the room-capability language in this record. A room link redeems into a
reusable entrance capability. A successful `subscribe` creates a membership
and reconstitutes the live room when none exists. The link itself retains
neither a live room nor a membership.

## Context

Rooms locators began at the server level: every client dialed one directory and
asked it for rooms by name, so a room was reachable only through its hosting
server and a browser tab could hold exactly one directory. Making the room the
addressable thing decides three surfaces at once: how a room is named to a peer
with no prior relationship, what a tab that holds several directories owns per
directory, and how a directory lists rooms hosted elsewhere. An IRC channel on
a public network, and an IRC client that wants a native room, sit at the two
edges of the same design, and where they attach decides whether IRC leaks into
addressing or authority.

The decision rests on two architecture-rule principles, that session state owns
authority and that names carry their namespace ("Names carry three things" in
the [architecture rule](../../../.agents/rules/architecture.md)), and on the
route-bundle contract of [ADR-0125](ADR-0125-identity-route-multihome.md). The
[objects on the wire](../../../apps/rooms/developing.md#the-objects) and
[`apps/rooms/irc/README.md`](../../../apps/rooms/irc/README.md) describe the
shipped shape.

## Decision

Four rules decide every choice below.

1. **A transport is anything CapTP comes out the other end of.** The far side
   of an IRC bridge is an IRC network, where there is no session and no
   capability, so the bridge is an application object above the public binding
   surface, never a netlayer.
2. **Names carry their network.** A bridged room is `libera/#ocapn`, never a
   bare `#ocapn`. The same channel name on two networks is two rooms, and two
   directories may both have an `alice` who are two people.
3. **One authority per room, chosen at creation.** A native room's roster is
   the Rooms server's truth. A bridged room is a view of its channel, and the
   channel is the truth it mirrors. A room is never half of each.
4. **The gateway is invisible in the address.** A bridged room's locator is
   indistinguishable from any other room's. IRC appearing in a locator scheme
   or segment would mean the bridge had leaked into addressing.

**Room links.** A room's shareable name is one OCapN sturdyref that redeems
directly into the room capability with no name-passing step. The hosting Host
authors the complete link from the durable room publication and the location it
advertises on the asking session. A client never joins a swiss number to a route
it happens to have. The server keeps a small, bounded durable record of the
rooms it has been asked to link and derives each swiss number from its own
retained key, so a link survives a restart without storing bearer strings and a
room nobody linked has no durable name. A link promises that the hosting peer
will enliven the room, not that the room is lively: redeeming a link whose far
side is gone returns a room that reports its far side broken, so a dead channel
is told apart from a dead bridge. The readable name is the human layer and the
link is the real one, the split Rooms makes between nicknames and capabilities.

The browser creates the link from the room's Capabilities tab and states its
bearer, forwarding, durability, moderation, and history boundaries beside the
control. A listed room re-enters by name after reconnect. A private room with a
retained link re-enters through that sturdyref, while a one-session handoff with
no link is reported as lost instead of being mistaken for durable authority.

**Several directories in one tab.** A tab holds as many rooms as it likes, each
delivering into its own conversation, and the session is keyed per directory
rather than held as one page-wide singleton. The tab owns only what the tab
mints (transfer progress, unconfirmed sends). Everything else belongs to one
directory: its locator, rooms, registered nickname, deferred inbox offers,
signaling, blob capabilities, and direct lines. A direct line belongs to the
directory that introduced it because its counterparty is a nickname, and a
nickname is that directory's to grant and reclaim. Ending a session there ends
its own lines and no others. Room conversations and the live-room list are keyed
by directory in the same change, because a name alone collides the moment two
servers both call a room `general`. A directory is a property of a row, not a
box that owns rows: the rail names a row's directory only when there is more
than one to tell apart, filters never group or reorder, and a directory is left
explicitly, behind a confirmation naming the rooms, lines, and nickname that go,
and never implicitly at zero rooms.

**Directory peering.** A directory that lists rooms hosted elsewhere holds
references to them and hands one to a member through the same three-party
handoff the direct-message path ships: the directory introduces, the member
redeems, the member connects to the hosting server directly, and the introducing
directory carries no traffic afterward. A peered room reference names the
hosting peer plus its routes (ADR-0125), and the directory lowers what it hands
out to the recipient's session: a glowcap peer that negotiated identity routes
receives the `id` form, a Goblins member receives one `1.0`/Syrup-compatible
locator, and a room with no such route is refused as unreachable rather than
leaking private vocabulary. There is no server-to-server protocol, replication,
or shared authority, so netsplit semantics do not exist. A foreign listing
belongs to the publisher's destination Session. Its exact lease can revoke it.
Disconnect retires every listing that Session still owns. Giving up the lease
without revoking gives up only that exact control and leaves discovery in place
until disconnect. Either retirement leaves room references already handed to
members live.

**The IRC edges.** The bridge is a Rooms server whose published rooms mirror IRC
channels. Its operator-held gateway creates a network connection capability.
That capability creates channel bridge leases, so joining and parting a channel
cannot accidentally create or close another network identity. The network
capability remains valid with no channels and no socket. Its first channel
enacts one shared feed connection, and its last channel's departure retires that
transport without retiring the network authority. A recreated channel is a new
publication generation. Saved conversations move to it only after the directory
reports that the prior generation is gone and the same source name has a current
replacement. Each Rooms member likewise has one IRC identity connection per
network, with channel memberships beneath it. Inbound, the feed projects one
Rooms member per IRC nick under an `irc/` prefix and drops the claim when the
nick parts. Outbound, it posts under its own registered, SASL-authenticated nick
with a visible `<nick>` prefix, throttled below the network's flood limit.
Everything it injects is visibly bridge-backed, nothing from IRC is presented as
verified, and a direct message to an IRC nick terminates at the bridge because
there is no capability on the far side. The front is one more listener speaking
the IRC client protocol, translating each verb onto the directory and room
capabilities every front uses: a refused join becomes a numeric, and a DM rides
the real introduction path. The two edges share one IRC vocabulary module so the
mapping has one authority, and they never talk to each other.

## Scope (what this does not decide)

- Per-user IRC citizenship on a public network remains subject to that
  network's connection, account, and flood policies. Rooms does not imply the
  network permits it.
- The IRC front accepts no IRC capabilities and projects no steward or operator
  authority. If modes are ever added they act through a room capability the
  front holds, never a separate privilege system.
- The builtin gateway proves a connection-provider, channel, and room-publication
  seam. A transferable contract for external bouncers or other edge providers
  does not exist. The directory must not grow IRC policy when one is
  introduced.
- Whether the rail's filter outlives a reload waits on wherever a reader's
  other view state is kept, so one answer covers all of it.
- The remaining IRC representation limits are recorded in
  [`docs/boundaries.md`](../../boundaries.md).

## Alternatives Considered

- **Server-to-server IRC linking**: rejected because linking as a peer server
  imports IRC's federation model, where every linked server is trusted by the
  whole network and can forge anyone, the authority model this project exists
  to not have.
- **A `relay-irc` netlayer carrying CapTP over IRC as ciphertext**: satisfies
  the participants-only contract in principle and fails on capacity.
  512-byte lines, text-safe encoding, and flood limits near one line per
  second cap the channel at a few hundred bytes per second, and exceeding
  the limit disconnects rather than queues. Room links make IRC reachable as
  cargo behind a locatable bridge instead.
- **Storing each room's swissnum**: rejected because deriving it from the
  server's retained key gives the same durability with no secret table.
- **Grouping the rail by directory**: rejected, because a grouping is a view
  that belongs to the reader.
- **Leaving a directory implicitly at zero rooms**: rejected because it gives
  up a nickname the reader never offered, frees it for the next claimant, and
  drops that directory's direct lines, none of which rejoining recovers.

## Consequences

`apps/rooms/lib/locator.ts` owns the TypeScript consumer's locator parsing and
dialing. The Rust server policy under `apps/rooms/rust/application/src/server/`
owns the bounded durable room-link record, swiss derivation, and complete
sturdyref construction. The web state keys every table by directory.
`apps/rooms/rust/application/src/server/peering/` carries peered rooms through
the handoff path with profile-aware lowering. `apps/rooms/irc/` retains only the
shared TypeScript consumer vocabulary. No netlayer symbol, locator scheme, or
session type learned that IRC exists.

## Evidence and gate

`zig build rooms-server-test` holds room links, host-authored multi-location
routes, the per-directory session model, directory peering, and the lowering
rules. The `rooms-web-*` browser proofs (`zig build rooms-web-routes`,
`rooms-web-private`, `rooms-web-reconnect`, `rooms-web-dm-foreign`) hold the
tab-side model, including creating a link from the visible control and using a
private room's link after a server restart. The bridge is checked in both
directions against a scripted in-process IRC server fixture through the native
Rooms profile and the Goblins-compatible 1.0/Syrup floor. The front is checked
by socket-driven goldens that prove the complete channel vocabulary plus
introduced direct messages meeting over Noise on one live peer connection.
`zig build goblins-rooms`, `zig build goblins-rooms-peering`, and
`zig build goblins-rooms-irc` hold the live Goblins compositions. The Peering
fixture enters a foreign listing from a real v1.0/Syrup vat, revokes discovery,
and continues using the already-handed room. Live Libera is an opt-in demo.

## Notes

Related: [ADR-0125](ADR-0125-identity-route-multihome.md) for the route bundle
a peered room carries, [ADR-0126](ADR-0126-durable-room-stewardship.md) and
[ADR-0127](ADR-0127-room-steward-operator.md) for the steward authority the
IRC front does not project.
