---
id: ADR-0249
status: accepted
date: 2026-10-15
tags: [actors, driver, engine, memory, performance]
decision: "A served Host reply carrying no capability stays a view through interception and is copied into the answer store at the engine boundary. Near replies keep their model representation, and capability-bearing replies keep transactional lowering."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0249 Served replies stay views until retained

## Context

A Host handler returns application values borrowed from its turn. Lowering
built temporary model containers for the actor layer, then the engine
copied those containers and their leaves into the answer store. A reply
with no capability needed no session projection between those copies.

The answer store outlives the handler and the incoming frame. Later
listeners and pipelined operations can read it, so its copy must remain.

## Decision

A handler result distinguishes model containers from views. Both borrow the
active turn. The behavior adapter selects its handler's return contract at
compile time. A Host handler lends a served reply as views when it carries
no capability, and lowers other replies through the existing transaction.

Interceptors receive and return views inside the active turn. The engine
copies an intercepted resolution directly into the answer store's owned
representation. The source actor and frame remain live until that copy
finishes. A queued answer retains no pointer into either source.

Near calls still return model arguments. A handler that explicitly returns
views to a near caller has them materialized into the turn arena before
replacement or turn commit. That materialization also severs any borrow
from the actor's state, so replacement needs no second copy.

## Consequences

- Host reply containers are projected once at the retained copy, instead of
  being built in the turn arena first.
- Capability-bearing replies still pass through transactional lowering and
  the Host's routing interceptor.
- Interceptor callbacks now use `model.view.Argument`.
- `test/actors/vat/borrowed_reply_test.zig` covers near materialization,
  actor replacement, interceptor reentry, frame retirement, retained
  answers, and allocation failure cleanup.
