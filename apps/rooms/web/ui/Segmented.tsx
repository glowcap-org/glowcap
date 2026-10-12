// A closed set of answers on one track, each of which can be turned on or off.
//
// The tab bar next door answers "which one of these am I looking at" and slides
// a single thumb between panels that take turns. This answers "which of these
// do I want", where any number can be in force at once and turning one off
// changes nothing else. Same well and the same raised cell, and a mark in each
// cell that is on, because a control where two answers can be chosen has to say
// so cell by cell rather than by where a thumb has come to rest.
//
// A chosen cell is washed, inked and outlined in the accent while the cells
// beside it are none of those. It draws no tick: a mark that is there
// whenever a cell is on says nothing the cell has not already said, and it cost
// a reserved column in every cell to keep the words from moving when one came
// or went.
//
// It is compact. A row of cells is what you reach for when the
// answers have to sit on one line beside something else. Anywhere with room to
// spare wants a column of checkboxes instead, which reads better and needs no
// track. Sized past that and it stops being the thing it is for.

import type { ComponentPropsWithRef, ReactNode } from "react";

/** One answer this control offers. */
export interface SegmentedChoice {
	/** The value a press reports back. */
	value: string;
	/** What the cell draws. Anything a caller wants to put there, which is how
	 * an answer gets an icon without this control knowing what an icon is: a
	 * surface that wants one passes it beside the words, and one that does not
	 * passes the words. Icons in this page are drawn `aria-hidden`, so a label
	 * built that way still announces as its text. */
	label: ReactNode;
	/** What a reader is told, when what is drawn will not tell them. Only needed
	 * for a cell whose label carries no words of its own. */
	said?: string;
}

// `onToggle` is dropped from the element's own props as well as taken here: a
// `<div>` already has one, for the disclosure element's toggle event, and left
// in place the two names collide into a handler that is asked to be both.
export type SegmentedProps = Omit<ComponentPropsWithRef<"div">, "role" | "children" | "onToggle"> & {
	choices: readonly SegmentedChoice[];
	/** The answers in force. Held by the caller, because what a set of answers
	 * means is the caller's question and never this control's. */
	chosen: ReadonlySet<string>;
	onToggle: (value: string) => void;
	/** None of the answers is on offer. Stated once for the whole set rather
	 * than per answer: a set where some cells could be pressed and others could
	 * not is two controls sharing a track. */
	disabled?: boolean;
};

export function Segmented({ choices, chosen, onToggle, disabled, className, ...group }: SegmentedProps) {
	return (
		<div
			{...group}
			role="group"
			className={["segmented", className].filter(Boolean).join(" ")}
			data-count={String(choices.length)}
		>
			{choices.map((choice) => {
				const on = chosen.has(choice.value);
				return (
					<button
						key={choice.value}
						type="button"
						className="segment"
						aria-pressed={on}
						disabled={disabled}
						aria-label={choice.said}
						onClick={() => onToggle(choice.value)}
					>
						<span className="segment-said">{choice.label}</span>
					</button>
				);
			})}
		</div>
	);
}
