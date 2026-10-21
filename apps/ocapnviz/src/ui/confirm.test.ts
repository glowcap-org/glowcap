/**
 * The question channel a destructive act asks through.
 *
 * Four claims, each of which the browser's own `confirm` gave for free and this
 * has to earn back, and each of which is silent when broken:
 *
 *   1. The answer reaches the caller. A guard whose promise never settles leaves
 *      the act neither done nor refused, and the button just stops working.
 *   2. Answering twice does not answer twice. Escape and a click on the same
 *      button can both fire, and the second must be nothing.
 *   3. A second question does not stack. `confirm` was synchronous so this could
 *      not arise. A promise can, and the safe answer for a guard is no.
 *   4. Listeners are woken when the question appears and when it goes, because a
 *      dialog that stayed up after being answered would hold the app inert.
 *
 * Validated by injection: dropping the identity check in `answer` fails the
 * double-answer case, and resolving a stacked request against the live row fails
 * the third.
 */

import { assert, assertEquals } from "@std/assert";
import {
	_resetConfirmForTesting,
	type ConfirmRequest,
	currentConfirm,
	requestConfirm,
	subscribeConfirm,
} from "./confirm.ts";

const ASK: ConfirmRequest = {
	title: "Discard every edit?",
	detail: "This cannot be undone.",
	confirmLabel: "Discard all",
};

Deno.test("the answer reaches the caller, both ways", async () => {
	_resetConfirmForTesting();
	const yes = requestConfirm(ASK);
	currentConfirm()?.answer(true);
	assertEquals(await yes, true);

	const no = requestConfirm(ASK);
	currentConfirm()?.answer(false);
	assertEquals(await no, false);
});

Deno.test("the question is on the channel before the caller awaits", () => {
	// What lets a caller read as it did with `confirm`: the request is registered
	// synchronously, so the dialog has something to draw on the same tick the
	// reader clicked. A channel that published on a microtask would render a frame
	// with the act already in flight and nothing on screen about it.
	_resetConfirmForTesting();
	const answered = requestConfirm(ASK);
	const asked = currentConfirm();
	assert(asked !== null, "the question had not arrived yet");
	assertEquals(asked.title, ASK.title);
	assertEquals(asked.confirmLabel, ASK.confirmLabel);
	asked.answer(false);
	return answered.then(() => {});
});

Deno.test("the question is one object while it waits", async () => {
	// `useSyncExternalStore` compares snapshots by identity, so a fresh object per
	// read would re-render the dialog on every unrelated render of the app.
	_resetConfirmForTesting();
	const answered = requestConfirm(ASK);
	const first = currentConfirm();
	assert(first !== null);
	assert(currentConfirm() === first, "reading it twice built two of them");
	first.answer(false);
	assertEquals(currentConfirm(), null, "it stayed up after being answered");
	await answered;
});

Deno.test("answering twice answers once", async () => {
	// Escape and a click on Cancel can both land. The second must be nothing, or
	// it clears a question that is no longer its own. status-allow: lifecycle transition
	_resetConfirmForTesting();
	const answered = requestConfirm(ASK);
	const asked = currentConfirm();
	assert(asked !== null);
	asked.answer(true);
	asked.answer(false);
	assertEquals(await answered, true, "the second answer changed the first");

	// And a stale handle cannot clear the question that replaced it.
	const next = requestConfirm(ASK);
	asked.answer(false);
	assert(
		currentConfirm() !== null,
		"a stale answer cleared the live question",
	);
	currentConfirm()?.answer(true);
	assertEquals(await next, true);
});

Deno.test("a second question while one is up is refused, not queued", async () => {
	// Unreachable through the UI, the dialog marks the rest of the app inert and
	// swallows keystrokes, so this pins the answer for the case that is a caller
	// bug: refuse, because the act not happening is the safe outcome for a guard,
	// and nobody is asked two questions at once.
	_resetConfirmForTesting();
	const first = requestConfirm(ASK);
	const second = requestConfirm({ ...ASK, title: "Something else?" });
	assertEquals(await second, false, "the second question was not refused");
	assertEquals(
		currentConfirm()?.title,
		ASK.title,
		"the second question replaced the one on screen",
	);
	currentConfirm()?.answer(true);
	assertEquals(await first, true);
});

Deno.test("listeners wake when the question appears and when it goes", async () => {
	_resetConfirmForTesting();
	let woken = 0;
	const stop = subscribeConfirm(() => {
		woken++;
	});
	const answered = requestConfirm(ASK);
	assertEquals(woken, 1, "nothing woke when the question arrived");
	currentConfirm()?.answer(false);
	assertEquals(woken, 2, "nothing woke when the question went");
	await answered;
	stop();
	const next = requestConfirm(ASK);
	assertEquals(woken, 2, "a detached listener still woke");
	currentConfirm()?.answer(false);
	await next;
});
