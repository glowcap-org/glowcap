// The glowcap mark, live: a shader mushroom standing in a box the size the
// caller asks for, with its light hanging around it.
//
// The box is the mushroom; the light reaches past it, so whatever holds the
// mark leaves its overflow visible. The control around the mark carries the
// accessible name: the mark itself is decoration and says so.

import { useEffect, useRef } from "react";
import type { MarkLive, MarkPlay } from "./mark_gpu_live.ts";

/** How the mark plays in a component: `arrive` runs the whole cycle once and
 * is a lockup afterwards, for the screen a person lands on; `stand` is a
 * lockup's, lit from the start; `unlit` is a control's, dark until the pointer
 * reaches the control and lit while it is there. The opening screen's loop is
 * not here, because it belongs to the boot markup rather than to a component. */
export type MarkStance = Exclude<MarkPlay, "loop">;

export function Mark({ size, play = "stand" }: { size: number; play?: MarkStance }) {
	const host = useRef<HTMLSpanElement>(null);
	useEffect(() => {
		const el = host.current;
		if (el === null) return;
		let gone = false;
		let live: MarkLive | null = null;
		// The shader and its driver are their own chunk, fetched when the first
		// mark mounts, so the page's own bytes never wait on a mushroom.
		void import("./mark_gpu_live.ts").then((m) => m.start(el, play)).then((mark) => {
			if (mark === null) return;
			if (gone) {
				mark.stop();
				return;
			}
			live = mark;
		}).catch(() => {
			// best-effort: a chunk that will not load leaves the mark's box
			// empty. The control around it keeps its name and its action, and
			// the page has nothing to say about a decoration it cannot draw.
		});
		return () => {
			gone = true;
			live?.stop();
		};
	}, [play]);
	return <span ref={host} className="icon-svg mark-live" style={{ width: size, height: size }} aria-hidden="true" />;
}
