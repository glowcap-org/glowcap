# Three-party handoffs

Anchors: CapTP Specification § Third-party handoffs (depositing the gift,
desc:handoff-give, desc:handoff-receive, withdrawing the gift, validation). All
certificates ride `desc:sig-envelope` (Ed25519 over the canonical bytes of the
inner certificate). The `op:resolve` settlement arrows below draw pancake's
PreSpec shape; on the v1.0 wire the same settlement is the resolver-callback
deliver (see the vocabulary note and DR-4 in
[02-deliver-and-resolve.md](02-deliver-and-resolve.md)).

## HO-1: Roles and sessions

Three peers hold three sessions between them. The Gifter already talks to both
other parties; the Receiver↔Exporter session is established (if absent) to
withdraw.

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
    Note over R: 3. validate recipient-key, dial Exporter
    R->>X: 4. withdraw-gift (signed desc:handoff-receive) on R-X
    Note over X: 5. verify both signatures, check handoff-count
    X->>R: op:resolve (resolve:fulfill gifted-ref)
```

## HO-3: Step 1: deposit-gift

Step 1 is an ordinary bootstrap-object call on the Gifter↔Exporter session. The
Exporter stores the gift keyed by gift-id until a matching withdrawal.

```mermaid
sequenceDiagram
    participant G as Gifter
    participant X as Exporter
    G->>X: op:deliver (to desc:export 0, ['deposit-gift, gift-id, gifted-ref])
    Note over X: deposited-gifts table records (gift-id, gifted-ref)
```

## HO-4: The desc:handoff-give certificate

The give carries five fields, signed by the Gifter with its key from the **G↔X**
session. Each field exists so a specific later check can hold, as HO-5 and HO-7
show.

```mermaid
flowchart TD
    SIG["desc:sig-envelope - Gifter signs with its G-X session key"] --> HG["desc:handoff-give"]
    HG --> RK["recipient-key: Receiver's pubkey in the G-R session"]
    HG --> EL["exporter-location: how the Receiver reaches the Exporter"]
    HG --> GXS["session: the G-X session id the gift was deposited through"]
    HG --> GS["gifter-side: Gifter's identity in the G-X session"]
    HG --> GID["gift-id: matches the deposit"]
```

## HO-5: Step 3: Receiver-side validation

The Receiver cannot verify the Gifter's signature yet, because it has never seen
the Gifter's G↔X pubkey; that check belongs to the Exporter. What the Receiver
_can_ check is that the give was addressed to it.

```mermaid
flowchart TD
    IN["inbound signed desc:handoff-give"] --> CK{"recipient-key equals my G-R pubkey?"}
    CK -->|no| REJ["reject the handoff"]
    CK -->|yes| PR["create local promise for the gift"]
    PR --> CONN["connect to exporter-location if no session exists"]
    CONN --> CNT["allocate next handoff-count for the R-X session"]
    CNT --> HR["build desc:handoff-receive, sign with my G-R key"]
    HR --> WD["send withdraw-gift to the Exporter's bootstrap object"]
```

## HO-6: The desc:handoff-receive certificate

The receive carries four fields wrapping the original signed give. The Receiver
signs it with its key from the **G↔R** session, not the R↔X session, and that is
what binds the new R↔X identity to the identity the Gifter addressed.

```mermaid
flowchart TD
    SIG["desc:sig-envelope - Receiver signs with its G-R session key"] --> HR["desc:handoff-receive"]
    HR --> RS["receiving-session: the R-X session id"]
    HR --> RSide["receiving-side: Receiver's identity in the R-X session"]
    HR --> HC["handoff-count: unique within the R-X session"]
    HR --> SG["signed-give: the Gifter's certificate, carried whole"]
```

## HO-7: Step 5: Exporter-side validation

The Exporter is the only party that can verify both signatures: it knows the
Gifter's pubkey from the G↔X session, and the give itself carries the
recipient-key that must have signed the receive. A repeated handoff-count is a
replay and aborts the session.

```mermaid
flowchart TD
    IN["inbound withdraw-gift"] --> S1{"give signature valid against Gifter's G-X pubkey?"}
    S1 -->|no| AB["abort"]
    S1 -->|yes| S2{"receive signature valid against recipient-key from the give?"}
    S2 -->|no| AB
    S2 -->|yes| S3{"handoff-count above the last accepted for this receiving session?"}
    S3 -->|no| AB2["abort - replay"]
    S3 -->|yes| TK["take deposited gift by gift-id"]
    TK --> RES["resolve the withdraw answer with the gifted reference"]
```

The count guard is monotonic per receiving-session identity (the R↔X session the
receive names). It lives in the vat-scoped gift registry rather than in any one
CapTP session, so a host that keeps that registry across reconnects refuses a
replayed count.

## HO-8: Withdraw before deposit

The two inbound legs race: the Receiver's withdrawal can reach the Exporter
before the Gifter's deposit does. The Exporter parks a validated withdrawal
until the matching gift-id lands, then dispatches.

```mermaid
sequenceDiagram
    participant R as Receiver
    participant X as Exporter
    participant G as Gifter
    R->>X: withdraw-gift (gift-id 7), arrives first
    Note over X: signatures valid, but gift-id 7 not yet deposited
    Note over X: withdrawal parked
    G->>X: deposit-gift (gift-id 7, gifted-ref)
    Note over X: matching deposit lands
    X->>R: op:resolve (resolve:fulfill gifted-ref)
```
