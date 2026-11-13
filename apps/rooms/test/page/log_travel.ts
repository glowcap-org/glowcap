// A change to the page moves what it displaces, and the page draws that move.
//
// The moves are started from script, which the stylesheet's rule for a reader
// who asked for less motion does not reach. So this phase watches two readers
// of one room. One sees the rows of the log travel when a line lands, and a
// count roll and a member's row fade in when somebody arrives. The other
// asked for less motion and is started no move, until they ask for motion
// again.
//
// A row on its way to its place can be drawn past the log's end. The reader
// stays at the end through that, and through a line that lands while such a
// row is still on its way. The last part holds both, with every move held at
// its start so that the second line lands while the first is as far out as it
// gets.

import type { Browser, Page } from "playwright";
import { fail } from "../support/fail.ts";
import { joinAs } from "../support/join.ts";
import { NEAR_END } from "../../web/ui/panes/log_travel.tsx";
import { awaitBubble, say } from "./harness.ts";

const ROOM = "travel";
const LINE = "a line that moves the log";
const AGAIN = "a line for a reader who wants motion back";
const SHORT = "a short line first";
const LAST = "a line after both tall ones";
/** A line that wraps taller than the room the composer leaves under the log,
 * and well short of a screen. */
function tall(what: string): string {
	return Array.from({ length: 20 }, (_, at) => `part ${at + 1} of ${what} long enough to wrap many times`).join(" ");
}
const TALL = tall("a line");
const BEHIND = tall("the line behind it");

type Moves = { rows: number; rolls: number; members: number; all: number };

/** Count the moves the page starts from script from here on, by what moves,
 * and hold each at its start while the reader's moves are held. */
async function countMoves(tab: Page): Promise<void> {
	await tab.evaluate(() => {
		const counted = document.documentElement.dataset;
		const count = (name: string) => counted[name] = String(Number(counted[name] ?? 0) + 1);
		const animate = Element.prototype.animate;
		Element.prototype.animate = function (frames, timing) {
			count("proofMoves");
			if (this.parentElement?.id === "log") count("proofRowMoves");
			if (this.parentElement?.id === "members") count("proofMemberMoves");
			if (this.classList.contains("rolling-count")) count("proofRollMoves");
			const move = animate.call(this, frames, timing);
			if (counted.proofHeld === "1") move.pause();
			return move;
		};
	});
}

/** Hold every move this reader is started at its start, or let them all run. */
async function holdMoves(tab: Page, held: boolean): Promise<void> {
	await tab.evaluate((held) => {
		document.documentElement.dataset.proofHeld = held ? "1" : "0";
		if (held) return;
		for (const move of document.getAnimations()) if (move.playState === "paused") move.play();
	}, held);
}

/** How far the log reports itself past where its reader is, once the page has
 * been told of every scroll so far. A reader at the end is at no distance from
 * it, so this is how far rows in motion are drawn past the end. */
async function pastEnd(tab: Page, who: string): Promise<number> {
	const past = await tab.evaluate(async () => {
		// A scroll is told to the page before the frame after it is drawn.
		await new Promise((drawn) => requestAnimationFrame(() => requestAnimationFrame(drawn)));
		const log = document.getElementById("log");
		return log == null ? null : log.scrollHeight - log.scrollTop - log.clientHeight;
	});
	if (past == null) fail(`${who} has no log to read`);
	return past;
}

async function moves(tab: Page): Promise<Moves> {
	return await tab.evaluate(() => {
		const counted = document.documentElement.dataset;
		return {
			rows: Number(counted.proofRowMoves ?? 0),
			rolls: Number(counted.proofRollMoves ?? 0),
			members: Number(counted.proofMemberMoves ?? 0),
			all: Number(counted.proofMoves ?? 0),
		};
	});
}

/** The reader's member list has this many rows. */
async function sees(tab: Page, who: string, members: number): Promise<void> {
	await tab.waitForFunction(
		(count) => document.querySelectorAll("#members li").length === count,
		members,
		{ timeout: 30_000 },
	).catch(() => fail(`${who} never saw ${members} members in the room`));
}

/** No row of the log is moving. A move ends where the log put the row, so one
 * still listed long after the last change is holding the row somewhere else. */
async function rowsAtRest(tab: Page, who: string): Promise<void> {
	await tab.waitForFunction(
		() => [...document.querySelectorAll("#log > *")].every((row) => row.getAnimations().length === 0),
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail(`a row of ${who}'s log was still moving ten seconds after the last change`));
}

export async function run(browser: Browser, port: number): Promise<void> {
	const moving = await joinAs(browser, port, "travel-moving", { room: ROOM });
	const calm = await joinAs(browser, port, "travel-calm", { room: ROOM });
	const tabs = [moving, calm];
	try {
		await calm.emulateMedia({ reducedMotion: "reduce" });
		await sees(moving, "travel-moving", 2);
		await sees(calm, "travel-calm", 2);
		await countMoves(moving);
		await countMoves(calm);

		const before = await moves(moving);
		await say(moving, LINE);
		await awaitBubble(moving, LINE, "travel-moving");
		await awaitBubble(calm, LINE, "travel-calm");
		const line = await moves(moving);
		if (line.rows === before.rows) fail(`a line landed and no row of the log traveled: ${JSON.stringify(line)}`);

		const third = await joinAs(browser, port, "travel-third", { room: ROOM });
		tabs.push(third);
		await sees(moving, "travel-moving", 3);
		await sees(calm, "travel-calm", 3);
		const arrival = await moves(moving);
		if (arrival.members === line.members) {
			fail(`a member arrived and their row did not: ${JSON.stringify(arrival)}`);
		}
		if (arrival.rolls === line.rolls) fail(`a member arrived and no count rolled: ${JSON.stringify(arrival)}`);

		const spared = await moves(calm);
		if (spared.all !== 0) {
			fail(`a reader who asked for less motion was started moves from script: ${JSON.stringify(spared)}`);
		}
		// The same reader, wanting motion again, is started moves. So it was
		// the asking that spared them and nothing else about that tab.
		await calm.emulateMedia({ reducedMotion: "no-preference" });
		await say(moving, AGAIN);
		await awaitBubble(calm, AGAIN, "travel-calm");
		const wanted = await moves(calm);
		if (wanted.rows === 0) fail(`a reader who wants motion again was started none: ${JSON.stringify(wanted)}`);

		// A tall line joins its author's group, so the group grows by more than
		// the room under the log and starts its move drawn past the log's end.
		// The move is held there while a second tall line lands. A reader the
		// page kept at the end is as far from the log's reported end after
		// the second line as after the first, because the one group is still
		// drawn where it was.
		await say(calm, SHORT);
		await awaitBubble(moving, SHORT, "travel-moving");
		await rowsAtRest(moving, "travel-moving");
		await holdMoves(moving, true);
		await say(calm, TALL);
		await awaitBubble(moving, TALL, "travel-moving");
		const first = await pastEnd(moving, "travel-moving");
		if (first <= NEAR_END) {
			fail(`the tall line drew its group ${first}px past the log's end, too little to hold anything`);
		}
		await say(third, BEHIND);
		await awaitBubble(moving, BEHIND, "travel-moving");
		const second = await pastEnd(moving, "travel-moving");
		if (Math.abs(second - first) > 2) {
			fail(
				`a line that landed behind a group drawn ${first}px past the log's end left its reader ${second}px from the end the log reports`,
			);
		}
		await holdMoves(moving, false);
		await rowsAtRest(moving, "travel-moving");
		await say(calm, LAST);
		await awaitBubble(moving, LAST, "travel-moving");
		await rowsAtRest(moving, "travel-moving");
		const short = await pastEnd(moving, "travel-moving");
		if (short > 1) {
			fail(`a reader at the end of the log was left ${short}px short of it after two tall lines and the next`);
		}
	} finally {
		for (const tab of tabs) await tab.context().close();
	}
}
