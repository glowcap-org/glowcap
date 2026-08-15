// The tools coordinator, written on pancake actors in native Deno.
//
// It publishes a `tools` capability. An agent fetches it and asks for the tools a
// task requests; the coordinator hands back capabilities — full, attenuated to
// read-only, or revocable — and the agent calls them. This demo leaves policy
// deliberately simple: a caller may request any tool name the coordinator knows.
// A real harness must restrict that grant surface before exposing it to untrusted
// callers.
//
// Read how the capability trio falls out of ordinary code:
//   - delegation  — `grant` returns `session.spawn(toolBehavior)`, a reference the
//     agent receives and calls. Authority travels as a reference.
//   - attenuation — a read-only view is a function wrapping a function: it
//     forwards `read` and refuses `write`. No special API.
//   - revocation  — a revocable handle is a forwarder with a flag you flip.
//
// Run it with a port:  deno run --allow-ffi --allow-net --allow-read server.ts 9099

import { type Argument, Session } from "@pancake/runtime";
import * as tcp from "@pancake/tcp";
import { GRANT, GRANT_REVOCABLE, NOW, READ, REVOKE_LAST, TOOLS, WRITE } from "./protocol.ts";

/** A tool is a plain behavior function. These are the things the coordinator
 * holds; it never hands the agent the functions, only capabilities to them. */
type Tool = (verb: string, args: Argument[]) => Argument;

/** A clock tool: tells the time, nothing else. */
const clock: Tool = (verb) => {
	if (verb === NOW) return BigInt(Date.now());
	throw new Error(`clock has no method ${verb}`);
};

/** A files tool: read and write. The coordinator holds the full version; agents
 * usually get an attenuated, read-only view of it. */
function makeFiles(): Tool {
	const store = new Map<string, string>([[
		"report.txt",
		"all systems nominal",
	]]);
	return (verb, args) => {
		const path = typeof args[0] === "string" ? args[0] : "";
		if (verb === READ) return store.get(path) ?? `(no such file: ${path})`;
		if (verb === WRITE) {
			store.set(path, typeof args[1] === "string" ? args[1] : "");
			return "ok";
		}
		throw new Error(`files has no method ${verb}`);
	};
}

/** Attenuation. A read-only view is a function wrapping a function: forward the
 * safe verb, refuse the rest. This is the whole of attenuation. */
function readOnly(tool: Tool): Tool {
	return (verb, args) => {
		if (verb === READ) return tool(verb, args);
		throw new Error("attenuated: only read is permitted");
	};
}

/** Revocation, a forwarder you can switch off. Returns the wrapped behavior and
 * the lever that severs it; after `revoke()`, every call breaks. */
function revocable(tool: Tool): { behavior: Tool; revoke: () => void } {
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

function toolFor(name: string): Tool {
	if (name === "clock") return clock;
	if (name === "files") return makeFiles();
	if (name === "files-readonly") return readOnly(makeFiles());
	throw new Error(`unknown tool: ${name}`);
}

/** The coordinator behavior for one connected agent. It closes over that agent's
 * connection (to spawn capabilities on it) and the last revocable grant. */
function coordinatorBehavior(session: Session) {
	let lastRevoke: (() => void) | null = null;
	return (verb: string, args: Argument[]): Argument => {
		if (verb === GRANT) {
			const name = typeof args[0] === "string" ? args[0] : "";
			// Delegation: hand the agent a capability to the requested tool.
			return session.spawn(toolFor(name));
		}
		if (verb === GRANT_REVOCABLE) {
			const name = typeof args[0] === "string" ? args[0] : "";
			const { behavior, revoke } = revocable(toolFor(name));
			lastRevoke = revoke;
			return session.spawn(behavior);
		}
		if (verb === REVOKE_LAST) {
			lastRevoke?.();
			lastRevoke = null;
			return "revoked";
		}
		throw new Error(`coordinator has no method ${verb}`);
	};
}

const port = Number(Deno.args[0] ?? "0");
const server = await tcp.listen("127.0.0.1", port);
console.log(`TOOLS-SERVER-LISTENING ${server.port}`);

for await (const session of server) {
	session.publish(TOOLS, coordinatorBehavior(session));
	session.serve().catch(() => {});
}
