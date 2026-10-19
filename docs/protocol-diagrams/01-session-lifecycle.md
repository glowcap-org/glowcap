---
type: static
description: Diagrams of the CapTP session lifecycle, covering states, handshake, ending a session, and crossed hellos.
sources:
  - resource: /src/ocapn/session/
  - resource: /src/ocapn/engine/hello.zig
  - resource: /src/ocapn/engine/negotiation.zig
  - resource: /src/ocapn/engine/pairing.zig
---

# Session lifecycle

These diagrams follow the CapTP Specification sections CapTP Overview,
op:start-session, Ending a session, and Crossed Hellos Resolution.

## SL-1: Session state machine

The lifecycle is one-way: a session moves from `Negotiating` to `Open` to
`Closed`. A refused handshake is terminal like every other abort
([ADR-0030](../decisions/adr/ADR-0030-failure-and-close-policy.md)). A
closed session never reopens.

```mermaid
stateDiagram-v2
    [*] --> Negotiating
    Negotiating --> Open: both start-session halves observed, versions equal
    Negotiating --> Closed: handshake refusal (abort queued), abort received, or transport closed by the adapter
    Open --> Closed: abort (sent or received)
    Closed --> [*]
```

## SL-2: op:start-session handshake

Anchor: CapTP Specification § op:start-session. Each side sends one
`op:start-session`. The session opens when both halves have been observed and
verified. The bootstrap object is installed at export position 0.

```mermaid
sequenceDiagram
    participant A as Peer A
    participant B as Peer B
    A->>B: op:start-session (captp-version, session-pubkey, acceptable-location, location-sig)
    B->>A: op:start-session (captp-version, session-pubkey, acceptable-location, location-sig)
    Note over A,B: each side verifies the partner's location signature
    Note over A,B: captp-version strict-compares equal
    Note over A,B: session Open, bootstrap object at export position 0
```

## SL-3: Handshake refusal

A version mismatch or a location signature that fails verification refuses the
handshake: the offended side emits the typed `op:abort` and closes the CapTP
session. The refused hello never opens the session, and no corrected hello is
admitted on the aborted stream.

```mermaid
sequenceDiagram
    participant A as Peer A
    participant B as Peer B
    A->>B: op:start-session (captp-version 1.0, ...)
    Note over B: version unsupported, or location-sig invalid
    B->>A: op:abort (reason)
    Note over A,B: session never Opened, B is Closed (SL-6)
```

## SL-4: Crossed hellos

Anchor: CapTP Specification § Crossed hellos. Two peers dialing each other
simultaneously produce two half-open sessions for one peer pair. Each side
compares the public identifiers of the two sessions byte by byte, and the
session with the lower identifier is aborted.

```mermaid
sequenceDiagram
    participant A as Peer A
    participant B as Peer B
    par A dials B
        A->>B: op:start-session
    and B dials A
        B->>A: op:start-session
    end
    Note over A,B: two sessions now exist for one peer pair
    Note over A,B: compare the two sessions' public identifiers bytewise
    A--xB: op:abort on the session with the lower identifier
    Note over A,B: the surviving session opens normally
```

## SL-5: Per-state message admission

What a session admits depends only on its state. While negotiating, only the
handshake itself (`op:start-session`) and `op:abort` get through. Authority-
bearing traffic (`op:deliver`, gc ops, `op:listen`, `op:get`,
`op:index`, handoffs) requires Open.

```mermaid
flowchart TD
    M["message at the session boundary"] --> S{"session state"}
    S -->|Negotiating| N{"op:start-session or op:abort?"}
    N -->|yes| OK1["admit"]
    N -->|no| RF1["refuse - lifecycle violation"]
    S -->|Open| OK2["admit all traffic"]
    S -->|Closed| RF3["refuse everything"]
```

## SL-6: Abort teardown effects

Anchor: CapTP Specification § Ending a session. `op:abort` (in either direction)
severs an open session: all imports and exports release, unresolved promises
break, and per-session key material is discarded. An unrecognized wire record
is a protocol error, and a protocol error aborts the session. A handshake
refusal while still `negotiating` (version mismatch, bad signature, partner-key
pin) queues an outbound `op:abort` and then closes the session
([ADR-0030](../decisions/adr/ADR-0030-failure-and-close-policy.md)).

```mermaid
flowchart TD
    AB["op:abort sent or received on an open session"] --> CL["state becomes Closed"]
    CL --> T1["release all imports and exports"]
    CL --> T2["break every unresolved promise"]
    CL --> T3["release answer tables"]
    CL --> T4["discard per-session key material"]
    UR["unrecognized wire record"] --> PE["protocol error"] --> AB
    HR["handshake refusal while negotiating"] --> AO["queue op:abort, then state becomes Closed"]
```

Handoff replay authority follows the same lifecycle. Each live
Receiver–Exporter session owns one monotonic accepted count. Closing it destroys
that counter. Deposited gifts likewise die with their Gifter–Exporter session.
See [06-handoffs.md](06-handoffs.md) HO-7.
