// Positional, empty-symbol, and named invocation stay distinct on both profiles.
import { Host, type HostProfile, type Ref, Runtime } from "@glowcap/runtime";
import * as tcp from "@glowcap/tcp";
import * as generated from "../generated/callbacks.ts";

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

export async function invocation(): Promise<void> {
	for (const profile of ["interop", "glowcap"] satisfies HostProfile[]) {
		await using host = new Host(undefined, { profile });
		await using clientHost = new Host(undefined, { profile });
		let notices = 0;
		host.publish("invocation", (verb, args) => {
			if (verb === null) {
				assert(args.length === 1 && args[0] === "positional input", "positional arguments");
				return "positional result";
			}
			assert(args.length === 0, "symbolic arguments");
			if (verb === "") return "empty-symbol result";
			if (verb === "then") return "named result";
			throw new Error("unknown invocation");
		});
		host.publish("notify", (verb, args) => {
			assert(verb === null && args.length === 1 && args[0] === "notification", "positional tell");
			notices++;
		});
		const server = await tcp.listen("127.0.0.1", 0, { host });
		await using runtime = await Runtime.open({ adoptHost: clientHost, providers: [tcp.provider()] });
		const accepting = server[Symbol.asyncIterator]().next();
		const client = await runtime.connect(tcp.locator("127.0.0.1", server.port));
		const incoming = await accepting;
		assert(!incoming.done, "accepted connection");
		const serving = incoming.value.serve();
		const failures: unknown[] = [];
		try {
			const negotiated = client.profile;
			assert(negotiated.codec === (profile === "interop" ? "syrup" : "capnp"), "negotiated codec");
			assert(negotiated.captpVersion === (profile === "interop" ? "v1_0" : "next"), "negotiated version");
			const target: Ref = await client.fetch("invocation");
			assert(
				await generated.invoke_direct(client, target, "positional input").observe() === "positional result",
				"positional result",
			);
			assert(
				await generated.invoke_empty(client, target).observe() === "empty-symbol result",
				"empty-symbol result",
			);
			const notify = await client.fetch("notify");
			await generated.notify_direct(client, notify, "notification");
			assert(await generated.invoke_named(client, target).observe() === "named result", "named result");
			assert(notices === 1, "tell delivered before barrier");
		} catch (error) {
			failures.push(error);
		}
		for (const cleanup of [() => client.close({ pending: "cancel" }), () => server.close(), () => serving]) {
			try {
				await cleanup();
			} catch (error) {
				failures.push(error);
			}
		}
		if (failures.length) throw new AggregateError(failures, "invocation proof failed");
	}
}
