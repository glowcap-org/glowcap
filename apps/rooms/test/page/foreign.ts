// A room owned by another server.
//
// This is where 'which directory' stops being rhetorical: two directories, two
// grants of a name, two rooms that may share a label. Everything here is about
// the page saying which one it means, and about leaving one without disturbing
// the other.

import type { Page } from "playwright";
import { fail, fillSettled, freePort, reachDirectoryOnCard } from "./harness.ts";
export async function run(
	tab: Page,
	httpPort: number,
	foreignRoomPort: number,
	hangPort: number,
): Promise<string> {
	// ── A room owned by another server ──────────────────────────────────
	// The locator changes which directory the room is entered on; the page does
	// not proxy a foreign room through the server that served its HTML. Staying in
	// the local room while doing it is the point: a second directory is opened
	// beside the first, not instead of it.
	await tab.setViewportSize({ width: 1280, height: 800 });
	const foreignLocator = `127.0.0.1:${foreignRoomPort}`;
	// Reached from the rail's own field, which is the way a reader finds it: type
	// a name, then say it is somewhere else. The name goes with you to the card.
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "elsewhere");
	// The room being named is drawn as one of the rooms already named: a mark, a
	// name, and under it the line saying where it will land. That line is a
	// target of its own, so it is measured as one — a glyph and its words as a
	// single piece in the middle of a rectangle the panel draws at rest. It is no
	// longer two entries placed by the columns above.
	const panel = await tab.evaluate(() => {
		const box = document.querySelector("#newRoom");
		const line = box?.querySelector(".rwhere");
		const glyph = box?.querySelector(".rwhere .icon-svg");
		const said = box?.querySelector(".rwhere-said");
		// The line ends with whatever it ends with. It carries the destination
		// and, after it, the word that acts; measuring the centring from the
		// destination alone would read a line that is perfectly centred as
		// pushed left by exactly the width of the word beside it.
		const last = line?.lastElementChild;
		if (!line || !glyph || !said || !last) return null;
		const at = (el: Element) => {
			const b = el.getBoundingClientRect();
			return { l: b.left, r: b.right };
		};
		const c = at(line), i = at(glyph), w = at(said), e = at(last);
		return {
			markBesideItsWords: Math.abs(w.l - i.r) > 12 ? Math.abs(w.l - i.r) : 0,
			centredInTheLine: Math.abs((i.l - c.l) - (c.r - e.r)),
			edge: parseFloat(getComputedStyle(line).borderTopWidth),
		};
	});
	if (panel === null) fail("the panel for a room being named carried no line saying where it lands");
	else {
		// Asked apart from the measurements, because it is a yes and not a
		// distance: folded in as a number it would have to pick one that trips the
		// threshold below, and picking one that did not is how a check comes to
		// pass with its own defect in front of it.
		if (!(panel.edge > 0)) fail("the panel's directory line is drawn with no rectangle at rest");
		for (const [what, off] of Object.entries(panel)) {
			if (what !== "edge" && off > 1) {
				fail(`the panel for a new room is not built like a room row: ${what} is out by ${off.toFixed(1)}px`);
			}
		}
	}
	// Reached by keyboard on purpose. A pointer press and a key press take
	// different paths into a button — Enter and Space raise a click with no
	// mousedown before it — so a proof that only ever clicks cannot tell a
	// control that works from one that is focusable, visibly focused, and dead.
	await tab.focus("#newRoomElsewhere");
	await tab.press("#newRoomElsewhere", "Enter");
	await tab.waitForSelector("#joinForm", { timeout: 10_000 })
		.catch(() => fail("the rail offered no way to reach a room on another server"));
	const carried = await tab.inputValue("#room");
	if (carried !== "elsewhere") {
		fail(`the room name did not travel to the join card; it holds ${JSON.stringify(carried)}`);
	}
	const aimed = await tab.inputValue("#locator");
	if (aimed !== "") {
		fail(
			`the join card did not keep this directory selected; the locator holds ${JSON.stringify(aimed)}`,
		);
	}

	// The addresses already in hand live on the locator field, behind the
	// directory mark that opens them — not as a row between this question and
	// the next. Opening that mark has to put the list under the field it fills.
	await tab.click("#joinLocator");
	const placed = await tab.evaluate(() => {
		const field = document.getElementById("locator")?.closest(".join-field");
		const picks = document.querySelector(".locator-picks");
		if (!(field instanceof HTMLElement) || !(picks instanceof HTMLElement)) return null;
		return picks.getBoundingClientRect().top - field.getBoundingClientRect().bottom;
	});
	if (placed === null) fail("the join form's directory mark did not offer the held addresses");
	else if (placed < 0 || placed > 24) {
		fail(`the held addresses opened ${placed.toFixed(0)}px from the locator field, not under it`);
	}
	await tab.keyboard.press("Escape");

	// Stopping an act that is still waiting. An address this tab has not reached
	// is a connect rather than a join, and the busy button keeps saying so rather
	// than becoming a second press of it; the × beside it is the stop, the same
	// mark that takes a file chip back. The locator has to hang, not refuse:
	// a port nobody is holding is reset in a millisecond, and the card would
	// settle before the × had a frame to be the thing this proof pressed.
	const cancelled = `127.0.0.1:${hangPort}`;
	await tab.fill("#locator", cancelled);
	await tab.click("#joinBtn");
	await tab.waitForSelector("#joinStop", { timeout: 10_000 })
		.catch(() => fail("joining did not offer a way to stop waiting"));
	await tab.click("#joinStop");
	await tab.waitForFunction(
		() =>
			document.getElementById("joinStop") === null &&
			(document.getElementById("joinBtn")?.textContent ?? "").trim() === "Connect",
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("stopping a connect left the card waiting"));
	const afterStop = await tab.evaluate(() => ({
		error: (document.getElementById("joinError")?.textContent ?? "").trim(),
		locator: (document.getElementById("locator") as HTMLInputElement | null)?.value ?? "",
		named: document.querySelectorAll("#roomList .rwhere").length,
	}));
	if (afterStop.error !== "") {
		fail(`stopping a join was reported as a refusal: ${JSON.stringify(afterStop.error)}`);
	}
	if (afterStop.locator !== cancelled) {
		fail(`stopping a join did not leave the locator to correct; it holds ${JSON.stringify(afterStop.locator)}`);
	}
	if (afterStop.named !== 0) {
		fail("stopping a join kept the abandoned address as a server in the rail");
	}

	// The same address again. Stopping cannot withdraw the outstanding dial, so a
	// retry must wait that attempt out and then dial, not join the abandoned one
	// and fail the moment it is torn down.
	await tab.click("#joinBtn");
	await tab.waitForSelector("#joinStop", { timeout: 10_000 })
		.catch(() => fail("the same address after stopping did not wait; it settled at once"));
	// Read it off the document rather than waiting for it: a refusal that was
	// never made has no element, and waiting for one is waiting out the timeout.
	const retried = await tab.evaluate(() => document.getElementById("joinError")?.textContent?.trim() ?? "");
	if (retried !== "") {
		fail(`the same address after stopping was refused at once: ${JSON.stringify(retried)}`);
	}
	await tab.click("#joinStop");
	await tab.waitForFunction(
		() =>
			document.getElementById("joinStop") === null &&
			(document.getElementById("joinBtn")?.textContent ?? "").trim() === "Connect",
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("stopping the retried connect left the card waiting"));

	// A typo first. An address nobody has ever reached is most likely wrong, so
	// the page must let it go rather than keep a row for it and dial it forever —
	// and it must leave what was typed in the field, because correcting an
	// address is an edit and not a retype.
	const typo = `127.0.0.1:${freePort()}`;
	await tab.fill("#locator", typo);
	await tab.click("#joinBtn");
	await tab.waitForFunction(
		() => (document.getElementById("joinError")?.textContent ?? "").length > 0,
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("a locator that cannot be reached never settled; the card waits for good"));
	// And the line under the rail stops claiming an attempt that has ended.
	await tab.waitForFunction(
		() => !(document.getElementById("status")?.textContent ?? "").startsWith("reaching"),
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("the status line went on reaching for a server the page had given up on"));
	const kept = await tab.inputValue("#locator");
	if (kept !== typo) {
		fail(`a refused locator was not left in the field to correct; it holds ${JSON.stringify(kept)}`);
	}
	const locatorSaid = await tab.evaluate(() => {
		const field = document.getElementById("locator");
		return {
			invalid: field?.getAttribute("aria-invalid"),
			described: field?.getAttribute("aria-describedby"),
		};
	});
	if (locatorSaid.invalid !== "true" || locatorSaid.described !== "joinError") {
		fail(`a refused locator was not marked on the field Connect is about; ${JSON.stringify(locatorSaid)}`);
	}
	// Nothing was kept for it. A second server would have made every row in the
	// rail say which of the two it was on.
	const named = await tab.locator("#roomList .rwhere").count();
	if (named !== 0) fail("an address that never answered was kept as a server in the rail");

	// Then text that is not an address at all, which is the other half of the same
	// mistake and the half that used to take the page down. The one above points
	// nowhere and is refused by the dial; this one cannot be parsed, and the parse
	// threw where nothing was catching — so a person who mistyped badly enough got
	// the error screen instead of a correction, losing the room they were in.
	// Checked as a crash rather than as a message: the interface has to still be
	// there afterwards.
	await tab.fill("#locator", "not a locator at all");
	await tab.click("#joinBtn");
	await tab.waitForFunction(
		() => (document.getElementById("joinError")?.textContent ?? "").length > 0,
		undefined,
		{ timeout: 20_000 },
	).catch(() => fail("text that is not an address was never refused on the join card"));
	const survived = await tab.evaluate(() => ({
		rail: document.getElementById("roomList") !== null,
		rooms: document.querySelectorAll("#roomList li").length,
		kept: (document.getElementById("locator") as HTMLInputElement | null)?.value ?? null,
	}));
	if (!survived.rail) fail("text that is not an address took the whole interface down to the error screen");
	if (survived.rooms === 0) fail("text that is not an address cost the reader the room they were already in");
	if (survived.kept !== "not a locator at all") {
		fail(`what was typed was not left to correct; the field holds ${JSON.stringify(survived.kept)}`);
	}

	// Under a different name on purpose. A directory grants the name, and grants
	// it for itself alone, so being alice on one and bo on another is ordinary
	// rather than exotic — and it is the state in which anything claiming a single
	// name for every room a reader is in has to be wrong about some of them.
	await fillSettled(tab, "#locator", foreignLocator);
	await fillSettled(tab, "#nick", "bo");
	// The directory first, then the room: this address has not been reached, so
	// the card's act is a connect until it has been.
	if (await reachDirectoryOnCard(tab, "elsewhere") === "question") await tab.click("#joinBtn");
	// This wait failed twice in runs nobody could reproduce afterwards, so it
	// reports the card rather than only the disappointment. A bare "did not
	// join" says nothing about whether the fields still held what was typed,
	// whether the join was refused with a reason, or whether it is still
	// waiting — and those three point at three different layers. That report is
	// what eventually named the cause: a card holding the previous address
	// beside a freshly filled name, which is why the two fills above wait for
	// their fields to agree. Both halves stay — one stopped that flake, the
	// other is how the next one gets diagnosed.
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(async () => {
			const card = await tab.evaluate(() => ({
				room: (document.getElementById("room") as HTMLInputElement | null)?.value,
				locator: (document.getElementById("locator") as HTMLInputElement | null)?.value,
				nick: (document.getElementById("nick") as HTMLInputElement | null)?.value,
				refused: document.getElementById("joinError")?.textContent,
				status: document.getElementById("status")?.textContent,
				button: document.getElementById("joinBtn")?.textContent?.trim(),
				rooms: document.querySelectorAll("#roomList li").length,
			}));
			fail("the browser did not join the room owned by the second server: " + JSON.stringify(card));
		});
	// The foot's identity row says who this reader is, and a name is one
	// directory's grant. Across directories that granted two names it may not
	// claim one covers both: it says the home directory's grant, wears that
	// directory's own mark so the name is visibly one directory's, counts the
	// others in words, and carries the whole list on its title — while the
	// state row under it says how this reader stands. Saying the foreign name
	// for everything would be the kind of wrong that reads as right: a real
	// name, on a real directory, and not the one the home rooms know this
	// reader by.
	await tab.waitForFunction(
		() => {
			const row = document.querySelector("#standingBtn .foot-names");
			const name = (row?.querySelector(".name")?.textContent ?? "").trim();
			const more = (document.querySelector("#standingBtn .foot-more")?.textContent ?? "").trim();
			const state = (document.getElementById("status")?.textContent ?? "").trim();
			return name === "web-alice" && more === "+1 name" && state === "here" &&
				row?.getAttribute("data-dir") === "home";
		},
		undefined,
		{ timeout: 15_000 },
	).catch(async () =>
		fail(
			"holding rooms under two granted names, the foot does not say the home grant plus a count " +
				"over a settled state row; it says " +
				JSON.stringify(
					await tab.evaluate(() => ({
						name: document.querySelector("#standingBtn .foot-names .name")?.textContent ?? "",
						more: document.querySelector("#standingBtn .foot-more")?.textContent ?? "",
						state: document.getElementById("status")?.textContent ?? "",
						mark: document.querySelector("#standingBtn .foot-names")?.getAttribute("data-dir") ?? "",
					})),
				),
		)
	);
	// The full list, on the row's title, in the rail's own directory vocabulary:
	// the page's own directory is "this directory", never a raw locator.
	const whoTitle = (await tab.getAttribute("#standingBtn .foot-names", "title")) ?? "";
	if (!whoTitle.includes("web-alice on this directory") || !whoTitle.includes("bo on ")) {
		fail(`the identity row's title does not list every grant with its directory: ${JSON.stringify(whoTitle)}`);
	}
	if (whoTitle.includes("://")) {
		fail(`the identity row's title leaks a raw locator: ${JSON.stringify(whoTitle)}`);
	}
	await tab.fill("#line", "hello across servers");
	await tab.press("#line", "Enter");
	await tab.waitForSelector('.bubble:has-text("hello across servers")', { timeout: 30_000 })
		.catch(() => fail("the foreign room did not echo over its own capability"));
	// Settings is about *this* directory, and stays about it while a room on
	// another one is being read. It used to answer with whichever directory the
	// conversation on screen was on, so the same heading meant two different
	// things depending on where you had been — checked from the foreign room for
	// exactly that reason, because that is the state in which the two answers
	// differ.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	// The dialog reopens on whichever panel was last selected, so name the
	// one this check reads.
	await tab.click("#reachabilityTab");
	const shownLocator = (await tab.textContent("#directoryLocator"))?.trim() ?? "";
	if (shownLocator === foreignLocator) {
		fail("Settings described the directory of the room being read, not the one the page came from");
	}
	const homeAnswer = await fetch(`http://127.0.0.1:${httpPort}/locator`);
	const homeLocator = (await homeAnswer.text()).trim();
	if (shownLocator !== homeLocator) {
		fail(`Settings names ${JSON.stringify(shownLocator)} as this directory, but the page came from ${homeLocator}`);
	}
	await tab.keyboard.press("Escape");

	return foreignLocator;
}
