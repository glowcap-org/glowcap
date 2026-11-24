// Wires the page's foreground and network facts to its link to the session.
import type { ManagedLink } from "./session/managed/link.ts";
import type { PageProjection } from "./store/projection.ts";

/** Tell `link` when the page is seen, returns to the foreground, or gains or
 * loses a network. Each return or network gain wakes it, which probes a live
 * link and dials a lost one now. Returns the stop. */
export function bindLinkToPage(projection: PageProjection, link: ManagedLink): () => void {
	let { visible, returns, online } = projection.get();
	link.visibility(visible);
	link.connectivity(online);
	const stop = projection.subscribe(() => {
		// A closed link has nothing left to hear.
		if (link.state.kind === "closed") return stop();
		const now = projection.get();
		const seen = now.visible !== visible;
		visible = now.visible;
		link.visibility(visible);
		if (now.online !== online) {
			online = now.online;
			link.connectivity(online);
		}
		// A return that changed what is seen already woke the link.
		if (now.returns !== returns) {
			returns = now.returns;
			if (visible && !seen) link.wake();
		}
	});
	return stop;
}
