/**
 * Is a key event aimed at a surface the user is typing into?
 *
 * Three keyboard pipelines need the same answer — the global key
 * authority, the pointer FSM's Space bridge, and the timeline's own
 * verbs all step aside while text is being edited — so the question
 * is answered once here instead of once per listener.
 */

/** True when `target` is a focusable text surface: an `<input>`, a
 *  `<textarea>`, or any element with `contenteditable`. */
export function isTextInputTarget(target: EventTarget | null): boolean {
	const el = target as HTMLElement | null;
	return el?.tagName === "INPUT" || el?.tagName === "TEXTAREA" ||
		el?.isContentEditable === true;
}
