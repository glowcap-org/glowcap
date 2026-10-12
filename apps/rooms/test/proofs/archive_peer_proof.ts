import { spawnWeb } from "../support/web_front.ts";
// A reader selects the standalone archive peer in Settings, writes a direct
// message into it, and disappears. A fresh browser profile selects the same
// sturdyref and recovers the line, proving the peer is a member feature rather
// than only a callable service. The first profile also hands the other member a
// read-only facet for exactly their direct conversation; the receiver chooses
// to read it and sees its separate attribution.
//
// The first profile writes one line before selecting the peer, so the same
// conversation generation is split across this browser's store and the peer.
// The reopen is the combined view of ADR-0144: both lines stand once, and the
// account divider names both keepers.
//
// The room uses the self-contained TCP relay. The archive uses direct iroh for
// this same-host proof; deployments use discovery-backed iroh so its node-ID
// locator survives endpoint address changes.

import { type Browser, type BrowserContext, chromium, type Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { reapOwned } from "../support/children.ts";
import { confirmTitleLeave, directOpened } from "../page/harness.ts";
import { namedDirectRow } from "../support/conversation_row.ts";

const ROOT = new URL("../../../../", import.meta.url).pathname;

import { startArchivePeer } from "../support/archive_peer.ts";
const ROOM = "archive-room";
const KEPT = "this line outlives the browser that wrote it";
const KEPT_DEVICE = "this line was this browser's account of it";
const AFTER_PEER = "this still reaches its recipient while the archive is away";

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

async function announcedArchive(proc: Deno.ChildProcess): Promise<string> {
	const reader = proc.stdout.getReader();
	const decoder = new TextDecoder();
	let buffered = "";
	let done = false;
	let announced: string | null = null;
	try {
		while (!done && announced == null) {
			const chunk = await reader.read();
			done = chunk.done;
			if (done) continue;
			buffered += decoder.decode(chunk.value, { stream: true });
			announced = buffered.match(/ROOMS-ARCHIVE-LISTENING (\S+)/)?.[1] ?? null;
		}
	} finally {
		reader.releaseLock();
	}
	if (announced != null) return announced;
	fail("the archive peer exited without announcing its sturdyref");
}

async function waitForPage(port: number): Promise<void> {
	for (let attempt = 0; attempt < 400; attempt += 1) {
		try {
			const response = await fetch(`http://127.0.0.1:${port}/locator`);
			await response.body?.cancel();
			if (response.ok) return;
		} catch {
			// The supervisor has not finished opening its room yet.
		}
		await new Promise((resolve) => setTimeout(resolve, 50));
	}
	fail("the Rooms page did not become ready");
}

async function join(browser: Browser, port: number, nick: string): Promise<{ context: BrowserContext; tab: Page }> {
	const context = await browser.newContext();
	const tab = await context.newPage();
	tab.on("pageerror", (error) => console.error(`  [${nick} page error]`, error.message));
	await tab.goto(`http://127.0.0.1:${port}/`);
	await establishLocalSession(tab);
	await tab.fill("#nick", nick);
	await tab.fill("#room", ROOM);
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
	return { context, tab };
}

async function chooseArchive(tab: Page, sturdyref: string): Promise<void> {
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#holdingsTab");
	await tab.click("#archivePeerOpen");
	await tab.waitForSelector("#archivePeerTitle");
	const historyForm = await tab.evaluate(() => {
		const holdings = document.getElementById("holdingsPanel");
		const data = document.getElementById("sessionPanel");
		const history = document.getElementById("historyLegend");
		const archive = document.getElementById("archiveHoldingLegend");
		const remember = document.getElementById("rememberArchivePeer");
		const form = document.getElementById("archivePeerForm");
		const card = form?.closest(".modal-card");
		// History policy remains Data; the archive capability and Operations are
		// both explicit Holdings.
		return {
			ordered: holdings?.contains(archive) === true &&
				holdings?.contains(document.getElementById("opsLegend")) ===
					true &&
				data === null && history === null,
			sessionOwned: remember === null && (form?.textContent ?? "").includes("session retains"),
			contained: form?.contains(document.getElementById("archivePeerLink")) === true,
			copy: (card?.textContent ?? "") + (document.getElementById("archivePeerLinkHint")?.textContent ?? ""),
		};
	});
	if (!historyForm.ordered) fail("archive authority is not in Holdings, separate from Data's history policy");
	if (!historyForm.sessionOwned || !historyForm.contained) {
		fail(`the archive choice is not one design-system form: ${JSON.stringify(historyForm)}`);
	}
	// Case-folded: the claim is that the copy names what this peer is and what
	// the link lets its holder do, in everyday words rather than protocol
	// vocabulary, not that it opens either sentence in lower case.
	const explained = historyForm.copy.toLowerCase();
	if (!explained.includes("separate glowcap peer") || !explained.includes("read and write the archive")) {
		fail(`the archive peer explanation does not name its role and authority: ${JSON.stringify(historyForm.copy)}`);
	}
	await tab.fill("#archivePeerLink", sturdyref);
	await tab.click('#archivePeerForm button:has-text("Use archive peer")');
	await tab.waitForSelector("#archivePeerTaken")
		.catch(() => fail("taking an archive peer never said it went through"));
	await tab.locator(".archive-peer-modal").getByRole("button", { name: "Close" }).click();
	await tab.waitForSelector('.hint:has-text("Connected")', { timeout: 30_000 }).catch(async () => {
		const panel = await tab.textContent("#holdingsPanel").catch(() => "?");
		fail(`Settings did not connect the archive peer: ${JSON.stringify(panel)}`);
	});
	await tab.click("#settingsClose");
	await tab.waitForSelector("#settingsTitle", { state: "hidden" });
}

async function openDm(tab: Page, nick: string): Promise<void> {
	const button = tab.locator(`#members li:has-text("${nick}") button.dm-btn`);
	if (!await button.isVisible().catch(() => false)) await tab.click("#backBtn").catch(() => {});
	await button.waitFor({ state: "visible", timeout: 60_000 });
	await button.click();
	await directOpened(tab, nick, 15_000);
}

async function send(tab: Page, text: string): Promise<void> {
	await tab.fill("#line", text);
	await tab.press("#line", "Enter");
}

async function see(tab: Page, text: string, who: string): Promise<void> {
	await tab.locator(`.bubble:has-text("${text}")`).last().waitFor({ state: "visible", timeout: 30_000 }).catch(() =>
		fail(`${who} did not see ${JSON.stringify(text)}`)
	);
}

const deadline = setTimeout(() => fail("archive browser proof timed out after 120s"), 120_000);
const state = await Deno.makeTempDir();
const httpPort = freePort();
const roomPort = freePort();
const archive = startArchivePeer(state, ["--reachability=direct"], "inherit");
spawnWeb({
	args: ["--transport=tcp", String(httpPort), String(roomPort)],
	cwd: ROOT,
	stdout: "piped",
	stderr: "inherit",
});

let browser: Browser | null = null;
try {
	const [sturdyref] = await Promise.all([announcedArchive(archive), waitForPage(httpPort)]);
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const alice = await join(browser, httpPort, "archive-alice");
	const bob = await join(browser, httpPort, "archive-bob");
	// Written before any peer selection, this line is the device store's account
	// of the conversation the peer is about to start recording too. The direct
	// button waits for Bob's registration rather than navigating away from a
	// members list that has not drawn him yet. The conversation stays open
	// across the selection change, so both writes share one generation.
	const firstDm = alice.tab.locator('#members li:has-text("archive-bob") button.dm-btn');
	await firstDm.waitFor({ state: "visible", timeout: 90_000 });
	await firstDm.click();
	await directOpened(alice.tab, "archive-bob", 15_000);
	await send(alice.tab, KEPT_DEVICE);
	await see(alice.tab, KEPT_DEVICE, "Alice before archive selection");
	await chooseArchive(alice.tab, sturdyref);
	await alice.tab.waitForSelector("#line:not([disabled])", { timeout: 15_000 });
	await send(alice.tab, KEPT);
	await openDm(bob.tab, "archive-alice");
	await see(bob.tab, KEPT, "Bob");

	// The selected peer, not the browser's fallback store, mints a read-only
	// occurrence scoped to this line. Bob holds it only as a visible offer until
	// choosing to read, then the page returns it and attributes Alice's account
	// separately from live traffic.
	// Handing one over is a form, so it is a card of its own behind the
	// door on the conversation card.
	const openArchive = async (page: import("playwright").Page) => {
		await page.click("#convcardArchiveOpen");
		await page.waitForSelector(".archive-history-modal", { timeout: 30_000 });
	};
	const closeArchive = async (page: import("playwright").Page) => {
		await page.locator(".archive-history-modal").getByRole("button", { name: "Close" }).click();
		await page.waitForSelector(".archive-history-modal", { state: "detached", timeout: 30_000 });
	};
	await alice.tab.click("#roomAbout");
	await openArchive(alice.tab);
	await alice.tab.click("#convcardShareArchive");
	await alice.tab.waitForSelector('#convcardArchiveSaid:has-text("Shared with archive-bob")', { timeout: 30_000 });
	await closeArchive(alice.tab);
	await alice.tab.click("#convcardClose");
	await bob.tab.waitForSelector('.sys-line:has-text("shared read-only history")', { timeout: 30_000 });
	await bob.tab.click("#roomAbout");
	await openArchive(bob.tab);
	await bob.tab.waitForSelector('.archive-share-offer:has-text("archive-alice")', { timeout: 30_000 });
	await bob.tab.click(".archive-share-read");
	await bob.tab.waitForSelector('.sys-line:has-text("Earlier messages shared by archive-alice")', {
		timeout: 30_000,
	});
	await bob.tab.waitForSelector(".archive-share-offer", { state: "detached", timeout: 30_000 });
	await closeArchive(bob.tab);
	await bob.tab.click("#convcardClose");

	// A second offer exercises the other custody exit: the recipient can return
	// the imported occurrence without disclosing its records.
	await alice.tab.click("#roomAbout");
	await openArchive(alice.tab);
	await alice.tab.click("#convcardShareArchive");
	await bob.tab.click("#roomAbout");
	await openArchive(bob.tab);
	await bob.tab.waitForSelector('.archive-share-offer:has-text("archive-alice")', { timeout: 30_000 });
	await bob.tab.click(".archive-share-drop");
	// Letting go of what somebody handed over asks first, the way the room
	// card's other two Discards do.
	await bob.tab.locator(".archive-share-offer").getByRole("button", { name: "Discard", exact: true }).click();
	await bob.tab.waitForSelector(".archive-share-offer", { state: "detached", timeout: 30_000 });
	await closeArchive(bob.tab);
	await bob.tab.click("#convcardClose");
	await closeArchive(alice.tab);
	await alice.tab.click("#convcardClose");

	// Reopening forces Alice to read the record back through the peer before her
	// first profile disappears, so the proof never races a fire-and-forget put.
	await confirmTitleLeave(alice.tab);
	await openDm(alice.tab, "archive-bob");
	await alice.tab.waitForSelector('.sys-line:has-text("kept by the shared Rooms session archive peer")', {
		timeout: 30_000,
	}).catch(async () =>
		fail(
			`the archive read did not identify peer custody: ${
				JSON.stringify(
					await alice.tab.locator('.sys-line:has-text("Earlier messages")').allTextContents(),
				)
			}`,
		)
	);
	await see(alice.tab, KEPT, "Alice's first profile");
	// The combined read: the device-kept line stands beside the peer-kept one,
	// each exactly once, under one divider naming both keepers (ADR-0144).
	await see(alice.tab, KEPT_DEVICE, "Alice's device-kept line");
	const dividers = await alice.tab.locator('.sys-line:has-text("Earlier messages")').allTextContents();
	const combined = dividers.filter((text) => text.includes("kept by the shared Rooms session archive peer"));
	if (combined.length !== 1 || !combined[0].includes("and on this device")) {
		fail(`the split generation's divider did not name both keepers: ${JSON.stringify(dividers)}`);
	}
	for (const text of [KEPT, KEPT_DEVICE]) {
		const shown = await alice.tab.locator(`.bubble:has-text("${text}")`).count();
		if (shown !== 1) fail(`a combined account showed ${JSON.stringify(text)} ${shown} times`);
	}
	await alice.context.close();

	const returned = await join(browser, httpPort, "archive-returned");
	await chooseArchive(returned.tab, sturdyref);
	await openDm(returned.tab, "archive-bob");
	await returned.tab.waitForSelector('.sys-line:has-text("kept by the shared Rooms session archive peer")', {
		timeout: 30_000,
	});
	await see(returned.tab, KEPT, "Alice's fresh profile");
	// A fresh profile's device store holds nothing, so the combined read shows
	// the peer's account only: the first profile's device line stays behind.
	if (await returned.tab.locator(`.bubble:has-text("${KEPT_DEVICE}")`).count() !== 0) {
		fail("a fresh profile showed the first profile's device-only account");
	}

	// A selected peer going away is a visible recording failure, never a reason
	// to fork the member's history into this fresh profile. Sending still belongs
	// to the direct session and must continue independently.
	archive.kill("SIGTERM");
	const archiveExit = await archive.status;
	if (!archiveExit.success) fail(`the archive peer did not stop cleanly: ${JSON.stringify(archiveExit)}`);
	await returned.tab.locator('.toast:has-text("archive peer is unavailable")').waitFor({
		state: "visible",
		timeout: 30_000,
	}).catch(async () =>
		fail(
			`the page did not report that its selected archive peer became unavailable: ${
				JSON.stringify(
					await returned.tab.locator(".toast").allTextContents(),
				)
			}`,
		)
	);
	await send(returned.tab, AFTER_PEER);
	const incoming = namedDirectRow(bob.tab, "archive-returned").locator(".dm-open");
	await incoming.waitFor({ state: "visible", timeout: 30_000 }).catch(() =>
		fail("Bob did not receive a direct line from the returning profile")
	);
	await incoming.click();
	await see(bob.tab, AFTER_PEER, "Bob after the archive stopped");

	console.log(
		"PASS: a browser selected a durable iroh archive peer, handed one direct-line facet over explicitly, read one split generation back as a single account under both keepers, recovered history in a fresh profile, and declined archive writes visibly without interrupting delivery when the peer stopped",
	);
} finally {
	clearTimeout(deadline);
	if (browser !== null) await browser.close().catch(() => {});
	await reapOwned();
	await Deno.remove(state, { recursive: true }).catch(() => {});
}
Deno.exit(0);
