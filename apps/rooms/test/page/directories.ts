// Holding two directories at once.
//
// This is where "which directory" stops being rhetorical. Two servers each
// grant their own names and may each have a room with the same label, so every
// row has to say which one it belongs to, Settings has to stay about the page's
// locator, and leaving one must not disturb the other.

import type { Page } from "playwright";
import { namedDirectRow, namedRoomRow } from "../support/conversation_row.ts";
import { fail, openDirectoryCardFromCaption, openDirectoryCardFromSettings } from "./harness.ts";
import { proveDirectoryCommands } from "./directory_commands.ts";
import { run as dirColorsRun } from "./dir_colors.ts";
import { run as filteringRun } from "./filtering.ts";
import { run as leavingRun } from "./leaving.ts";

export async function run(
	tab: Page,
	second: Page,
	foreignLocator: string,
	foreignRoom: Deno.ChildProcess,
	foreignState: string,
	foreignRoomPort: number,
	/** The port this page's own room server holds. The last phase takes that
	 * server down and lets `serve.ts` stand it back up, which is the only
	 * directory in this run that can recover while another is still away. */
	homeRoomPort: number,
	/** The sweep for text a short line box has clipped, handed down from the
	 * scene that owns it. The filter's panel is the one surface in this run that
	 * is only ever on screen here, so it is swept here or nowhere. */
	descendersIntact: (where: string) => Promise<void>,
): Promise<void> {
	// Both servers at once, which is the whole of it: every row says which server
	// its room is on the moment there is more than one to tell apart, the local
	// room is still listed and still joined, and going back to it is one press.
	await tab.waitForFunction(
		() => document.querySelectorAll("#roomList li .rwhere").length >= 2,
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("holding two servers did not make the rooms say which server hosts each of them"));
	await tab.waitForFunction(
		() => {
			const joined = [...document.querySelectorAll("#roomList .rname")]
				.map((row) => row.textContent?.trim());
			return joined.includes("lobby") && joined.includes("elsewhere");
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("reaching a second server gave up the room held on the first"));

	// One list, and every row in it says which directory its room is on. A
	// directory is a property of a room rather than a box that owns a list of
	// them, so the second server adds rows to the list a reader already has
	// instead of rearranging it into something else.
	//
	// The order is the order the rooms were entered, as the rail promises:
	// nobody else's activity can move a row, and joining
	// appends rather than inserting into the middle, so the lobby entered first
	// is still first.
	const rail = await tab.evaluate(() => ({
		list: document.getElementById("roomList")?.tagName ?? "",
		// Anything in the list that is not a row. A wrapper around some of the
		// rows would be the grouping arriving again by another name.
		boxes: document.querySelectorAll("#roomList > :not(li)").length,
		rows: [...document.querySelectorAll("#roomList li")].map((row) => ({
			room: row.querySelector(".rname")?.textContent?.trim() ?? "",
			said: row.querySelector(".rwhere-said")?.textContent?.trim() ?? "",
			mark: row.getAttribute("data-dir") ?? "",
			// The words are a control, because asking what a directory is has to
			// be reachable from the row that is on it.
			asks: row.querySelector("button.rwhere") !== null,
		})),
	}));
	const lobby = rail.rows.find((row) => row.room === "lobby");
	const elsewhere = rail.rows.find((row) => row.room === "elsewhere");
	if (rail.list !== "UL" || rail.boxes > 0) {
		fail(`holding two servers turned the rooms list into a ${rail.list} holding ${rail.boxes} boxes of rows`);
	} else if (lobby === undefined || elsewhere === undefined) {
		fail(`the rooms list does not hold a row per room: ${JSON.stringify(rail.rows)}`);
	} else if (rail.rows.indexOf(lobby) > rail.rows.indexOf(elsewhere)) {
		fail(`a second server reordered the rooms a reader had already learned: ${JSON.stringify(rail.rows)}`);
	} else if (lobby.said !== "in this directory") {
		fail(`the row for the room on this page's own server says ${JSON.stringify(lobby.said)}`);
	} else if (!elsewhere.said.includes(String(foreignRoomPort))) {
		fail(`the row for the room on the second server says ${JSON.stringify(elsewhere.said)}`);
	} else if (!lobby.asks || !elsewhere.asks) {
		fail(`a row names its directory without offering to say what that directory is: ${JSON.stringify(rail.rows)}`);
	} else if (lobby.mark === "" || elsewhere.mark === "" || lobby.mark === elsewhere.mark) {
		fail(`the two servers' rooms wear ${JSON.stringify([lobby.mark, elsewhere.mark])} rather than a mark each`);
	}

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

	// The one stripe the screen carries runs from the reader to the directory the
	// room is on, so the bar over a conversation and the row that opened it have
	// to name the same directory. Both halves are checked, because each alone
	// passes while the feature is dead: the attribute can agree with the rail and
	// paint nothing, and the bar can be painted from a mark nobody chose.
	//
	// The second half removes the attribute, reads the bar again, and puts it
	// back inside one evaluate, so the page is in the state it started in. That
	// counterfactual is the point: without it a stripe that ignores the mark
	// entirely still reads as a gradient and still passes.
	const stripe = await tab.evaluate(() => {
		const area = document.querySelector(".workarea")!;
		const here = document.querySelector("#roomList li.here");
		const bar = document.querySelector(".topbar")!;
		const painted = () => getComputedStyle(bar, "::before").backgroundImage;
		const worn = area.getAttribute("data-dir");
		const withMark = painted();
		area.removeAttribute("data-dir");
		const without = painted();
		if (worn !== null) area.setAttribute("data-dir", worn);
		return { worn, row: here?.getAttribute("data-dir") ?? null, withMark, without };
	});
	if (stripe.worn === null || stripe.worn !== stripe.row) {
		fail(
			`the bar over the conversation and the row that opened it name different directories: ${
				JSON.stringify(stripe)
			}`,
		);
	}
	if (stripe.withMark === stripe.without) {
		fail(`the conversation's directory does not reach the bar over it: ${JSON.stringify(stripe)}`);
	}

	// A row's directory is a line under the room's name, not a second name beside
	// it, and the difference is carried entirely by its size. That size is worth
	// measuring because it is quiet to lose: the line is drawn as a caption,
	// captions here are buttons, and a button takes its surroundings' font unless
	// its own family is written to beat that. Nothing about the page looks broken
	// when it does not — the words are all still there, in the wrong place in the
	// reading order.
	const scale = await tab.evaluate(() => {
		const name = document.querySelector("#roomList li .rname");
		const caption = document.querySelector("#roomList li .rwhere");
		if (name === null || caption === null) return null;
		const px = (el: Element) => parseFloat(getComputedStyle(el).fontSize);
		return { name: px(name), caption: px(caption) };
	});
	if (scale === null) fail("the rooms list held no row naming its directory to size against a room name");
	else if (!(scale.caption <= scale.name * 0.85)) {
		fail(
			`a row's directory is set at ${scale.caption}px against a ${scale.name}px room name, ` +
				"so it reads as a name among the names rather than as a line under one",
		);
	}

	// Pressing the directory a row names opens that directory. Every directory
	// this tab holds uses the same conversation, this page's own included:
	// Settings keeps the page locator and a button that opens that conversation,
	// rather than answering the same three questions twice. The title chip opens
	// the card.
	const aboutOf = (room: string) => namedRoomRow(tab, room).locator(".rwhere");
	await openDirectoryCardFromCaption(tab, aboutOf("lobby"));
	const homeAt = await tab.evaluate(() => ({
		path: location.pathname,
		dir: new URLSearchParams(location.search).get("dir"),
		full: location.pathname + location.search,
	}));
	const homeCard = await tab.evaluate(() => ({
		title: document.getElementById("dircardTitle")?.textContent?.trim() ?? "",
		facts: [...document.querySelectorAll(".modal .dirfacts dt")].map((dt) => dt.textContent?.trim() ?? ""),
		mark: document.querySelector(".modal-card.dircard")?.getAttribute("data-dir") ?? "",
	}));
	if (homeCard.title !== "this directory") {
		fail(`the card for this page's own directory titled ${JSON.stringify(homeCard.title)}`);
	}
	if (!homeCard.facts.includes("Your name")) {
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
	await proveDirectoryCommands(tab);

	// Settings still names this page's locator, and its button opens that same
	// directory rather than growing a second copy of the facts. The title chip
	// opens the card.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle", { timeout: 10_000 });
	// The dialog reopens on whichever panel was last selected, so name the
	// one this check reads.
	await tab.click("#reachabilityTab");
	await tab.waitForSelector("#settingsAboutDir");
	const aboutBox = await tab.evaluate(() => {
		const about = document.querySelector("#settingsAboutDir");
		const group = about?.closest(".group");
		if (about == null || group == null) return null;
		return {
			// Placed by an actions row, at the end of the line, at the width of its
			// words: the form vocabulary's rule for every act on the plane.
			placed: about.closest(".actions") !== null,
			width: about.getBoundingClientRect().width,
			column: group.getBoundingClientRect().width,
		};
	});
	if (aboutBox == null) fail("Settings had no About this directory to measure");
	if (!aboutBox.placed || aboutBox.width >= aboutBox.column - 1) {
		fail(
			`About this directory spans the card (${aboutBox.width.toFixed(1)}px in a ${
				aboutBox.column.toFixed(1)
			}px group) rather than sitting at its words like Close`,
		);
	}
	await openDirectoryCardFromSettings(tab);
	await tab.waitForSelector("#settingsTitle", { state: "hidden", timeout: 10_000 });
	const fromSettings = (await tab.textContent("#dircardTitle"))?.trim() ?? "";
	if (fromSettings !== "this directory") {
		fail(`Settings opened a card titled ${JSON.stringify(fromSettings)}`);
	}
	const centered = await tab.evaluate(() => {
		const card = document.querySelector<HTMLElement>("#dircardTitle")?.closest(".modal-card");
		if (card == null) return null;
		const bounds = card.getBoundingClientRect();
		return Math.abs(bounds.left + bounds.width / 2 - innerWidth / 2);
	});
	if (centered == null || centered > 1) {
		fail(`Settings opened this directory ${centered ?? "without a card"}px off the viewport center`);
	}
	const priorViewport = tab.viewportSize();
	await tab.setViewportSize({ width: 390, height: 720 });
	const mobileCentered = await tab.evaluate(() => {
		const card = document.querySelector<HTMLElement>("#dircardTitle")?.closest(".modal-card");
		if (card == null) return null;
		const bounds = card.getBoundingClientRect();
		return {
			delta: Math.abs(bounds.left + bounds.width / 2 - innerWidth / 2),
			left: bounds.left,
			right: innerWidth - bounds.right,
		};
	});
	if (
		mobileCentered == null || mobileCentered.delta > 1 || mobileCentered.left < 23 || mobileCentered.right < 23
	) {
		fail(
			`the phone-sized directory card was not centered inside its modal padding: ${
				JSON.stringify(mobileCentered)
			}`,
		);
	}
	if (priorViewport != null) await tab.setViewportSize(priorViewport);
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
	// A reader selecting a line in the card and letting go past its edge has
	// not asked for anything. The click that gesture reports names the dialog,
	// which is the same thing the dim reports, so the card used to close and
	// take their place with it. Pressed inside, released outside, and it stays.
	await tab.mouse.move(dim.cardLeft + 24, dim.y);
	await tab.mouse.down();
	await tab.mouse.move(dim.x, dim.y, { steps: 8 });
	await tab.mouse.up();
	// Waited out rather than looked at: a card closes through a transition and
	// stays in the document while it runs, so asking straight away finds it
	// there whether or not the press took it.
	const dragClosed = await tab.locator("#dircardTitle")
		.waitFor({ state: "detached", timeout: 2_000 })
		.then(() => true, () => false);
	if (dragClosed) {
		fail("dragging out of the directory card and releasing on the dim closed it");
	}
	await tab.mouse.click(dim.x, dim.y);
	await tab.waitForSelector("#dircardTitle", { state: "detached", timeout: 10_000 })
		.catch(() => fail("pressing the dim around the directory card did not close it"));

	await openDirectoryCardFromCaption(tab, aboutOf("elsewhere"));
	// Two directories cannot share one address. This page's is `/directory`;
	// the other carries its locator, the same `?dir=` a room on it would.
	const otherAt = await tab.evaluate(() => ({
		path: location.pathname,
		dir: new URLSearchParams(location.search).get("dir"),
		full: location.pathname + location.search,
	}));
	if (homeAt.path !== "/directory" || homeAt.dir !== null) {
		fail(`this directory's address was ${homeAt.full}, not /directory`);
	}
	if (otherAt.path !== "/directory" || otherAt.dir === null) {
		fail(`the other directory's address was ${otherAt.full}, with no locator`);
	}
	if (homeAt.full === otherAt.full) {
		fail(`this directory and the other shared ${homeAt.full}`);
	}
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
	// Where you are here is a hanging menu, not more card. It is drawn at the end
	// of the document and lifted into the browser's top layer, so it is found by
	// what it is rather than by where it sits — and the card neither grows a
	// scrollbar to hold it nor has to promise never to clip.
	await tab.click("#dircardStanding");
	const standingMenu = await tab.evaluate(() => {
		const card = document.querySelector(".modal-card.dircard");
		const menu = document.querySelector(".menu-layer .standing-menu");
		if (card == null || menu == null) return null;
		const m = menu.getBoundingClientRect();
		return {
			scrolls: card.scrollHeight > card.clientHeight + 1,
			menuH: Math.round(m.height),
			// Whether it is painted where it was put, rather than clipped away by
			// something between it and the screen.
			onTop: document.elementFromPoint(m.left + m.width / 2, m.top + 6)?.closest(".standing-menu") != null,
			// What is actually there, so a failure names it rather than leaving
			// the next reader to go and look.
			over: (() => {
				const el = document.elementFromPoint(m.left + m.width / 2, m.top + 6);
				return el == null ? "nothing" : el.tagName.toLowerCase() + "." + String(el.className);
			})(),
			popover: document.querySelector(".menu-layer")?.matches(":popover-open") ?? null,
			at: { top: Math.round(m.top), left: Math.round(m.left), w: Math.round(m.width) },
		};
	});
	if (standingMenu === null) fail("where you are here did not open a menu on the directory card");
	else if (standingMenu.menuH < 40) {
		fail(`the directory card's standing menu did not paint: ${JSON.stringify(standingMenu)}`);
	} else if (!standingMenu.onTop) {
		fail(`the directory card's standing menu was drawn behind something: ${JSON.stringify(standingMenu)}`);
	} else if (standingMenu.scrolls) {
		fail(`opening where you are here made the directory card scroll: ${JSON.stringify(standingMenu)}`);
	}
	await tab.keyboard.press("Escape");
	await tab.waitForSelector(".menu-layer .standing-menu", { state: "detached", timeout: 5_000 });
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#dircardTitle", { state: "detached", timeout: 10_000 });
	await namedRoomRow(tab, "elsewhere").locator(".room-open").click();
	await tab.waitForSelector("#line:not([disabled])").catch(() =>
		fail("returning from the directory did not put the room back")
	);

	// The line naming a row's directory is a line of its own, so it has to line
	// up like one: it is inset to the row's content box, starting where the
	// room's own sigil starts and ending where that room's leave mark ends, so
	// the two lines of a row read as one thing rather than as a row with
	// something tucked under it. Measured rather than looked at, because a line
	// out by a few pixels reads as the rail having been nudged without saying
	// which half moved.
	const laidOut = await tab.evaluate(() => {
		const row = document.querySelector("#roomList li");
		const caption = row?.querySelector(".rwhere");
		const sigil = row?.querySelector(".hash");
		const mark = row?.querySelector(".room-leave");
		if (!caption || !sigil || !mark) return null;
		const box = (el: Element) => {
			const b = el.getBoundingClientRect();
			return { l: b.left, r: b.right };
		};
		const c = box(caption), p = box(sigil), m = box(mark);
		return {
			startsWhereTheRoomsMarkStarts: Math.abs(c.l - p.l),
			endsWhereItsMarkEnds: Math.abs(c.r - m.r),
			// Drawn at rest, not only under a pointer: this line is what opens the
			// card about the directory, and a target that appears when a pointer is
			// already on it was never findable.
			edge: parseFloat(getComputedStyle(caption).borderTopWidth),
		};
	});
	if (laidOut === null) fail("no room row carried a line naming its directory beside the marks that end it");
	else {
		if (!(laidOut.edge > 0)) {
			fail("a row's directory is drawn with no rectangle at rest, so it is a target only under a pointer");
		}
		for (const [what, off] of Object.entries(laidOut)) {
			if (what !== "edge" && off > 1) {
				fail(`a row's directory does not line up with its room: ${what} is out by ${off.toFixed(1)}px`);
			}
		}
	}

	// The bar marking the row being read is the row's height less a little at
	// each end, not a number of its own. A row grows a second line when it has
	// one to carry, and a fixed bar that reads as half of a short row gets a
	// third of a tall one; nothing about that looks broken enough to notice
	// without measuring it.
	const marking = await tab.evaluate(() => {
		const row = document.querySelector("#roomList li.here");
		if (row === null) return null;
		const mark = parseFloat(getComputedStyle(row, "::before").height);
		return { row: row.getBoundingClientRect().height, mark };
	});
	if (marking === null) fail("no room in the rail was being read, so the mark had no row to be measured against");
	else if (!(marking.mark > 0) || Math.abs(marking.row - marking.mark - 14) > 1) {
		fail(
			`the mark on the row being read is ${marking.mark.toFixed(1)}px on a ${
				marking.row.toFixed(1)
			}px row, which is not that row's height less its inset`,
		);
	}

	// One takes the other's place, so they have to occupy the same place, and the
	// place a reader aims at is the middle of the mark rather than its right edge.
	//
	// The press is measured too, and separately, because every other reading here
	// was already perfect while the control could not be pressed: the count fades
	// to nothing when the mark takes its slot, and something at zero opacity still
	// takes clicks. Visible, enabled, aligned, and dead through its own middle is
	// a state only this question can see.
	const slot = await tab.evaluate(() => {
		const row = document.querySelector("#roomList li");
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
	if (slot === null) fail("no room row carried both a badge and the leave mark that shares its slot");
	else if (slot.dy > 1 || slot.dx > 1) {
		fail(
			`the leave mark and the badge do not share a slot: ` +
				`${slot.dy.toFixed(1)}px apart vertically and ${slot.dx.toFixed(1)}px across`,
		);
	} else if (!slot.pressable) {
		fail(`a press at the centre of the leave mark lands on ${slot.covering} instead of the mark`);
	}

	// Two rules that belong to every surface wearing a directory's colour, not
	// to any one of them, and this is the point in the run where the rail
	// carries the most for them to sweep.
	await dirColorsRun(tab);

	await tab.click('.room-open:has-text("lobby")');
	await tab.waitForSelector('.bubble:has-text("hello from a browser peer")', { timeout: 10_000 })
		.catch(() => fail("the first server's room did not come back with its history"));

	// ── A direct line says which directory introduced it ────────────────
	// A direct line belongs to the directory that introduced it, because the
	// counterparty is a nickname and a nickname is that directory's to grant and
	// reclaim. Two directories may each have an `alice` and they are two people,
	// so the same line a room row carries is what tells them apart here.
	//
	// It takes a line open while two directories are held, which nothing before
	// this point in the run produces: the second peer stepped out of the room
	// several scenes ago, so it walks them back in, opens a line from the roster
	// the way a reader does, and walks them out again — the state the scene after
	// this one expects to find.
	{
		await second.fill("#room", "lobby");
		await second.click("#joinBtn");
		await second.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
			.catch(() => fail("the second peer could not walk back in to be written to"));
		// The directory grants whatever name is free, so the name to write to is
		// read off their own roster row rather than assumed.
		const mine = await second.evaluate(() => {
			const names = [...document.querySelectorAll("#members .name")].map((el) => el.textContent ?? "");
			const at = names.findIndex((name) => name.endsWith(" (you)"));
			return { names, at, own: at < 0 ? "" : names[at].slice(0, -" (you)".length) };
		});
		if (mine.own === "") fail("the second peer's own roster row never said which name it was granted");
		const who = mine.own;
		// The reader's own row is the first one. They know exactly one name in the
		// list and would otherwise scan for it, a longer scan the busier the room,
		// so first is the one position that does not move as people come and go.
		//
		// Read on this tab and not on the second peer, because this is the tab the
		// rule does work on: its own name sorts after the other member's, so
		// without the rule it would be second. The second peer's name happens to
		// sort first anyway, and asking there proves only that sorting exists.
		//
		// The check says so itself rather than trusting that to stay true. It wants
		// a name below its own that would outrank it alphabetically, and fails if
		// this room ever stops offering one, because a check that cannot tell the
		// rule from its absence passes either way.
		const ours = await tab.evaluate(() => {
			const names = [...document.querySelectorAll("#members .name")].map((el) => el.textContent ?? "");
			const at = names.findIndex((name) => name.endsWith(" (you)"));
			const own = at < 0 ? "" : names[at].slice(0, -" (you)".length);
			return { names, at, own, outranked: names.slice(1).some((name) => name.localeCompare(own) < 0) };
		});
		if (ours.at !== 0) {
			fail(`the reader's own row sits at ${ours.at} of ${ours.names.length}: ${JSON.stringify(ours.names)}`);
		} else if (!ours.outranked) {
			fail(
				`nobody here sorts before ${JSON.stringify(ours.own)}, so first proved nothing: ${
					JSON.stringify(ours.names)
				}`,
			);
		}
		const theirRow = `#members li:has(.name:text-is(${JSON.stringify(who)})) .dm-btn`;
		await tab.waitForSelector(theirRow, { timeout: 30_000 })
			.catch(() => fail(`no direct-line button for ${JSON.stringify(who)} in the room both peers are in`));
		await tab.click(theirRow);
		await namedDirectRow(tab, who).waitFor({ timeout: 10_000 })
			.catch(() => fail("opening a direct line did not put a row for it in the rail"));

		const lines = await tab.evaluate((name) => {
			const row = [...document.querySelectorAll("#dmList li")]
				.find((li) => li.querySelector(".rname")?.textContent?.trim() === name);
			return {
				list: document.getElementById("dmList")?.tagName ?? "",
				boxes: document.querySelectorAll("#dmList > :not(li)").length,
				// Three ways of saying the same thing, and the row owes a reader
				// every one of them: the color it wears, the directory drawn on it,
				// and the directory named in what it announces.
				mark: row?.getAttribute("data-dir") ?? "",
				said: row?.querySelector(".rwhere-said")?.textContent?.trim() ?? "",
				announced: row?.querySelector(".dm-open")?.getAttribute("aria-label") ?? "",
				// And the same control a room row carries, because a person's
				// directory is as worth asking about as a room's.
				asks: row?.querySelector("button.rwhere") !== null,
			};
		}, who);
		if (lines.list !== "UL" || lines.boxes > 0) {
			fail(`the direct list is a ${lines.list} holding ${lines.boxes} boxes of rows rather than a list of them`);
		} else if (lines.mark === "") {
			fail("the direct row wears no directory color, so two people with one nickname look like one person");
		} else if (lines.said !== "in this directory") {
			fail(`the direct row says ${JSON.stringify(lines.said)} rather than the directory that introduced it`);
		} else if (!lines.announced.includes("this directory")) {
			fail(`the direct row does not name its directory in what it announces: ${JSON.stringify(lines.announced)}`);
		} else if (!lines.asks) {
			fail("the direct row names its directory without offering to say what that directory is");
		}

		// Back to the room, which is where the scene after this one starts, and
		// the second peer back out of it.
		await tab.click('.room-open:has-text("lobby")');
		await tab.waitForSelector("#line:not([disabled])", { timeout: 30_000 })
			.catch(() => fail("the room did not come back after reading a direct line"));
		const theirs = namedRoomRow(second, "lobby");
		await theirs.hover();
		await theirs.locator(".room-leave").click();
		await theirs.waitFor({ state: "hidden", timeout: 30_000 });
		await second.click(".wordmark-link");
		await second.waitForSelector("#joinBtn", { timeout: 30_000 })
			.catch(async () =>
				fail(`the second peer could not step back out of the room: ${await second.locator("body").innerText()}`)
			);
	}
	// How much of all that a reader is looking at is theirs to say, and a
	// directory is one of the things they can say it by. That belongs here
	// rather than in a scene of its own, because a question about which
	// directory only has more than one answer while two are held. It borrows the
	// second peer to leave a line waiting in a room, and hands it back at the
	// join card, which is where this scene picked it up.
	await filteringRun(tab, second, foreignRoomPort, descendersIntact);

	await leavingRun(tab, foreignLocator, foreignRoom, foreignState, foreignRoomPort, homeRoomPort, aboutOf);
}
