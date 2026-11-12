// Heavy rooms interoperability matrix. Two browser glowcap peers and two real
// Goblins rooms-chat vats exercise room movement and every direct-message pair
// over iroh. Each phase starts clean because Goblins assigns independent
// receivers one shared handoff-count namespace; the count-discrepancy phase
// pins that incompatibility directly.

import { type Browser, type BrowserContext, chromium, type Page } from "playwright";
import { acquireTraceCapability, connectTraceViewer, vatTraceEnv } from "../../apps/rooms/test/trace/viewer.ts";
import { ChatPeer, WAIT_MS } from "./chat_peer.ts";
import { until } from "../../apps/rooms/test/support/wait.ts";
import { establishLocalSession } from "../../apps/rooms/test/support/session_setup.ts";
import { confirmTitleLeave, directOpened } from "../../apps/rooms/test/page/harness.ts";
import { webAnnouncements, webPort } from "../../apps/rooms/test/support/web_front.ts";
import { retryCountdown } from "../../apps/rooms/lib/text/admission.ts";
import { sessionEffectOne } from "../../apps/rooms/lib/text/page.ts";
import { ROOMS_FAILURES } from "../../apps/rooms/lib/failure_data.ts";
import { INTRODUCTION_PER_MINUTE } from "../../apps/rooms/lib/application_data.ts";

const ROOT = new URL("../../", import.meta.url).pathname;
import { WEB } from "../../apps/rooms/test/support/paths.ts";
const PHASES = [
	"rooms-mixed",
	"rooms-homogeneous",
	"rooms-split",
	"dms-a",
	"dms-b",
	"dms-goblins",
	"count-discrepancy",
];
const phase = Deno.args.find((arg) => arg.startsWith("--phase="))?.slice(8);
if (phase == null || !PHASES.includes(phase)) {
	throw new Error(`name one phase with --phase=<${PHASES.join("|")}>, not ${phase ?? "none"}`);
}

const FULL = "matrix-all";
const WEB_A = "web-ada";
const WEB_B = "web-bob";
const GOB_A = "goblins-carol";
const GOB_B = "goblins-dan";

async function locatorAt(port: number): Promise<string> {
	let locator = "";
	await until(
		async () => {
			try {
				const response = await fetch(`http://127.0.0.1:${port}/locator`);
				locator = (await response.text()).trim();
				return response.ok && locator.length > 0;
			} catch {
				return false;
			}
		},
		"the rooms web front",
		WAIT_MS,
	);
	return locator;
}

type WebPeer = { nick: string; context: BrowserContext; page: Page };

type TimelineRecord = Record<string, unknown>;

function observedWireIds(records: TimelineRecord[]): Set<string> {
	return new Set(
		records
			.filter((record) => record.kind === "ocapn.session-opened")
			.map((record) => record.session_id)
			.filter((id): id is string => typeof id === "string" && id.length > 0),
	);
}

function liveWireIds(records: TimelineRecord[]): Set<string> {
	const wireByLocal = new Map<string, string>();
	const live = new Set<string>();
	for (const record of records) {
		const local = typeof record.session === "string" ? record.session : null;
		if (local === null) continue;
		if (record.kind === "ocapn.session-opened" && typeof record.session_id === "string") {
			wireByLocal.set(local, record.session_id);
			live.add(record.session_id);
			continue;
		}
		if (record.kind !== "ocapn.session-closed" && record.kind !== "ocapn.session-unobserved") {
			continue;
		}
		const wire = wireByLocal.get(local);
		if (wire === undefined) continue;
		wireByLocal.delete(local);
		live.delete(wire);
	}
	return live;
}

/** A viewer on the live timeline, connected the way ocapnviz connects.
 *
 * Records arrive through a capability the endpoint hands this viewer's inbox
 * after the announced sturdyref is enlivened, so this harness reads the
 * endpoint through the same shape as the browser proofs. */
async function watchTimeline(sturdyref: string): Promise<{
	records: TimelineRecord[];
	close: () => Promise<void>;
}> {
	const records: TimelineRecord[] = [];
	const viewer = await connectTraceViewer(sturdyref, (record) => {
		records.push(record as TimelineRecord);
	});
	return { records, close: () => viewer.close() };
}

async function joinWeb(
	browser: Browser,
	port: number,
	nick: string,
	room: string,
	trace: string,
): Promise<WebPeer> {
	const context = await browser.newContext({ viewport: { width: 1100, height: 760 } });
	const page = await context.newPage();
	page.on("pageerror", (err) => console.error(`  [${nick} page] ${err.message}`));
	await page.goto(`http://127.0.0.1:${port}/`);
	await establishLocalSession(page);
	await acquireTraceCapability(page, trace);
	await joinRoom({ nick, context, page }, room);
	return { nick, context, page };
}

async function joinRoom(peer: WebPeer, room: string): Promise<void> {
	await peer.page.fill("#nick", peer.nick);
	await peer.page.fill("#room", room);
	await peer.page.click("#joinBtn");
	await peer.page.waitForSelector("#line:not([disabled])", { timeout: WAIT_MS }).catch(async (cause) => {
		const shown = (await peer.page.locator("body").innerText()).slice(0, 2_000);
		throw new Error(`${peer.nick} did not enter ${room}: ${JSON.stringify(shown)}`, { cause });
	});
}

async function moveWeb(peer: WebPeer, room: string): Promise<void> {
	await confirmTitleLeave(peer.page);
	await peer.page.waitForSelector("#joinBtn", { state: "visible", timeout: WAIT_MS });
	await joinRoom(peer, room);
}

async function sayWeb(peer: WebPeer, text: string): Promise<void> {
	await peer.page.fill("#line", text);
	await peer.page.press("#line", "Enter");
}

async function seesWeb(peer: WebPeer, text: string): Promise<void> {
	await peer.page.locator(".bubble", { hasText: text }).last().waitFor({
		state: "visible",
		timeout: WAIT_MS,
	});
}

/** The live conversation with `other`. A receiver keeps a conversation its
 * partner closed, under the same name, beside the one a reopened line arrives
 * on, so the name alone does not pick the conversation that can carry. */
function liveDmRow(peer: WebPeer, other: string) {
	return peer.page.locator(`#dmList li:not(.closed) .dm-open:has(.rname:text-is("${other}"))`);
}

async function openWebDm(peer: WebPeer, other: string): Promise<void> {
	if (await liveDmRow(peer, other).count() > 0) {
		await showWebDm(peer, other);
		return;
	}
	const first = await pressNewDm(peer, other);
	if (first == null) return;
	await waitAdvisedRetry(peer, other, first);
	const again = await pressNewDm(peer, other);
	if (again != null) {
		throw new Error(
			`${peer.nick}'s direct message to ${other} was refused again after its advised delay: ${first} / ${again}`,
		);
	}
}

// An opening pays one introduction token at its first press, and the session
// refills `INTRODUCTION_PER_MINUTE` of them a minute (`Class::Introduction` in
// apps/rooms/rust/application/src/admission.rs). An empty bucket therefore
// advises at most one refill. Longer advice is a defect, not a wait.
const MAX_INTRODUCTION_RETRY_S = Math.ceil(60 / INTRODUCTION_PER_MINUTE);

/** Ask for a direct conversation by name, as a person does, and read what the
 * page answers: `null` once the conversation is open, otherwise the failure
 * the page told. */
async function pressNewDm(peer: WebPeer, other: string): Promise<string | null> {
	const refusals = peer.page.locator('.toast[data-kind="failure"] :is(p.toast-text, .toast-text .said-clamp)');
	// An earlier refusal leaves the page by itself, so the one read below is
	// this press's.
	await until(async () => await refusals.count() === 0, `${peer.nick}'s earlier refusal to leave the page`, WAIT_MS);
	if (!await peer.page.locator("#newDmInput").isVisible()) await peer.page.click("#newDmBtn");
	await peer.page.fill("#newDmInput", other);
	await peer.page.press("#newDmInput", "Enter");
	const refusal = refusals.first();
	// WAIT_MS outlasts the page's own bound on an opening, so the page always
	// settles one way or the other first.
	const refused = refusal.waitFor({ state: "attached", timeout: WAIT_MS }).then(() => true);
	const opened = directOpened(peer.page, other, WAIT_MS).then(() => false);
	const wasRefused = await Promise.race([refused, opened]);
	// tolerant: the race's loser times out on its own, and its rejection carries no outcome.
	refused.catch(() => {});
	// tolerant: the race's loser times out on its own, and its rejection carries no outcome.
	opened.catch(() => {});
	if (!wasRefused) return null;
	return (await refusal.textContent())?.trim() ?? "";
}

/** A rate-limited press says what happened and when to try again. The person
 * waits that long, and the page asks them no decision, because the session
 * admitted nothing. Any other refusal ends the opening. */
async function waitAdvisedRetry(peer: WebPeer, other: string, said: string): Promise<void> {
	const limited = ROOMS_FAILURES["rate-limited"];
	if (!said.startsWith(limited.summary)) {
		throw new Error(`${peer.nick}'s direct message to ${other} was refused: ${said}`);
	}
	const seconds = Array.from({ length: MAX_INTRODUCTION_RETRY_S }, (_, i) => i + 1).find((s) =>
		said === `${limited.summary} ${retryCountdown(s)} (rate-limited: scope=introduction; owner=session)`
	);
	if (seconds == null) {
		throw new Error(
			`${peer.nick}'s rate-limited direct message names no retry within ${MAX_INTRODUCTION_RETRY_S}s: ${said}`,
		);
	}
	if (await peer.page.getByText(sessionEffectOne, { exact: true }).count() > 0) {
		throw new Error(`${peer.nick}'s rate-limited direct message asked for a decision`);
	}
	await peer.page.waitForTimeout(seconds * 1000);
}

async function showWebDm(peer: WebPeer, other: string): Promise<void> {
	const row = liveDmRow(peer, other);
	await row.waitFor({ state: "visible", timeout: WAIT_MS });
	await row.click();
	// The previous conversation's composer stays live while this one opens, so
	// a line typed now waits for the conversation itself.
	await directOpened(peer.page, other, WAIT_MS);
}

async function roomLine(
	peers: WebPeer[],
	chats: ChatPeer[],
	sender: WebPeer | ChatPeer,
	text: string,
): Promise<void> {
	if (sender instanceof ChatPeer) await sender.send(text);
	else await sayWeb(sender, text);
	await Promise.all(peers.map((peer) => seesWeb(peer, text)));
	await Promise.all(
		chats.map((peer) => peer.wait(new RegExp(`<[^>]+> ${text}$`), `receive "${text}"`)),
	);
}

async function browserDm(
	sender: WebPeer,
	recipient: WebPeer | ChatPeer,
	text: string,
): Promise<void> {
	await openWebDm(sender, recipient.nick);
	await sayWeb(sender, text);
	if (recipient instanceof ChatPeer) {
		await recipient.wait(
			new RegExp(`^\\(dm\\) <${sender.nick}> ${text}$`),
			`receive DM from ${sender.nick}`,
		);
	} else {
		await showWebDm(recipient, sender.nick);
		await seesWeb(recipient, text);
	}
}

async function goblinsDm(
	sender: ChatPeer,
	recipient: WebPeer | ChatPeer,
	text: string,
): Promise<void> {
	await sender.reaches(recipient.nick);
	await sender.send(`/dm ${recipient.nick} ${text}`);
	if (recipient instanceof ChatPeer) {
		await recipient.wait(
			new RegExp(`^\\(dm\\) <${sender.nick}> ${text}$`),
			`receive DM from ${sender.nick}`,
		);
	} else {
		await showWebDm(recipient, sender.nick);
		await seesWeb(recipient, text);
	}
}

async function reopenBrowserDm(
	browserPeer: WebPeer,
	other: WebPeer | ChatPeer,
	round: number,
	timeline: TimelineRecord[],
): Promise<void> {
	await showWebDm(browserPeer, other.nick);
	const liveBefore = liveWireIds(timeline);
	await confirmTitleLeave(browserPeer.page);
	await until(
		() => {
			const live = liveWireIds(timeline);
			return [...liveBefore].some((wire) => !live.has(wire));
		},
		`${browserPeer.nick}'s DM with ${other.nick} to close on the timeline`,
		WAIT_MS,
	);
	const sessionIdsBefore = observedWireIds(timeline);
	await openWebDm(browserPeer, other.nick);
	const text = `reopen-${round}-${browserPeer.nick}-to-${other.nick}`;
	await sayWeb(browserPeer, text);
	if (other instanceof ChatPeer) {
		await other.wait(
			new RegExp(`^\\(dm\\) <${browserPeer.nick}> ${text}$`),
			`receive reopened DM`,
		);
	} else {
		// The receiver was reading the conversation that just closed, so its view
		// follows the reopened line on its own and the closed one stays as history.
		await directOpened(other.page, browserPeer.nick, WAIT_MS);
		await seesWeb(other, text);
	}
	await until(
		() => [...liveWireIds(timeline)].some((wire) => !sessionIdsBefore.has(wire)),
		`${browserPeer.nick}'s reopened DM with ${other.nick} to use a new timeline session`,
		WAIT_MS,
	);
}

const web = new Deno.Command(WEB, {
	// Every peer runs on this host, so the room announces its direct addresses
	// and the run never depends on a public relay.
	args: [
		"--transport=iroh",
		"--reachability=direct",
		"0",
	],
	cwd: ROOT,
	env: { GLOWCAP_ROOMS_CAPABILITIES: "trace", GLOWCAP_ROOMS_TRACE_PORT: "0" },
	// Piped for the front's startup block: its HTTP port and the trace link it
	// prints for the directory it runs. One reader takes every announcement and
	// passes the stream through. Its stderr is inherited, so nothing it says
	// waits on a reader.
	stdout: "piped",
	stderr: "inherit",
}).spawn();
const httpPort = await webPort(web);

const deadline = setTimeout(() => {
	console.error("goblins-rooms-matrix-iroh timed out after 10 minutes");
	try {
		web.kill();
	} catch {
		// already gone
	}
}, 600_000);

let browser: Browser | null = null;
let gobA: ChatPeer | null = null;
let gobB: ChatPeer | null = null;
let timeline: { records: TimelineRecord[]; close: () => void } | null = null;
try {
	const locator = await locatorAt(httpPort);
	const traceRef = await webAnnouncements(web).line("ROOMS-TRACE-LISTENING", "rooms-web");
	const vatTrace = vatTraceEnv(traceRef);
	timeline = await watchTimeline(traceRef);
	gobA = new ChatPeer(GOB_A, locator, FULL, vatTrace);
	gobB = new ChatPeer(GOB_B, locator, FULL, vatTrace);
	await Promise.all([gobA.ready(FULL), gobB.ready(FULL)]);
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const webA = await joinWeb(browser, httpPort, WEB_A, FULL, traceRef);
	const webB = await joinWeb(browser, httpPort, WEB_B, FULL, traceRef);

	if (phase === "count-discrepancy") {
		await browserDm(webA, gobA, "first independent receiver");
		// web-bob's opening redeems carol's introduction, and Goblins counts that
		// handoff in the namespace web-ada's redeem already used. Goblins rejects
		// the certificate, so the page settles the opening as a refusal the
		// person reads, and no direct line opens.
		const errorCursor = gobA.errors.length;
		const refused = await pressNewDm(webB, gobA.nick);
		if (refused == null) throw new Error("web-bob opened a direct line Goblins should have refused");
		console.log(`web-bob read: ${refused}`);
		if (!refused.startsWith(`${ROOMS_FAILURES["introduction-refused"].summary} (introduction-refused`)) {
			throw new Error(`web-bob's opening was not refused by carol's side: ${refused}`);
		}
		await gobA.waitError(
			/invalid-handoff-cert: Handoff cert invalid for session/,
			"reject Goblins' second independent receiver count",
			errorCursor,
		);
		if (await liveDmRow(webB, gobA.nick).count() > 0) {
			throw new Error("Goblins rejected web-bob's handoff but the page lists the direct line");
		}
		gobB.assertClean();
	} else if (phase === "rooms-mixed") {
		for (
			const [sender, text] of [
				[webA, "mixed from web ada"],
				[webB, "mixed from web bob"],
				[gobA, "mixed from goblins carol"],
				[gobB, "mixed from goblins dan"],
			] as const
		) await roomLine([webA, webB], [gobA, gobB], sender, text);
	} else if (phase === "rooms-homogeneous") {
		await Promise.all([moveWeb(webA, "glowcap-only"), moveWeb(webB, "glowcap-only")]);
		await roomLine([webA, webB], [], webA, "glowcap-only line");

		await gobA.command(
			"/open goblins-only",
			/^\* you are in goblins-only$/,
			"open #goblins-only",
		);
		await gobB.command(
			"/enter goblins-only",
			/^\* you are in goblins-only$/,
			"enter #goblins-only",
		);
		await roomLine([], [gobA, gobB], gobA, "goblins-only line");
	} else if (phase === "rooms-split") {
		await Promise.all([moveWeb(webA, "mixed-a"), moveWeb(webB, "mixed-b")]);
		await gobA.command("/enter mixed-a", /^\* you are in mixed-a$/, "enter #mixed-a");
		await gobB.command("/enter mixed-b", /^\* you are in mixed-b$/, "enter #mixed-b");
		await roomLine([webA], [gobA], webA, "small mixed a");
		await roomLine([webB], [gobB], gobB, "small mixed b");
	}

	if (phase === "dms-a" || phase === "dms-b") {
		const primary = phase === "dms-a" ? webA : webB;
		const other = phase === "dms-a" ? webB : webA;
		await browserDm(primary, other, `dm ${primary.nick} ${other.nick}`);
		await browserDm(other, primary, `dm ${other.nick} ${primary.nick}`);
		await browserDm(primary, gobA, `dm ${primary.nick} gob-a`);
		await goblinsDm(gobA, primary, `dm gob-a ${primary.nick}`);
		await browserDm(primary, gobB, `dm ${primary.nick} gob-b`);
		await goblinsDm(gobB, primary, `dm gob-b ${primary.nick}`);

		await reopenBrowserDm(primary, other, 1, timeline.records);
		await reopenBrowserDm(primary, gobA, 1, timeline.records);
		await reopenBrowserDm(primary, gobB, 1, timeline.records);
		await reopenBrowserDm(primary, gobA, 2, timeline.records);
	}

	if (phase === "dms-goblins") {
		await goblinsDm(gobA, gobB, "dm gob-a gob-b");
		await goblinsDm(gobB, gobA, "dm gob-b gob-a");

		// Goblins has no explicit per-DM close command. Restart one real chat peer,
		// which severs every session it owned, reclaim its nickname, and prove the
		// Goblins-to-Goblins pair can establish and carry again.
		gobA.assertClean();
		const liveBeforeRestart = liveWireIds(timeline.records);
		await gobA.close();
		await until(
			() => {
				const live = liveWireIds(timeline!.records);
				return [...liveBeforeRestart].some((wire) => !live.has(wire));
			},
			`${GOB_A}'s sessions to close after restart`,
			WAIT_MS,
		);
		gobA = new ChatPeer(GOB_A, locator, FULL, vatTrace);
		await gobA.ready(FULL);
		await goblinsDm(gobB, gobA, "dm gob-b restarted gob-a");
		await goblinsDm(gobA, gobB, "dm restarted gob-a gob-b");
	}

	if (phase !== "count-discrepancy") {
		await Promise.all([gobA.close(), gobB.close()]);
		gobA.assertClean();
		gobB.assertClean();
		console.log(
			`PASS (goblins-rooms-matrix-iroh, ${phase}): four real peers completed the requested rooms and DM matrix`,
		);
	} else {
		await Promise.all([gobA.close(), gobB.close()]);
		gobA.assertNoSyrupEof();
		gobB.assertClean();
		console.log(
			"PASS (goblins-rooms-matrix-iroh, count-discrepancy): Goblins reproduced its pinned cross-receiver handoff-count rejection",
		);
	}
} finally {
	clearTimeout(deadline);
	await timeline?.close();
	// best-effort: this teardown runs after the verdict, and a browser that fails to close leaks only its own process.
	if (browser) await browser.close().catch(() => {});
	for (const peer of [gobA, gobB]) peer?.kill();
	// best-effort: the status of a peer that was just killed carries no verdict, so a rejection is dropped.
	for (const peer of [gobA, gobB]) if (peer) await peer.child.status.catch(() => {});
	for (const peer of [gobA, gobB]) peer?.cleanupCompiled();
	try {
		web.kill();
	} catch {
		// already gone
	}
	await web.status;
}
