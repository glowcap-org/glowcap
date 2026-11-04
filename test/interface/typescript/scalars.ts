// Raw behaviors check scalar tags independently of the generated description.
import { type Argument, type HostProfile, Sym, VowBroken } from "@glowcap/runtime";
import * as g from "../generated/scalars.ts";
import { assert, withPair } from "./pair.ts";

type Scalar = boolean | Uint8Array | Sym | number | Error;
type Observation = { observe(): Promise<Scalar> };
export async function scalars(): Promise<void> {
	for (const profile of ["interop", "glowcap"] satisfies HostProfile[]) {
		await withPair(profile, async (host, client) => {
			let outcome: "value" | "wrong" | "broken" = "value";
			let floating = -0;
			let bounded = new Uint8Array([0, 255]);
			const calls: { verb: string; count: number }[] = [];
			function expected(kind: string): Scalar {
				switch (kind) {
					case "bool":
						return true;
					case "bytes":
						return new Uint8Array();
					case "bounded":
						return bounded;
					case "symbol":
						return new Sym("scalar-λ");
					case "float":
						return floating;
					case "error":
						return new Error("fulfilled error data");
					default:
						throw new Error("unknown scalar");
				}
			}
			function equal(actual: Argument, wanted: Scalar): void {
				if (wanted instanceof Uint8Array) {
					assert(
						actual instanceof Uint8Array && actual.length === wanted.length &&
							actual.every((v, i) => v === wanted[i]),
						"byte category/value",
					);
				} else if (wanted instanceof Sym) {
					assert(actual instanceof Sym && actual.value === wanted.value, "symbol category/value");
				} else if (wanted instanceof Error) {
					assert(
						actual instanceof Error && actual.message === wanted.message,
						"fulfilled error category/value",
					);
				} else assert(Object.is(actual, wanted), "scalar category/value");
			}
			host.publish("scalars", (verb, args) => {
				assert(verb !== null, "named scalar method");
				const kind = verb.slice(0, verb.indexOf("_"));
				assert(args.length <= 1 && (verb.includes("optional") || args.length === 1), "scalar arity");
				const value = expected(kind);
				if (args.length) equal(args[0], value);
				calls.push({ verb, count: args.length });
				if (outcome === "broken") throw new Error("unlisted scalar break");
				if (outcome === "wrong") return kind === "float" ? 1n : "wrong scalar category";
				return value;
			});
			const target = await client.fetch("scalars");
			async function exercise(
				call: () => Observation,
				absent: () => Observation,
				present: () => Observation,
				tell: () => Promise<void>,
				absentTell: () => Promise<void>,
				presentTell: () => Promise<void>,
				wanted: Scalar,
			): Promise<void> {
				equal(await call().observe(), wanted);
				equal(await absent().observe(), wanted);
				assert(calls[calls.length - 1].count === 0, "omitted scalar argument");
				equal(await present().observe(), wanted);
				assert(calls[calls.length - 1].count === 1, "present scalar argument");
				await tell();
				await absentTell();
				await presentTell();
				await g.bool_call(client, target, true).observe();
				assert(calls[calls.length - 3].count === 0 && calls[calls.length - 2].count === 1, "tell presence");
				outcome = "wrong";
				let wrong = false;
				try {
					await call().observe();
				} catch (error) {
					wrong = error instanceof TypeError;
				}
				assert(wrong, "wrong scalar fulfillment accepted");
				outcome = "broken";
				let broken: unknown;
				try {
					await call().observe();
				} catch (error) {
					broken = error;
				}
				assert(
					broken instanceof VowBroken && broken.reason === "unlisted scalar break",
					"scalar break changed",
				);
				outcome = "value";
			}
			await exercise(
				() => g.bool_call(client, target, true),
				() => g.bool_optional(client, target),
				() => g.bool_optional(client, target, true),
				() => g.bool_tell(client, target, true),
				() => g.bool_optional_tell(client, target),
				() => g.bool_optional_tell(client, target, true),
				true,
			);
			await exercise(
				() => g.bytes_call(client, target, new Uint8Array()),
				() => g.bytes_optional(client, target),
				() => g.bytes_optional(client, target, new Uint8Array()),
				() => g.bytes_tell(client, target, new Uint8Array()),
				() => g.bytes_optional_tell(client, target),
				() => g.bytes_optional_tell(client, target, new Uint8Array()),
				new Uint8Array(),
			);
			await exercise(
				() => g.bounded_call(client, target, bounded),
				() => g.bounded_optional(client, target),
				() => g.bounded_optional(client, target, bounded),
				() => g.bounded_tell(client, target, bounded),
				() => g.bounded_optional_tell(client, target),
				() => g.bounded_optional_tell(client, target, bounded),
				bounded,
			);
			await exercise(
				() => g.symbol_call(client, target, new Sym("scalar-λ")),
				() => g.symbol_optional(client, target),
				() => g.symbol_optional(client, target, new Sym("scalar-λ")),
				() => g.symbol_tell(client, target, new Sym("scalar-λ")),
				() => g.symbol_optional_tell(client, target),
				() => g.symbol_optional_tell(client, target, new Sym("scalar-λ")),
				new Sym("scalar-λ"),
			);
			await exercise(
				() => g.float_call(client, target, -0),
				() => g.float_optional(client, target),
				() => g.float_optional(client, target, -0),
				() => g.float_tell(client, target, -0),
				() => g.float_optional_tell(client, target),
				() => g.float_optional_tell(client, target, -0),
				-0,
			);
			await exercise(
				() => g.error_call(client, target, new Error("fulfilled error data")),
				() => g.error_optional(client, target),
				() => g.error_optional(client, target, new Error("fulfilled error data")),
				() => g.error_tell(client, target, new Error("fulfilled error data")),
				() => g.error_optional_tell(client, target),
				() => g.error_optional_tell(client, target, new Error("fulfilled error data")),
				new Error("fulfilled error data"),
			);
			for (const value of [0, Number.MIN_VALUE, Number.MAX_VALUE, Infinity, -Infinity, NaN]) {
				floating = value;
				assert(Object.is(await g.float_call(client, target, value).observe(), value), "float edge changed");
			}
			for (const value of [new Uint8Array([1]), new Uint8Array([0, 1, 2, 255])]) {
				bounded = value;
				equal(await g.bounded_call(client, target, value).observe(), value);
			}
			const bytes = g.bounded_call(client, target, bounded);
			const raw = bytes.raw.then((value) => value);
			assert(await bytes.observe() === await raw, "byte observation added a copy");
			const errorData = g.error_call(client, target, new Error("fulfilled error data"));
			const rawError = errorData.raw.then((value) => value);
			assert(await errorData.observe() === await rawError, "error observation changed data identity");
			const before = calls.length;
			for (
				const [fn, values] of [
					[g.bool_call, [1]],
					[g.bool_tell, [false, true]],
					[g.bytes_call, [new Uint16Array([1])]],
					[g.bytes_optional, [undefined]],
					[g.bounded_call, [new Uint8Array()]],
					[g.bounded_call, [new Uint8Array(5)]],
					[g.bounded_optional, [new Uint8Array(5)]],
					[g.bounded_optional, [new Uint8Array()]],
					[g.bounded_tell, [new Uint8Array()]],
					[g.bounded_tell, [new Uint8Array(5)]],
					[g.bounded_optional_tell, [new Uint8Array(5)]],
					[g.bounded_optional_tell, [new Uint8Array()]],
					[g.symbol_call, ["scalar-λ"]],
					[g.symbol_tell, ["scalar-λ"]],
					[g.float_call, [1n]],
					[g.float_tell, ["1"]],
					[g.error_call, ["fulfilled error data"]],
					[g.error_tell, ["fulfilled error data"]],
				] satisfies [(...args: never[]) => unknown, unknown[]][]
			) {
				let refused = false;
				try {
					Reflect.apply(fn, undefined, [client, target, ...values]);
				} catch (error) {
					refused = error instanceof TypeError;
				}
				assert(refused, "invalid scalar argument did not refuse locally");
			}
			await g.bool_call(client, target, true).observe();
			assert(calls.length === before + 1, "invalid scalar argument sent");
			for (const value of [new Uint8Array(), new Uint8Array(5)]) {
				bounded = value;
				let length = false;
				try {
					await g.bounded_optional(client, target).observe();
				} catch (error) {
					length = error instanceof TypeError;
				}
				assert(length, "out-of-bounds byte reply accepted");
			}
		});
	}
}
