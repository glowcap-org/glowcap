---
id: ADR-0005
status: accepted
date: 2026-10-19
tags: ["model", "codec", "syrup-wire", "goblins-interop", "value-tree", "syrup", "capnp", "conformance"]
decision: "The shared model represents the supported OCapN passable value tree."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0005 Passable value model

## Context

A supported wire value needs a representation that survives transport and codec changes without changing its meaning.

## Decision

The shared model represents the supported OCapN passable value tree. Codecs refuse values they cannot represent rather than dropping, coercing or truncating them.

Integers use an `i64` fast path and a canonical signed arbitrary-precision representation outside that range. Protocol positions, indexes and wire deltas retain their bounded protocol types.

Structs contain string-keyed entries. Decoding refuses duplicate keys, encoding orders keys canonically, and structural equality ignores entry order. Undefined uses the existing void representation. No distinct Null meaning is invented for an unsettled upstream encoding.

## Alternatives and consequences

A codec-specific model would make equality and application behavior depend on serialization. General value keys would admit dictionaries outside the Struct contract. Parallel key/value arrays would complicate the borrowed single-cursor representation.

Owning values and borrowed views describe the same semantic tree. A compact integer run is a list backing, not a second application-level meaning.

## Evidence

`zig build test` and `zig build oracle-check` cover canonical values, malformed encodings, equality and cross-codec behavior. The [protocol architecture](../../architecture.md) identifies the model and codec owners.
