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
// row is still on its way. The last part holds both, with the moves slowed so
// that the second line lands inside the first one's move.

import type { Browser, Page } from "playwright";
import { fail } from "../support/fail.ts";
import { joinAs } from "../support/join.ts";
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
/** How far from the end the page still counts a reader as reading the newest
 * line. The tall line has to draw its group farther past the end than this. */
const AT_END = 80;

type Moves = { rows: number; rolls: number; members: number; all: number };

/** Count the moves the page starts from script from here on, by what moves. */
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
			// A slowed move runs at an even pace, so how far along it is
			// follows from how long ago it started.
			const slowed = Number(counted.proofSlowed ?? 1);
			const paced = slowed !== 1 && typeof timing === "object" && typeof timing.duration === "number"
				? { ...timing, duration: timing.duration * slowed, easing: "linear" }
				: timing;
			return animate.call(this, frames, paced);
		};
	});
}

/** Slow this reader's moves from here on, and record how far the log reports
 * itself past where its reader is. A reader at the end is at no distance from
 * it, so that distance is how far rows in motion are drawn past the end. */
async function slowAndMeasure(tab: Page, slowed: number): Promise<void> {
	await tab.evaluate((slowed) => {
		const counted = document.documentElement.dataset;
		counted.proofSlowed = String(slowed);
		counted.proofPastEnd = "0";
		const measure = () => {
			const log = document.getElementById("log");
			if (log == null) return;
			const past = log.scrollHeight - log.scrollTop - log.clientHeight;
			counted.proofPastEnd = String(Math.max(Number(counted.proofPastEnd), past));
			requestAnimationFrame(measure);
		};
		requestAnimationFrame(measure);
	}, slowed);
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
		// A second tall line lands while the group is still out there.
		await say(calm, SHORT);
		await awaitBubble(moving, SHORT, "travel-moving");
		await rowsAtRest(moving, "travel-moving");
		await slowAndMeasure(moving, 20);
		await say(calm, TALL);
		await awaitBubble(moving, TALL, "travel-moving");
		await say(third, BEHIND);
		await awaitBubble(moving, BEHIND, "travel-moving");
		await rowsAtRest(moving, "travel-moving");
		await say(calm, LAST);
		await awaitBubble(moving, LAST, "travel-moving");
		await rowsAtRest(moving, "travel-moving");
		const end = await moving.evaluate(() => {
			const log = document.getElementById("log");
			return {
				short: log == null ? null : log.scrollHeight - log.scrollTop - log.clientHeight,
				pastEnd: Number(document.documentElement.dataset.proofPastEnd),
			};
		});
		if (end.pastEnd <= AT_END) {
			fail(`the tall line drew its group ${end.pastEnd}px past the log's end, too little to hold anything`);
		}
		if (end.short == null || end.short > 1) {
			fail(
				`a reader at the end of the log was left ${end.short}px short of it after two tall lines and the next`,
			);
		}
	} finally {
		for (const tab of tabs) await tab.context().close();
	}
}
