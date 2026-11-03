// Positional, empty-symbol, and named invocation stay distinct on both profiles.
import { type HostProfile, type Ref } from "@glowcap/runtime";
import * as generated from "../generated/callbacks.ts";
import { assert, withPair } from "./pair.ts";

export async function invocation(): Promise<void> {
	for (const profile of ["interop", "glowcap"] satisfies HostProfile[]) {
		await withPair(profile, async (host, client) => {
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
		});
	}
}
