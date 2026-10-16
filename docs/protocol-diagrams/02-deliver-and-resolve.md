---
type: static
description: Diagrams of op:deliver, the bootstrap object, op:get, and how answers resolve.
sources:
  - resource: /src/ocapn/session/answers/
  - resource: /src/ocapn/engine/inbound/
  - resource: /src/ocapn/engine/outbound/
  - resource: /src/ocapn/engine/bootstrap/
---

# Deliver and resolve

These diagrams follow the CapTP Specification sections op:deliver, The
bootstrap Object, op:get, and op:index.

These diagrams use the next profile unless a step says V1.0. Next carries a resolver and integer listen mode in
`op:deliver`. Goblins V1.0 carries the resolver as its fourth operand and has
no inline listen mode. Neither profile sends wire `op:resolve`. The projection
operations below are V1.0 only.

## DR-1: op:deliver with an answer

The questioner allocates a fresh answer position and includes a resolver with
mode 3. The answerer records the answer and subscription, then calls the
resolver once when shortening or settlement occurs.

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:deliver (to-desc, args, answer-pos N, resolver P, mode 3)
    Note over R: answers-owed table records position N
    R->>Q: op:deliver-only (to desc:export P, ['fulfill, value])
```

## DR-2: op:deliver with no answer (one-way)

`op:deliver-only` carries the target and arguments, with no answer or resolver.
The receiver invokes the target and no callback returns.

```mermaid
sequenceDiagram
    participant Q as Sender
    participant R as Receiver
    Q->>R: op:deliver-only (to-desc, args)
    Note over R: target invoked, nothing owed back
```

## DR-3: Settlement with a break

The callback's `fulfill` arm carries a value and its `break` arm carries an
error. A broken answer propagates its error to anything pipelined against it
(see [03-promises-and-pipelining.md](03-promises-and-pipelining.md)).

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:deliver (to-desc, args, answer-pos N, resolver P, mode 3)
    Note over R: invocation raises an error
    R->>Q: op:deliver-only (to desc:export P, ['break, error])
```

## DR-4: V1.0 inline resolver

On Goblins V1.0, the fourth `op:deliver` operand names the resolver object. The
answerer imports it and later delivers `'fulfill` or `'break` to it. V1.0 does
not need a following listen for this answer.

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:deliver (to-desc, args, answer-pos N, resolve-me-desc desc:import-object P)
    Note over R: imports resolver at position P
    R->>Q: op:deliver (to desc:export P, args ['fulfill, value], answer-pos false)
```

## DR-5: Bootstrap fetch

Anchor: CapTP Specification § The bootstrap Object. Export position 0 is always
the bootstrap object. `fetch` with a swiss number is how a peer turns held
out-of-band authority into a live reference.

```mermaid
sequenceDiagram
    participant C as Client
    participant H as Host
    C->>H: op:deliver (to desc:export 0, args ['fetch, swiss-num], answer-pos N, resolver P, mode 3)
    Note over H: bootstrap object looks up the swiss number
    H->>C: op:deliver-only (to desc:export P, ['fulfill, desc:import-object M])
    Note over C: client now imports the fetched object at M
```

## DR-6: V1.0 op:get

`op:get` projects one field out of a receiver's eventual fulfillment into a
fresh promise. It breaks if the fulfillment has no such field, and it inherits
the receiver's rejection if the receiver breaks.

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:get (receiver-desc, field-name, new-answer-pos M)
    Q->>R: op:listen (desc:answer M, desc:import-object P, wants-partial false)
    Note over R: waits for receiver to settle, projects the field
    R->>Q: op:deliver (to desc:export P, ['fulfill, field-value], answer-pos false)
```

## DR-7: V1.0 op:index

`op:index` is the list-shaped sibling of `op:get`: it projects one element by
index. An index out of range breaks the new answer.

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:index (receiver-desc, index, new-answer-pos M)
    Q->>R: op:listen (desc:answer M, desc:import-object P, wants-partial false)
    alt index in range of the fulfillment
        R->>Q: op:deliver (to desc:export P, ['fulfill, element], answer-pos false)
    else out of range or wrong shape
        R->>Q: op:deliver (to desc:export P, ['break, error], answer-pos false)
    end
```
