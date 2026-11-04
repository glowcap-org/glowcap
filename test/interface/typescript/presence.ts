// The raw peer distinguishes omitted arguments from explicitly supplied wire void.
import { type Argument, type HostProfile, Ref, VowBroken } from "@glowcap/runtime";
import * as generated from "../generated/callbacks.ts";
import { presenceArguments } from "../generated/expected.ts";
import { assert, withPair } from "./pair.ts";

export async function presence(): Promise<void> {
	for (const profile of ["interop", "glowcap"] satisfies HostProfile[]) {
		await scenario(profile);
	}
}

async function scenario(profile: HostProfile): Promise<void> {
	await withPair(profile, async (host, client, accepted) => {
		const calls: { verb: string; count: number }[] = [];
		let outcome: "void" | "wrong" | "broken" = "void";
		let settle: ((value: Argument) => void) | undefined;
		const localReader = accepted.spawn(() => null);
		host.publish("presence", (verb, args) => {
			assert(verb !== null, "presence method selector");
			if (verb === "reader") return localReader;
			if (verb === "pending") return new Promise<Argument>((resolve) => settle = resolve);
			if (verb === "references") {
				assert(args.length <= 2 && args.every((arg) => arg instanceof Ref), "reference arguments");
				if (args.length === 2) assert(settle, "pending reference was awaited");
			} else {
				let expected: readonly Argument[];
				if (verb === "required") expected = presenceArguments.void;
				else if (verb === "suffix") expected = presenceArguments[args.length === 1 ? "one" : "text-void"];
				else if (verb === "pair") expected = presenceArguments[["absent", "one", "two"][args.length]];
				else {
					assert(["optional", "notify", "value"].includes(verb), "known presence method");
					expected = presenceArguments[args.length === 0 ? "absent" : args[0] === null ? "void" : "one"];
				}
				assert(args.length === expected.length, "independent expected arity");
				assert(args.every((arg, i) => arg === expected[i]), "independent expected arguments");
			}
			calls.push({ verb, count: args.length });
			if (outcome === "wrong") return "wrong void result";
			if (outcome === "broken") throw new Error("presence refusal");
			return null;
		});
		const target = await client.fetch("presence");
		const required = () => generated.presence_required(client, target, undefined).observe();
		const lastCount = () => calls[calls.length - 1].count;
		const unobserved = generated.presence_optional(client, target);
		assert(unobserved.raw, "optional call preserves the raw pending handle");
		await required();
		assert(calls[0].verb === "optional" && calls[0].count === 0, "optional send was lazy");
		await unobserved.observe();
		assert(
			await generated.presence_optional(client, target, undefined).observe() === undefined,
			"typed void result",
		);
		assert(lastCount() === 1, "explicit undefined was omitted");
		await generated.presence_suffix(client, target, "first").observe();
		assert(lastCount() === 1, "optional suffix omission");
		await generated.presence_suffix(client, target, "first", undefined).observe();
		assert(lastCount() === 2, "explicit undefined suffix");
		await generated.presence_pair(client, target).observe();
		assert(lastCount() === 0, "empty optional prefix");
		await generated.presence_pair(client, target, "first").observe();
		assert(lastCount() === 1, "one optional argument");
		await generated.presence_pair(client, target, "first", "second").observe();
		assert(lastCount() === 2, "two optional arguments");
		for (const value of [null, "first"] satisfies Argument[]) {
			await generated.presence_value(client, target, value).observe();
			assert(lastCount() === 1, "optional runtime value");
		}
		await generated.presence_value(client, target).observe();
		assert(lastCount() === 0, "optional runtime value omission");
		await generated.presence_notify(client, target);
		await generated.presence_notify(client, target, undefined);
		await required();
		assert(
			calls.filter((call) => call.verb === "notify").map((call) => call.count).join() === "0,1",
			"tell presence",
		);

		const reader = await client.send(target, "reader", []);
		assert(reader instanceof Ref, "reader reference");
		await generated.presence_references(client, target).observe();
		assert(lastCount() === 0, "optional reference omission");
		await generated.presence_references(client, target, reader).observe();
		assert(lastCount() === 1, "optional target");
		const pending = client.send(target, "pending", []);
		await generated.presence_references(client, target, pending).observe();
		assert(lastCount() === 1 && settle, "plain interface argument was awaited");
		await generated.presence_references(client, target, reader, pending).observe();
		assert(lastCount() === 2, "optional pending reference");
		assert(settle, "pending call admitted before observation");
		settle(localReader);
		await pending;

		const before = calls.length;
		for (
			const [fn, args] of [
				[generated.presence_required, []],
				[generated.presence_required, [null]],
				[generated.presence_required, [false]],
				[generated.presence_required, [undefined, undefined]],
				[generated.presence_optional, [null]],
				[generated.presence_optional, [false]],
				[generated.presence_pair, [undefined, "second"]],
				[generated.presence_pair, [1]],
				[generated.presence_pair, [{ toString: () => "first" }]],
				[generated.presence_suffix, []],
				[generated.presence_suffix, [1]],
				[generated.presence_suffix, ["first", null]],
				[generated.presence_references, [undefined, reader]],
				[generated.presence_references, ["not a reference"]],
				[generated.presence_references, [reader, Promise.resolve(reader)]],
				[generated.presence_notify, [null]],
			] satisfies [(...args: never[]) => unknown, unknown[]][]
		) {
			let refused = false;
			try {
				Reflect.apply(fn, undefined, [client, target, ...args]);
			} catch (error) {
				refused = error instanceof TypeError;
			}
			assert(refused, "invalid arguments were not refused before sending");
		}
		const localCalls: Argument[][] = [];
		const local = client.spawn((_verb, args) => {
			localCalls.push(args);
			return null;
		});
		for (const receiver of [target, local]) {
			let refused = false;
			try {
				generated.presence_value(client, receiver, undefined);
			} catch (error) {
				refused = error instanceof TypeError;
			}
			assert(refused, "supplied optional opaque undefined was not narrowed");
		}
		assert(Number(localCalls.length) === 0, "invalid optional opaque value reached local handler");
		await generated.presence_value(client, local).observe();
		await generated.presence_value(client, local, null).observe();
		await generated.presence_required(client, local, undefined).observe();
		assert(
			localCalls.length === 3 && localCalls[0].length === 0 && localCalls[1][0] === null &&
				localCalls[2][0] === null,
			"local omission/opaque null/explicit void controls",
		);
		await required();
		assert(calls.length === before + 1, "invalid arguments admitted a call");
		outcome = "wrong";
		let wrong = false;
		try {
			await required();
		} catch (error) {
			wrong = error instanceof TypeError;
		}
		assert(wrong, "wrong void fulfillment was accepted");
		outcome = "broken";
		let broken: unknown;
		try {
			await generated.presence_optional(client, target).observe();
		} catch (error) {
			broken = error;
		}
		assert(broken instanceof VowBroken && broken.reason === "presence refusal", "runtime break changed");
		outcome = "void";
		await required();
	});
}
