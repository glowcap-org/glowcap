// A count that changes while its reader watches: the new figure rolls in from
// the side the count moved toward. A figure drawn for somewhere else, as when
// the reader opens another room, is simply drawn. So is a figure that stays
// as it is while its count changes, as a capped "99+" does.

import { useLayoutEffect, useRef } from "react";
import { still, TRAVEL } from "./motion.ts";

export function RollingCount(
	{ count, said, of }: {
		count: number;
		/** What to draw when it is not the bare figure. */
		said?: string;
		/** What is being counted. A change of subject is not a change of count. */
		of: string;
	},
) {
	const figure = useRef<HTMLSpanElement>(null);
	const drawn = said ?? String(count);
	const last = useRef({ count, drawn, of });
	useLayoutEffect(() => {
		const was = last.current;
		last.current = { count, drawn, of };
		if (was.of !== of || was.drawn === drawn || figure.current == null || still()) return;
		const from = count > was.count ? "55%" : "-55%";
		figure.current.animate(
			[{ transform: `translateY(${from})`, opacity: 0 }, { transform: "translateY(0)", opacity: 1 }],
			TRAVEL,
		);
	}, [count, drawn, of]);
	return <span ref={figure} className="rolling-count">{drawn}</span>;
}
