// Translate only the parser's typed input refusal into an ordinary form error.
// Runtime, archive, and Wasm failures remain failures: calling valid input
// malformed would hide the broken component and ask the reader to retry it.

import { INVALID_ARGUMENT } from "@glowcap/abi";
import { GlowcapError } from "@glowcap/runtime";

export function invalidArgumentOrThrow(error: unknown): null {
	if (error instanceof GlowcapError && error.code === INVALID_ARGUMENT) return null;
	throw error;
}
