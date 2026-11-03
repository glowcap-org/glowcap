// One proposed-text input reaches existing generated calls and a raw peer.
import { type Argument, type HostProfile, Ref, VowBroken } from "@glowcap/runtime";
import { accept_text, invoke_text } from "../generated/authoring_text.ts";
import { presenceArguments } from "../generated/expected.ts";
import { assert, withPair } from "./pair.ts";

export async function authoring(): Promise<void> {
	for (const profile of ["interop", "glowcap"] satisfies HostProfile[]) {
		await withPair(profile, async (host, client, accepted) => {
			const reader = accepted.spawn(() => "reader");
			let settle: ((value: Argument) => void) | undefined;
			let broken = false;
			const counts: number[] = [];
			host.publish("authoring", (verb, args) => {
				if (verb === "pending") return new Promise<Argument>((resolve) => settle = resolve);
				if (verb === "reader") return reader;
				if (verb === "accept") {
					assert(
						settle && args.length === 2 && args.every((arg) => arg instanceof Ref),
						"pending input admission",
					);
					return null;
				}
				assert(verb === null, "text frontend inserted a selector");
				const expected = presenceArguments[counts.length === 0 ? "absent" : "void"];
				assert(
					args.length === expected.length && args.every((arg, i) => arg === expected[i]),
					"text frontend presence",
				);
				counts.push(args.length);
				if (broken) throw new Error("unlisted authoring failure");
				return null;
			});
			const target = await client.fetch("authoring");
			const first = invoke_text(client, target);
			assert(first.raw, "text frontend lost the raw pending handle");
			await invoke_text(client, target, undefined).observe();
			await first.observe();
			assert(counts.join() === "0,1", "text frontend changed supplied arity");
			const ready = await client.send(target, "reader", []);
			assert(ready instanceof Ref, "raw reader");
			const pending = client.send(target, "pending", []);
			await accept_text(client, target, ready, pending).observe();
			assert(settle, "text frontend waited for the pending argument");
			settle(reader);
			await pending;
			broken = true;
			let reason: unknown;
			try {
				await invoke_text(client, target, undefined).observe();
			} catch (error) {
				reason = error;
			}
			assert(
				reason instanceof VowBroken && reason.reason === "unlisted authoring failure",
				"unknown break changed",
			);
		});
	}
}
