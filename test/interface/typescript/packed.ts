// Local packed integer lists and wire-normalized arrays share one schema view.
import { type Argument, type HostProfile, type RemotePromise, Sym, Tagged } from "@glowcap/runtime";
import * as lists from "../generated/packed_lists.ts";
import * as tuples from "../generated/packed_tuples.ts";
import { assert, withPair } from "./pair.ts";

type Pending = { raw: RemotePromise; observe(): Promise<Argument> };

async function same(pending: Pending, original: Argument): Promise<void> {
	const [typed, raw, repeated] = await Promise.all([
		pending.observe(),
		pending.raw.then((value) => value),
		pending.observe(),
	]);
	assert(typed === original && raw === original && repeated === original, "local projection replaced its result");
}

async function refused(pending: Pending, original: Argument): Promise<void> {
	const [typed, raw] = await Promise.allSettled([pending.observe(), pending.raw.then((value) => value)]);
	assert(typed.status === "rejected" && typed.reason instanceof TypeError, "packed schema accepted");
	assert(raw.status === "fulfilled" && raw.value === original, "packed refusal replaced raw settlement");
}

export async function packed(): Promise<void> {
	for (const profile of ["interop", "glowcap"] satisfies HostProfile[]) {
		await withPair(profile, async (host, client) => {
			let reply: Argument = null;
			const local = client.spawn((_verb, args) => {
				assert(args.length === 0, "local packed call arity");
				return reply;
			});
			const integers = new BigInt64Array([-(2n ** 63n), -2n, 0n, 2n ** 63n - 1n]);
			reply = integers;
			assert(await client.send(local, "integers", []) === integers, "raw local packed identity");
			await same(lists.integers(client, local), integers);
			await same(lists.signed(client, local), integers);
			await same(lists.values(client, local), integers);
			for (
				const method of [
					lists.symbols,
					lists.floats,
					lists.targets,
					lists.texts,
					lists.booleans,
					lists.byteArrays,
					lists.nested,
				]
			) await refused(method(client, local), integers);
			for (
				const method of [
					lists.integers,
					lists.signed,
					lists.narrow,
					lists.values,
					lists.symbols,
					lists.floats,
					lists.targets,
					lists.texts,
					lists.booleans,
					lists.byteArrays,
					lists.nested,
					lists.limited,
				]
			) {
				reply = new BigInt64Array();
				await same(method(client, local), reply);
			}
			for (const value of [new BigInt64Array([-2n, 0n, 2n]), [-(2n ** 128n), 2n ** 128n]]) {
				reply = value;
				await same(lists.integers(client, local), value);
			}
			reply = new BigInt64Array([-2n, 2n]);
			await same(lists.narrow(client, local), reply);
			await same(lists.limited(client, local), reply);
			for (const value of [new BigInt64Array([-3n]), new BigInt64Array([3n])]) {
				reply = value;
				await refused(lists.narrow(client, local), value);
			}
			reply = new BigInt64Array([0n, 0n, 0n]);
			await refused(lists.limited(client, local), reply);
			const child = new BigInt64Array([1n, 2n]);
			reply = [child, [2n ** 128n]];
			await same(lists.nested(client, local), reply);
			const nested = await lists.nested(client, local).observe();
			assert(nested[0] === child && nested[1][0] === 2n ** 128n, "nested packed child replaced or narrowed");
			for (const value of [new BigInt64Array([1n, -2n, 99n]), [2n ** 128n, 2n, new Sym("opaque")]]) {
				reply = value;
				await same(tuples.tuple(client, local), value);
				const projected = await tuples.tuple(client, local).observe();
				const [first, second] = projected;
				assert(first === value[0] && second === value[1], "fixed positions changed");
			}
			for (const value of [new BigInt64Array([1n, 3n, 4n]), new BigInt64Array([1n, 0n])]) {
				reply = value;
				await refused(tuples.tuple(client, local), value);
			}
			reply = new BigInt64Array([1n, 2n]);
			await same(tuples.wideTuple(client, local), reply);
			await same(tuples.opaqueTuple(client, local), reply);
			await refused(tuples.incompatible(client, local), reply);
			reply = [2n ** 128n, "text"];
			await same(tuples.incompatible(client, local), reply);
			reply = new BigInt64Array();
			await same(tuples.zero(client, local), reply);
			reply = new BigInt64Array([1n]);
			await refused(tuples.zero(client, local), reply);
			reply = [child, [2n ** 128n, new Sym("opaque")]];
			await same(tuples.nestedTuples(client, local), reply);
			const record = new Tagged("packed:record", [integers, child]);
			reply = record;
			await same(tuples.record(client, local), record);
			const observed = await tuples.record(client, local).observe();
			assert(
				observed.value[0] === integers && observed.value[1] === child,
				"record ancestors or children replaced",
			);
			let forwarded = 0;
			const receiver = client.spawn((_verb, args) => {
				assert(args.length === 1 && args[0] === integers, "forwarded projection copied or cast");
				forwarded++;
				return null;
			});
			reply = integers;
			const view = await lists.integers(client, local).observe();
			await client.send(receiver, "accept", [view]);
			await client.tell(receiver, "accept", [view]);
			assert(forwarded === 2, "projected view not passable");
			host.publish("packed-wire", () => integers);
			const far = await client.fetch("packed-wire");
			const rawWire = await client.send(far, "integers", []);
			assert(
				Array.isArray(rawWire) && rawWire.every((value) => typeof value === "bigint"),
				"wire list not normalized",
			);
			const wire = lists.integers(client, far);
			const [typedWire, untouchedWire] = await Promise.all([wire.observe(), wire.raw.then((value) => value)]);
			assert(typedWire === untouchedWire && Array.isArray(typedWire), "wire typed/raw result replaced");
		});
	}
}
