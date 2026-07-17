# A2A on CapTP (Spec D)

Status: active plan

Deferred product design for Agent2Agent ([A2A](https://github.com/a2aproject/A2A))
as an application vocabulary on CapTP. Not implemented. Companion:
[ADR-0084](../decisions/adr/ADR-0084-pancake-cli-product-boundary.md)
(product CLI boundary; Spec D is deferred from A-v1).

## Boundary

| Layer | Job |
|-------|-----|
| CapTP / OCapN | Capability substrate (pancake native mesh, Goblins) |
| A2A-on-CapTP | Agent Card, Task, Skill, and artifact as CapTP objects |
| A2A-HTTP facade (optional) | Wire Agent2Agent (Agent Cards, JSON-RPC over HTTP) for foreign agents |

A2A does not replace CapTP. CapTP already does capability-secure agent-to-agent
messaging. Spec D adds the task, skill, and card application shape for pancake
peers, plus an optional HTTP facade for the public A2A ecosystem.

## CLI surface (when built)

```
pancake app a2a …
```

Not a CapTP root noun. Not a synonym for `app rooms-peer` (the CapTP presence harness).

## Primary shape

- Publish an Agent Card as a CapTP capability (fetchable or sturdy).
- Task actors with CapTP verbs; skills as method allow-lists or attenuation.
- Artifacts as settled values or sturdyrefs.
- Discovery among pancake peers uses CapTP (`fetch`, sturdy, handoff), not
  `/.well-known` HTTP.

## Secondary shape (optional facade)

HTTP and JSON-RPC (gRPC only if it earns rent) that speak wire A2A and map onto
the CapTP-native objects. That gives ecosystem interop without making HTTP the
substrate. I/O stays in adapters; `arch-check` keeps it out of `core = true`.

## Present boundary

Spec D is not implemented. A-v1 ships without `app a2a`. Do not narrate an
unbuilt facade as if it runs.
