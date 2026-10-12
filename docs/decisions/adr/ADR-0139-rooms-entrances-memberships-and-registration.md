---
id: ADR-0139
status: accepted
date: 2026-08-28
tags: [rooms, capabilities, membership, invitations, registration, sessions]
decision: "A room has stable identity independent of its public registration. Reusable and one-shot entrance capabilities mint live membership capabilities, and the directory publishes only the attenuated entrance selected by the room manager."
supersedes: []
superseded_by: []
amends: [ADR-0128, ADR-0134, ADR-0135]
amended_by: [ADR-0142, ADR-0183]
---

# ADR-0139 Rooms entrances, memberships, and registration

## Context

Rooms used one room reference for three different acts. A directory returned it as the way into a room, `subscribe`
made the calling session a member, and later calls on the same reference spoke or left on that membership. A durable
room link repeated the same shape across restarts. Public versus private was therefore inferred from whether the room
was found by name or held by reference.

That shape cannot express a public room that admits visible readers without letting every reader speak. It also makes a
reusable room link indistinguishable from an invitation intended for one membership. Moving a room between public and
private naming would change the key used to derive its durable authority.

OCapN carries object references and their behavior. It does not define room roles, accounts, or access-control lists.
Rooms therefore needs application objects whose delegation and lifetime match the authority they represent.

## Decision

Every managed room has an opaque stable identity. Its room link, manager, moderator, invitation, history, and
revocation generations derive from that identity. A public name is a separate registration which the manager may add,
change, or withdraw without replacing the room or its existing memberships.

### Entrances and memberships

An entrance capability can create a membership. A membership capability is one live seat in the room. It owns the
ordinary operations for that seat and is held by the application session, not by a browser view.

Rooms has two membership facets:

| Membership | Authority |
| --- | --- |
| Observer | Receive the room, read retained history, appear in its roster, state presence, and leave. |
| Participant | Everything an observer can do, plus post, upload, edit through returned line capabilities, and signal typing. |

Observer and participant are facets of one membership concept. They are not account roles. Passing a membership
capability delegates that seat's authority. Releasing or revoking it ends the seat.

The room issues three kinds of entrance:

| Entrance | Lifetime | Redemption |
| --- | --- | --- |
| Public | Published under a directory registration and replaced when the manager changes public admission. | Mints the membership facet selected by the registration. |
| Room link | Reusable and stable across ordinary use and server restart until explicitly rotated or revoked. | Mints a participant membership. |
| Invitation | Good for one live membership. A live invitation stays with its runtime owner. A durable invitation sturdyref can outlive that runtime. | Mints the observer or participant membership chosen when it was issued. |

A public registration selects one public surface:

| Registration | Directory result |
| --- | --- |
| Open | Participant entrance. |
| Moderated | Observer entrance. A participant invitation or room link carries the stronger admission. |
| Private | No registration, metadata, or public entrance. |

An observer is a visible member. Rooms has no second, invisible watching state. Selecting a moderated room joins it as
an observer and keeps it in the session's conversation list.

### One-shot redemption

Copying an invitation copies a reference to the same stateful object. It does not multiply the available membership.
Concurrent claims race for one durable transition.

The claimant supplies an unguessable receipt before redemption. The invitation records the winning receipt and creates
one shared pending admission. Repeating the winning claim may return another entrance, but every returned entrance
competes over that same admission. The first successful subscription consumes it and another receipt is refused. This
preserves one-shot behavior when the transport ends after the server commits the claim but before its answer arrives.

Expiry and revocation are Rooms behavior, not OCapN behavior. Resource pressure never silently expires authority.
Durable pending invitations are bounded, visible to their issuer, and explicitly revocable. A live invitation needs no
sturdyref and ends with the runtime owner that hosts it.

### Administration

The manager capability controls the registration, public entrance generation, reusable room-link generation, and
invitation issuance. These acts remain available while the room is empty because registration outlives membership.

The moderator capability controls live memberships. It may remove a seat or grant a participant facet to an exact
observer membership. It cannot change registration, mint durable room links, or acquire IRC operator privilege.

Changing public admission retires the public entrance generation so a previously fetched but unused public entrance
cannot bypass the new policy. Existing memberships and separately issued room links or invitations remain valid.
Withdrawing a registration removes discovery and public admission without ending current memberships.
It does not revoke the room link, moderator, or manager. The same manager may
offer a public registration again, subject to the ordinary name collision rule.

### Session custody

A browser-owned session holds its memberships until that runtime ends. A shared Rooms session holds them while browser
views detach, like a bouncer. A view observes and exercises the session's memberships but does not become their owner.

Saved sturdyrefs remain explicit bearer authority. Workspace labels and desired room names are reconstruction intent
only. Losing a session loses live memberships and live invitations unless a durable entrance was separately retained.

## Compatibility and evidence

The baseline directory list remains the Goblins-shaped `[name, count]` tuple. Rich Rooms publication rows carry the
public membership offer so the interface can distinguish open and moderated registrations. Private rooms have no
publication row.

Release evidence must cover every public surface, observer and participant behavior, live and durable invitation
redemption, competing claims, retry by the winning receipt, expiry, revocation, room-link reuse, public-entrance
rotation, policy collision rollback, empty-room restoration, shared-session custody, and IRC source ownership.

## Consequences

Room identity, registration, entrance, membership, moderation, and management have separate owners and lifetimes. A
public policy change does not rotate unrelated room authority. A one-shot invitation can be shared as text without
becoming a reusable room link.

The server hosts one bounded membership object per seat and one bounded pending object per invitation. Ordinary posts
arrive on a membership capability, so authorization is one capability dispatch rather than a name or account lookup.
Directory snapshots add no capability occurrence to their baseline form.
