# A2A on CapTP (Spec D)

This is a design sketch for Agent2Agent
([A2A](https://github.com/a2aproject/A2A)) as an application vocabulary on
CapTP. Nothing here is built.
[ADR-0084](../decisions/adr/ADR-0084-glowcap-cli-product-boundary.md) deferred
it. The roadmap item owns this sketch, and its plan starts from the object
shapes below.

## Boundary

| Layer | Job |
|-------|-----|
| CapTP / OCapN | Capability substrate (glowcap mesh, Goblins) |
| A2A-on-CapTP | Agent Card, Task, Skill, and artifact as CapTP objects |
| A2A-HTTP facade (optional) | Wire Agent2Agent (Agent Cards, JSON-RPC over HTTP) for foreign agents |

A2A does not replace CapTP, which already carries capability-secure
agent-to-agent messaging. Spec D adds the task, skill, and card application shape for glowcap
peers, plus an optional HTTP facade for the public A2A ecosystem.

## CLI surface (when built)

```
glowcap app a2a …
```

Not a CapTP root noun. Not a synonym for `apps rooms session` (the CapTP presence harness).

## Primary shape

- Publish an Agent Card as a CapTP capability (fetchable or sturdy).
- Task actors with CapTP verbs. Skills as method allow-lists or attenuation.
- Artifacts as settled values or sturdyrefs.
- Discovery among glowcap peers uses CapTP (`fetch`, sturdy, handoff), not
  `/.well-known` HTTP.

## Secondary shape (optional facade)

HTTP and JSON-RPC (gRPC only if it is needed) that speak wire A2A and map onto
the CapTP objects. That gives ecosystem interop without making HTTP the
substrate. I/O stays in adapters. `arch-check` keeps it out of `core = true`.

## Present boundary

A-v1 ships without `app a2a`. Do not describe the facade as if it runs.
