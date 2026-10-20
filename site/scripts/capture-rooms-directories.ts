#!/usr/bin/env -S deno run --allow-all
/// <reference lib="dom" />
/**
 * Capture the Rooms image of one session holding rooms on three directories,
 * with a direct conversation open to a member of each.
 *
 * `zig build site-captures` runs this from the repository root after the
 * Rooms product and the browser assets are built, and `zig build site`
 * depends on it, so the pictures are a build output and never a tracked
 * file. The script starts its own three directories from the installed
 * runtimes, each a web front over plain TCP on free loopback ports, so it
 * needs nothing running beforehand. To iterate on it, run it the same way:
 *
 *   deno run --allow-all site/scripts/capture-rooms-directories.ts --out=site/assets
 *
 * Four isolated browser peers drive the shipped page. mira's page is served
 * by the first directory, and she joins a room there, then a room on each of
 * the other two by pasting its locator into the join card. One member is at
 * home on each directory, in the room mira joined there, and each of them
 * opens a direct conversation with her from that room's member list. Only
 * mira's page may dial the other two directories, and only because its relay
 * is told their room ports. Nothing links the directories to each other. No
 * product state or screenshot markup is mocked. Only the lines are scripted.
 * The images land under `--out`, `site/assets/` by default:
 *
 *   rooms-directories-*.webp        three rooms on three directories and a direct line from each
 *   rooms-directories-phone-*.webp  the same session shared to a phone, every directory included
 */
import { type BrowserContext, chromium, type Page } from "playwright";
import { spawnWeb } from "../../apps/rooms/test/support/web_front.ts";
import { freePort } from "../../apps/rooms/test/support/ports.ts";
import { reapOwned } from "../../apps/rooms/test/support/children.ts";
import { establishLocalSession } from "../../apps/rooms/test/support/session_setup.ts";
import { directOpened, openDmTo, reachDirectoryOnCard } from "../../apps/rooms/test/page/harness.ts";
import { awaitLocator, outDirArg, pinToLatest, plainRun, shot, still } from "./capture.ts";

const outDir = outDirArg();

/** One directory: a web front serving the page, over a room server of its own. */
interface Directory {
	http: number;
	room: number;
	/** The room this scene holds there. */
	name: string;
	/** The member who is at home on it. */
	member: string;
	/** The address mira pastes into the join card: the directory's TCP authority. */
	locator: string;
}

function directory(name: string, member: string): Directory {
	const room = freePort();
	return { http: freePort(), room, name, member, locator: `127.0.0.1:${room}` };
}

/** Start a directory. `reaches` are the other directories this page's relay may
 * dial: a relay dials cleartext TCP only where it is told. */
function serve(dir: Directory, reaches: Directory[] = []): void {
	spawnWeb({
		env: reaches.length === 0 ? {} : { GLOWCAP_RELAY_TCP_PEERS: reaches.map((r) => r.locator).join(",") },
		args: ["--transport=tcp", String(dir.http), String(dir.room)],
		stdout: "null",
		stderr: "inherit",
	});
}

/** A directory is up once its page answers with its room locator. */
const ready = (dir: Directory): Promise<void> => awaitLocator(dir.http, `the directory serving ${dir.name}`);

const home = directory("workshop", "ren");
const zines = directory("zine-swap", "oskar");
const sky = directory("night-sky", "lu");
const human = "mira";

/** Type a line and send it, then wait for it to render on every page given. */
async function post(speaker: Page, text: string, ...watchers: Page[]): Promise<void> {
	await speaker.fill("#line", text);
	await speaker.press("#line", "Enter");
	for (const page of [speaker, ...watchers]) {
		await page.locator(".bubble", { hasText: plainRun(text) }).last().waitFor({ timeout: 30_000 });
	}
}

/** Open a room on the directory that served this page. */
async function joinHome(page: Page, room: string, nick: string): Promise<void> {
	await page.fill("#nick", nick);
	await reachDirectoryOnCard(page);
	await page.fill("#room", room);
	await page.click("#joinBtn");
	await page.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
}

/** From inside a room, open another directory's room beside it: name the room
 * in the rail, say it is somewhere else, and give the card that directory. */
async function joinElsewhere(page: Page, dir: Directory, nick: string): Promise<void> {
	await page.click("#newRoomBtn");
	await page.fill("#newRoomInput", dir.name);
	await page.click("#newRoomElsewhere");
	await page.waitForSelector("#joinForm", { timeout: 10_000 });
	await page.fill("#locator", dir.locator);
	await page.fill("#nick", nick);
	await reachDirectoryOnCard(page);
	await page.fill("#room", dir.name);
	await page.click("#joinBtn");
	await page.locator("#roomName", { hasText: dir.name }).waitFor({ timeout: 60_000 });
	await page.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
}

/** Bring a conversation in the rail forward by its name. */
async function open(page: Page, list: "#roomList" | "#dmList", name: string): Promise<void> {
	const row = list === "#roomList" ? `${list} li .rname-text` : `${list} li .rname`;
	await page.locator(row, { hasText: new RegExp(`^${name}$`) }).click();
	await page.locator("#roomName", { hasText: name }).waitFor({ timeout: 30_000 });
}

serve(home, [zines, sky]);
serve(zines);
serve(sky);

const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
const contexts: BrowserContext[] = [];
async function tab(dir: Directory, scale = 1): Promise<Page> {
	const context = await browser.newContext({
		...still,
		viewport: { width: 1280, height: 760 },
		deviceScaleFactor: scale,
		colorScheme: "dark",
	});
	contexts.push(context);
	const page = await context.newPage();
	await page.goto(`http://127.0.0.1:${dir.http}/?dm=webrtc`, { waitUntil: "domcontentloaded" });
	await establishLocalSession(page);
	return page;
}

try {
	await Deno.mkdir(outDir, { recursive: true });
	await Promise.all([home, zines, sky].map(ready));

	// Each member is at home: one directory, the one that served their page.
	const members = new Map<Directory, Page>();
	for (const dir of [home, zines, sky]) {
		const page = await tab(dir);
		await joinHome(page, dir.name, dir.member);
		members.set(dir, page);
	}

	// mira starts at home and then goes visiting, keeping every room she holds.
	const mira = await tab(home, 1.5);
	await joinHome(mira, home.name, human);
	await joinElsewhere(mira, zines, human);
	await joinElsewhere(mira, sky, human);

	// A line in each room, so the rail shows what each one is about.
	const ren = members.get(home)!;
	const oskar = members.get(zines)!;
	const lu = members.get(sky)!;
	await open(mira, "#roomList", home.name);
	await post(ren, "Kiln is free Saturday if anyone wants to fire the new mugs.", mira);
	await open(mira, "#roomList", zines.name);
	await post(oskar, "Issue nine is printed. Trading two copies for anything hand-bound.", mira);
	await open(mira, "#roomList", sky.name);
	await post(lu, "Clear skies after midnight. Saturn is up by one.", mira);

	// Each member writes to mira from the member list of their own room. The
	// directory that holds the room introduces them, and the line goes
	// directly between the two pages after that.
	const lines: [Directory, string, string][] = [
		[
			home,
			"Did your glaze test come out? I left the tiles by the sink.",
			"They did. The blue one crazed, the rest are perfect.",
		],
		[
			zines,
			"Saw you joined from another server. Want a copy of nine?",
			"Yes please. I can trade the risograph poster.",
		],
		[
			sky,
			"Bringing the big scope tonight. Want a turn on Saturn?",
			"Absolutely. I will bring coffee for the cold part.",
		],
	];
	for (const [dir, ask] of lines) {
		const page = members.get(dir)!;
		await openDmTo(page, human);
		await post(page, ask);
		const row = mira.locator("#dmList li .rname", { hasText: new RegExp(`^${dir.member}$`) });
		await row.waitFor({ timeout: 30_000 });
	}
	for (const [dir, ask, answer] of lines) {
		await open(mira, "#dmList", dir.member);
		await directOpened(mira, dir.member);
		await mira.locator(".bubble", { hasText: plainRun(ask) }).last().waitFor({ timeout: 30_000 });
		await post(mira, answer, members.get(dir)!);
	}

	// The capture: the direct line with the member from the farthest directory
	// open, and the rail holding all three rooms and all three lines.
	// The direct timeline is short, so a shorter window keeps it beside the
	// whole rail instead of under a band of empty sky.
	await open(mira, "#dmList", sky.member);
	await mira.setViewportSize({ width: 1280, height: 640 });
	await pinToLatest(mira);
	await shot(mira, outDir, "rooms-directories");
	await mira.setViewportSize({ width: 1280, height: 760 });

	// Share the session and open it on a phone. The phone is served by the
	// first directory and dials none of the others: it is a view of mira's
	// session, so every room and every direct line on every directory comes
	// with it, and a reply from the phone reaches oskar on his own directory.
	await mira.click("#settingsBtn");
	await mira.waitForSelector("#settingsTitle");
	await mira.click("#sessionTab");
	await mira.click("#sessionShareAsk");
	await mira.getByRole("button", { name: "Share this session", exact: true }).click();
	await mira.waitForSelector("#sessionShareAsk", { state: "detached", timeout: 60_000 });
	await mira.click("#holdingsTab");
	await mira.waitForSelector("#currentSessionCapability", { timeout: 60_000 });
	const sessionCapability = (await mira.textContent("#currentSessionCapability"))?.trim() ?? "";
	if (!sessionCapability.startsWith("ocapn://")) throw new Error(`no session capability: ${sessionCapability}`);
	await mira.click("#settingsClose");

	const second = await browser.newContext({
		...still,
		viewport: { width: 430, height: 900 },
		deviceScaleFactor: 2,
		colorScheme: "dark",
		isMobile: true,
		hasTouch: true,
	});
	contexts.push(second);
	const phone = await second.newPage();
	await phone.goto(`http://127.0.0.1:${home.http}/`, { waitUntil: "domcontentloaded" });
	await phone.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await phone.waitForSelector("#sessionSetup", { timeout: 60_000 });
	await phone.fill("#sessionSetupCapability", sessionCapability);
	await Promise.all([
		phone.waitForNavigation({ waitUntil: "domcontentloaded" }),
		phone.click("#sessionAttach"),
	]);
	await phone.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	for (const dir of [home, zines, sky]) {
		await phone.locator("#roomList li .rname-text", { hasText: new RegExp(`^${dir.name}$`) })
			.waitFor({ state: "attached", timeout: 60_000 });
		await phone.locator("#dmList li .rname", { hasText: new RegExp(`^${dir.member}$`) })
			.waitFor({ state: "attached", timeout: 60_000 });
	}
	// A reply from the phone into the line with oskar, who is on the second
	// directory, proves the phone is driving the session and not a copy of it.
	const fromPhone = "Sending this from my phone. Bring nine on Saturday?";
	const showing = (await phone.locator("#roomName").textContent().catch(() => "")) ?? "";
	if (!showing.includes(zines.member)) {
		await phone.locator("#backBtn:visible, #railToggle:visible").first().click();
		await phone.locator("#dmList li .rname", { hasText: new RegExp(`^${zines.member}$`) }).click();
	}
	await phone.locator("#roomName", { hasText: zines.member }).waitFor({ timeout: 30_000 });
	await phone.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
	await phone.fill("#line", fromPhone);
	await phone.click("#sendBtn");
	await oskar.locator(".bubble", { hasText: plainRun(fromPhone) }).last().waitFor({ timeout: 30_000 });
	// The capture is the phone's rail: three directories and a line on each.
	await phone.locator("#backBtn:visible, #railToggle:visible").first().click();
	await phone.locator("#dmList").waitFor({ state: "visible", timeout: 30_000 });
	// The rail is short, so a shorter phone keeps it from floating over empty sky.
	await phone.setViewportSize({ width: 430, height: 640 });
	await shot(phone, outDir, "rooms-directories-phone");
} finally {
	for (const context of contexts.reverse()) await context.close();
	await browser.close();
	await reapOwned();
}
