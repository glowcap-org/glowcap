// How the rail's filter is drawn: the heading that opens it, and the form
// inside.
//
// Its sibling `filtering.ts` is about what the filter does to the rail. It
// watches which rows come out and that none of the rest move. This is about the
// control itself, a separate promise that breaks in separate ways: a heading
// that stopped being pressable, a question given a treatment its peers were
// not, answers that drifted back into a scatter of chips, ink that a change of
// ground left too faint to read.
//
// It opens the panel and leaves it open, because the scene that calls it goes
// straight on to answer the questions in it.

import type { Page } from "playwright";
import { fail } from "./harness.ts";
import { inkContrast } from "../ink_contrast.ts";

/** The questions the rail's filter puts to its rows, in the order the panel
 * draws them.
 *
 * Named here rather than in each scene that checks them, because more than one
 * does: this one, and the scene that watches the same control with a single
 * directory held. Two lists of the same questions would be one place to add a
 * question and two places to find out you had not. */
export const railQuestions = ["Name", "Directory", "Access", "Unread"];

/** Open the rail's questions from the rooms heading and hold the panel to what
 * it promises. */
export async function run(
	tab: Page,
	/** The sweep for text a short line box has clipped, handed down rather than
	 * written again: this panel is only ever on screen inside this scene. */
	descendersIntact: (where: string) => Promise<void>,
): Promise<void> {
	// ── The heading is the control ───────────────────────────────────────
	// The whole heading opens the questions, not the funnel drawn in front of
	// it. Pressed on its words, which is where a reader aims when the target is
	// a line of text: a control that only answered on its glyph would look like
	// this one and be a fifteen-pixel target in a rail two hundred wide.
	await tab.click("#railFilter .rail-filter-title");
	await tab.waitForSelector("#railFilterPanel", { timeout: 5_000 })
		.catch(() => fail("pressing the words of the rooms heading opened no questions"));
	const opener = await tab.evaluate(() => {
		const head = document.getElementById("railFilter");
		const title = head?.querySelector(".rail-filter-title");
		const list = document.getElementById("dmList")?.closest(".section")?.querySelector(".section-head");
		if (head == null || title == null || list == null) return null;
		const box = head.getBoundingClientRect(), words = title.getBoundingClientRect();
		return {
			expanded: head.getAttribute("aria-expanded") ?? "",
			// The words are inside the target rather than beside it, making the
			// heading the press rather than a mark that shares its line.
			holdsItsWords: box.left <= words.left + 0.5 && box.right + 0.5 >= words.right,
			// Direct messages keeps an ordinary heading. The questions are about
			// every row in the rail, so a second control asking them would be two
			// filters that have to agree. Its own "+" is a button and stays one,
			// so what is asked is whether the words of that heading open
			// anything, not whether its line carries a control at all.
			otherHeadIsPlain: list.querySelector(".rail-filter") === null &&
				list.querySelector(":scope > span") !== null,
			controls: document.querySelectorAll(".rail-filter").length,
		};
	});
	if (opener === null) fail("the rail has no rooms heading, or no direct-message heading beside it");
	else if (opener.expanded !== "true") {
		fail(`the rooms heading does not say its questions are open: ${JSON.stringify(opener)}`);
	} else if (!opener.holdsItsWords) {
		fail("the rooms heading's words sit outside the control, so pressing them is not pressing it");
	} else if (!opener.otherHeadIsPlain) {
		fail("the direct-message heading is not a plain label, so the rail may be asking its questions twice");
	} else if (opener.controls !== 1) {
		fail(`the rail holds ${opener.controls} filter controls rather than one for both lists`);
	}

	// ── The questions are peers ──────────────────────────────────────────
	// Every one of them drawn the same way. A question with a set of answers is
	// a well of rows with a box on each, whichever question it is, and the one
	// with a typed answer is a field. Which directory a row is on gets no
	// treatment of its own here: no place of honor in the list, no color the
	// others do not get, no different label. Neither does the newest of them,
	// which is where a mark or a count would have crept in.
	const asks = await tab.evaluate(() =>
		[...document.querySelectorAll("#railFilterPanel .filter-ask")].map((ask) => ({
			label: ask.querySelector(".filter-label")?.textContent?.trim() ?? "",
			// The typed question's own field. An answer's box is an input too, so
			// this counts only the ones a set of answers does not put there.
			fields: ask.querySelectorAll('input:not([type="checkbox"])').length,
			choices: [...ask.querySelectorAll(".filter-choice")].map((choice) => ({
				said: choice.querySelector(".filter-choice-said")?.textContent?.trim() ?? "",
				on: choice.querySelector<HTMLInputElement>(".checkbox")?.checked === true,
				// The mark is the control itself here rather than a glyph beside a
				// word, and the whole row is its label.
				marks: choice.querySelectorAll(".checkbox").length,
				labels: choice.tagName === "LABEL" ? 1 : 0,
			})),
			// A color anywhere in one question and not the others would be the
			// directory being drawn as the thing the rail is really about.
			colored: ask.querySelectorAll("[data-dir]").length,
		}))
	);
	const labels = asks.map((ask) => ask.label);
	if (labels.length !== railQuestions.length || railQuestions.some((label) => !labels.includes(label))) {
		fail(`the rail's filter asks ${JSON.stringify(labels)} rather than ${JSON.stringify(railQuestions)}`);
	}
	const setOut = asks.filter((ask) => ask.choices.length > 0);
	if (setOut.length !== 3) {
		fail(`${setOut.length} of the filter's questions offer a set of answers rather than three`);
	}
	for (const ask of asks) {
		if (ask.colored > 0) {
			fail(`the ${ask.label} question wears a directory's color, which the others are not given`);
		}
		if (ask.choices.length > 0 && ask.fields > 0) {
			fail(`the ${ask.label} question draws a field as well as its answers`);
		}
		for (const choice of ask.choices) {
			if (choice.marks !== 1 || choice.labels !== 1 || !choice.on) {
				fail(
					`the ${ask.label} question's ${JSON.stringify(choice.said)} is not a labelled box that is ` +
						`ticked while the answer is in view: ${JSON.stringify(choice)}`,
				);
			}
		}
	}

	// ── An answer set is one well, one answer to a row ───────────────────
	// A question offers a closed set of answers, and rows loose on the panel read
	// as an open one, as things somebody added and a reader could add to. So the
	// answers share one well: rows stacked one to a line, every row starting on
	// the same left edge, all of them inside a box that draws a ground and a
	// corner of its own.
	//
	// Measured rather than looked at, because a row of things side by side and a
	// scatter of pills would both pass every count this could be asked for. What
	// tells them apart is geometry: side by side means two answers on one line,
	// and loose means no box around them.
	//
	// One answer is turned off first, and everything below is read with it off.
	// Both states have to be on screen at once or there is nothing to compare,
	// and a reading taken with every answer in view finds the second state
	// missing rather than wrong. That is a pass by absence, and it is the one way
	// this whole section could quietly stop meaning anything.
	const first = tab.locator("#railFilterPanel .filter-choice").first();
	await first.click();
	await tab.waitForFunction(
		() =>
			[...document.querySelectorAll<HTMLInputElement>("#railFilterPanel .filter-choice .checkbox")]
				.some((box) => !box.checked),
		undefined,
		{ timeout: 5_000 },
	).catch(() => fail("turning an answer off did not leave one saying so"));
	// The pointer off the row it just pressed, because a hovered row wears the
	// state it is about to be read for and the reading would be of a hover.
	await tab.mouse.move(0, 0);
	// And settled. A row changes ink over a tenth of a second, and a computed
	// style read inside that window is the value it is travelling from, not the
	// one it is going to. Read immediately, the row that had just been turned off
	// still answered in the ink it wore while it was in view, which reads exactly
	// like a stylesheet that never distinguished the two.
	await tab.evaluate(() => Promise.all(document.getAnimations().map((a) => a.finished.catch(() => {}))));
	const wells = await tab.evaluate(() =>
		[...document.querySelectorAll("#railFilterPanel .filter-ask")]
			.filter((ask) => ask.querySelector(".filter-choice") !== null)
			.map((ask) => {
				const well = ask.querySelector(".filter-choices")!;
				const style = getComputedStyle(well);
				const box = well.getBoundingClientRect();
				const rows = [...well.querySelectorAll(".filter-choice")].map((choice) => {
					const at = choice.getBoundingClientRect();
					return {
						top: Math.round(at.top),
						left: at.left,
						right: at.right,
						on: choice.querySelector<HTMLInputElement>(".checkbox")?.checked === true,
						ink: getComputedStyle(choice).color,
					};
				});
				const lefts = rows.map((row) => row.left);
				const on = rows.find((row) => row.on);
				const off = rows.find((row) => !row.on);
				return {
					label: ask.querySelector(".filter-label")?.textContent?.trim() ?? "",
					answers: rows.length,
					// One line per answer. Two answers sharing a line is the row of
					// things side by side this is not.
					lines: new Set(rows.map((row) => row.top)).size,
					// And every row starting on the same edge, so the list reads as a
					// column rather than as an indent nobody chose.
					raggedBy: Math.max(...lefts) - Math.min(...lefts),
					// The well around all of them says the set is closed. Rows loose
					// on the panel stand on nothing and turn no
					// corner of their own.
					wellGround: style.backgroundColor,
					wellCorner: parseFloat(style.borderTopLeftRadius),
					// Every row inside it, so none of them escaped the box.
					outside: rows.filter((row) => row.left < box.left - 0.5 || row.right > box.right + 0.5).length,
					// What an answer in view and one turned off are drawn in. The box
					// is the answer, and the ink follows it.
					onInk: on?.ink ?? "",
					offInk: off?.ink ?? "",
				};
			})
	);
	if (wells.length !== setOut.length) {
		fail(`${wells.length} of the filter's ${setOut.length} answer sets stand in a well`);
	}
	const transparent = (paint: string) => paint === "" || paint === "transparent" || /,\s*0\)$/.test(paint);
	for (const well of wells) {
		if (transparent(well.wellGround) || !(well.wellCorner > 0)) {
			fail(`the ${well.label} question's answers stand on no well of their own: ${JSON.stringify(well)}`);
		} else if (well.outside > 0) {
			fail(`${well.outside} of the ${well.label} question's answers hang outside their own well`);
		} else if (well.lines !== well.answers) {
			fail(
				`the ${well.label} question puts its ${well.answers} answers on ${well.lines} lines, ` +
					"so some of them share a line rather than each having a row",
			);
		} else if (well.raggedBy > 1) {
			fail(
				`the ${well.label} question's rows start ${well.raggedBy.toFixed(1)}px apart, ` +
					"so they are not one column",
			);
		} else if (well.offInk !== "" && well.onInk === well.offInk) {
			fail(
				`the ${well.label} question draws an answer in view and one turned off in the same ink, ` +
					`${well.onInk}, so only the box says which is which`,
			);
		}
	}
	if (!wells.some((well) => well.offInk !== "")) {
		fail("no question held an answer turned off, so nothing read a row in both of its states");
	}

	// The panel is the one surface in this run that is only ever on screen here,
	// so what a short line box would clip is swept while it is open. Its answers
	// truncate, and an element that clips sideways clips top and bottom with it.
	await descendersIntact("in the rail's filter panel");

	// And every word in it clears what small text asks for, in both appearances,
	// against what is really behind it. Both states of a row are read, because
	// they are two inks on one ground and only one of them is the page's plain
	// ink. Measured with the panel open, because a sweep run while it is away
	// reads nothing at all and nothing at all is indistinguishable from a pass.
	{
		const FILTER_INK: readonly (readonly [string, string])[] = [
			["a question's name", "#railFilterPanel .filter-label"],
			["an answer in view", "#railFilterPanel .filter-choice:has(.checkbox:checked) .filter-choice-said"],
			[
				"an answer turned off",
				"#railFilterPanel .filter-choice:not(:has(.checkbox:checked)) .filter-choice-said",
			],
			// On the heading rather than in the panel, and only drawn once
			// something is hidden. This block has an answer turned off, so this
			// is the one place in the run where it can be read at all.
			["how much of the rail is on screen", "#railFilter .rail-filter-count"],
			// The way out of every answer, drawn as one more row and readable only
			// while there is something to come out of. This block has an answer
			// turned off, so it is live here and nowhere else in the run. Its word
			// is what is read: the box beside it carries no text.
			["the way back to everything", "#railFilterClear ~ .filter-choice-said"],
		];
		// At rest: the pointer sent away and the keyboard let go, or what is read
		// is a hovered or focused state wearing a resting state's name.
		await tab.mouse.move(0, 0);
		await tab.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
		const wasTheme = await tab.getAttribute("html", "data-theme");
		const tooFaint: string[] = [];
		for (const appearance of ["light", "dark"] as const) {
			await tab.evaluate((t) => document.documentElement.setAttribute("data-theme", t), appearance);
			await tab.evaluate(() => Promise.all(document.getAnimations().map((a) => a.finished.catch(() => {}))));
			for (const [what, selector] of FILTER_INK) {
				const measured = await inkContrast(tab, selector);
				if (measured === null) tooFaint.push(`${what} could not be measured in ${appearance}`);
				else if (measured.ratio < 4.5) {
					tooFaint.push(`${what} is ${measured.ratio.toFixed(2)}:1 in ${appearance} (${measured.saw})`);
				}
			}
		}
		await tab.evaluate((t) => {
			if (t === null) document.documentElement.removeAttribute("data-theme");
			else document.documentElement.setAttribute("data-theme", t);
		}, wasTheme);
		if (tooFaint.length > 0) {
			fail(`the rail's filter does not clear 4.5 to 1 for small text: ${tooFaint.join("; ")}`);
		}
		await first.click();
		await tab.waitForFunction(
			() =>
				[...document.querySelectorAll<HTMLInputElement>("#railFilterPanel .filter-choice .checkbox")]
					.every((box) => box.checked),
			undefined,
			{ timeout: 5_000 },
		).catch(() => fail("turning that answer back on left the panel holding it off"));
	}
}
