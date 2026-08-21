// The lifecycle of an operations capability: take it, drop it, ask it again.
//
// Three capabilities, and four places used to name them one at a time. The
// take modal picked a verb by capability name, the drop mapped a name to a
// function, the modal refreshed two of them by hand, and each pane wired its
// own asking. Four switches over one fact drift, which is the same reason
// `ops/catalog.ts` next door holds the words in one table; this is that
// table's other half, and the page above reaches all three capabilities
// through it rather than through any one of them.
//
// The visualizer has no refresh because it has nothing to ask: its pane draws
// this tab's own publishing socket, which the store already knows about.

import type { OpsCap } from "../types.ts";
import { dropDiagnosticCap, refreshDiagnostics, takeDiagnosticCap } from "./diagnostics.ts";
import { dropListenersCap, refreshListeners, takeListenersCap } from "./listeners.ts";
import { dropVizCap, takeVizCap } from "./viz.ts";

interface OpsVerbs {
	/** Redeem `pasted` for this capability, empty when the tab now holds it
	 * and the reason it would not take otherwise. `remember` is the reader's
	 * current word on keeping the swiss in this browser. */
	readonly take: (pasted: string, remember?: boolean) => Promise<string>;
	/** Let it go, swiss and all. */
	readonly drop: () => void;
	/** Ask the capability in hand to say again what it holds, where there is
	 * something to ask. */
	readonly refresh?: () => Promise<void>;
}

const VERBS: Record<OpsCap, OpsVerbs> = {
	listeners: { take: takeListenersCap, drop: dropListenersCap, refresh: refreshListeners },
	diagnostics: { take: takeDiagnosticCap, drop: dropDiagnosticCap, refresh: refreshDiagnostics },
	viz: { take: takeVizCap, drop: dropVizCap },
};

export function takeOpsCap(cap: OpsCap, pasted: string, remember = false): Promise<string> {
	return VERBS[cap].take(pasted, remember);
}

export function dropOpsCap(cap: OpsCap): void {
	VERBS[cap].drop();
}

/** Ask `cap` again, or do nothing where it has nothing to ask. */
export async function refreshOpsCap(cap: OpsCap): Promise<void> {
	await VERBS[cap].refresh?.();
}
