// Presentation-resource cleanup. Rust file holders already settle session closure.
import type { PageProjection } from "../store/core.ts";
import { noteTrouble } from "../store/trouble.ts";

export function settleViewCleanup(projection: PageProjection, label: string, cleanup: () => void): void {
	try {
		cleanup();
	} catch (error) {
		noteTrouble(projection, label, error instanceof Error ? error.message : String(error));
	}
}
