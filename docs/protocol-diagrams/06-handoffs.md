# Three-party handoffs

Anchors: CapTP Specification § Third Party Handoffs (depositing the gift,
desc:handoff-give, desc:handoff-receive, validation) and § The bootstrap Object
(the `withdraw-gift` method). All
certificates ride `desc:sig-envelope` (Ed25519 over the canonical bytes of the
inner certificate). The `op:resolve` settlement arrows below draw pancake's
`pancake-next` profile shape; on the v1.0 wire the same settlement is the
resolver-callback deliver (see the vocabulary note and DR-4 in
[02-deliver-and-resolve.md](02-deliver-and-resolve.md)).

## HO-1: Roles and sessions

Three peers hold three sessions between them. The Gifter already talks to both
other parties. The Receiver–Exporter session is established (if it is absent)
in order to withdraw.

```mermaid
flowchart LR
    G["Gifter"] ---|"G-X session, existing"| X["Exporter"]
    G ---|"G-R session, existing"| R["Receiver"]
    R -.->|"R-X session, established to withdraw"| X
```

## HO-2: Happy path overview

This diagram shows the five steps end-to-end; HO-3 through HO-7 zoom into each.

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
    X->>R: op:resolve (resolve:fulfill gifted-ref)
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
suggests the Receiver check that the give's receiver-key names it; pancake
leaves that to the Exporter too, where the receive must be signed by exactly
that key (HO-7), so a mis-addressed give fails at withdraw rather than locally.
What the Receiver does check locally is the exporter-location: an unparseable
locator fails closed with no dial.

```mermaid
flowchart TD
    IN["inbound signed desc:handoff-give"] --> LOC{"exporter-location parseable?"}
    LOC -->|no| REJ["fail closed - no dial"]
    LOC -->|yes| PR["create local promise for the gift"]
    PR --> CONN["connect to the Exporter if no session exists"]
    CONN --> CNT["allocate next handoff-count for the R-X session"]
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
    HR --> HC["handoff-count: unique within the R-X session"]
    HR --> SG["signed-give: the Gifter's certificate, carried whole"]
```

## HO-7: Step 5: Exporter-side validation

The Exporter is the only party that can verify both signatures. It knows the
Gifter's pubkey from the G-X session, and the give itself carries the
receiver-key that must have signed the receive. A failed check refuses the
withdrawal by breaking its answer with a typed reason; the session stays open.

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

The count guard is one monotonic scalar on the live R-X session. The gift table
belongs to the live G-X session. Closing either `Peer` destroys the authority it
owns; no Host- or Vat-wide replay map survives. The current Host does reuse its
session key, however, so a reconnect can recreate the same side and session
names. Until ADR-0097 supplies fresh per-session keys, an old signed receive can
resolve against that replacement session and consume a later same-id deposit.

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
    X->>R: op:resolve (resolve:fulfill gifted-ref)
```
