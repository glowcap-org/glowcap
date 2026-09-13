// The tools coordinator, written on glowcap actors in native Deno.
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
// Run it with a port:  deno run --allow-ffi --allow-net --allow-read coordinator.ts 9099

import { type Argument, Session } from "@glowcap/runtime";
import * as tcp from "@glowcap/tcp";
import { GRANT, GRANT_REVOCABLE, REVOKE_LAST, TOOLS } from "./protocol.ts";
import { revocable, toolFor } from "./capabilities.ts";

/** A tool is a plain behavior function. These are the things the coordinator
 * holds; it never hands the agent the functions, only capabilities to them. */
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
	// A partner's transport fault ends only that partner's service; the
	// coordinator keeps accepting, and says which session went down.
	session.serve().catch((error: unknown) => {
		console.error(
			`tools coordinator: a session ended with a fault: ${error instanceof Error ? error.message : error}`,
		);
	});
}
