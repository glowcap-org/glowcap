// Live interop proof: the Deno binding listens, publishes a greeter actor, and a
// real Goblins vat dials in over TCP through the C ABI Host/listen surface.
//
// Needs `deno` + `racket` + the `goblins` collection on PATH; runs as
// `zig build deno-goblins-listen`.

import { listen, type Session } from "@pancake/stack";
import { fail } from "../_common/deno/helpers.ts";

const HOST = "127.0.0.1";
const RACKET = "/usr/local/bin/racket";
const DIALER_SCRIPT = "conformance/goblins-peer/racket/pancake-actor-call.rkt";
// Same swiss-num the other listener scenarios register on the pancake side.
const ACTOR_SWISS = "pancakeActorSwissnumABCDEFGH1234";

function greeter(_verb: string, args: unknown[]): string {
	const name = args[0] instanceof Uint8Array
		? new TextDecoder().decode(args[0])
		: String(args[0] ?? "stranger");
	return `Hello ${name}, from a Deno binding host!`;
}

const server = listen(HOST, 0);
const port = await server.ready();
console.log(`deno-goblins-listen: pancake listening on ${HOST}:${port}`);

const served: Session[] = [];
const hosted = (async () => {
	for await (const conn of server) {
		conn.publish(ACTOR_SWISS, greeter);
		conn.serve().catch(() => {});
		served.push(conn);
	}
})();

const child = new Deno.Command(RACKET, {
	args: [DIALER_SCRIPT, String(port), ACTOR_SWISS, "world"],
	stdout: "piped",
	stderr: "piped",
}).spawn();

const stdoutReader = child.stdout.getReader();
const decoder = new TextDecoder();
let buf = "";
let ok = false;
try {
	const deadline = Date.now() + 30_000;
	while (Date.now() < deadline) {
		const { value, done } = await stdoutReader.read();
		if (done) break;
		buf += decoder.decode(value, { stream: true });
		if (buf.includes("DIAL OK")) {
			ok = true;
			break;
		}
	}
} finally {
	try {
		await stdoutReader.cancel();
	} catch { /* already released */ }
	try {
		child.kill();
	} catch { /* already gone */ }
	await child.status;
}

server.close();
for (const conn of served) conn.close();
await hosted;

if (!ok) {
	console.error(`deno-goblins-listen: dialer stdout: ${buf.trim()}`);
	fail("deno-goblins-listen", "Goblins did not print DIAL OK");
}

console.log(
	"deno-goblins-listen OK: binding Host/listen published and a real Goblins vat dialed it",
);
