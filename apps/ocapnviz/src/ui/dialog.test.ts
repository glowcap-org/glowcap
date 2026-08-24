/**
 * The dialog keyboard contract.
 *
 * These are the rules a person expects without being told, so each test is
 * named for the expectation rather than the branch. There is no DOM in this
 * suite; the decision is a pure function precisely so it can be read here,
 * and `ErrorModalView` owns the part that moves real focus.
 */
import { assertEquals } from "@std/assert";
import { type DialogFocusState, dialogKeyIntent } from "./dialog.ts";

/** Focus on a middle control of a dismissible dialog: no wrap due, and the
 *  control acts on Enter itself. */
const middle: DialogFocusState = {
	atFirst: false,
	atLast: false,
	focusActivates: true,
	dismissible: true,
};

const key = (k: string, shiftKey = false) => ({ key: k, shiftKey });

Deno.test("Escape dismisses a dialog that has somewhere to go", () => {
	assertEquals(dialogKeyIntent(key("Escape"), middle), { kind: "dismiss" });
});

Deno.test("Escape does nothing when there is nothing to dismiss to", () => {
	// The error boundary's dialog: the app behind it is broken, so dismissing
	// would leave a person staring at the wreckage with the explanation gone.
	assertEquals(
		dialogKeyIntent(key("Escape"), { ...middle, dismissible: false }),
		null,
	);
});

Deno.test("Enter takes the default action, unless the focused control has one", () => {
	// Focus starts on the primary button, where the browser already activates
	// on Enter; claiming it here too would fire the action twice. Focus on a
	// secondary button belongs to that button.
	assertEquals(dialogKeyIntent(key("Enter"), middle), null);
	assertEquals(
		dialogKeyIntent(key("Enter"), { ...middle, focusActivates: false }),
		{ kind: "primary" },
	);
});

Deno.test("Tab cycles inside the dialog and never leaves it", () => {
	// In the middle of the cycle the browser's own Tab is right, so this layer
	// stays out of the way. At each end it takes over, and the cycle closes.
	assertEquals(dialogKeyIntent(key("Tab"), middle), null);
	assertEquals(dialogKeyIntent(key("Tab", true), middle), null);
	assertEquals(
		dialogKeyIntent(key("Tab"), { ...middle, atLast: true }),
		{ kind: "wrap-focus", to: "first" },
	);
	assertEquals(
		dialogKeyIntent(key("Tab", true), { ...middle, atFirst: true }),
		{ kind: "wrap-focus", to: "last" },
	);
});

Deno.test("Tab off the wrong end of a one-control dialog still wraps to itself", () => {
	// A dialog with a single button is both ends at once. Either direction
	// wraps rather than falling through to the page behind it, which is the
	// whole point of the trap.
	const only: DialogFocusState = { ...middle, atFirst: true, atLast: true };
	assertEquals(dialogKeyIntent(key("Tab"), only), {
		kind: "wrap-focus",
		to: "first",
	});
	assertEquals(dialogKeyIntent(key("Tab", true), only), {
		kind: "wrap-focus",
		to: "last",
	});
});

Deno.test("an ordinary keystroke is left alone", () => {
	for (const k of ["a", " ", "ArrowDown", "Home"]) {
		assertEquals(dialogKeyIntent(key(k), middle), null, k);
	}
});
