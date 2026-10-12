// How a directory's colour behaves as a channel.
//
// Two rules, and both belong to the class rather than to any one surface that
// wears a colour. A colour is only ever the glance at something the words
// already say, so nothing may be identified by one alone. And every word in the
// rail has to clear what small text asks for against whatever is really behind
// it, in both appearances.
//
// Split out of `directories.ts` because it is its own subject: that scene is
// about two directories being held at once, and this is about what wearing a
// directory's colour commits the interface to. It is called from the point in
// that run where the rail carries the most, which is the only place these
// sweeps have enough to sweep.

import type { Page } from "playwright";
import { fail } from "./harness.ts";
import { inkContrast } from "../ink_contrast.ts";

/** Sweep the rail for a directory told apart by colour alone, then measure every
 * word in it against its real ground in both appearances. */
export async function run(tab: Page): Promise<void> {
	// No directory is identified by color alone. Every row in the rail that
	// wears a directory's color also says which directory that is, either in
	// words on the row or in the label the control announces: the color is the
	// glance, and a reader who cannot use it must not be left with nothing.
	//
	// Swept over whatever the rail is carrying rather than asserted row by row,
	// because the rule belongs to the class and not to any one member of it: a
	// room row, a direct row, an invitation and the foot's own lockup all wear a
	// directory's color, and a new kind of surface must not be able to join them
	// without saying which directory it is on. This run holds two directories
	// with a room open on each, so what it sweeps is the room rows, the panel's
	// own destination line, and the foot.
	const byColorAlone = await tab.evaluate(() => {
		const rail = document.querySelector(".sidebar");
		if (rail === null) return null;
		// What the rail is calling its directories, taken from the rows that name
		// one. A directory row's line says why it is there rather than naming a
		// directory, so its name is read off the row itself.
		const named = new Set<string>();
		for (const said of rail.querySelectorAll("#roomList li:not(.dirrow) .rwhere-said, #dmList li .rwhere-said")) {
			const name = (said.textContent ?? "").trim().replace(/^in /, "");
			if (name !== "") named.add(name);
		}
		for (const row of rail.querySelectorAll("#roomList li.dirrow .rname")) {
			const name = (row.textContent ?? "").trim();
			if (name !== "") named.add(name);
		}
		const silent: string[] = [];
		const worn = rail.querySelectorAll("[data-dir]");
		for (const row of worn) {
			// Everything this row gives a reader: its own words, every label and
			// title on it or inside it, and the label of the control it sits in,
			// which is where the foot's lockup carries its names.
			const speaking: Element[] = [row, ...row.querySelectorAll("*")];
			const holder = row.closest("button, li");
			if (holder !== null && holder !== row) speaking.push(holder);
			const said = speaking
				.flatMap((el) => [el.getAttribute("aria-label") ?? "", el.getAttribute("title") ?? ""])
				.concat(row.textContent ?? "")
				.join(" ");
			if (![...named].some((name) => said.includes(name))) {
				silent.push(
					row.nodeName + "." + String(row.getAttribute("class") ?? "") + " wearing " +
						String(row.getAttribute("data-dir")),
				);
			}
		}
		return { names: [...named], rows: worn.length, silent };
	});
	if (byColorAlone === null) fail("the rail was not on screen to sweep for directories told apart by color alone");
	else if (byColorAlone.names.length < 2) {
		fail(`the rail names ${byColorAlone.names.length} directories, so this sweep had nothing to tell apart`);
	} else if (byColorAlone.rows < 3) {
		fail(`only ${byColorAlone.rows} things in the rail wore a directory's color, which is too few to have swept`);
	} else if (byColorAlone.silent.length > 0) {
		fail(
			`the rail tells directories apart by color alone on ${byColorAlone.silent.join(", ")}; ` +
				`it names ${JSON.stringify(byColorAlone.names)}`,
		);
	}

	// Every word in the rails clears the 4.5 to 1 small text asks for, against
	// what is really behind it, in both appearances.
	//
	// The stylesheet argues these numbers in prose, and nothing else holds them:
	// any of the tokens underneath could move one back under the line without a
	// word changing. The whole argument had also only ever been made in light,
	// while the rail is drawn from the same tokens in syrup at different values.
	//
	// This is the point in the run where the rail carries the most: two
	// directories, so every row names one, with a room open on each and a roster
	// beside them. The line naming a directory is read twice, because it sits on
	// the row's own ground and the row being read is painted: at four fifths on
	// an unpainted row it is the page's ink on the rail's fill, and on the
	// painted one it is at full strength for exactly this reason.
	const RAIL_INK = [
		["the directory of a room", "#roomList li:not(.here) .rwhere-said"],
		["the directory of the room being read", "#roomList li.here .rwhere-said"],
		["the name of the room being read", "#roomList li.here .rname"],
		["a room's name", "#roomList li:not(.here) .rname"],
		["a room's count", "#roomList .rcount"],
		["a list's label", ".section-head span"],
		["the roster's label", ".members h2"],
		["a member's name", "#members .online .name"],
		["what the connection is doing", "#status"],
		// The panel that opens the conversation wears the directory's colour too,
		// in its wash and in its heading, so it answers to the same bar as the rail
		// that sent the reader here.
		["the name of the conversation being read", ".conv-intro h2"],
		["what this conversation is", ".conv-intro p"],
	] as const;
	// The panel has to be wearing a foreign directory for those last two to say
	// anything about the ramp. On this page's own directory it draws in teal, the
	// same as it always did, and a sweep of that measures the colour this change
	// did not touch.
	const panelWears = await tab.evaluate(() => {
		const area = document.querySelector(".workarea");
		return document.querySelector(".conv-intro") === null ? null : area?.getAttribute("data-dir") ?? "";
	});
	if (panelWears === null) fail("no conversation panel was on screen to sweep for a directory's colour");
	else if (panelWears === "" || panelWears === "home") {
		fail(
			`the conversation panel is wearing ${
				panelWears === "" ? "no directory" : "this page's own directory"
			}, so sweeping it says nothing about the directory ramp`,
		);
	}
	const wasTheme = await tab.getAttribute("html", "data-theme");
	const tooFaint: string[] = [];
	// At rest, which takes saying twice: the pointer sent away and the keyboard
	// let go. Earlier checks left the pointer parked on a row and focus on the
	// caption it pressed, and either one swaps that caption's ink for the teal a
	// link wears, hover changes its ground too. What came back was an interactive
	// state wearing a resting state's name, and its numbers said nothing about the
	// rail a reader is looking at.
	await tab.mouse.move(0, 0);
	await tab.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
	for (const appearance of ["light", "dark"] as const) {
		await tab.evaluate((t) => document.documentElement.setAttribute("data-theme", t), appearance);
		// Settled first. Changing the appearance re-renders the rail, and a rail
		// arriving runs a two-tenths fade that starts at nothing, so a reading
		// taken straight after the switch is of a half-drawn panel, and it lands
		// near one to one however the colours are set. That is what a colour bug
		// looks like from here, and it does not move when you fix colours.
		await tab.evaluate(() => Promise.all(document.getAnimations().map((a) => a.finished.catch(() => {}))));
		for (const [what, selector] of RAIL_INK) {
			const measured = await inkContrast(tab, selector);
			// A refusal is a failure of its own. Every one of these is on screen here,
			// so "could not measure" means the measuring broke, and a measurement that
			// quietly stops answering is indistinguishable from one that passes.
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
		fail(`the rail and its conversation do not clear 4.5 to 1 for small text: ${tooFaint.join("; ")}`);
	}
}
