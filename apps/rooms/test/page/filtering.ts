// Choosing how much of the rail you are looking at.
//
// The rail is a flat list of rooms and direct lines in the order the reader
// made, and a filter is how that reader narrows it without anybody rearranging
// it for them. So the thing to prove is mostly what the filter does not do: it
// takes rows out and puts them back, and every row still standing is where it
// was.
//
// How the control itself is drawn (the heading that opens it, and the form
// inside) is next door in `filter_form.ts`, which this scene calls once the
// rail is holding enough for the questions to have more than one answer.
//
// It runs inside the two-directories scene, where a directory is a real choice
// with more than one answer. It makes the rooms it needs, borrows the second
// peer to leave a line waiting in one of them, and leaves the page where it
// found it.

import type { Page } from "playwright";
import { namedRoomRow } from "../support/conversation_row.ts";
import { fail } from "./harness.ts";
import { run as filterFormRun } from "./filter_form.ts";

/** What the rail is drawing, and what the filter says about it. */
interface Rail {
	rooms: string[];
	dms: string[];
	/** Anything in either list that is not a row. A wrapper around some of the
	 * rows would be a grouping arriving by another name, which is the thing a
	 * filter exists instead of. */
	boxes: number;
	heads: number;
	/** What the rooms heading says beside its own name: the two numbers once
	 * something is hidden, and nothing at all while nothing is. */
	said: string;
	/** What each list says in place of the rows it is not drawing. */
	heldRooms: string[];
	heldDms: string[];
	/** The rows drawing a count of lines nobody has read, by list. Read off the
	 * badge rather than assumed, so what the filter is asked for and what the
	 * rail says is waiting are two separate readings that have to agree. */
	waitingRooms: string[];
	waitingDms: string[];
}

const readRail = (tab: Page) =>
	tab.evaluate((): Rail => {
		const named = (selector: string) =>
			[...document.querySelectorAll(selector)].map((el) => el.textContent?.trim() ?? "");
		const waiting = (rows: string, badge: string) =>
			[...document.querySelectorAll(rows)]
				.filter((row) => row.querySelector(badge) !== null)
				.map((row) => row.querySelector(".rname")?.textContent?.trim() ?? "");
		return {
			rooms: named("#roomList li .rname"),
			dms: named("#dmList li .rname"),
			boxes: document.querySelectorAll("#roomList > :not(li), #dmList > :not(li)").length,
			heads: document.querySelectorAll(".section-head").length,
			said: document.querySelector("#railFilter .rail-filter-count")?.textContent?.trim() ?? "",
			// What either list says when the filter is holding rows back.
			heldRooms: named("#roomList li.empty"),
			heldDms: named("#dmList li.empty"),
			// A room row's badge counts either unread lines or the people in the
			// room, and only the unread one is marked. A direct row's badge is
			// only ever unread.
			waitingRooms: waiting("#roomList li", ".rcount.unread"),
			waitingDms: waiting("#dmList li", ".rcount"),
		};
	});

/** Whether one list is what is left of another after rows were taken out.
 *
 * The whole promise in one question. A filter that hid the right rows and then
 * put the rest in some other order fails this while passing every count it
 * could be asked for. It does not matter what the other order was: how well
 * each matched, which directory each was on, anything at all. */
function isWhatIsLeftOf(all: readonly string[], shown: readonly string[]): boolean {
	let at = 0;
	for (const name of shown) {
		const found = all.indexOf(name, at);
		if (found < 0) return false;
		at = found + 1;
	}
	return true;
}

/** Make a room from the rail's own field, the way a reader does. */
async function makeRoom(tab: Page, name: string, privateRoom: boolean): Promise<void> {
	await tab.click("#newRoomBtn");
	await tab.waitForSelector("#newRoomInput", { state: "visible", timeout: 10_000 });
	if (privateRoom) {
		await tab.click(".newroom-private");
		await tab.click(".newroom-private");
	}
	await tab.fill("#newRoomInput", name);
	await tab.press("#newRoomInput", "Enter");
	await tab.waitForFunction(
		(room) => [...document.querySelectorAll("#roomList .rname")].some((el) => el.textContent?.trim() === room),
		name,
		{ timeout: 30_000 },
	).catch(() => fail(`naming ${JSON.stringify(name)} in the rail did not put a row for it in the list`));
}

/** Leave a room from its own row. */
async function leaveRoom(tab: Page, name: string): Promise<void> {
	const row = namedRoomRow(tab, name);
	await row.hover();
	await row.locator(".room-leave").click();
	await tab.waitForFunction(
		(room) => ![...document.querySelectorAll("#roomList .rname")].some((el) => el.textContent?.trim() === room),
		name,
		{ timeout: 10_000 },
	).catch(() => fail(`leaving ${JSON.stringify(name)} left its row in the rail`));
}

/** Send the second peer into a room to say one line, and back out again.
 *
 * A room this tab is not reading counts what arrives in it, and nothing else in
 * the page produces a row with something waiting on it. The peer starts and
 * ends at the join card, which is where the scene around this one leaves it. */
async function sayInto(peer: Page, room: string, line: string): Promise<void> {
	await peer.fill("#room", room);
	await peer.click("#joinBtn");
	await peer.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail(`the second peer could not walk into ${JSON.stringify(room)} to say anything`));
	await peer.fill("#line", line);
	await peer.press("#line", "Enter");
	await peer.waitForSelector(`.bubble:has-text(${JSON.stringify(line)})`, { timeout: 30_000 })
		.catch(() => fail(`the second peer's line never landed in ${JSON.stringify(room)}`));
	const row = namedRoomRow(peer, room);
	await row.hover();
	await row.locator(".room-leave").click();
	await peer.waitForSelector("#joinBtn", { timeout: 30_000 })
		.catch(() => fail(`the second peer could not step back out of ${JSON.stringify(room)}`));
}

/** Type a needle into the name question and wait for the rail to answer it. */
async function askName(tab: Page, needle: string): Promise<void> {
	await tab.fill("#railFilter-name", needle);
	await tab.waitForFunction(
		(text) => (document.getElementById("railFilter-name") as HTMLInputElement | null)?.value === text,
		needle,
		{ timeout: 5_000 },
	);
}

export async function run(
	tab: Page,
	second: Page,
	foreignRoomPort: number,
	/** The sweep for text a short line box has clipped, handed down rather than
	 * written again: the panel below is only ever on screen inside this scene. */
	descendersIntact: (where: string) => Promise<void>,
): Promise<void> {
	// Four rooms and two directories, which is what it takes to ask an honest
	// question about order. Two rooms cannot tell insertion order apart from
	// alphabetical, from directory order, or from how early a needle matched,
	// and every one of those is a way a filter could quietly rearrange a list.
	//
	// The names are chosen so those answers disagree. Entered as lobby,
	// elsewhere, council, orchard, the needle "o" matches lobby, council and
	// orchard, and it matches them at the second character, the third, and the
	// first. A filter that ranked its rows by how well each matched would put
	// orchard at the top, which is a different list from the one the reader
	// made.
	//
	// Earlier scenes leave rooms of their own in this rail, so what is expected
	// below is read off the list rather than written out: the four this scene
	// reasons about have to be there, in that order, and whatever else the run
	// has collected rides along.
	await makeRoom(tab, "council", false);
	await makeRoom(tab, "orchard", true);

	// One of them is left with something waiting on it, which is what gives the
	// question about unread rows two answers to tell apart. A room being read
	// counts nothing, so the room the line goes into has to be one this tab is
	// not in. Naming which room that is rather than opening one, because the
	// scene ends by opening the lobby and pressing the room you are already in
	// is how a reader puts the rail away.
	const reading = await tab.evaluate(() =>
		document.querySelector("#roomList li.here .rname")?.textContent?.trim() ?? ""
	);
	if (reading === "council") {
		fail("the tab is reading the room a line was about to be left waiting in");
	}
	await sayInto(second, "council", "a line nobody here has read");
	await tab.waitForFunction(
		(room) => {
			const row = [...document.querySelectorAll("#roomList li")]
				.find((li) => li.querySelector(".rname")?.textContent?.trim() === room);
			return row?.querySelector(".rcount.unread")?.textContent === "1";
		},
		"council",
		{ timeout: 30_000 },
	).catch(() => fail("a line said into a room nobody was reading never showed as waiting on that room's row"));

	const before = await readRail(tab);
	const entered = ["lobby", "elsewhere", "council", "orchard"];
	for (const room of entered) {
		if (!before.rooms.includes(room)) {
			fail(`the scene needs ${room} in the rail and found ${JSON.stringify(before.rooms)}`);
		}
	}
	if (!isWhatIsLeftOf(before.rooms, entered)) {
		fail(`the rooms are not in the order they were entered: ${JSON.stringify(before.rooms)}`);
	}
	if (before.said !== "") {
		fail(`the rooms heading says ${JSON.stringify(before.said)} before anything has been asked of it`);
	}
	// Exactly one row in the whole rail has something waiting on it. A scene
	// where several did could be passed by a filter that answered some other
	// question and happened to leave a list of the same length.
	if (before.waitingRooms.join() !== "council" || before.waitingDms.length !== 0) {
		fail(
			`the scene needs one room waiting to be read and no direct lines, and found ` +
				`${JSON.stringify(before.waitingRooms)} and ${JSON.stringify(before.waitingDms)}`,
		);
	}

	// How the control itself is drawn is next door, and it leaves the panel open
	// for the questions below to be answered in.
	await filterFormRun(tab, descendersIntact);

	// ── A name hides rows and moves none ─────────────────────────────────
	await askName(tab, "o");
	await tab.waitForFunction(
		() => !document.querySelector("#roomList")?.textContent?.includes("elsewhere"),
		undefined,
		{ timeout: 5_000 },
	).catch(() => fail("asking for rooms whose name holds an o left one that does not in the rail"));
	const byName = await readRail(tab);
	if (byName.rooms.join() !== ["lobby", "council", "orchard"].join()) {
		fail(
			`the name question left ${JSON.stringify(byName.rooms)} rather than the three rooms holding an o, ` +
				"in the order they were entered",
		);
	}
	if (!isWhatIsLeftOf(before.rooms, byName.rooms)) {
		fail(
			`filtering by name rearranged the rail: ${JSON.stringify(byName.rooms)} out of ${
				JSON.stringify(before.rooms)
			}`,
		);
	}
	if (byName.boxes !== 0 || byName.heads !== 2) {
		fail(
			`filtering grew ${byName.boxes} boxes of rows and ${byName.heads} headings, ` +
				"which is the grouping the filter exists instead of",
		);
	}
	// It says so on the line as well as in the list, because a reader who
	// filtered and looked away has to be able to tell a narrowed rail from a
	// rail that lost something.
	if (!/^\d+ of \d+$/.test(byName.said)) {
		fail(`the rooms heading says ${JSON.stringify(byName.said)} while the filter is holding rows back`);
	}
	if (!byName.heldRooms.some((said) => said.includes("hidden by the filter"))) {
		fail(`the rooms list did not say a row was being held back: ${JSON.stringify(byName.heldRooms)}`);
	}

	// Nothing matches, and the list says which of the two things that is: the
	// rail is not empty, it is filtered.
	await askName(tab, "zzzz");
	await tab.waitForFunction(
		() => document.querySelectorAll("#roomList li .rname").length === 0,
		undefined,
		{ timeout: 5_000 },
	).catch(() => fail("a needle no room holds still left rooms in the rail"));
	const nothing = await readRail(tab);
	const emptied: [string, string[]][] = [["rooms", nothing.heldRooms]];
	// The direct list only has the two answers to tell apart when it holds a
	// line to hide, which this scene does and the ones before it may not.
	if (before.dms.length > 0) emptied.push(["direct", nothing.heldDms]);
	for (const [list, said] of emptied) {
		if (!said.some((line) => line.includes("filter"))) {
			fail(`with nothing matching, the ${list} list says ${JSON.stringify(said)} rather than naming the filter`);
		}
	}
	await askName(tab, "");

	// ── Which directory is one question among them ───────────────────────
	// Turning the second directory off takes its room out and leaves the three
	// on this one exactly where they were.
	const foreignChoice = tab.locator("#railFilterPanel .filter-choice")
		.filter({ hasText: String(foreignRoomPort) });
	if (await foreignChoice.count() !== 1) {
		fail("the directory question does not offer the second directory this tab holds");
	}
	await foreignChoice.click();
	await tab.waitForFunction(
		() => !document.querySelector("#roomList")?.textContent?.includes("elsewhere"),
		undefined,
		{ timeout: 5_000 },
	).catch(() => fail("turning a directory off left its room in the rail"));
	const byDir = await readRail(tab);
	const elsewhereGone = before.rooms.filter((room) => room !== "elsewhere");
	if (byDir.rooms.join() !== elsewhereGone.join()) {
		fail(
			`turning a directory off left ${JSON.stringify(byDir.rooms)} rather than ` +
				`${JSON.stringify(elsewhereGone)}`,
		);
	}
	if (await foreignChoice.locator(".checkbox").isChecked()) {
		fail("a directory turned off still says it is in view");
	}
	await foreignChoice.click();
	await tab.waitForFunction(
		() => document.querySelector("#roomList")?.textContent?.includes("elsewhere") === true,
		undefined,
		{ timeout: 5_000 },
	).catch(() => fail("turning a directory back on did not bring its room back"));

	// ── A row the question does not apply to stays in view ───────────────
	// Who can get into a room is a question a direct line has no answer to, and
	// a line between two people is not a public room that failed the test. So
	// asking for private rooms takes the public ones away and leaves every
	// direct line where it was.
	const publicChoice = tab.locator("#railFilterPanel .filter-choice").filter({ hasText: "Public" });
	await publicChoice.click();
	await tab.waitForFunction(
		() => document.querySelectorAll("#roomList li .rname").length === 1,
		undefined,
		{ timeout: 5_000 },
	).catch(() => fail("asking for private rooms did not take the public ones out of the rail"));
	const byAccess = await readRail(tab);
	if (byAccess.rooms.join() !== "orchard") {
		fail(`asking for private rooms left ${JSON.stringify(byAccess.rooms)} rather than the one private room`);
	}
	if (byAccess.dms.join() !== before.dms.join()) {
		fail(
			`a question about who can get into a room took direct lines with it: ` +
				`${JSON.stringify(byAccess.dms)} out of ${JSON.stringify(before.dms)}`,
		);
	}

	// ── Whether anything is waiting is one question among them ───────────
	// The public rooms come back first, because this question is being asked on
	// its own rather than on top of another one.
	await publicChoice.click();
	await tab.waitForFunction(
		(rooms) => document.querySelectorAll("#roomList li .rname").length === rooms,
		before.rooms.length,
		{ timeout: 5_000 },
	).catch(() => fail("turning the public rooms back on did not bring them back"));

	// Turning the read rows off leaves the rows with something waiting on them,
	// and what those are is read off the badges rather than written out here. A
	// filter that answered some other question and left a list of the right
	// length is a different list, and this says which.
	const caughtUpChoice = tab.locator("#railFilterPanel .filter-choice").filter({ hasText: "Caught up" });
	if (await caughtUpChoice.count() !== 1) fail("the filter does not offer to put the rows already read away");
	await caughtUpChoice.click();
	await tab.waitForFunction(
		(rooms) => document.querySelectorAll("#roomList li .rname").length === rooms,
		before.waitingRooms.length,
		{ timeout: 5_000 },
	).catch(() => fail("asking for the rows with something waiting on them left the rooms already read in view"));
	const waiting = await readRail(tab);
	if (waiting.rooms.join() !== before.waitingRooms.join() || waiting.dms.join() !== before.waitingDms.join()) {
		fail(
			`asking for rows with something waiting left ${JSON.stringify(waiting.rooms)} and ` +
				`${JSON.stringify(waiting.dms)} rather than ${JSON.stringify(before.waitingRooms)} and ` +
				`${JSON.stringify(before.waitingDms)}`,
		);
	}
	if (!isWhatIsLeftOf(before.rooms, waiting.rooms)) {
		fail(`filtering by what is waiting rearranged the rail: ${JSON.stringify(waiting.rooms)}`);
	}

	// And the other way round, which is the half a question with one populated
	// answer cannot prove on its own: turning the waiting rows off takes that
	// one row away and leaves every other row exactly where it was.
	await caughtUpChoice.click();
	const unreadChoice = tab.locator("#railFilterPanel .filter-choice").filter({ hasText: "Unread" });
	if (await unreadChoice.count() !== 1) fail("the filter does not offer to put the rows waiting to be read away");
	await unreadChoice.click();
	await tab.waitForFunction(
		(rooms) => document.querySelectorAll("#roomList li .rname").length === rooms,
		before.rooms.length - before.waitingRooms.length,
		{ timeout: 5_000 },
	).catch(() => fail("turning the rows waiting to be read off left one of them in the rail"));
	const read = await readRail(tab);
	const stillRead = before.rooms.filter((room) => !before.waitingRooms.includes(room));
	if (read.rooms.join() !== stillRead.join()) {
		fail(
			`turning the waiting rows off left ${JSON.stringify(read.rooms)} rather than ` +
				`${JSON.stringify(stillRead)}`,
		);
	}
	if (read.dms.join() !== before.dms.join()) {
		fail(
			`turning the waiting rows off took direct lines with nothing waiting on them too: ` +
				`${JSON.stringify(read.dms)} out of ${JSON.stringify(before.dms)}`,
		);
	}

	// ── The way out of all of it ─────────────────────────────────────────
	await tab.click("#railFilterClear");
	await tab.waitForFunction(
		(rooms) => document.querySelectorAll("#roomList li .rname").length === rooms,
		before.rooms.length,
		{ timeout: 5_000 },
	).catch(() => fail("showing everything again did not bring every room back"));
	const after = await readRail(tab);
	if (after.rooms.join() !== before.rooms.join() || after.dms.join() !== before.dms.join()) {
		fail(
			`the rail came back as ${JSON.stringify(after.rooms)} and ${JSON.stringify(after.dms)} ` +
				`rather than ${JSON.stringify(before.rooms)} and ${JSON.stringify(before.dms)}`,
		);
	}
	if (after.said !== "") {
		fail(`with nothing asked the rooms heading still says ${JSON.stringify(after.said)}`);
	}

	// Escape puts the panel away and hands the keyboard back to what opened it,
	// which is what every other menu in this page does.
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#railFilterPanel", { state: "detached", timeout: 5_000 })
		.catch(() => fail("Escape did not put the filter panel away"));
	const holding = await tab.evaluate(() => document.activeElement?.id ?? "");
	if (holding !== "railFilter") {
		fail(`closing the filter left the keyboard on ${JSON.stringify(holding)} rather than on what opened it`);
	}

	// The page as the next scene expects to find it: in the lobby, holding the
	// two rooms it held before this one.
	await tab.click('.room-open:has-text("lobby")');
	await tab.waitForSelector("#line:not([disabled])", { timeout: 30_000 })
		.catch(() => fail("the lobby did not come back after the filter scene"));
	await leaveRoom(tab, "orchard");
	await leaveRoom(tab, "council");
}
