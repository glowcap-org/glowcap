# tools — least authority for AI agent harnesses, in code

This is the capability showcase: the concrete answer to "what is pancake actually
good for beyond chat?" A coordinator holds tools; an agent connects and is handed
exactly the authority a task needs — attenuated to read-only where appropriate,
revocable when the task is done. The agent can call what it was given and nothing
else, because there is no ambient authority to escalate to.

This is the authority model AI agent harnesses are currently reinventing with API
keys, allowlists, and middleware. In pancake it is one `spawn` away.

Run it:

```sh
zig build tools
```

That starts a Deno coordinator and runs one agent per available language against
it — Deno and the always-built Zig agent, plus Python, Racket, and Rust when their
runtimes are on PATH. The coordinator and the agent are different languages on the
wire, so the capability passing, attenuation, and revocation are real — not
in-process tricks. Each agent prints `ok` for every property and exits non-zero if
any fails.

## The three properties, and why they are ordinary code

The whole argument for capability networking is that the hard authority patterns
fall out of `spawn` + `send` + passing a reference. No special API.

### Delegation — authority travels as a reference

The coordinator hands the agent a capability to a tool by returning a spawned
actor from `grant`:

```typescript
// coordinator
if (verb === GRANT) return conn.spawn(toolFor(name));
```

```typescript
// agent
const clock = await conn.send(tools, "grant", ["clock"]);
const now = await conn.send(clock, "now"); // it just works — clock is a capability
```

The agent received a reference it can call. It did not receive a URL, a token, or
a name to look up in a registry. The reference *is* the authority.

### Attenuation — a read-only view is a function wrapping a function

```typescript
function readOnly(tool) {
  return (verb, args) => {
    if (verb === "read") return tool(verb, args);
    throw new Error("attenuated: only read is permitted");
  };
}
```

The agent gets `grant("files-readonly")`, reads successfully, and its write breaks.
There is no "permission" field anywhere — the attenuated capability simply cannot
express a write.

### Revocation — a forwarder you can switch off

```typescript
function revocable(tool) {
  let live = true;
  return {
    behavior: (verb, args) => { if (!live) throw new Error("revoked"); return tool(verb, args); },
    revoke: () => { live = false; },
  };
}
```

The agent calls the revocable handle successfully, the coordinator revokes it, and
every subsequent call breaks — with no change to the agent and no global registry
of who-can-do-what.

### Least authority, by construction

The fourth property is the one you cannot show with a positive assertion: the
agent can reach *exactly* the capabilities it was granted. There is no ambient
authority — no global namespace, no "list all tools" it can call, no way to forge
a reference. A tool it was never handed is unreachable, not merely forbidden. That
is the property that makes a capability harness safe to point an LLM at.

## Why this matters for AI

An agent harness needs to give a model tools without giving it the keys to the
house. Today that means API keys (coarse, leaky, hard to revoke), allowlists
(ambient, easy to get wrong), and middleware (a separate layer to maintain). With
capabilities:

- The agent holds references, not credentials. It cannot escalate to authority it
  was not handed.
- Attenuation is composition: wrap a capability to narrow it.
- Revocation is a lever you hold: sever a capability the moment a task ends or an
  agent misbehaves.

The same `connect` / `fetch` / `spawn` / `send` surface that makes the chat demo
trivial makes this safe-by-construction harness trivial too.

## Layout

```
examples/apps/tools/
├── deno/protocol.ts   the wire contract: the coordinator name and tool verbs
├── deno/server.ts     the coordinator: grants full/attenuated/revocable tools
├── deno/agent.ts      a Deno agent proving the three properties
├── python/agent.py    the same agent, in Python, over the same wire
├── racket/agent.rkt   the same agent, in Racket
├── rust/agent.rs      the same agent, in Rust (its own crate)
├── zig/agent.zig      the same agent, in native Zig, on the connection driver
└── demo.ts            the orchestrator `zig build tools` runs
```
