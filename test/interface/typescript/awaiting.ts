// Ordinary await must observe generated calls and their declared reply types.
import { type Argument, type HostProfile, VowBroken } from "@glowcap/runtime";
import * as g from "../generated/callbacks.ts";
import { assert, withPair } from "./pair.ts";

export async function awaiting(): Promise<void> {
	for (const profile of ["interop", "glowcap"] satisfies HostProfile[]) {
		await withPair(profile, async (host, client) => {
			let resolve: ((value: Argument) => void) | undefined;
			let reply: "pending" | "wrong" | "broken" = "pending";
			host.publish("awaiting", (verb) => {
				if (verb === "barrier") return null;
				if (verb === "read") return "typed text";
				assert(verb === "required", "unexpected method");
				if (reply === "wrong") return "not void";
				if (reply === "broken") throw new Error("ordinary await refusal");
				return new Promise<Argument>((settle) => resolve = settle);
			});
			const target = await client.fetch("awaiting");
			const pending = g.presence_required(client, target, undefined);
			let completed = false;
			const observation = (async () => {
				await pending;
				completed = true;
			})();
			await client.send(target, "barrier");
			assert(resolve && !completed, "await returned before the generated void call settled");
			resolve(null);
			await observation;
			const value: string = await g.reader_read(client, target);
			assert(value === "typed text", "await returned a wrapper instead of the declared value");
			const lengths = await Promise.all([
				g.reader_read(client, target).then((text) => text.length),
				g.reader_read(client, target),
			]);
			assert(lengths[0] === 10 && lengths[1] === "typed text", "standard promise composition lost typed replies");
			reply = "wrong";
			let wrong: unknown;
			try {
				await g.presence_required(client, target, undefined);
			} catch (error) {
				wrong = error;
			}
			assert(wrong instanceof TypeError, "ordinary await bypassed reply validation");
			const recovered = await g.presence_required(client, target, undefined).then(
				() => false,
				(error) => error instanceof TypeError,
			);
			assert(recovered, "then rejection callback missed the decoder failure");
			reply = "broken";
			let broken: unknown;
			try {
				await g.presence_required(client, target, undefined);
			} catch (error) {
				broken = error;
			}
			assert(
				broken instanceof VowBroken && broken.reason === "ordinary await refusal",
				"await lost the remote break",
			);
			client.release(target);
		});
	}
}
