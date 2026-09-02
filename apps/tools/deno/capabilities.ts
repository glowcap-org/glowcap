// The capability primitives the tools showcase is about, apart from the socket
// that serves them.
//
// Delegation, attenuation, and revocation are the whole point of this demo, and
// they are pure `Tool -> Tool` transforms with nothing of the wire in them. They
// live here, away from `coordinator.ts`'s server loop, so the properties the
// agent proves over a live session can also be held by an in-process test that
// needs no socket. Delegation stays a wire property — it is handing a spawned
// reference across a session — so `capabilities_test.ts` covers attenuation and
// revocation here, and the cross-language demo proves delegation end to end.

import type { Argument } from "@glowcap/runtime";
import { NOW, READ, WRITE } from "./protocol.ts";

export type Tool = (verb: string, args: Argument[]) => Argument;

/** A clock tool: tells the time, nothing else. */
export const clock: Tool = (verb) => {
	if (verb === NOW) return BigInt(Date.now());
	throw new Error(`clock has no method ${verb}`);
};

/** A files tool: read and write. The coordinator holds the full version; agents
 * usually get an attenuated, read-only view of it. */
export function makeFiles(): Tool {
	const store = new Map<string, string>([["report.txt", "all systems nominal"]]);
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
export function readOnly(tool: Tool): Tool {
	return (verb, args) => {
		if (verb === READ) return tool(verb, args);
		throw new Error("attenuated: only read is permitted");
	};
}

/** Revocation, a forwarder you can switch off. Returns the wrapped behavior and
 * the lever that severs it; after `revoke()`, every call breaks. */
export function revocable(tool: Tool): { behavior: Tool; revoke: () => void } {
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

export function toolFor(name: string): Tool {
	if (name === "clock") return clock;
	if (name === "files") return makeFiles();
	if (name === "files-readonly") return readOnly(makeFiles());
	throw new Error(`unknown tool: ${name}`);
}
