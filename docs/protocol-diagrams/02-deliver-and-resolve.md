# Deliver and resolve

Anchors: CapTP Specification § op:deliver, § The bootstrap Object, § op:get, §
op:index.

One vocabulary note before the diagrams. The draft CapTP specification has no
`op:resolve` section. The OCapN working group has agreed to adopt two settlement
operators, `op:resolve` and `op:break` (see the 2026-02-10 minutes in
`conformance/ocapn-spec/`). The wire encoding is still unsettled, so pancake
folds both into one `op:resolve` with fulfill and break arms. That
`pancake-next` profile shape is what every `op:resolve` arrow in these diagrams
draws. On the v1.0 wire that Goblins speaks, settlement instead travels as the
resolver-callback deliver in DR-4.

## DR-1: op:deliver with an answer

The questioner allocates a fresh answer position; the answerer records it and
later settles it with exactly one `op:resolve`.

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:deliver (to-desc, args, answer-pos N, resolve-me-desc false)
    Note over R: answers-owed table records position N
    R->>Q: op:resolve (N, resolve:fulfill value)
```

## DR-2: op:deliver with no answer (one-way)

Fire-and-forget: the answer position is `false`, so no `op:resolve` returns.
The receiver invokes the target and the transaction ends.

```mermaid
sequenceDiagram
    participant Q as Sender
    participant R as Receiver
    Q->>R: op:deliver (to-desc, args, answer-pos false)
    Note over R: target invoked, nothing owed back
```

## DR-3: op:resolve with a break

Settlement has two shapes: `resolve:fulfill` carries a value, `resolve:break`
carries an error. A broken answer propagates its error to anything pipelined
against it (see [03-promises-and-pipelining.md](03-promises-and-pipelining.md)).

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:deliver (to-desc, args, answer-pos N)
    Note over R: invocation raises an error
    R->>Q: op:resolve (N, resolve:break error)
```

## DR-4: resolve-me-desc resolver callback

The fourth `op:deliver` operand may name a resolver object the questioner
exports. The answerer imports it and later _delivers the resolution to it_ as an
ordinary call carrying `'fulfill` or `'break`, instead of (or alongside) the
`op:resolve` path.

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
    C->>H: op:deliver (to desc:export 0, args ['fetch, swiss-num], answer-pos N)
    Note over H: bootstrap object looks up the swiss number
    H->>C: op:resolve (N, resolve:fulfill desc:import-object M)
    Note over C: client now imports the fetched object at M
```

## DR-6: op:get

`op:get` projects one field out of a receiver's eventual fulfillment into a
fresh promise. It breaks if the fulfillment has no such field, and it inherits
the receiver's rejection if the receiver breaks.

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:get (receiver-desc, field-name, new-answer-pos M)
    Note over R: waits for receiver to settle, projects the field
    R->>Q: op:resolve (M, resolve:fulfill field-value)
```

## DR-7: op:index

`op:index` is the list-shaped sibling of `op:get`: it projects one element by
index. An index out of range breaks the new answer.

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:index (receiver-desc, index, new-answer-pos M)
    alt index in range of the fulfillment
        R->>Q: op:resolve (M, resolve:fulfill element)
    else out of range or wrong shape
        R->>Q: op:resolve (M, resolve:break error)
    end
```
