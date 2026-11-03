// One owner for live TCP proof setup, negotiated profiles, and cleanup.
import { Host, type HostProfile, Runtime, type Session } from "@glowcap/runtime";
import * as tcp from "@glowcap/tcp";

export function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

export async function withPair(
	profile: HostProfile,
	run: (host: Host, client: Session, accepted: Session) => Promise<void>,
): Promise<void> {
	await using host = new Host(undefined, { profile });
	await using server = await tcp.listen("127.0.0.1", 0, { host });
	await using runtime = await Runtime.open({ profile, providers: [tcp.provider()] });
	const accepting = server[Symbol.asyncIterator]().next();
	const client = await runtime.connect(tcp.locator("127.0.0.1", server.port));
	const incoming = await accepting;
	assert(!incoming.done, "accepted connection");
	const accepted = incoming.value;
	const serving = Promise.allSettled([accepted.serve()]);
	const failures: unknown[] = [];
	try {
		const negotiated = client.profile;
		assert(negotiated.codec === (profile === "interop" ? "syrup" : "capnp"), "negotiated codec");
		assert(negotiated.captpVersion === (profile === "interop" ? "v1_0" : "next"), "negotiated version");
		await run(host, client, accepted);
	} catch (error) {
		failures.push(error);
	}
	for (
		const cleanup of [
			() => client.close({ pending: "cancel" }),
			() => server.close(),
			async () => {
				const [outcome] = await serving;
				if (outcome.status === "rejected") throw outcome.reason;
			},
		]
	) {
		try {
			await cleanup();
		} catch (error) {
			failures.push(error);
		}
	}
	if (failures.length) throw new AggregateError(failures, "interface pair failed");
}
