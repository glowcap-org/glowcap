/**
 * What a keystroke means inside a modal dialog.
 *
 * A person who has used a computer expects a fixed contract from a dialog:
 * focus moves in when it opens and cannot leave while it is up, Tab cycles
 * the controls and wraps at the ends, Enter takes the default action,
 * Escape dismisses, and focus goes back where it came from. That contract
 * is worth having in one place, because one that holds in some dialogs and
 * not others is worse than none: a person learns to trust it and is then
 * caught out.
 *
 * The decision half lives here as a pure function so it can be read and
 * tested without a browser. The `Dialog` component in `ui/Dialog.tsx` owns
 * the DOM half: reading which element has focus, moving it, and restoring it
 * on close. Every dialog in the app is one of those, which is what makes the
 * contract one promise rather than several.
 */

/** What a dialog should do about one keystroke. Null means "nothing this
 *  layer decides", which leaves the browser's own behavior in place, a
 *  focused button already activates on Enter, and Tab already moves through
 *  the controls everywhere except the two ends. */
export type DialogKeyIntent =
	| { kind: "primary" }
	| { kind: "dismiss" }
	/** Tab ran off an end of the dialog. Put focus back at the other end. */
	| { kind: "wrap-focus"; to: "first" | "last" }
	| null;

export type DialogFocusState = {
	/** Focus sits on the first focusable control in the dialog. */
	atFirst: boolean;
	/** Focus sits on the last one. */
	atLast: boolean;
	/** The focused element acts on Enter by itself. A button, a link, a
	 *  submit input. Enter must not then ALSO fire the default action, or
	 *  pressing it on "Copy detail" would copy and dismiss at once. */
	focusActivates: boolean;
	/** The dialog has somewhere to go when dismissed. An error the app cannot
	 *  continue past has not: Escape on it would leave a broken screen with no
	 *  dialog explaining it, so Escape does nothing there and the dialog says
	 *  so with the only button it offers. */
	dismissible: boolean;
};

export function dialogKeyIntent(
	ev: { key: string; shiftKey: boolean },
	at: DialogFocusState,
): DialogKeyIntent {
	if (ev.key === "Escape") return at.dismissible ? { kind: "dismiss" } : null;
	if (ev.key === "Enter") {
		return at.focusActivates ? null : { kind: "primary" };
	}
	if (ev.key !== "Tab") return null;
	// The wrap is the whole trap: Tab off the last control goes to the first,
	// Shift-Tab off the first goes to the last, and focus never reaches the
	// page behind the dialog.
	if (!ev.shiftKey && at.atLast) return { kind: "wrap-focus", to: "first" };
	if (ev.shiftKey && at.atFirst) return { kind: "wrap-focus", to: "last" };
	return null;
}

/** The elements a dialog's Tab cycle runs over, in document order.
 *
 * Narrow: this app's dialogs hold buttons and nothing else, and
 * a selector that guessed at every focusable thing would quietly include
 * whatever a future dialog puts inside it, including elements that should
 * not be in the cycle. Widen it when a dialog grows a control, not before. */
export const DIALOG_FOCUSABLE_SELECTOR = "button:not([disabled]), [href], input:not([disabled]), " +
	"select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])";
