---
type: static
description: Diagrams of sturdyref anatomy, locators, and fetching an object by swiss number.
sources:
  - resource: /src/ocapn/engine/sturdyref.zig
  - resource: /src/ocapn/engine/fetch.zig
  - resource: /src/ocapn/session/sturdyref_cache.zig
  - resource: /src/ocapn/model/peer_locator.zig
---

# Sturdyrefs and locators

These diagrams follow the OCapN Locators specification and the CapTP
Specification section The bootstrap Object (fetch). The next profile carries the resolver and
listen mode in the fetch deliver. Goblins V1.0 carries the resolver as its
fourth operand.

## ST-1: Sturdyref anatomy

A sturdyref is offline authority: a locator saying _where_ the hosting peer
lives plus a swiss number saying _which_ object to fetch there. It carries no
live session state, so the token survives restarts. Whether it still redeems
after the hosting peer restarts depends on that host re-registering the swiss
number under the same identity. glowcap keeps no registry across processes,
so a glowcap host republishes the name from its saved entropy
(see [boundaries](../boundaries.md)).

```mermaid
flowchart TD
    SR["sturdyref"] --> LOC["peer locator"]
    SR --> SW["swiss number"]
    LOC --> TR["transport designator"]
    LOC --> AD["address / hints"]
    SW --> AU["unguessable token naming one object at that peer"]
```

## ST-2: Enlivenment

Turning a sturdyref into a live reference takes two moves: establish a session
per the locator if none exists, then bootstrap-`fetch` the swiss number. The
result is an ordinary import.

```mermaid
sequenceDiagram
    participant H as Holder
    participant P as Hosting peer
    Note over H: holds sturdyref (locator, swiss number)
    H->>P: op:start-session handshake per the locator
    H->>P: op:deliver (to desc:export 0, ['fetch, swiss-num], answer-pos N, resolver R, mode 3)
    P->>H: op:deliver-only (to desc:export R, ['fulfill, desc:import-object M])
    Note over H: sturdy authority is now a live import at M
```

## ST-3: Enlivenment dedup

OCapN's equality rules require successive enlivenments of the same sturdyref
over the same session to compare equal. A second fetch of an already-enlivened
swiss number therefore reuses the existing live import. The Host first checks
that the selected session's transport and designator match the sturdyref. Hints
do not affect peer identity, and a mismatch is refused before cache lookup or
wire traffic.

```mermaid
flowchart TD
    EN["enliven sturdyref"] --> PM{"selected session matches the sturdyref peer?"}
    PM -->|no| RF["refuse - no wire traffic"]
    PM -->|yes| CK{"swiss number already enlivened on this session?"}
    CK -->|no| FE["bootstrap fetch over the wire"]
    FE --> REC["record swiss number to live-import mapping"]
    CK -->|yes| RE["reuse the recorded live import - no wire traffic"]
    REC --> EQ["successive enlivenments compare equal"]
    RE --> EQ
```
