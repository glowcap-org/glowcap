# A2A on CapTP

Agent2Agent ([A2A](https://github.com/a2aproject/A2A)) gives AI agents a
shared vocabulary for advertising skills and handing each other tasks. This
sketch carries that vocabulary as CapTP objects, so glowcap peers trade agent
tasks with the same capability rules as any other call. None of it is built,
and [ADR-0032](../decisions/adr/ADR-0032-cli-and-product-boundaries.md)
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

## What a Rooms bot already delegates

A [Rooms bot](../rooms/bot.md) attaches to its session through a collaborator
grant. Its agent runs the model and tools. The Rooms session decides which
operations that grant allows. A role brief guides the agent’s replies.
The operator grants access to the member independently of the choice of model.

Before adding another harness, evaluate the [Agent Client Protocol Rust SDK](https://github.com/agentclientprotocol/rust-sdk)
as the local connection to the agent. Test the adapter with a live CapTP session.
An attenuated grant must refuse operations outside its rights. Revocation must
still hold after a reconnect or a resumed model session.

Also verify cancellation, safe-mode tool restrictions, and that an edited role
takes effect on the next turn. Measure startup and turn overhead against the
existing harness. A workflow engine that owns schedules, task graphs or memory
can participate through an ordinary Rooms member with its own grant.
The optional A2A objects below would let peers exchange structured tasks.

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
