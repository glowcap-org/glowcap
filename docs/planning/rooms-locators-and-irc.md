# Room links, directory peering, and the IRC gateway

Status: active plan. Tier 1 room joins and several rooms at once ship; direct
room sturdyrefs, the multi-directory session model, directory peering, and both
IRC adapters remain. This plan extends the rooms
application described in [`apps/rooms/README.md`](../../apps/rooms/README.md)
and [`apps/rooms/developing.md`](../../apps/rooms/developing.md). The one-line
direction already recorded there ("IRC is a front, not a netlayer") is expanded
by this plan, not replaced.

## Destination

A room is the addressable unit of rooms, not the server it happens to live on.
Any front (the web UI, the terminal clients, the CLI) can join a room hosted on
any reachable machine by redeeming an ordinary OCapN sturdyref. Directories can
list rooms hosted elsewhere and hand them off. An IRC channel on a public
network appears as a room behind a bridge, and an IRC client can connect to a
rooms server directly through a front. No front ever learns that IRC exists.

```text
weechat ──IRC──▶ front ──▶ directory / room ◀── bridge ◀──IRC── libera/#ocapn
```

The front and the bridge are adapters at opposite edges of the same core. They
never talk to each other, and the room object between them keeps all authority.

## Design rules

Four rules shaped every choice below. A change that breaks one of them is the
wrong change.

1. **A transport is anything CapTP comes out the other end of.** The bridge
   fails that test: the far side of it is an IRC network, where there is no
   session and no capability. The bridge is therefore an application object,
   never a netlayer, and it lives above the public binding surface like every
   other app in `apps/`.
2. **Names carry their network.** A bridged room is `libera/#ocapn`, never a
   bare `#ocapn` that hides which network owns the namespace. The same channel
   name on two networks is two different rooms.
3. **One authority per room, chosen at creation.** A native room's roster is the
   rooms server's truth. A bridged room is a view of its IRC channel, and the
   channel is the truth it mirrors. A room is never half of each.
4. **The gateway is invisible in the address.** A bridged room's locator is
   indistinguishable from any other room's locator. If IRC ever appears in a
   locator scheme or segment, the bridge has leaked into the addressing layer
   and every client would need to know about it.

## Part 1: room links

Rooms already has locators at the server level. Every terminal client accepts
one, and an iroh server prints one. What is missing is the room as the
addressable thing, surfaced in every front.

**Tier 1, join by locator (shipped).** A room's full name is a server locator plus a room
name. Reaching a foreign room means dialing that server's directory and calling
`enter(name)`, exactly as the clients do against their own server today. The
work here is front plumbing, most of all in the web UI: a place to paste a
locator, and dropping the assumption that the page's server is the room's
server. The iroh relay already dials any key-verified iroh node, so the
encrypted path needs no relay change. The TCP relay stays pinned to its own
rooms server; joining across machines is a feature of the encrypted transport,
and the cleartext path keeps its existing boundary.

**Tier 2, a sturdyref per room.** The shareable room link: one OCapN sturdyref
that redeems directly into the room capability, with no name-passing step.

```text
ocapn://<node-designator>.<transport>/s/<swissnum>
```

The transport suffix says how to reach the hosting peer, the node designator
says who it is, and the swissnum designates the room. This is a feature of all
rooms, not an IRC feature. A native room wants a pasteable link for the same
reason a bridged one does, and one design serves both.

The hosting server can mint room swissnums without storing a table. The
swissnum encodes the room name together with an HMAC of that name under a
server secret. Redemption verifies the MAC and reads the room name out of the
swissnum itself, so the mint is stateless, survives restarts, and gives the
same room a stable ref. The swissnum stays unguessable to anyone without the
secret, so the OCapN sturdyref contract holds.

A room link promises that the hosting peer will enliven the room. It does not
promise the room is lively, and for a bridged room it does not promise the far
channel exists. Redemption of a link whose far side is gone succeeds and hands
back a room that reports its far side broken, so a dead channel is
distinguishable from a dead bridge.

Humans do not share swissnums. The readable name (`libera/#ocapn`, `general`)
is the human layer and the link is the real one, the same split rooms already
makes between nicknames and capabilities. The UI shows the name; the link
carries the ref.

## Part 1b: several rooms, and the session model

A tab now holds as many rooms as it likes, the way it already held as many
direct lines. Entering takes nothing away, each room delivers into its own
conversation whether or not it is the one on screen, and leaving one leaves one.
Membership needs no field of its own: a room conversation exists exactly while
its membership does, so the two cannot disagree.

That lands on one directory. **The singleton that gates everything after it is
the session**: the page holds one `Live`, and one `Live` holds one directory. A
locator chooses which directory that is, and choosing a different one replaces
the session rather than adding to it. So a tab cannot hold rooms on two servers
at once, and the interface has nothing to group by.

Splitting it is the enabling move, and the split is along a line the fields
already suggest. A few are the tab's, being keyed by something the tab mints:
transfer progress and unconfirmed sends. The rest belong to one directory: the
directory itself, the locator that reached it, its rooms, the nickname
registered on it, its deferred inbox offers, its WebRTC signaling, the blob
capabilities behind the files it carried and their object URLs, and its direct
lines.

**A direct line belongs to the directory that introduced it**, which is not
obvious and is worth stating, because the line itself is a separate connection
to the peer and could outlive it. It does not, and should not. The counterparty
of a direct line is a nickname, and a nickname is the directory's to grant and
reclaim; once this tab's session there ends, both ends of that claim have
lapsed, and a conversation kept open across it would be a conversation with
whoever holds the name now. Ending a directory session hands its lines back
today, and under several directories that has to become "its own lines", never
all of them.

**A room conversation's key gains its directory in that same change, not
before.** A key of the room name alone is correct while there is one directory
and wrong the moment there are two, because two servers may both call a room
`general`. It waits because the live-room list is name-keyed for the same reason
and collides the same way: fixing one alone leaves the other wrong and the fix
looks done. This is the architecture rule's "names carry three things" applied
to an application, and the missing dimension is whose namespace the name is in.

## Part 1c: the directory in the interface

**A directory is not a workspace you switch to.** It is closer to an IRC
network, and the difference decides the interface. A directory grants a
nickname, per connection, and takes it back when the connection ends, so who you
are and who may reach you are the directory's to say. Two directories may both
have an `alice`, and they are two people. Every directory this tab holds stays
connected, the way every room does; nothing is given up to look at something
else, because giving it up would give up an identity and a reachability, not a
view.

Rooms and direct lines stay the rail's two lists. They are different kinds of
thing rather than different places, and grouping by place does not change that.
**Inside each list, a directory is a group, and the grouping appears only when
there is more than one.** With a single directory the rail draws exactly what it
draws today, with no heading and no extra chrome, so the structure arrives when
it starts carrying information and not before.

A directory is told apart by colour, but never only by colour. The colour is the
glance, and it marks the group and each of its rows; the name lives in the group
heading and in every row's accessible label, so nothing depends on seeing it. A
locator is not a label either — `ocapn://` URIs are unreadable at a glance — so a
directory is named by what distinguishes it, the server that served the page
saying so in words, a TCP peer showing host and port, an iroh peer a shortened
node id, with the exact locator one copy away.

The foot of the rail reports one status per directory once there are several.
One line cannot say that one directory is reconnecting while another is fine,
and that is exactly the state holding several makes ordinary.

**The "+" belongs to a group, not to the list.** With more than one directory,
"create a room called `general`" has no answer until you say where, and a field
that sits inside a directory's group has already answered it. That is also what
keeps the cheap path cheap: naming a room on a directory already open stays one
field and one Enter. Reaching a room somewhere new is a step up from that same
field into the join card, carrying whatever has been typed. Nothing typed is
dropped moving between the two surfaces, which is the rule the current field
already holds when it fills the card behind it.

The phone is the one place this drills rather than groups. Vertical space is
scarce there, the narrow layout already slides between the list and the
conversation, and wide and narrow navigation are already separate state on
purpose. A level for directories is that layout's own idiom, not an exception.

A room reached by a link belongs under the peer that hosts it, because a link
names that peer. Its heading says whether this tab is registered there, which is
also the honest answer to why direct messages work under one heading and not
another: a sturdyref reaches a room, while a nickname, an introduction, and the
live list are all the directory's.

### Leaving a directory is not leaving its rooms

**A directory is left explicitly, and never implicitly.** Leaving every room on a
directory does not leave the directory, because a nickname is registered per
connection and not per room: someone who has left every room still answers to
their name for direct messages, which is exactly why the room refuses to grant a
name another live connection holds. Being connected, registered, reachable, and
in no rooms at all is a real state and a useful one, and it is the state the
page is already in the moment you leave your last room.

Leaving implicitly at zero rooms would therefore give up a name the reader never
offered to give up, free it for the next person who asks, and take that
directory's direct lines with it. None of that is recoverable by rejoining, and
none of it was asked for.

So the group heading carries the leave, beside the status it already carries,
and it says what goes: the rooms under it, the direct lines it introduced, and
the name. Leaving its rooms is a consequence of leaving it rather than a
separate act, which is the opposite of the room case and the reason the two
controls must not look alike.

The affordance implies its opposite. Once a directory can be left, a tab can
hold zero rooms on one, or none at all, so **adding a directory has to be
expressible without naming a room** — the join card asks for a room today, and a
"connect to this server" that stops short of entering anything has nowhere to be
said. A rail that can draw an empty directory group needs a way to make one.

## Part 2: directory peering

A directory that lists rooms hosted elsewhere is just a directory holding
references to them. Handing one to a member is the same three-party handoff the
DM path already ships: the directory introduces, the member redeems, the member
connects to the hosting server directly, and the introducing directory carries
none of the traffic afterward.

That is the whole federation design. There is no server-to-server protocol, no
state synchronization, and no shared authority, so netsplit semantics do not
exist because nothing is replicated. The existing `register` and `introduce`
verbs generalize from members to rooms; the work is that generalization plus
the directory UI to show foreign rooms beside native ones, labeled with where
they live.

## Part 3: the IRC bridge

The bridge is a gateway object: a rooms server whose published rooms mirror IRC
channels, holding one IRC client connection per network as private
implementation. On the rooms side it is indistinguishable from any rooms
server. It uses only the public binding surface, like every app.

- **Inbound, IRC to rooms.** The bridge puppets one rooms member per IRC nick,
  so the member list shows the channel's real roster and each message arrives
  under its author's nick. Rooms nick claims are already ephemeral, and that
  matches IRC exactly: when a nick parts the channel, the bridge drops its
  claim.
- **Outbound, rooms to IRC.** One registered connection per network, so rooms
  members appear on IRC under the bridge's nick with a `<nick>` prefix, the
  convention every relay bot uses. Per-user puppeting on public networks is a
  special arrangement with the network and is out of scope.
- **Attribution stays honest.** Everything the bridge injects into rooms is
  visibly bridge-backed, and nothing from IRC is ever presented as verified. A
  direct message to an IRC nick terminates at the bridge, because there is no
  capability on the far side to hand off to, and the UI says so rather than
  implying an end-to-end line.
- **Lifecycle follows membership.** The bridge joins a channel when the first
  rooms member enters its room and parts when the room empties, matching the
  existing rule that an empty room is removed.
- **Operations.** The bridge's nick is registered and it authenticates with
  SASL. Outbound lines are throttled below the network's flood limit, and the
  connection reconnects with backoff. These are conditions of being a good
  citizen on a public network, not options.

The first slice is read-only: mirror `libera/#ocapn` into a room and relay
nothing outward. It delivers the visible goal (the channel, live, in rooms)
with no risk of misbehaving on a public network, and the two-way slice builds
on its translation table.

The check for the bridge cannot depend on a public network. A scripted
in-process IRC server fixture covers the subset a bridge speaks (registration,
join, part, privmsg, ping) and proves the relay in both directions with no
network. Live Libera is an opt-in demo, the same posture as the iroh public
discovery demo.

## Part 4: the IRC front

The front is one more listener beside the web page and the relay, speaking the
IRC client-to-server protocol directly. An IRC client connects and its verbs
are translated onto the same directory and room capabilities every other front
uses:

| IRC verb | Capability act |
| --- | --- |
| `NICK` | claim a nickname from the room |
| `JOIN #general` | `enter("general")` on the directory |
| `PRIVMSG #general` | `post(text)` on the room |
| `NAMES`, `LIST`, `PART` | member list, room list, drop the reference |
| `PRIVMSG alice` | ask the room for an introduction and carry the DM over it |
| `PING`, `TOPIC`, `WHOIS` | liveness and room metadata numerics |

The front holds capabilities per connection and translates syntax. It invents
no semantics: a join the directory refuses becomes an IRC numeric error, never
front policy. A DM from an IRC client rides the real introduction path, so IRC
users get retarget-safe conversations without knowing the feature exists. The
line still terminates at the rooms server, because an IRC client cannot hold
capabilities itself, and no numeric claims otherwise.

The front has no operator modes in its first slice, because native rooms have
no moderation yet. When rooms grows moderation as attenuated room facets, IRC
modes map onto those facets; the front never gets its own privilege system.

Its check is a set of goldens driven by a scripted socket, the same way the
relay tests drive the relay, with no external IRC software anywhere.

The front and the bridge share one IRC vocabulary module (line parsing,
message shapes, the verb mapping), with the front reading the table one way and
the bridge the other. The mapping has one authority so the two edges cannot
drift apart.

## Refusals

Two shapes are refused, and when the first IRC piece lands, both belong in
[`docs/boundaries.md`](../boundaries.md) beside the other named boundaries.

- **No server-to-server linking.** Actually linking into an IRC network as a
  peer server would import IRC's federation model, where every linked server
  is implicitly trusted by the whole network and can forge anyone. That is
  precisely the authority model this project exists to not have. The front is
  client-to-server only.
- **No `relay-irc` netlayer.** Carrying CapTP itself over IRC in the
  `noise-relay` shape (the IRC server as an untrusted pipe forwarding
  ciphertext, Noise between the real peers) would satisfy the
  participants-only contract in principle. It is refused on arithmetic, not
  principle: 512-byte lines, text-safe encoding overhead, and public flood
  limits near one line per second cap the channel at a few hundred bytes per
  second, and exceeding the limit disconnects the session rather than queuing.
  Nothing in this plan needs it; room links make IRC reachable as cargo behind
  a locatable bridge.

## Order

Each slice ships alone and is verified alone. The order is an argument: what
comes first is what the rest is built into, so a slice moves up when leaving it
late would mean building on a shape that has to be torn out.

1. **Room links, Tier 1** (shipped) and **several rooms at once** (shipped).
2. **Profile-correct sturdyrefs** (shipped). C and every binding require the
   CapTP profile that owns the swiss-number path spelling, so a rooms peer can
   redeem the same `pancake-next` link it formats.
3. **Room links, Tier 2.** The room-ref mint and its durable state on the
   server, then redeeming a pasted link in the web UI. The mint half needs no
   interface at all and can land against the server tests alone.
4. **The multi-directory session model.** Split the one live session into per-tab
   tables and a map of directory sessions, and key room conversations and the
   live-room list by their directory in the same change. Reconnection becomes
   one backoff per directory, because one directory being unreachable says
   nothing about the others. Everything under Part 2 waits on this.
5. **The directory in the rail.** Grouping each list by directory, one status per
   directory in the foot, a colour per directory, and the add-a-room field moving
   into its group. This follows the session model rather than leading it: the
   grouping is drawn only when there is more than one directory, so until there
   can be, there is nothing to show. What can land first, and should, is sorting
   the rooms this tab holds above the rest of the list, which is worth having
   with one directory.
6. **Directory peering**, generalizing introductions from members to rooms. Its
   server half is the same three-party handoff the direct-message path already
   ships and needs no interface; the interface half is one more group in a rail
   that already groups.
7. **Read-only bridge** publishing `libera/#ocapn`, checked against the scripted
   IRC fixture, demoed live as an opt-in step.
8. **Two-way bridge**, adding the outbound relay, throttling, and the prefix
   convention.
9. **IRC front**, reusing the shared vocabulary module.

Steps 3 and 6 each have a server half that needs no interface, and both are
worth landing ahead of their interface halves: they are provable against the
server tests alone, and they keep the interface work from being the thing that
gates protocol work.

The bridge does not strictly depend on room links (a bridge on one's own
server needs no link), but links come first because they turn every later
slice into something reachable from anywhere, and because they are the one
piece that touches every front.
