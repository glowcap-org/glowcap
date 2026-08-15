import { Host, Runtime, type Session } from "@pancake/runtime";
import * as tcp from "@pancake/tcp";
import { listen, Reachability } from "../impl.ts";

function assert(value: unknown, message: string): asserts value {
	if (!value) throw new Error(message);
}

Deno.test("supplied iroh Host transfers to the generic driver listener", async () => {
	const seed = crypto.getRandomValues(new Uint8Array(32));
	const host = new Host(seed);
	const server = await listen({ reachability: Reachability.Direct }, { host });
	try {
		assert(server.host === host, "iroh listener replaced the supplied Host wrapper");
		assert(host.driverLoop != null, "supplied iroh Host did not transfer to the driver");
		assert(server.uri.includes(".iroh"), "generic driver listener did not advertise iroh");
		await server.stopAdmission();
		assert(!host.released, "iroh listener close released its shared Host");
	} finally {
		await server.stopAdmission();
		await host.close();
	}
});

Deno.test("closing iroh admission leaves a sibling TCP listener live", async () => {
	const seed = crypto.getRandomValues(new Uint8Array(32));
	const host = new Host(seed);
	const tcpServer = await tcp.listen("127.0.0.1", 0, { host });
	const iroh = await listen({ reachability: Reachability.Direct }, { host });
	const runtime = await Runtime.open({ providers: [tcp.provider()] });
	let client: Session | null = null;
	let accepted: Session | null = null;
	try {
		await iroh.stopAdmission();
		assert(!host.released, "iroh listener close released the shared loop");
		const next = tcpServer[Symbol.asyncIterator]().next();
		client = await runtime.connect(tcp.locator("127.0.0.1", tcpServer.port));
		const result = await next;
		assert(!result.done, "sibling TCP listener stopped with iroh admission");
		accepted = result.value;
	} finally {
		await accepted?.close();
		await client?.close();
		await runtime.close();
		await iroh.stopAdmission();
		await tcpServer.stopAdmission();
		await host.close();
	}
});
