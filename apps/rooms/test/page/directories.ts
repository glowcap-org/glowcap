// Holding two directories at once.
//
// This is where "which directory" stops being rhetorical. Two servers each
// grant their own names and may each have a room with the same label, so every
// row has to say which one it belongs to, Settings has to stay about the page's
// locator, and leaving one must not disturb the other.

import type { Page } from "playwright";
import { fail } from "./harness.ts";
import { inkContrast } from "../ink_contrast.ts";
import { run as leavingRun } from "./leaving.ts";

export async function run(
	tab: Page,
	foreignLocator: string,
	foreignRoom: Deno.ChildProcess,
	foreignRoomPort: number,
): Promise<Deno.ChildProcess | null> {
	// Both servers at once, which is the whole of it: the rail groups by
	// directory the moment there is more than one to group by, the local room is
	// still listed and still joined, and going back to it is one press.
	// Every room row now says which server it is on, in words as well as colour.
	await tab.waitForFunction(
		() => {
			const said = [...document.querySelectorAll("#roomList .rwhere")]
				.map((row) => row.textContent?.trim() ?? "");
			return said.length >= 2 && new Set(said).size >= 2;
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("holding two servers did not say which server each room is on"));
	await tab.waitForFunction(
		() => {
			const joined = [...document.querySelectorAll("#roomList .rname")]
				.map((row) => row.textContent?.trim());
			return joined.includes("lobby") && joined.includes("elsewhere");
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("reaching a second server gave up the room held on the first"));

	// A name is one directory's grant, and the foot is the one place on screen
	// that says who this reader is — so with two directories granting names it
	// has to stop reading as the page's own idea of who you are. The name wears
	// the mark of the directory that granted it, the same colour that
	// directory's rooms wear above, and the chip beside it counts the others in
	// words rather than as a bare number.
	const identity = await tab.evaluate(() => {
		const row = document.querySelector(".sidebar-foot .foot-names");
		return {
			drawn: row !== null,
			mark: row?.getAttribute("data-dir") ?? "",
			name: row?.querySelector(".name")?.textContent?.trim() ?? "",
			more: row?.querySelector(".foot-more")?.textContent?.trim() ?? "",
			title: row?.getAttribute("title") ?? "",
		};
	});
	if (!identity.drawn) fail("the rail foot drew no name while two directories had granted one");
	if (identity.mark === "") {
		fail(`the foot's name does not say which directory granted it: ${JSON.stringify(identity)}`);
	}
	if (!/^\+\d+ names?$/.test(identity.more)) {
		fail(`the foot does not count the other names in words: ${JSON.stringify(identity)}`);
	}
	if (!identity.title.includes(" on ")) {
		fail(`the foot's title does not say which name is on which directory: ${JSON.stringify(identity)}`);
	}

	// The directory line is a caption under the room's name, not a second name
	// beside it, and the difference is carried entirely by its size. That size is
	// worth measuring because it is quiet to lose: the line is drawn as a link,
	// links here take their surroundings' font so one inside a sentence matches
	// the sentence, and that rule outranks the caption's own size unless the
	// caption is written to beat it. Nothing about the page looks broken when it
	// does not — the words are all still there, in the wrong place in the reading
	// order.
	const scale = await tab.evaluate(() => {
		const row = document.querySelector("#roomList li");
		const name = row?.querySelector(".rname");
		const where = row?.querySelector(".rwhere");
		if (name === null || name === undefined || where === null || where === undefined) return null;
		const px = (el: Element) => parseFloat(getComputedStyle(el).fontSize);
		return { name: px(name), where: px(where) };
	});
	if (scale === null) fail("a room row held no directory caption to size");
	else if (!(scale.where <= scale.name * 0.85)) {
		fail(
			`the directory caption is set at ${scale.where}px against a ${scale.name}px room name, ` +
				"so it reads as a second name rather than a caption under the first",
		);
	}

	// The caption under a room's name opens what is known about the directory it
	// names. Every directory this tab holds uses the same card, this page's own
	// included: Settings keeps the page locator and a button that opens that
	// card, rather than answering the same three questions twice.
	const captionOf = (room: string) => {
		const row = tab.locator("#roomList li").filter({ has: tab.locator(`.rname:text-is("${room}")`) });
		return row.locator(".rwhere");
	};
	await (captionOf("lobby")).click();
	await tab.waitForSelector("#dircardTitle", { timeout: 10_000 })
		.catch(() => fail("the caption on a room in this page's own directory did not open a card about it"));
	const homeCard = await tab.evaluate(() => ({
		title: document.getElementById("dircardTitle")?.textContent?.trim() ?? "",
		facts: [...document.querySelectorAll(".modal .dirfacts dt")].map((dt) => dt.textContent?.trim() ?? ""),
		mark: document.querySelector(".modal-card.dircard")?.getAttribute("data-dir") ?? "",
	}));
	if (homeCard.title !== "this directory") {
		fail(`the card for this page's own directory titled ${JSON.stringify(homeCard.title)}`);
	}
	if (!homeCard.facts.includes("Your name here")) {
		fail(`the card does not say what this directory granted you; it lists ${JSON.stringify(homeCard.facts)}`);
	}
	if (homeCard.mark !== "home") {
		fail(
			`the card for this page's own directory did not wear the home mark; it wore ${
				JSON.stringify(homeCard.mark)
			}`,
		);
	}
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#dircardTitle", { state: "detached", timeout: 10_000 });

	// Settings still names this page's locator, and its button opens that same
	// card rather than growing a second copy of the facts.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle", { timeout: 10_000 });
	// The dialog reopens on whichever panel was last selected, so name the
	// one this check reads.
	await tab.click("#overviewTab");
	await tab.waitForSelector("#settingsAboutDir");
	const aboutBox = await tab.evaluate(() => {
		const about = document.querySelector("#settingsAboutDir");
		const group = about?.closest(".group");
		if (about == null || group == null) return null;
		return {
			align: getComputedStyle(about).alignSelf,
			width: about.getBoundingClientRect().width,
			column: group.getBoundingClientRect().width,
		};
	});
	if (aboutBox == null) fail("Settings had no About this directory to measure");
	if (aboutBox.align !== "center" || aboutBox.width >= aboutBox.column - 1) {
		fail(
			`About this directory spans the card (${aboutBox.width.toFixed(1)}px in a ${
				aboutBox.column.toFixed(1)
			}px group) rather than sitting at its words like Close`,
		);
	}
	await tab.click("#settingsAboutDir");
	await tab.waitForSelector("#dircardTitle", { timeout: 10_000 })
		.catch(() => fail("Settings did not open this directory's card"));
	await tab.waitForSelector("#settingsTitle", { state: "hidden", timeout: 10_000 });
	const fromSettings = (await tab.textContent("#dircardTitle"))?.trim() ?? "";
	if (fromSettings !== "this directory") {
		fail(`Settings opened a card titled ${JSON.stringify(fromSettings)}`);
	}
	// The dim around the card is the same press that leaves Settings and Help.
	// Escape is the other half of that chain and is asked in opening.ts; this
	// is the half a stacked directory card used to ignore.
	const dim = await tab.evaluate(() => {
		const layer = document.querySelector("dialog.modal:modal");
		const card = layer?.querySelector(".modal-card");
		if (layer == null || card == null) return null;
		const a = layer.getBoundingClientRect();
		const b = card.getBoundingClientRect();
		return { x: a.left + 8, y: (a.top + a.bottom) / 2, cardLeft: b.left };
	});
	if (dim == null || dim.x >= dim.cardLeft) {
		fail("the directory card had no dimmer around it to press");
	}
	await tab.mouse.click(dim.x, dim.y);
	await tab.waitForSelector("#dircardTitle", { state: "detached", timeout: 10_000 })
		.catch(() => fail("pressing the dim around the directory card did not close it"));
	await tab.waitForSelector("#settingsTitle", { timeout: 10_000 })
		.catch(() => fail("closing the directory card did not return to Settings"));
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#settingsTitle", { state: "detached", timeout: 10_000 });

	await (captionOf("elsewhere")).click();
	await tab.waitForSelector("#dircardTitle", { timeout: 10_000 })
		.catch(() => fail("the caption on a room in another directory did not open a card about it"));
	const cardSaid = await tab.evaluate(() => ({
		title: document.getElementById("dircardTitle")?.textContent?.trim() ?? "",
		locator: document.getElementById("dircardLocator")?.textContent?.trim() ?? "",
		facts: [...document.querySelectorAll(".dircard-title, #dircardTitle")].length,
		rows: document.querySelectorAll(".modal .dirfacts dt").length,
	}));
	// The title is the readable name and the field is the exact locator, which is
	// the split that lets one be read aloud and the other pasted.
	if (cardSaid.title === "" || cardSaid.title.includes("%")) {
		fail(`the card titled a directory with something unreadable: ${JSON.stringify(cardSaid.title)}`);
	}
	if (cardSaid.rows < 3) {
		fail(`the card answered ${cardSaid.rows} of the three questions a directory raises`);
	}
	// And it wears the directory's own mark, in the colour that directory's rows
	// wear in the rail. Compared rather than asserted as a value, because the
	// claim is that the two agree: a card carrying some other colour, or the
	// ink's default because the variable never reached it, both read as this
	// card being about something else.
	const marksAgree = await tab.evaluate(() => {
		const inCard = document.querySelector(".dircard .dircard-mark");
		const row = [...document.querySelectorAll("#roomList li")]
			.find((li) => (li.querySelector(".rname")?.textContent ?? "").includes("elsewhere"));
		const inRail = row?.querySelector(".rwhere .icon-svg");
		if (inCard === null || inRail === null || inRail === undefined) return null;
		return {
			card: getComputedStyle(inCard).color,
			rail: getComputedStyle(inRail).color,
		};
	});
	if (marksAgree === null) fail("the card or the rail carried no directory mark to compare");
	else if (marksAgree.card !== marksAgree.rail) {
		fail(
			`the card's directory mark is ${marksAgree.card} where the rail draws that directory ${marksAgree.rail}`,
		);
	}
	// The card's top stripe is the same bar Settings wears, with this directory's
	// colour in the teal stop. Compared to the mark rather than named, because a
	// bar that stayed teal would still look like a modal and would be about the
	// wrong directory.
	const stripeAgrees = await tab.evaluate(() => {
		const card = document.querySelector(".modal-card.dircard");
		const mark = document.querySelector(".dircard .dircard-mark");
		if (!(card instanceof HTMLElement) || !(mark instanceof HTMLElement)) return null;
		const probe = (from: HTMLElement, value: string) => {
			const el = document.createElement("span");
			from.appendChild(el);
			el.style.color = value;
			const saw = getComputedStyle(el).color;
			el.remove();
			return saw;
		};
		return {
			stripe: probe(card, "var(--card-stripe-to)"),
			mark: probe(mark, "currentColor"),
			teal: probe(card, "var(--teal)"),
		};
	});
	if (stripeAgrees === null) fail("the directory card had no stripe or mark to compare");
	else if (stripeAgrees.stripe !== stripeAgrees.mark) {
		fail(
			`the directory card's top stripe is ${stripeAgrees.stripe} where that directory is ${stripeAgrees.mark}`,
		);
	} else if (stripeAgrees.stripe === stripeAgrees.teal) {
		fail("the directory card's top stripe stayed teal, the colour of this page's own directory");
	}
	// Where you are here is a hanging menu, not more card. Overflow auto took
	// that menu into the card's scroll, so opening it grew a scrollbar instead
	// of sitting over the facts.
	await tab.click("#dircardStanding");
	const standingMenu = await tab.evaluate(() => {
		const card = document.querySelector(".modal-card.dircard");
		const menu = document.querySelector(".dircard .standing-menu");
		if (card == null || menu == null) return null;
		return {
			scrolls: card.scrollHeight > card.clientHeight + 1,
			menuH: Math.round(menu.getBoundingClientRect().height),
		};
	});
	if (standingMenu === null) fail("where you are here did not open a menu on the directory card");
	else if (standingMenu.menuH < 40) {
		fail(`the directory card's standing menu did not paint: ${JSON.stringify(standingMenu)}`);
	} else if (standingMenu.scrolls) {
		fail(`opening where you are here made the directory card scroll: ${JSON.stringify(standingMenu)}`);
	}
	await tab.keyboard.press("Escape");
	await tab.waitForSelector(".dircard .standing-menu", { state: "detached", timeout: 5_000 });
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#dircardTitle", { state: "detached", timeout: 10_000 });

	// The line under a room's name is a target of its own, so it has to look like
	// one: it spans the row's whole content box, starting where the sigil starts
	// and ending where the count and the leave mark end, and what is written on
	// it — the directory's mark and the words naming it — sits in the middle of
	// that box as one piece. Measured, because every one of these was wrong at
	// some point while the line still read fine in a screenshot: an indent that
	// put it past the name, a right edge short of the marks, and words that
	// centred while the glyph stayed pinned at the far left, which is the shape
	// this replaced.
	const laidOut = await tab.evaluate(() => {
		const row = [...document.querySelectorAll("#roomList li")]
			.find((li) => li.querySelector(".rwhere") !== null);
		const cap = row?.querySelector(".rwhere");
		const hash = row?.querySelector(".hash");
		const leave = row?.querySelector(".room-leave");
		const icon = cap?.querySelector(".icon-svg");
		const said = cap?.querySelector(".rwhere-said");
		if (!cap || !hash || !leave || !icon || !said) return null;
		const box = (el: Element) => {
			const b = el.getBoundingClientRect();
			return { l: b.left, r: b.right, cx: b.x + b.width / 2 };
		};
		const c = box(cap), h = box(hash), v = box(leave);
		const i = box(icon), w = box(said);
		return {
			startsAtTheMark: Math.abs(c.l - h.l),
			endsAtTheMarks: Math.abs(c.r - v.r),
			// One piece: the words follow the glyph across the family's own gap,
			// rather than each being placed by a column of the row above.
			markBesideItsWords: Math.abs(w.l - i.r) > 12 ? Math.abs(w.l - i.r) : 0,
			// And the piece sits in the middle, which is what leaves the glyph the
			// air on its left that being placed by the mark column took away.
			centredInTheLine: Math.abs((i.l - c.l) - (c.r - w.r)),
			// Drawn at rest, not only under a pointer. A distance, so it is asked
			// as one below rather than folded in among them.
			edge: parseFloat(getComputedStyle(cap).borderTopWidth),
		};
	});
	// The bar marking the row being read is the row's height less a little at
	// each end, not a number of its own. A row is one line tall until it names its
	// directory and then it is two: measured against a fixed bar that reads as
	// half of a short row, a tall one gets a third, and nothing about that looks
	// broken enough to notice without measuring it.
	const marking = await tab.evaluate(() => {
		const row = [...document.querySelectorAll("#roomList li.here")]
			.find((li) => li.querySelector(".rwhere") !== null);
		if (row === undefined) return null;
		const mark = parseFloat(getComputedStyle(row, "::before").height);
		return { row: row.getBoundingClientRect().height, mark };
	});
	if (marking === null) fail("no room being read carried a directory line, so the mark had nothing to grow with");
	else if (!(marking.mark > 0) || Math.abs(marking.row - marking.mark - 14) > 1) {
		fail(
			`the mark on the row being read is ${marking.mark.toFixed(1)}px on a ${
				marking.row.toFixed(1)
			}px row, which is not that row's height less its inset`,
		);
	}

	if (laidOut === null) fail("no room row carried a directory line with a mark and words in it");
	else {
		if (!(laidOut.edge > 0)) {
			fail("the directory line is drawn with no rectangle at rest, so it is a target only under a pointer");
		}
		for (const [what, off] of Object.entries(laidOut)) {
			if (what !== "edge" && off > 1) {
				fail(`the directory line does not line up: ${what} is out by ${off.toFixed(1)}px`);
			}
		}
	}

	// One takes the other's place, so they have to occupy the same place, and the
	// place a reader aims at is the middle of the mark rather than its right edge.
	// A row grows a second line the moment it names a directory, and anything
	// anchored to the row's full height then drifts below anything anchored to the
	// line the name is on. Measured on a captioned row for that reason: on a
	// single-line row the two anchors agree and the defect cannot appear.
	//
	// The press is measured too, and separately, because every other reading here
	// was already perfect while the control could not be pressed: the count fades
	// to nothing when the mark takes its slot, and something at zero opacity still
	// takes clicks. Visible, enabled, aligned, and dead through its own middle is
	// a state only this question can see.
	const slot = await tab.evaluate(() => {
		const row = [...document.querySelectorAll("#roomList li")]
			.find((li) => li.querySelector(".rwhere") !== null);
		const leave = row?.querySelector(".room-leave");
		const badge = row?.querySelector(".rcount");
		if (!leave || !badge) return null;
		const a = leave.getBoundingClientRect();
		const b = badge.getBoundingClientRect();
		const at = document.elementFromPoint(a.x + a.width / 2, a.y + a.height / 2);
		return {
			dy: Math.abs((a.y + a.height / 2) - (b.y + b.height / 2)),
			dx: Math.abs((a.x + a.width / 2) - (b.x + b.width / 2)),
			pressable: at !== null && leave.contains(at),
			covering: at === null ? "nothing" : at.nodeName + "." + String(at.getAttribute("class") ?? ""),
		};
	});
	if (slot === null) fail("no room row carried both a directory caption and the pair of marks that share its slot");
	else if (slot.dy > 1 || slot.dx > 1) {
		fail(
			`the leave mark and the badge do not share a slot on a two-line row: ` +
				`${slot.dy.toFixed(1)}px apart vertically and ${slot.dx.toFixed(1)}px across`,
		);
	} else if (!slot.pressable) {
		fail(`a press at the centre of the leave mark lands on ${slot.covering} instead of the mark`);
	}

	// Every word in the rails clears the 4.5 to 1 small text asks for, against
	// what is really behind it, in both appearances.
	//
	// The stylesheet argues two of these numbers in prose — the caption on a
	// selected row was diluted, measured, and undiluted again because the quieter
	// ink came out at 4.0 on the amber and 3.1 on the teal. Nothing held the
	// answer, so any of the tokens underneath could have moved it back under the
	// line without a word changing. And the whole argument had only ever been made
	// in light: the rail is drawn from the same tokens in syrup, at different
	// values, and nothing had ever measured it there.
	//
	// This is the point in the run where the rail carries the most: two
	// directories, so every row wears a caption, one of them selected, and a
	// roster beside it.
	const RAIL_INK = [
		["the caption on the row being read", "#roomList li.here .rwhere-said"],
		["the caption on an ordinary row", "#roomList li:not(.here) .rwhere-said"],
		["the name of the room being read", "#roomList li.here .rname"],
		["a room's name", "#roomList li:not(.here) .rname"],
		["a room's count", "#roomList .rcount"],
		["a list's label", ".section-head span"],
		["the roster's label", ".members h2"],
		["a member's name", "#members .online .name"],
		["what the connection is doing", "#status"],
	] as const;
	const wasTheme = await tab.getAttribute("html", "data-theme");
	const tooFaint: string[] = [];
	// At rest, which takes saying twice: the pointer sent away and the keyboard
	// let go. Earlier checks left the pointer parked on a row and focus on the
	// caption it pressed, and either one swaps that caption's ink for the teal a
	// link wears — hover changes its ground too. What came back was an interactive
	// state wearing a resting state's name, and its numbers said nothing about the
	// rail a reader is looking at.
	await tab.mouse.move(0, 0);
	await tab.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
	for (const appearance of ["light", "dark"] as const) {
		await tab.evaluate((t) => document.documentElement.setAttribute("data-theme", t), appearance);
		// Settled first. Changing the appearance re-renders the rail, and a rail
		// arriving runs a two-tenths fade that starts at nothing — so a reading
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
		fail(`the rail does not clear 4.5 to 1 for small text: ${tooFaint.join("; ")}`);
	}

	await tab.click('.room-open:has-text("lobby")');
	await tab.waitForSelector('.bubble:has-text("hello from a browser peer")', { timeout: 10_000 })
		.catch(() => fail("the first server's room did not come back with its history"));
	return await leavingRun(tab, foreignLocator, foreignRoom, foreignRoomPort, captionOf);
}
