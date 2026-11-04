import { UNSUPPORTED_VALUE } from "@glowcap/abi";
import { encodeArgs, readArgArray } from "../abi_value.ts";
import { GlowcapError } from "../errors.ts";
import { ffi } from "../internal/ffi/runtime.ts";
import { type Argument, PSet, PStruct, Tagged } from "../value.ts";
import { assertEquals } from "../../test/assert.ts";

const sparse = () => new Array<Argument>(1);

for (
	const [name, args] of [
		["arguments", sparse()],
		["list", [sparse()]],
		["set", [new PSet(sparse())]],
		["record", [new Tagged("example", sparse())]],
		["struct", [new PStruct(new Array<readonly [string, Argument]>(1))]],
	] satisfies Array<[string, Argument[]]>
) {
	Deno.test(`argument encoding refuses a sparse ${name}`, () => {
		try {
			encodeArgs(args, []);
		} catch (error) {
			if (!(error instanceof GlowcapError)) throw error;
			assertEquals(error.code, UNSUPPORTED_VALUE);
			return;
		}
		throw new Error("sparse slot was encoded instead of refused");
	});
}

Deno.test("argument encoding preserves dense slots including false and void", () => {
	const args: Argument[] = [false, 0n, 0, "", null];
	const keep: Uint8Array[] = [];
	const encoded = encodeArgs(args, keep);
	const decoded = readArgArray(ffi.pointerOf(encoded), BigInt(args.length));
	assertEquals(decoded.length, args.length);
	for (let index = 0; index < args.length; index++) assertEquals(decoded[index], args[index]);
});
