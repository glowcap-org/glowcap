// Independent raw peers qualify exact bigint categories and UTF-8 text limits.
import {
	type Argument,
	type HostProfile,
	Ref,
	type RemotePromise,
	type Session,
	Sym,
	Tagged,
	VowBroken,
} from "@glowcap/runtime";
import * as integers from "../generated/integers.ts";
import * as text from "../generated/text_bounds.ts";
import * as mixed from "../generated/mixed_bounds.ts";
import { assert, withPair } from "./pair.ts";

type Observed<T> = { raw: RemotePromise; observe(): Promise<T> };
type Methods<T> = {
	call(session: Session, target: Ref, value: T): Observed<T>;
	optional(session: Session, target: Ref, value?: T): Observed<T>;
	tell(session: Session, target: Ref, value: T): Promise<void>;
	optionalTell(session: Session, target: Ref, value?: T): Promise<void>;
};
type Case<T> = Methods<T> & { name: string; values: T[]; outside: T[] };
const huge = 2n ** 128n;
const minimum = -(2n ** 63n);
const maximum = 2n ** 63n - 1n;
const integerCases: Case<bigint>[] = [
	{
		name: "bare",
		call: integers.bare_call,
		optional: integers.bare_optional,
		tell: integers.bare_tell,
		optionalTell: integers.bare_optional_tell,
		values: [0n, -1n, minimum, maximum, minimum - 1n, maximum + 1n, huge, -huge],
		outside: [],
	},
	{
		name: "empty",
		call: integers.empty_call,
		optional: integers.empty_optional,
		tell: integers.empty_tell,
		optionalTell: integers.empty_optional_tell,
		values: [0n, huge, -huge],
		outside: [],
	},
	{
		name: "lower",
		call: integers.lower_call,
		optional: integers.lower_optional,
		tell: integers.lower_tell,
		optionalTell: integers.lower_optional_tell,
		values: [-2n, 0n, huge],
		outside: [-3n, -huge],
	},
	{
		name: "upper",
		call: integers.upper_call,
		optional: integers.upper_optional,
		tell: integers.upper_tell,
		optionalTell: integers.upper_optional_tell,
		values: [-huge, 0n, 2n],
		outside: [3n, huge],
	},
	{
		name: "signed",
		call: integers.signed_call,
		optional: integers.signed_optional,
		tell: integers.signed_tell,
		optionalTell: integers.signed_optional_tell,
		values: [minimum, 0n, maximum],
		outside: [minimum - 1n, maximum + 1n],
	},
	{
		name: "narrow",
		call: integers.narrow_call,
		optional: integers.narrow_optional,
		tell: integers.narrow_tell,
		optionalTell: integers.narrow_optional_tell,
		values: [-2n, 0n, 2n],
		outside: [-3n, 3n],
	},
	{
		name: "alias",
		call: integers.alias_call,
		optional: integers.alias_optional,
		tell: integers.alias_tell,
		optionalTell: integers.alias_optional_tell,
		values: [-2n, 0n, 2n],
		outside: [-3n, 3n],
	},
];
const textCases: Case<string>[] = [
	{
		name: "bare",
		call: text.bare_call,
		optional: text.bare_optional,
		tell: text.bare_tell,
		optionalTell: text.bare_optional_tell,
		values: ["", "é", "€", "💩", "\ud800", "\udc00", "\ud800\udc00", "\ud800a\udc00"],
		outside: [],
	},
	{
		name: "empty",
		call: text.empty_call,
		optional: text.empty_optional,
		tell: text.empty_tell,
		optionalTell: text.empty_optional_tell,
		values: ["", "é", "\ud800"],
		outside: [],
	},
	{
		name: "lower",
		call: text.lower_call,
		optional: text.lower_optional,
		tell: text.lower_tell,
		optionalTell: text.lower_optional_tell,
		values: ["abc", "éa", "€", "💩", "\ud800", "\udc00"],
		outside: ["", "a", "é"],
	},
	{
		name: "upper",
		call: text.upper_call,
		optional: text.upper_optional,
		tell: text.upper_tell,
		optionalTell: text.upper_optional_tell,
		values: ["", "abcd", "éé", "€", "💩", "\ud800", "\udc00", "a\ud800"],
		outside: ["abcde", "ééa", "💩a", "\ud800\ud800"],
	},
	{
		name: "zero",
		call: text.zero_call,
		optional: text.zero_optional,
		tell: text.zero_tell,
		optionalTell: text.zero_optional_tell,
		values: [""],
		outside: ["a", "\ud800"],
	},
	{
		name: "bounded",
		call: text.bounded_call,
		optional: text.bounded_optional,
		tell: text.bounded_tell,
		optionalTell: text.bounded_optional_tell,
		values: ["a", "é", "€", "💩", "\ud800"],
		outside: ["", "abcde", "ééa"],
	},
	{
		name: "alias",
		call: text.alias_call,
		optional: text.alias_optional,
		tell: text.alias_tell,
		optionalTell: text.alias_optional_tell,
		values: ["a", "é", "€", "💩", "\ud800"],
		outside: ["", "abcde", "ééa"],
	},
];
const encoder = new TextEncoder();
const decoder = new TextDecoder();
function wire(value: string | bigint): string | bigint {
	return typeof value === "string" ? decoder.decode(encoder.encode(value)) : value;
}

async function scalar<T extends string | bigint>(
	profile: HostProfile,
	cases: Case<T>[],
	wrong: Argument[],
): Promise<void> {
	await withPair(profile, async (host, client) => {
		let reply: Argument = null;
		let expected: string | bigint = "";
		let broken = false;
		const counts: number[] = [];
		let prefix = "";
		host.publish("bounds", (verb, args) => {
			assert(verb?.startsWith(`${prefix}_`), "raw scalar selector");
			assert(args.length <= 1 && (verb.includes("optional") || args.length === 1), "raw scalar arity");
			if (args.length) assert(args[0] === expected, "raw scalar category/value");
			counts.push(args.length);
			if (broken) throw new Error("unlisted scalar bounds break");
			return reply;
		});
		const target = await client.fetch("bounds");
		for (const spec of cases) {
			prefix = spec.name;
			for (const value of spec.values) {
				const before = counts.length;
				reply = expected = wire(value);
				assert(await spec.call(client, target, value).observe() === expected, "required scalar value");
				assert(await spec.optional(client, target).observe() === expected, "omitted scalar");
				assert(
					await spec.optional(client, target, value).observe() === expected,
					"present scalar",
				);
				await spec.tell(client, target, value);
				await spec.optionalTell(client, target);
				await spec.optionalTell(client, target, value);
				await spec.optional(client, target).observe();
				assert(counts.slice(before).join() === "1,0,1,1,0,1,0", "required/optional call/tell presence");
			}
			const before = counts.length;
			for (const value of [...wrong, undefined, ...spec.outside]) {
				for (const fn of [spec.call, spec.optional, spec.tell, spec.optionalTell]) {
					let refused = false;
					try {
						Reflect.apply(fn, undefined, [client, target, value]);
					} catch (error) {
						refused = error instanceof TypeError;
					}
					assert(refused, `${prefix}: invalid scalar input admitted`);
				}
			}
			reply = expected = wire(spec.values[0]);
			await spec.optional(client, target).observe();
			assert(counts.length === before + 1, "invalid scalar sent before refusal");
			for (const value of [...wrong, ...spec.outside]) {
				reply = value;
				const pending = spec.optional(client, target);
				const [typed, raw, repeated] = await Promise.allSettled([
					pending.observe(),
					pending.raw.then((v) => v),
					pending.observe(),
				]);
				assert(typed.status === "rejected" && typed.reason instanceof TypeError, "wrong scalar reply accepted");
				assert(
					repeated.status === "rejected" && repeated.reason instanceof TypeError,
					"repeated scalar accepted",
				);
				assert(
					raw.status === "fulfilled" &&
						(value instanceof Sym
							? raw.value instanceof Sym && raw.value.value === value.value
							: Object.is(raw.value, typeof value === "string" ? wire(value) : value)),
					"scalar raw settlement replaced",
				);
			}
			reply = expected = wire(spec.values[0]);
			broken = true;
			const pending = spec.optional(client, target);
			const [typed, raw] = await Promise.allSettled([pending.observe(), pending.raw.then((v) => v)]);
			assert(
				typed.status === "rejected" && raw.status === "rejected" && typed.reason === raw.reason,
				"scalar remote break replaced",
			);
			assert(
				typed.reason instanceof VowBroken && typed.reason.reason === "unlisted scalar bounds break",
				"scalar break cause lost",
			);
			broken = false;
		}
	});
}

async function compounds(profile: HostProfile): Promise<void> {
	await withPair(profile, async (host, client) => {
		let reply: Argument = null;
		host.publish("mixed-bounds", () => reply);
		const target = await client.fetch("mixed-bounds");
		for (const value of [[huge, "💩", [-2n, "€"]], [-huge, "\ud800", [2n, "éa"]]] satisfies Argument[][]) {
			reply = value;
			const pending = mixed.tuple(client, target);
			const [typed, raw] = await Promise.all([pending.observe(), pending.raw.then((v) => v)]);
			assert(typed === raw && typed[0] === value[0], "mixed tuple copied or narrowed integer");
			reply = new Tagged("bounds:mixed", value);
			const record = mixed.record(client, target);
			const [recordValue, rawRecord] = await Promise.all([record.observe(), record.raw.then((v) => v)]);
			assert(recordValue === rawRecord && recordValue.value[0] === value[0], "mixed record copied");
		}
		for (
			const value of [[1, "x", [0n, "abc"]], [huge, "", [0n, "abc"]], [huge, "x", [3n, "abc"]], [huge, "x", [
				0n,
				"é",
			]]]
		) {
			for (const shape of ["tuple", "record"]) {
				reply = shape === "tuple" ? value : new Tagged("bounds:mixed", value);
				const pending = shape === "tuple" ? mixed.tuple(client, target) : mixed.record(client, target);
				const [typed, raw] = await Promise.allSettled([pending.observe(), pending.raw.then((v) => v)]);
				assert(
					typed.status === "rejected" && typed.reason instanceof TypeError && raw.status === "fulfilled",
					"nested bounds/raw outcome",
				);
			}
		}
	});
}

export async function bounds(): Promise<void> {
	for (const profile of ["interop", "glowcap"] satisfies HostProfile[]) {
		await scalar(profile, integerCases, [1, "1", true, null]);
		await scalar(profile, textCases, [1n, 1, true, null, new Sym("text")]);
		await compounds(profile);
	}
}
