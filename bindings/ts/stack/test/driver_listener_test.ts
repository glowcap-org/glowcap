import { connect, Host, listen, type Session, tcpLocator } from "../mod.ts";

function assert(value: unknown, message: string): asserts value {
	if (!value) throw new Error(message);
}

Deno.test("closing a TCP listener preserves its Host and yielded session", async () => {
	const host = new Host();
	const server = listen("127.0.0.1", 0, host);
	let client: Session | null = null;
	let accepted: Session | null = null;
	try {
		const next = server[Symbol.asyncIterator]().next();
		await server.ready();
		client = await connect(tcpLocator("127.0.0.1", server.port));
		const result = await next;
		assert(!result.done, "driver listener did not yield a session");
		accepted = result.value;
		assert(server.host === host, "driver listener replaced the supplied Host wrapper");
		assert(host.driverLoop != null, "supplied Host did not transfer to the driver");
		accepted.publish("still-live", () => null);

		server.close();
		await server.stopAdmission();
		assert(!host.released, "listener close released its shared Host");
		const afterClose = await server[Symbol.asyncIterator]().next();
		assert(afterClose.done, "closed listener admitted another session");
		await client.fetch("still-live");
		await accepted.close();
		await client.close();
		assert(!host.released, "closing yielded sessions released the supplied Host");
	} finally {
		await accepted?.close();
		await client?.close();
		await server.stopAdmission();
		await host.releaseAsync();
	}
});
