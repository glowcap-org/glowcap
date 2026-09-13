// Shared schema primitives for bounded Rooms documents and JSON DTOs.

import * as z from "zod/mini";

export const boundedText = (max: number) => z.string().check(z.maxLength(max));

export const nonemptyText = (max: number) => boundedText(max).check(z.minLength(1));

export const nonnegativeSafeInteger = z.int().check(z.gte(0));

export const positiveSafeInteger = z.int().check(z.gte(1));

export const fixedHex = (bytes: number) =>
	z.string().check(
		z.length(bytes * 2),
		z.regex(/^[0-9a-f]+$/),
	);

/** Exact natural counts and IDs at the Rooms wire boundary. */
export const naturalWireNumber = z.pipe(
	z.bigint().check(z.gte(0n), z.lte(BigInt(Number.MAX_SAFE_INTEGER))),
	z.transform((value) => Number(value)),
);
