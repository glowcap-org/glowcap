---
type: static
description: The loopback scenario and the checks that verify the Accountability application's signed requests and audit log.
sources:
  - resource: /apps/accountability-on-glowcap/zig/
  - resource: /apps/accountability-on-glowcap/deno/
  - resource: /apps/accountability-on-glowcap/python/
---

# Accountability design and verification

This note describes the checks behind the
[Accountability application](README.md).

## Two-peer scenario

`zig build accountability` runs two glowcap peers over a real loopback TCP
socket:

1. The host and caller each create a KERI-shaped AID from an inception event.
2. The caller rotates its key. The inception event had already committed to the
   digest of that next key.
3. The host publishes the Affordance as a capability.
4. Before sending, the caller records an Attempt Episode.
5. The caller invokes the Affordance with a signed request and its key-event
   log.
6. The host validates the log, binds its current key to the claimed AID, and
   verifies the request signature.
7. A tampered signature breaks with `UnattestedCaller`. The host writes no
   Episode.
8. A valid signature made with a retired key breaks with `UnboundCaller`. The
   host writes no Episode.
9. The accepted Outcome Episode names the caller's AID. The run verifies its
   payload signature, countersignature, and transparency root.

The host records the outcome inside the actor turn. The app imports the `glowcap` module and does not reach
into protocol internals.

## Validating a key-event log

`zig/identity.zig` owns the controller. `zig/kel.zig` implements the walk in
`currentVerkey`. SAID rendering and keys live in `zig/said.zig`. Zig, Deno, and
Python callers are checked the same way:

- The claimed AID must equal the self-addressing identifier of the inception
  event. That identifier is derived from the event that names the first key.
- Every event's identifier must match a digest of that event's bytes.
- The first event must be an inception event.
- Each rotation must name its predecessor.
- Each rotation must reveal the key its predecessor committed to.
- Each rotation must be signed by the key it retires.
- The key presented with the request must be the final key in the validated
  history.

The tests also refuse an edited event, a history beginning with a rotation, a
broken predecessor link, an uncommitted next key, a rotation signed by the
wrong key, an AID the history does not derive, and a request signed by a retired
key.

The host validates the history it is given, so it cannot know the caller
withheld a newer event. Closing that gap takes witness receipts or retained
cross-session state.

## Cross-language scenario

`zig build demo-accountability` starts a new `accountability-host` process for
each caller. Deno and Python independently:

1. create an AID
2. rotate once
3. sign the request
4. send the key-event history with the invocation

The Zig host derives the same identifier from the received history. The
accepted response is `ack:read-thermostat`. The two rejection cases use
`UnattestedCaller` and `UnboundCaller`.

The host serves one connection and exits, so this demo has no attach mode.

## Three-party scenario

`zig build accountability-three-party` runs three owning Hosts over loopback
TCP. A fetches C's Affordance, returns that foreign-homed capability to B, and
B's Host redeems the handoff by dialing C through the ordinary `Session.call`
path. B rotates before invoking the introduced capability, and C's Outcome Episode
attributes B rather than A. The identity check belongs to this application and
the introduction belongs to OCapN. Bare TCP is isolated test transport.

## Source map

| File | Role |
| --- | --- |
| `zig/main.zig` | Two-peer Zig scenario. |
| `zig/said.zig` | SAID rendering, Ed25519 keys, and the draft digest minting and verification share. |
| `zig/identity.zig` | Identity creation and rotation. |
| `zig/kel.zig` | Key-event minting and walking a presented log. |
| `zig/episode.zig` | Episode creation, signatures, and audit. |
| `zig/log.zig` | Merkle transparency log over Episode hashes. |
| `zig/accountable.zig` | Durable Episode store. |
| `zig/host.zig` | Single-caller Zig host for foreign-language runs. |
| `zig/three_party_test.zig` | Attribution after a three-Host TCP handoff. |
| `deno/caller.ts`, `deno/identity.ts` | TypeScript identity and caller. |
| `deno/blake3.ts`, `python/blake3.py` | Blake3-256 for SAIDs. The host platforms do not carry it. |
| `python/caller.py`, `python/identity.py` | Python identity and caller. |
| `deno/demo.ts` | Cross-language orchestrator. |

Runtime output is written to `.data/`:

- `episodes.jsonld` contains the durable Episode records.
- `transparency.root` contains the current Merkle root.

The directory is generated state and is not committed. An auditor needs a root
retained or published elsewhere to detect replacement of both local files.
