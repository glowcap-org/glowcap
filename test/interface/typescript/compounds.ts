// Generated projections validate raw peer replies on both negotiated profiles.
import { type Argument, type HostProfile, Ref, Sym, Tagged, VowBroken } from "@glowcap/runtime";
import * as g from "../generated/compounds.ts";
import { poll } from "../generated/observation.ts";
import { assert, withPair } from "./pair.ts";

type Observation = { raw: PromiseLike<Argument>; observe(): Promise<unknown> };

async function refused(observation: Observation): Promise<void> {
	const [typed, raw, repeated] = await Promise.allSettled([
		observation.observe(),
		observation.raw.then((value) => value),
		observation.observe(),
	]);
	assert(typed.status === "rejected" && typed.reason instanceof TypeError, "compound shape accepted");
	assert(repeated.status === "rejected" && repeated.reason instanceof TypeError, "repeated shape accepted");
	assert(raw.status === "fulfilled", "typed refusal changed raw settlement");
}

async function same(observation: Observation): Promise<unknown> {
	const [typed, raw, repeated] = await Promise.all([
		observation.observe(),
		observation.raw.then((value) => value),
		observation.observe(),
	]);
	assert(typed === raw && typed === repeated, "compound projection replaced original object");
	return typed;
}

export async function compounds(): Promise<void> {
	for (const profile of ["interop", "glowcap"] satisfies HostProfile[]) {
		await withPair(profile, async (host, client, accepted) => {
			let reply: Argument = [];
			let broken = false;
			const reference = accepted.spawn(() => "compound reference survived");
			host.publish("compound", (_verb, args) => {
				assert(args.length === 0, "compound call arity");
				if (broken) throw new Error("future compound break");
				return reply;
			});
			const target = await client.fetch("compound");
			for (const value of [[], [new Sym("future"), new Sym("future")]]) {
				reply = value;
				const result = await g.list(client, target).observe();
				assert(
					result.length === value.length && Array.from(result).every((item) => item.value === "future"),
					"symbol list",
				);
				await same(g.list(client, target));
				await same(g.limited(client, target));
			}
			for (const value of ["not a list", new Tagged("tag", []), ["not a symbol"], [true], [1n], [1]]) {
				reply = value;
				await refused(g.list(client, target));
			}
			reply = [new Sym("one"), new Sym("two"), new Sym("three")];
			await refused(g.limited(client, target));
			reply = [new Uint8Array([0, 255]), reference, true];
			const tuple = await g.tuple(client, target).observe();
			assert(tuple[0][1] === 255 && tuple[2], "tuple positional fields");
			assert(
				await client.send(tuple[1], "read", []) === "compound reference survived",
				"tuple reference custody",
			);
			const rawTuple = await same(g.tuple(client, target));
			assert(Array.isArray(rawTuple) && rawTuple[0] instanceof Uint8Array, "tuple payload survived");
			for (
				const value of [
					[],
					[new Uint8Array(2), reference],
					[new Uint8Array(2), reference, true, null],
					[new Uint8Array(1), reference, true],
					[new Uint8Array(3), reference, true],
					["bytes", reference, true],
					[new Uint8Array(2), "reference", true],
					[new Uint8Array(2), reference, 1n],
					new Tagged("tuple", [new Uint8Array(2), reference, true]),
				]
			) {
				reply = value;
				await refused(g.tuple(client, target));
			}
			reply = [];
			assert((await g.zero(client, target).observe()).length === 0, "empty tuple");
			reply = [null];
			await refused(g.zero(client, target));
			reply = [[new Sym("nested"), reference, new Tagged("opaque", [[reference], 7n])]];
			const nested = await g.nested(client, target).observe();
			assert(nested[0][0].value === "nested" && nested[0][2] instanceof Tagged, "nested compound/opaque");
			await same(g.nested(client, target));
			for (const value of [[["wrong", reference, null]], [[new Sym("nested"), false, null]], [null]]) {
				reply = value;
				await refused(g.nested(client, target));
			}
			broken = true;
			const observed = g.list(client, target);
			const [typed, raw] = await Promise.allSettled([observed.observe(), observed.raw.then((value) => value)]);
			assert(typed.status === "rejected" && raw.status === "rejected", "remote break accepted");
			assert(typed.reason === raw.reason && typed.reason instanceof VowBroken, "compound break replaced");
			assert(typed.reason.reason === "future compound break", "compound remote reason lost");
		});
		await observation(profile);
	}
}

async function observation(profile: HostProfile): Promise<void> {
	await withPair(profile, async (host, client, accepted) => {
		const reference = accepted.spawn(() => "opaque reference survived");
		const opaque = new Tagged("opaque", [[reference], new Uint8Array([0, 255]), 1n, 1.5]);
		const valid = (): Tagged =>
			new Tagged("access:observation", [
				new Uint8Array(56).fill(7),
				opaque,
				false,
				true,
				[new Sym("future-notice"), new Sym("future-notice")],
			]);
		let reply: Argument = valid();
		let calls = 0;
		host.publish("observation", (verb, args) => {
			assert(verb === "poll" && args.length <= 1, "observation call shape");
			if (args.length) assert(args[0] instanceof Uint8Array && args[0].byteLength === 56, "cursor argument");
			calls++;
			return reply;
		});
		const target = await client.fetch("observation");
		const observed = poll(client, target);
		const value = await observed.observe();
		assert(value.tag === "access:observation" && value.value.length === 5, "record tag/arity");
		assert(value.value[0].byteLength === 56 && !value.value[2] && value.value[3], "record fields");
		assert(
			value.value[4].length === 2 && Array.from(value.value[4]).every((n) => n.value === "future-notice"),
			"unknown duplicate notices lost",
		);
		assert(value.value[1] instanceof Tagged, "opaque Tagged category");
		const children = value.value[1].value[0];
		assert(Array.isArray(children) && children[0] instanceof Ref, "opaque capability preserved");
		assert(await client.send(children[0], "read", []) === "opaque reference survived", "opaque capability custody");
		assert(await same(observed) === value, "record observation identity");
		const cursor = value.value[0];
		await poll(client, target, cursor).observe();
		for (
			const malformed of [
				new Tagged("wrong:observation", valid().value),
				valid().value,
				new Tagged("access:observation", valid().value.slice(0, 4)),
				new Tagged("access:observation", [...valid().value, null]),
			]
		) {
			reply = malformed;
			await refused(poll(client, target));
		}
		for (
			const [field, wrong] of [
				[0, new Uint8Array(55)],
				[0, new Uint8Array(57)],
				[0, "cursor"],
				[2, 0n],
				[3, "true"],
				[4, ["future-notice"]],
				[4, new Tagged("list", [])],
			] satisfies [number, Argument][]
		) {
			const malformed = valid();
			malformed.value[field] = wrong;
			reply = malformed;
			await refused(poll(client, target));
		}
		const before = calls;
		for (const cursor of [new Uint8Array(55), new Uint8Array(57), null, undefined, "cursor"]) {
			let failed = false;
			try {
				Reflect.apply(poll, undefined, [client, target, cursor]);
			} catch (error) {
				failed = error instanceof TypeError;
			}
			assert(failed, "invalid cursor sent");
		}
		reply = valid();
		await poll(client, target).observe();
		assert(calls === before + 1, "cursor refusal changed remote state");
	});
}
