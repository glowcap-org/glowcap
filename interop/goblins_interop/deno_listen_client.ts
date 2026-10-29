// Deno row of the live Goblins listener matrix. The shared harness supplies
// the outside peer; this process owns one TCP listener and one accepted session.

import type { Argument } from "@glowcap/runtime";
import * as tcp from "@glowcap/tcp";

const ACTOR_SWISS = "glowcapActorSwissnumABCDEFGH1234";

function greeter(_verb: string | null, args: Argument[]): string {
	const value = args[0];
	const who = value instanceof Uint8Array ? new TextDecoder().decode(value) : String(value ?? "stranger");
	return `Hello from a binding host: ${who}`;
}

await using server = await tcp.listen("127.0.0.1", 0);
server.host.publish(ACTOR_SWISS, greeter);
console.log(`GOBLINS-LISTENER-READY ${server.port}`);

for await (const accepted of server) {
	await using session = accepted;
	await session.serve();
	break;
}
