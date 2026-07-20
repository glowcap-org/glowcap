# Session lifecycle

Anchors: CapTP Specification § CapTP Overview, § op:start-session, § Ending a
session, § Crossed Hellos Resolution.

## SL-1: Session state machine

The lifecycle is one-way: a session moves from `Negotiating` to `Open` to
`Closed`, with one self-loop where a refused handshake stays negotiating. No
transition reverses; a closed session never reopens.

```mermaid
stateDiagram-v2
    [*] --> Negotiating
    Negotiating --> Open: both start-session halves observed, versions equal
    Negotiating --> Negotiating: handshake refusal (typed op:abort queued, ADR-0083)
    Negotiating --> Closed: op:abort received, fatal non-handshake refusal, or transport closed by the adapter
    Open --> Closed: abort (sent or received)
    Closed --> [*]
```

## SL-2: op:start-session handshake

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

## SL-3: Handshake refusal

A version mismatch or a location signature that fails verification refuses the
handshake: the offended side emits the typed `op:abort` and stays negotiating.
Staying negotiating is ADR-0083's named exception, spelled out in SL-6;
severing the transport is the adapter's call, not the session's. The refused
hello never opens the session; a corrected hello on the same stream still can,
and it grants nothing a first valid hello would not. A partner that severs
after aborting, as the spec advises and Goblins does, never uses that retry:
it is pancake's session-layer accounting, not an interop expectation.

```mermaid
sequenceDiagram
    participant A as Peer A
    participant B as Peer B
    A->>B: op:start-session (captp-version 1.0, ...)
    Note over B: version unsupported, or location-sig invalid
    B->>A: op:abort (reason)
    Note over A,B: session never Opened; B stays Negotiating (SL-6)
```

## SL-4: Crossed hellos

Anchor: CapTP Specification § Crossed hellos. Two peers dialing each other
simultaneously produce two half-open sessions for one peer pair. A deterministic
tie-break over the two sessions' key material selects the survivor; the losing
session is aborted. Exactly one open session per peer pair survives.

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

## SL-5: Per-state message admission

What a session admits depends only on its state. While negotiating, only the
handshake itself (`op:start-session`) and `op:abort` get through; authority-
bearing traffic (`op:deliver`, `op:resolve`, gc ops, `op:listen`, `op:get`,
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
reaches the same teardown: a record the receiver does not recognize is a
protocol error, and a protocol error aborts the session. Handshake refusals
while still `negotiating` (version mismatch, bad signature, partner-key pin)
queue an outbound `op:abort` without moving to Closed
([ADR-0083](../decisions/adr/ADR-0083-outbound-abort-closes-session.md)).

```mermaid
flowchart TD
    AB["op:abort sent or received on an open session"] --> CL["state becomes Closed"]
    CL --> T1["release all imports and exports"]
    CL --> T2["break every unresolved promise"]
    CL --> T3["release answer tables"]
    CL --> T4["discard per-session key material"]
    UR["unrecognized wire record"] --> PE["protocol error"] --> AB
    HR["handshake refusal while negotiating"] --> AO["queue op:abort, stay Negotiating"]
```

One deliberate survivor is the handoff-count replay guard. It lives in the
vat-scoped gift registry, not in any one CapTP session, so a host that keeps the
registry across reconnects still refuses a replayed count. See
[06-handoffs.md](06-handoffs.md) HO-7.
