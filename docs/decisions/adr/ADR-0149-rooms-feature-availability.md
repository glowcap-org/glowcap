---
id: ADR-0149
status: accepted
date: 2026-09-12
tags: [rooms, capabilities, protocol, ui]
decision: "A Rooms client learns what it can do in a room from what it holds and what the room keeps from what it states: authority is a facet the subscribe answer hands over or withholds, description is a fact told at arrival, and nothing probes a verb."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0149 Rooms feature availability

## Context

A room bridged to IRC cannot take a file, keeps no link previews, and relays
no typing signal, and a one-way bridge cannot take a line at all. Until this
decision the browser found each of those out at send time. The attach control
was drawn everywhere, a pasted screenshot was refused with "the membership has
no method attach", draft preview chips loaded and were dropped on send, and a
typing signal was told to a seat that ignored it. One feature, link previews,
had its own answer, a `messageFeatures` verb the Rust client probed and cached,
with a partner break read as "no". That is one mechanism per feature, and each
one a description the client trusts.

The question is where a client learns what a room affords. Authority is what a
capability holds, so the answer is a held reference. OCapN has no introspection:
a peer does not ask an object which verbs it answers, it is handed the objects
that answer them. The subscribe answer already worked this way for one feature.
It hands a participant the topic authority as a separate reference and an
observer a null, and the page draws the topic control from holding it. A
read-only membership already has a name, the `observer` seat kind, which the IRC
bridge did not use: it seated read-only readers as participants and refused
their posts.

## Decision

What a member can *do* in a room is what they hold, and the subscribe answer
is where a room hands it over: `[seat, kind, topic, files]`. The seat's kind
says whether lines can be posted, so a read-only bridge seats an observer. The
`topic` slot is the authority to set the topic. The `files` slot is the
authority to stage files against the room's storage and publish them. `attach`
and `postFiles` go to it, a participant in a room that can hold bytes is
handed one, and a room that cannot answers null. Every client reads that
answer through one reader per language, generated from
`tools/gen/rooms_protocol.zig`. The page's `grants` set carries "files"
beside "topic" and "steward", so the attach control, the drop target, and a
pasted file are drawn from the same seam the topic control is.

What a room *keeps* of a message that no capability stands for, it states, on
the same structured tail its other standing facts ride, as
`notify("room", "", "carries", ...features)` at arrival and before the roster.
The vocabulary is `previews` and `typing`, positive and additive: a feature
named is carried, one not named is not, one a client does not know is skipped,
and a room that never states the fact has not said it lacks anything. The
Rust and TypeScript readers live in `rooms_application::room::carries` and
`apps/rooms/lib/room/message.ts`.

The line between the two is whether a member could hand the thing to
somebody else. Files can be: a helper holding the facet posts on the member's
behalf without holding the seat. Whether the room keeps a preview selection or
relays a courtesy signal is a property of the room, not a thing anybody holds,
so it is described rather than handed over. The `messageFeatures` probe is
retired. The fact answers it.

## Scope (what this does not decide)

The line capability a post answers with, the topic authority, and the steward
are unchanged. Direct lines carry files and previews on their own inbox verbs
and state nothing. The IRC front, an IRC client on native rooms, is the
reverse direction and keeps its existing notices for what IRC cannot show.

## Alternatives Considered

- **One stated fact naming every feature, files and text included**: a list
  the client trusts rather than a thing it holds, and a second authority over
  what the seat already says. Rejected because it describes authority instead
  of conferring it.
- **A facet for every feature, previews and typing included**: invents
  authority where there is none and costs an export per membership for a
  courtesy signal. Rejected because nothing is handed over by holding it.
- **Keep probing verbs, one per feature**: `messageFeatures` generalized.
  Rejected because a probe is a round trip per feature per room, its
  "unknown method" answer is indistinguishable from a break, and it is still a
  description.

## Consequences

The subscribe answer grows a fourth nullable reference in every client's
grammar. The native server spawns a files facet per participant beside the
seat. The IRC bridge and the operator gateway answer null there. The IRC
bridge seats observers when it runs one way, so the composer says the room is
read-only before anything is typed. The browser's composer admission refuses
files for a membership that holds no facet, at the one path every controller
submits through. The session view carries `canPostFiles` beside `canSetTopic`
and `carries` beside `bridge`.

## Evidence and gate

`rust/proofs/fixtures/membership.json` holds the answer reader to the four-slot
shape and refuses the three-slot one. `rust/application/src/server/rooms/tests.rs`
and `server/irc/room/tests.rs` pin the `carries` notice ahead of the arrival
mark. `apps/rooms/test/room/facts_test.ts` reads the fact. `test/store/irc_test.ts`
and `test/attached/projection_test.ts` draw the grant and the fact into the
page. `zig build gen-rooms-protocol-check` holds the application and every
client's grammar to the one table. `zig build rooms-rust-test` and
`zig build rooms-server-test` run the rest.

## Notes

Sits on the session and Host vocabulary ADR-0079 fixes for the core, and on
the Rooms crate boundaries ADR-0147 and ADR-0148 draw.
