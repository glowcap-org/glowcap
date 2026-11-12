// Presentation-resource cleanup. Rust file holders already settle session closure.
import type { PageProjection } from "../store/projection.ts";
import { noteTrouble } from "../store/trouble.ts";
import { refusalText } from "../../../lib/text/failure.ts";

export function settleViewCleanup(projection: PageProjection, label: string, cleanup: () => void): void {
	try {
		cleanup();
	} catch (error) {
		noteTrouble(projection, label, refusalText(error));
	}
}
