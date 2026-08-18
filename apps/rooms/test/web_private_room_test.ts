// A room nobody can look up, and the only way into one.
//
// A public room is reached by its name: the directory lists it, `enter` finds
// it, and knowing what it is called is the whole of being able to walk in. A
// private room is the same room with none of that — it is in no list, `enter`
// does not find it, and its name is a label two of them may share. What is left
// is the reference, and holding one is being in the room.
//
// So an invitation is the room itself: `/invite` hands the live reference over
// the direct line this reader already has, carried across as a third-party
// handoff, with the room and the directory told nothing about who was offered
// what. `/link` is the durable sibling: data the room minted, for an offer that
// must outlive its sessions.
//
// Here both routes to the server spell it the same way, so taking up a handed
// room reuses the session the guest already holds and his name needs no proof.
// A deployment where the spellings diverge opens a second session, and the
// name-capability voucher seats him there; that half is pinned hermetically in
// server_test.ts, where a byte pipe makes the divergence on purpose.
//
// So this drives the difference rather than the feature. Two tabs on one
// directory:
//
//   ada  makes a private room called "plans" and says something in it.
//   bo   asks for the room list, and it is not there.
//   bo   names a room "plans" himself, and gets a different room — same label,
//        nothing of ada's in it, which is what makes the label a label.
//   ada  hands hers over. bo takes it up and hears what she said next.
//   bo   is offered a second one and declines it, which lets the reference go.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives
// (serve.ts's room server is native), and a Playwright Chromium.
// Run: `deno run --allow-all apps/rooms/test/web_private_room_test.ts`.

import { type Browser, chromium, type Page } from "playwright";

const WEB = new URL("../web/serve.ts", import.meta.url).pathname;
const ROOT = new URL("../../../", import.meta.url).pathname;
const ROOM = "lobby";
const LABEL = "plans";
const PRIVATE_LINE = "just us then";
const PUBLIC_LINE = "this is my own plans room";

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

function freePort(): number {
	const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (listener.addr as Deno.NetAddr).port;
	listener.close();
	return port;
}

async function waitForHttp(port: number): Promise<void> {
	for (let i = 0; i < 400; i++) {
		try {
			const answer = await fetch(`http://127.0.0.1:${port}/locator`);
			await answer.body?.cancel();
			if (answer.status === 200) return;
		} catch {
			// not up yet
		}
		await new Promise((resolve) => setTimeout(resolve, 50));
	}
	fail("serve.ts did not answer with a room locator");
}

async function joinAs(browser: Browser, port: number, nick: string): Promise<Page> {
	const context = await browser.newContext();
	const tab = await context.newPage();
	tab.on("pageerror", (error) => console.error(`  [${nick} page error]`, error.message));
	tab.on("console", (message) => {
		if (message.type() === "error") console.error(`  [${nick} console.error]`, message.text());
	});
	await tab.goto(`http://127.0.0.1:${port}/`);
	await tab.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await tab.fill("#nick", nick);
	await tab.fill("#room", ROOM);
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 }).catch(async () => {
		const status = await tab.textContent("#status").catch(() => "?");
		fail(`${nick} never joined; status="${status}"`);
	});
	return tab;
}

async function say(tab: Page, text: string): Promise<void> {
	await tab.fill("#line", text);
	await tab.press("#line", "Enter");
}

/** Name a room in the rail's own field, privately or not. */
async function makeRoom(tab: Page, label: string, privately: boolean): Promise<void> {
	await tab.click("#newRoomBtn");
	const publicName = await tab.getAttribute("#newRoomInput", "placeholder");
	if (publicName !== "room name") {
		fail(`the rail field said ${JSON.stringify(publicName)} before the lock was pressed`);
	}
	await tab.fill("#newRoomInput", label);
	if (privately) {
		await tab.click(".newroom-private");
		const privateName = await tab.getAttribute("#newRoomInput", "placeholder");
		if (privateName !== "private room name") {
			fail(`the rail field said ${JSON.stringify(privateName)} after the lock was pressed`);
		}
	}
	await tab.press("#newRoomInput", "Enter");
}

/** Every room row this tab holds, as a reader sees it: what it is called, and
 * whether it wears the lock that says nobody can walk in by name. */
function railRooms(tab: Page): Promise<{ name: string; locked: boolean; here: boolean }[]> {
	return tab.evaluate(() =>
		[...document.querySelectorAll("#roomList li")].map((row) => ({
			name: row.querySelector(".rname")?.textContent ?? "",
			locked: row.querySelector(".hash svg") !== null,
			here: row.classList.contains("here"),
		}))
	);
}

function said(tab: Page): Promise<string> {
	return tab.evaluate(() => document.getElementById("log")?.textContent ?? "");
}

const deadline = setTimeout(() => fail("web-private-room scenario timed out after 180s"), 180_000);

const httpPort = freePort();
const roomPort = freePort();
const web = new Deno.Command("deno", {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		"--allow-write",
		"--allow-net",
		"--allow-env",
		"--allow-run",
		WEB,
		String(httpPort),
		String(roomPort),
	],
	cwd: ROOT,
	stdout: "null",
	stderr: "inherit",
}).spawn();

let browser: Browser | null = null;
try {
	await waitForHttp(httpPort);
	browser = await chromium.launch({ args: ["--no-sandbox"] });

	const ada = await joinAs(browser, httpPort, "ada");
	const bo = await joinAs(browser, httpPort, "bo");
	await ada.locator('#members li:has-text("bo")').waitFor({ state: "visible", timeout: 60_000 })
		.catch(() => fail("the two tabs never met in the public room"));

	// ── A room that is in no list ────────────────────────────────────────
	await makeRoom(ada, LABEL, true);
	await ada.waitForFunction(
		() => document.querySelector("#roomList li .hash svg") !== null,
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("naming a room privately did not put a private room in the rail"));
	const hers = await railRooms(ada);
	const locked = hers.filter((row) => row.locked);
	if (locked.length !== 1 || locked[0].name !== LABEL || !locked[0].here) {
		fail(`making a private room did not open exactly one, on screen: ${JSON.stringify(hers)}`);
	}
	// The panel at the top of a room says what kind of room a reader is in, and
	// the open sentence over a private room would be the worst answer here.
	const panel = (await ada.textContent(".conv-intro")) ?? "";
	if (!panel.includes("private") || panel.includes("Anyone who knows its name")) {
		fail(`a private room's panel does not say what it is: ${JSON.stringify(panel)}`);
	}
	if (await ada.locator(".conv-intro .hash svg").count() !== 1) {
		fail("a private room's welcome title did not wear the lock");
	}
	// The private room's spoken name — the label with no hash — is the rail
	// row's and the intro panel's, both pinned above. The rail foot no longer
	// names rooms at all: it is the reader's identity-and-standing lockup, so
	// there is no third spelling to hold to the same authority.
	await say(ada, PRIVATE_LINE);
	await ada.waitForFunction(
		(text) => (document.getElementById("log")?.textContent ?? "").includes(text),
		PRIVATE_LINE,
		{ timeout: 30_000 },
	).catch(() => fail("ada's own line never landed in her private room"));

	// The directory does not offer it, to anybody. `/list` is the whole of what
	// a directory will say about its rooms, so this is the surface a stranger
	// would find it on if it were findable at all.
	await say(bo, "/list");
	await bo.waitForFunction(
		(room) => (document.getElementById("log")?.textContent ?? "").includes(`#${room}: `),
		ROOM,
		{ timeout: 30_000 },
	).catch(() => fail("/list never answered"));
	const listed = await said(bo);
	if (listed.includes(`#${LABEL}: `)) {
		fail(`the directory offered a private room in its list: ${JSON.stringify(listed.slice(-200))}`);
	}

	// And to somebody who was not here when it was made. Bo's list was built
	// from the changes the directory pushed him, which is one of the two ways a
	// room can be offered; a tab arriving now is handed the whole list at once,
	// which is the other, and a guard on one of them is not a guard.
	const cy = await joinAs(browser, httpPort, "cy");
	await say(cy, "/list");
	await cy.waitForFunction(
		(room) => (document.getElementById("log")?.textContent ?? "").includes(`#${room}: `),
		ROOM,
		{ timeout: 30_000 },
	).catch(() => fail("/list never answered for a tab that arrived later"));
	const arrived = await said(cy);
	if (arrived.includes(`#${LABEL}: `)) {
		fail(`a tab arriving later was handed a private room in its list: ${JSON.stringify(arrived.slice(-200))}`);
	}

	// ── The label is a label ─────────────────────────────────────────────
	// Naming the same thing gets a room of one's own rather than a way into
	// hers, which is the difference between a name and an address.
	await makeRoom(bo, LABEL, false);
	await bo.waitForFunction(
		(label) => [...document.querySelectorAll("#roomList .rname")].some((row) => row.textContent === label),
		LABEL,
		{ timeout: 30_000 },
	).catch(() => fail("bo could not open a public room of his own by that name"));
	await say(bo, PUBLIC_LINE);
	await bo.waitForFunction(
		(text) => (document.getElementById("log")?.textContent ?? "").includes(text),
		PUBLIC_LINE,
		{ timeout: 30_000 },
	).catch(() => fail("bo's own line never landed in his own room"));
	const inBos = await said(bo);
	if (inBos.includes(PRIVATE_LINE)) {
		fail("naming a room the same thing reached the private one");
	}
	const inHers = await said(ada);
	if (inHers.includes(PUBLIC_LINE)) {
		fail("a public room of the same name reached into the private one");
	}

	// ── Handed over ──────────────────────────────────────────────────────
	await say(ada, "/invite bo");
	await bo.waitForSelector(".inviterow", { timeout: 30_000 })
		.catch(() => fail("handing the room over never reached bo"));
	const offered = (await bo.textContent(".inviterow")) ?? "";
	if (!offered.includes(LABEL) || !offered.includes("ada")) {
		fail(`the invitation does not say what it is or who it is from: ${JSON.stringify(offered)}`);
	}
	await bo.click(".inviterow .room-open");
	await bo.waitForFunction(
		() => document.querySelector("#roomList li.held.here") !== null,
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("taking up the invitation did not open the room"));
	const afterTaking = await railRooms(bo);
	if (afterTaking.filter((row) => row.locked).length !== 1) {
		fail(`taking up one invitation left bo with the wrong rooms: ${JSON.stringify(afterTaking)}`);
	}
	// He arrives under his own name, and ada is still here to see it. Both
	// halves of this assertion have caught a real defect: a room behaviour that
	// closed over the session it was spawned for blamed bo's subscribe on ada's
	// connection, which silently replaced her own membership — she vanished
	// from her own room, and bo arrived into an empty roster.
	await ada.waitForFunction(
		() => [...document.querySelectorAll("#members li")].some((row) => row.textContent?.includes("bo")),
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("ada never saw bo arrive in her private room"));
	const roster = await ada.evaluate(() =>
		[...document.querySelectorAll("#members li")].map((row) => row.textContent ?? "")
	);
	if (roster.some((row) => row.includes("bo-"))) {
		fail(`the handed reference seated bo as a suffixed stranger: ${JSON.stringify(roster)}`);
	}
	// What she says now reaches him: he is in the room, by the reference she
	// handed him and nothing else.
	const second = "and here is the thing itself";
	await say(ada, second);
	await bo.waitForFunction(
		(text) => (document.getElementById("log")?.textContent ?? "").includes(text),
		second,
		{ timeout: 30_000 },
	).catch(() => fail("bo took up the invitation but the room never reached him"));

	// ── The link on its own ──────────────────────────────────────────────
	// An invitation through the rail is one channel; the link under it is the
	// authority, and it works with no channel at all. Ada reads hers out, cy
	// arrives knowing nothing, and pasting it is the whole of getting in.
	await say(ada, "/link");
	const shown = await ada.waitForFunction(
		() => {
			const line = [...document.querySelectorAll("#log .sys")]
				.map((row) => row.textContent ?? "")
				.find((text) => text.includes("ocapn://"));
			return line === undefined ? null : (line.match(/ocapn:\/\/\S+/) ?? [null])[0];
		},
		undefined,
		{ timeout: 30_000 },
	).then((handle) => handle.jsonValue()).catch(() => null);
	if (typeof shown !== "string" || !shown.includes("/s/")) {
		fail(`/link did not say a link to this room: ${JSON.stringify(shown)}`);
	}
	// Redeemed by somebody who was never offered anything, on their own session.
	await say(cy, `/join ${shown} plans`);
	await cy.waitForFunction(
		() => document.querySelector("#roomList li.held") !== null,
		undefined,
		{ timeout: 30_000 },
	).catch(async () => {
		const log = (await cy.textContent("#log").catch(() => "?")) ?? "?";
		fail(`a reader holding the link alone could not get in: ${JSON.stringify(log.slice(-200))}`);
	});
	const heard = "anybody holding the link is here";
	await say(ada, heard);
	await cy.waitForFunction(
		(text) => (document.getElementById("log")?.textContent ?? "").includes(text),
		heard,
		{ timeout: 30_000 },
	).catch(() => fail("the reader who redeemed the link is not in the room"));
	// A link carries no name, so what the reader called it is what they see.
	const named = (await railRooms(cy)).find((row) => row.locked);
	if (named?.name !== "plans") {
		fail(`a room taken up by link is not called what the reader called it: ${JSON.stringify(named)}`);
	}

	// ── Declined ─────────────────────────────────────────────────────────
	// A second room, offered and refused. Declining lets the reference go, so
	// the row is answered and no room appears.
	await makeRoom(ada, "quiet", true);
	await ada.waitForFunction(
		(label) => [...document.querySelectorAll("#roomList .rname")].some((row) => row.textContent === label),
		"quiet",
		{ timeout: 30_000 },
	).catch(() => fail("ada could not make a second private room"));
	await say(ada, "/invite bo");
	await bo.waitForSelector(".inviterow", { timeout: 30_000 })
		.catch(() => fail("the second invitation never arrived"));
	await bo.click(".inviterow .room-leave");
	await bo.waitForFunction(
		() => document.querySelector(".inviterow") === null,
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("declining an invitation left it in the rail"));
	const afterDeclining = await railRooms(bo);
	if (afterDeclining.some((row) => row.name === "quiet")) {
		fail(`declining an invitation put the reader in the room anyway: ${JSON.stringify(afterDeclining)}`);
	}

	// The join card's own way in: a reader arriving cold — at this directory or
	// a foreign one, the branch is the same — makes a private room without first
	// announcing themselves in a listed room. The card's lock is pressed, the
	// join lands in a room whose intro says it is private, and the other tab's
	// live list never shows it.
	const cold = await browser.newPage();
	await cold.goto(`http://127.0.0.1:${httpPort}/`);
	await cold.waitForSelector("#joinBtn", { timeout: 20_000 });
	await cold.fill("#nick", "cole");
	await cold.fill("#room", "colddrop");
	const publicLabel = (await cold.textContent('label[for="room"]'))?.trim();
	if (publicLabel !== "Room") {
		fail(`the join card labeled the room field ${JSON.stringify(publicLabel)} before the lock was pressed`);
	}
	await cold.click("#joinPrivate");
	const privateLabel = (await cold.textContent('label[for="room"]'))?.trim();
	if (privateLabel !== "Private room") {
		fail(`the join card labeled the room field ${JSON.stringify(privateLabel)} after the lock was pressed`);
	}
	await cold.click("#joinBtn");
	await cold.waitForFunction(() => {
		const intro = document.querySelector("#log .conv-intro p")?.textContent ?? "";
		return intro.includes("private");
	}, { timeout: 20_000 }).catch(() => fail("the join card's lock did not open a private room"));
	await ada.waitForTimeout(400);
	const listedCold = await ada.evaluate(() =>
		[...document.querySelectorAll("#roomList .rname")].map((row) => row.textContent?.trim())
	);
	if (listedCold.includes("colddrop")) {
		fail("a private room made from the join card appeared in another tab's room list");
	}
	await cold.close();

	console.log(
		"PASS: a private room is reachable only by the authority to it — it is in no list, " +
			"naming the same thing opens a different room, an offer over a direct line is what " +
			"puts somebody else in it, and the link under that offer gets a reader in with no " +
			"channel at all; a declined offer leaves them out",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	try {
		web.kill();
	} catch {
		// already gone
	}
	await web.status;
}
Deno.exit(0);
