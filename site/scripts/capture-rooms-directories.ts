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
 * the other two by pasting its address into the join card. One member is at
 * home on each directory, in the room mira joined there, and each of them
 * opens a direct conversation with her from that room's member list. Only
 * mira's page may dial the other two directories, and only because its relay
 * is told their room ports. Nothing links the directories to each other. No
 * product state or screenshot markup is mocked. Only the lines are scripted.
 * The images land under `--out`, `site/assets/` by default:
 *
 *   rooms-directories-*.webp        three rooms on three directories and a direct line from each
 *   rooms-directories-phone-*.webp  the same session shared to a phone, every directory included
 *
 * Given `--reels=<dir>`, it also films mira's two visits, each room's first
 * line arriving from the member at home there, the direct lines arriving from
 * all three directories, and mira opening the one from the farthest, as the
 * `rooms-directories` reel for the site's video (see `reel.ts`) in that
 * directory. Without it, the capture films nothing.
 */
import { type BrowserContext, chromium, type Page } from "playwright";
import { spawnWeb, webPort } from "../../apps/rooms/test/support/web_front.ts";
import { roomPortOf } from "../../apps/rooms/test/support/rooms_server.ts";
import { reapOwned } from "../../apps/rooms/test/support/children.ts";
import { establishLocalSession } from "../../apps/rooms/test/support/session_setup.ts";
import { directOpened, openDmTo, reachDirectoryOnCard } from "../../apps/rooms/test/page/harness.ts";
import { outDirArg, pinToLatest, plainRun, shot, still } from "./capture.ts";
import {
	filmArgs,
	filmDirArg,
	glide,
	glideClick,
	placePointer,
	startReel,
	themeArg,
	themedContext,
	typeOnFilm,
	unfilmed,
} from "./reel.ts";
import { ROOMS_LAYOUT, settled, smoothLayout } from "./film-smooth.ts";

const outDir = outDirArg();
/** How far apart the three members start writing to mira, so their lines
 * still land one after another in her rail. */
const LINE_BEAT_MS = 700;

/** One directory: a web front serving the page, over a room server of its own. */
interface Directory {
	http: number;
	room: number;
	/** The room this scene holds there. */
	name: string;
	/** The member who is at home on it. */
	member: string;
	/** The address mira pastes into the join card: the directory's TCP authority. */
	address: string;
}

/** Start a directory and learn where it listens: the front and its room server
 * each choose their own port and the front announces them. `reaches` are the
 * other directories this page's relay may dial, so they are up before it
 * starts: a relay dials cleartext TCP only where it is told. */
async function directory(name: string, member: string, reaches: Directory[] = []): Promise<Directory> {
	const front = spawnWeb({
		env: reaches.length === 0 ? {} : { GLOWCAP_RELAY_TCP_PEERS: reaches.map((r) => r.address).join(",") },
		args: ["--transport=tcp", "0", "0"],
		stdout: "piped",
		stderr: "inherit",
	});
	const http = await webPort(front);
	const room = await roomPortOf(http, `the directory serving ${name}`);
	return { http, room, name, member, address: `127.0.0.1:${room}` };
}

const zines = await directory("zine-swap", "oskar");
const sky = await directory("night-sky", "lu");
const home = await directory("workshop", "ren", [zines, sky]);
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

/** From inside a room, open another directory's room beside it, on film:
 * name the room in the sidebar, say it is somewhere else, and paste the
 * directory's address into the card. The pointer presses each control, and
 * the room's name is typed where the reel can see it. The card may already
 * hold the nick and the room, and then they are left as they are. */
async function visitOnFilm(
	page: Page,
	dir: Directory,
	nick: string,
	marked: (name: string) => Promise<void>,
): Promise<void> {
	const typeInto = async (selector: string, text: string, { paste = false } = {}) => {
		const field = page.locator(selector);
		if ((await field.inputValue()) === text) return;
		await glideClick(page, field);
		await field.fill("");
		if (paste) await field.fill(text);
		else await typeOnFilm(field, text);
	};
	await glideClick(page, page.locator("#newRoomBtn"));
	await typeInto("#newRoomInput", dir.name);
	await glideClick(page, page.locator("#newRoomElsewhere"));
	await page.waitForSelector("#joinForm", { timeout: 10_000 });
	await settled(page, "#joinForm");
	await marked("card");
	await typeInto("#joinAddressField", dir.address, { paste: true });
	await typeInto("#nick", nick);
	if (((await page.textContent("#joinBtn")) ?? "").trim() === "Connect") {
		await glideClick(page, page.locator("#joinBtn"));
		await page.locator("#room").waitFor({ state: "visible", timeout: 60_000 });
	}
	await typeInto("#room", dir.name);
	await glideClick(page, page.locator("#joinBtn"));
	await page.locator("#roomName", { hasText: dir.name }).waitFor({ timeout: 60_000 });
	await page.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
}

/** Bring a conversation in the rail forward by its name. */
async function open(page: Page, list: "#roomList" | "#dmList", name: string): Promise<void> {
	const row = list === "#roomList" ? `${list} li .rname-text` : `${list} li .rname`;
	await page.locator(row, { hasText: new RegExp(`^${name}$`) }).click();
	await page.locator("#roomName", { hasText: name }).waitFor({ timeout: 30_000 });
}

// A run that films draws mira's window at its scale.
const FILM_SCALE = 1.5;
const reelsDir = filmDirArg();
const theme = themeArg();
const browser = await chromium.launch({
	headless: true,
	args: ["--no-sandbox", ...(reelsDir == null ? [] : filmArgs(FILM_SCALE))],
});
const contexts: BrowserContext[] = [];
async function tab(dir: Directory, scale = 1): Promise<Page> {
	const context = await themedContext(browser, theme, {
		...still,
		viewport: { width: 1280, height: 760 },
		deviceScaleFactor: scale,
	});
	contexts.push(context);
	const page = await context.newPage();
	await page.goto(`http://127.0.0.1:${dir.http}/?dm=webrtc`, { waitUntil: "domcontentloaded" });
	await establishLocalSession(page);
	return page;
}

try {
	await Deno.mkdir(outDir, { recursive: true });

	// Each member is at home: one directory, the one that served their page.
	const members = new Map<Directory, Page>();
	for (const dir of [home, zines, sky]) {
		const page = await tab(dir);
		await joinHome(page, dir.name, dir.member);
		members.set(dir, page);
	}

	const ren = members.get(home)!;
	const oskar = members.get(zines)!;
	const lu = members.get(sky)!;

	// mira starts at home and then goes visiting, keeping every room she
	// holds. In each room she visits, the member at home there says what the
	// room is about, and the line reaches her across directories. The film
	// shows one visit, at the video's 16:9, then a member on each directory
	// writing to her. The window is small enough that the rail's addresses
	// read in the video with the whole app in view, so no camera crops it.
	const mira = await tab(home, FILM_SCALE);
	await joinHome(mira, home.name, human);
	await mira.setViewportSize({ width: 1088, height: 612 });
	await placePointer(mira, 595, 357);
	await visitOnFilm(mira, sky, human, async () => {});
	await post(lu, "Clear skies after midnight. Saturn is up by one.", mira);
	// Only a film eases the layout. A picture takes it as it stands.
	if (reelsDir != null) await smoothLayout(mira, ROOMS_LAYOUT);
	const reel = reelsDir == null ? unfilmed : await startReel(mira, `${reelsDir}/rooms-directories`);
	await mira.waitForTimeout(500);
	await reel.mark("home");
	// The window fades in on the open dialog before the pointer moves.
	await visitOnFilm(mira, zines, human, async (name) => {
		await reel.mark(name);
		await reel.hold(500);
	});
	// The rail now lists rooms on three servers. The pointer leaves the
	// composer, where it joined, for the empty foot of the member list.
	await reel.mark("joined");
	await glide(mira, 968, 380, 500);
	const visitLine = "Issue nine is printed. Trading two copies for anything hand-bound.";
	await post(oskar, visitLine, mira);
	// The rail rests on its three servers' rooms before the lines come.
	await reel.hold(1100);

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
	// The members write at once, a beat apart, so the film waits for the
	// slowest line to arrive rather than for each in turn. Each opens its own
	// direct session, and how long that takes varies from run to run.
	const rows = lines.map(([dir]) => mira.locator("#dmList li .rname", { hasText: new RegExp(`^${dir.member}$`) }));
	const writing = Promise.all(lines.map(async ([dir, ask], i) => {
		const page = members.get(dir);
		if (page == null) throw new Error(`film: no page for ${dir.member}`);
		await page.waitForTimeout(i * LINE_BEAT_MS);
		await openDmTo(page, human);
		await post(page, ask);
	}));
	// The first line to arrive marks the moment, and a member who fails to
	// write fails the film then, not after the wait.
	const firstRow = Promise.any(rows.map((row) => row.waitFor({ timeout: 30_000 })));
	await Promise.race([firstRow, writing.then(() => firstRow)]);
	await reel.mark("lines");
	await writing;
	for (const row of rows) await row.waitFor({ timeout: 30_000 });
	await mira.waitForTimeout(700);
	// mira opens the line from the farthest directory, and it reads like any
	// other conversation.
	const farthest = lines[lines.length - 1];
	// The pointer clicks the name's upper edge, so the arrow leaves the
	// server address under it in view.
	const name = await mira.locator("#dmList li .rname", { hasText: new RegExp(`^${farthest[0].member}$`) })
		.boundingBox();
	if (name == null) throw new Error(`the rail shows no line from ${farthest[0].member}`);
	await glideClick(mira, { x: name.x + name.width / 2, y: name.y + 3 });
	await directOpened(mira, farthest[0].member);
	await mira.locator(".bubble", { hasText: plainRun(farthest[1]) }).last().waitFor({ timeout: 30_000 });
	await reel.mark("direct");
	// The conversation holds long enough to read.
	await reel.hold(1300);
	await reel.stop();
	await mira.setViewportSize({ width: 1280, height: 760 });

	for (const [dir, ask, answer] of lines) {
		await open(mira, "#dmList", dir.member);
		await directOpened(mira, dir.member);
		await mira.locator(".bubble", { hasText: plainRun(ask) }).last().waitFor({ timeout: 30_000 });
		await post(mira, answer, members.get(dir)!);
	}

	// The home room's line, so the rail shows what each room is about. The
	// other two had theirs when mira visited. Each member is still in their direct line
	// with mira, so each goes back to their room first.
	await open(ren, "#roomList", home.name);
	await open(oskar, "#roomList", zines.name);
	await open(lu, "#roomList", sky.name);
	await open(mira, "#roomList", home.name);
	await post(ren, "Kiln is free Saturday if anyone wants to fire the new mugs.", mira);

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

	const second = await themedContext(browser, theme, {
		...still,
		viewport: { width: 430, height: 900 },
		deviceScaleFactor: 2,
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
	// oskar watches the line with mira, where the reply lands.
	await open(oskar, "#dmList", human);
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
