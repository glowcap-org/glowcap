import { OK } from "@glowcap/abi";
import { GlowcapError } from "../errors.ts";
import { outUsize } from "../internal/seam.ts";

const ERROR_BYTES = 257;
const decoder = new TextDecoder();

type DiagnosedCall = (
	outError: Uint8Array,
	errorCap: bigint,
	outErrorLen: Uint8Array,
) => Promise<number>;

/** Caller-owned storage that brings one worker thread's native diagnostic back
 * with the status it describes. Reuse one slot only behind `SingleFlight`;
 * concurrent operations need distinct slots. */
export class NativeDiagnostic {
	readonly #family: string;
	readonly #bytes = new Uint8Array(ERROR_BYTES);
	readonly #length = new Uint8Array(8);

	constructor(family: string) {
		this.#family = family;
	}

	async check(operation: string, call: DiagnosedCall): Promise<void> {
		this.#length.fill(0);
		const code = await call(this.#bytes, BigInt(this.#bytes.length), this.#length);
		if (code === OK) return;

		const reported = Number(outUsize(this.#length));
		const copied = Math.min(reported, this.#bytes.length - 1);
		const detail = copied === 0
			? `${operation}: ${this.#family} transport call failed (code ${code})`
			: decoder.decode(this.#bytes.subarray(0, copied));
		throw new GlowcapError(code, detail);
	}
}

/** Diagnose one call that may overlap sibling operations and therefore cannot
 * borrow a reusable per-direction slot. */
export function checkDiagnosedCall(
	family: string,
	operation: string,
	call: DiagnosedCall,
): Promise<void> {
	return new NativeDiagnostic(family).check(operation, call);
}
