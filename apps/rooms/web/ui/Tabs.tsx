// A row of tabs over panels that take turns, with the sliding thumb behind
// the chosen one.
//
// Settings and Operations both draw one. They had a tab bar each, identical
// down to the arrow walking and the thumb's index, which is two places to fix
// a keyboard bug and two places for the markup to drift apart. The shape is
// the same because the ARIA pattern is the same, so it is one component and
// the callers differ only in which tabs they hand it.
//
// Walking with the arrows moves focus onto the tab it lands on, which is what
// makes a keyboard reader hear where they are; clicking one leaves focus
// where the pointer put it. That distinction lives here rather than in each
// caller, because it belongs to the pattern rather than to either screen.

import { useLayoutEffect, useRef } from "react";
import type { RefObject } from "react";

/** One tab, and the panel it speaks for. */
export interface TabFace<T extends string> {
	/** What the caller calls this tab. */
	readonly id: T;
	/** The button's own DOM id, which the browser proofs press. */
	readonly domId: string;
	/** The tab's word. */
	readonly label: string;
	/** The panel this tab controls, named while it is the chosen one. */
	readonly panelId: string;
}

export function Tabs<T extends string>(
	{ id, className, tabs, selected, labelledBy, chosenRef, onSelect }: {
		/** The tablist's own id, where a proof looks for the bar itself. */
		id?: string;
		/** Anything the caller styles the bar by, beyond the shared look. */
		className?: string;
		tabs: readonly TabFace<T>[];
		selected: T;
		/** What names the set of tabs, usually the dialog's title. */
		labelledBy: string;
		/** The chosen tab's button, for a dialog that opens focus onto it. */
		chosenRef?: RefObject<HTMLButtonElement | null>;
		onSelect: (next: T) => void;
	},
) {
	// Whether the last selection came from an arrow, so focus follows it.
	const walked = useRef(false);
	const own = useRef<HTMLButtonElement>(null);
	const chosen = chosenRef ?? own;
	useLayoutEffect(() => {
		if (!walked.current) return;
		walked.current = false;
		chosen.current?.focus();
	}, [selected, chosen]);

	const at = Math.max(0, tabs.findIndex((tab) => tab.id === selected));
	return (
		<div
			id={id}
			className={className === undefined ? "tabs" : `tabs ${className}`}
			data-count={String(tabs.length)}
			data-thumb={String(at)}
			role="tablist"
			aria-labelledby={labelledBy}
			onKeyDown={(event) => {
				const go = (next: number) => {
					event.preventDefault();
					walked.current = true;
					onSelect(tabs[next].id);
				};
				if (event.key === "Home") go(0);
				else if (event.key === "End") go(tabs.length - 1);
				else if (event.key === "ArrowRight" || event.key === "ArrowDown") {
					go(Math.min(tabs.length - 1, at + 1));
				} else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
					go(Math.max(0, at - 1));
				}
			}}
		>
			<span className="tabs-thumb" aria-hidden="true" />
			{tabs.map((tab) => (
				<button
					key={tab.id}
					ref={tab.id === selected ? chosen : undefined}
					id={tab.domId}
					type="button"
					className="tab"
					role="tab"
					aria-selected={tab.id === selected}
					aria-controls={tab.id === selected ? tab.panelId : undefined}
					tabIndex={tab.id === selected ? 0 : -1}
					onClick={() => onSelect(tab.id)}
				>
					{tab.label}
				</button>
			))}
		</div>
	);
}
