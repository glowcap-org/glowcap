import { spawnWeb } from "../support/web_front.ts";
/// <reference lib="dom" />
// The page's address, and what standing at one means.
//
// A conversation the reader is in has an address, so it can be sent to
// somebody, bookmarked, or returned to with the browser's own back button.
// That makes the address a second way of saying what the store already says,
// and the whole risk is the two disagreeing: an address that opens the wrong
// place, a conversation that never reaches the address bar, a back button
// that walks somewhere the page is not.
//
// So this drives the disagreements rather than the feature:
//
//   1. A cold deep link at /room/<name> arrives with that room named, and
//      joining leaves the address where it already was.
//   2. Opening a second room writes its address, and back and forward walk
//      between the two, the view and the address together, never one
//      without the other.
//   3. Following an address never rearranges the furniture. The rail is the
//      reader's, not the link's, so navigating with it closed leaves it
//      closed and navigating with it open leaves it open.
//   4. A private room's key never reaches the address: its link carries the
//      label alone, so it reopens the held conversation in this tab and is
//      an ordinary join card to a tab that was never handed the room.
//   5. The card standing in for a link is a gate on it, so its fields answer
//      that link rather than whatever this browser used last, and asking for
//      the card with nothing named still offers what was used last.
//   6. An address nothing answers folds back to the front.
//   7. A refused room nickname remains the reader's choice, offers a deliberate
//      alternative, and a roster already held can offer that alternative live.
//   8. An empty nickname field promises the connected directory's granted
//      name, and joining through that promise uses it.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the installed archives
// (serve.ts's room server is the Rust process), and a Playwright Chromium.
// Run: `deno run --allow-all apps/rooms/test/web/routes_test.ts`.

import { type Browser, chromium, type Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { reapOwned } from "../support/children.ts";
import { freePort, waitForHttp } from "../support/rooms_server.ts";
import { fail } from "../page/harness.ts";

const ROOT = new URL("../../../../", import.meta.url).pathname;
const FIRST = "arrivals";
const SECOND = "departures";
const PRIVATE = "backroom";
const NICK_CHOICE = "nick-choice";

function watch(tab: Page, who: string): void {
	tab.on("pageerror", (error) => console.error(`  [${who} page error]`, error.message));
	tab.on("console", (message) => {
		if (message.type() === "error") console.error(`  [${who} console.error]`, message.text());
	});
}

/** Where the page says it is: the path plus whatever the address carries. */
function addressOf(tab: Page): Promise<string> {
	return tab.evaluate(() => location.pathname + location.search);
}

/** Whether the rail is showing, as a reader sees it rather than as a field. */
function railShown(tab: Page): Promise<boolean> {
	return tab.evaluate(() => !document.querySelector(".app")?.classList.contains("rooms-hidden"));
}

/** The room the conversation column is showing, from the title the page
 * stamps, the one place the view's own answer is readable as text. */
async function showing(tab: Page): Promise<string> {
	return (await tab.title()).replace(" · glowcap rooms", "").replace(/^\(\d+\)\s*/, "");
}

const deadline = setTimeout(() => fail("web-routes scenario timed out after 180s"), 180_000);

const httpPort = freePort();
const roomPort = freePort();
spawnWeb({
	args: ["--transport=tcp", String(httpPort), String(roomPort)],
	cwd: ROOT,
	stdout: "null",
	stderr: "inherit",
});

let browser: Browser | null = null;
try {
	await waitForHttp(httpPort);
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const tab = await (await browser.newContext()).newPage();
	watch(tab, "reader");

	// ── A link names where to stand ──────────────────────────────────────
	await tab.goto(`http://127.0.0.1:${httpPort}/room/${FIRST}`);
	await establishLocalSession(tab);
	await tab.waitForSelector("#boot", { state: "detached", timeout: 60_000 })
		.catch(() => fail("the page never left its opening screen at a room address"));
	await tab.waitForFunction(
		(room) => (document.querySelector("#room") as HTMLInputElement | null)?.value === room,
		FIRST,
		{ timeout: 30_000 },
	).catch(() => fail("a cold room link did not arrive with that room named"));
	await tab.fill("#nick", "ada");
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail("the room named by the link never opened"));
	if (await addressOf(tab) !== `/room/${FIRST}`) {
		fail(`joining moved the address to ${await addressOf(tab)}`);
	}

	// ── Opening writes the address; back and forward walk it ─────────────
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", SECOND);
	await tab.press("#newRoomInput", "Enter");
	await tab.waitForFunction(
		(room) => location.pathname === `/room/${room}` && document.title.includes(`#${room}`),
		SECOND,
		{ timeout: 30_000 },
	).catch(async () => fail(`opening a second room left the address at ${await addressOf(tab)}`));

	await tab.goBack();
	await tab.waitForFunction(
		(room) => location.pathname === `/room/${room}` && document.title.includes(`#${room}`),
		FIRST,
		{ timeout: 30_000 },
	).catch(async () => fail(`back landed at ${await addressOf(tab)} showing "${await showing(tab)}"`));
	await tab.goForward();
	await tab.waitForFunction(
		(room) => location.pathname === `/room/${room}` && document.title.includes(`#${room}`),
		SECOND,
		{ timeout: 30_000 },
	).catch(async () => fail(`forward landed at ${await addressOf(tab)} showing "${await showing(tab)}"`));

	// ── The rail is the reader's, not the link's ─────────────────────────
	// Navigation must not rearrange the furniture: whatever the reader left
	// the rail doing, following an address leaves it doing.
	// The rail's own control hides it; the conversation's mark brings it back.
	await tab.click("#railToggle");
	await tab.waitForFunction(
		() => document.querySelector(".app")?.classList.contains("rooms-hidden") === true,
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("the rail did not close when its control was pressed"));
	await tab.goBack();
	await tab.waitForFunction(
		(room) => document.title.includes(`#${room}`),
		FIRST,
		{ timeout: 30_000 },
	).catch(() => fail("back did not reach the first room with the rail closed"));
	if (await railShown(tab)) fail("following an address opened the rail the reader had closed");
	await tab.click("#backBtn");
	await tab.waitForFunction(
		() => document.querySelector(".app")?.classList.contains("rooms-hidden") === false,
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("the rail did not open when the conversation's mark was pressed"));
	await tab.goForward();
	await tab.waitForFunction(
		(room) => document.title.includes(`#${room}`),
		SECOND,
		{ timeout: 30_000 },
	).catch(() => fail("forward did not reach the second room with the rail open"));
	if (!await railShown(tab)) fail("following an address closed the rail the reader had open");

	// ── A private room's key is not in its address ───────────────────────
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", PRIVATE);
	// Open, moderated, private: two presses to reach the one whose key must stay
	// out of the address.
	await tab.click(".newroom-private");
	await tab.click(".newroom-private");
	await tab.press("#newRoomInput", "Enter");
	await tab.waitForFunction(
		(label) => document.title.includes(label),
		PRIVATE,
		{ timeout: 30_000 },
	).catch(() => fail("the private room never opened"));
	// Privacy is what the room's policy says, and the policy arrives after the
	// room opens. The address must settle on the private form once it does.
	await tab.waitForFunction(
		(room) => location.pathname === `/room/${room}` && new URLSearchParams(location.search).get("private") === "1",
		PRIVATE,
		{ timeout: 15_000 },
	).catch(async () => fail(`a private room's address is ${await addressOf(tab)}`));
	const privateAddress = await addressOf(tab);
	// Its key is the whole authority to it, so nothing resembling one may be
	// in the address a reader could paste anywhere.
	const key = await tab.evaluate(() => {
		const rows = [...document.querySelectorAll("#roomList li")];
		return rows.length > 0 ? rows.length : 0;
	});
	if (key === 0) fail("the rail lost its rooms");
	if (/[0-9a-f]{16,}/i.test(privateAddress)) {
		fail(`a private room's address carries something key-shaped: ${privateAddress}`);
	}
	// A tab that was never handed the room gets the ordinary join card, not
	// somebody else's private room.
	const stranger = await (await browser.newContext()).newPage();
	watch(stranger, "stranger");
	await stranger.goto(`http://127.0.0.1:${httpPort}${privateAddress}`);
	await establishLocalSession(stranger);
	await stranger.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await stranger.waitForSelector("#joinBtn", { timeout: 30_000 })
		.catch(() => fail("a private room's link did not degrade to the join card"));
	const strangerRoom = await stranger.evaluate(() =>
		(document.querySelector("#room") as HTMLInputElement | null)?.value ?? ""
	);
	if (strangerRoom === PRIVATE) {
		fail("a private room's link offered its label as a room to join");
	}
	await stranger.close();

	// ── A gate reflects what it gates ────────────────────────────────────
	// The card standing in for a room link is a gate on that link, so every
	// field it holds has to answer it. A returning reader arrives with a
	// directory they used before, and the link says nothing about it out loud;
	// it only names a room here, which can mean this directory and nothing
	// else. Silence there would let the earlier address stand, so a link to a
	// room on this page would offer to join it somewhere the link never mentioned.
	//
	// The same tab then asks for the card with nothing named, which is where
	// the remembered address is the right answer. Both halves are driven,
	// because a fix that stopped offering anything would pass the first
	// on its own.
	const returning = await browser.newContext();
	await returning.addInitScript(() => {
		localStorage.setItem(
			"rooms.view-preferences",
			JSON.stringify({
				theme: "light",
				notifyOn: false,
				railOpen: true,
				rosterOpen: true,
				settingsTab: "session",
				opsPane: "listeners",
				remembered: { locator: "ocapn://elsewhereelsewhere.iroh", room: "lobby", nick: "ada" },
			}),
		);
	});
	const back = await returning.newPage();
	watch(back, "returning");
	await back.goto(`http://127.0.0.1:${httpPort}/room/${FIRST}`);
	await establishLocalSession(back);
	await back.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await back.waitForFunction(
		(room) => (document.querySelector("#room") as HTMLInputElement | null)?.value === room,
		FIRST,
		{ timeout: 30_000 },
	).catch(() => fail("a room link did not name its room over a remembered one"));
	const gatedAt = await back.evaluate(() => (document.querySelector("#locator") as HTMLInputElement | null)?.value);
	if (gatedAt !== "") {
		fail(`the gate on a room here offered another directory: ${gatedAt}`);
	}
	const gatedAs = await back.evaluate(() => ({
		value: (document.querySelector("#nick") as HTMLInputElement | null)?.value,
		placeholder: (document.querySelector("#nick") as HTMLInputElement | null)?.placeholder,
	}));
	if (gatedAs.value !== "" || gatedAs.placeholder !== "guest") {
		fail(`a stale remembered nickname displaced the directory's current offer: ${JSON.stringify(gatedAs)}`);
	}
	// And it says so once, in the line where a card explains itself, rather
	// than annotating each field it filled.
	const gateSays = await back.evaluate(() => document.querySelector("#joinForm .lead")?.textContent ?? "");
	if (!gateSays.includes(`#${FIRST}`) || !gateSays.includes("this page's directory")) {
		fail(`the gate did not say what it was gating: ${JSON.stringify(gateSays)}`);
	}
	// Nothing named, so what this browser used last is exactly what to offer.
	await back.goto(`http://127.0.0.1:${httpPort}/join`);
	await establishLocalSession(back);
	await back.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await back.waitForFunction(
		() => (document.querySelector("#locator") as HTMLInputElement | null)?.value !== "",
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("asking for the card with nothing named forgot the directory last used"));
	const openRoom = await back.evaluate(() => (document.querySelector("#room") as HTMLInputElement | null)?.value);
	if (openRoom !== "lobby") fail(`the card with nothing named offered "${openRoom}" rather than the last room`);
	await back.close();
	await returning.close();

	// ── A nickname suggestion is a choice, not a silent rename ───────────
	// Another member establishes the directory's authoritative answer first.
	// Its live registration is enough to reject the same explicit name while it
	// is typed, without sending an intent the room can only refuse later.
	const holderContext = await browser.newContext();
	const holder = await holderContext.newPage();
	watch(holder, "nickname holder");
	await holder.goto(`http://127.0.0.1:${httpPort}/room/${NICK_CHOICE}`);
	await establishLocalSession(holder);
	await holder.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await holder.fill("#nick", "bob");
	await holder.click("#joinBtn");
	await holder.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail("the nickname holder did not enter its room"));
	await holder.locator('#members li:has-text("bob")').waitFor({ timeout: 30_000 })
		.catch(() => fail("the nickname holder's room did not grant bob"));

	await tab.goto(`http://127.0.0.1:${httpPort}/join`);
	await establishLocalSession(tab);
	await tab.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await tab.fill("#room", NICK_CHOICE);
	await tab.waitForSelector("#joinPrivate:disabled", { timeout: 30_000 })
		.catch(() => fail("the joining tab did not receive the holder's live room listing"));
	await tab.fill("#nick", "bob");
	await tab.locator('#joinNickSuggestion:has-text("bob-2")').waitFor({ timeout: 30_000 })
		.catch(async () =>
			fail(
				`a room nickname refusal did not offer bob-2 at the nickname field: ${
					JSON.stringify({
						address: await addressOf(tab),
						nick: await tab.locator("#nick").inputValue().catch(() => null),
						form: await tab.locator("#joinForm").textContent().catch(() => null),
						nickError: await tab.locator("#joinNickError").evaluate((node) => node.outerHTML).catch(() =>
							null
						),
						holderRoster: await holder.locator("#members").textContent().catch(() => null),
						title: await tab.title(),
					})
				}`,
			)
		);
	if (!(await tab.locator("#joinBtn").isDisabled())) {
		fail("a nickname known to be registered remained submittable");
	}
	if (await tab.inputValue("#nick") !== "bob") {
		fail("live validation silently replaced the unavailable nickname instead of preserving the reader's choice");
	}
	await tab.click("#joinNickSuggestion");
	if (await tab.inputValue("#nick") !== "bob-2") {
		fail("taking the nickname suggestion did not become the field's intent");
	}
	if (await tab.locator("#joinBtn").isDisabled()) {
		fail("taking an available nickname suggestion did not enable Join");
	}
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail("the explicitly chosen nickname suggestion did not join"));
	await tab.locator('#members li:has-text("bob-2")').waitFor({ timeout: 30_000 })
		.catch(() => fail("the room did not grant the nickname the reader explicitly chose"));

	// Once this tab holds the exact room, its live roster is sufficient to warn
	// before another submit. It still does not claim that a directory listing or
	// an unrelated room knows this answer.
	await tab.goto(`http://127.0.0.1:${httpPort}/join`);
	await establishLocalSession(tab);
	await tab.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await tab.fill("#room", NICK_CHOICE);
	await tab.waitForSelector("#joinPrivate:disabled", { timeout: 30_000 })
		.catch(() => fail("the reloaded tab did not recognize its held room as live"));
	await tab.fill("#nick", "bob");
	await tab.locator('#joinNickSuggestion:has-text("bob-3")').waitFor({ timeout: 30_000 })
		.catch(() => fail("the held room's live roster did not skip bob-2 and offer bob-3"));
	await holder.close();
	await holderContext.close();

	// ── An empty nickname is the displayed grant ─────────────────────────
	// This directory most recently granted the explicitly chosen `bob-2` above.
	// Success spends that exact override: the next form must already be empty,
	// while its placeholder names the live grant. Submitting the optional answer
	// must request that offer rather than silently falling back to another identity.
	await tab.goto(`http://127.0.0.1:${httpPort}/join`);
	await establishLocalSession(tab);
	await tab.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	if (await tab.inputValue("#nick") !== "") {
		fail("a successful join left its exact nickname override prefilled for the next room");
	}
	const promisedNick = await tab.getAttribute("#nick", "placeholder");
	if (promisedNick !== "bob-2") {
		fail(`the empty nickname field promised ${JSON.stringify(promisedNick)}, not the granted name`);
	}
	await tab.fill("#room", "nick-promise");
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail("joining with the nickname field empty never opened the room"));
	await tab.locator("#members li", { hasText: promisedNick ?? "" }).waitFor({ timeout: 30_000 })
		.catch(async () =>
			fail(
				`the room did not grant the nickname promised by the empty field: ${
					JSON.stringify({
						promisedNick,
						roster: await tab.locator("#members").textContent().catch(() => null),
						title: await tab.title(),
					})
				}`,
			)
		);

	// ── An address nothing answers ───────────────────────────────────────
	await tab.goto(`http://127.0.0.1:${httpPort}/nowhere/at/all`);
	await establishLocalSession(tab);
	await tab.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await tab.waitForFunction(() => location.pathname === "/", undefined, { timeout: 30_000 })
		.catch(async () => fail(`an unanswered address stayed at ${await addressOf(tab)}`));

	console.log(
		"PASS: the rooms page's address is a shareable place to stand — a cold link arrives " +
			"named, opening writes it, back and forward walk it with the view, following one " +
			"never moves the rail, a private room's key stays out of it, a gate reflects what " +
			"it gates rather than what was used last, nickname collisions remain explicit choices, " +
			"an empty nickname uses its displayed " +
			"directory grant, and an address nothing answers folds back to the front",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
