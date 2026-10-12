// One rail section: a label, an optional "+" field, and the rows.
//
// The two sections differ only in what they are called and what they list, so
// this is one component used twice. What it does not own is the field itself:
// that is `NamePanel`, so the panel a section holds and the panel's own rules
// about being open stay two subjects rather than one file.

import { type ReactNode, useRef } from "react";
import { AddButton, type AddField, NamePanel } from "./NamePanel.tsx";

/** One section of the rail.
 *
 * The field sits *after* the label rather than inside it, which the stylesheet
 * depends on: the label is a flex row, and a field inside it would land beside
 * the "+" instead of below it. */
export function RailSection(
	{ className, title, listId, heading, field, children }: {
		className?: string;
		title: string;
		listId: string;
		/** A control standing in for the plain label, given this section's title
		 * to draw and the head it stands in. A section says what it is called.
		 * Whether those words are also something to press belongs to whoever
		 * hands one in. The head is for a control whose panel spans the section
		 * rather than the words, so it can measure against the line it labels. */
		heading?: (title: string, head: { current: HTMLDivElement | null }) => ReactNode;
		/** This section's own "+" and the field under it, when it has one. Where
		 * what is named there lands is stated on the field, so one field answers
		 * for the list however many directories this tab holds. */
		field?: AddField;
		children: ReactNode;
	},
) {
	const head = useRef<HTMLDivElement>(null);
	return (
		<div className={className ? "section " + className : "section"}>
			<div className="section-head overline" ref={head}>
				{heading === undefined ? <span>{title}</span> : heading(title, head)}
				{field !== undefined && (
					<AddButton
						id={field.id}
						label={field.label}
						open={field.open}
						canAdd={field.canAdd}
						onOpen={field.onOpen}
					/>
				)}
			</div>
			{field !== undefined && <NamePanel {...field} />}
			<ul id={listId}>{children}</ul>
		</div>
	);
}
