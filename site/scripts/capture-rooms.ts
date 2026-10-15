#!/usr/bin/env -S deno run --allow-all
/// <reference lib="dom" />
/**
 * Capture the Rooms product images used by the website.
 *
 * Start the web peer with every operator capability and a state directory,
 * its output captured to a file, and the IRC server against its directory:
 *
 *   GLOWCAP_ROOMS_STATE=/tmp/rooms-capture-state \
 *     zig build rooms-web -Dtransport=tcp -- 8080 9098 --diagnostics --admin-listeners --operator --peering --irc \
 *     > /tmp/rooms-web-capture.log 2>&1
 *   zig build rooms-irc-server -- --directory=127.0.0.1:9098 --port=6667
 *
 * then run:
 *
 *   deno run --allow-all site/scripts/capture-rooms.ts --state=/tmp/rooms-capture-state \
 *     --server-log=/tmp/rooms-web-capture.log
 *
 * The capture drives isolated browser peers through the shipped page: a
 * person and the four-bot roster a rooms team runs at its default cap, one
 * lead and three members named by their persona slugs. They join one team
 * room and exchange real lines in the shape the rooms-team skill prescribes
 * (strategy announced, findings reported, the human redirecting). The person
 * then opens a direct line from the roster, an IRC client enters the same
 * room through the IRC server, the person takes the operator capabilities into
 * Holdings and opens the directory pane, and finally shares the session so a
 * second browser can attach to it. No product state or screenshot markup is
 * mocked. Only the lines are scripted. Every capture is written twice, as
 * `<name>-dark.webp` and `<name>-light.webp` as lossless WebP, so a page can
 * show the face that matches its own theme without banding the UI gradients.
 * The images land under `site/assets/`:
 *
 *   rooms-session-*.webp           the first-run choice of where session state lives
 *   rooms-join-*.webp              the join card, pointed at the directory that served the page
 *   rooms-direct-*.webp            the direct conversation, browser to browser
 *   rooms-conversation-*.webp      the team room, with a direct line already in the rail
 *   rooms-irc-*.webp               the same room after an IRC client joined through the IRC server
 *   rooms-irc-transcript.txt      what that IRC client sent and received, verbatim
 *   rooms-operations-*.webp        the directory pane under /ops, held by capability
 *   rooms-session-attached-*.webp  a second browser attached to the first one's session
 *
 * Without `--state` the operations capture is skipped, and without an IRC server
 * on the IRC port the IRC capture is skipped. Each says so on stderr.
 */
import { type BrowserContext, chromium, type Page } from "playwright";
import { pinToLatest, plainRun, shot as capture, still } from "./capture.ts";

const positional = Deno.args.filter((arg) => !arg.startsWith("--"));
const flag = (name: string): string | undefined =>
	Deno.args.find((arg) => arg.startsWith(`--${name}=`))?.slice(name.length + 3);
const url = positional[0] ?? "http://127.0.0.1:8080/";
const outDir = positional[1] ?? "site/assets";
const stateDir = flag("state");
const serverLog = flag("server-log");
const ircPort = Number(flag("irc-port") ?? "6667");
const shot = (page: Page, name: string, within?: string) => capture(page, outDir, name, within);

/** A team room, named the way the rooms-team skill mints one. */
const room = "team-guide-20260912";
const human = "mira";
const lead = "agentic-lead";
const members = ["wire-clarity", "fresh-eyes", "first-impression"];
const ircNick = "ada";

/** Open the page and land on the join card, choosing a browser-local session on first use. */
async function open(page: Page, capture?: { session: string; join: string }): Promise<void> {
	await page.goto(url, { waitUntil: "domcontentloaded" });
	await page.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await page.waitForSelector("#sessionSetup, #joinBtn", { timeout: 60_000 });
	if (await page.locator("#sessionSetup").count()) {
		if (capture) await shot(page, capture.session, "#sessionSetup > *");
		await Promise.all([
			page.waitForNavigation({ waitUntil: "domcontentloaded" }),
			page.click("#sessionUseLocal"),
		]);
		await page.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	}
	await page.waitForSelector("#joinBtn", { timeout: 60_000 });
	if (capture) {
		// The join still shows a first room's name, the one the walkthrough
		// asks a reader to type; the team room below is what the scene joins.
		await page.fill("#room", "workshop");
		await shot(page, capture.join, "#joinForm");
	}
}

async function join(page: Page, nick: string): Promise<void> {
	await page.fill("#room", room);
	await page.fill("#nick", nick);
	await page.click("#joinBtn");
	await page.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
}

/** Type a line and send it: Enter on a keyboard, the send button on a phone, where Enter breaks the line. */
async function say(page: Page, text: string, phone = false): Promise<void> {
	await page.fill("#line", text);
	if (phone) await page.click("#sendBtn");
	else await page.press("#line", "Enter");
	await page.locator(".bubble", { hasText: plainRun(text) }).last().waitFor({ timeout: 30_000 });
}

/** The captured peer shows the line before the conversation moves on, so no capture catches a pending bubble. */
async function post(speaker: Page, watcher: Page, text: string, phone = false): Promise<void> {
	await say(speaker, text, phone);
	if (watcher !== speaker) {
		await watcher.locator(".bubble", { hasText: plainRun(text) }).last().waitFor({ timeout: 30_000 });
	}
}

/** A raw IRC client: what an ordinary IRC program does, with every line kept for the transcript. */
class IrcClient {
	readonly transcript: string[] = [];
	#conn: Deno.TcpConn;
	#pending = "";
	#lines: string[] = [];
	constructor(conn: Deno.TcpConn) {
		this.#conn = conn;
	}
	static async connect(port: number): Promise<IrcClient> {
		return new IrcClient(await Deno.connect({ hostname: "127.0.0.1", port }));
	}
	async send(line: string): Promise<void> {
		this.transcript.push(`> ${line}`);
		const bytes = new TextEncoder().encode(`${line}\r\n`);
		let written = 0;
		while (written < bytes.length) written += await this.#conn.write(bytes.subarray(written));
	}
	async #readLine(): Promise<string> {
		while (this.#lines.length === 0) {
			const buffer = new Uint8Array(4096);
			const n = await this.#conn.read(buffer);
			if (n === null) throw new Error("the IRC server closed the connection");
			this.#pending += new TextDecoder().decode(buffer.subarray(0, n));
			const parts = this.#pending.split("\r\n");
			this.#pending = parts.pop() ?? "";
			this.#lines.push(...parts);
		}
		const line = this.#lines.shift()!;
		this.transcript.push(`< ${line}`);
		return line;
	}
	/** Read until a line matches, answering pings on the way. */
	async until(pattern: RegExp): Promise<string> {
		for (;;) {
			const line = await this.#readLine();
			const ping = line.match(/^PING (.+)$/);
			if (ping) await this.send(`PONG ${ping[1]}`);
			if (pattern.test(line)) return line;
		}
	}
	close(): void {
		this.#conn.close();
	}
}

const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
const contexts: BrowserContext[] = [];
try {
	await Deno.mkdir(outDir, { recursive: true });
	// Tall enough for the whole scene from the human's first line to the
	// lead's replan, with the rail and roster beside it.
	const viewport = { width: 1280, height: 940 };
	const person = await browser.newContext({ ...still, viewport, deviceScaleFactor: 1.5, colorScheme: "dark" });
	contexts.push(person);
	const mira = await person.newPage();
	await open(mira, { session: "rooms-session", join: "rooms-join" });
	await join(mira, human);

	const bots = new Map<string, Page>();
	for (const nick of [lead, ...members]) {
		const context = await browser.newContext({ ...still, viewport, colorScheme: "dark" });
		contexts.push(context);
		const page = await context.newPage();
		await open(page);
		await join(page, nick);
		await mira.locator(`#members li:has(.name:text-is("${nick}"))`).waitFor({ timeout: 30_000 });
		bots.set(nick, page);
	}
	const leadPage = bots.get(lead)!;

	// The scene the rooms-team skill prescribes: the human hands the lead a
	// mission, the lead announces strategy and speak policy, members report
	// findings, the human redirects, the lead acks and replans.
	await post(mira, mira, `@${lead} review the new Rooms website section. This room is yours.`);
	await post(
		leadPage,
		mira,
		"Ack. Strategy: fan-out then fan-in, three independent reads merged here. Speak policy: I answer @mira in-room, members take DMs. Cap 4 incl. lead.",
	);
	await post(
		bots.get("wire-clarity")!,
		mira,
		"Reading rooms/architecture. The introduction paragraph matches the draft's three-party handoff. Checking the diagram against it now.",
	);
	await post(
		bots.get("fresh-eyes")!,
		mira,
		'First read of rooms/index: "the browser is a peer" lands. "Authority the reader can move or revoke" does not, not without an example.',
	);
	await post(
		bots.get("first-impression")!,
		mira,
		"The lead image is the product, good. The feature table squeezes the host column to a third, and that is the first thing a phone reader meets.",
	);
	await post(
		leadPage,
		mira,
		"@mira two findings so far: the squeezed host column and one abstract sentence in the intro. Merging once wire-clarity reports.",
	);
	await post(mira, mira, "Take the table out. Two lists side by side.");
	await post(
		leadPage,
		mira,
		`Ack, replanning. @first-impression owns the list rewrite, @fresh-eyes owns the intro sentence. @wire-clarity carry on.`,
	);

	// A direct line: mira presses the roster's direct control for the lead,
	// the lead answers in the conversation that appears, and both rails list it.
	await mira.click(`#members li:has(.name:text-is("${lead}")) .dm-btn`);
	await mira.locator("#dmList li .rname", { hasText: new RegExp(`^${lead}$`) }).waitFor({ timeout: 30_000 });
	await mira.waitForSelector("#line:not([disabled])", { timeout: 30_000 });
	await say(mira, "Keep the roster at four. I want the phone read fixed today, before anything else.");
	const leadDm = leadPage.locator("#dmList li .rname", { hasText: new RegExp(`^${human}$`) });
	await leadDm.waitFor({ timeout: 30_000 });
	await leadDm.click();
	await leadPage.locator(".bubble", { hasText: "Keep the roster" }).last().waitFor({ timeout: 30_000 });
	await post(leadPage, mira, "Noted. This stays between us. The room gets a plain @first-impression assignment.");
	// The direct timeline is short, so a shorter window keeps the capture on
	// its two lines and the conversation's own header instead of empty sky.
	await mira.setViewportSize({ width: viewport.width, height: 600 });
	await pinToLatest(mira);
	await shot(mira, "rooms-direct");
	await mira.setViewportSize(viewport);

	// Back in the room for the lead image: the timeline holds the whole
	// exchange, the rail shows the direct line beside it.
	const roomRow = mira.locator("#roomList li .rname-text", { hasText: new RegExp(`^${room}$`) });
	await roomRow.click();
	await mira.locator(".bubble", { hasText: "carry on" }).last().waitFor({ timeout: 30_000 });
	await shot(mira, "rooms-conversation");

	// An IRC client enters the same room through the IRC server: the registration
	// an ordinary client sends, a JOIN, a line, and what came back.
	let irc: IrcClient | undefined;
	try {
		irc = await IrcClient.connect(ircPort);
	} catch (error) {
		console.error(
			`capture-rooms: no IRC server on 127.0.0.1:${ircPort}, skipping the rooms-irc captures (${error})`,
		);
	}
	if (irc) {
		await irc.send(`NICK ${ircNick}`);
		await irc.send(`USER ${ircNick} 0 * :Ada, from an IRC client`);
		await irc.until(/ 001 /);
		await irc.until(/ 376 /);
		await irc.send(`JOIN #${room}`);
		await irc.until(/ 366 /);
		await mira.locator(`#members li:has(.name:text-is("${ircNick}"))`).waitFor({ timeout: 30_000 });
		const fromIrc = "Reading along from an IRC client. Same room, no browser.";
		await irc.send(`PRIVMSG #${room} :${fromIrc}`);
		await mira.locator(".bubble", { hasText: fromIrc }).last().waitFor({ timeout: 30_000 });
		const toIrc = `@${ircNick} welcome. The IRC server holds your seat, and the room sees an ordinary member.`;
		await say(mira, toIrc);
		await irc.until(new RegExp(`PRIVMSG #${room} :.*welcome`));
		// The IRC arrival is the last few rows, so a shorter window keeps the
		// capture on the join notice, the line, and the reply beside the roster.
		await mira.setViewportSize({ width: viewport.width, height: 640 });
		await pinToLatest(mira);
		await shot(mira, "rooms-irc");
		await mira.setViewportSize(viewport);
		await irc.send("QUIT :done");
		irc.close();
		await Deno.writeTextFile(`${outDir}/rooms-irc-transcript.txt`, irc.transcript.join("\n") + "\n");
	}

	// The operator capabilities: the complete `ROOMS-*` lines the server
	// prints go into Holdings, the same lines the field tells a reader to
	// enter, and the directory pane opens under /ops.
	if (stateDir == null || serverLog == null) {
		console.error(
			"capture-rooms: the rooms-operations captures need --state=<dir> and --server-log=<path>",
		);
	} else {
		const lines = (await Deno.readTextFile(serverLog))
			.split("\n")
			.filter((line) => /^ROOMS-[A-Z-]+ ocapn:\/\/\S+$/.test(line.trim()));
		if (lines.length === 0) {
			throw new Error(
				`capture-rooms: ${serverLog} prints no ROOMS-* capability lines; start the server with the operator flags and capture its output`,
			);
		}
		await mira.click("#settingsBtn");
		await mira.waitForSelector("#settingsTitle");
		await mira.click("#holdingsTab");
		await mira.click("#opsCapabilitySetEditText");
		await mira.fill("#opsCapabilitySet", lines.join("\n"));
		await mira.click("#opsCapabilitySetEditControls");
		await mira.click('#opsCapabilitySetForm button[type="submit"]');
		await mira.waitForSelector("#opsCapabilitySetSaved", { timeout: 30_000 });
		await mira.click("#settingsClose");
		await mira.goto(`${url}ops/directory`, { waitUntil: "domcontentloaded" });
		await mira.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
		await mira.waitForSelector("#directoryOpsPanel", { timeout: 60_000 });
		await mira.waitForSelector("#operatorRooms", { timeout: 60_000 });
		await shot(mira, "rooms-operations");
		await mira.goto(url, { waitUntil: "domcontentloaded" });
		await mira.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
		await roomRow.waitFor({ timeout: 60_000 });
	}

	// Share the session: this tab hosts it, and a fresh browser attaches with
	// the capability it prints, seeing the same rooms and the same direct line.
	await mira.click("#settingsBtn");
	await mira.waitForSelector("#settingsTitle");
	await mira.click("#sessionTab");
	await mira.click("#sessionShareAsk");
	await mira.getByRole("button", { name: "Share this session", exact: true }).click();
	await mira.waitForSelector("#sessionShareAsk", { state: "detached", timeout: 60_000 });
	await mira.getByText("This browser is hosting", { exact: true }).waitFor({ timeout: 10_000 });
	await mira.click("#holdingsTab");
	await mira.waitForSelector("#currentSessionCapability", { timeout: 60_000 });
	const sessionCapability = (await mira.textContent("#currentSessionCapability"))?.trim() ?? "";
	if (!sessionCapability.startsWith("ocapn://")) throw new Error(`no session capability: ${sessionCapability}`);
	await mira.click("#settingsClose");

	// A phone-sized window, so the picture says "wherever you go" rather
	// than repeating the desktop capture above it.
	const second = await browser.newContext({
		...still,
		viewport: { width: 430, height: 900 },
		deviceScaleFactor: 2,
		colorScheme: "dark",
		isMobile: true,
		hasTouch: true,
	});
	contexts.push(second);
	const attached = await second.newPage();
	await attached.goto(url, { waitUntil: "domcontentloaded" });
	await attached.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await attached.waitForSelector("#sessionSetup", { timeout: 60_000 });
	await attached.fill("#sessionSetupCapability", sessionCapability);
	await Promise.all([
		attached.waitForNavigation({ waitUntil: "domcontentloaded" }),
		attached.click("#sessionAttach"),
	]);
	await attached.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	// On a phone the rail is a drawer, so the room is reached through it
	// unless the session already opens on that room.
	// The session remembers which conversation was open, so the phone lands
	// on the room. If it did not, the rail is a drawer behind the top-left
	// button, and the room is a row in it.
	const phoneRoomRow = attached.locator("#roomList li .rname-text", { hasText: new RegExp(`^${room}$`) });
	await phoneRoomRow.waitFor({ state: "attached", timeout: 60_000 });
	const showing = (await attached.locator("#roomName").textContent().catch(() => "")) ?? "";
	if (!showing.includes(room)) {
		await attached.locator("#backBtn:visible, #railToggle:visible").first().click();
		await phoneRoomRow.waitFor({ state: "visible", timeout: 30_000 });
		await phoneRoomRow.click();
	}
	await attached.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
	await attached.locator("#roomName", { hasText: room }).waitFor({ timeout: 60_000 });
	await post(attached, mira, "Same session, from my phone. Every room and the direct line came with it.", true);
	await shot(attached, "rooms-session-attached");
} finally {
	for (const context of contexts.reverse()) await context.close();
	await browser.close();
}
