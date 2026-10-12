// This page projection names its opened viewer. Retained Rust custody owns
// the saved selection. This object never writes a workspace document.
import type { RoomsControllerSelection } from "../../../lib/rooms_state.ts";

export class ControllerSelection {
	#current: RoomsControllerSelection = { kind: "none" };
	readonly #listeners = new Set<() => void>();
	readonly getSnapshot = (): RoomsControllerSelection => this.#current;
	readonly subscribe = (changed: () => void): () => void => {
		this.#listeners.add(changed);
		return () => this.#listeners.delete(changed);
	};
	set(current: RoomsControllerSelection): void {
		this.#current = current;
		for (const changed of this.#listeners) changed();
	}
}
