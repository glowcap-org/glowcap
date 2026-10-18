---
type: static
description: Diagrams of three-party handoffs, covering depositing a gift, certificates, and withdrawing it.
sources:
  - resource: /src/ocapn/engine/handoff_gifter.zig
  - resource: /src/ocapn/engine/handoff_recipient.zig
  - resource: /src/ocapn/engine/handoff_names.zig
  - resource: /src/ocapn/model/handoff.zig
---

# Three-party handoffs

These diagrams follow the CapTP Specification sections Third Party Handoffs
(depositing the gift, desc:handoff-give, desc:handoff-receive, validation) and
The bootstrap Object (the `withdraw-gift` method). All certificates ride
`desc:sig-envelope` (Ed25519 over the canonical bytes of the inner
certificate). Settlement arrows below are resolver callbacks. Both profiles carry the
resolver in the withdrawal deliver, and next also carries the listen mode.

## HO-1: Roles and sessions

Three peers hold three sessions between them. The Gifter already talks to both
other parties. The Receiver establishes the Receiver–Exporter session, if it
is absent, to withdraw.

```mermaid
flowchart LR
    G["Gifter"] ---|"G-X session, existing"| X["Exporter"]
    G ---|"G-R session, existing"| R["Receiver"]
    R -.->|"R-X session, established to withdraw"| X
```

## HO-2: Happy path overview

HO-3 through HO-7 zoom into each of the five steps.

```mermaid
sequenceDiagram
    participant G as Gifter
    participant X as Exporter
    participant R as Receiver
    G->>X: 1. deposit-gift (gift-id, gifted-ref) on G-X
    G->>R: 2. signed desc:handoff-give on G-R
    Note over R: 3. parse exporter-location, dial Exporter
    R->>X: 4. withdraw-gift (signed desc:handoff-receive) on R-X
    Note over X: 5. verify both signatures, check handoff-count
    X->>R: resolver callback (fulfill gifted-ref)
```

## HO-3: Step 1: deposit-gift

Step 1 is an ordinary bootstrap-object call on the Gifter–Exporter session. The
Exporter stores the gift in that session's table, keyed by gift-id, until a
matching withdrawal or session close.

```mermaid
sequenceDiagram
    participant G as Gifter
    participant X as Exporter
    G->>X: op:deliver (to desc:export 0, ['deposit-gift, gift-id, gifted-ref])
    Note over X: G-X session table records (gift-id, gifted-ref)
```

## HO-4: The desc:handoff-give certificate

The give carries five fields, signed by the Gifter with its key from the
Gifter–Exporter (G-X) session. Each field exists so a specific later check can
hold, as HO-5 and HO-7 show.

```mermaid
flowchart TD
    SIG["desc:sig-envelope - Gifter signs with its G-X session key"] --> HG["desc:handoff-give"]
    HG --> RK["receiver-key: Receiver's pubkey in the G-R session"]
    HG --> EL["exporter-location: how the Receiver reaches the Exporter"]
    HG --> GXS["session: the G-X session id the gift was deposited through"]
    HG --> GS["gifter-side: Gifter's identity in the G-X session"]
    HG --> GID["gift-id: matches the deposit"]
```

## HO-5: Step 3: Receiver-side validation

The Receiver cannot verify the Gifter's signature yet, because it has never seen
the Gifter's G-X pubkey. That check belongs to the Exporter. The spec also
suggests the Receiver check that the give's receiver-key names it. glowcap
leaves that to the Exporter too, where the receive must be signed by that
key (HO-7), so a mis-addressed give fails at withdraw rather than locally.
What the Receiver does check locally is the exporter-location: an unparseable
locator fails closed with no dial.

```mermaid
flowchart TD
    IN["inbound signed desc:handoff-give"] --> LOC{"exporter-location parseable?"}
    LOC -->|no| REJ["fail closed - no dial"]
    LOC -->|yes| PR["create local promise for the gift"]
    PR --> CONN["connect to the Exporter if no session exists"]
    CONN --> CNT["allocate next handoff-count: R-X session in next, Node-lifetime cursor in V1"]
    CNT --> HR["build desc:handoff-receive, sign with my G-R key"]
    HR --> WD["send withdraw-gift to the Exporter's bootstrap object"]
```

## HO-6: The desc:handoff-receive certificate

The receive carries four fields wrapping the original signed give. The Receiver
signs it with its key from the Gifter–Receiver (G-R) session, not the
Receiver–Exporter (R-X) session. That is what binds the new R-X identity to the
identity the Gifter addressed.

```mermaid
flowchart TD
    SIG["desc:sig-envelope - Receiver signs with its G-R session key"] --> HR["desc:handoff-receive"]
    HR --> RS["receiving-session: the R-X session id"]
    HR --> RSide["receiving-side: Receiver's identity in the R-X session"]
    HR --> HC["handoff-count: session-local in next, Node-lifetime monotonic in V1 for Goblins compatibility"]
    HR --> SG["signed-give: the Gifter's certificate, carried whole"]
```

## HO-7: Step 5: Exporter-side validation

The Exporter is the only party that can verify both signatures. It knows the
Gifter's pubkey from the G-X session, and the give itself carries the
receiver-key that must have signed the receive. A failed check refuses the
withdrawal by breaking its answer with a typed reason. The session stays open.

```mermaid
flowchart TD
    IN["inbound withdraw-gift"] --> LIVE{"named G-X session still open?"}
    LIVE -->|no| BK["break the withdraw answer"]
    LIVE -->|yes| S1{"give signature valid against that session's pubkey?"}
    S1 -->|no| BK
    S1 -->|yes| S2{"receive signature valid against receiver-key from the give?"}
    S2 -->|no| BK
    S2 -->|yes| S3{"handoff-count above the last accepted for this receiving session?"}
    S3 -->|no| BK2["break - replay"]
    S3 -->|yes| TK["take gift-id from the G-X session table"]
    TK --> RES["resolve the withdraw answer with the gifted reference"]
```

Replay authority lives with the live sessions:

- The count guard is one monotonic scalar on the live R-X session.
- The gift table belongs to the live G-X session.
- Closing either `Peer` destroys the authority it owns. No Host- or Vat-wide
  replay map survives.
- Every Host session derives a distinct signing seed from a process-fresh,
  domain-separated session root and a monotonic counter (ADR-0097). A
  reconnect cannot recreate the old side or session names, so an old signed
  receive cannot name a replacement session.
- The V1 Node uses a separate lifetime cursor for receive-certificate issuance
  to accommodate the pinned Goblins counter behavior across reconnects.

## HO-8: Withdraw before deposit

The two inbound legs race: the Receiver's withdrawal can reach the Exporter
before the Gifter's deposit does. The Exporter resolves the still-open gifter
session named by the give, verifies both signatures and the receiving-session
names, and advances the Receiver–Exporter session's replay counter before it
waits. When the matching gift-id lands, the accepted withdrawal consumes it
without treating its own count as a replay.

```mermaid
sequenceDiagram
    participant R as Receiver
    participant X as Exporter
    participant G as Gifter
    R->>X: withdraw-gift (gift-id 7), arrives first
    Note over X: resolve gifter session and verify the certificates
    Note over X: accept replay count, then park the verified withdrawal
    G->>X: deposit-gift (gift-id 7, gifted-ref)
    Note over X: deposit lands, accepted withdrawal consumes it
    X->>R: resolver callback (fulfill gifted-ref)
```
