// Translate only the parser's typed input refusal into an ordinary form error.
// Runtime, archive, and Wasm failures remain failures: calling valid input
// malformed would hide the broken component and ask the reader to retry it.

import { INVALID_ARGUMENT } from "@pancake/abi";
import { PancakeError } from "@pancake/runtime";

export function invalidArgumentOrThrow(error: unknown): null {
	if (error instanceof PancakeError && error.code === INVALID_ARGUMENT) return null;
	throw error;
}
