/**
 * What a Tools-pane command offers, and when.
 *
 * Three rules the button holds, each invisible until it is wrong, so
 * they are read off the element itself. Outside Build there is nothing
 * to render, because Build is the mode that holds mutation authority.
 * With nothing to do the button stays put and inert, saying why,
 * rather than disappearing and taking the reader's knowledge that the
 * command exists with it. And a command that cannot be taken back asks
 * before it runs, while one that can does not — the difference between
 * "Discard all" and its two neighbours.
 *
 * Neither the button nor the row has hooks, so both can be called as
 * the plain functions they are. Asking is the app's own dialog rather than the
 * browser's, so a click is two parts with the reader's answer in between, and
 * these drive that channel directly (`ui/confirm.ts`).
 */

import { assert, assertEquals } from "@std/assert";
import { ToolCommandButton, ToolCommandRow } from "./ToolCommands.tsx";
import { _resetConfirmForTesting, type ConfirmRequest, currentConfirm } from "./confirm.ts";

type Command = {
	ran: number;
	el: ReturnType<typeof ToolCommandButton>;
};

const ASK: ConfirmRequest = {
	title: "Are you sure?",
	detail: "This cannot be undone.",
	confirmLabel: "Do it",
};

function command(
	mode: "play" | "build" | "live",
	ready: boolean,
	confirm?: ConfirmRequest,
): Command {
	const out: Command = { ran: 0, el: null };
	out.el = ToolCommandButton({
		mode,
		label: "Discard all",
		ready,
		whenReady: "there is something to do",
		whenInert: "there is nothing to do, and here is why",
		...(confirm !== undefined ? { confirm } : {}),
		onRun: () => {
			out.ran += 1;
		},
	});
	return out;
}

/**
 * Click the command, answer whatever it asks with `answer`, and wait for the act
 * to have run or not.
 *
 * Driving the real channel rather than stubbing a global, which is the point of
 * having one: the click asks through `requestConfirm`, so the question is on the
 * channel by the time the handler reaches its first await and the test answers it
 * exactly as the dialog would. `asked` is what happened, so one helper covers a
 * command that asks and one that does not.
 */
async function click(
	c: Command,
	answer: boolean,
): Promise<{ asked: boolean }> {
	assert(c.el !== null, "there is no button to click");
	const done = c.el.props.onClick();
	const pending = currentConfirm();
	const asked = pending !== null;
	pending?.answer(answer);
	await done;
	return { asked };
}

Deno.test("a command renders in Build and nowhere else", () => {
	assertEquals(command("play", true).el, null);
	assertEquals(command("live", true).el, null);
	assert(command("build", true).el !== null);
	// The row goes with them, so the section closes up instead of
	// leaving a gap under the tool strip.
	assertEquals(ToolCommandRow({ mode: "play", children: null }), null);
	assert(ToolCommandRow({ mode: "build", children: null }) !== null);
});

Deno.test("with nothing to do it stays, inert, and says why", () => {
	const inert = command("build", false).el;
	assert(inert !== null, "the button vanished instead of going inert");
	assertEquals(inert.props.disabled, true);
	assertEquals(inert.props.title, "there is nothing to do, and here is why");
	assertEquals(inert.props.children, "Discard all");
});

Deno.test("with something to do it is live, and says what", () => {
	const live = command("build", true).el;
	assert(live !== null);
	assertEquals(live.props.disabled, false);
	assertEquals(live.props.title, "there is something to do");
});

Deno.test("a recoverable command runs on the click, asking nothing", async () => {
	_resetConfirmForTesting();
	const c = command("build", true);
	// The answer offered is no, so a command that asked would not run: `ran` and
	// `asked` together say it never asked rather than asked and was allowed.
	const { asked } = await click(c, false);
	assertEquals(asked, false, "a recoverable act asked about itself");
	assertEquals(c.ran, 1, "a command with no confirm did not just run");
});

Deno.test("a command that cannot be taken back asks first", async () => {
	_resetConfirmForTesting();
	const yes = command("build", true, ASK);
	assertEquals((await click(yes, true)).asked, true, "it did not ask");
	assertEquals(yes.ran, 1, "the confirmed command did not run");

	const no = command("build", true, ASK);
	assertEquals((await click(no, false)).asked, true, "it did not ask");
	assertEquals(no.ran, 0, "the refused command ran anyway");
});

Deno.test("the question a command asks names the act, not OK", async () => {
	// What the dialog is for: the browser's own could only offer OK, and a reader
	// who reads nothing but the button should still know what is about to happen.
	_resetConfirmForTesting();
	const c = command("build", true, ASK);
	assert(c.el !== null);
	const done = c.el.props.onClick();
	const asked = currentConfirm();
	assert(asked !== null, "nothing reached the channel");
	assertEquals(asked.title, ASK.title);
	assertEquals(asked.confirmLabel, "Do it");
	assert(asked.detail.length > 0, "the question gave no reason");
	asked.answer(false);
	await done;
});
