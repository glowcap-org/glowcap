// The rail as one directory draws it, before a second ever exists.
//
// Split from `opening.ts` by subject when that file outgrew the project's
// file budget: the opening owns the wait and the join, and this owns the
// inventory of a one-directory rail. Run right after the opening, on the
// same conversation.

import type { Page } from "playwright";
import { fail } from "./harness.ts";
import { railQuestions } from "./filter_form.ts";

export async function run(tab: Page): Promise<void> {
	// ── One directory draws the rail it always drew ──────────────────────
	// Everything about several directories, the line on a row saying which
	// directory it is on, the color it wears, arrives only when there is more
	// than one to tell apart. With one, a reader must get exactly what they got
	// before any of it existed, and this is the moment to say so: this tab holds
	// the directory that served the page and nothing else, and it will hold a
	// second one two scenes from now.
	//
	// Asserted as an exact inventory rather than as "nothing looks new", because
	// the ways to break this are all additive: a box around some of the rows, a
	// heading over them, a second field, a row naming the only directory there
	// is. Each of those draws a rail that reads fine and is not this one.
	const alone = await tab.evaluate(() => ({
		lists: {
			rooms: document.getElementById("roomList")?.tagName ?? "",
			dms: document.getElementById("dmList")?.tagName ?? "",
		},
		boxes: document.querySelectorAll("#roomList > :not(li), #dmList > :not(li)").length,
		named: document.querySelectorAll("#roomList .rwhere, #dmList .rwhere").length,
		// A row says how its directory is doing when there is something to say,
		// whether this tab holds one directory or several. Counted here because a
		// connected directory has nothing to say and this one is connected: the
		// line arrives with the news and goes with it, so a rail that carries one
		// now is a rail that would carry it for the life of the tab.
		standings: document.querySelectorAll("#roomList .rwhere-how, #dmList .rwhere-how").length,
		colored: document.querySelectorAll("#roomList li[data-dir], #dmList li[data-dir]").length,
		heads: document.querySelectorAll(".section-head").length,
		filters: document.querySelectorAll(".rail-filter").length,
		fields: document.querySelectorAll(".newroom").length,
		status: document.querySelectorAll("#status").length,
	}));
	const extra = [
		alone.lists.rooms !== "UL" && `the rooms list is a ${alone.lists.rooms} rather than the list it was`,
		alone.lists.dms !== "UL" && `the direct list is a ${alone.lists.dms} rather than the list it was`,
		alone.boxes !== 0 && `${alone.boxes} boxes stand between the rail's lists and their rows`,
		alone.named !== 0 && `${alone.named} rows name the only directory there is`,
		alone.standings !== 0 && `${alone.standings} rows report a standing for a directory that is connected`,
		alone.colored !== 0 && `${alone.colored} rows wear a directory's color with nothing to tell apart`,
		alone.heads !== 2 && `the rail has ${alone.heads} section headings rather than its two`,
		// The one piece of chrome the rail has gained since this inventory was
		// written, counted here rather than left out of it. One
		// control, on the rooms heading, because how much of the rail a reader
		// is looking at is one question and not one per list. Two would be the
		// scoping this control does not have, and none would mean a reader on
		// one directory had lost a way to narrow a long list of rooms.
		alone.filters !== 1 && `the rail holds ${alone.filters} filter controls rather than one for both lists`,
		alone.fields !== 2 && `the rail holds ${alone.fields} name fields rather than one per list`,
		alone.status !== 1 && `the rail's foot reports ${alone.status} states rather than one`,
	].filter((said) => said !== false);
	if (extra.length > 0) {
		fail(`one directory does not draw the rail it always drew: ${extra.join("; ")}`);
	}

	// The filter asks the same questions whatever this tab holds. A tab on one
	// directory is still asked which directory, for the same reason a tab in one
	// room is still asked for a name: a question with one answer today is a
	// question all the same, and a control that dropped it would change shape
	// under a reader as they joined things. What a reader gets from the answer
	// is a different matter and not this control's to decide for them.
	await tab.click("#railFilter");
	await tab.waitForSelector("#railFilterPanel", { timeout: 5_000 })
		.catch(() => fail("the rail's filter opened nothing while this tab held one directory"));
	const asked = await tab.evaluate(() =>
		[...document.querySelectorAll("#railFilterPanel .filter-ask")].map((ask) => ({
			label: ask.querySelector(".filter-label")?.textContent?.trim() ?? "",
			choices: ask.querySelectorAll(".filter-choice").length,
		}))
	);
	const directory = asked.find((ask) => ask.label === "Directory");
	if (asked.length !== railQuestions.length) {
		fail(
			`with one directory held the rail's filter asks ${JSON.stringify(asked.map((ask) => ask.label))} ` +
				`rather than ${JSON.stringify(railQuestions)}`,
		);
	} else if (directory === undefined || directory.choices !== 1) {
		fail(`with one directory held the filter offers ${JSON.stringify(directory)} to filter by`);
	}
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#railFilterPanel", { state: "detached", timeout: 5_000 })
		.catch(() => fail("Escape did not put the rail's filter panel away"));
}
