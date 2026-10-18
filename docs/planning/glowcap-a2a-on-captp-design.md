# A2A on CapTP

Agent2Agent ([A2A](https://github.com/a2aproject/A2A)) gives AI agents a
shared vocabulary for advertising skills and handing each other tasks. This
sketch carries that vocabulary as CapTP objects, so glowcap peers trade agent
tasks with the same capability rules as any other call. None of it is built,
and [ADR-0084](../decisions/adr/ADR-0084-glowcap-cli-product-boundary.md)
deferred it until the maintainer decides to take it up.

## Layers

| Layer | Job |
| --- | --- |
| CapTP and OCapN | Capability-secure messaging between peers, glowcap or Goblins |
| A2A on CapTP | Agent Card, Task, Skill, and artifact as CapTP objects |
| HTTP facade (optional) | Wire A2A (Agent Cards, JSON-RPC over HTTP) for agents outside CapTP |

CapTP already carries messages between agents. This work adds the shape of
cards, skills, and tasks on top, and an optional facade for agents that speak
A2A over HTTP.

## The CapTP shape

- An Agent Card is a capability a peer can fetch by name or restore from a
  sturdyref.
- A task is an actor called through ordinary CapTP messages. A skill is a set
  of allowed methods, handed out by attenuating the agent.
- An artifact is a settled value or a sturdyref.
- glowcap peers find each other through CapTP (`fetch`, sturdyrefs, and
  introductions) instead of an HTTP `/.well-known` path.

## The HTTP facade

The facade speaks wire A2A over HTTP and JSON-RPC and maps each request onto
the CapTP objects. It lives in an adapter, so the protocol core stays free of
I/O, and `arch-check` keeps it out of the core modules.

## Reference

- CLI: a `glowcap apps a2a` command group, separate from the CapTP commands and
  from `glowcap apps rooms session`.
