# Tools

This demo passes tools to an agent as capabilities. It shows three useful
patterns: granting a tool, wrapping it as read-only, and switching a grant off.

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

Authority travels with the reference. The agent does not need a URL, token, or
second lookup when it calls the returned clock. The coordinator's named
`grant("clock")` request is the policy lookup in this demo.

## Attenuation

To grant less authority, wrap a capability and expose only the safe operations:

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
No global permission table is involved.

glowcap also provides these common wrappers as
`session.attenuate(capability, methods)` and `session.caretaker(capability)`.
This demo uses small hand-written versions so their behavior is visible.

## Limits of the demo

The published coordinator accepts a tool name and grants any tool it knows,
including the full read/write file tool. It shows how authority can be
delegated, narrowed, and revoked after a grant decision. A policy engine and a
complete least-authority agent harness are separate work.

A real harness must decide which grants a task may request, keep unapproved
tools unreachable, and treat model output as untrusted. Capabilities make those
boundaries concrete, but do not choose the policy or make the surrounding
system safe.

The coordinator and Deno agent live under [`deno/`](deno/). The Python, Racket,
Rust, and Zig directories contain agents that exercise the same three patterns.
[`demo.ts`](demo.ts) coordinates the run.
