// Two browser tabs direct-message each other end to end on the page's default
// DM transport: each advertises a `webrtc` locator, and the room carries only
// the signaling (ADR-0089). Neither tab opens a listening socket, so neither
// can be dialed the ordinary way. When Alice direct-messages Bob, the room
// introduces her, her Host redeems the handoff give by signaling through the
// room directory, the DataChannel opens tab-to-tab, and the keyed OCapN
// session runs over it with the room out of the message path. Bob answers
// over that same arriving connection (`currentSession`), so a tab that never
// listens still replies.
//
// This is the default two-tab conversation as a reader meets it, with no
// query flag on the page URL. Reaching a tab through the relay's rendezvous
// instead has its own proofs: `dm_native_dial_test.ts` cold-dials a
// `?dm=relay` tab from a native Deno peer, and `dm_reopen_test.ts`
// drives both DM transports against the live timeline.
//
// Then Alice closes the conversation and starts a second one with the same
// person. Closing a direct line ends a connection and drops a history; it says
// nothing about who is reachable, so the members list must still offer her a
// direct line to Bob afterwards, and taking it must reach him. The two facts go
// together on purpose: an interface that keeps the button but cannot open a
// second line, and one that opens a second line but hides the way in, are the
// same broken promise from a reader's side.
//
// The room and both tabs run over plain TCP-through-relay (no iroh, no cargo):
// the tabs reach the room over `/relay?target=…` and reach each other over a
// DataChannel the room only signals, so this whole proof is deno-only.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives
// (serve.ts's room server is native), and a Playwright Chromium
// (the devcontainer image ships one).
// Run: `deno run --allow-all apps/rooms/test/web/dm_tabs_test.ts`.

import { Buffer } from "node:buffer";
import { type Browser, type BrowserContext, chromium, type Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { inkContrast } from "../ink_contrast.ts";
import { reapOwned, spawnOwned } from "../support/children.ts";
import { freePort, waitForHttp } from "../support/rooms_server.ts";
import { awaitBubble, confirmTitleLeave, fail, openDmTo } from "../support/page.ts";

import { WEB } from "../support/web_binary.ts";
const ROOT = new URL("../../../../", import.meta.url).pathname;
const ROOM = "lobby";
const DM_TEXT = "hi Bob, privately, from one browser tab to another";
const ALICE_FILE = "attachment over the introduced WebRTC line";
const ALICE_FILE_TWO = "a second capability on that same direct message";
const REPLY_TEXT = "got it Alice, replying over the same connection";
const BOB_FILE = "attachment over the inbound reply capability";
const SWAPPED_FILE = "the file Alice put in place of the first one";
const SECOND_TEXT = "hi again Bob, on a second line after I closed the first";
const SECOND_REPLY = "still here Alice, on the new connection";

// Open a fresh, isolated tab (its own storage, so the two peers never share a
// nick or room in localStorage), join `ROOM` as `nick`, and wait until the
// composer is live: the room session is up and the tab can register its inbox.
async function joinAs(browser: Browser, port: number, nick: string): Promise<{
	context: BrowserContext;
	tab: Page;
}> {
	const context = await browser.newContext();
	const tab = await context.newPage();
	tab.on("pageerror", (e) => console.error(`  [${nick} page error]`, e.message));
	tab.on("console", (msg) => {
		if (msg.type() === "error" || msg.type() === "warning") {
			console.error(`  [${nick} console.${msg.type()}]`, msg.text());
		}
	});
	await tab.goto(`http://127.0.0.1:${port}/`);
	await establishLocalSession(tab);
	await tab.fill("#nick", nick);
	await tab.fill("#room", ROOM);
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 }).catch(async () => {
		const status = await tab.textContent("#status").catch(() => "?");
		fail(`${nick} never joined; status="${status}"`);
	});
	return { context, tab };
}

// Open a direct line to `peer` from `tab` by clicking their direct-line button
// in the members list. It is there only once `peer` is both in the room roster
// and advertised as DM-able (their DM locator advertisement landed).
async function send(tab: Page, text: string): Promise<void> {
	await tab.fill("#line", text);
	await tab.press("#line", "Enter");
}

async function sendFiles(
	tab: Page,
	files: readonly { name: string; contents: string }[],
	caption: string,
): Promise<void> {
	await tab.setInputFiles(
		"#filePick",
		files.map((file) => ({
			name: file.name,
			mimeType: "text/plain",
			buffer: Buffer.from(file.contents),
		})),
	);
	await tab.fill("#line", caption);
	await tab.click("#sendBtn");
}

async function sameBubble(tab: Page, names: readonly string[], who: string): Promise<void> {
	await tab.waitForFunction(
		(names) => {
			const bubbles = names.map((name) =>
				[...document.querySelectorAll(".attach-file")]
					.find((row) => row.querySelector(".name")?.textContent === name)
					?.closest(".bubble")
			);
			return bubbles[0] != null && bubbles.every((bubble) => bubble === bubbles[0]);
		},
		names,
		{ timeout: 30_000 },
	).catch(() => fail(`${who} did not render ${names.join(" and ")} in one message bubble`));
}

async function downloadFile(tab: Page, name: string, expected: string, who: string): Promise<void> {
	const row = tab.locator(`.attach-file:has(.name:text-is("${name}"))`).last();
	await row.waitFor({ state: "visible", timeout: 30_000 }).catch(() =>
		fail(`${who} never rendered the direct-message file ${name}`)
	);
	const [download] = await Promise.all([
		tab.waitForEvent("download", { timeout: 30_000 }),
		row.locator("button").click(),
	]);
	const path = await download.path();
	if (path === null || await Deno.readTextFile(path) !== expected) {
		fail(`${who} did not download the bytes of ${name}`);
	}
}

// Wait until a bubble carrying `text` is on screen in the active conversation.
const deadline = setTimeout(() => fail("web-dm-tabs scenario timed out after 180s"), 180_000);

const httpPort = freePort();
const roomPort = freePort();

// serve.ts serves the page and runs the room + relay over plain TCP (no
// `--transport=iroh`), so the whole proof is deno-only.
spawnOwned(WEB, {
	args: ["--transport=tcp", String(httpPort), String(roomPort)],
	cwd: ROOT,
	stdout: "piped",
	stderr: "inherit",
});

let browser: Browser | null = null;
try {
	await waitForHttp(httpPort);

	browser = await chromium.launch({ args: ["--no-sandbox"] });

	// Alice joins first and opens the room; Bob joins it. Both advertise a
	// `webrtc` locator and file signaling inboxes with the directory, so each
	// appears in the other's DM-able roster.
	const alice = await joinAs(browser, httpPort, "web-alice");
	const bob = await joinAs(browser, httpPort, "web-bob");

	// Alice dials Bob: opening the DM redeems the room's introduction, the
	// directory carries the signaling, and the DataChannel session opens
	// tab-to-tab. Her line lands on Bob's giftable `dm`.
	await openDmTo(alice.tab, "web-bob");
	await send(alice.tab, DM_TEXT);

	// Bob renders it — the direct message reached a browser that never listens,
	// over the DataChannel, with the room off the message path.
	await openDmTo(bob.tab, "web-alice");
	await awaitBubble(bob.tab, DM_TEXT, "Bob");

	// A file follows the same introduced line. Bob pulls its bytes through the
	// capability Alice appended to the DM; the room and WebRTC signaling see no
	// file-specific operation.
	await sendFiles(
		alice.tab,
		[
			{ name: "from-alice.txt", contents: ALICE_FILE },
			{ name: "also-from-alice.txt", contents: ALICE_FILE_TWO },
		],
		"two files on our direct line",
	);
	await sameBubble(bob.tab, ["from-alice.txt", "also-from-alice.txt"], "Bob");
	await downloadFile(bob.tab, "from-alice.txt", ALICE_FILE, "Bob");
	await downloadFile(bob.tab, "also-from-alice.txt", ALICE_FILE_TWO, "Bob");

	// Bob replies over the very connection Alice's message arrived on
	// (`currentSession` + the reply capability she handed over), never dialing
	// her back. His DM thread with Alice is already open, so the composer sends
	// on the back-channel.
	await sendFiles(bob.tab, [{ name: "from-bob.txt", contents: BOB_FILE }], REPLY_TEXT);

	// Alice renders Bob's reply in her DM thread with him — the bidirectional
	// completion of a direct line between two peers that both refuse a listener.
	await awaitBubble(alice.tab, REPLY_TEXT, "Alice");
	await downloadFile(alice.tab, "from-bob.txt", BOB_FILE, "Alice");

	// A direct file line is a line, editable after the fact like a room's. Alice
	// changes the files on the message she sent: she drops the first, keeps the
	// second, and adds a new one. There is no room in the path — the handle she
	// holds is one Bob minted on their direct connection — and Bob, who is the
	// durable owner of a direct line's display, redraws the message in place. The
	// kept file is never re-sent; only the new one crosses.
	{
		const line = alice.tab.locator('.bubble:has-text("two files on our direct line")').last();
		await line.hover();
		await line.getByLabel("More for this message").click();
		await alice.tab.locator('.line-menu [role=menuitem]:has-text("Edit")').click();
		await alice.tab.waitForSelector('#changing:has-text("files")', { timeout: 10_000 })
			.catch(() => fail("editing a direct file line did not open the composer on its files"));
		await alice.tab.click('.composer-file:has-text("from-alice.txt") .composer-file-remove');
		await alice.tab.setInputFiles("#filePick", {
			name: "swapped-in.txt",
			mimeType: "text/plain",
			buffer: Buffer.from(SWAPPED_FILE),
		});
		await alice.tab.waitForSelector('.composer-file:has-text("swapped-in.txt")', { timeout: 10_000 })
			.catch(() => fail("the replacement direct file was not attached to the change"));
		await alice.tab.fill("#line", "swapped one file on our direct line");
		await alice.tab.click("#sendBtn");
		// Bob redraws the same line: the kept file and the new one, the dropped one
		// gone, and the new one's bytes fetch over the same direct connection.
		await sameBubble(bob.tab, ["also-from-alice.txt", "swapped-in.txt"], "Bob");
		await bob.tab.waitForFunction(
			() =>
				![...document.querySelectorAll(".attach-file .name")].some((name) =>
					name.textContent === "from-alice.txt"
				),
			undefined,
			{ timeout: 30_000 },
		).catch(() => fail("Bob still showed the file Alice dropped from the direct line"));
		await downloadFile(bob.tab, "swapped-in.txt", SWAPPED_FILE, "Bob");

		// And taking the whole line back reaches Bob too: the message goes, its
		// files with it.
		const refiled = alice.tab.locator('.bubble:has-text("swapped one file on our direct line")').last();
		await refiled.hover();
		await refiled.getByLabel("More for this message").click();
		await alice.tab.locator('.line-menu [role=menuitem]:has-text("Withdraw")').click();
		await bob.tab.waitForFunction(
			() =>
				![...document.querySelectorAll(".attach-file .name")].some((name) =>
					name.textContent === "swapped-in.txt"
				),
			undefined,
			{ timeout: 30_000 },
		).catch(() => fail("withdrawing a direct file line did not take its file away for Bob"));
	}

	// The rail is one rail. A direct line's row is the same object as a room's —
	// a mark, a name, and the marks that end it — so the mark that closes it has
	// to land where the marks it replaces were, exactly as leaving a room lands
	// on that room's count. This is the half of the rail no layout proof had
	// reached: the room row's geometry is measured in `page_test.ts`, and a
	// direct row is the only place these rules can be seen at all, because no
	// other proof opens one.
	await alice.tab.locator("#dmList li").first().hover();
	const shared = await alice.tab.evaluate(() => {
		const row = document.querySelector("#dmList li");
		const leave = row?.querySelector(".room-leave");
		const marks = row?.querySelector(".dm-marks");
		const name = row?.querySelector(".rname");
		const open = row?.querySelector(".dm-open");
		if (!row || !leave || !marks || !name || !open) return null;
		const mid = (el: Element) => {
			const b = el.getBoundingClientRect();
			return { x: b.x + b.width / 2, y: b.y + b.height / 2, r: b.right };
		};
		const a = mid(leave), b = mid(marks);
		const at = document.elementFromPoint(a.x, a.y);
		const seen = (el: Element) => {
			const b = el.getBoundingClientRect();
			return `${b.width.toFixed(0)}x${b.height.toFixed(0)} at ${b.x.toFixed(0)},${b.y.toFixed(0)}`;
		};
		return {
			dy: Math.abs(a.y - b.y),
			dx: Math.abs(a.x - b.x),
			pressable: at !== null && leave.contains(at),
			covering: at === null ? "nothing" : at.nodeName + "." + String(at.getAttribute("class") ?? ""),
			// Carried so a failure says what the boxes actually were. Which
			// mechanism laid the row out is the first question a wrong number
			// raises, and it is the one thing a difference of two centres cannot
			// answer on its own.
			boxes: `row ${seen(row)} (${getComputedStyle(row).display}), ` +
				`button ${seen(open)} (${getComputedStyle(open).display}), ` +
				`marks ${seen(marks)}, close ${seen(leave)}`,
		};
	});
	if (shared === null) fail("a direct-message row carried neither its marks nor the mark that closes it");
	else if (shared.dy > 1 || shared.dx > 1) {
		fail(
			`the close mark and the marks it replaces do not share a slot on a direct line: ` +
				`${shared.dy.toFixed(1)}px apart vertically and ${shared.dx.toFixed(1)}px across — ${shared.boxes}`,
		);
	} else if (!shared.pressable) {
		fail(`a press at the centre of the close mark lands on ${shared.covering} instead of the mark`);
	}

	// And a direct line's words clear the 4.5 to 1 small text asks for, against
	// what is really behind them, in both appearances.
	//
	// This is the teal half of a rule the page proof only ever checked on the
	// amber, and it is the harder half: the selected row puts the readable teal on
	// a wash of teal, and in syrup that readable teal *is* the teal — ink and
	// ground the same hue, with the wash lifting one toward the other. A room's
	// count stood in exactly that place and came out under the line.
	//
	// At rest, which takes saying twice. A hovered or focused row swaps its ink
	// for the one a link wears, so a reading taken with the pointer or the
	// keyboard still on it describes a state nobody is looking at.
	await alice.tab.mouse.move(0, 0);
	await alice.tab.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
	// One line, because one is what this scenario holds open: a second direct row
	// and the roster's own summary are not on screen here, and a selector that
	// cannot resolve is reported rather than skipped, so naming them would spend
	// every run restating that they are absent.
	const DM_INK = [
		["the name on the line being read", "#dmList li.here .rname"],
	] as const;
	const wasTheme = await alice.tab.getAttribute("html", "data-theme");
	const faint: string[] = [];
	for (const appearance of ["light", "dark"] as const) {
		await alice.tab.evaluate((t) => document.documentElement.setAttribute("data-theme", t), appearance);
		// Settled: changing the appearance re-renders the rail, and a rail arriving
		// runs a fade that starts at nothing. Read too early it lands near one to
		// one however the colours are set, which looks like a colour bug and does
		// not move when you fix colours.
		await alice.tab.evaluate(() => Promise.all(document.getAnimations().map((a) => a.finished.catch(() => {}))));
		for (const [what, selector] of DM_INK) {
			const measured = await inkContrast(alice.tab, selector);
			// Absent is not the same as fine. A row that is not on screen cannot be
			// measured, and a measurement that quietly stops answering reads exactly
			// like one that passes.
			if (measured === null) faint.push(`${what} could not be measured in ${appearance}`);
			else if (measured.ratio < 4.5) {
				faint.push(`${what} is ${measured.ratio.toFixed(2)}:1 in ${appearance} (${measured.saw})`);
			}
		}
	}
	await alice.tab.evaluate((t) => {
		if (t === null) document.documentElement.removeAttribute("data-theme");
		else document.documentElement.setAttribute("data-theme", t);
	}, wasTheme);
	if (faint.length > 0) {
		fail(`a direct line does not clear 4.5 to 1 for small text: ${faint.join("; ")}`);
	}

	// Alice ends the conversation with the mark in its title. The line's
	// connection goes with it and the thread leaves her rail, which is what
	// closing means here.
	await confirmTitleLeave(alice.tab);
	await alice.tab.waitForFunction(
		() => document.querySelectorAll("#dmList .dm-open").length === 0,
		undefined,
		{ timeout: 20_000 },
	).catch(() => fail("Alice closed the direct message but its thread stayed in her rail"));

	// The person is still there. Who can be reached directly is the room's
	// answer, not this conversation's, so the members list still offers Alice a
	// direct line to Bob — the way back in, and the only one she has once the
	// thread is gone.
	const again = alice.tab.locator(`#members li:has-text("web-bob") button.dm-btn`);
	await again.waitFor({ state: "visible", timeout: 30_000 }).catch(() =>
		fail("after closing the conversation, the members list no longer offered a line to web-bob")
	);

	// Taking it opens a second conversation, and it reaches him: a fresh
	// introduction, redeemed by a fresh dial, because the first line's
	// connection is gone.
	await again.click();
	await alice.tab.waitForSelector("#line:not([disabled])", { timeout: 10_000 });
	// The reopened line stands on what this device kept of the first one: the
	// remembered messages, then the divider saying where they came from.
	await alice.tab.waitForSelector('.sys-line:has-text("Earlier messages, kept on this device")', {
		timeout: 10_000,
	}).catch(() => fail("the reopened direct line did not hydrate the device's kept history"));
	await alice.tab.waitForSelector(`.bubble:has-text("${DM_TEXT}")`, { timeout: 5_000 })
		.catch(() => fail("the kept history did not stand the first conversation's line back up"));
	// The deleted direct file line must not rehydrate: history that outlives
	// a withdrawal would break the promise withdraw makes everywhere else.
	if (await alice.tab.$('.bubble:has-text("swapped one file on our direct line")') !== null) {
		fail("a withdrawn line stood back up from the device's kept history");
	}
	await send(alice.tab, SECOND_TEXT);
	await awaitBubble(bob.tab, SECOND_TEXT, "Bob");

	// And Bob answers on the new connection, so the second conversation is as
	// bidirectional as the first: his old reply route died with the line Alice
	// closed, and the one her second message arrived on replaced it.
	await send(bob.tab, SECOND_REPLY);
	await awaitBubble(alice.tab, SECOND_REPLY, "Alice");

	console.log(
		"PASS: two browser tabs direct-messaged each other on the default webrtc DM transport — one " +
			"redeemed a room introduction by signaling through the directory, the keyed session " +
			"opened tab-to-tab over the DataChannel with the room off the message path, and " +
			"independent files stayed in one bubble and crossed in both directions over the " +
			"introduced line and its reply capability; " +
			"the reply rode back over the same arriving connection to a tab that never listens; " +
			"then closing the conversation left the member reachable in the list and a second " +
			"line to the same person opened, carried a message, and carried a reply back",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
