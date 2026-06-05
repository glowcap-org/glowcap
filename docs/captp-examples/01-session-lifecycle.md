# Session lifecycle

Anchors: CapTP Specification § Sessions, § op:start-session, § Ending a
session, § Crossed hellos.

## SL-1 — Session state machine

The lifecycle is one-way: `Negotiating → Open → Draining → Closed`. No
transition reverses; a closed session never reopens.

```mermaid
stateDiagram-v2
    [*] --> Negotiating
    Negotiating --> Open: both start-session halves observed, versions equal
    Negotiating --> Closed: version mismatch or invalid location signature
    Open --> Draining: local decision to wind down
    Open --> Closed: abort (sent or received)
    Draining --> Closed: outstanding answers settled, or abort
    Closed --> [*]
```

`Draining` is a local posture, not a wire state — the partner sees nothing
until the session aborts or closes.

## SL-2 — op:start-session handshake

Anchor: CapTP Specification § op:start-session. Each side sends one
`op:start-session`; the session opens when both halves have been observed and
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

## SL-3 — Handshake refusal

A version mismatch or a location signature that fails verification is fatal:
the offended side sends `op:abort` and the session moves straight to Closed
without ever opening.

```mermaid
sequenceDiagram
    participant A as Peer A
    participant B as Peer B
    A->>B: op:start-session (captp-version 1.0, ...)
    Note over B: version unsupported, or location-sig invalid
    B->>A: op:abort (reason)
    Note over A,B: session Closed, never Opened
```

## SL-4 — Crossed hellos

Anchor: CapTP Specification § Crossed hellos. Two peers dialing each other
simultaneously produce two half-open sessions for one peer pair. A
deterministic tie-break over the two sessions' key material selects the
survivor; the losing session is aborted. Exactly one open session per peer
pair survives.

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
    Note over A,B: deterministic tie-break over session key material
    A--xB: op:abort on the losing session
    Note over A,B: the surviving session opens normally
```

## SL-5 — Per-state message admission

What a session admits depends only on its state. Authority-bearing traffic
(`op:deliver`, `op:resolve`, gc ops, `op:listen`, `op:get`, `op:index`,
handoffs) requires Open or Draining; Draining additionally refuses initiating
*new outbound* delivers so pending answers can settle.

```mermaid
flowchart TD
    M["message at the session boundary"] --> S{"session state"}
    S -->|Negotiating| N{"op:start-session or op:abort?"}
    N -->|yes| OK1["admit"]
    N -->|no| RF1["refuse - lifecycle violation"]
    S -->|Open| OK2["admit all traffic"]
    S -->|Draining| D{"new outbound op:deliver?"}
    D -->|yes| RF2["refuse"]
    D -->|no| OK3["admit"]
    S -->|Closed| RF3["refuse everything"]
```

## SL-6 — Abort teardown effects

Anchor: CapTP Specification § Ending a session. `op:abort` (in either
direction) severs the session: all imports and exports release, unresolved
promises break, and per-session key material is discarded. The unrecognized-
record policy feeds this path: a wire record the receiver does not recognize
is a protocol error and aborts the session.

```mermaid
flowchart TD
    AB["op:abort sent or received"] --> CL["state becomes Closed"]
    CL --> T1["release all imports and exports"]
    CL --> T2["break every unresolved promise"]
    CL --> T3["release answer tables"]
    CL --> T4["discard per-session key material"]
    UR["unrecognized wire record"] --> PE["protocol error"] --> AB
```

One deliberate survivor: the handoff-count replay-protection set is scoped to
the *introduction* session identity, not the carrying connection, so a
reconnecting Receiver cannot replay a previously seen count (see
[06-handoffs.md](06-handoffs.md) HO-7).
