// One question on a form: its written label, the refusal its answer met, the
// control that answers it, and the sentence that qualifies it.
//
// Above the control goes what the reader must act on, below it what only
// informs; the README beside this file argues why. Every field-level refusal
// on the page comes through here, so this one return is where that order
// lives.
//
// The control is the caller's, because a field is a text input on one line, a
// select on the next, a textarea or a file picker on the one after, and each
// carries attributes that belong to what it asks (a locator turns off the
// keyboard's corrections; a port takes numbers). What is not the caller's is
// the wiring around it. A label has to name the control by id, a hint has to
// be announced with it, a refusal has to be too and has to mark the control
// invalid, and every form here used to do some of that and forget the rest.
// This does all of it from three strings.
//
// `inline` lays the name to the left of the control for a short list of knobs
// that would read as a form three times taller stacked; the name column is one
// width for the whole list, so the fields line up down it (`--field-name-w`).

import type { ReactNode } from "react";
import { Said } from "./Said.tsx";

export interface FieldWiring {
	id: string;
	/** The ids the control should announce with itself, or undefined when
	 * nothing qualifies it. */
	describedBy: string | undefined;
	/** The control did not take the value; wired straight onto `aria-invalid`. */
	invalid: true | undefined;
}

export function Field(
	{ id, label, optional, hint, said, layout, width, children }: {
		/** The control's own id, which the label names. */
		id: string;
		label: ReactNode;
		/** Said beside the label for a question that may go unanswered. */
		optional?: string;
		/** The sentence under the control. */
		hint?: ReactNode;
		/** The refusal the answer met, drawn above the control, or empty while
		 * it has not met one. It takes a node because a refusal may carry the
		 * way out with it, such as the name to use instead. */
		said?: ReactNode;
		layout?: "stack" | "inline";
		/** How long an answer this expects, said by the box: a port or a count is
		 * short, an address is medium, and prose takes the whole line. */
		width?: "full" | "medium" | "short";
		/** The control, given what to wire onto itself. */
		children: (wiring: FieldWiring) => ReactNode;
	},
) {
	const hintId = hint === undefined ? undefined : `${id}Hint`;
	const saidId = `${id}Said`;
	const refused = said != null && said !== "";
	// Announced in the order they are seen.
	const describedBy = [refused ? saidId : undefined, hintId].filter(Boolean).join(" ") || undefined;
	return (
		<div
			className="field-stack"
			data-layout={layout === "inline" ? "inline" : undefined}
			data-width={width === undefined || width === "full" ? undefined : width}
		>
			<label className="field-label" htmlFor={id}>
				{label}
				{optional !== undefined && <span className="optional">{optional}</span>}
			</label>
			{refused && <Said id={saidId} kind="failure">{said}</Said>}
			{children({ id, describedBy, invalid: refused ? true : undefined })}
			{hint !== undefined && <p className="hint" id={hintId}>{hint}</p>}
		</div>
	);
}
