// A row of tabs over panels that take turns, with the sliding thumb behind
// the chosen one.
//
// Settings draws this control wherever several panels take turns. The ARIA
// pattern and keyboard walking live here rather than in each dialog that uses
// it, so focus and the sliding thumb cannot drift apart.
//
// Walking with the arrows moves focus onto the tab it lands on, so a keyboard
// reader hears where they are. Clicking one leaves focus
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
		/** The chosen tab, or null while none of these is the one on screen. */
		selected: T | null;
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

	// -1 while nothing is chosen: the thumb hides on it, and focus enters at
	// the first tab.
	const at = tabs.findIndex((tab) => tab.id === selected);
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
					go(Math.max(0, at === -1 ? 0 : at - 1));
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
					tabIndex={tab.id === selected || (selected === null && tab === tabs[0]) ? 0 : -1}
					onClick={() => onSelect(tab.id)}
				>
					{tab.label}
				</button>
			))}
		</div>
	);
}
