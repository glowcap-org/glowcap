# Tools

This demo hands an AI agent its tools as capabilities. The coordinator grants
a tool, wraps one as read-only, and switches a grant off.

```sh
zig build demo-tools
```

Deno runs the coordinator and one agent. The Zig agent always joins. Python,
Racket, and Rust agents join when their runtimes are available. Common port and
attach options are in the [app index](../README.md#how-the-cross-language-demos-run).

## Delegation

The coordinator creates a tool object and returns a reference to it:

```typescript
if (verb === GRANT) return session.spawn(toolFor(name));
```

The agent calls that reference directly:

```typescript
const clock = await session.send(tools, "grant", ["clock"]);
const now = await session.send(clock, "now");
```

The agent calls the returned clock with no URL, token, or second lookup. The
coordinator decides what to hand out when it answers `grant("clock")`.

## Attenuation

To grant less access, wrap a capability and expose only the safe operations:

```typescript
function readOnly(tool) {
	return (verb, args) => {
		if (verb === "read") return tool(verb, args);
		throw new Error("attenuated: only read is permitted");
	};
}
```

The wrapper can read the in-memory file store but cannot write to it.

## Revocation

A revocable capability is a forwarding object with a switch:

```typescript
function revocable(tool) {
	let live = true;
	return {
		behavior: (verb, args) => {
			if (!live) throw new Error("revoked");
			return tool(verb, args);
		},
		revoke: () => {
			live = false;
		},
	};
}
```

After the coordinator calls `revoke`, later calls through that reference break.

glowcap also provides these common wrappers as
`session.attenuate(capability, methods)` and `session.caretaker(capability)`.
This demo uses small hand-written versions so their behavior is visible.

## Limits of the demo

The published coordinator accepts a tool name and grants any tool it knows,
including the full read/write file tool. It shows how a tool is handed out,
narrowed, and revoked once the coordinator decides to grant it. It has no policy
engine and is not a complete harness for confining an agent.

A real harness must decide which grants a task may request, keep unapproved
tools unreachable, and treat model output as untrusted. Capabilities then
enforce what it decided.

The coordinator and Deno agent live under [`deno/`](deno/). The Python, Racket,
Rust, and Zig directories contain agents that exercise the same three patterns.
[`demo.ts`](demo.ts) coordinates the run.
