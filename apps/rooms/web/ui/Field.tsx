// One question on a form: its written label, the sentence that qualifies it,
// the control that answers it, and the refusal that answer may have met.
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
		/** The sentence under the label, before the control. */
		hint?: ReactNode;
		/** The refusal the answer met, or empty while it has not. */
		said?: string;
		layout?: "stack" | "inline";
		/** A short answer — a port, a count — takes a short box rather than the
		 * whole line, so the box says how long an answer it expects. */
		width?: "full" | "short";
		/** The control, given what to wire onto itself. */
		children: (wiring: FieldWiring) => ReactNode;
	},
) {
	const hintId = hint === undefined ? undefined : `${id}Hint`;
	const saidId = `${id}Said`;
	const refused = said !== undefined && said !== "";
	const describedBy = [hintId, refused ? saidId : undefined].filter(Boolean).join(" ") || undefined;
	return (
		<div
			className="field-stack"
			data-layout={layout === "inline" ? "inline" : undefined}
			data-width={width === "short" ? "short" : undefined}
		>
			<label className="field-label" htmlFor={id}>
				{label}
				{optional !== undefined && <span className="optional">{optional}</span>}
			</label>
			{children({ id, describedBy, invalid: refused ? true : undefined })}
			{hint !== undefined && <p className="hint" id={hintId}>{hint}</p>}
			{refused && <Said id={saidId} kind="failure">{said}</Said>}
		</div>
	);
}
