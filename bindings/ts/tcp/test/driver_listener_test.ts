import * as tcp from "../mod.ts";
import {
	FEATURE_FULL,
	FEATURE_MULTI_LOCATION,
	formatLocatorUri,
	Host,
	Runtime,
	type Session,
} from "../../runtime/mod.ts";

function assert(value: unknown, message: string): asserts value {
	if (!value) throw new Error(message);
}

Deno.test("high-level servers expose the driver's complete listener locator", async () => {
	const plain = await tcp.listen("127.0.0.1", 0);
	const keyed = await tcp.keyed.listen("127.0.0.1", 0, {
		seed: new Uint8Array(32).fill(7),
	});
	const noise = await tcp.noise.listen("127.0.0.1", 0, {
		seed: new Uint8Array(32).fill(8),
	});
	try {
		assert(plain.locator.transport === "tcp", "plain server did not expose a tcp locator");
		assert(formatLocatorUri(plain.locator) === plain.uri, "plain server URI drifted from its locator");
		assert(keyed.uri.includes(".keyed-tcp?"), "keyed server did not expose its locator hint");
		assert(noise.uri.includes(".noise-tcp?"), "noise server did not expose its locator hint");
		assert(
			formatLocatorUri(keyed.locator) === keyed.uri,
			"keyed server URI drifted from its locator",
		);
		assert(
			formatLocatorUri(noise.locator) === noise.uri,
			"Noise server URI drifted from its locator",
		);
		assert(keyed.designator.length > 0, "keyed server lost its locator designator");
		assert(noise.designator.length > 0, "noise server lost its locator designator");
	} finally {
		await plain.close();
		await keyed.close();
		await noise.close();
	}
});

Deno.test("closing a TCP listener preserves its Host and yielded session", async () => {
	const host = new Host();
	const server = await tcp.listen("127.0.0.1", 0, { host });
	const runtime = await Runtime.open({ providers: [tcp.provider()] });
	let client: Session | null = null;
	let accepted: Session | null = null;
	try {
		const next = server[Symbol.asyncIterator]().next();
		client = await runtime.connect(tcp.locator("127.0.0.1", server.port));
		const result = await next;
		assert(!result.done, "driver listener did not yield a session");
		accepted = result.value;
		assert(client.transportName === "tcp", "dialed session lost its transport name");
		assert(accepted.transportName === "tcp", "accepted session lost its transport name");
		assert(client.profile.captpVersion === "v1_0", "dialed session did not settle v1.0");
		assert(client.profile.codec === "syrup", "dialed session did not settle Syrup");
		assert(
			client.profile.features === (FEATURE_FULL & ~FEATURE_MULTI_LOCATION),
			"dialed session did not report the exact v1.0 feature floor",
		);
		assert(
			client.profile.captpVersion === accepted.profile.captpVersion,
			"session profiles disagree on CapTP version",
		);
		assert(client.profile.codec === accepted.profile.codec, "session profiles disagree on codec");
		assert(client.profile.features === accepted.profile.features, "session profiles disagree on features");
		assert(server.host === host, "driver listener replaced the supplied Host wrapper");
		assert(host.driverLoop != null, "supplied Host did not transfer to the driver");
		accepted.publish("still-live", () => null);
		void accepted.serve();

		await server.close();
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
		await runtime.close();
		await server.stopAdmission();
		await host.close();
	}
});

Deno.test("closing an owned-loop TCP listener preserves its yielded session", async () => {
	const server = await tcp.listen("127.0.0.1", 0);
	const runtime = await Runtime.open({ providers: [tcp.provider()] });
	let client: Session | null = null;
	let accepted: Session | null = null;
	try {
		const next = server[Symbol.asyncIterator]().next();
		client = await runtime.connect(tcp.locator("127.0.0.1", server.port));
		const result = await next;
		assert(!result.done, "driver listener did not yield a session");
		accepted = result.value;
		accepted.publish("still-live", () => null);
		void accepted.serve();

		await new Promise<void>((resolve, reject) => {
			const timer = setTimeout(
				() => reject(new Error("owned-loop server.close waited for a live session")),
				2_000,
			);
			void server.close().then(
				() => {
					clearTimeout(timer);
					resolve();
				},
				(error: unknown) => {
					clearTimeout(timer);
					reject(error);
				},
			);
		});
		assert(!server.host.released, "owned-loop listener close released its Host");
		await client.fetch("still-live");
		await accepted.close();
		await client.close();
	} finally {
		await accepted?.close();
		await client?.close();
		await runtime.close();
		await server.close();
		await server.host.close();
	}
});

Deno.test("failed listener setup preserves a supplied Host for retry", async () => {
	const host = new Host();
	let retry: Awaited<ReturnType<typeof tcp.listen>> | null = null;
	try {
		let failed = false;
		try {
			await tcp.listen("0.0.0.0", 0, { host });
		} catch {
			failed = true;
		}
		assert(failed, "wildcard listen without an advertised host did not fail");
		assert(!host.released, "failed listen released the supplied Host");
		assert(host.driverLoop != null, "failed listen detached the adopted driver loop");

		retry = await tcp.listen("127.0.0.1", 0, { host });
		assert(retry.host === host, "listener retry replaced the supplied Host");
	} finally {
		await retry?.stopAdmission();
		await host.close();
	}
});

Deno.test("keyed and Noise listeners preserve a supplied Host", async () => {
	const seed = new Uint8Array(32).fill(9);
	const host = new Host(seed);
	const keyed = await tcp.keyed.listen("127.0.0.1", 0, { host });
	const noise = await tcp.noise.listen("127.0.0.1", 0, { host });
	try {
		assert(keyed.host === host, "keyed listener replaced the supplied Host");
		assert(noise.host === host, "Noise listener replaced the supplied Host");
		assert(host.driverLoop != null, "TCP profile listeners did not adopt the Host");
	} finally {
		await keyed.stopAdmission();
		await noise.stopAdmission();
		await host.close();
	}
});
