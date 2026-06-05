# Promises and pipelining

Anchors: CapTP Specification § Promises, § Promise pipelining, § op:listen.
The `wants-partial?` operand is `[goblins-canonical]`.

## PP-1 — Promise lifecycle

A promise settles exactly once into Fulfilled or Broken. Fulfilling with
*another promise* is a partial step — the promise stays pending against the
new target until a non-promise value or an error arrives.

```mermaid
stateDiagram-v2
    [*] --> Pending
    Pending --> Pending: fulfill with another promise (partial step)
    Pending --> Fulfilled: fulfill with a settled value
    Pending --> Broken: break with an error
    Fulfilled --> [*]
    Broken --> [*]
```

## PP-2 — Pipelined deliver on an answer

A questioner may target `desc:answer N` before N has resolved. The answerer
queues the pipelined call against the pending answer and runs it on
settlement — saving the round-trip.

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:deliver (to desc:export 5, args, answer-pos 3)
    Q->>R: op:deliver (to desc:answer 3, args, answer-pos 4)
    Note over R: second call queues against pending answer 3
    R->>Q: op:resolve (3, resolve:fulfill ref)
    Note over R: queued call runs against the fulfillment
    R->>Q: op:resolve (4, resolve:fulfill result)
```

## PP-3 — Multi-hop chain

`a.lookup(x).getCalendar().eventsToday()` is three hops, each anchored on the
previous answer position. On the wire each hop is its own `op:deliver`
against `desc:answer`; encodings with richer path types may carry the chain
in fewer frames, but the semantics are this chain.

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:deliver (to desc:import-object 1, ['lookup, x], answer-pos 3)
    Q->>R: op:deliver (to desc:answer 3, ['getCalendar], answer-pos 4)
    Q->>R: op:deliver (to desc:answer 4, ['eventsToday], answer-pos 5)
    Note over R: each hop queues against the previous answer
    R->>Q: op:resolve (5, resolve:fulfill events)
```

## PP-4 — Deliver to an already-resolved answer

If the answer has settled by the time a pipelined deliver targeting it
arrives, the call forwards to the resolution: invoked on the fulfillment
value, or broken immediately with the inherited error.

```mermaid
flowchart TD
    IN["op:deliver to desc:answer N arrives"] --> ST{"answer N already settled?"}
    ST -->|no| QU["queue against pending answer"]
    ST -->|"fulfilled with ref"| FW["invoke on the fulfillment"]
    ST -->|"broken"| BR["break the new answer with the inherited error"]
```

## PP-5 — op:listen, fire on settlement

The listener is an object the questioner exports. When the target settles,
the answerer delivers the resolution to the listener as an ordinary call.
With `wants-partial?` false (spec-strict), it fires exactly once, on the
eventually-settled non-promise resolution.

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:listen (desc:answer 7, desc:import-object 9, wants-partial false)
    Note over R: listener installed on answer 7
    Note over R: answer 7 settles
    R->>Q: op:deliver-only (to desc:import-object 9, ['fulfill, value])
```

## PP-6 — op:listen with wants-partial `[goblins-canonical]`

With `wants-partial?` true, the listener also fires on each intermediate
promise-shaped fulfillment, re-installing on the next link until a settled
value arrives.

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:listen (desc:answer 7, desc:import-object 9, wants-partial true)
    Note over R: answer 7 fulfills with another promise
    R->>Q: op:deliver-only (to desc:import-object 9, ['fulfill, partial-promise])
    Note over R: listener re-installs on the new promise
    Note over R: chain bottoms out in a settled value
    R->>Q: op:deliver-only (to desc:import-object 9, ['fulfill, value])
```

## PP-7 — op:listen on an already-settled target

Listening on a target that is already settled — e.g. a live local export —
fires the listener immediately with that resolution. Nothing waits.

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:listen (desc:export 5, desc:import-object 9, wants-partial false)
    Note over R: export 5 is live, nothing pending
    R->>Q: op:deliver-only (to desc:import-object 9, ['fulfill, desc:import-object 5])
```
