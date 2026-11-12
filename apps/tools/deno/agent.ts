// An agent, written on glowcap actors in native Deno. It connects to the tools
// coordinator and proves the three capability properties — delegation,
// attenuation, revocation — over the wire:
//
//   1. delegation  — it is handed a capability to a tool and can call it.
//   2. attenuation — a read-only file capability serves reads and refuses writes.
//   3. revocation  — a revoked handle breaks on every subsequent call.
//
// And, by construction, least authority: the agent holds exactly the references
// it was granted — there is no ambient authority and no global directory of tools
// to enumerate, so no reference the coordinator never sent it names a tool it can
// reach.
//
//   deno run --allow-ffi --allow-read --allow-net agent.ts <locator> deno-agent
//
// The locator is the `ocapn://` URI the coordinator printed.

import { type Argument, parseLocator, Ref, Runtime, VowBroken } from "@glowcap/runtime";
import * as tcp from "@glowcap/tcp";
import { GRANT, GRANT_REVOCABLE, NOW, READ, REVOKE_LAST, TOOLS, WRITE } from "./protocol.ts";

const [locator, nick] = Deno.args;
if (!locator || !nick) {
	console.error("usage: agent.ts <locator> <nick>");
	Deno.exit(2);
}

function check(label: string, ok: boolean): void {
	console.log(`${nick}: ${ok ? "ok" : "FAIL"}, ${label}`);
	if (!ok) Deno.exit(1);
}

/** Whether the partner broke the call. Only a broken promise is the refusal
 * these checks look for, so a transport or marshalling failure propagates and
 * fails the agent with its own cause. */
async function broke(call: Promise<unknown>): Promise<boolean> {
	try {
		await call;
		return false;
	} catch (error) {
		if (error instanceof VowBroken) return true;
		throw error;
	}
}

function capability(granted: Argument, what: string): Ref {
	if (granted instanceof Ref) return granted;
	throw new Error(`the coordinator's ${what} grant was not a capability`);
}

await using runtime = await Runtime.open({ providers: [tcp.provider()] });
const session = await runtime.connect(parseLocator(locator));
// A transport fault fails the next call on this session; say why it did.
session.serve().catch((error: unknown) => {
	console.error(
		`tools agent: the coordinator session ended with a fault: ${error instanceof Error ? error.message : error}`,
	);
});
const tools = await session.fetch(TOOLS);

// 1. Delegation: get a clock capability and call it.
const clock = capability(await session.send(tools, GRANT, ["clock"]), "clock");
const now = await session.send(clock, NOW);
check("delegation: was handed a clock and called it", typeof now === "bigint");

// 2. Attenuation: a read-only file capability reads but refuses writes.
const files = capability(await session.send(tools, GRANT, ["files-readonly"]), "read-only files");
const contents = await session.send(files, READ, ["report.txt"]);
check(
	"attenuation: read through the read-only view",
	typeof contents === "string",
);
check(
	"attenuation: write is refused",
	await broke(session.send(files, WRITE, ["report.txt", "tampered"])),
);

// 3. Revocation: a revocable handle works, then breaks after revoke.
const revocableClock = capability(await session.send(tools, GRANT_REVOCABLE, ["clock"]), "revocable clock");
const before = await session.send(revocableClock, NOW);
check("revocation: the handle works before revoke", typeof before === "bigint");
await session.send(tools, REVOKE_LAST);
check(
	"revocation: the handle breaks after revoke",
	await broke(session.send(revocableClock, NOW)),
);

console.log(`${nick}: all capability properties held`);
session.close();
