// Heavy rooms interoperability matrix. Two browser glowcap peers and two real
// Goblins rooms-chat vats exercise room movement and every direct-message pair
// over iroh. Each phase starts clean because Goblins assigns independent
// receivers one shared handoff-count namespace; the count-discrepancy phase
// pins that incompatibility directly.

import { type Browser, type BrowserContext, chromium, type Page } from "playwright";
import {
	connectTraceViewer,
	scrapeTraceSturdyref,
	traceMemorySeed,
	traceUrlOf,
} from "../../apps/rooms/test/trace/viewer.ts";
import { confirmTitleLeave } from "../../apps/rooms/test/page/harness.ts";
import { freePort } from "../../apps/rooms/test/support/rooms_server.ts";

const ROOT = new URL("../../", import.meta.url).pathname;
import { WEB } from "../../apps/rooms/test/support/paths.ts";
const CHAT = new URL("../../conformance/goblins-peer/racket/rooms-chat.rkt", import.meta.url)
	.pathname;
const RACKET_DIR = new URL("../../conformance/goblins-peer/racket/", import.meta.url).pathname;
const WAIT_MS = 60_000;
const phase = Deno.args.find((arg) => arg.startsWith("--phase="))?.slice(8) ?? "full";
if (
	!new Set([
		"rooms-mixed",
		"rooms-homogeneous",
		"rooms-split",
		"dms-a",
		"dms-b",
		"dms-goblins",
		"count-discrepancy",
	]).has(phase)
) {
	throw new Error(`unknown phase ${phase}`);
}

const FULL = "matrix-all";
const WEB_A = "web-ada";
const WEB_B = "web-bob";
const GOB_A = "goblins-carol";
const GOB_B = "goblins-dan";

async function until(
	ready: () => boolean | Promise<boolean>,
	what: string,
	ms = WAIT_MS,
): Promise<void> {
	const deadline = Date.now() + ms;
	while (!(await ready())) {
		if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
		await new Promise((resolve) => setTimeout(resolve, 50));
	}
}

async function locatorAt(port: number): Promise<string> {
	let locator = "";
	await until(async () => {
		try {
			const response = await fetch(`http://127.0.0.1:${port}/locator`);
			locator = (await response.text()).trim();
			return response.ok && locator.length > 0;
		} catch {
			return false;
		}
	}, "the rooms web front");
	return locator;
}

class ChatPeer {
	readonly lines: string[] = [];
	readonly errors: string[] = [];
	readonly child: Deno.ChildProcess;
	readonly #writer: WritableStreamDefaultWriter<Uint8Array>;
	readonly #drains: Promise<void>[];
	#compiledRoot: string | null;

	constructor(readonly nick: string, locator: string, room: string, traceUrl: string) {
		// Concurrent Racket processes must not replace one shared .zo while its
		// sibling is opening it. A private compiled root keeps startup parallel
		// and leaves the checkout untouched.
		this.#compiledRoot = Deno.makeTempDirSync({ prefix: "glowcap-rooms-racket-" });
		this.child = new Deno.Command("racket", {
			args: ["-y", CHAT, locator, room, nick],
			cwd: RACKET_DIR,
			env: {
				GLOWCAP_ROOMS_TRACE_URL: traceUrl,
				// The trailing empty path is Racket's `same` fallback: reuse
				// installed package bytecode, but write checkout-local bytecode only
				// into this peer's private first root.
				PLTCOMPILEDROOTS: `${this.#compiledRoot}${Deno.build.os === "windows" ? ";" : ":"}`,
			},
			stdin: "piped",
			stdout: "piped",
			stderr: "piped",
		}).spawn();
		this.#writer = this.child.stdin.getWriter();
		this.#drains = [
			this.#drain(this.child.stdout, this.lines, ""),
			this.#drain(this.child.stderr, this.errors, " stderr"),
		];
	}

	#drain(stream: ReadableStream<Uint8Array>, into: string[], suffix: string): Promise<void> {
		return (async () => {
			const decoder = new TextDecoder();
			let buffered = "";
			for await (const chunk of stream) {
				buffered += decoder.decode(chunk, { stream: true });
				const lines = buffered.split("\n");
				buffered = lines.pop() ?? "";
				for (const line of lines) {
					into.push(line);
					console.log(`  [${this.nick}${suffix}] ${line}`);
				}
			}
			buffered += decoder.decode();
			if (buffered.length > 0) {
				into.push(buffered);
				console.log(`  [${this.nick}${suffix}] ${buffered}`);
			}
		})().catch((err) => {
			this.errors.push(String(err));
		});
	}

	async ready(room: string): Promise<void> {
		await this.wait(new RegExp(`^\\* you are in ${room}$`), `join #${room}`);
		await this.wait(/granted you the name/, "DM registration");
	}

	async send(line: string): Promise<number> {
		const cursor = this.lines.length;
		await this.#writer.write(new TextEncoder().encode(`${line}\n`));
		return cursor;
	}

	async command(line: string, expected: RegExp, what: string): Promise<void> {
		const cursor = await this.send(line);
		await this.wait(expected, what, cursor);
	}

	async wait(pattern: RegExp, what: string, cursor = 0): Promise<void> {
		await until(
			() => this.lines.slice(cursor).some((line) => pattern.test(line)),
			`${this.nick} to ${what}`,
		);
	}

	async waitError(pattern: RegExp, what: string, cursor = 0): Promise<void> {
		await until(
			() => this.errors.slice(cursor).some((line) => pattern.test(line)),
			`${this.nick} to ${what}`,
		);
	}

	assertClean(): void {
		const fatal = this.errors.find((line) =>
			line.includes("invalid-handoff-cert") ||
			this.isSyrupEof(line)
		);
		if (fatal) throw new Error(`${this.nick} reported ${fatal}`);
	}

	assertNoSyrupEof(): void {
		const fatal = this.errors.find((line) => this.isSyrupEof(line));
		if (fatal) throw new Error(`${this.nick} reported ${fatal}`);
	}

	private isSyrupEof(line: string): boolean {
		return line.includes("open-input-bytes: contract violation") ||
			line.includes("expected: bytes?");
	}

	async close(): Promise<void> {
		await this.#writer.close().catch(() => {});
		const status = await this.child.status;
		await Promise.all(this.#drains);
		this.cleanupCompiled();
		if (!status.success) throw new Error(`${this.nick} exited ${status.code}`);
	}

	cleanupCompiled(): void {
		if (this.#compiledRoot === null) return;
		Deno.removeSync(this.#compiledRoot, { recursive: true });
		this.#compiledRoot = null;
	}

	kill(): void {
		try {
			this.child.kill();
		} catch {
			// already gone
		}
	}
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
	seed: ReturnType<typeof traceMemorySeed>,
): Promise<WebPeer> {
	const context = await browser.newContext({ viewport: { width: 1100, height: 760 } });
	await context.addInitScript(({ key, value }) => localStorage.setItem(key, value), seed);
	const page = await context.newPage();
	page.on("pageerror", (err) => console.error(`  [${nick} page] ${err.message}`));
	await page.goto(`http://127.0.0.1:${port}/`);
	await joinRoom({ nick, context, page }, room);
	return { nick, context, page };
}

async function joinRoom(peer: WebPeer, room: string): Promise<void> {
	await peer.page.fill("#nick", peer.nick);
	await peer.page.fill("#room", room);
	await peer.page.click("#joinBtn");
	await peer.page.waitForSelector("#line:not([disabled])", { timeout: WAIT_MS });
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

async function openWebDm(peer: WebPeer, other: string): Promise<void> {
	const row = peer.page.locator(`#dmList li:has-text("${other}") .dm-open`).first();
	if (await row.count() > 0) {
		await showWebDm(peer, other);
		return;
	}
	await peer.page.click("#newDmBtn");
	await peer.page.fill("#newDmInput", other);
	await peer.page.press("#newDmInput", "Enter");
	await peer.page.waitForSelector("#line:not([disabled])", { timeout: WAIT_MS });
}

async function showWebDm(peer: WebPeer, other: string): Promise<void> {
	const row = peer.page.locator(`#dmList li:has-text("${other}") .dm-open`).first();
	await row.waitFor({ state: "visible", timeout: WAIT_MS });
	await row.click();
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
		await showWebDm(other, browserPeer.nick);
		await seesWeb(other, text);
	}
	await until(
		() => [...liveWireIds(timeline)].some((wire) => !sessionIdsBefore.has(wire)),
		`${browserPeer.nick}'s reopened DM with ${other.nick} to use a new timeline session`,
	);
}

const httpPort = freePort();
const roomPort = freePort();
const tracePort = freePort();
const web = new Deno.Command(WEB, {
	args: [
		"--transport=tcp",
		"--transport=iroh",
		String(httpPort),
		String(roomPort),
	],
	cwd: ROOT,
	env: { GLOWCAP_ROOMS_TRACE: "1", GLOWCAP_ROOMS_TRACE_PORT: String(tracePort) },
	stdout: "null",
	// Read rather than inherited, because the trace capability is announced on
	// this stream and a viewer needs it. `scrapeTraceSturdyref` tees it onward, so
	// nothing the server says is lost by reading it here.
	stderr: "piped",
}).spawn();

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
	const traceRef = await scrapeTraceSturdyref(web.stderr);
	const traceUrl = traceUrlOf(traceRef);
	const traceSeed = traceMemorySeed(httpPort, traceRef);
	timeline = await watchTimeline(traceRef);
	gobA = new ChatPeer(GOB_A, locator, FULL, traceUrl);
	gobB = new ChatPeer(GOB_B, locator, FULL, traceUrl);
	await Promise.all([gobA.ready(FULL), gobB.ready(FULL)]);
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const webA = await joinWeb(browser, httpPort, WEB_A, FULL, traceSeed);
	const webB = await joinWeb(browser, httpPort, WEB_B, FULL, traceSeed);

	if (phase === "count-discrepancy") {
		await browserDm(webA, gobA, "first independent receiver");
		const errorCursor = gobA.errors.length;
		await openWebDm(webB, gobA.nick);
		await sayWeb(webB, "second independent receiver");
		await gobA.waitError(
			/invalid-handoff-cert: Handoff cert invalid for session/,
			"reject Goblins' second independent receiver count",
			errorCursor,
		);
		if (gobA.lines.some((line) => line.endsWith("second independent receiver"))) {
			throw new Error("Goblins reported an invalid handoff but also delivered its message");
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
		);
		gobA = new ChatPeer(GOB_A, locator, FULL, traceUrl);
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
	if (browser) await browser.close().catch(() => {});
	for (const peer of [gobA, gobB]) peer?.kill();
	for (const peer of [gobA, gobB]) if (peer) await peer.child.status.catch(() => {});
	for (const peer of [gobA, gobB]) peer?.cleanupCompiled();
	try {
		web.kill();
	} catch {
		// already gone
	}
	await web.status;
}
