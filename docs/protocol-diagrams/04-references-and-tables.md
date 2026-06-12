# References and tables

Anchors: CapTP Specification § Descriptors, § Export and import tables.

## RT-1 — Descriptor taxonomy

Four wire descriptors name positions in session tables. Which table they
index, and on whose side, is the whole game; the next two diagrams, RT-2 and
RT-3, pin it down.

```mermaid
flowchart TD
    D["reference descriptor on the wire"] --> E["desc:export N"]
    D --> IO["desc:import-object N"]
    D --> IP["desc:import-promise N"]
    D --> A["desc:answer N"]
    E --> EN["names a position in the receiver's export table"]
    IO --> ION["object the receiver imports - sender hosts it"]
    IP --> IPN["promise the receiver imports - sender hosts it"]
    A --> AN["pending answer position the sender allocated"]
```

## RT-2 — The perspective flip

Descriptors are written from the *receiver's* point of view. An object the
sender hosts therefore travels as `desc:import-object` — "you will import
this" — and the receiver records a fresh import row pointing back at the
sender. The same position number means opposite things on the two sides.

```mermaid
sequenceDiagram
    participant A as Sender
    participant B as Receiver
    Note over A: my export table holds object at position 9
    A->>B: payload carries desc:import-object 9
    Note over B: import table records position 9, hosted by Sender
    B->>A: later, to-desc desc:export 9 targets that same object
```

## RT-3 — The four tables

Each side keeps exports (objects it hosts), imports (the mirror of the
partner's exports), answers-asked (questions it allocated), and answers-owed
(questions the partner allocated). Each table pairs with its mirror across
the wire.

```mermaid
flowchart LR
    subgraph A["Peer A"]
        AE["exports"]
        AI["imports"]
        AQ["answers asked"]
        AO["answers owed"]
    end
    subgraph B["Peer B"]
        BE["exports"]
        BI["imports"]
        BQ["answers asked"]
        BO["answers owed"]
    end
    AE --- BI
    AI --- BE
    AQ --- BO
    AO --- BQ
```

Position allocation is one-sided: a peer allocates positions only in its own
export table and its own answers-asked table; the mirrors fill in on receipt.

## RT-4 — Import installation on inbound traffic

Every `desc:import-object` / `desc:import-promise` appearing in an inbound
message's payload installs (or increments) an import row before the message
is acted on. This is what makes later `op:gc-exports` accounting sound — see
[05-gc.md](05-gc.md).

```mermaid
flowchart TD
    IN["inbound message decoded"] --> SCAN["scan payload positions for desc:import-*"]
    SCAN --> EX{"import row exists at that position?"}
    EX -->|no| NEW["install row, wire count 1"]
    EX -->|yes| INC["increment wire count"]
    NEW --> ACT["act on the message"]
    INC --> ACT
```
