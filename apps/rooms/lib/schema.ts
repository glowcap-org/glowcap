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
