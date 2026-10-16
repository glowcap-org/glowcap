---
type: static
description: Diagrams of the promise lifecycle, pipelining, and op:listen.
sources:
  - resource: /src/ocapn/session/promises/
  - resource: /src/ocapn/engine/pipeline.zig
  - resource: /src/ocapn/engine/pipeline_listeners.zig
  - resource: /src/ocapn/engine/pipeline_resolution.zig
---

# Promises and pipelining

These diagrams follow the CapTP Specification sections Promises, Promise
pipelining, and op:listen. They use next's integer listen modes. Goblins V1.0
translates its Boolean `wants-partial?` at the codec boundary.

## PP-1: Promise lifecycle

A promise settles once, into Fulfilled or Broken. Fulfilling with
_another promise_ is a partial step: the promise stays pending against the new
target until a non-promise value or an error arrives.

```mermaid
stateDiagram-v2
    [*] --> Pending
    Pending --> Pending: fulfill with another promise (partial step)
    Pending --> Fulfilled: fulfill with a settled value
    Pending --> Broken: break with an error
    Fulfilled --> [*]
    Broken --> [*]
```

## PP-2: Pipelined deliver on an answer

A questioner may target `desc:answer N` before N has resolved. The answerer
queues the pipelined call against the pending answer and runs it on settlement,
saving the round-trip. On next, a call carries its resolver and listen mode
inline. Mode 1 requests shortening, and mode 3 requests shortening or settlement.
The optional answer position enables pipelining independently of the resolver.

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:deliver (to desc:export 5, args, answer-pos 3, resolver 8, mode 3)
    Q->>R: op:deliver (to desc:answer 3, args, answer-pos 4, resolver 9, mode 3)
    Note over R: second call queues against pending answer 3
    R->>Q: op:deliver-only (to desc:export 8, ['fulfill, far-promise])
    Note over R: queued call runs against the fulfillment
    R->>Q: op:deliver-only (to desc:export 9, ['fulfill, result])
```

## PP-3: Multi-hop chain

`a.lookup(x).getCalendar().eventsToday()` is three hops, each anchored on the
previous answer position. On the wire each hop is its own `op:deliver` against
`desc:answer`. An encoding with richer path types may carry the chain in fewer
frames, but the semantics stay this chain.

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:deliver (to desc:export 1, ['lookup, x], answer-pos 3, resolver 8, mode 3)
    Q->>R: op:deliver (to desc:answer 3, ['getCalendar], answer-pos 4, resolver 9, mode 3)
    Q->>R: op:deliver (to desc:answer 4, ['eventsToday], answer-pos 5, resolver 10, mode 3)
    Note over R: each hop queues against the previous answer
    R->>Q: op:deliver-only (to listener 10, ['fulfill, events])
```

## PP-4: Deliver to an already-resolved answer

If the answer has settled by the time a pipelined deliver targeting it arrives,
the call forwards to the resolution: invoked on the fulfillment value, or broken
immediately with the inherited error. Another same-peer promise re-anchors the
call on its exact backing answer, including when that promise is a local
export paired with a virtual answer.

```mermaid
flowchart TD
    IN["op:deliver to desc:answer N arrives"] --> ST{"answer N already settled?"}
    ST -->|no| QU["queue against pending answer"]
    ST -->|"fulfilled with ref"| FW["invoke on the fulfillment"]
    ST -->|"broken"| BR["break the new answer with the inherited error"]
```

## PP-5: Settling listener

Mode 2 follows a shortening subscription and asks only for settlement. The answerer delivers the resolution to the
listener as an ordinary call. A same-peer promise fulfillment re-anchors the
listener without firing it.

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:listen (desc:answer 7, desc:import-object 9, mode 2)
    Note over R: listener installed on answer 7
    Note over R: answer 7 settles
    R->>Q: op:deliver-only (to desc:export 9, ['fulfill, value])
```

## PP-6: Shortening listener

Mode 1 asks only for shortening. A far-promise fulfillment fires the listener
once. The receiving peer installs a new mode-1 listener on the returned promise.

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:listen (desc:answer 7, desc:import-object 9, mode 1)
    Note over R: answer 7 fulfills with a far promise
    R->>Q: op:deliver-only (to desc:export 9, ['fulfill, partial-promise])
    Q->>R: op:listen (partial-promise, desc:import-object 10, mode 1)
```

## PP-7: op:listen on an already-settled target

A settling listener on an already-settled target fires immediately with that
resolution. Shapes:

- an already-settled **answer** (suite `test_op_listen_already_has_answer`)
- a live **object export** (fulfill of that export)

A **local promise export** uses its explicit pairing with a backing answer.
Listeners follow that answer through same-peer promise chains. A bare
unresolved export without the pairing refuses with `InvalidReference`, because
no settlement authority could discharge its subscription.

```mermaid
sequenceDiagram
    participant Q as Questioner
    participant R as Answerer
    Q->>R: op:listen (desc:export 5, desc:import-object 9, mode 2)
    Note over Q,R: a prior mode-1 subscription already concluded
    Note over R: export 5 is a live object, nothing pending
    R->>Q: op:deliver-only (to desc:export 9, ['fulfill, desc:import-object 5])
```
