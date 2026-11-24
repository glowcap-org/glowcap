// Wires the page's foreground and network facts to its link to the session.
import type { ManagedLink } from "./link.ts";
import type { PageProjection } from "../../store/projection.ts";

/** Tell `link` when the page is seen, returns to the foreground, or gains or
 * loses a network. Each return or network gain wakes it, which probes a live
 * link and dials a lost one now. Returns the stop, which the page calls when
 * its session closes. */
export function bindLinkToPage(projection: PageProjection, link: ManagedLink): () => void {
	let { visible, returns, online } = projection.get();
	link.visibility(visible);
	link.connectivity(online);
	return projection.subscribe(() => {
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
}
